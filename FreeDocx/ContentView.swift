//
//  ContentView.swift
//  FreeDocx
//
//  Created by Siavash Bonakdar on 8/30/26.
//

import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var document: FreeDocxDocument
    @StateObject private var editorController = RichTextEditorController()

    var body: some View {
        VStack(spacing: 0) {
            FormattingToolbar(controller: editorController)

            RichTextEditor(
                text: $document.attributedText,
                pageLayout: document.pageLayout,
                controller: editorController,
                validateEdit: document.canApplyEditorChanges
            )

            Divider()
            HStack(spacing: 12) {
                Spacer()
                Text("\(document.wordCount) \(document.wordCount == 1 ? "word" : "words")")
                Text("\(document.attributedText.length) characters")

                Divider()
                    .frame(height: 14)

                Button(action: editorController.zoomOut) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom Out")

                Button("100%", action: editorController.resetZoom)
                    .help("Actual Size")

                Button(action: editorController.zoomIn) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom In")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .frame(minWidth: 620, minHeight: 480)
        .focusedSceneObject(editorController)
        .alert("This edit isn’t supported yet", isPresented: Binding(
            get: { document.editRejectionMessage != nil },
            set: { if !$0 { document.editRejectionMessage = nil } }
        )) {
            Button("OK", role: .cancel) { document.editRejectionMessage = nil }
        } message: {
            Text((document.editRejectionMessage ?? "")
                + " The edit was not applied. Your earlier edits can still be saved.")
        }
    }
}

@MainActor
final class RichTextEditorController: ObservableObject {
    struct Formatting: Equatable {
        var fontSize: CGFloat?
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        var isList = false
        var alignment: NSTextAlignment = .left
        var textColor = NSColor.black
    }

    @Published private(set) var formatting = Formatting()
    private var formattingUpdatePending = false
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?

    // Selection, typing attributes and storage can change together during an
    // edit. Read their final values after TextKit and SwiftUI finish updating.
    func scheduleFormattingUpdate() {
        guard !formattingUpdatePending else { return }
        formattingUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.formattingUpdatePending = false
            self.updateFormatting()
        }
    }

    private func updateFormatting() {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let attributes: [NSAttributedString.Key: Any]
        if selection.length > 0, selection.location < storage.length {
            attributes = storage.attributes(at: selection.location, effectiveRange: nil)
        } else {
            attributes = textView.typingAttributes
        }

        var current = Formatting()
        let fallbackFont = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let font = attributes[.font] as? NSFont ?? fallbackFont
        let traits = NSFontManager.shared.traits(of: font)
        current.isBold = traits.contains(.boldFontMask)
        current.isItalic = traits.contains(.italicFontMask)
        current.fontSize = font.pointSize
        for range in textView.selectedRanges.map(\.rangeValue) where range.length > 0 {
            storage.enumerateAttribute(.font, in: range) { value, _, stop in
                if (value as? NSFont ?? fallbackFont).pointSize != font.pointSize {
                    current.fontSize = nil
                    stop.pointee = true
                }
            }
            if current.fontSize == nil { break }
        }
        current.isUnderlined = (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0
        let color = attributes[.foregroundColor] as? NSColor ?? .black
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            current.textColor = color.usingColorSpace(.sRGB) ?? color
        }

        let ranges = selectedParagraphRanges(in: textView)
        current.isList = allParagraphsHaveListMarkers(ranges, in: storage)
        let style = attributes[.paragraphStyle] as? NSParagraphStyle ?? .default
        current.alignment = style.alignment
        if current.alignment == .natural {
            current.alignment = textView.userInterfaceLayoutDirection == .rightToLeft ? .right : .left
        }
        if current != formatting {
            formatting = current
        }
    }

    private func withEditor(_ action: (NSTextView) -> Void) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        action(textView)
    }

    func toggleBold() {
        toggleFontTrait(.boldFontMask)
    }

    func toggleItalic() {
        toggleFontTrait(.italicFontMask)
    }

    func toggleUnderline() {
        withEditor { $0.underline(nil) }
    }

    func alignLeft() {
        withEditor { $0.alignLeft(nil) }
    }

    func alignCenter() {
        withEditor { $0.alignCenter(nil) }
    }

    func alignRight() {
        withEditor { $0.alignRight(nil) }
    }

    func toggleBulletedList() {
        withEditor { textView in
            guard let textStorage = textView.textStorage else { return }
            let startedEmpty = textStorage.length == 0
            if startedEmpty {
                // Match the editable empty paragraph supplied by the Word
                // importer, so its bullet is visible before the first key.
                let caret = NSRange(location: 0, length: 0)
                textView.insertText("\n", replacementRange: caret)
                guard textStorage.length > 0 else { return }
                textView.setSelectedRange(caret)
            }
            let ranges = selectedParagraphRanges(in: textView)
            guard !ranges.isEmpty else { return }

            // AppKit's importer adds a terminal newline. If the caret is
            // beyond it but the button targets the preceding Word paragraph,
            // put subsequent typing in the paragraph that was just formatted.
            if textView.selectedRange() == NSRange(location: textStorage.length, length: 0) {
                var start = 0, contentsEnd = 0
                (textStorage.string as NSString).getParagraphStart(
                    &start, end: nil, contentsEnd: &contentsEnd,
                    for: NSRange(location: textStorage.length - 1, length: 1)
                )
                if ranges.last?.location == start, contentsEnd < textStorage.length {
                    textView.setSelectedRange(NSRange(location: contentsEnd, length: 0))
                }
            }
            let allBulleted = !startedEmpty && allParagraphsHaveListMarkers(ranges, in: textStorage)
            let combinedRange = NSUnionRange(ranges.first!, ranges.last!)
            guard textView.shouldChangeText(
                in: combinedRange,
                replacementString: nil
            ) else {
                return
            }

            textStorage.beginEditing()
            for range in ranges {
                let existingStyle = textStorage.attribute(
                    .paragraphStyle,
                    at: range.location,
                    effectiveRange: nil
                ) as? NSParagraphStyle ?? NSParagraphStyle.default
                let style = existingStyle.mutableCopy() as! NSMutableParagraphStyle

                if allBulleted {
                    textStorage.removeAttribute(
                        DocxEditorAttribute.listMarker,
                        range: range
                    )
                    textStorage.removeAttribute(
                        DocxEditorAttribute.listMarkerIndent,
                        range: range
                    )
                    style.firstLineHeadIndent = 0
                    style.headIndent = 0
                    style.textLists = []
                    style.tabStops = style.tabStops.filter {
                        abs($0.location - 36) > 0.5
                    }
                } else {
                    style.firstLineHeadIndent = 36
                    style.headIndent = 36
                    style.tabStops = style.tabStops.filter {
                        abs($0.location - 36) > 0.5
                    }
                    style.addTabStop(
                        NSTextTab(textAlignment: .left, location: 36)
                    )
                    textStorage.addAttribute(
                        DocxEditorAttribute.listMarker,
                        value: "•",
                        range: range
                    )
                    textStorage.addAttribute(
                        DocxEditorAttribute.listMarkerIndent,
                        value: NSNumber(value: 18),
                        range: range
                    )
                }
                textStorage.addAttribute(
                    .paragraphStyle,
                    value: style,
                    range: range
                )
            }
            textStorage.endEditing()
            textView.didChangeText()
        }
    }

    /// Return on an empty list item ends the list without adding a paragraph.
    func endListIfEmpty() -> Bool {
        guard let textView,
              let textStorage = textView.textStorage,
              textStorage.length > 0 else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let plainText = textStorage.string as NSString
        var paragraphStart = 0
        var paragraphEnd = 0
        var contentsEnd = 0
        plainText.getParagraphStart(
            &paragraphStart,
            end: &paragraphEnd,
            contentsEnd: &contentsEnd,
            for: selection
        )
        guard paragraphStart == contentsEnd,
              let range = selectedParagraphRanges(in: textView).first,
              textStorage.attribute(
                DocxEditorAttribute.listMarker,
                at: range.location,
                effectiveRange: nil
              ) != nil else { return false }

        toggleBulletedList()
        var attributes = textView.typingAttributes
        attributes.removeValue(forKey: DocxEditorAttribute.listMarker)
        attributes.removeValue(forKey: DocxEditorAttribute.listMarkerIndent)
        let style = (attributes[.paragraphStyle] as? NSParagraphStyle
            ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
        style.textLists = []
        style.firstLineHeadIndent = 0
        style.headIndent = 0
        attributes[.paragraphStyle] = style
        textView.typingAttributes = attributes
        return true
    }

    func performFindAction(_ action: NSTextFinder.Action) {
        withEditor { textView in
            let sender = NSMenuItem()
            sender.tag = action.rawValue
            textView.performTextFinderAction(sender)
        }
    }

    func showFonts() {
        withEditor { textView in
            NSFontManager.shared.orderFrontFontPanel(textView)
        }
    }

    func showColors() {
        withEditor { textView in
            NSColorPanel.shared.orderFront(textView)
        }
    }

    func zoomOut() {
        changeZoom(by: 1 / 1.15)
    }

    func resetZoom() {
        setZoom(1)
    }

    func zoomIn() {
        changeZoom(by: 1.15)
    }

    private func changeZoom(by factor: CGFloat) {
        guard let scrollView else { return }
        setZoom(scrollView.magnification * factor)
    }

    private func setZoom(_ magnification: CGFloat) {
        guard let scrollView else { return }
        let point = NSPoint(
            x: scrollView.documentVisibleRect.midX,
            y: scrollView.documentVisibleRect.midY
        )
        scrollView.setMagnification(magnification, centeredAt: point)
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        changeFonts { font, selectionFont in
            let manager = NSFontManager.shared
            if manager.traits(of: selectionFont).contains(trait) {
                return manager.convert(font, toNotHaveTrait: trait)
            }
            return manager.convert(font, toHaveTrait: trait)
        }
    }

    func setFontSize(_ size: CGFloat) {
        changeFonts { font, _ in NSFontManager.shared.convert(font, toSize: size) }
    }

    private func changeFonts(_ convert: (NSFont, NSFont) -> NSFont) {
        withEditor { textView in
            guard let textStorage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let fallbackFont = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)

            if selection.length == 0 {
                var attributes = textView.typingAttributes
                let typingFont = attributes[.font] as? NSFont ?? fallbackFont
                attributes[.font] = convert(typingFont, typingFont)
                textView.typingAttributes = attributes
                scheduleFormattingUpdate()
                return
            }

            let ranges = textView.selectedRanges
            guard textView.shouldChangeText(inRanges: ranges, replacementStrings: nil) else { return }
            let selectionFont = textStorage.attribute(.font, at: selection.location, effectiveRange: nil)
                as? NSFont ?? fallbackFont

            textStorage.beginEditing()
            for range in ranges {
                textStorage.enumerateAttribute(.font, in: range.rangeValue) { value, run, _ in
                    let font = value as? NSFont ?? fallbackFont
                    textStorage.addAttribute(.font, value: convert(font, selectionFont), range: run)
                }
            }
            textStorage.endEditing()
            textView.didChangeText()
        }
    }

    private func allParagraphsHaveListMarkers(_ ranges: [NSRange], in storage: NSTextStorage) -> Bool {
        !ranges.isEmpty && ranges.allSatisfy { range in
            storage.attribute(DocxEditorAttribute.listMarker, at: range.location, effectiveRange: nil) != nil
        }
    }

    private func selectedParagraphRanges(in textView: NSTextView) -> [NSRange] {
        guard let textStorage = textView.textStorage,
              textStorage.length > 0 else {
            return []
        }
        let selection = textView.selectedRange()
        let plainText = textStorage.string as NSString

        // A final empty paragraph can share the last newline with the
        // populated paragraph before it. Its distinct model identity lets the
        // bullet button target that empty line alone.
        if selection.length == 0,
           selection.location == textStorage.length,
           let lastScalar = UnicodeScalar(
               plainText.character(at: textStorage.length - 1)
           ),
           CharacterSet.newlines.contains(lastScalar) {
            var paragraphStart = 0
            var paragraphEnd = 0
            var contentsEnd = 0
            plainText.getParagraphStart(
                &paragraphStart,
                end: &paragraphEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: textStorage.length - 1, length: 0)
            )
            let populatedID = textStorage.attribute(
                DocxEditorAttribute.paragraphID,
                at: paragraphStart,
                effectiveRange: nil
            ) as? String
            let trailingID = textStorage.attribute(
                DocxEditorAttribute.paragraphID,
                at: textStorage.length - 1,
                effectiveRange: nil
            ) as? String
            if contentsEnd > paragraphStart,
               let trailingID,
               trailingID != populatedID {
                return [NSRange(location: textStorage.length - 1, length: 1)]
            }
        }

        let location = min(selection.location, textStorage.length - 1)
        let endLocation = min(NSMaxRange(selection), textStorage.length)
        let lookupLength = max(endLocation - location, 0)
        let enclosingRange = plainText.paragraphRange(
            for: NSRange(location: location, length: lookupLength)
        )
        var ranges: [NSRange] = []
        var cursor = enclosingRange.location
        while cursor < NSMaxRange(enclosingRange) {
            var paragraphStart = 0
            var paragraphEnd = 0
            var contentsEnd = 0
            plainText.getParagraphStart(
                &paragraphStart,
                end: &paragraphEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            let range = NSRange(
                location: paragraphStart,
                length: paragraphEnd - paragraphStart
            )
            if range.length > 0 {
                ranges.append(range)
            }
            cursor = max(paragraphEnd, cursor + 1)
        }
        return ranges
    }
}

private struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    let pageLayout: DocumentPageLayout
    let controller: RichTextEditorController
    let validateEdit: (NSAttributedString, [NSRange], [String]?) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, controller: controller, validateEdit: validateEdit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PagedEditorScrollView()
        let textView = PagedTextView(pageLayout: pageLayout)

        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textColor = .black
        textView.insertionPointColor = .black
        textView.textStorage?.setAttributedString(text)
        if text.string == "\n" {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        textView.repaginate()

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 2
        scrollView.documentView = textView
        scrollView.pagedTextView = textView

        controller.textView = textView
        controller.scrollView = scrollView
        controller.scheduleFormattingUpdate()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // SwiftUI can reuse this representable when an untitled document is
        // replaced by one opened from the app. Keep the coordinator connected
        // to the current document rather than its original binding.
        context.coordinator.updateBinding($text, validateEdit: validateEdit)

        guard let textView = scrollView.documentView as? PagedTextView else { return }
        textView.apply(pageLayout: pageLayout)

        guard !textView.attributedString().isEqual(to: text) else { return }

        let selection = textView.selectedRange()
        context.coordinator.isApplyingExternalUpdate = true
        textView.textStorage?.setAttributedString(text)
        let location = min(selection.location, text.length)
        let length = min(selection.length, text.length - location)
        textView.setSelectedRange(NSRange(location: location, length: length))
        context.coordinator.isApplyingExternalUpdate = false
        controller.scheduleFormattingUpdate()
        textView.repaginate()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? NSTextView)?.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: NSAttributedString
        private let controller: RichTextEditorController
        private var validateEdit: (NSAttributedString, [NSRange], [String]?) -> Bool
        var isApplyingExternalUpdate = false

        init(
            text: Binding<NSAttributedString>,
            controller: RichTextEditorController,
            validateEdit: @escaping (NSAttributedString, [NSRange], [String]?) -> Bool
        ) {
            _text = text
            self.controller = controller
            self.validateEdit = validateEdit
        }

        func updateBinding(
            _ text: Binding<NSAttributedString>,
            validateEdit: @escaping (NSAttributedString, [NSRange], [String]?) -> Bool
        ) {
            _text = text
            self.validateEdit = validateEdit
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            isApplyingExternalUpdate || validateEdit(
                textView.attributedString(),
                affectedRanges.map(\.rangeValue),
                replacementStrings
            )
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            commandSelector == #selector(NSTextView.insertNewline(_:))
                && controller.endListIfEmpty()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.scheduleFormattingUpdate()
        }

        func textViewDidChangeTypingAttributes(_ notification: Notification) {
            controller.scheduleFormattingUpdate()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate,
                  let textView = notification.object as? NSTextView
            else {
                return
            }

            text = textView.attributedString().copy() as! NSAttributedString
            // Reconcile stable paragraph metadata immediately, and restore the
            // accepted projection if a rich edit failed the final validation.
            if !textView.attributedString().isEqual(to: text) {
                let selection = textView.selectedRange()
                isApplyingExternalUpdate = true
                textView.textStorage?.setAttributedString(text)
                let location = min(selection.location, text.length)
                textView.setSelectedRange(NSRange(
                    location: location,
                    length: min(selection.length, text.length - location)
                ))
                isApplyingExternalUpdate = false
            }
            controller.scheduleFormattingUpdate()
            (textView as? PagedTextView)?.schedulePagination()
        }
    }
}
