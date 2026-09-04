//
//  DocxEditorProjection.swift
//  FreeDocx
//

import AppKit
import Foundation

/// Builds and reconciles the TextKit projection. Paragraph IDs, rather than
/// paragraph text, connect editor mutations back to the OOXML model.
enum DocxEditorProjection {
    struct ParagraphSlice {
        let paragraphRange: NSRange
        let contentsRange: NSRange
        let text: String
        let id: UUID?
        let isList: Bool
    }

    static func initial(
        importedText: NSAttributedString,
        model: DocxDocumentModel
    ) throws -> NSAttributedString {
        let slices = paragraphSlices(in: importedText)
        guard slices.count == model.paragraphs.count else {
            throw DocxModelError.projectionMismatch(
                xmlParagraphs: model.paragraphs.count,
                renderedParagraphs: slices.count
            )
        }

        let projection = NSMutableAttributedString(attributedString: importedText)
        for (slice, paragraph) in zip(slices, model.paragraphs) where slice.paragraphRange.length > 0 {
            projection.addAttribute(
                DocxEditorAttribute.paragraphID,
                value: paragraph.id.uuidString,
                range: slice.paragraphRange
            )
        }
        applyPresentationMetadata(to: projection, model: model)
        return projection.copy() as! NSAttributedString
    }

