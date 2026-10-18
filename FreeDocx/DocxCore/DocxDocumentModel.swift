//
//  DocxDocumentModel.swift
//  FreeDocx
//

import AppKit
import Foundation

enum DocxModelError: LocalizedError {
    case invalidDocumentXML
    case projectionMismatch(xmlParagraphs: Int, renderedParagraphs: Int)
    case unknownParagraphID
    case unsupportedComplexParagraph
    case unsupportedParagraphContainer

    var errorDescription: String? {
        switch self {
        case .invalidDocumentXML:
            return "word/document.xml is not a valid Word document."
        case let .projectionMismatch(xmlParagraphs, renderedParagraphs):
            return "The Word structure and editor projection do not match (Word: \(xmlParagraphs), editor: \(renderedParagraphs))."
        case .unknownParagraphID:
            return "FreeDocx lost the source identity for an edited paragraph."
        case .unsupportedComplexParagraph:
            return "This paragraph contains a field, drawing, or embedded object that cannot be edited safely yet."
        case .unsupportedParagraphContainer:
            return "This paragraph is inside a Word structure that cannot be edited safely yet."
        }
    }
}

enum DocxEditorAttribute {
    static let paragraphID = NSAttributedString.Key("com.thirdeyeds.FreeDocx.paragraphID")
    static let listMarker = NSAttributedString.Key("com.thirdeyeds.FreeDocx.listMarker")
    static let listMarkerIndent = NSAttributedString.Key("com.thirdeyeds.FreeDocx.listMarkerIndent")
    static let sectionRule = NSAttributedString.Key("com.thirdeyeds.FreeDocx.sectionRule")
    static let sourceFontFamily = NSAttributedString.Key("com.thirdeyeds.FreeDocx.sourceFontFamily")
    static let substituteFontFamily = NSAttributedString.Key("com.thirdeyeds.FreeDocx.substituteFontFamily")
}

struct DocxParagraphPresentation {
    let listMarker: String?
    let markerIndent: CGFloat?
    let textIndent: CGFloat?
    let sectionRuleColor: NSColor?
    let hasExplicitUnderline: Bool
    let spacingBefore: CGFloat?
    let spacingAfter: CGFloat?
    let lineSpacing: DocxLineSpacing?
}

enum DocxLineSpacing {
    case multiple(CGFloat)
    case exact(CGFloat)
    case atLeast(CGFloat)
}

final class DocxParagraph {
    let id: UUID
    fileprivate(set) var element: XMLElement

    init(id: UUID = UUID(), element: XMLElement) {
        self.id = id
        self.element = element
    }

    var text: String {
        (try? element.nodes(forXPath: ".//*[local-name()='t']"))?
            .compactMap(\.stringValue)
            .joined() ?? ""
    }

    var isComplex: Bool {
        let xpath = ".//*[local-name()='drawing' or local-name()='object' or local-name()='fldChar' or local-name()='instrText' or local-name()='footnoteReference' or local-name()='endnoteReference']"
        return ((try? element.nodes(forXPath: xpath))?.isEmpty == false)
    }
}

/// OOXML is the authoritative editable model. AppKit attributed text is only a
/// projection of these nodes and carries stable paragraph IDs back to them.
final class DocxDocumentModel {
    private(set) var xmlDocument: XMLDocument
    private(set) var paragraphs: [DocxParagraph]
    private var numbering: DocxNumberingResolver
    private var numberingData: Data?
    private var isNumberingDirty = false
    private let styles: DocxStyleResolver
    private let stylesData: Data?
    private let themeData: Data?
    private let fontTableData: Data?
    private let settingsData: Data?
    private(set) var isDirty = false

    convenience init(package: DocxPackage) throws {
        let documentData = try package.part(named: "word/document.xml")
        let numberingData = try? package.part(named: "word/numbering.xml")
        let stylesData = try? package.part(named: "word/styles.xml")
        let fontTableData = try? package.part(named: "word/fontTable.xml")
        let settingsData = try? package.part(named: "word/settings.xml")
        let themeData = package.paths.first(where: {
            $0.hasPrefix("word/theme/") && $0.hasSuffix(".xml")
        }).flatMap { try? package.part(named: $0) }
        try self.init(
            documentData: documentData,
            numberingData: numberingData,
            stylesData: stylesData,
            themeData: themeData,
            fontTableData: fontTableData,
            settingsData: settingsData,
            paragraphIDs: nil
        )
    }

    private init(
        documentData: Data,
        numberingData: Data?,
        stylesData: Data?,
        themeData: Data?,
        fontTableData: Data?,
        settingsData: Data?,
        paragraphIDs: [UUID]?
    ) throws {
        xmlDocument = try XMLDocument(data: documentData, options: [.nodePreserveAll])
        let nodes = try xmlDocument.nodes(forXPath: "//*[local-name()='p']")
        let elements = nodes.compactMap { $0 as? XMLElement }
        guard elements.count == nodes.count else {
            throw DocxModelError.invalidDocumentXML
        }
        if let paragraphIDs, paragraphIDs.count == elements.count {
            paragraphs = zip(paragraphIDs, elements).map {
                DocxParagraph(id: $0.0, element: $0.1)
            }
        } else {
            paragraphs = elements.map { DocxParagraph(element: $0) }
        }
        self.numberingData = numberingData
        numbering = try DocxNumberingResolver(data: numberingData)
        self.stylesData = stylesData
        self.themeData = themeData
        self.fontTableData = fontTableData
        self.settingsData = settingsData
        styles = try DocxStyleResolver(
            data: stylesData,
            themeData: themeData,
            fontTableData: fontTableData,
            settingsData: settingsData
        )
    }

    func transactionalCopy() throws -> DocxDocumentModel {
        let copy = try DocxDocumentModel(
            documentData: documentXMLData(),
            numberingData: numberingData,
            stylesData: stylesData,
            themeData: themeData,
            fontTableData: fontTableData,
            settingsData: settingsData,
            paragraphIDs: paragraphs.map(\.id)
        )
        copy.isDirty = isDirty
        copy.isNumberingDirty = isNumberingDirty
        return copy
    }

    func paragraph(with id: UUID) -> DocxParagraph? {
        paragraphs.first(where: { $0.id == id })
    }

    func applyRunPresentation(
        to projection: NSMutableAttributedString,
        paragraph: DocxParagraph,
        in range: NSRange
    ) {
        styles.applyRunPresentation(
            to: projection,
            paragraph: paragraph.element,
            in: range
        )
    }

    func pageLayout(fallback: DocumentPageLayout) -> DocumentPageLayout {
        guard let section = try? xmlDocument.nodes(
            forXPath: "(//*[local-name()='sectPr'])[last()]"
        ).first as? XMLElement else {
            return fallback
        }
        let size = try? section.nodes(forXPath: "./*[local-name()='pgSz']").first as? XMLElement
        let margins = try? section.nodes(forXPath: "./*[local-name()='pgMar']").first as? XMLElement

        let width = size.flatMap { Self.integerAttribute("w", in: $0) }.map { CGFloat($0) / 20 }
        let height = size.flatMap { Self.integerAttribute("h", in: $0) }.map { CGFloat($0) / 20 }
        let top = margins.flatMap { Self.integerAttribute("top", in: $0) }.map { CGFloat($0) / 20 }
        let right = margins.flatMap { Self.integerAttribute("right", in: $0) }.map { CGFloat($0) / 20 }
        let bottom = margins.flatMap { Self.integerAttribute("bottom", in: $0) }.map { CGFloat($0) / 20 }
        let left = margins.flatMap { Self.integerAttribute("left", in: $0) }.map { CGFloat($0) / 20 }

        return DocumentPageLayout(
            paperSize: CGSize(
                width: width ?? fallback.paperSize.width,
                height: height ?? fallback.paperSize.height
            ),
            topMargin: top ?? fallback.topMargin,
            rightMargin: right ?? fallback.rightMargin,
            bottomMargin: bottom ?? fallback.bottomMargin,
            leftMargin: left ?? fallback.leftMargin
        )
    }

