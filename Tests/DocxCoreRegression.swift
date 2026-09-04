import AppKit
import Foundation
import ZIPFoundation

@main
struct DocxCoreRegression {
    static func main() throws {
        if CommandLine.arguments.count == 4,
           CommandLine.arguments[1] == "--compare" {
            try compareSavedFile(
                baselinePath: CommandLine.arguments[2],
                savedPath: CommandLine.arguments[3]
            )
            return
        }

        let original = try makeFixture()
        let originalPackage = try DocxPackage(data: original)
        let session = try DocxDocumentSession(data: original)

        try require(try session.serializedData() == original, "No-op save must be byte-identical")
        let titleRange = (session.attributedText.string as NSString).range(
            of: "Real Word-style list"
        )
        try require(titleRange.location != NSNotFound, "Fixture is missing its styled heading")
        try require(
            session.attributedText.attribute(
                DocxEditorAttribute.sectionRule,
                at: titleRange.location,
                effectiveRange: nil
            ) is NSColor,
            "Inherited section rule was not projected"
        )
        let styledListRange = (session.attributedText.string as NSString).range(
            of: "Style-inherited list item"
        )
        try require(styledListRange.location != NSNotFound, "Fixture is missing its styled list")
        try require(
            session.attributedText.attribute(
                DocxEditorAttribute.listMarker,
                at: styledListRange.location,
                effectiveRange: nil
            ) as? String == "•",
            "Inherited list definition was not projected"
        )

        let trailingSession = try DocxDocumentSession(data: original)
        var trailingEditor = NSMutableAttributedString(
            attributedString: trailingSession.attributedText
        )
        if trailingEditor.string.unicodeScalars.last.map(CharacterSet.newlines.contains) == true {
            trailingEditor.deleteCharacters(
                in: NSRange(location: trailingEditor.length - 1, length: 1)
            )
            trailingSession.acceptEditorText(trailingEditor)
            try require(
                trailingSession.pendingError == nil,
                "Removing the importer's terminal newline failed"
            )
            trailingEditor = NSMutableAttributedString(
                attributedString: trailingSession.attributedText
            )
        }
        let finalAttributes = trailingEditor.attributes(
            at: trailingEditor.length - 1,
            effectiveRange: nil
        )
        trailingEditor.append(
            NSAttributedString(string: "\n", attributes: finalAttributes)
        )
        trailingSession.acceptEditorText(trailingEditor)
        try require(
            trailingSession.pendingError == nil,
            "Trailing empty list paragraph reconciliation failed"
        )
        try require(
            trailingSession.attributedText.attribute(
                DocxEditorAttribute.listMarker,
                at: trailingSession.attributedText.length - 1,
                effectiveRange: nil
            ) as? String == "•",
            "Trailing empty list paragraph lost its visible marker"
        )
        let trailingText = trailingSession.attributedText
        let trailingNSString = trailingText.string as NSString
        var finalParagraphStart = 0
        var finalParagraphEnd = 0
        var finalContentsEnd = 0
        trailingNSString.getParagraphStart(
            &finalParagraphStart,
            end: &finalParagraphEnd,
            contentsEnd: &finalContentsEnd,
            for: NSRange(location: trailingText.length - 1, length: 0)
        )
        let populatedID = trailingText.attribute(
            DocxEditorAttribute.paragraphID,
            at: finalParagraphStart,
            effectiveRange: nil
        ) as? String
        let emptyID = trailingText.attribute(
            DocxEditorAttribute.paragraphID,
            at: trailingText.length - 1,
            effectiveRange: nil
        ) as? String
        try require(
            emptyID != nil && emptyID != populatedID,
            "Trailing empty paragraph lacks an independently drawable identity"
        )
        let trailingSaved = try trailingSession.serializedData()
        let trailingPackage = try DocxPackage(data: trailingSaved)
        let trailingXML = try XMLDocument(
            data: trailingPackage.part(named: "word/document.xml"),
            options: [.nodePreserveAll]
        )
        try require(
            try trailingXML.nodes(forXPath: "//*[local-name()='p']").count == 6,
            "Trailing empty list paragraph was not added to OOXML"
        )
        let trailingReopened = try DocxDocumentSession(data: trailingSaved)
        try require(
            try trailingReopened.serializedData() == trailingSaved,
            "Trailing empty paragraph did not survive reopening"
        )

        let toggleSession = try DocxDocumentSession(data: original)
        let toggledEditor = NSMutableAttributedString(
            attributedString: toggleSession.attributedText
        )
        let headingToggleRange = (toggledEditor.string as NSString).paragraphRange(
            for: (toggledEditor.string as NSString).range(of: "Real Word-style list")
        )
        toggledEditor.addAttribute(
            DocxEditorAttribute.listMarker,
            value: "•",
            range: headingToggleRange
        )
        let firstToggleRange = (toggledEditor.string as NSString).paragraphRange(
            for: (toggledEditor.string as NSString).range(of: "First item")
        )
        toggledEditor.removeAttribute(
            DocxEditorAttribute.listMarker,
            range: firstToggleRange
        )
        toggledEditor.removeAttribute(
            DocxEditorAttribute.listMarkerIndent,
            range: firstToggleRange
        )
        let unlistedStyle = (
            toggledEditor.attribute(
                .paragraphStyle,
                at: firstToggleRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle ?? NSParagraphStyle.default
        ).mutableCopy() as! NSMutableParagraphStyle
        unlistedStyle.textLists = []
        unlistedStyle.firstLineHeadIndent = 0
        unlistedStyle.headIndent = 0
        toggledEditor.addAttribute(
            .paragraphStyle,
            value: unlistedStyle,
            range: firstToggleRange
        )
        toggleSession.acceptEditorText(toggledEditor)
        try require(toggleSession.pendingError == nil, "List toggle reconciliation failed")
        let toggledData = try toggleSession.serializedData()
        let toggledPackage = try DocxPackage(data: toggledData)
        try require(
            try toggledPackage.part(named: "word/numbering.xml")
                == originalPackage.part(named: "word/numbering.xml"),
            "Using an existing bullet definition changed numbering.xml"
        )
        let toggledXML = try XMLDocument(
            data: toggledPackage.part(named: "word/document.xml"),
            options: [.nodePreserveAll]
        )
        let toggledHeading = try paragraph(
            containing: "Real Word-style list",
            in: toggledXML
        )
        try require(
            !(try toggledHeading.nodes(
                forXPath: "./*[local-name()='pPr']/*[local-name()='numPr']/*[local-name()='numId' and @*[local-name()='val']!='0']"
            )).isEmpty,
            "Bullet button did not add OOXML numbering"
        )
        let unlistedParagraph = try paragraph(containing: "First item", in: toggledXML)
        try require(
            (try unlistedParagraph.nodes(
                forXPath: "./*[local-name()='pPr']/*[local-name()='numPr']"
            )).isEmpty,
            "Bullet button did not remove OOXML numbering"
        )
        try require(
            (try unlistedParagraph.nodes(
                forXPath: "./*[local-name()='pPr']/*[local-name()='ind']"
            )).isEmpty,
            "Removing a bullet left list indentation behind"
        )

        let plainData = try makePlainFixture()
        let plainSession = try DocxDocumentSession(data: plainData)
        let plainEditor = NSMutableAttributedString(
            attributedString: plainSession.attributedText
        )
        plainEditor.addAttribute(
            DocxEditorAttribute.listMarker,
            value: "•",
            range: NSRange(location: 0, length: plainEditor.length)
        )
        plainSession.acceptEditorText(plainEditor)
        try require(
            plainSession.pendingError == nil,
            "Creating the first bullet definition failed"
        )
        let newNumberingData = try plainSession.serializedData()
        let newNumberingPackage = try DocxPackage(data: newNumberingData)
        try require(
            newNumberingPackage.containsPart(named: "word/numbering.xml"),
            "The first list did not create numbering.xml"
        )
        let updatedContentTypes = String(
            decoding: try newNumberingPackage.part(named: "[Content_Types].xml"),
            as: UTF8.self
        )
        try require(
            updatedContentTypes.contains("/word/numbering.xml"),
            "The first list did not register its content type"
        )
        let updatedRelationships = String(
            decoding: try newNumberingPackage.part(
                named: "word/_rels/document.xml.rels"
            ),
            as: UTF8.self
        )
        try require(
            updatedRelationships.contains("relationships/numbering"),
            "The first list did not create a document relationship"
        )
        let newNumberingReopened = try DocxDocumentSession(data: newNumberingData)
        try require(
            try newNumberingReopened.serializedData() == newNumberingData,
            "A newly created numbering part did not survive reopening"
        )

        let edited = NSMutableAttributedString(attributedString: session.attributedText)
        let headingParagraphRange = (edited.string as NSString).paragraphRange(
            for: titleRange
        )
        edited.deleteCharacters(in: headingParagraphRange)
        let firstRange = (edited.string as NSString).range(of: "First")
        try require(firstRange.location != NSNotFound, "Fixture is missing First")
        edited.replaceCharacters(in: firstRange, with: "Updated")

        let secondRange = (edited.string as NSString).range(of: "Second item")
        try require(secondRange.location != NSNotFound, "Fixture is missing Second item")
        let originalFont = edited.attribute(
            .font,
            at: secondRange.location,
            effectiveRange: nil
        ) as? NSFont ?? NSFont.systemFont(ofSize: 14)
        let emphasizedFont = NSFontManager.shared.convert(
            originalFont,
            toHaveTrait: [.boldFontMask, .italicFontMask]
        )
        edited.addAttributes(
            [
                .font: emphasizedFont,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor(
                    deviceRed: 0.2,
                    green: 0.4,
                    blue: 0.6,
                    alpha: 1
                )
            ],
            range: secondRange
        )
        let appendedAttributes = edited.attributes(
            at: NSMaxRange(secondRange) - 1,
            effectiveRange: nil
        )
        edited.insert(
            NSAttributedString(string: " updated", attributes: appendedAttributes),
            at: NSMaxRange(secondRange)
        )
        let centeredStyle = (
            edited.attribute(
                .paragraphStyle,
                at: secondRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle ?? NSParagraphStyle.default
        ).mutableCopy() as! NSMutableParagraphStyle
        centeredStyle.alignment = .center
        edited.addAttribute(.paragraphStyle, value: centeredStyle, range: secondRange)

        let thirdRange = (edited.string as NSString).range(of: "Third item")
        try require(thirdRange.location != NSNotFound, "Fixture is missing Third item")
        let inheritedAttributes = edited.attributes(
            at: NSMaxRange(thirdRange) - 1,
            effectiveRange: nil
        )
        edited.insert(
            NSAttributedString(
                string: "\nhello\nnew line",
                attributes: inheritedAttributes
            ),
            at: NSMaxRange(thirdRange)
        )
        session.acceptEditorText(edited)
        try require(session.pendingError == nil, "Editor reconciliation failed")

        let saved = try session.serializedData()
        let savedPackage = try DocxPackage(data: saved)
        try require(savedPackage.paths == originalPackage.paths, "Package entry order or membership changed")

        for path in originalPackage.paths where path != "word/document.xml" {
            try require(
                try originalPackage.part(named: path) == savedPackage.part(named: path),
                "Untouched package part changed: \(path)"
            )
        }

        let documentXML = try savedPackage.part(named: "word/document.xml")
        let documentString = String(decoding: documentXML, as: UTF8.self)
        try require(documentString.components(separatedBy: "<w:numPr>").count - 1 == 5, "Inserted bullets are not real lists")
        try require(!documentString.contains("•"), "Literal bullet leaked into document text")
        try require(!documentString.contains("Real Word-style list"), "Deleted paragraph survived")
        try require(documentString.contains("Updated item"), "Text replacement is missing")
        try require(
            documentString.contains("Second item") && documentString.contains(" updated"),
            "Formatted text insertion is missing"
        )
        try require(documentString.contains("hello"), "First inserted paragraph is missing")
        try require(documentString.contains("new line"), "Second inserted paragraph is missing")
        try require(documentString.contains("Helvetica Neue"), "Inserted runs lost their font")

        let documentTree = try XMLDocument(data: documentXML, options: [.nodePreserveAll])
        guard let formattedParagraph = try documentTree.nodes(
            forXPath: "//*[local-name()='p'][.//*[local-name()='t' and contains(., 'Second item')]]"
        ).first as? XMLElement else {
            throw NSError(
                domain: "DocxCoreRegression",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Formatted paragraph is missing"]
            )
        }
        try require(
            !(try formattedParagraph.nodes(forXPath: ".//*[local-name()='b']")).isEmpty,
            "Bold formatting was not serialized"
        )
        try require(
            !(try formattedParagraph.nodes(forXPath: ".//*[local-name()='i']")).isEmpty,
            "Italic formatting was not serialized"
        )
        let underline = try formattedParagraph.nodes(
            forXPath: ".//*[local-name()='u']"
        ).first as? XMLElement
        try require(
            attribute("val", in: underline) == "single",
            "Underline formatting was not serialized"
        )
        let color = try formattedParagraph.nodes(
            forXPath: ".//*[local-name()='color']"
        ).first as? XMLElement
        try require(
            attribute("val", in: color) == "336699",
            "Text color was not serialized"
        )
        let alignment = try formattedParagraph.nodes(
            forXPath: "./*[local-name()='pPr']/*[local-name()='jc']"
        ).first as? XMLElement
        try require(
            attribute("val", in: alignment) == "center",
            "Paragraph alignment was not serialized"
        )

        let reopened = try DocxDocumentSession(data: saved)
        try require(
            reopened.attributedText.string.contains("Third item\nhello\nnew line"),
            "Inserted paragraphs did not survive reopening"
        )
        try require(try reopened.serializedData() == saved, "Reopened no-op save must be byte-identical")

        print("PASS: byte-identical no-op save")
        print("PASS: inherited section rule and list style projection")
        print("PASS: trailing empty list paragraph marker and OOXML persistence")
        print("PASS: toolbar-style add and remove bullet operations")
        print("PASS: first bullet creates complete numbering infrastructure")
        print("PASS: paragraph deletion without stale-index failure")
        print("PASS: stable-ID text replacement")
        print("PASS: two real-list paragraph insertions")
        print("PASS: all untouched package parts preserved")
        print("PASS: font properties preserved")
        print("PASS: run formatting and paragraph alignment serialized")
        print("PASS: reopen and second no-op save")
    }

    private static func compareSavedFile(
        baselinePath: String,
        savedPath: String
    ) throws {
        let baselineData = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
        let savedData = try Data(contentsOf: URL(fileURLWithPath: savedPath))
        let baseline = try DocxPackage(data: baselineData)
        let saved = try DocxPackage(data: savedData)

        try require(
            baseline.paths == saved.paths,
            "Saved package membership or entry order changed"
        )
        for path in baseline.paths where path != "word/document.xml" {
            try require(
                try baseline.part(named: path) == saved.part(named: path),
                "Untouched package part changed: \(path)"
            )
        }

        let documentData = try saved.part(named: "word/document.xml")
        _ = try XMLDocument(data: documentData, options: [.nodePreserveAll])
        let session = try DocxDocumentSession(data: savedData)
        try require(
            try session.serializedData() == savedData,
            "Reopened no-op save is not byte-identical"
        )

        let document = String(decoding: documentData, as: UTF8.self)
        try require(
            !document.contains("•"),
            "A literal bullet character leaked into document text"
        )

        print("PASS: saved ZIP and document XML are valid")
        print("PASS: package membership and order are unchanged")
        print("PASS: every untouched package part is byte-identical")
        print("PASS: edited document reopens with a byte-identical no-op save")
        print("PASS: lists remain OOXML numbering, not literal bullet text")
    }

    private static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw NSError(
                domain: "DocxCoreRegression",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private static func paragraph(
        containing text: String,
        in document: XMLDocument
    ) throws -> XMLElement {
        guard let paragraph = try document.nodes(
            forXPath: "//*[local-name()='p'][.//*[local-name()='t' and contains(., '\(text)')]]"
        ).first as? XMLElement else {
            throw NSError(
                domain: "DocxCoreRegression",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Paragraph is missing: \(text)"]
            )
        }
        return paragraph
    }

    private static func attribute(_ name: String, in element: XMLElement?) -> String? {
        element?.attributes?.first(where: {
            $0.localName == name || $0.name == name || $0.name == "w:\(name)"
        })?.stringValue
    }

    private static func makeFixture() throws -> Data {
        let parts: [(String, String)] = [
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", packageRelationships),
            ("docProps/app.xml", appProperties),
            ("docProps/core.xml", coreProperties),
            ("docProps/meta.xml", metadata),
            ("word/_rels/document.xml.rels", documentRelationships),
            ("word/document.xml", document),
            ("word/fontTable.xml", fontTable),
            ("word/numbering.xml", numbering),
            ("word/settings.xml", settings),
            ("word/styles.xml", styles),
            ("word/theme/theme1.xml", theme)
        ]
        let archive = try Archive(accessMode: .create)
        for (path, source) in parts {
            let data = Data(source.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        guard let data = archive.data else {
            throw NSError(domain: "DocxCoreRegression", code: 2)
        }
        return data
    }

    private static func makePlainFixture() throws -> Data {
        let plainContentTypes = contentTypes.replacingOccurrences(
            of: "  <Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>\n",
            with: ""
        )
        let plainRelationships = documentRelationships.replacingOccurrences(
            of: "  <Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>\n",
            with: ""
        )
        let plainDocument = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(wordNamespace)" xmlns:r="\(relationshipNamespace)"><w:body>
          <w:p><w:pPr/><w:r><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue"/><w:sz w:val="28"/></w:rPr><w:t>Plain paragraph</w:t></w:r></w:p>
          <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
        </w:body></w:document>
        """
        let parts: [(String, String)] = [
            ("[Content_Types].xml", plainContentTypes),
            ("_rels/.rels", packageRelationships),
            ("docProps/app.xml", appProperties),
            ("docProps/core.xml", coreProperties),
            ("docProps/meta.xml", metadata),
            ("word/_rels/document.xml.rels", plainRelationships),
            ("word/document.xml", plainDocument),
            ("word/fontTable.xml", fontTable),
            ("word/settings.xml", settings),
            ("word/styles.xml", styles),
            ("word/theme/theme1.xml", theme)
        ]
        let archive = try Archive(accessMode: .create)
        for (path, source) in parts {
            let data = Data(source.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        guard let data = archive.data else {
            throw NSError(domain: "DocxCoreRegression", code: 5)
        }
        return data
    }

    private static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
      <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
      <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
      <Override PartName="/word/fontTable.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"/>
    </Types>
    """

    private static let packageRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static let documentRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
      <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable" Target="fontTable.xml"/>
    </Relationships>
    """

    private static let document = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="\(wordNamespace)" xmlns:r="\(relationshipNamespace)"><w:body>
      <w:p><w:pPr><w:pStyle w:val="SectionHeader"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue"/><w:sz w:val="40"/><w:b/></w:rPr><w:t>Real Word-style list</w:t></w:r></w:p>
      \(listParagraph("First item"))
      \(listParagraph("Second item"))
      \(listParagraph("Third item"))
      <w:p><w:pPr><w:pStyle w:val="StyledBullet"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue"/><w:sz w:val="28"/></w:rPr><w:t>Style-inherited list item</w:t></w:r></w:p>
      <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
    </w:body></w:document>
    """

    private static func listParagraph(_ text: String) -> String {
        """
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr><w:ind w:left="720" w:hanging="360"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue"/><w:sz w:val="28"/></w:rPr><w:t>\(text)</w:t></w:r></w:p>
        """
    }

    private static let numbering = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="\(wordNamespace)">
      <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
      <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
    </w:numbering>
    """

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="\(wordNamespace)">
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue"/><w:sz w:val="28"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="SectionHeaderBase"><w:name w:val="Section Header Base"/><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="8" w:color="1F4E79"/></w:pBdr></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="SectionHeader"><w:name w:val="Section Header"/><w:basedOn w:val="SectionHeaderBase"/></w:style>
      <w:style w:type="paragraph" w:styleId="StyledBulletBase"><w:name w:val="Styled Bullet Base"/><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="StyledBullet"><w:name w:val="Styled Bullet"/><w:basedOn w:val="StyledBulletBase"/></w:style>
    </w:styles>
    """
    private static let settings = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:settings xmlns:w="\(wordNamespace)"/>
    """
    private static let fontTable = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:fonts xmlns:w="\(wordNamespace)"><w:font w:name="Helvetica Neue"/></w:fonts>
    """
    private static let theme = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Test"/>
    """
    private static let appProperties = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>FreeDocx Tests</Application></Properties>
    """
    private static let coreProperties = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"/>
    """
    private static let metadata = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><metadata/>
    """
}
