//
//  ArticleHighlightLayout.swift
//  ClickyCore
//
//  P8 highlights on screen: each highlight is one or more line rects (CG
//  global points). Given the article's viewport (the web area's visible
//  part) this decides what is drawn: the parts of on-screen highlights,
//  clipped to the viewport, as soft yellow highlighter strokes, and for
//  each highlight that is scrolled away entirely, a small numbered tick in
//  the window's right margin: at the top when it is above, at the bottom
//  when it is below. Also the tracking math: a tracked highlight moves by
//  how far its anchor element moved (scrolling translates the whole page).
//

import CoreGraphics
import Foundation

public struct ArticleHighlightGeometry: Equatable, Sendable {
    /// 1-based, the note it belongs to.
    public var number: Int
    /// One rect per text line, CG global points.
    public var lineRects: [CGRect]

    public init(number: Int, lineRects: [CGRect]) {
        self.number = number
        self.lineRects = lineRects
    }

    public var bounds: CGRect? {
        lineRects.reduce(nil as CGRect?) { union, rect in union.map { $0.union(rect) } ?? rect }
    }

    /// Moved by `delta` (a scroll or a window move).
    public func translated(by delta: CGVector) -> ArticleHighlightGeometry {
        ArticleHighlightGeometry(number: number, lineRects: lineRects.map { $0.offsetBy(dx: delta.dx, dy: delta.dy) })
    }
}

public enum ArticleHighlightTickDirection: String, Equatable, Sendable {
    case above
    case below
}

public struct ArticleHighlightTick: Equatable, Sendable {
    public var number: Int
    public var direction: ArticleHighlightTickDirection
    /// CG global points.
    public var rect: CGRect

    public init(number: Int, direction: ArticleHighlightTickDirection, rect: CGRect) {
        self.number = number
        self.direction = direction
        self.rect = rect
    }
}

public struct ArticleHighlightLayout: Equatable, Sendable {
    /// Highlighter strokes to draw (clipped to the viewport), with their highlight's number.
    public var strokes: [(number: Int, rect: CGRect)]
    public var ticks: [ArticleHighlightTick]

    public static func == (lhs: ArticleHighlightLayout, rhs: ArticleHighlightLayout) -> Bool {
        lhs.ticks == rhs.ticks && lhs.strokes.map(\.number) == rhs.strokes.map(\.number) && lhs.strokes.map(\.rect) == rhs.strokes.map(\.rect)
    }

    public init(strokes: [(number: Int, rect: CGRect)], ticks: [ArticleHighlightTick]) {
        self.strokes = strokes
        self.ticks = ticks
    }

    public static let empty = ArticleHighlightLayout(strokes: [], ticks: [])

    public var visibleNumbers: [Int] { Array(Set(strokes.map(\.number))).sorted() }

    public static let tickSize = CGSize(width: 18, height: 12)
    public static let tickSpacing: CGFloat = 4
    /// Distance of the tick's right edge from the viewport's right edge (clear of an overlay scroll bar).
    public static let tickRightInset: CGFloat = 16
    /// Line rects get this much extra height above and below (a highlighter is a bit taller than the glyphs).
    public static let strokeVerticalPadding: CGFloat = 1
    public static let strokeHorizontalPadding: CGFloat = 1.5
    /// A highlight counts as on screen when at least this many points of a line are inside the viewport.
    public static let minimumVisibleHeight: CGFloat = 4

    /// What to draw for these highlights in this viewport.
    public static func layout(highlights: [ArticleHighlightGeometry], viewport: CGRect) -> ArticleHighlightLayout {
        var strokes: [(number: Int, rect: CGRect)] = []
        var aboveNumbers: [Int] = []
        var belowNumbers: [Int] = []
        guard viewport.width > 0, viewport.height > 0 else { return ArticleHighlightLayout(strokes: [], ticks: []) }
        for highlight in highlights.sorted(by: { $0.number < $1.number }) {
            var isVisible = false
            for lineRect in highlight.lineRects {
                let padded = lineRect.insetBy(dx: -strokeHorizontalPadding, dy: -strokeVerticalPadding)
                let clipped = padded.intersection(viewport)
                guard !clipped.isNull, clipped.height >= minimumVisibleHeight, clipped.width > 0 else { continue }
                strokes.append((highlight.number, clipped))
                isVisible = true
            }
            guard !isVisible, let bounds = highlight.bounds else { continue }
            if bounds.maxY <= viewport.minY + minimumVisibleHeight {
                aboveNumbers.append(highlight.number)
            } else if bounds.minY >= viewport.maxY - minimumVisibleHeight {
                belowNumbers.append(highlight.number)
            }
            // Beside the viewport (scrolled sideways) gets no tick.
        }
        return ArticleHighlightLayout(strokes: strokes, ticks: ticks(above: aboveNumbers, below: belowNumbers, viewport: viewport))
    }

    /// Ticks stacked down from the viewport's top-right (above) and up from its bottom-right (below).
    static func ticks(above: [Int], below: [Int], viewport: CGRect) -> [ArticleHighlightTick] {
        let x = viewport.maxX - tickRightInset - tickSize.width
        var ticks: [ArticleHighlightTick] = []
        // Both stacks keep note order top to bottom.
        for (index, number) in above.enumerated() {
            let y = viewport.minY + 6 + CGFloat(index) * (tickSize.height + tickSpacing)
            ticks.append(ArticleHighlightTick(number: number, direction: .above, rect: CGRect(origin: CGPoint(x: x, y: y), size: tickSize)))
        }
        for (index, number) in below.enumerated() {
            let fromBottom = CGFloat(below.count - 1 - index)
            let y = viewport.maxY - 6 - tickSize.height - fromBottom * (tickSize.height + tickSpacing)
            ticks.append(ArticleHighlightTick(number: number, direction: .below, rect: CGRect(origin: CGPoint(x: x, y: y), size: tickSize)))
        }
        return ticks
    }

    /// How far the page moved: the anchor element's frame now minus when the highlight was measured.
    public static func trackingDelta(originalAnchorFrame: CGRect, currentAnchorFrame: CGRect) -> CGVector {
        CGVector(dx: currentAnchorFrame.minX - originalAnchorFrame.minX, dy: currentAnchorFrame.minY - originalAnchorFrame.minY)
    }

    /// The anchor changed size (the page reflowed: a resize or zoom), so the line rects must be measured again.
    public static func needsRemeasure(originalAnchorFrame: CGRect, currentAnchorFrame: CGRect) -> Bool {
        abs(originalAnchorFrame.width - currentAnchorFrame.width) > 1 || abs(originalAnchorFrame.height - currentAnchorFrame.height) > 1
    }
}

/// When the highlight tracker runs: 10 Hz while highlights exist, never otherwise.
public enum ArticleHighlightCadence {
    public static let trackingInterval: TimeInterval = 0.1
    /// Remeasure everything at most this often (reflow, an anchor that disappeared).
    public static let minimumRemeasureInterval: TimeInterval = 0.75

    public static func shouldTrack(highlightCount: Int, isPanelOrOverlayShown: Bool) -> Bool {
        highlightCount > 0 && isPanelOrOverlayShown
    }
}