    func presentations() -> [UUID: DocxParagraphPresentation] {
        var listCounters: [Int: [Int: Int]] = [:]
        var result: [UUID: DocxParagraphPresentation] = [:]

        for paragraph in paragraphs {
            let listReference = styles.listReference(in: paragraph.element)
            let listPresentation: (marker: String, markerIndent: CGFloat, textIndent: CGFloat)?
            if let listReference,
               let level = numbering.level(numID: listReference.numID, level: listReference.level) {
                var counters = listCounters[listReference.numID, default: [:]]
                let number = (counters[listReference.level] ?? (level.start - 1)) + 1
                counters[listReference.level] = number
                counters = counters.filter { $0.key <= listReference.level }
                listCounters[listReference.numID] = counters
                listPresentation = (
                    numbering.marker(
                        for: level,
                        level: listReference.level,
                        counters: counters
                    ),
                    CGFloat(level.leftTwips - level.hangingTwips) / 20,
                    CGFloat(level.leftTwips) / 20
                )
            } else if let listReference {
                listPresentation = (
                    "•",
                    CGFloat(max(listReference.level, 0) * 720 + 360) / 20,
                    CGFloat(max(listReference.level, 0) * 720 + 720) / 20
                )
            } else {
                listPresentation = nil
            }

            let paragraphLayout = styles.paragraphLayout(in: paragraph.element)
            result[paragraph.id] = DocxParagraphPresentation(
                listMarker: listPresentation?.marker,
                markerIndent: listPresentation?.markerIndent,
                textIndent: listPresentation?.textIndent,
                sectionRuleColor: styles.sectionRuleColor(in: paragraph.element),
                hasExplicitUnderline: styles.hasExplicitUnderline(in: paragraph.element),
                spacingBefore: paragraphLayout.spacingBefore,
                spacingAfter: paragraphLayout.spacingAfter,
                lineSpacing: paragraphLayout.lineSpacing
            )
        }
        return result
    }

    func updateText(of paragraph: DocxParagraph, to text: String) throws {
        guard !paragraph.isComplex else {
            throw DocxModelError.unsupportedComplexParagraph
        }
        guard paragraph.text != text else { return }
        try Self.replaceText(in: paragraph.element, with: text)
        isDirty = true
    }

    func applyRunFormatting(
        to paragraph: DocxParagraph,
        from attributedText: NSAttributedString
    ) throws {
        guard !paragraph.isComplex,
              Self.hasOnlySimpleRuns(paragraph.element) else {
            throw DocxModelError.unsupportedComplexParagraph
        }

        let existingRuns = (paragraph.element.children ?? []).compactMap { child -> XMLElement? in
            guard let element = child as? XMLElement, element.localName == "r" else { return nil }
            return element
        }
        let templates = Self.runTemplates(existingRuns)
        for run in existingRuns {
            run.detach()
        }

        if attributedText.length == 0 {
            paragraph.element.addChild(XMLElement(name: "w:r"))
            isDirty = true
            return
        }

        attributedText.enumerateAttributes(
            in: NSRange(location: 0, length: attributedText.length)
        ) { attributes, range, _ in
            let template = templates.first(where: { NSLocationInRange(range.location, $0.range) })?.run
                ?? templates.last?.run
            let run = XMLElement(name: "w:r")
            let runProperties: XMLElement
            if let template,
               let existing = try? template.nodes(
                   forXPath: "./*[local-name()='rPr']"
               ).first as? XMLElement {
                runProperties = existing.copy() as! XMLElement
            } else {
                runProperties = XMLElement(name: "w:rPr")
            }
            Self.applyRunProperties(attributes, to: runProperties)
            if !(runProperties.children?.isEmpty ?? true) {
                run.addChild(runProperties)
            }
            let value = attributedText.attributedSubstring(from: range).string
            let text = XMLElement(name: "w:t", stringValue: value)
            Self.updateSpacePreservation(on: text, text: value)
            run.addChild(text)
            paragraph.element.addChild(run)
        }
        isDirty = true
    }

    func setAlignment(
        of paragraph: DocxParagraph,
        to alignment: NSTextAlignment
    ) throws {
        let paragraphProperties: XMLElement
        if let existing = try paragraph.element.nodes(
            forXPath: "./*[local-name()='pPr']"
        ).first as? XMLElement {
            paragraphProperties = existing
        } else {
            paragraphProperties = XMLElement(name: "w:pPr")
            paragraph.element.insertChild(paragraphProperties, at: 0)
        }
        for node in try paragraphProperties.nodes(forXPath: "./*[local-name()='jc']") {
            node.detach()
        }
        let justification = XMLElement(name: "w:jc")
        let value: String
        switch alignment {
        case .center:
            value = "center"
        case .right:
            value = "right"
        case .justified:
            value = "both"
        default:
            value = "left"
        }
        justification.addAttribute(
            XMLNode.attribute(withName: "w:val", stringValue: value) as! XMLNode
        )
        paragraphProperties.addChild(justification)
        isDirty = true
    }

    func setBulletedList(
        of paragraph: DocxParagraph,
        enabled: Bool
    ) throws {
        let paragraphProperties: XMLElement
        if let existing = try paragraph.element.nodes(
            forXPath: "./*[local-name()='pPr']"
        ).first as? XMLElement {
            paragraphProperties = existing
        } else {
            paragraphProperties = XMLElement(name: "w:pPr")
            paragraph.element.insertChild(paragraphProperties, at: 0)
        }

        for node in try paragraphProperties.nodes(forXPath: "./*[local-name()='numPr']") {
            node.detach()
        }

        if enabled {
            let numberID = try ensureBulletNumbering()
            let numberingProperties = XMLElement(name: "w:numPr")
            let level = XMLElement(name: "w:ilvl")
            level.addAttribute(
                XMLNode.attribute(withName: "w:val", stringValue: "0") as! XMLNode
            )
            let number = XMLElement(name: "w:numId")
            number.addAttribute(
                XMLNode.attribute(
                    withName: "w:val",
                    stringValue: String(numberID)
                ) as! XMLNode
            )
            numberingProperties.addChild(level)
            numberingProperties.addChild(number)
            paragraphProperties.addChild(numberingProperties)
        } else {
            // A zero numId explicitly turns off numbering inherited from a
            // paragraph style. It is unnecessary for a direct-only list.
            if styles.listReference(in: paragraph.element) != nil {
                let numberingProperties = XMLElement(name: "w:numPr")
                let number = XMLElement(name: "w:numId")
                number.addAttribute(
                    XMLNode.attribute(withName: "w:val", stringValue: "0") as! XMLNode
                )
                numberingProperties.addChild(number)
                paragraphProperties.addChild(numberingProperties)
            }
            for node in try paragraphProperties.nodes(forXPath: "./*[local-name()='ind']") {
                node.detach()
            }
        }
        isDirty = true
    }

