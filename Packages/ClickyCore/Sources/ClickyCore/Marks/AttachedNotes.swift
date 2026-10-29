//
//  AttachedNotes.swift
//  ClickyCore
//
//  The `attached` label style (v2.marks.labelStyle, the default): each
//  mark's note is a small pill RIGHT BESIDE its mark, so a box around a
//  product photo can say "wrong photo, use 4G9088's" where the user is
//  looking. No leader lines; the spoken explanation stays in the caption
//  bubble near the cursor.
//
//  Note text: at most 8 words and ~40 characters (cut at a word, with …).
//  Pill: 12 pt semibold, 6×3 padding, single line; a step's number rides in
//  a 14 pt disc at its left.
//
//  Placement (pure geometry, CG points), around the mark's drawn bounds
//  (outline + halo, or text span + underline):
//   - sides right, left, below, above; a wide mark (≥ 3 × as wide as tall,
//     or > 320 pt) tries below, above, right, left;
//   - along each side: centred / start-aligned / end-aligned;
//   - gap 6 pt, then further out in 4 pt steps up to 40 pt; the nearest
//     clean spot wins (side order breaks ties);
//   - clean = inside visible.insetBy(4) and touching no obstacle (text,
//     every mark's geometry, placed notes and chips, the companion); a
//     first pass also keeps off neighbouring photos / cards, a second
//     allows them.
//  No clean spot: that mark falls back to a numbered chip on the mark and
//  its note in the caption bubble's legend (the nearCursor mechanism).
//

import AppKit
import CoreGraphics

public enum AttachedNotes {
    public static let fontSize: CGFloat = 12
    public static let horizontalPadding: CGFloat = 6
    public static let verticalPadding: CGFloat = 3
    public static let cornerRadius: CGFloat = 6
    public static let maximumWords = 8
    public static let maximumCharacters = 40
    public static let gap: CGFloat = 6
    public static let maximumReach: CGFloat = 40
    public static let reachStep: CGFloat = 4
    public static let screenMargin: CGFloat = 4
    public static let stepBadgeDiameter: CGFloat = 14
    public static let stepBadgeSpacing: CGFloat = 4

    public static var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .semibold) }

    public enum Side: String, Sendable, CaseIterable {
        case right, left, below, above
    }

    /// The note as shown on screen: ≤ 8 words, ≤ 40 characters, cut at a
    /// word boundary with "…".
    public static func noteText(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var words = collapsed.split(separator: " ").map(String.init)
        var isCut = false
        if words.count > maximumWords {
            words = Array(words.prefix(maximumWords))
            isCut = true
        }
        var text = words.joined(separator: " ")
        if text.count > maximumCharacters {
            let limit = maximumCharacters - 1
            let prefix = String(text.prefix(limit))
            if let lastSpace = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: lastSpace) >= limit / 2 {
                text = String(prefix[..<lastSpace])
            } else {
                text = prefix
            }
            isCut = true
        }
        if isCut {
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-–—"))
            text += "…"
        }
        return text
    }

    /// Pill size for `text` (already shortened) with an optional step disc.
    public static func size(for text: String?, stepNumber: Int? = nil) -> CGSize {
        let measured = text.map { text -> CGSize in
            let bounds = NSAttributedString(string: text, attributes: [.font: font])
                .boundingRect(with: CGSize(width: 10_000, height: 100), options: [.usesLineFragmentOrigin, .usesFontLeading])
            return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        } ?? CGSize(width: 0, height: ceil(font.ascender - font.descender))
        let badgeWidth = stepNumber == nil ? 0 : stepBadgeDiameter + (text == nil ? 0 : stepBadgeSpacing)
        let width = measured.width + badgeWidth + 2 * horizontalPadding
        let height = max(measured.height + 2 * verticalPadding, stepNumber == nil ? 0 : stepBadgeDiameter + 4)
        return CGSize(width: width, height: height)
    }

    /// Side order for a mark: wide marks prefer below / above.
    public static func sides(for markRect: CGRect) -> [Side] {
        let isWide = markRect.width >= 3 * markRect.height || markRect.width > 320
        return isWide ? [.below, .above, .right, .left] : [.right, .left, .below, .above]
    }

    /// Candidate rects on `side` at `distance` from `markRect`: centred,
    /// start-aligned, end-aligned.
    static func candidates(side: Side, distance: CGFloat, size: CGSize, around markRect: CGRect) -> [CGRect] {
        switch side {
        case .right, .left:
            let x = side == .right ? markRect.maxX + distance : markRect.minX - distance - size.width
            return [markRect.midY - size.height / 2, markRect.minY, markRect.maxY - size.height].map {
                CGRect(x: x, y: $0, width: size.width, height: size.height)
            }
        case .below, .above:
            let y = side == .below ? markRect.maxY + distance : markRect.minY - distance - size.height
            return [markRect.minX, markRect.midX - size.width / 2, markRect.maxX - size.width].map {
                CGRect(x: $0, y: y, width: size.width, height: size.height)
            }
        }
    }

    public struct Placement: Equatable, Sendable {
        public let rect: CGRect
        public let side: Side
        /// Distance from the mark (≥ `gap`).
        public let distance: CGFloat
    }

    /// The nearest clean spot beside `markRect` within `maximumReach`, or nil.
    public static func place(size: CGSize, around markRect: CGRect, visible: CGRect, obstacles: [CGRect]) -> Placement? {
        let allowed = visible.insetBy(dx: screenMargin, dy: screenMargin)
        let searchArea = markRect.insetBy(dx: -(maximumReach + size.width + 2), dy: -(maximumReach + size.height + 2))
        let nearbyObstacles = obstacles.filter { $0.intersects(searchArea) }
        let sideOrder = sides(for: markRect)
        var distance = gap
        while distance <= maximumReach + 0.01 {
            for side in sideOrder {
                for candidate in candidates(side: side, distance: distance, size: size, around: markRect)
                where allowed.contains(candidate) && !nearbyObstacles.contains(where: { $0.intersects(candidate) }) {
                    return Placement(rect: candidate, side: side, distance: distance)
                }
            }
            distance += reachStep
        }
        return nil
    }
}
