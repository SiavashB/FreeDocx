//
//  PagedTextView.swift
//  FreeDocx
//

import AppKit

/// A TextKit container that flows text through equally sized page bodies while
/// skipping each page's bottom margin, the visual page gap, and the following
/// page's top margin.
@MainActor
final class PagedTextContainer: NSTextContainer {
    var pageHeight: CGFloat = 792
    var bodyHeight: CGFloat = 648
    var pageGap: CGFloat = 28

    private var pageStride: CGFloat {
        max(pageHeight + pageGap, 1)
    }

    override var isSimpleRectangularTextContainer: Bool {
        false
    }

    override func lineFragmentRect(
        forProposedRect proposedRect: NSRect,
        at characterIndex: Int,
        writingDirection baseWritingDirection: NSWritingDirection,
        remaining remainingRect: UnsafeMutablePointer<NSRect>?
    ) -> NSRect {
        var adjustedRect = proposedRect
        let stride = pageStride
        let page = max(floor(adjustedRect.minY / stride), 0)
        let pageStart = page * stride
        let bodyEnd = pageStart + max(bodyHeight, 1)

        if adjustedRect.minY >= bodyEnd
            || (adjustedRect.minY > pageStart && adjustedRect.maxY > bodyEnd) {
            adjustedRect.origin.y = (page + 1) * stride
        }

        var result = super.lineFragmentRect(
            forProposedRect: adjustedRect,
            at: characterIndex,
            writingDirection: baseWritingDirection,
            remaining: remainingRect
        )

        let resultPage = max(floor(result.minY / stride), 0)
        let resultBodyEnd = resultPage * stride + max(bodyHeight, 1)
        result.size.height = min(result.height, max(resultBodyEnd - result.minY, 0))
        remainingRect?.pointee = .zero
        return result
    }
}

/// A single rich text view that draws Word-like pages behind a continuous
/// TextKit editing surface.
@MainActor
final class PagedTextView: NSTextView {
    static let pageGap: CGFloat = 28
    static let canvasPadding: CGFloat = 32

    private(set) var pageLayout: DocumentPageLayout
    private(set) var pageCount = 1
    private var viewportWidth: CGFloat = 0

    private var pagedTextContainer: PagedTextContainer {
        textContainer as! PagedTextContainer
    }

    private var effectiveMargins: (top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat) {
        (
            pageLayout.topMargin,
            pageLayout.rightMargin,
            pageLayout.bottomMargin,
            pageLayout.leftMargin
        )
    }

    private var pageOriginX: CGFloat {
        max(Self.canvasPadding, (bounds.width - pageLayout.paperSize.width) / 2)
    }

    init(pageLayout: DocumentPageLayout) {
        self.pageLayout = pageLayout

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = PagedTextContainer(size: NSSize(width: 468, height: 100_000_000))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        super.init(frame: .zero, textContainer: textContainer)

        // A printed Word page stays light even when the surrounding app uses
        // Dark Mode. Keep the editor in Aqua so AppKit's dynamic text and
        // background colors resolve for white paper, while the scroll view,
        // toolbar, and window continue to follow the system appearance.
        appearance = NSAppearance(named: .aqua)
        drawsBackground = true
        backgroundColor = .clear
        isHorizontallyResizable = false
        isVerticallyResizable = false
        autoresizingMask = []
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        configureForCurrentPageLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(pageLayout: DocumentPageLayout) {
        guard self.pageLayout != pageLayout else { return }
        self.pageLayout = pageLayout
        configureForCurrentPageLayout()
        repaginate()
    }

    func resize(forViewportWidth width: CGFloat) {
        let normalizedWidth = max(width, 0)
        guard abs(viewportWidth - normalizedWidth) > 0.5 else { return }
        viewportWidth = normalizedWidth
        updateFrameSize()
    }

    func repaginate() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).maxY
        let stride = max(pageLayout.paperSize.height + Self.pageGap, 1)
        let newPageCount = max(Int(floor(max(usedHeight - 0.5, 0) / stride)) + 1, 1)

        if pageCount != newPageCount {
            pageCount = newPageCount
            updateFrameSize()
        } else {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.86, alpha: 1).setFill()
        dirtyRect.fill()