    @discardableResult
    func insertParagraph(
        text: String,
        at index: Int,
        template: DocxParagraph
    ) throws -> DocxParagraph {
        guard (0...paragraphs.count).contains(index) else {
            throw DocxModelError.unknownParagraphID
        }
        let element = try Self.makeParagraph(text: text, from: template.element)
        try Self.insert(element, among: paragraphs.map(\.element), at: index)
        let paragraph = DocxParagraph(element: element)
        paragraphs.insert(paragraph, at: index)
        isDirty = true
        return paragraph
    }

    func deleteParagraph(_ paragraph: DocxParagraph) throws {
        guard let index = paragraphs.firstIndex(where: { $0 === paragraph }) else {
            throw DocxModelError.unknownParagraphID
        }
        paragraph.element.detach()
        paragraphs.remove(at: index)
        isDirty = true
    }

    func documentXMLData() -> Data {
        xmlDocument.xmlData(options: [.nodePreserveAll])
    }

    var dirtyNumberingXMLData: Data? {
        isNumberingDirty ? numberingData : nil
    }

    private func ensureBulletNumbering() throws -> Int {
        if let existing = numbering.firstBulletNumberID {
            return existing
        }

        let numberingDocument: XMLDocument
        let root: XMLElement
        if let numberingData {
            numberingDocument = try XMLDocument(
                data: numberingData,
                options: [.nodePreserveAll]
            )
            guard let existingRoot = numberingDocument.rootElement() else {
                throw DocxModelError.invalidDocumentXML
            }
            root = existingRoot
        } else {
            root = XMLElement(name: "w:numbering")
            root.addNamespace(
                XMLNode.namespace(
                    withName: "w",
                    stringValue: "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                ) as! XMLNode
            )
            numberingDocument = XMLDocument(rootElement: root)
            numberingDocument.version = "1.0"
            numberingDocument.characterEncoding = "UTF-8"
        }

        let abstractIDs = ((try? root.nodes(
            forXPath: "./*[local-name()='abstractNum']"
        )) ?? []).compactMap { node -> Int? in
            guard let element = node as? XMLElement else { return nil }
            return Self.integerAttribute("abstractNumId", in: element)
        }
        let numberIDs = ((try? root.nodes(
            forXPath: "./*[local-name()='num']"
        )) ?? []).compactMap { node -> Int? in
            guard let element = node as? XMLElement else { return nil }
            return Self.integerAttribute("numId", in: element)
        }
        let abstractID = (abstractIDs.max() ?? -1) + 1
        let numberID = max((numberIDs.max() ?? 0) + 1, 1)

        let abstractNumber = XMLElement(name: "w:abstractNum")
        abstractNumber.addAttribute(
            XMLNode.attribute(
                withName: "w:abstractNumId",
                stringValue: String(abstractID)
            ) as! XMLNode
        )
        let level = XMLElement(name: "w:lvl")
        level.addAttribute(
            XMLNode.attribute(withName: "w:ilvl", stringValue: "0") as! XMLNode
        )
        let start = XMLElement(name: "w:start")
        start.addAttribute(XMLNode.attribute(withName: "w:val", stringValue: "1") as! XMLNode)
        let format = XMLElement(name: "w:numFmt")
        format.addAttribute(XMLNode.attribute(withName: "w:val", stringValue: "bullet") as! XMLNode)
        let levelText = XMLElement(name: "w:lvlText")
        levelText.addAttribute(XMLNode.attribute(withName: "w:val", stringValue: "•") as! XMLNode)
        let justification = XMLElement(name: "w:lvlJc")
        justification.addAttribute(XMLNode.attribute(withName: "w:val", stringValue: "left") as! XMLNode)
        let levelProperties = XMLElement(name: "w:pPr")
        let indentation = XMLElement(name: "w:ind")
        indentation.addAttribute(XMLNode.attribute(withName: "w:left", stringValue: "720") as! XMLNode)
        indentation.addAttribute(XMLNode.attribute(withName: "w:hanging", stringValue: "360") as! XMLNode)
        levelProperties.addChild(indentation)
        level.addChild(start)
        level.addChild(format)
        level.addChild(levelText)
        level.addChild(justification)
        level.addChild(levelProperties)
        abstractNumber.addChild(level)

        let number = XMLElement(name: "w:num")
        number.addAttribute(
            XMLNode.attribute(withName: "w:numId", stringValue: String(numberID)) as! XMLNode
        )
        let abstractReference = XMLElement(name: "w:abstractNumId")
        abstractReference.addAttribute(
            XMLNode.attribute(
                withName: "w:val",
                stringValue: String(abstractID)
            ) as! XMLNode
        )
        number.addChild(abstractReference)

        let firstNumberIndex = root.children?.firstIndex(where: {
            ($0 as? XMLElement)?.localName == "num"
        })
        if let firstNumberIndex {
            root.insertChild(abstractNumber, at: firstNumberIndex)
        } else {
            root.addChild(abstractNumber)
        }
        root.addChild(number)

        let updatedData = numberingDocument.xmlData(options: [.nodePreserveAll])
        numberingData = updatedData
        numbering = try DocxNumberingResolver(data: updatedData)
        isNumberingDirty = true
        return numberID
    }

    private static func replaceText(in paragraph: XMLElement, with newText: String) throws {
        let textNodes = try paragraph.nodes(
            forXPath: ".//*[local-name()='t']"
        ).compactMap { $0 as? XMLElement }

        if textNodes.isEmpty {
            let run = XMLElement(name: "w:r")
            let text = XMLElement(name: "w:t", stringValue: newText)
            updateSpacePreservation(on: text, text: newText)
            run.addChild(text)
            paragraph.addChild(run)
            return
        }

        let oldText = textNodes.compactMap(\.stringValue).joined()
        let oldCharacters = Array(oldText)
        let newCharacters = Array(newText)
        var prefix = 0
        while prefix < min(oldCharacters.count, newCharacters.count),
              oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(oldCharacters.count, newCharacters.count) - prefix,
              oldCharacters[oldCharacters.count - suffix - 1]
                == newCharacters[newCharacters.count - suffix - 1] {
            suffix += 1
        }

        var originalNodeForCharacter: [Int] = []
        for (nodeIndex, node) in textNodes.enumerated() {
            originalNodeForCharacter.append(
                contentsOf: Array(repeating: nodeIndex, count: Array(node.stringValue ?? "").count)
            )
        }

        var contents = Array(repeating: "", count: textNodes.count)
        for newIndex in newCharacters.indices {
            let nodeIndex: Int
            if newIndex < prefix, newIndex < originalNodeForCharacter.count {
                nodeIndex = originalNodeForCharacter[newIndex]
            } else if newIndex >= newCharacters.count - suffix {
                let oldIndex = oldCharacters.count - (newCharacters.count - newIndex)
                nodeIndex = originalNodeForCharacter.indices.contains(oldIndex)
                    ? originalNodeForCharacter[oldIndex]
                    : max(textNodes.count - 1, 0)
            } else if prefix > 0, originalNodeForCharacter.indices.contains(prefix - 1) {
                nodeIndex = originalNodeForCharacter[prefix - 1]
            } else if suffix > 0,
                      originalNodeForCharacter.indices.contains(oldCharacters.count - suffix) {
                nodeIndex = originalNodeForCharacter[oldCharacters.count - suffix]
            } else {
                nodeIndex = 0
            }
            contents[nodeIndex].append(newCharacters[newIndex])
        }

        for (node, value) in zip(textNodes, contents) {
            node.stringValue = value
            updateSpacePreservation(on: node, text: value)
        }
    }

    private static func makeParagraph(text: String, from template: XMLElement) throws -> XMLElement {
        let paragraph = XMLElement(name: template.name ?? "w:p")
        if let properties = try template.nodes(
            forXPath: "./*[local-name()='pPr']"
        ).first {
            paragraph.addChild(properties.copy() as! XMLNode)
        }

        let run = XMLElement(name: "w:r")
        if let runProperties = try template.nodes(
            forXPath: ".//*[local-name()='r'][.//*[local-name()='t']][1]/*[local-name()='rPr']"
        ).first {
            run.addChild(runProperties.copy() as! XMLNode)
        }
        let textElement = XMLElement(name: "w:t", stringValue: text)
        updateSpacePreservation(on: textElement, text: text)
        run.addChild(textElement)
        paragraph.addChild(run)
        return paragraph
    }

    private static func hasOnlySimpleRuns(_ paragraph: XMLElement) -> Bool {
        for child in paragraph.children ?? [] {
            guard let element = child as? XMLElement else { continue }
            guard element.localName == "pPr" || element.localName == "r" else {
                return false
            }
            if element.localName == "r" {
                for runChild in element.children ?? [] {
                    guard let runElement = runChild as? XMLElement else { continue }
                    guard runElement.localName == "rPr" || runElement.localName == "t" else {
                        return false
                    }
                }
            }
        }
        return true
    }

    private static func runTemplates(
        _ runs: [XMLElement]
    ) -> [(range: NSRange, run: XMLElement)] {
        var location = 0
        return runs.map { run in
            let length = ((try? run.nodes(forXPath: ".//*[local-name()='t']")) ?? [])
                .compactMap(\.stringValue)
                .joined()
                .utf16
                .count
            defer { location += length }
            return (NSRange(location: location, length: max(length, 1)), run)
        }
    }

    private static func applyRunProperties(
        _ attributes: [NSAttributedString.Key: Any],
        to properties: XMLElement
    ) {
        let supportedNames = Set(["rFonts", "sz", "szCs", "b", "i", "u", "color"])
        for child in properties.children ?? [] {
            if let element = child as? XMLElement,
               let localName = element.localName,
               supportedNames.contains(localName) {
                element.detach()
            }
        }

        if let font = attributes[.font] as? NSFont {
            let renderedFamily = font.familyName ?? font.fontName
            let sourceFamily = attributes[DocxEditorAttribute.sourceFontFamily] as? String
            let substituteFamily = attributes[DocxEditorAttribute.substituteFontFamily] as? String
            let family: String
            if let sourceFamily,
               let substituteFamily,
               renderedFamily.caseInsensitiveCompare(substituteFamily) == .orderedSame {
                family = sourceFamily
            } else {
                family = renderedFamily
            }
            let fonts = XMLElement(name: "w:rFonts")
            for name in ["w:ascii", "w:hAnsi", "w:cs"] {
                fonts.addAttribute(XMLNode.attribute(withName: name, stringValue: family) as! XMLNode)
            }
            properties.addChild(fonts)

            let halfPoints = String(Int((font.pointSize * 2).rounded()))
            for name in ["w:sz", "w:szCs"] {
                let size = XMLElement(name: name)
                size.addAttribute(XMLNode.attribute(withName: "w:val", stringValue: halfPoints) as! XMLNode)
                properties.addChild(size)
            }

            let traits = NSFontManager.shared.traits(of: font)
            for (name, enabled) in [
                ("w:b", traits.contains(.boldFontMask)),
                ("w:i", traits.contains(.italicFontMask))
            ] {
                let property = XMLElement(name: name)
                // Omission inherits the style; an editor toggle needs an
                // explicit off value to override inherited emphasis.
                if !enabled {
                    property.addAttribute(
                        XMLNode.attribute(withName: "w:val", stringValue: "0") as! XMLNode
                    )
                }
                properties.addChild(property)
            }
        }

        let underlineValue = (attributes[.underlineStyle] as? NSNumber)?.intValue
            ?? (attributes[.underlineStyle] as? Int)
            ?? 0
        let underline = XMLElement(name: "w:u")
        underline.addAttribute(
            XMLNode.attribute(
                withName: "w:val",
                stringValue: underlineValue == 0 ? "none" : "single"
            ) as! XMLNode
        )
        properties.addChild(underline)

        if let color = attributes[.foregroundColor] as? NSColor,
           let rgb = color.usingColorSpace(.sRGB) {
            let red = Int((rgb.redComponent * 255).rounded())
            let green = Int((rgb.greenComponent * 255).rounded())
            let blue = Int((rgb.blueComponent * 255).rounded())
            let colorElement = XMLElement(name: "w:color")
            colorElement.addAttribute(
                XMLNode.attribute(
                    withName: "w:val",
                    stringValue: String(format: "%02X%02X%02X", red, green, blue)
                ) as! XMLNode
            )
            properties.addChild(colorElement)
        }
    }

    private static func insert(
        _ paragraph: XMLElement,
        among current: [XMLElement],
        at index: Int
    ) throws {
        let previous = index > 0 ? current[index - 1] : nil
        let next = index < current.count ? current[index] : nil
        if let previous, let next, previous.parent !== next.parent {
            throw DocxModelError.unsupportedParagraphContainer
        }
        let reference = next ?? previous
        guard let reference,
              let parent = reference.parent as? XMLElement,
              let referenceIndex = parent.children?.firstIndex(where: { $0 === reference }) else {
            throw DocxModelError.unsupportedParagraphContainer
        }
        parent.insertChild(paragraph, at: next == nil ? referenceIndex + 1 : referenceIndex)
    }

    private static func updateSpacePreservation(on element: XMLElement, text: String) {
        element.removeAttribute(forName: "xml:space")
        if text.first?.isWhitespace == true || text.last?.isWhitespace == true {
            element.addAttribute(
                XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as! XMLNode
            )
        }
    }

    private static func integerAttribute(_ localName: String, in element: XMLElement) -> Int? {
        stringAttribute(localName, in: element).flatMap(Int.init)
    }

    private static func stringAttribute(_ localName: String, in element: XMLElement) -> String? {
        element.attributes?.first(where: {
            $0.localName == localName || $0.name == localName || $0.name == "w:\(localName)"
        })?.stringValue
    }

}

/// Resolves paragraph presentation through Word's style inheritance instead
/// of guessing from rendered text. The style part remains untouched on save;
/// this resolver is only used to build faithful editor metadata.
private struct DocxStyleResolver {
    private struct Style {
        let id: String
        let type: String
        let basedOn: String?
        let paragraphProperties: XMLElement?
        let runProperties: XMLElement?
    }

