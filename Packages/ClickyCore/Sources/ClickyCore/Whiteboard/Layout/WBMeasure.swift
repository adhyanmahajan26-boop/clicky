//
//  WBMeasure.swift
//  ClickyCore
//
//  How big each whiteboard element is before it is placed. Text is measured
//  with NSAttributedString.boundingRect (.usesLineFragmentOrigin |
//  .usesFontLeading) and ceil'd, in the board's hand font (ChalkboardSE-
//  Regular when installed, else the rounded system font):
//   - box / callout: wraps at 220 pt, 16 pt padding; ellipse: that box ×√2
//     so the text rect fits inside the ellipse
//   - text: wraps at 420 pt; code: monospaced, never wrapped
//   - math: `mathSizeProvider` (the app sets it to SwiftMath); default is the
//     TeX source measured monospaced
//   - chart: fixed 320 × 200; table: column widths × row heights; list:
//     items stacked
//  No font is ever below 15 pt. Results are cached (same input → same size).
//

import AppKit
import CoreGraphics

public enum WBMeasure {
    public static let minimumFontSize: CGFloat = 15
    public static let boxWrapWidth: CGFloat = 220
    public static let boxPadding: CGFloat = 16
    public static let boxFontSize: CGFloat = 17
    public static let minimumBoxSize = CGSize(width: 64, height: 44)
    public static let textWrapWidth: CGFloat = 420
    public static let textFontSize: CGFloat = 19
    public static let textPadding: CGFloat = 4
    public static let codeFontSize: CGFloat = 15
    public static let codePadding: CGFloat = 12
    public static let mathFontSize: CGFloat = 20
    public static let mathPadding: CGFloat = 8
    public static let chartSize = CGSize(width: 320, height: 200)
    public static let tableFontSize: CGFloat = 15
    public static let tableCellHorizontalPadding: CGFloat = 10
    public static let tableCellVerticalPadding: CGFloat = 6
    public static let listWrapWidth: CGFloat = 320
    public static let listFontSize: CGFloat = 16
    public static let listItemSpacing: CGFloat = 6
    public static let listPadding: CGFloat = 10
    public static let edgeLabelFontSize: CGFloat = 15
    public static let edgeLabelHorizontalPadding: CGFloat = 6
    public static let edgeLabelVerticalPadding: CGFloat = 3
    public static let edgeLabelWrapWidth: CGFloat = 180
    public static let handwrittenFontName = "ChalkboardSE-Regular"
    static let unboundedWidth: CGFloat = 100_000

    /// Set by the app to measure rendered math (SwiftMath); arguments are the
    /// TeX source and font size. nil → monospaced source measurement.
    nonisolated(unsafe) public static var mathSizeProvider: ((_ texSource: String, _ fontSize: CGFloat) -> CGSize)?

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var sizeCache: [String: CGSize] = [:]
    nonisolated(unsafe) private static var fontCache: [String: NSFont] = [:]

    // MARK: Fonts

    /// The board's text font: SF Pro (medium) for a clean, modern look. Measuring and drawing both go through here.
    public static func handFont(size: CGFloat) -> NSFont {
        cachedFont(key: "hand\(size)") { NSFont.systemFont(ofSize: size, weight: .medium) }
    }

