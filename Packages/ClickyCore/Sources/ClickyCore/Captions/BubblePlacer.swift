//
//  BubblePlacer.swift
//  ClickyCore
//
//  Where the caption bubble sits next to the companion, in CG points.
//  Four slots around the companion (gap 10): right-below, right-above,
//  left-below, left-above. The current slot is kept until it overlaps
//  something or leaves the screen (so a jittering companion doesn't make
//  the bubble hop); then the first free slot wins; if none is free the
//  bubble docks at the top centre of the screen with a leader line.
//  Everything stays inside the visible frame inset by 8. Avoided: the
//  companion (+4), 24×24 around the mouse, the POINT target, marks, and
//  this segment's upcoming targets. While the companion flies it stays put.
//  A slot that covers on-screen text (AX / OCR text bounds) is skipped too,
//  so the bubble never sits on a table's rows (only leaf text counts: a row
//  frame around its cells is seen through); the dock ignores text (it's
//  the last resort) but still keeps clear of the other obstacles.
//

import CoreGraphics
import Foundation

public enum BubbleSlot: String, CaseIterable, Sendable {
    case rightBelow, rightAbove, leftBelow, leftAbove, dockedTop
}

public struct BubblePlacement: Equatable, Sendable {
    public let rect: CGRect
    public let slot: BubbleSlot
    /// From the bubble to the companion when docked.
    public let leaderLine: (start: CGPoint, end: CGPoint)?

    public static func == (first: BubblePlacement, second: BubblePlacement) -> Bool {
        first.rect == second.rect && first.slot == second.slot
            && first.leaderLine?.start == second.leaderLine?.start && first.leaderLine?.end == second.leaderLine?.end
    }
}

public enum BubblePlacer {
    public static let gap: CGFloat = 10
    public static let screenInset: CGFloat = 8
    public static let companionMargin: CGFloat = 4
    public static let mouseBoxSize: CGFloat = 24

    public struct Input: Sendable {
        public var companionRect: CGRect
        public var bubbleSize: CGSize
        /// Visible frames (menu bar / Dock / notch excluded) of every display.
        public var visibleFrames: [CGRect]
        public var mouseLocation: CGPoint?
        /// POINT target, marks, upcoming targets of this segment.
        public var obstacles: [CGRect]
        /// On-screen text near the companion: slots that cover it are skipped.
        public var textObstacles: [CGRect]
        public var isCompanionFlying: Bool
        public var previous: BubblePlacement?

        public init(companionRect: CGRect, bubbleSize: CGSize, visibleFrames: [CGRect], mouseLocation: CGPoint? = nil,
                    obstacles: [CGRect] = [], textObstacles: [CGRect] = [], isCompanionFlying: Bool = false, previous: BubblePlacement? = nil) {
            self.textObstacles = textObstacles
            self.companionRect = companionRect
            self.bubbleSize = bubbleSize
            self.visibleFrames = visibleFrames
            self.mouseLocation = mouseLocation
            self.obstacles = obstacles
            self.isCompanionFlying = isCompanionFlying
            self.previous = previous
        }
    }