    private struct RunPresentation {
        let utf16Length: Int
        let properties: ResolvedRunProperties
    }

    private struct ResolvedFont {
        let font: NSFont
        let substitutedSourceFamily: String?
    }

    private struct ResolvedRunProperties {
        var fontFamily: String?
        var pointSize: CGFloat?
        var bold: Bool?
        var italic: Bool?
        var foregroundColor: NSColor?
        var underline: Bool?
        var kern: CGFloat?

        var hasFontProperties: Bool {
            fontFamily != nil || pointSize != nil || bold != nil || italic != nil
        }
    }

    struct ParagraphLayout {
        var spacingBefore: CGFloat?
        var spacingAfter: CGFloat?
        var lineSpacing: DocxLineSpacing?
    }

    private struct DocumentTheme {
        let majorLatin: String?
        let minorLatin: String?
        private let colors: [String: NSColor]
        private let colorMappings: [String: String]

        init(data: Data?, settingsData: Data?) {
            var mappings: [String: String] = [:]
            if let settingsData,
               let settings = try? XMLDocument(data: settingsData, options: [.nodePreserveAll]),
               let mapping = try? settings.nodes(
                   forXPath: "//*[local-name()='clrSchemeMapping']"
               ).first as? XMLElement {
                for attribute in mapping.attributes ?? [] {
                    if let name = attribute.localName, let value = attribute.stringValue {
                        mappings[name.lowercased()] = value.lowercased()
                    }
                }
            }
            colorMappings = mappings
            guard let data,
                  let document = try? XMLDocument(data: data, options: [.nodePreserveAll]) else {
                majorLatin = nil
                minorLatin = nil
                colors = [:]
                return
            }
            let major = try? document.nodes(
                forXPath: "//*[local-name()='fontScheme']/*[local-name()='majorFont']/*[local-name()='latin']"
            ).first as? XMLElement
            let minor = try? document.nodes(
                forXPath: "//*[local-name()='fontScheme']/*[local-name()='minorFont']/*[local-name()='latin']"
            ).first as? XMLElement
            majorLatin = major.flatMap { DocxStyleResolver.stringAttribute("typeface", in: $0) }
            minorLatin = minor.flatMap { DocxStyleResolver.stringAttribute("typeface", in: $0) }

            var parsedColors: [String: NSColor] = [:]
            let entries = ((try? document.nodes(
                forXPath: "//*[local-name()='themeElements']/*[local-name()='clrScheme']/*"
            )) ?? []).compactMap { $0 as? XMLElement }
            for entry in entries {
                guard let name = entry.localName,
                      let value = (entry.children ?? []).compactMap({ $0 as? XMLElement }).first else {
                    continue
                }
                let hex: String?
                switch value.localName {
                case "srgbClr":
                    hex = DocxStyleResolver.stringAttribute("val", in: value)
                case "sysClr":
                    hex = DocxStyleResolver.stringAttribute("lastClr", in: value)
                default:
                    hex = nil
                }
                parsedColors[name.lowercased()] = DocxStyleResolver.color(from: hex)
            }
            colors = parsedColors
        }

