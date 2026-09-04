//
//  DocxDocumentSession.swift
//  FreeDocx
//

import AppKit
import Foundation

enum DocxDocumentSessionError: LocalizedError {
    case pendingEdit(Error)

    var errorDescription: String? {
        switch self {
        case let .pendingEdit(error):
            return "This edit could not be represented safely in the Word document: \(error.localizedDescription)"
        }
    }
}

/// Reference-owned document state. Model changes are applied transactionally:
/// a failed editor reconciliation never mutates the last valid OOXML graph.
final class DocxDocumentSession {
    private var package: DocxPackage
    private var model: DocxDocumentModel
    private(set) var attributedText: NSAttributedString
    private(set) var pageLayout: DocumentPageLayout
    private(set) var pendingError: Error?

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

    func acceptEditorText(_ editorText: NSAttributedString) {
        do {
            let candidate = try model.transactionalCopy()
            let normalized = try DocxEditorProjection.reconcile(
                editorText: editorText,
                previousText: attributedText,
                model: candidate
            )
            model = candidate
            attributedText = normalized
            pendingError = nil
        } catch {
            attributedText = editorText
            pendingError = error
        }
    }

    func serializedData() throws -> Data {
        if let pendingError {
            throw DocxDocumentSessionError.pendingEdit(pendingError)
        }
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
