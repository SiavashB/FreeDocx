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

    private var wordCount: Int {
        document.attributedText.string.split { $0.isWhitespace || $0.isNewline }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            FormattingToolbar(controller: editorController)
            Divider()

            if let message = document.pendingEditMessage {
                PendingEditBanner(message: message)
                Divider()
            }

            RichTextEditor(
                text: $document.attributedText,
                pageLayout: document.pageLayout,
                controller: editorController
            )

            Divider()
            HStack(spacing: 12) {
                Spacer()
                Text("\(wordCount) \(wordCount == 1 ? "word" : "words")")
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
    }
}

/// Warns the user that the last edit was rejected by the Word model and
/// that saving is blocked until the edit is undone or removed.
private struct PendingEditBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange)
            .accessibilityLabel("Pending edit problem: \(message)")
    }
}

private struct FormattingToolbar: View {
    @ObservedObject var controller: RichTextEditorController

    var body: some View {
        HStack(spacing: 4) {
            Group {
                Button(action: controller.toggleBold) {
                    Image(systemName: "bold")
                }
                .keyboardShortcut("b", modifiers: .command)
                .help("Bold (⌘B)")

                Button(action: controller.toggleItalic) {
                    Image(systemName: "italic")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("Italic (⌘I)")

                Button(action: controller.toggleUnderline) {
                    Image(systemName: "underline")
                }
                .keyboardShortcut("u", modifiers: .command)
                .help("Underline (⌘U)")
            }

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 4)

            Group {
                Button(action: controller.alignLeft) {
                    Image(systemName: "text.alignleft")
                }
                .help("Align Left")

                Button(action: controller.alignCenter) {
                    Image(systemName: "text.aligncenter")
                }
                .help("Align Center")

                Button(action: controller.alignRight) {
                    Image(systemName: "text.alignright")
                }
                .help("Align Right")
            }

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 4)

            Button(action: controller.toggleBulletedList) {
                Image(systemName: "list.bullet")
            }
            .help("Add or Remove Bullets")

            Spacer()

            Button(action: controller.showFonts) {
                Label("Fonts", systemImage: "textformat")
            }
            .help("Show the system font panel")

            Button(action: controller.showColors) {
                Label("Color", systemImage: "paintpalette")
            }
            .help("Show the system color panel")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

@MainActor
final class RichTextEditorController: ObservableObject {
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?

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
            guard let textStorage = textView.textStorage,
                  textStorage.length > 0 else {
                return
            }
            let ranges = selectedParagraphRanges(in: textView)
            guard !ranges.isEmpty else { return }

            let allBulleted = ranges.allSatisfy { range in
                textStorage.attribute(
                    DocxEditorAttribute.listMarker,
                    at: range.location,
                    effectiveRange: nil
                ) != nil
            }
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
        withEditor { textView in
            let selection = textView.selectedRange()
            let fontManager = NSFontManager.shared
            let fallbackFont = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let currentFont: NSFont

            if selection.length == 0 {
                currentFont = textView.typingAttributes[.font] as? NSFont ?? fallbackFont
            } else {
                currentFont = textView.textStorage?.attribute(
                    .font,
                    at: selection.location,
                    effectiveRange: nil
                ) as? NSFont ?? fallbackFont
            }

            let shouldRemove = fontManager.traits(of: currentFont).contains(trait)
            let convert: (NSFont) -> NSFont = { font in
                if shouldRemove {
                    return fontManager.convert(font, toNotHaveTrait: trait)
                }
                return fontManager.convert(font, toHaveTrait: trait)
            }

            if selection.length == 0 {
                var attributes = textView.typingAttributes
                attributes[.font] = convert(currentFont)
                textView.typingAttributes = attributes
                return
            }

            guard textView.shouldChangeText(in: selection, replacementString: nil),
                  let textStorage = textView.textStorage
            else {
                return
            }

            textStorage.beginEditing()
            textStorage.enumerateAttribute(.font, in: selection) { value, range, _ in
                textStorage.addAttribute(.font, value: convert(value as? NSFont ?? fallbackFont), range: range)
            }
            textStorage.endEditing()
            textView.didChangeText()
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

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
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
        textView.usesFontPanel = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textColor = .black
        textView.insertionPointColor = .black
        textView.textStorage?.setAttributedString(text)
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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // SwiftUI can reuse this representable when an untitled document is
        // replaced by one opened from the app. Keep the coordinator connected
        // to the current document rather than its original binding.
        context.coordinator.updateBinding($text)

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
        textView.repaginate()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? NSTextView)?.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: NSAttributedString
        var isApplyingExternalUpdate = false

        init(text: Binding<NSAttributedString>) {
            _text = text
        }

        func updateBinding(_ text: Binding<NSAttributedString>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate,
                  let textView = notification.object as? NSTextView
            else {
                return
            }

            text = textView.attributedString().copy() as! NSAttributedString
            if let pagedTextView = textView as? PagedTextView {
                DispatchQueue.main.async {
                    pagedTextView.repaginate()
                }
            }
        }
    }
}