        func family(for reference: String?) -> String? {
            guard let reference else { return nil }
            let value = reference.lowercased()
            if value.hasPrefix("major") || value.hasPrefix("+mj") {
                return majorLatin
            }
            if value.hasPrefix("minor") || value.hasPrefix("+mn") {
                return minorLatin
            }
            return nil
        }

        func color(for reference: String) -> NSColor? {
            let name = reference.lowercased()
            let mappingKeys = [
                "background1": "bg1", "text1": "t1",
                "background2": "bg2", "text2": "t2"
            ]
            let mappedName = colorMappings[mappingKeys[name] ?? name] ?? name
            let schemeNames = [
                "dark1": "dk1", "light1": "lt1",
                "dark2": "dk2", "light2": "lt2",
                "background1": "lt1", "text1": "dk1",
                "background2": "lt2", "text2": "dk2",
                "hyperlink": "hlink", "followedhyperlink": "folhlink"
            ]
            return colors[schemeNames[mappedName] ?? mappedName]
        }
    }

    private struct DocumentFontTable {
        private struct Entry {
            let alternativeName: String?
            let familyClass: String?
        }

        private let entries: [String: Entry]

        init(data: Data?) {
            guard let data,
                  let document = try? XMLDocument(data: data, options: [.nodePreserveAll]) else {
                entries = [:]
                return
            }

            var parsed: [String: Entry] = [:]
            let fonts = ((try? document.nodes(
                forXPath: "//*[local-name()='font']"
            )) ?? []).compactMap { $0 as? XMLElement }
            for font in fonts {
                guard let name = DocxStyleResolver.stringAttribute("name", in: font) else {
                    continue
                }
                let alternative = (try? font.nodes(
                    forXPath: "./*[local-name()='altName']"
                ).first as? XMLElement).flatMap {
                    DocxStyleResolver.stringAttribute("val", in: $0)
                }
                let family = (try? font.nodes(
                    forXPath: "./*[local-name()='family']"
                ).first as? XMLElement).flatMap {
                    DocxStyleResolver.stringAttribute("val", in: $0)
                }
                parsed[name.lowercased()] = Entry(
                    alternativeName: alternative,
                    familyClass: family?.lowercased()
                )
            }
            entries = parsed
        }

        func fallbackFont(for declaredFamily: String, size: CGFloat) -> NSFont? {
            let normalized = declaredFamily.lowercased()
            let entry = entries[normalized]
            if let alternativeName = entry?.alternativeName,
               let font = NSFont(name: alternativeName, size: size) {
                return font
            }

            if normalized.contains("aptos")
                || normalized.contains("calibri")
                || normalized.contains("segoe") {
                return NSFont.systemFont(ofSize: size)
            }

            switch entry?.familyClass {
            case "swiss", "system":
                return NSFont.systemFont(ofSize: size)
            case "roman":
                return NSFont(name: "Times New Roman", size: size)
            case "modern":
                return NSFont(name: "Courier New", size: size)
            default:
                return nil
            }
        }
    }

    private let document: XMLDocument?
    private var stylesByID: [String: Style] = [:]
    private let defaultRunProperties: XMLElement?
    private let defaultParagraphProperties: XMLElement?
    private let defaultParagraphStyleID: String?
    private let theme: DocumentTheme
    private let fontTable: DocumentFontTable

    init(data: Data?, themeData: Data?, fontTableData: Data?, settingsData: Data?) throws {
        theme = DocumentTheme(data: themeData, settingsData: settingsData)
        fontTable = DocumentFontTable(data: fontTableData)
        guard let data else {
            document = nil
            defaultRunProperties = nil
            defaultParagraphProperties = nil
            defaultParagraphStyleID = nil
            return
        }

        let document = try XMLDocument(data: data, options: [.nodePreserveAll])
        self.document = document
        defaultRunProperties = try document.nodes(
            forXPath: "//*[local-name()='docDefaults']/*[local-name()='rPrDefault']/*[local-name()='rPr']"
        ).first as? XMLElement
        defaultParagraphProperties = try document.nodes(
            forXPath: "//*[local-name()='docDefaults']/*[local-name()='pPrDefault']/*[local-name()='pPr']"
        ).first as? XMLElement

        var parsed: [String: Style] = [:]
        var parsedDefaultParagraphStyleID: String?
        for node in try document.nodes(forXPath: "//*[local-name()='style']") {
            guard let element = node as? XMLElement,
                  let id = Self.stringAttribute("styleId", in: element) else {
                continue
            }
            let type = Self.stringAttribute("type", in: element) ?? "paragraph"
            let basedOnElement = try element.nodes(
                forXPath: "./*[local-name()='basedOn']"
            ).first as? XMLElement
            parsed[id] = Style(
                id: id,
                type: type,
                basedOn: basedOnElement.flatMap { Self.stringAttribute("val", in: $0) },
                paragraphProperties: try element.nodes(
                    forXPath: "./*[local-name()='pPr']"
                ).first as? XMLElement,
                runProperties: try element.nodes(
                    forXPath: "./*[local-name()='rPr']"
                ).first as? XMLElement
            )
            if type == "paragraph",
               Self.onOffAttribute("default", in: element) == true {
                parsedDefaultParagraphStyleID = id
            }
        }
        stylesByID = parsed
        defaultParagraphStyleID = parsedDefaultParagraphStyleID
    }

