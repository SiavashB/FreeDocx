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
}

struct DocxParagraphPresentation {
    let listMarker: String?
    let markerIndent: CGFloat?
    let textIndent: CGFloat?
    let sectionRuleColor: NSColor?
    let hasExplicitUnderline: Bool
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
    private(set) var isDirty = false

    convenience init(package: DocxPackage) throws {
        let documentData = try package.part(named: "word/document.xml")
        let numberingData = try? package.part(named: "word/numbering.xml")
        let stylesData = try? package.part(named: "word/styles.xml")
        try self.init(
            documentData: documentData,
            numberingData: numberingData,
            stylesData: stylesData,
            paragraphIDs: nil
        )
    }

    private init(
        documentData: Data,
        numberingData: Data?,
        stylesData: Data?,
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
        styles = try DocxStyleResolver(data: stylesData)
    }

    func transactionalCopy() throws -> DocxDocumentModel {
        let copy = try DocxDocumentModel(
            documentData: documentXMLData(),
            numberingData: numberingData,
            stylesData: stylesData,
            paragraphIDs: paragraphs.map(\.id)
        )
        copy.isDirty = isDirty
        copy.isNumberingDirty = isNumberingDirty
        return copy
    }

    func paragraph(with id: UUID) -> DocxParagraph? {
        paragraphs.first(where: { $0.id == id })
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

            result[paragraph.id] = DocxParagraphPresentation(
                listMarker: listPresentation?.marker,
                markerIndent: listPresentation?.markerIndent,
                textIndent: listPresentation?.textIndent,
                sectionRuleColor: styles.sectionRuleColor(in: paragraph.element),
                hasExplicitUnderline: styles.hasExplicitUnderline(in: paragraph.element)
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
            let family = font.familyName ?? font.fontName
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
            if traits.contains(.boldFontMask) {
                properties.addChild(XMLElement(name: "w:b"))
            }
            if traits.contains(.italicFontMask) {
                properties.addChild(XMLElement(name: "w:i"))
            }
        }

        let underlineValue = (attributes[.underlineStyle] as? NSNumber)?.intValue
            ?? (attributes[.underlineStyle] as? Int)
            ?? 0
        if underlineValue != 0 {
            let underline = XMLElement(name: "w:u")
            underline.addAttribute(
                XMLNode.attribute(withName: "w:val", stringValue: "single") as! XMLNode
            )
            properties.addChild(underline)
        }

        if let color = attributes[.foregroundColor] as? NSColor,
           let rgb = color.usingColorSpace(.deviceRGB) {
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

    private let document: XMLDocument?
    private var stylesByID: [String: Style] = [:]
    private let defaultRunProperties: XMLElement?

    init(data: Data?) throws {
        guard let data else {
            document = nil
            defaultRunProperties = nil
            return
        }

        let document = try XMLDocument(data: data, options: [.nodePreserveAll])
        self.document = document
        defaultRunProperties = try document.nodes(
            forXPath: "//*[local-name()='docDefaults']/*[local-name()='rPrDefault']/*[local-name()='rPr']"
        ).first as? XMLElement

        var parsed: [String: Style] = [:]
        for node in try document.nodes(forXPath: "//*[local-name()='style']") {
            guard let element = node as? XMLElement,
                  let id = Self.stringAttribute("styleId", in: element) else {
                continue
            }
            let basedOnElement = try element.nodes(
                forXPath: "./*[local-name()='basedOn']"
            ).first as? XMLElement
            parsed[id] = Style(
                id: id,
                type: Self.stringAttribute("type", in: element) ?? "paragraph",
                basedOn: basedOnElement.flatMap { Self.stringAttribute("val", in: $0) },
                paragraphProperties: try element.nodes(
                    forXPath: "./*[local-name()='pPr']"
                ).first as? XMLElement,
                runProperties: try element.nodes(
                    forXPath: "./*[local-name()='rPr']"
                ).first as? XMLElement
            )
        }
        stylesByID = parsed
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
        guard let styleElement = try? paragraph.nodes(
            forXPath: "./*[local-name()='pPr']/*[local-name()='pStyle']"
        ).first as? XMLElement,
              let styleID = Self.stringAttribute("val", in: styleElement) else {
            return []
        }
        return styleChain(startingAt: styleID, requiredType: "paragraph")
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
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
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
