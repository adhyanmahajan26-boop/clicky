//
//  LabelPlacer.swift
//  ClickyCore
//
//  Sizes a mark's label (15 pt semibold, 8×6 padding, max 260 pt wide) and
//  picks where it goes around its mark: the first anchor, in a fixed order,
//  that stays inside visible.insetBy(8) and touches no obstacle (other marks
//  and labels, the padded target, the companion); else the least-overlapping
//  one, pulled inside.
//

import AppKit
import CoreGraphics

public enum LabelPlacer {
    public static let fontSize: CGFloat = 15
    public static let maximumTextWidth: CGFloat = 260
    public static let horizontalPadding: CGFloat = 8
    public static let verticalPadding: CGFloat = 6
    public static let cornerRadius: CGFloat = 8
    public static let gap: CGFloat = 6
    public static let screenMargin: CGFloat = 8

    public static var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .semibold) }

    public enum Anchor: String, CaseIterable, Sendable {
        case belowLeft, belowRight, aboveLeft, aboveRight, right, left, below, above
    }

    /// Pill size for `text`, ceil'd.
    public static func size(for text: String) -> CGSize {
        let attributedText = NSAttributedString(string: text, attributes: [.font: font])
        let textBounds = attributedText.boundingRect(with: CGSize(width: maximumTextWidth, height: 10_000),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(textBounds.width) + 2 * horizontalPadding, height: ceil(textBounds.height) + 2 * verticalPadding)
    }

    /// The step number's white disc at the pill's left, and the space after it.
    public static let stepBadgeDiameter: CGFloat = 20
    public static let stepBadgeSpacing: CGFloat = 6

    /// Pill size for a step's label: the number's disc, then `text` (or the
    /// disc alone when there's no text), never shorter than a text pill.
    public static func size(for text: String?, stepNumber: Int?) -> CGSize {
        guard stepNumber != nil else { return size(for: text ?? "") }
        let textSize = text.map { size(for: $0) } ?? CGSize(width: 2 * horizontalPadding, height: size(for: "0").height)
        let badgeWidth = stepBadgeDiameter + (text == nil ? 0 : stepBadgeSpacing)
        return CGSize(width: textSize.width + badgeWidth - (text == nil ? 2 * horizontalPadding - 2 * verticalPadding : 0),
                      height: max(textSize.height, stepBadgeDiameter + 2 * verticalPadding))
    }

    public static func rect(for anchor: Anchor, size: CGSize, around anchorRect: CGRect) -> CGRect {
        let origin: CGPoint
        switch anchor {
        case .belowLeft: origin = CGPoint(x: anchorRect.minX, y: anchorRect.maxY + gap)
        case .belowRight: origin = CGPoint(x: anchorRect.maxX - size.width, y: anchorRect.maxY + gap)
        case .aboveLeft: origin = CGPoint(x: anchorRect.minX, y: anchorRect.minY - gap - size.height)
        case .aboveRight: origin = CGPoint(x: anchorRect.maxX - size.width, y: anchorRect.minY - gap - size.height)
        case .right: origin = CGPoint(x: anchorRect.maxX + gap, y: anchorRect.midY - size.height / 2)
        case .left: origin = CGPoint(x: anchorRect.minX - gap - size.width, y: anchorRect.midY - size.height / 2)
        case .below: origin = CGPoint(x: anchorRect.midX - size.width / 2, y: anchorRect.maxY + gap)
        case .above: origin = CGPoint(x: anchorRect.midX - size.width / 2, y: anchorRect.minY - gap - size.height)
        }
        return CGRect(origin: origin, size: size)
    }

    public struct Placement: Equatable, Sendable {
        public let rect: CGRect
        public let anchor: Anchor
        /// False when no anchor was clean and the least-overlap fallback was used.
        public let isClean: Bool
    }

    /// `anchorRect` is the mark's outline bounds; `obstacles` must include the
    /// padded target.
    public static func place(size: CGSize, around anchorRect: CGRect, visible: CGRect, obstacles: [CGRect]) -> Placement {
        let allowedRect = visible.insetBy(dx: screenMargin, dy: screenMargin)
        for anchor in Anchor.allCases {
            let candidateRect = rect(for: anchor, size: size, around: anchorRect)
            if allowedRect.contains(candidateRect) && !obstacles.contains(where: { $0.intersects(candidateRect) }) {
                return Placement(rect: candidateRect, anchor: anchor, isClean: true)
            }
        }
        var bestPlacement: Placement?
        var bestOverlap = CGFloat.greatestFiniteMagnitude
        for anchor in Anchor.allCases {
            let candidateRect = clamped(rect(for: anchor, size: size, around: anchorRect), into: allowedRect)
            let overlap = obstacles.reduce(CGFloat(0)) { total, obstacle in
                let intersection = obstacle.intersection(candidateRect)
                return total + (intersection.isNull ? 0 : intersection.area)
            }
            if overlap < bestOverlap {
                bestOverlap = overlap
                bestPlacement = Placement(rect: candidateRect, anchor: anchor, isClean: false)
            }
        }
        return bestPlacement!
    }

    /// Moves `rect` inside `container` (keeps its size when it fits).
    public static func clamped(_ rect: CGRect, into container: CGRect) -> CGRect {
        let width = min(rect.width, container.width)
        let height = min(rect.height, container.height)
        let originX = min(max(rect.minX, container.minX), container.maxX - width)
        let originY = min(max(rect.minY, container.minY), container.maxY - height)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}