    func paragraphLayout(in paragraph: XMLElement) -> ParagraphLayout {
        var spacingBeforeTwips: Double?
        var spacingAfterTwips: Double?
        var lineValue: Double?
        var lineRule: String?

        let direct = (try? paragraph.nodes(
            forXPath: "./*[local-name()='pPr']"
        ).first as? XMLElement) ?? nil
        let sources = [defaultParagraphProperties]
            + paragraphStyleChain(for: paragraph).reversed().map(\.paragraphProperties)
            + [direct]

        for properties in sources.compactMap({ $0 }) {
            guard let spacing = try? properties.nodes(
                forXPath: "./*[local-name()='spacing']"
            ).last as? XMLElement else {
                continue
            }
            if let value = Self.stringAttribute("before", in: spacing).flatMap(Double.init) {
                spacingBeforeTwips = value
            }
            if let value = Self.stringAttribute("after", in: spacing).flatMap(Double.init) {
                spacingAfterTwips = value
            }
            if let value = Self.stringAttribute("line", in: spacing).flatMap(Double.init) {
                lineValue = value
            }
            if let value = Self.stringAttribute("lineRule", in: spacing) {
                lineRule = value.lowercased()
            }
        }

        let resolvedLineSpacing: DocxLineSpacing?
        if let lineValue {
            switch lineRule {
            case "exact":
                resolvedLineSpacing = .exact(CGFloat(lineValue / 20))
            case "atleast", "at-least":
                resolvedLineSpacing = .atLeast(CGFloat(lineValue / 20))
            default:
                resolvedLineSpacing = .multiple(CGFloat(lineValue / 240))
            }
        } else {
            resolvedLineSpacing = nil
        }

        return ParagraphLayout(
            spacingBefore: spacingBeforeTwips.map { CGFloat($0 / 20) },
            spacingAfter: spacingAfterTwips.map { CGFloat($0 / 20) },
            lineSpacing: resolvedLineSpacing
        )
    }

    func applyRunPresentation(
        to projection: NSMutableAttributedString,
        paragraph: XMLElement,
        in range: NSRange
    ) {
        guard range.length > 0 else { return }
        let runs = runPresentations(in: paragraph)
        guard !runs.isEmpty,
              runs.reduce(0, { $0 + $1.utf16Length }) == range.length else {
            return
        }

        var location = range.location
        for run in runs {
            let runRange = NSRange(location: location, length: run.utf16Length)
            apply(run.properties, to: projection, in: runRange)
            location += run.utf16Length
        }
    }

    private func runPresentations(in paragraph: XMLElement) -> [RunPresentation] {
        let runs = ((try? paragraph.nodes(
            forXPath: ".//*[local-name()='r']"
        )) ?? []).compactMap { $0 as? XMLElement }

        return runs.compactMap { run in
            let text = ((try? run.nodes(
                forXPath: ".//*[local-name()='t']"
            )) ?? []).compactMap(\.stringValue).joined()
            let length = text.utf16.count
            guard length > 0 else { return nil }
            return RunPresentation(
                utf16Length: length,
                properties: resolvedRunProperties(for: run, paragraph: paragraph)
            )
        }
    }

    private func resolvedRunProperties(
        for run: XMLElement,
        paragraph: XMLElement
    ) -> ResolvedRunProperties {
        var result = ResolvedRunProperties()
        merge(defaultRunProperties, into: &result)
        for style in paragraphStyleChain(for: paragraph).reversed() {
            merge(style.runProperties, into: &result, isStyleDefinition: true)
        }
        for style in characterStyleChain(for: run).reversed() {
            merge(style.runProperties, into: &result, isStyleDefinition: true)
        }
        let direct = try? run.nodes(
            forXPath: "./*[local-name()='rPr']"
        ).first as? XMLElement
        merge(direct ?? nil, into: &result)
        return result
    }

    private func merge(
        _ properties: XMLElement?,
        into result: inout ResolvedRunProperties,
        isStyleDefinition: Bool = false
    ) {
        guard let properties else { return }

        if let fonts = try? properties.nodes(
            forXPath: "./*[local-name()='rFonts']"
        ).last as? XMLElement {
            let explicitFamily = Self.stringAttribute("ascii", in: fonts)
                ?? Self.stringAttribute("hAnsi", in: fonts)
                ?? Self.stringAttribute("cs", in: fonts)
            let themeReference = Self.stringAttribute("asciiTheme", in: fonts)
                ?? Self.stringAttribute("hAnsiTheme", in: fonts)
                ?? Self.stringAttribute("cstheme", in: fonts)
            if let family = explicitFamily.flatMap(resolvedExplicitFontFamily)
                ?? theme.family(for: themeReference) {
                result.fontFamily = family
            }
        }
        if let size = try? properties.nodes(
            forXPath: "./*[local-name()='sz']"
        ).last as? XMLElement,
           let halfPoints = Self.stringAttribute("val", in: size).flatMap(Double.init),
           halfPoints > 0 {
            result.pointSize = CGFloat(halfPoints / 2)
        }
        if let bold = try? properties.nodes(
            forXPath: "./*[local-name()='b']"
        ).last as? XMLElement {
            result.bold = Self.toggleValue(
                of: bold,
                inherited: result.bold,
                isStyleDefinition: isStyleDefinition
            )
        }
        if let italic = try? properties.nodes(
            forXPath: "./*[local-name()='i']"
        ).last as? XMLElement {
            result.italic = Self.toggleValue(
                of: italic,
                inherited: result.italic,
                isStyleDefinition: isStyleDefinition
            )
        }
        if let color = try? properties.nodes(
            forXPath: "./*[local-name()='color']"
        ).last as? XMLElement {
            // An unresolved direct color must not keep a lower-priority
            // inherited color and overwrite the importer's presentation.
            result.foregroundColor = resolvedRunColor(in: color)
        }
        if let underline = try? properties.nodes(
            forXPath: "./*[local-name()='u']"
        ).last as? XMLElement {
            result.underline = Self.isActiveUnderline(underline)
        }
        if let spacing = try? properties.nodes(
            forXPath: "./*[local-name()='spacing']"
        ).last as? XMLElement,
           let twips = Self.stringAttribute("val", in: spacing).flatMap(Double.init) {
            result.kern = CGFloat(twips / 20)
        }
    }

    private func resolvedRunColor(in element: XMLElement) -> NSColor? {
        guard let reference = Self.stringAttribute("themeColor", in: element),
              let base = theme.color(for: reference)?.usingColorSpace(.sRGB) else {
            return Self.color(from: Self.stringAttribute("val", in: element))
        }

        func fraction(for attribute: String) -> CGFloat? {
            guard let hex = Self.stringAttribute(attribute, in: element),
                  hex.count == 2,
                  let value = UInt8(hex, radix: 16) else { return nil }
            return CGFloat(value) / 255
        }

        let tint = fraction(for: "themeTint")
        let shade = fraction(for: "themeShade")
        guard tint != nil || shade != nil else { return base }

        // Word changes HSL luminance, with tint taking precedence over shade.
        let red = base.redComponent
        let green = base.greenComponent
        let blue = base.blueComponent
        let minimum = min(red, green, blue)
        let maximum = max(red, green, blue)
        let luminance = (minimum + maximum) / 2
        let adjustedLuminance: CGFloat
        if let tint {
            adjustedLuminance = 1 - (1 - luminance) * tint
        } else {
            adjustedLuminance = luminance * (shade ?? 1)
        }

        let chroma = maximum - minimum
        let saturation = chroma == 0 ? 0 : chroma / (1 - abs(2 * luminance - 1))
        let adjustedChroma = (1 - abs(2 * adjustedLuminance - 1)) * saturation
        let scale = chroma == 0 ? 0 : adjustedChroma / chroma
        func adjusted(_ component: CGFloat) -> CGFloat {
            min(1, max(0, adjustedLuminance + (component - luminance) * scale))
        }
        return NSColor(
            srgbRed: adjusted(red),
            green: adjusted(green),
            blue: adjusted(blue),
            alpha: base.alphaComponent
        )
    }

