//
//  DocxDocumentSession.swift
//  FreeDocx
//

import AppKit
import Foundation

/// Reference-owned document state. Model changes are applied transactionally:
/// a failed editor reconciliation never mutates the last valid OOXML graph.
final class DocxDocumentSession {
    private var package: DocxPackage
    private var model: DocxDocumentModel
    private(set) var attributedText: NSAttributedString
    private(set) var pageLayout: DocumentPageLayout
    private(set) var pendingError: Error?
    private enum ModelEdit {
        case paragraphs([DocxParagraph])
        case document(DocxDocumentModel)
    }
    private struct PreparedEdit {
        let proposed: NSAttributedString
        let normalized: NSAttributedString
        let change: ModelEdit
    }
    private var preparedEdit: PreparedEdit?
    private var affectedRange: NSRange?

    init(data: Data) throws {
        let package = try DocxPackage(data: data)
        let model = try DocxDocumentModel(package: package)

        var documentAttributes: NSDictionary?
        let importedText = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: &documentAttributes
        )
        let fallbackLayout = DocumentPageLayout(documentAttributes: documentAttributes)

        self.package = package
        self.model = model
        attributedText = try DocxEditorProjection.initial(
            importedText: importedText,
            model: model
        )
        pageLayout = model.pageLayout(fallback: fallbackLayout)
    }

    convenience init() throws {
        try self.init(data: Self.blankDocumentData())
    }

    /// Validate native replacements before TextKit changes its text or undo history.
    func validateEditorChanges(
        in editorText: NSAttributedString,
        ranges: [NSRange],
        replacementStrings: [String]?
    ) throws {
        preparedEdit = nil
        affectedRange = nil
        guard ranges.allSatisfy({
            $0.location >= 0 && $0.length >= 0 && $0.location <= editorText.length
                && $0.length <= editorText.length - $0.location
        }) else {
            throw DocxModelError.unknownParagraphID
        }
        let range = ranges.first.map { first in ranges.dropFirst().reduce(first, NSUnionRange) }
        if let replacementStrings {
            guard ranges.count == replacementStrings.count else {
                throw DocxModelError.unknownParagraphID
            }
            let proposed = NSMutableAttributedString(attributedString: editorText)
            for (range, replacement) in zip(ranges, replacementStrings).reversed() {
                proposed.replaceCharacters(in: range, with: replacement)
            }
            preparedEdit = try prepare(proposed, range: range)
        } else {
            // The replacement attributes are not available until TextKit applies
            // them. Protect paragraphs whose runs cannot be rewritten safely.
            for range in ranges where editorText.length > 0 {
                let affectedRange = NSRange(
                    location: min(range.location, editorText.length - 1),
                    length: max(range.length, 1)
                )
                var validationError: Error?
                editorText.enumerateAttribute(
                    DocxEditorAttribute.paragraphID,
                    in: affectedRange
                ) { value, _, stop in
                    guard let value = value as? String,
                          let id = UUID(uuidString: value),
                          let paragraph = model.paragraph(with: id) else {
                        validationError = DocxModelError.unknownParagraphID
                        stop.pointee = true
                        return
                    }
                    do {
                        try model.validateRunEditing(of: paragraph)
                    } catch {
                        validationError = error
                        stop.pointee = true
                    }
                }
                if let validationError { throw validationError }
            }
        }
        affectedRange = range
    }

    private func prepare(_ text: NSAttributedString, range: NSRange?) throws -> PreparedEdit {
        let snapshot = text.copy() as! NSAttributedString
        if let local = try DocxEditorProjection.prepareParagraphEdits(
            editorText: snapshot, previousText: attributedText, affectedRange: range, model: model
        ) {
            return PreparedEdit(proposed: snapshot, normalized: local.text, change: .paragraphs(local.paragraphs))
        }
        let candidate = try model.transactionalCopy()
        let normalized = try DocxEditorProjection.reconcile(
            editorText: snapshot, previousText: attributedText, model: candidate
        )
        return PreparedEdit(proposed: snapshot, normalized: normalized, change: .document(candidate))
    }

    @discardableResult
    func acceptEditorText(_ editorText: NSAttributedString) -> Bool {
        defer {
            preparedEdit = nil
            affectedRange = nil
        }
        do {
            let edit: PreparedEdit
            if let preparedEdit, preparedEdit.proposed.isEqual(to: editorText) {
                edit = preparedEdit
            } else {
                edit = try prepare(editorText, range: affectedRange)
            }
            switch edit.change {
            case let .paragraphs(replacements):
                try model.commitParagraphs(replacements)
            case let .document(candidate):
                model = candidate
            }
            attributedText = edit.normalized
            pendingError = nil
            return true
        } catch {
            // Keep both the model and its projection at the last valid edit.
            // A rejected edit must never prevent saving earlier accepted work.
            pendingError = error
            return false
        }
    }

    func serializedData() throws -> Data {
        var outputPackage = package
        if model.isDirty {
            try outputPackage.replacePart(
                named: "word/document.xml",
                with: model.documentXMLData()
            )
        }
        if let numberingData = model.dirtyNumberingXMLData {
            if outputPackage.containsPart(named: "word/numbering.xml") {
                try outputPackage.replacePart(
                    named: "word/numbering.xml",
                    with: numberingData
                )
            } else {
                try outputPackage.addPart(
                    named: "word/numbering.xml",
                    data: numberingData
                )
                try Self.addNumberingContentType(to: &outputPackage)
                try Self.addNumberingRelationship(to: &outputPackage)
            }
        }
        return try outputPackage.serializedData()
    }

    private static func addNumberingContentType(
        to package: inout DocxPackage
    ) throws {
        let path = "[Content_Types].xml"
        let data = try package.part(named: path)
        let document = try XMLDocument(data: data, options: [.nodePreserveAll])
        let existing = try document.nodes(
            forXPath: "//*[local-name()='Override' and @PartName='/word/numbering.xml']"
        )
        guard existing.isEmpty, let root = document.rootElement() else { return }

        let override = XMLElement(name: "Override")
        override.addAttribute(
            XMLNode.attribute(
                withName: "PartName",
                stringValue: "/word/numbering.xml"
            ) as! XMLNode
        )
        override.addAttribute(
            XMLNode.attribute(
                withName: "ContentType",
                stringValue: "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"
            ) as! XMLNode
        )
        root.addChild(override)
        try package.replacePart(
            named: path,
            with: document.xmlData(options: [.nodePreserveAll])
        )
    }

    private static func addNumberingRelationship(
        to package: inout DocxPackage
    ) throws {
        let path = "word/_rels/document.xml.rels"
        let document: XMLDocument
        let root: XMLElement
        if package.containsPart(named: path) {
            document = try XMLDocument(
                data: package.part(named: path),
                options: [.nodePreserveAll]
            )
            guard let existingRoot = document.rootElement() else {
                throw DocxPackageError.missingPart(path)
            }
            root = existingRoot
        } else {
            root = XMLElement(name: "Relationships")
            root.addNamespace(
                XMLNode.namespace(
                    withName: "",
                    stringValue: "http://schemas.openxmlformats.org/package/2006/relationships"
                ) as! XMLNode
            )
            document = XMLDocument(rootElement: root)
            document.version = "1.0"
            document.characterEncoding = "UTF-8"
        }

        let numberingType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
        let relationships = try root.nodes(
            forXPath: "./*[local-name()='Relationship']"
        ).compactMap { $0 as? XMLElement }
        if relationships.contains(where: {
            Self.attribute("Type", in: $0) == numberingType
        }) {
            return
        }
        let usedIDs = Set(relationships.compactMap { Self.attribute("Id", in: $0) })
        var index = 1
        while usedIDs.contains("rId\(index)") { index += 1 }

        let relationship = XMLElement(name: "Relationship")
        relationship.addAttribute(
            XMLNode.attribute(withName: "Id", stringValue: "rId\(index)") as! XMLNode
        )
        relationship.addAttribute(
            XMLNode.attribute(withName: "Type", stringValue: numberingType) as! XMLNode
        )
        relationship.addAttribute(
            XMLNode.attribute(withName: "Target", stringValue: "numbering.xml") as! XMLNode
        )
        root.addChild(relationship)
        let updatedData = document.xmlData(options: [.nodePreserveAll])
        if package.containsPart(named: path) {
            try package.replacePart(named: path, with: updatedData)
        } else {
            try package.addPart(named: path, data: updatedData)
        }
    }

    private static func attribute(_ name: String, in element: XMLElement) -> String? {
        element.attributes?.first(where: {
            $0.localName == name || $0.name == name
        })?.stringValue
    }

    private static func blankDocumentData() throws -> Data {
        let text = NSAttributedString(
            string: "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.black
            ]
        )
        var attributes = DocumentPageLayout.letter.documentAttributes
        attributes[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        return try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: attributes
        )
    }
}
