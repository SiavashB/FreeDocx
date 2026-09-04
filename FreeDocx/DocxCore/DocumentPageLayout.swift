//
//  DocumentPageLayout.swift
//  FreeDocx
//

import AppKit
import Foundation

/// The physical page geometry stored in a Word document, expressed in points.
struct DocumentPageLayout: Sendable, Equatable {
    static let letter = DocumentPageLayout(
        paperSize: CGSize(width: 612, height: 792),
        topMargin: 72,
        rightMargin: 72,
        bottomMargin: 72,
        leftMargin: 72
    )

    var paperSize: CGSize
    var topMargin: CGFloat
    var rightMargin: CGFloat
    var bottomMargin: CGFloat
    var leftMargin: CGFloat

    init(
        paperSize: CGSize,
        topMargin: CGFloat,
        rightMargin: CGFloat,
        bottomMargin: CGFloat,
        leftMargin: CGFloat
    ) {
        let fallback = CGSize(width: 612, height: 792)
        let resolvedPaperSize = Self.validPaperSize(paperSize) ?? fallback
        let horizontalMargins = Self.normalizedMargins(
            first: Self.validMargin(leftMargin) ?? 72,
            second: Self.validMargin(rightMargin) ?? 72,
            availableLength: resolvedPaperSize.width
        )
        let verticalMargins = Self.normalizedMargins(
            first: Self.validMargin(topMargin) ?? 72,
            second: Self.validMargin(bottomMargin) ?? 72,
            availableLength: resolvedPaperSize.height
        )

        self.paperSize = resolvedPaperSize
        self.topMargin = verticalMargins.first
        self.rightMargin = horizontalMargins.second
        self.bottomMargin = verticalMargins.second
        self.leftMargin = horizontalMargins.first
    }

    init(documentAttributes: NSDictionary?) {
        let fallback = Self.letter
        let paperSize = (documentAttributes?[NSAttributedString.DocumentAttributeKey.paperSize] as? NSValue)?.sizeValue

        self.init(
            paperSize: paperSize ?? fallback.paperSize,
            topMargin: Self.number(for: .topMargin, in: documentAttributes) ?? fallback.topMargin,
            rightMargin: Self.number(for: .rightMargin, in: documentAttributes) ?? fallback.rightMargin,
            bottomMargin: Self.number(for: .bottomMargin, in: documentAttributes) ?? fallback.bottomMargin,
            leftMargin: Self.number(for: .leftMargin, in: documentAttributes) ?? fallback.leftMargin
        )
    }

    var documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] {
        [
            .paperSize: NSValue(size: paperSize),
            .topMargin: topMargin,
            .rightMargin: rightMargin,
            .bottomMargin: bottomMargin,
            .leftMargin: leftMargin
        ]
    }

    private static func number(
        for key: NSAttributedString.DocumentAttributeKey,
        in attributes: NSDictionary?
    ) -> CGFloat? {
        (attributes?[key] as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    private static func validPaperSize(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite,
              size.height.isFinite,
              (72...14_400).contains(size.width),
              (72...14_400).contains(size.height) else {
            return nil
        }
        return size
    }

    private static func validMargin(_ margin: CGFloat) -> CGFloat? {
        guard margin.isFinite, margin >= 0 else { return nil }
        return margin
    }

    private static func normalizedMargins(
        first: CGFloat,
        second: CGFloat,
        availableLength: CGFloat
    ) -> (first: CGFloat, second: CGFloat) {
        let maximumTotal = max(availableLength - 1, 0)
        let total = first + second
        guard total > maximumTotal, total > 0 else { return (first, second) }
        let scale = maximumTotal / total
        return (first * scale, second * scale)
    }
}