    public static func monospacedFont(size: CGFloat) -> NSFont {
        cachedFont(key: "mono\(size)") { NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
    }

    private static func cachedFont(key: String, make: () -> NSFont) -> NSFont {
        cacheLock.lock()
        if let cachedFont = fontCache[key] {
            cacheLock.unlock()
            return cachedFont
        }
        cacheLock.unlock()
        let madeFont = make()
        cacheLock.lock()
        fontCache[key] = madeFont
        cacheLock.unlock()
        return madeFont
    }

    // MARK: Text

    /// boundingRect, ceil'd. Empty text measures as one line.
    public static func textSize(_ text: String, font: NSFont, maximumWidth: CGFloat) -> CGSize {
        let attributedText = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let textBounds = attributedText.boundingRect(with: CGSize(width: maximumWidth, height: 100_000),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(textBounds.width), height: ceil(textBounds.height))
    }

    static func clampedFontSize(_ requested: CGFloat?, default defaultSize: CGFloat) -> CGFloat {
        max(minimumFontSize, requested ?? defaultSize)
    }

    // MARK: Elements

    public static func size(of node: WBLayoutNode) -> CGSize {
        if let sizeHint = node.sizeHint { return CGSize(width: max(1, sizeHint.width), height: max(1, sizeHint.height)) }
        if node.kind == .chart { return chartSize }
        if node.kind == .math, let mathSizeProvider {
            let fontSize = clampedFontSize(node.fontSize, default: mathFontSize)
            let renderedSize = mathSizeProvider(node.text, fontSize)
            return CGSize(width: ceil(renderedSize.width) + 2 * mathPadding, height: ceil(renderedSize.height) + 2 * mathPadding)
        }
        let cacheKey = "\(node.kind.rawValue)|\(node.fontSize.map { "\($0)" } ?? "-")|\(node.text)|\(node.items.joined(separator: "\u{1}"))|\(node.rows.map { $0.joined(separator: "\u{1}") }.joined(separator: "\u{2}"))"
        cacheLock.lock()
        if let cachedSize = sizeCache[cacheKey] {
            cacheLock.unlock()
            return cachedSize
        }
        cacheLock.unlock()
        let measuredSize = uncachedSize(of: node)
        cacheLock.lock()
        sizeCache[cacheKey] = measuredSize
        cacheLock.unlock()
        return measuredSize
    }

    private static func uncachedSize(of node: WBLayoutNode) -> CGSize {
        switch node.kind {
        case .box, .callout:
            return boxSize(node.text, fontSize: clampedFontSize(node.fontSize, default: boxFontSize))
        case .ellipse:
            let innerBox = boxSize(node.text, fontSize: clampedFontSize(node.fontSize, default: boxFontSize))
            return CGSize(width: ceil(innerBox.width * 2.squareRoot()), height: ceil(innerBox.height * 2.squareRoot()))
        case .text:
            let font = handFont(size: clampedFontSize(node.fontSize, default: textFontSize))
            let measured = textSize(node.text, font: font, maximumWidth: textWrapWidth)
            return CGSize(width: measured.width + 2 * textPadding, height: measured.height + 2 * textPadding)
        case .code:
            let font = monospacedFont(size: clampedFontSize(node.fontSize, default: codeFontSize))
            let measured = textSize(node.text, font: font, maximumWidth: unboundedWidth)
            return CGSize(width: measured.width + 2 * codePadding, height: measured.height + 2 * codePadding)
        case .math:
            let font = monospacedFont(size: clampedFontSize(node.fontSize, default: mathFontSize))
            let measured = textSize(node.text, font: font, maximumWidth: unboundedWidth)
            return CGSize(width: measured.width + 2 * mathPadding, height: measured.height + 2 * mathPadding)
        case .chart:
            return chartSize
        case .table:
            return tableSize(node)
        case .list:
            return listSize(node)
        }
    }

    static func boxSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let measured = textSize(text, font: handFont(size: fontSize), maximumWidth: boxWrapWidth)
        return CGSize(width: max(minimumBoxSize.width, measured.width + 2 * boxPadding),
                      height: max(minimumBoxSize.height, measured.height + 2 * boxPadding))
    }

    static func tableSize(_ node: WBLayoutNode) -> CGSize {
        let tableRows = node.rows.isEmpty
            ? node.text.split(separator: "\n").map { $0.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
            : node.rows
        let font = handFont(size: clampedFontSize(node.fontSize, default: tableFontSize))
        let columnCount = tableRows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return minimumBoxSize }
        var columnWidths = [CGFloat](repeating: 0, count: columnCount)
        var totalHeight: CGFloat = 0
        for row in tableRows {
            var rowHeight: CGFloat = 0
            for (columnIndex, cell) in row.enumerated() {
                let cellSize = textSize(cell, font: font, maximumWidth: boxWrapWidth)
                columnWidths[columnIndex] = max(columnWidths[columnIndex], cellSize.width)
                rowHeight = max(rowHeight, cellSize.height)
            }
            totalHeight += rowHeight + 2 * tableCellVerticalPadding
        }
        let totalWidth = columnWidths.reduce(0, +) + CGFloat(columnCount) * 2 * tableCellHorizontalPadding
        return CGSize(width: ceil(totalWidth), height: ceil(totalHeight))
    }

    static func listSize(_ node: WBLayoutNode) -> CGSize {
        let listItems = node.items.isEmpty ? node.text.split(separator: "\n").map(String.init) : node.items
        let font = handFont(size: clampedFontSize(node.fontSize, default: listFontSize))
        var maximumWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for (itemIndex, item) in listItems.enumerated() {
            let itemSize = textSize("•  " + item, font: font, maximumWidth: listWrapWidth)
            maximumWidth = max(maximumWidth, itemSize.width)
            totalHeight += itemSize.height + (itemIndex > 0 ? listItemSpacing : 0)
        }
        if listItems.isEmpty { totalHeight = textSize(" ", font: font, maximumWidth: listWrapWidth).height }
        return CGSize(width: maximumWidth + 2 * listPadding, height: totalHeight + 2 * listPadding)
    }

    /// An edge label's pill.
    public static func edgeLabelSize(_ label: String) -> CGSize {
        let cacheKey = "edge-label|\(label)"
        cacheLock.lock()
        if let cachedSize = sizeCache[cacheKey] {
            cacheLock.unlock()
            return cachedSize
        }
        cacheLock.unlock()
        let measured = textSize(label, font: handFont(size: edgeLabelFontSize), maximumWidth: edgeLabelWrapWidth)
        let labelSize = CGSize(width: measured.width + 2 * edgeLabelHorizontalPadding, height: measured.height + 2 * edgeLabelVerticalPadding)
        cacheLock.lock()
        sizeCache[cacheKey] = labelSize
        cacheLock.unlock()
        return labelSize
    }
}