    public static func place(_ input: Input) -> BubblePlacement {
        if input.isCompanionFlying, let previous = input.previous { return previous }
        let companionCenter = input.companionRect.center
        let visible = (input.visibleFrames.first { $0.contains(companionCenter) }
            ?? input.visibleFrames.min { $0.edgeDistance(to: companionCenter) < $1.edgeDistance(to: companionCenter) }
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: screenInset, dy: screenInset)

        var avoided = input.obstacles
        avoided.append(input.companionRect.insetBy(dx: -companionMargin, dy: -companionMargin))
        if let mouseLocation = input.mouseLocation {
            avoided.append(CGRect(x: mouseLocation.x - mouseBoxSize / 2, y: mouseLocation.y - mouseBoxSize / 2, width: mouseBoxSize, height: mouseBoxSize))
        }

        // Containers (an AX row around its cells' text) are seen through, as for marks.
        let nearbyText = MarkDensity.leafTextBounds(input.textObstacles)
        func isFree(_ rect: CGRect) -> Bool {
            visible.contains(rect) && !avoided.contains { $0.intersects(rect) } && !nearbyText.contains { $0.intersects(rect) }
        }

        // Keep the current slot while it still works.
        if let previous = input.previous, previous.slot != .dockedTop {
            let candidate = rect(for: previous.slot, size: input.bubbleSize, companion: input.companionRect)
            if isFree(candidate) { return BubblePlacement(rect: candidate, slot: previous.slot, leaderLine: nil) }
        }
        for slot in [BubbleSlot.rightBelow, .rightAbove, .leftBelow, .leftAbove] {
            let candidate = rect(for: slot, size: input.bubbleSize, companion: input.companionRect)
            if isFree(candidate) { return BubblePlacement(rect: candidate, slot: slot, leaderLine: nil) }
        }
        // Dock at the top centre, moved down past anything it would cover.
        let width = min(input.bubbleSize.width, visible.width)
        let height = min(input.bubbleSize.height, visible.height)
        var docked = CGRect(x: visible.midX - width / 2, y: visible.minY, width: width, height: height)
        for _ in 0..<20 where avoided.contains(where: { $0.intersects(docked) }) {
            guard let blocker = avoided.filter({ $0.intersects(docked) }).max(by: { $0.maxY < $1.maxY }),
                  blocker.maxY + gap + height <= visible.maxY else { break }
            docked.origin.y = blocker.maxY + gap
        }
        let leaderStart = CGPoint(x: docked.midX, y: docked.maxY)
        return BubblePlacement(rect: docked, slot: .dockedTop, leaderLine: (leaderStart, companionCenter))
    }

    public static func rect(for slot: BubbleSlot, size: CGSize, companion: CGRect) -> CGRect {
        switch slot {
        case .rightBelow: return CGRect(x: companion.maxX + gap, y: companion.maxY + gap, width: size.width, height: size.height)
        case .rightAbove: return CGRect(x: companion.maxX + gap, y: companion.minY - gap - size.height, width: size.width, height: size.height)
        case .leftBelow: return CGRect(x: companion.minX - gap - size.width, y: companion.maxY + gap, width: size.width, height: size.height)
        case .leftAbove: return CGRect(x: companion.minX - gap - size.width, y: companion.minY - gap - size.height, width: size.width, height: size.height)
        case .dockedTop: return CGRect(origin: companion.origin, size: size)
        }
    }
}

#if canImport(AppKit)
import AppKit

extension BubblePlacer {
    /// The bubble's size for `caption`: text measured at 15 pt in the
    /// bubble's width, capped at `maxLines`, plus padding and the marks'
    /// legend rows. The size doesn't change as words are revealed
    /// (unrevealed text is drawn, just dimmed); it grows once per new mark.
    public static func estimatedBubbleSize(for caption: CaptionState, maxWidth: CGFloat, maxLines: Int) -> CGSize {
        let font = NSFont.systemFont(ofSize: CaptionBubbleMetrics.fontSize, weight: .medium)
        let text: String
        if let statusText = caption.statusText {
            text = statusText
        } else {
            text = [caption.previous?.display, caption.current?.display].compactMap { $0 }.joined(separator: " ")
        }
        let textWidth = maxWidth - 2 * CaptionBubbleMetrics.horizontalPadding
        let bounds = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: textWidth, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var height = min(ceil(bounds.height), lineHeight * CGFloat(maxLines))
        let width = caption.statusText != nil ? ceil(bounds.width) : textWidth
        if caption.statusText == nil { height += CaptionBubbleMetrics.legendHeight(rowCount: caption.markLegend.count) }
        return CGSize(width: width + 2 * CaptionBubbleMetrics.horizontalPadding, height: height + 2 * CaptionBubbleMetrics.verticalPadding)
    }
}
#endif