    /// Reconciles the editor's paragraph sequence with the model. Existing IDs
    /// update their exact nodes; duplicated IDs created by Return become new
    /// paragraphs cloned from their list/style neighbor; missing IDs represent
    /// deletions. No text-based LCS is involved.
    static func reconcile(
        editorText: NSAttributedString,
        previousText: NSAttributedString,
        model: DocxDocumentModel
    ) throws -> NSAttributedString {
        var sourceSlices = paragraphSlices(in: editorText)
        let editorEndsInNewline = endsInNewline(editorText.string)
        let previousEndsInNewline = endsInNewline(previousText.string)
        let addedAmbiguousTrailingParagraph = editorEndsInNewline
            && !previousEndsInNewline
            && editorText.string != previousText.string
        let modelAlreadyHasTrailingParagraph = model.paragraphs.count == sourceSlices.count + 1
        if (addedAmbiguousTrailingParagraph || modelAlreadyHasTrailingParagraph),
           let trailingSlice = trailingEmptySlice(in: editorText) {
            sourceSlices.append(trailingSlice)
        }
        let previousSlices = Dictionary(
            paragraphSlices(in: previousText).compactMap { slice in
                slice.id.map { ($0, slice) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let projection = NSMutableAttributedString(attributedString: editorText)
        var liveIndex = 0

        for (sliceIndex, slice) in sourceSlices.enumerated() {
            let requestedParagraph = slice.id.flatMap(model.paragraph(with:))
            let requestedIndex = requestedParagraph.flatMap { requested in
                model.paragraphs.firstIndex(where: { $0 === requested })
            }

            let paragraph: DocxParagraph
            let isExistingParagraph: Bool
            if let requestedParagraph,
               let requestedIndex,
               requestedIndex >= liveIndex {
                let deletionCount = requestedIndex - liveIndex
                for _ in 0..<deletionCount {
                    guard model.paragraphs.indices.contains(liveIndex) else {
                        throw DocxModelError.projectionMismatch(
                            xmlParagraphs: model.paragraphs.count,
                            renderedParagraphs: sourceSlices.count
                        )
                    }
                    try model.deleteParagraph(model.paragraphs[liveIndex])
                }
                guard model.paragraphs.indices.contains(liveIndex),
                      model.paragraphs[liveIndex] === requestedParagraph else {
                    throw DocxModelError.unknownParagraphID
                }
                paragraph = requestedParagraph
                isExistingParagraph = true
            } else {
                let previous = liveIndex > 0 ? model.paragraphs[liveIndex - 1] : nil
                let next = liveIndex < model.paragraphs.count ? model.paragraphs[liveIndex] : nil
                let presentations = model.presentations()
                let template = [previous, next].compactMap { $0 }.first(where: {
                    (presentations[$0.id]?.listMarker != nil) == slice.isList
                })
                guard let template else {
                    throw DocxModelError.unsupportedParagraphContainer
                }
                paragraph = try model.insertParagraph(
                    text: slice.text,
                    at: liveIndex,
                    template: template
                )
                isExistingParagraph = false
            }

            if isExistingParagraph {
                let currentlyBulleted = model.presentations()[paragraph.id]?.listMarker != nil
                if currentlyBulleted != slice.isList {
                    try model.setBulletedList(
                        of: paragraph,
                        enabled: slice.isList
                    )
                }
            }

            let currentContents = editorText.attributedSubstring(from: slice.contentsRange)
            if isExistingParagraph,
               let previousSlice = previousSlices[paragraph.id] {
                let previousContents = previousText.attributedSubstring(
                    from: previousSlice.contentsRange
                )
                if previousSlice.text != slice.text
                    || !runFormattingIsEqual(previousContents, currentContents) {
                    try model.applyRunFormatting(to: paragraph, from: currentContents)
                }
                let previousAlignment = paragraphAlignment(
                    in: previousText,
                    at: previousSlice.paragraphRange.location
                )
                let currentAlignment = paragraphAlignment(
                    in: editorText,
                    at: slice.paragraphRange.location
                )
                if previousAlignment != currentAlignment {
                    try model.setAlignment(of: paragraph, to: currentAlignment)
                }
            } else {
                try model.applyRunFormatting(to: paragraph, from: currentContents)
            }
            if slice.paragraphRange.length > 0 {
                projection.addAttribute(
                    DocxEditorAttribute.paragraphID,
                    value: paragraph.id.uuidString,
                    range: slice.paragraphRange
                )
            }
            liveIndex += 1

            // A paragraph ID may cover its terminating newline and therefore
            // be inherited by the following paragraph. Reassigning it here is
            // intentional; each slice must leave reconciliation with one ID.
            _ = sliceIndex
        }

        while liveIndex < model.paragraphs.count {
            try model.deleteParagraph(model.paragraphs[liveIndex])
        }

        guard sourceSlices.count == model.paragraphs.count else {
            throw DocxModelError.projectionMismatch(
                xmlParagraphs: model.paragraphs.count,
                renderedParagraphs: sourceSlices.count
            )
        }
        applyPresentationMetadata(to: projection, model: model)
        return projection.copy() as! NSAttributedString
    }

    static func paragraphSlices(in source: NSAttributedString) -> [ParagraphSlice] {
        guard source.length > 0 else { return [] }
        let plainText = source.string as NSString
        var result: [ParagraphSlice] = []
        var location = 0

        while location < source.length {
            var paragraphStart = 0
            var paragraphEnd = 0
            var contentsEnd = 0
            plainText.getParagraphStart(
                &paragraphStart,
                end: &paragraphEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let paragraphRange = NSRange(
                location: paragraphStart,
                length: paragraphEnd - paragraphStart
            )
            let contentsRange = NSRange(
                location: paragraphStart,
                length: contentsEnd - paragraphStart
            )
            let idValue: String? = paragraphRange.length > 0
                ? source.attribute(
                    DocxEditorAttribute.paragraphID,
                    at: paragraphStart,
                    effectiveRange: nil
                ) as? String
                : nil
            let style: NSParagraphStyle? = paragraphRange.length > 0
                ? source.attribute(.paragraphStyle, at: paragraphStart, effectiveRange: nil) as? NSParagraphStyle
                : nil
            let hasMarker = paragraphRange.length > 0 && source.attribute(
                DocxEditorAttribute.listMarker,
                at: paragraphStart,
                effectiveRange: nil
            ) != nil
            result.append(ParagraphSlice(
                paragraphRange: paragraphRange,
                contentsRange: contentsRange,
                text: plainText.substring(with: contentsRange).replacingOccurrences(of: "\u{0C}", with: ""),
                id: idValue.flatMap(UUID.init(uuidString:)),
                isList: hasMarker || style?.textLists.isEmpty == false
            ))
            location = max(paragraphEnd, location + 1)
        }

        return result
    }

    /// A single terminal newline is ambiguous in Cocoa: it can terminate the
    /// final populated paragraph and simultaneously host the insertion point
    /// for a new empty paragraph. Reconciliation opts into this extra slice
    /// only when an edit created it or the OOXML model already contains it.
    private static func trailingEmptySlice(
        in source: NSAttributedString
    ) -> ParagraphSlice? {
        guard source.length > 0, endsInNewline(source.string) else { return nil }
        let plainText = source.string as NSString
        var paragraphStart = 0
        var paragraphEnd = 0
        var contentsEnd = 0
        plainText.getParagraphStart(
            &paragraphStart,
            end: &paragraphEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: source.length - 1, length: 0)
        )
        guard contentsEnd > paragraphStart else { return nil }

        let attributeLocation = source.length - 1
        let idValue = source.attribute(
            DocxEditorAttribute.paragraphID,
            at: attributeLocation,
            effectiveRange: nil
        ) as? String
        let style = source.attribute(
            .paragraphStyle,
            at: attributeLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let hasMarker = source.attribute(
            DocxEditorAttribute.listMarker,
            at: attributeLocation,
            effectiveRange: nil
        ) != nil
        return ParagraphSlice(
            paragraphRange: NSRange(location: attributeLocation, length: 1),
            contentsRange: NSRange(location: source.length, length: 0),
            text: "",
            id: idValue.flatMap(UUID.init(uuidString:)),
            isList: hasMarker || style?.textLists.isEmpty == false
        )
    }

    private static func endsInNewline(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else { return false }
        return CharacterSet.newlines.contains(scalar)
    }

    private static func applyPresentationMetadata(
        to projection: NSMutableAttributedString,
        model: DocxDocumentModel
    ) {
        guard projection.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: projection.length)
        projection.removeAttribute(DocxEditorAttribute.listMarker, range: fullRange)
        projection.removeAttribute(DocxEditorAttribute.listMarkerIndent, range: fullRange)
        projection.removeAttribute(DocxEditorAttribute.sectionRule, range: fullRange)

        let slices = paragraphSlices(in: projection)
        let presentations = model.presentations()
        for (slice, paragraph) in zip(slices, model.paragraphs) {
            guard slice.paragraphRange.length > 0,
                  let presentation = presentations[paragraph.id] else {
                continue
            }

            if !presentation.hasExplicitUnderline {
                removeImportedUnderline(
                    from: projection,
                    in: slice.contentsRange
                )
            }

            if let marker = presentation.listMarker,
               let markerIndent = presentation.markerIndent,
               let textIndent = presentation.textIndent {
                let existingStyle = projection.attribute(
                    .paragraphStyle,
                    at: slice.paragraphRange.location,
                    effectiveRange: nil
                ) as? NSParagraphStyle ?? NSParagraphStyle.default
                let style = existingStyle.mutableCopy() as! NSMutableParagraphStyle
                style.firstLineHeadIndent = textIndent
                style.headIndent = textIndent
                style.tabStops = style.tabStops.filter { abs($0.location - textIndent) > 0.5 }
                style.addTabStop(NSTextTab(textAlignment: .left, location: textIndent))
                projection.addAttribute(.paragraphStyle, value: style, range: slice.paragraphRange)
                projection.addAttribute(DocxEditorAttribute.listMarker, value: marker, range: slice.paragraphRange)
                projection.addAttribute(
                    DocxEditorAttribute.listMarkerIndent,
                    value: NSNumber(value: Double(markerIndent)),
                    range: slice.paragraphRange
                )
            }

            if let color = presentation.sectionRuleColor,
               slice.contentsRange.length > 0 {
                projection.addAttribute(
                    DocxEditorAttribute.sectionRule,
                    value: color,
                    range: slice.contentsRange
                )
            }
        }
    }

    private static func runFormattingIsEqual(
        _ lhs: NSAttributedString,
        _ rhs: NSAttributedString
    ) -> Bool {
        guard lhs.string == rhs.string else { return false }
        return strippedRunFormatting(lhs).isEqual(to: strippedRunFormatting(rhs))
    }

    private static func strippedRunFormatting(
        _ source: NSAttributedString
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let range = NSRange(location: 0, length: result.length)
        for key in [
            NSAttributedString.Key.paragraphStyle,
            DocxEditorAttribute.paragraphID,
            DocxEditorAttribute.listMarker,
            DocxEditorAttribute.listMarkerIndent,
            DocxEditorAttribute.sectionRule
        ] {
            result.removeAttribute(key, range: range)
        }
        return result
    }

    private static func paragraphAlignment(
        in text: NSAttributedString,
        at location: Int
    ) -> NSTextAlignment {
        guard text.length > 0, location < text.length else { return .natural }
        return (text.attribute(
            .paragraphStyle,
            at: location,
            effectiveRange: nil
        ) as? NSParagraphStyle)?.alignment ?? .natural
    }

    private static func removeImportedUnderline(
        from projection: NSMutableAttributedString,
        in range: NSRange
    ) {
        guard range.length > 0 else { return }
        var removable: [NSRange] = []
        projection.enumerateAttributes(in: range) { attributes, attributeRange, _ in
            guard attributes[.link] == nil,
                  let value = attributes[.underlineStyle] as? NSNumber,
                  value.intValue != 0 else {
                return
            }
            removable.append(attributeRange)
        }
        for attributeRange in removable {
            projection.removeAttribute(.underlineStyle, range: attributeRange)
            projection.removeAttribute(.underlineColor, range: attributeRange)
        }
    }
}