// MARK: - Companion landing

/// Where the companion (the orange buddy) parks while a POINT is shown:
/// padded's bottom-right +6,+6, else the freest corner or side; always
/// inside `visible` and never on the padded target.
public enum CompanionLanding {
    public static let companionSize = CGSize(width: 28, height: 28)
    static let offset: CGFloat = 6

    /// Returns the companion's rect (CG); its centre is where the buddy flies.
    public static func landing(target: CGRect, visible: CGRect, obstacles: [CGRect] = [], size: CGSize = companionSize) -> CGRect {
        let paddedRect = MarkLayout.padded(target)
        let allowedRect = visible.insetBy(dx: 2, dy: 2)
        let candidateOrigins: [CGPoint] = [
            CGPoint(x: paddedRect.maxX + offset, y: paddedRect.maxY + offset),                         // bottom-right
            CGPoint(x: paddedRect.minX - offset - size.width, y: paddedRect.maxY + offset),            // bottom-left
            CGPoint(x: paddedRect.maxX + offset, y: paddedRect.minY - offset - size.height),           // top-right
            CGPoint(x: paddedRect.minX - offset - size.width, y: paddedRect.minY - offset - size.height), // top-left
            CGPoint(x: paddedRect.maxX + offset, y: paddedRect.midY - size.height / 2),                // right
            CGPoint(x: paddedRect.minX - offset - size.width, y: paddedRect.midY - size.height / 2),   // left
            CGPoint(x: paddedRect.midX - size.width / 2, y: paddedRect.maxY + offset),                 // below
            CGPoint(x: paddedRect.midX - size.width / 2, y: paddedRect.minY - offset - size.height)    // above
        ]
        let candidateRects = candidateOrigins.map { CGRect(origin: $0, size: size) }
        if let cleanRect = candidateRects.first(where: { allowedRect.contains($0) && !obstacles.contains(where: $0.intersects) }) {
            return cleanRect
        }
        // Pull each inside, keep those off padded, take the least crowded.
        let insideRects = candidateRects.map { LabelPlacer.clamped($0, into: allowedRect) }
        let offTargetRects = insideRects.filter { !$0.intersects(paddedRect) }
        let pool = offTargetRects.isEmpty ? insideRects : offTargetRects
        return pool.min { first, second in
            obstacleOverlap(first, obstacles) < obstacleOverlap(second, obstacles)
        }!
    }

    static func obstacleOverlap(_ rect: CGRect, _ obstacles: [CGRect]) -> CGFloat {
        obstacles.reduce(CGFloat(0)) { total, obstacle in
            let intersection = obstacle.intersection(rect)
            return total + (intersection.isNull ? 0 : intersection.area)
        }
    }
}