        let stride = pageLayout.paperSize.height + Self.pageGap
        let firstVisiblePage = max(
            Int(floor((dirtyRect.minY - Self.canvasPadding) / stride)),
            0
        )
        let lastVisiblePage = min(
            Int(floor((dirtyRect.maxY - Self.canvasPadding) / stride)),
            pageCount - 1
        )

        if firstVisiblePage <= lastVisiblePage {
            for pageIndex in firstVisiblePage...lastVisiblePage {
                let pageRect = NSRect(
                    x: pageOriginX,
                    y: Self.canvasPadding + CGFloat(pageIndex) * (pageLayout.paperSize.height + Self.pageGap),
                    width: pageLayout.paperSize.width,
                    height: pageLayout.paperSize.height
                )
                guard pageRect.intersects(dirtyRect) else { continue }

                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
                shadow.shadowBlurRadius = 5
                shadow.shadowOffset = NSSize(width: 0, height: 1)
                shadow.set()
                NSColor.white.setFill()
                pageRect.fill()
                NSGraphicsContext.restoreGraphicsState()

                NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
                pageRect.frame(withWidth: 0.5)
            }
        }

        super.draw(dirtyRect)
        drawListMarkers(in: dirtyRect)
        drawSectionRules(in: dirtyRect)
    }

    private func drawListMarkers(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else {
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let textOrigin = textContainerOrigin
        let plainText = textStorage.string as NSString
        var location = 0
        while location < textStorage.length {
            var paragraphStart = 0
            var paragraphEnd = 0
            var contentsEnd = 0
            plainText.getParagraphStart(
                &paragraphStart,
                end: &paragraphEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            guard let marker = textStorage.attribute(
                DocxEditorAttribute.listMarker,
                at: paragraphStart,
                effectiveRange: nil
            ) as? String else {
                location = max(paragraphEnd, location + 1)
                continue
            }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: paragraphStart, length: 1),
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else {
                location = max(paragraphEnd, location + 1)
                continue
            }

            let lineFragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            drawListMarker(
                marker,
                attributeLocation: paragraphStart,
                lineFragment: lineFragment,
                textOrigin: textOrigin,
                dirtyRect: dirtyRect
            )
            location = max(paragraphEnd, location + 1)
        }

        drawTrailingEmptyListMarker(
            textOrigin: textOrigin,
            dirtyRect: dirtyRect
        )
    }

    private func drawTrailingEmptyListMarker(
        textOrigin: NSPoint,
        dirtyRect: NSRect
    ) {
        guard let layoutManager,
              let textStorage,
              textStorage.length > 0,
              let lastScalar = UnicodeScalar(
                  (textStorage.string as NSString).character(at: textStorage.length - 1)
              ),
              CharacterSet.newlines.contains(lastScalar),
              layoutManager.extraLineFragmentTextContainer != nil else {
            return
        }

        let plainText = textStorage.string as NSString
        var paragraphStart = 0
        var paragraphEnd = 0
        var contentsEnd = 0
        plainText.getParagraphStart(
            &paragraphStart,
            end: &paragraphEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: textStorage.length - 1, length: 0)
        )
        let populatedParagraphID = textStorage.attribute(
            DocxEditorAttribute.paragraphID,
            at: paragraphStart,
            effectiveRange: nil
        ) as? String
        let trailingParagraphID = textStorage.attribute(
            DocxEditorAttribute.paragraphID,
            at: textStorage.length - 1,
            effectiveRange: nil
        ) as? String

        guard contentsEnd > paragraphStart,
              let trailingParagraphID,
              trailingParagraphID != populatedParagraphID,
              let marker = textStorage.attribute(
                  DocxEditorAttribute.listMarker,
                  at: textStorage.length - 1,
                  effectiveRange: nil
              ) as? String else {
            return
        }

        drawListMarker(
            marker,
            attributeLocation: textStorage.length - 1,
            lineFragment: layoutManager.extraLineFragmentRect,
            textOrigin: textOrigin,
            dirtyRect: dirtyRect
        )
    }

    private func drawListMarker(
        _ marker: String,
        attributeLocation: Int,
        lineFragment: NSRect,
        textOrigin: NSPoint,
        dirtyRect: NSRect
    ) {
        guard let textStorage else { return }
        let style = textStorage.attribute(
            .paragraphStyle,
            at: attributeLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let markerIndent = (
            textStorage.attribute(
                DocxEditorAttribute.listMarkerIndent,
                at: attributeLocation,
                effectiveRange: nil
            ) as? NSNumber
        )?.doubleValue
        let font = textStorage.attribute(
            .font,
            at: attributeLocation,
            effectiveRange: nil
        ) as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let color = textStorage.attribute(
            .foregroundColor,
            at: attributeLocation,
            effectiveRange: nil
        ) as? NSColor ?? .textColor
        let markerOrigin = NSPoint(
            x: textOrigin.x + CGFloat(markerIndent ?? Double(style?.firstLineHeadIndent ?? 0)),
            y: textOrigin.y + lineFragment.minY
                + max((lineFragment.height - font.boundingRectForFont.height) / 2, 0)
        )
        let markerRect = NSRect(
            origin: markerOrigin,
            size: (marker as NSString).size(withAttributes: [.font: font])
        )
        if markerRect.intersects(dirtyRect) {
            (marker as NSString).draw(
                at: markerOrigin,
                withAttributes: [.font: font, .foregroundColor: color]
            )
        }
    }

    private func drawSectionRules(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer, textStorage?.length ?? 0 > 0 else {
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let textOrigin = textContainerOrigin
        let contentWidth = textContainer.size.width
        let fullRange = NSRange(location: 0, length: textStorage?.length ?? 0)

        textStorage?.enumerateAttribute(
            DocxEditorAttribute.sectionRule,
            in: fullRange
        ) { value, characterRange, _ in
            guard let color = value as? NSColor, characterRange.length > 0 else {
                return
            }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return }

            let lastGlyph = NSMaxRange(glyphRange) - 1
            let lineFragment = layoutManager.lineFragmentRect(
                forGlyphAt: lastGlyph,
                effectiveRange: nil
            )
            let y = textOrigin.y + lineFragment.maxY + 1
            let ruleRect = NSRect(
                x: textOrigin.x,
                y: y,
                width: contentWidth,
                height: 1
            )
            guard ruleRect.intersects(dirtyRect) else { return }

            color.setStroke()
            let rule = NSBezierPath()
            rule.lineWidth = 0.75
            rule.move(to: NSPoint(x: ruleRect.minX, y: y))
            rule.line(to: NSPoint(x: ruleRect.maxX, y: y))
            rule.stroke()
        }
    }

    private func configureForCurrentPageLayout() {
        let margins = effectiveMargins
        let bodyWidth = max(pageLayout.paperSize.width - margins.left - margins.right, 1)
        let bodyHeight = max(pageLayout.paperSize.height - margins.top - margins.bottom, 1)

        pagedTextContainer.size = NSSize(width: bodyWidth, height: 100_000_000)
        pagedTextContainer.pageHeight = pageLayout.paperSize.height
        pagedTextContainer.bodyHeight = bodyHeight
        pagedTextContainer.pageGap = Self.pageGap
        textContainerInset = NSSize(
            width: pageOriginX + margins.left,
            height: Self.canvasPadding + margins.top
        )
        layoutManager?.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: string.utf16.count),
            actualCharacterRange: nil
        )
        updateFrameSize()
    }

    private func updateFrameSize() {
        let minimumWidth = pageLayout.paperSize.width + Self.canvasPadding * 2
        let width = max(minimumWidth, viewportWidth)
        let height = Self.canvasPadding * 2
            + CGFloat(pageCount) * pageLayout.paperSize.height
            + CGFloat(max(pageCount - 1, 0)) * Self.pageGap

        setFrameSize(NSSize(width: width, height: height))

        let margins = effectiveMargins
        textContainerInset = NSSize(
            width: pageOriginX + margins.left,
            height: Self.canvasPadding + margins.top
        )
        needsDisplay = true
    }
}

@MainActor
final class PagedEditorScrollView: NSScrollView {
    weak var pagedTextView: PagedTextView?

    override func layout() {
        super.layout()
        pagedTextView?.resize(forViewportWidth: contentView.bounds.width)
    }
}