    private func apply(
        _ properties: ResolvedRunProperties,
        to projection: NSMutableAttributedString,
        in range: NSRange
    ) {
        guard range.length > 0 else { return }

        if properties.hasFontProperties {
            let existingFont = projection.attribute(
                .font,
                at: range.location,
                effectiveRange: nil
            ) as? NSFont
            if let resolvedFont = resolvedFont(from: properties, fallback: existingFont) {
                projection.addAttribute(.font, value: resolvedFont.font, range: range)
                if let sourceFamily = resolvedFont.substitutedSourceFamily {
                    let substituteFamily = resolvedFont.font.familyName
                        ?? resolvedFont.font.fontName
                    projection.addAttribute(
                        DocxEditorAttribute.sourceFontFamily,
                        value: sourceFamily,
                        range: range
                    )
                    projection.addAttribute(
                        DocxEditorAttribute.substituteFontFamily,
                        value: substituteFamily,
                        range: range
                    )
                } else {
                    projection.removeAttribute(
                        DocxEditorAttribute.sourceFontFamily,
                        range: range
                    )
                    projection.removeAttribute(
                        DocxEditorAttribute.substituteFontFamily,
                        range: range
                    )
                }
            }
        }
        if let color = properties.foregroundColor {
            projection.addAttribute(.foregroundColor, value: color, range: range)
        }
        if let underline = properties.underline {
            if underline {
                projection.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            } else {
                projection.removeAttribute(.underlineStyle, range: range)
                projection.removeAttribute(.underlineColor, range: range)
            }
        }
        if let kern = properties.kern {
            if abs(kern) < 0.001 {
                projection.removeAttribute(.kern, range: range)
            } else {
                projection.addAttribute(.kern, value: kern, range: range)
            }
        }
    }

    private func resolvedFont(
        from properties: ResolvedRunProperties,
        fallback: NSFont?
    ) -> ResolvedFont? {
        let size = properties.pointSize ?? fallback?.pointSize ?? NSFont.systemFontSize
        let baseFont: NSFont
        let substitutedSourceFamily: String?
        if let family = properties.fontFamily,
           let namedFont = NSFont(name: family, size: size) {
            baseFont = namedFont
            substitutedSourceFamily = nil
        } else if let family = properties.fontFamily,
                  let substitute = fontTable.fallbackFont(for: family, size: size) {
            baseFont = substitute
            substitutedSourceFamily = family
        } else if let fallback {
            baseFont = NSFontManager.shared.convert(fallback, toSize: size)
            substitutedSourceFamily = nil
        } else {
            baseFont = NSFont.systemFont(ofSize: size)
            substitutedSourceFamily = nil
        }

        let manager = NSFontManager.shared
        var font = manager.convert(
            baseFont,
            toNotHaveTrait: [.boldFontMask, .italicFontMask]
        )
        if properties.bold == true {
            font = manager.convert(font, toHaveTrait: .boldFontMask)
        }
        if properties.italic == true {
            font = manager.convert(font, toHaveTrait: .italicFontMask)
        }
        return ResolvedFont(
            font: font,
            substitutedSourceFamily: substitutedSourceFamily
        )
    }

    private func resolvedExplicitFontFamily(_ family: String) -> String? {
        if family.hasPrefix("+mj") {
            return theme.majorLatin
        }
        if family.hasPrefix("+mn") {
            return theme.minorLatin
        }
        return family.isEmpty ? nil : family
    }

    func listReference(in paragraph: XMLElement) -> (numID: Int, level: Int)? {
        var numberID: Int?
        var level: Int?
        for properties in paragraphPropertySources(for: paragraph) {
            if level == nil,
               let element = try? properties.nodes(
                   forXPath: "./*[local-name()='numPr']/*[local-name()='ilvl']"
               ).first as? XMLElement {
                level = Self.integerAttribute("val", in: element)
            }
            if numberID == nil,
               let element = try? properties.nodes(
                   forXPath: "./*[local-name()='numPr']/*[local-name()='numId']"
               ).first as? XMLElement {
                numberID = Self.integerAttribute("val", in: element)
            }
        }
        guard let numberID, numberID != 0 else { return nil }
        return (numberID, level ?? 0)
    }

    func sectionRuleColor(in paragraph: XMLElement) -> NSColor? {
        for properties in paragraphPropertySources(for: paragraph) {
            guard let border = try? properties.nodes(
                forXPath: "./*[local-name()='pBdr']/*[local-name()='bottom']"
            ).first as? XMLElement else {
                continue
            }
            let value = Self.stringAttribute("val", in: border)?.lowercased()
            guard value != "nil", value != "none", value != "0" else { return nil }
            return Self.color(from: Self.stringAttribute("color", in: border))
                ?? NSColor(calibratedWhite: 0.25, alpha: 1)
        }
        return nil
    }

    func hasExplicitUnderline(in paragraph: XMLElement) -> Bool {
        let directUnderlines = ((try? paragraph.nodes(
            forXPath: "./*[local-name()='r']/*[local-name()='rPr']/*[local-name()='u']"
        )) ?? []).compactMap { $0 as? XMLElement }
        for underline in directUnderlines {
            if Self.isActiveUnderline(underline) {
                return true
            }
        }

        for style in paragraphStyleChain(for: paragraph) {
            if Self.containsActiveUnderline(style.runProperties) {
                return true
            }
        }

        let runStyleElements = ((try? paragraph.nodes(
            forXPath: "./*[local-name()='r']/*[local-name()='rPr']/*[local-name()='rStyle']"
        )) ?? []).compactMap { $0 as? XMLElement }
        for element in runStyleElements {
            guard let styleID = Self.stringAttribute("val", in: element) else { continue }
            for style in styleChain(startingAt: styleID, requiredType: "character") {
                if Self.containsActiveUnderline(style.runProperties) {
                    return true
                }
            }
        }

        return Self.containsActiveUnderline(defaultRunProperties)
    }

    private func paragraphPropertySources(for paragraph: XMLElement) -> [XMLElement] {
        let direct = (try? paragraph.nodes(
            forXPath: "./*[local-name()='pPr']"
        ).first as? XMLElement) ?? nil
        return [direct].compactMap { $0 }
            + paragraphStyleChain(for: paragraph).compactMap(\.paragraphProperties)
    }

    private func paragraphStyleChain(for paragraph: XMLElement) -> [Style] {
        let explicitStyleElement = try? paragraph.nodes(
            forXPath: "./*[local-name()='pPr']/*[local-name()='pStyle']"
        ).first as? XMLElement
        let styleID = (explicitStyleElement ?? nil).flatMap {
            Self.stringAttribute("val", in: $0)
        } ?? defaultParagraphStyleID
        guard let styleID else { return [] }
        return styleChain(startingAt: styleID, requiredType: "paragraph")
    }

