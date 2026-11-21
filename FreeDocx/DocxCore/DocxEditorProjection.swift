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

    /// TextKit may give the first typed character only its native typing
    /// attributes. Carry the destination paragraph's identity and list style
    /// from the original edit range, leaving the typed run's font and color alone.
    struct ParagraphInsertion {
        let insertedRange: NSRange
        private let attributes: [NSAttributedString.Key: Any]
        private static let keys: [NSAttributedString.Key] = [
            DocxEditorAttribute.paragraphID, DocxEditorAttribute.listMarker,
            DocxEditorAttribute.listMarkerIndent, .paragraphStyle
        ]

        init?(in original: NSAttributedString, range: NSRange, replacement: String, offset: Int) {
            guard original.length > 0, !replacement.isEmpty else { return nil }
            let string = original.string as NSString
            var start = 0, contentsEnd = 0
            string.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd,
                                     for: NSRange(location: range.location, length: 0))
            let isReturn = replacement == "\n" || replacement == "\r" || replacement == "\r\n"
            let isFirstText = start == range.location && replacement.rangeOfCharacter(from: .newlines) == nil
            guard (isReturn || isFirstText), NSMaxRange(range) <= contentsEnd else { return nil }
            let source = min(start, original.length - 1)
            var attributes = original.attributes(at: source, effectiveRange: nil)
            guard attributes[DocxEditorAttribute.paragraphID] != nil else { return nil }
            // At EOF the newline carries the trailing paragraph's ID, but
            // AppKit can give it the indent of the preceding list item.
            if start == original.length, attributes[DocxEditorAttribute.listMarker] == nil,
               let style = attributes[.paragraphStyle] as? NSParagraphStyle,
               style.headIndent != 0 || style.firstLineHeadIndent != 0 {
                let preceding = string.paragraphRange(for: NSRange(location: source, length: 1)).location
                if original.attribute(DocxEditorAttribute.listMarker, at: preceding, effectiveRange: nil) != nil {
                    let plain = style.mutableCopy() as! NSMutableParagraphStyle
                    plain.headIndent = 0
                    plain.firstLineHeadIndent = 0
                    plain.tabStops = plain.tabStops.filter { abs($0.location - style.headIndent) > 0.5 }
                    attributes[.paragraphStyle] = plain
                }
            }
            self.attributes = attributes
            insertedRange = NSRange(location: range.location + offset, length: replacement.utf16.count)
        }

        func apply(to text: NSMutableAttributedString) {
            for key in Self.keys {
                if let value = attributes[key] {
                    text.addAttribute(key, value: value, range: insertedRange)
                } else {
                    text.removeAttribute(key, range: insertedRange)
                }
            }
        }
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

    /// Prepare run and alignment changes on detached paragraph nodes. Structural
    /// edits use the sequence reconciler so later list numbers can change too.
    static func prepareParagraphEdits(
        editorText: NSAttributedString, previousText: NSAttributedString,
        affectedRange: NSRange?, model: DocxDocumentModel
    ) throws -> (paragraphs: [DocxParagraph], text: NSAttributedString)? {
        let (before, after) = paragraphEditRanges(
            before: previousText, after: editorText, hint: affectedRange
        )
        // Cocoa can store a final empty paragraph's ID on its predecessor's
        // newline. Changes there use the structural reconciler.
        if NSMaxRange(after) == editorText.length,
           endsInNewline(editorText.string) != endsInNewline(previousText.string)
                || hasSeparateTrailingParagraph(in: previousText) {
            return nil
        }
        let oldSlices = paragraphSlices(in: previousText, within: before)
        let newSlices = paragraphSlices(in: editorText, within: after)
        guard oldSlices.count == newSlices.count else { return nil }
        let projection = NSMutableAttributedString(attributedString: editorText)
        var replacements: [DocxParagraph] = []
        for (old, new) in zip(oldSlices, newSlices) {
            guard let id = old.id, id == new.id, old.isList == new.isList,
                  let original = model.paragraph(with: id) else { return nil }
            if previousText.attributedSubstring(from: old.paragraphRange).isEqual(
                to: editorText.attributedSubstring(from: new.paragraphRange)
            ) { continue }
            let contents = editorText.attributedSubstring(from: new.contentsRange)
            let oldContents = previousText.attributedSubstring(from: old.contentsRange)
            let runsChanged = !runFormattingIsEqual(oldContents, contents)
            let alignment = paragraphAlignment(in: editorText, at: new.paragraphRange.location)
            let alignmentChanged = alignment != paragraphAlignment(in: previousText, at: old.paragraphRange.location)
            guard model.isListParagraph(original) == new.isList,
                  let staged = try model.stagedParagraph(
                      original, contents: runsChanged ? contents : nil,
                      alignment: alignmentChanged ? alignment : nil
                  ), let presentation = staged.presentation else { return nil }
            if runsChanged || alignmentChanged { replacements.append(staged) }
            projection.addAttribute(DocxEditorAttribute.paragraphID, value: id.uuidString, range: new.paragraphRange)
            applyPresentation(presentation, to: projection, paragraph: staged, model: model,
                              paragraphRange: new.paragraphRange, contentsRange: new.contentsRange)
        }
        return (replacements, projection.copy() as! NSAttributedString)
    }

    private static func paragraphEditRanges(
        before old: NSAttributedString, after new: NSAttributedString, hint: NSRange?
    ) -> (NSRange, NSRange) {
        let fullRanges = (NSRange(location: 0, length: old.length), NSRange(location: 0, length: new.length))
        guard let hint, NSMaxRange(hint) <= old.length else { return fullRanges }

        // Include both sides of splits/merges. Paste and Undo can change
        // attributes outside the announced range, so verify both boundaries.
        let start = max(0, hint.location - 1)
        let end = min(old.length, NSMaxRange(hint) + 1)
        let oldSpan = (old.string as NSString).paragraphRange(for: NSRange(location: start, length: end - start))
        let newLength = oldSpan.length + new.length - old.length
        guard newLength > 0, oldSpan.location + newLength <= new.length else { return fullRanges }
        let newSpan = NSRange(location: oldSpan.location, length: newLength)
        let prefix = NSRange(location: 0, length: oldSpan.location)
        let suffixLength = old.length - NSMaxRange(oldSpan)
        let oldSuffix = NSRange(location: NSMaxRange(oldSpan), length: suffixLength)
        let newSuffix = NSRange(location: NSMaxRange(newSpan), length: suffixLength)
        guard (new.string as NSString).paragraphRange(for: newSpan) == newSpan,
              old.attributedSubstring(from: prefix).isEqual(to: new.attributedSubstring(from: prefix)),
              old.attributedSubstring(from: oldSuffix).isEqual(to: new.attributedSubstring(from: newSuffix))
        else { return fullRanges }
        return (oldSpan, newSpan)
    }

    private static func hasSeparateTrailingParagraph(in text: NSAttributedString) -> Bool {
        guard let id = trailingEmptySlice(in: text)?.id else { return false }
        let newline = NSRange(location: text.length - 1, length: 1)
        let start = (text.string as NSString).paragraphRange(for: newline).location
        let precedingID = text.attribute(DocxEditorAttribute.paragraphID, at: start, effectiveRange: nil) as? String
        return precedingID != id.uuidString
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
        if editorText.length == 0 {
            // An empty text storage cannot carry a paragraph ID. Retain the
            // first selected Word paragraph as the insertion point for typing.
            guard previousText.length > 0 else { return editorText }
            guard let value = previousText.attribute(DocxEditorAttribute.paragraphID, at: 0,
                                                     effectiveRange: nil) as? String,
                  let id = UUID(uuidString: value) else {
                throw DocxModelError.unknownParagraphID
            }
            try model.clearBody(keeping: id)
            return editorText
        }
        let projection = NSMutableAttributedString(attributedString: editorText)
        if previousText.length == 0, model.paragraphs.count == 1,
           let anchor = model.paragraphs.first {
            let first = (editorText.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            projection.addAttribute(DocxEditorAttribute.paragraphID, value: anchor.id.uuidString, range: first)
        }
        var sourceSlices = paragraphSlices(in: projection)
        let editorEndsInNewline = endsInNewline(editorText.string)
        let previousEndsInNewline = endsInNewline(previousText.string)
        let addedAmbiguousTrailingParagraph = editorEndsInNewline
            && !previousEndsInNewline
            && editorText.string != previousText.string
        let modelAlreadyHasTrailingParagraph = model.paragraphs.count == sourceSlices.count + 1
        if (addedAmbiguousTrailingParagraph || modelAlreadyHasTrailingParagraph),
           let trailingSlice = trailingEmptySlice(
               in: editorText, continuingParagraph: addedAmbiguousTrailingParagraph
           ) {
            sourceSlices.append(trailingSlice)
        }
        let previousSlices = Dictionary(
            paragraphSlices(in: previousText).compactMap { slice in
                slice.id.map { ($0, slice) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let originalIndices = Dictionary(uniqueKeysWithValues: model.paragraphs.enumerated().map { ($1.id, $0) })
        var nextOriginalIndex = 0
        var changedIDs = Set<UUID>()
        var liveIndex = 0

        for slice in sourceSlices {
            let paragraph: DocxParagraph
            let isExistingParagraph: Bool
            if let id = slice.id, let requestedIndex = originalIndices[id],
               requestedIndex >= nextOriginalIndex, let requestedParagraph = model.paragraph(with: id) {
                for _ in nextOriginalIndex..<requestedIndex {
                    model.deleteParagraph(at: liveIndex)
                }
                nextOriginalIndex = requestedIndex + 1
                guard model.paragraphs.indices.contains(liveIndex),
                      model.paragraphs[liveIndex] === requestedParagraph else {
                    throw DocxModelError.unknownParagraphID
                }
                paragraph = requestedParagraph
                isExistingParagraph = true
            } else {
                let previous = liveIndex > 0 ? model.paragraphs[liveIndex - 1] : nil
                let next = liveIndex < model.paragraphs.count ? model.paragraphs[liveIndex] : nil
                let neighbors = [previous, next].compactMap { $0 }
                let matchingTemplate = neighbors.first(where: {
                    model.isListParagraph($0) == slice.isList
                })
                guard let template = matchingTemplate ?? neighbors.first else {
                    throw DocxModelError.unsupportedParagraphContainer
                }
                paragraph = try model.insertParagraph(
                    text: slice.text,
                    at: liveIndex,
                    template: template
                )
                isExistingParagraph = false
            }

            if isExistingParagraph, let previousSlice = previousSlices[paragraph.id],
               editorText.attributedSubstring(from: slice.paragraphRange).isEqual(
                   to: previousText.attributedSubstring(from: previousSlice.paragraphRange)
               ) {
                liveIndex += 1
                continue
            }
            changedIDs.insert(paragraph.id)
            if model.isListParagraph(paragraph) != slice.isList {
                try model.setBulletedList(of: paragraph, enabled: slice.isList)
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
        }

        while liveIndex < model.paragraphs.count {
            model.deleteParagraph(at: liveIndex)
        }

        guard sourceSlices.count == model.paragraphs.count else {
            throw DocxModelError.projectionMismatch(
                xmlParagraphs: model.paragraphs.count,
                renderedParagraphs: sourceSlices.count
            )
        }
        applyPresentationMetadata(to: projection, model: model, changedIDs: changedIDs)
        return projection.copy() as! NSAttributedString
    }

    static func paragraphSlices(in source: NSAttributedString, within range: NSRange? = nil) -> [ParagraphSlice] {
        guard source.length > 0 else { return [] }
        let plainText = source.string as NSString
        var result: [ParagraphSlice] = []
        var location = range?.location ?? 0
        let end = range.map(NSMaxRange) ?? source.length

        while location < end {
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
        in source: NSAttributedString, continuingParagraph: Bool = false
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

        // A newly inserted terminal newline can carry the paragraph ID but
        // lose its list marker in TextKit. Continue the item the user split.
        // An existing trailing item has its own identity on the newline.
        let newlineLocation = source.length - 1
        let attributeLocation = continuingParagraph ? paragraphStart : newlineLocation
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
            paragraphRange: NSRange(location: newlineLocation, length: 1),
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
        model: DocxDocumentModel,
        changedIDs: Set<UUID>? = nil
    ) {
        guard projection.length > 0 else { return }
        var slices = paragraphSlices(in: projection)
        if model.paragraphs.count == slices.count + 1,
           let trailingSlice = trailingEmptySlice(in: projection) {
            slices.append(trailingSlice)
        }
        let presentations = model.presentations()
        for (index, pair) in zip(slices, model.paragraphs).enumerated() {
            let (slice, paragraph) = pair
            var paragraphRange = slice.paragraphRange
            // A terminal newline belongs to the separate empty paragraph when
            // one exists. Do not reapply the preceding item's list formatting
            // over it after the user ends the list.
            if slices.indices.contains(index + 1) {
                paragraphRange.length = min(
                    paragraphRange.length,
                    slices[index + 1].paragraphRange.location - paragraphRange.location
                )
            }
            guard paragraphRange.length > 0,
                  let presentation = presentations[paragraph.id] else {
                continue
            }

            if let changedIDs, !changedIDs.contains(paragraph.id),
               projection.attribute(DocxEditorAttribute.listMarker, at: paragraphRange.location,
                                    effectiveRange: nil) as? String == presentation.listMarker {
                continue
            }
            applyPresentation(presentation, to: projection, paragraph: paragraph, model: model,
                              paragraphRange: paragraphRange, contentsRange: slice.contentsRange)
        }
    }

    private static func applyPresentation(
        _ presentation: DocxParagraphPresentation, to projection: NSMutableAttributedString,
        paragraph: DocxParagraph, model: DocxDocumentModel,
        paragraphRange: NSRange, contentsRange: NSRange
    ) {
        projection.removeAttribute(DocxEditorAttribute.listMarker, range: paragraphRange)
        projection.removeAttribute(DocxEditorAttribute.listMarkerIndent, range: paragraphRange)
        projection.removeAttribute(DocxEditorAttribute.sectionRule, range: paragraphRange)
        model.applyRunPresentation(
            to: projection,
            paragraph: paragraph,
            in: contentsRange
        )

        if presentation.spacingBefore != nil
            || presentation.spacingAfter != nil
            || presentation.lineSpacing != nil {
            let existingStyle = projection.attribute(
                .paragraphStyle,
                at: paragraphRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle ?? NSParagraphStyle.default
            let style = existingStyle.mutableCopy() as! NSMutableParagraphStyle
            if let spacingBefore = presentation.spacingBefore {
                style.paragraphSpacingBefore = spacingBefore
            }
            if let spacingAfter = presentation.spacingAfter {
                style.paragraphSpacing = spacingAfter
            }
            if let lineSpacing = presentation.lineSpacing {
                switch lineSpacing {
                case let .multiple(value):
                    style.lineHeightMultiple = value
                    style.minimumLineHeight = 0
                    style.maximumLineHeight = 0
                case let .exact(value):
                    style.lineHeightMultiple = 0
                    style.minimumLineHeight = value
                    style.maximumLineHeight = value
                case let .atLeast(value):
                    style.lineHeightMultiple = 0
                    style.minimumLineHeight = value
                    style.maximumLineHeight = 0
                }
            }
            projection.addAttribute(
                .paragraphStyle,
                value: style,
                range: paragraphRange
            )
        }

        if !presentation.hasExplicitUnderline {
            removeImportedUnderline(
                from: projection,
                in: contentsRange
            )
        }

        if let marker = presentation.listMarker,
           let markerIndent = presentation.markerIndent,
           let textIndent = presentation.textIndent {
            let existingStyle = projection.attribute(
                .paragraphStyle,
                at: paragraphRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle ?? NSParagraphStyle.default
            let style = existingStyle.mutableCopy() as! NSMutableParagraphStyle
            style.firstLineHeadIndent = textIndent
            style.headIndent = textIndent
            style.tabStops = style.tabStops.filter { abs($0.location - textIndent) > 0.5 }
            style.addTabStop(NSTextTab(textAlignment: .left, location: textIndent))
            projection.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            projection.addAttribute(DocxEditorAttribute.listMarker, value: marker, range: paragraphRange)
            projection.addAttribute(
                DocxEditorAttribute.listMarkerIndent,
                value: NSNumber(value: Double(markerIndent)),
                range: paragraphRange
            )
        }

        if let color = presentation.sectionRuleColor,
           contentsRange.length > 0 {
            projection.addAttribute(
                DocxEditorAttribute.sectionRule,
                value: color,
                range: contentsRange
            )
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
            DocxEditorAttribute.sectionRule,
            DocxEditorAttribute.sourceFontFamily,
            DocxEditorAttribute.substituteFontFamily
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