    private func characterStyleChain(for run: XMLElement) -> [Style] {
        guard let styleElement = try? run.nodes(
            forXPath: "./*[local-name()='rPr']/*[local-name()='rStyle']"
        ).first as? XMLElement,
              let styleID = Self.stringAttribute("val", in: styleElement) else {
            return []
        }
        return styleChain(startingAt: styleID, requiredType: "character")
    }

    private func styleChain(startingAt styleID: String, requiredType: String) -> [Style] {
        var result: [Style] = []
        var nextID: String? = styleID
        var visited = Set<String>()
        while let currentID = nextID,
              visited.insert(currentID).inserted,
              let style = stylesByID[currentID] {
            if style.type == requiredType {
                result.append(style)
            }
            nextID = style.basedOn
        }
        return result
    }

    private static func containsActiveUnderline(_ properties: XMLElement?) -> Bool {
        guard let properties else { return false }
        let underlines = ((try? properties.nodes(
            forXPath: "./*[local-name()='u']"
        )) ?? []).compactMap { $0 as? XMLElement }
        for underline in underlines {
            if isActiveUnderline(underline) {
                return true
            }
        }
        return false
    }

    private static func isActiveUnderline(_ underline: XMLElement) -> Bool {
        let value = stringAttribute("val", in: underline)?.lowercased()
        return value == nil || (value != "none" && value != "nil" && value != "0")
    }

    private static func toggleValue(
        of element: XMLElement,
        inherited: Bool?,
        isStyleDefinition: Bool
    ) -> Bool? {
        let enabled = onOffValue(of: element)
        guard isStyleDefinition else { return enabled }
        // Within a style, true flips the inherited state and false leaves it
        // alone. Direct run formatting instead sets an absolute value.
        return enabled ? !(inherited ?? false) : inherited
    }

    private static func onOffValue(of element: XMLElement) -> Bool {
        let value = stringAttribute("val", in: element)?.lowercased()
        return value == nil || !["0", "false", "off", "none"].contains(value!)
    }

    private static func onOffAttribute(_ localName: String, in element: XMLElement) -> Bool? {
        guard let value = stringAttribute(localName, in: element)?.lowercased() else {
            return nil
        }
        return !["0", "false", "off", "none"].contains(value)
    }

    private static func integerAttribute(_ localName: String, in element: XMLElement) -> Int? {
        stringAttribute(localName, in: element).flatMap(Int.init)
    }

    private static func stringAttribute(_ localName: String, in element: XMLElement) -> String? {
        element.attributes?.first(where: {
            $0.localName == localName || $0.name == localName || $0.name == "w:\(localName)"
        })?.stringValue
    }

    private static func color(from value: String?) -> NSColor? {
        guard let value,
              value.lowercased() != "auto",
              value.count == 6,
              let rgb = Int(value, radix: 16) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

private struct DocxNumberingResolver {
    struct Level {
        let format: String
        let text: String
        let start: Int
        let leftTwips: Int
        let hangingTwips: Int
    }

    private var abstractForNumber: [Int: Int] = [:]
    private var levels: [Int: [Int: Level]] = [:]

    init(data: Data?) throws {
        guard let data else { return }
        let document = try XMLDocument(data: data, options: [.nodePreserveAll])

        for node in try document.nodes(forXPath: "//*[local-name()='num']") {
            guard let number = node as? XMLElement,
                  let numberID = Self.integerAttribute("numId", in: number),
                  let abstractElement = try number.nodes(
                    forXPath: "./*[local-name()='abstractNumId']"
                  ).first as? XMLElement,
                  let abstractID = Self.integerAttribute("val", in: abstractElement) else {
                continue
            }
            abstractForNumber[numberID] = abstractID
        }

        for node in try document.nodes(forXPath: "//*[local-name()='abstractNum']") {
            guard let abstract = node as? XMLElement,
                  let abstractID = Self.integerAttribute("abstractNumId", in: abstract) else {
                continue
            }
            var parsedLevels: [Int: Level] = [:]
            for levelNode in try abstract.nodes(forXPath: "./*[local-name()='lvl']") {
                guard let level = levelNode as? XMLElement,
                      let levelIndex = Self.integerAttribute("ilvl", in: level) else {
                    continue
                }
                let formatElement = try level.nodes(forXPath: "./*[local-name()='numFmt']").first as? XMLElement
                let textElement = try level.nodes(forXPath: "./*[local-name()='lvlText']").first as? XMLElement
                let startElement = try level.nodes(forXPath: "./*[local-name()='start']").first as? XMLElement
                let indentElement = try level.nodes(
                    forXPath: "./*[local-name()='pPr']/*[local-name()='ind']"
                ).first as? XMLElement
                parsedLevels[levelIndex] = Level(
                    format: formatElement.flatMap { Self.stringAttribute("val", in: $0) } ?? "bullet",
                    text: textElement.flatMap { Self.stringAttribute("val", in: $0) } ?? "•",
                    start: startElement.flatMap { Self.integerAttribute("val", in: $0) } ?? 1,
                    leftTwips: indentElement.flatMap { Self.integerAttribute("left", in: $0) } ?? ((levelIndex + 1) * 720),
                    hangingTwips: indentElement.flatMap { Self.integerAttribute("hanging", in: $0) } ?? 360
                )
            }
            levels[abstractID] = parsedLevels
        }
    }

    func level(numID: Int, level: Int) -> Level? {
        guard let abstractID = abstractForNumber[numID] else { return nil }
        return levels[abstractID]?[level]
    }

    var firstBulletNumberID: Int? {
        abstractForNumber.keys.sorted().first { numberID in
            guard let abstractID = abstractForNumber[numberID],
                  let level = levels[abstractID]?[0] else {
                return false
            }
            return level.format == "bullet"
        }
    }

    func marker(for definition: Level, level: Int, counters: [Int: Int]) -> String {
        guard definition.format != "bullet" else { return definition.text }
        var marker = definition.text
        for referencedLevel in 0...max(level, 0) {
            marker = marker.replacingOccurrences(
                of: "%\(referencedLevel + 1)",
                with: formatted(counters[referencedLevel] ?? 1, as: definition.format)
            )
        }
        return marker
    }

    private func formatted(_ number: Int, as format: String) -> String {
        switch format {
        case "upperLetter":
            return alphabetic(number).uppercased()
        case "lowerLetter":
            return alphabetic(number).lowercased()
        case "upperRoman":
            return roman(number).uppercased()
        case "lowerRoman":
            return roman(number).lowercased()
        default:
            return String(number)
        }
    }

    private func alphabetic(_ number: Int) -> String {
        var value = max(number, 1)
        var result = ""
        while value > 0 {
            value -= 1
            result.insert(Character(UnicodeScalar(65 + value % 26)!), at: result.startIndex)
            value /= 26
        }
        return result
    }

    private func roman(_ number: Int) -> String {
        var value = max(number, 1)
        let numerals = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var result = ""
        for (amount, numeral) in numerals {
            while value >= amount {
                result += numeral
                value -= amount
            }
        }
        return result
    }

    private static func integerAttribute(_ localName: String, in element: XMLElement) -> Int? {
        stringAttribute(localName, in: element).flatMap(Int.init)
    }

    private static func stringAttribute(_ localName: String, in element: XMLElement) -> String? {
        element.attributes?.first(where: {
            $0.localName == localName || $0.name == localName || $0.name == "w:\(localName)"
        })?.stringValue
    }
}
