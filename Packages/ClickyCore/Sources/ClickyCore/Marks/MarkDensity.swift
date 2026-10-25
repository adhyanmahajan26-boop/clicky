//
//  MarkDensity.swift
//  ClickyCore
//
//  Decides how loud a mark may be, from the text around its target. On a
//  dense UI (a Notion table, a file list) a fat ring around a 22 pt row
//  covers the rows above and below, so there the mark becomes a thin
//  underline under the row's TEXT (not the whole row). Rings and boxes are
//  kept for isolated controls, drawn tight (3 pt pad, 2 pt stroke).
//
//  Text obstacles are every text bound in the region, CG global points: AX
//  text / cell / row frames and OCR line frames. Containers (a row frame
//  holding its cells' text) are seen through: only leaf bounds count.
//
//  Rules (all pure geometry):
//   - text inside the target = leaf bounds with ≥ 60 % of their area in it;
//     every other leaf is a neighbour.
//   - text-like target: role .text, or (role unknown, text inside, and
//     width ≥ 4 × height). Controls are never text-like.
//   - dense: text-like and (height ≤ 32 pt, or a neighbour within 1.5 × its
//     height above or below, overlapping it horizontally).
//   - circle / box / step: dense → underline; else the tight outline, unless
//     it would cover > 15 % of any neighbour's text → underline too.
//   - underline: 2 pt below the text span (centre 3 pt below), never past
//     halfway to the next line below; spans the union of the text inside.
//

import CoreGraphics
import Foundation

/// What the target is, when the caller knows (the element's AX role, or
/// OCR text). Unknown falls back to geometry.
public enum MarkTargetRole: String, Sendable, Equatable {
    case text
    case control
    case unknown
}

/// What a circle / box / step mark ends up drawn as.
public enum MarkDrawnForm: String, Sendable, Equatable {
    /// Tight rounded box / pill around an isolated control.
    case tightOutline
    /// A thin underline under the target's text.
    case underline
}

public struct MarkDensityAnalysis: Equatable, Sendable {
    /// Leaf text bounds inside the target.
    public let textInside: [CGRect]
    /// Leaf text bounds that are not inside the target.
    public let neighbours: [CGRect]
    /// Union of `textInside`, nil when the target holds no known text.
    public let textSpan: CGRect?
    public let isTextLike: Bool
    public let isDense: Bool
}

public enum MarkDensity {
    public static let denseHeightLimit: CGFloat = 32
    public static let neighbourReachFactor: CGFloat = 1.5
    public static let insideAreaFraction: CGFloat = 0.6
    public static let textLikeAspectRatio: CGFloat = 4
    /// A circle / box covering more than this of a neighbour's text becomes an underline.
    public static let maximumNeighbourCoverage: CGFloat = 0.15
    /// Gap between the text's bottom and the underline stroke's top edge.
    public static let underlineGap: CGFloat = 2
    public static let underlineStrokeWidth: CGFloat = 2
    /// Tight outline padding for isolated controls.
    public static let tightPad: CGFloat = 3

    /// Drops empty bounds and containers: a bound that holds another,
    /// smaller bound (an AX row around its cells' OCR lines) is not text.
    /// Sorted by top edge so each bound only scans the few that start
    /// inside it (registries hold thousands of bounds; marks rebuild at 10 Hz).
    public static func leafTextBounds(_ textBounds: [CGRect]) -> [CGRect] {
        let candidates = textBounds.filter { !$0.isNull && $0.width > 0.5 && $0.height > 0.5 }
        let byTop = candidates.sorted { $0.minY < $1.minY }
        func firstIndex(withMinYAtLeast value: CGFloat) -> Int {
            var lower = 0
            var upper = byTop.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if byTop[middle].minY < value { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
        return candidates.filter { bound in
            let grown = bound.insetBy(dx: -1, dy: -1)
            var index = firstIndex(withMinYAtLeast: grown.minY)
            while index < byTop.count && byTop[index].minY <= grown.maxY {
                let other = byTop[index]
                if other != bound && other.area < bound.area * 0.95 && grown.contains(other) { return false }
                index += 1
            }
            return true
        }
    }

    public static func analyze(target: CGRect, role: MarkTargetRole, leafTexts: [CGRect]) -> MarkDensityAnalysis {
        var textInside: [CGRect] = []
        var neighbours: [CGRect] = []
        for leaf in leafTexts {
            let insideArea = leaf.intersection(target).area
            if leaf.area > 0 && insideArea >= insideAreaFraction * leaf.area { textInside.append(leaf) } else { neighbours.append(leaf) }
        }
        let textSpan = textInside.reduce(nil as CGRect?) { span, leaf in span.map { $0.union(leaf) } ?? leaf }

        let isTextLike: Bool
        switch role {
        case .text: isTextLike = true
        case .control: isTextLike = false
        case .unknown: isTextLike = !textInside.isEmpty && target.width >= textLikeAspectRatio * target.height
        }

        let lineRect = textSpan ?? target
        let reach = neighbourReachFactor * lineRect.height
        let hasCloseNeighbour = neighbours.contains { neighbour in
            let overlapsHorizontally = neighbour.maxX > target.minX && neighbour.minX < target.maxX
            let isAboveOrBelow = neighbour.midY < lineRect.minY || neighbour.midY > lineRect.maxY
            let gapAbove = lineRect.minY - neighbour.maxY
            let gapBelow = neighbour.minY - lineRect.maxY
            return overlapsHorizontally && isAboveOrBelow && max(gapAbove, gapBelow) <= reach
        }
        let isDense = isTextLike && (target.height <= denseHeightLimit || hasCloseNeighbour)
        return MarkDensityAnalysis(textInside: textInside, neighbours: neighbours, textSpan: textSpan, isTextLike: isTextLike, isDense: isDense)
    }

    /// Fraction of `neighbour` covered by `rect` (area).
    static func coverage(of neighbour: CGRect, by rect: CGRect) -> CGFloat {
        guard neighbour.area > 0 else { return 0 }
        return neighbour.intersection(rect).area / neighbour.area
    }

    /// Underline or tight outline for a circle / box / step mark.
    public static func form(for analysis: MarkDensityAnalysis, tightOutline: MarkShapeSpec) -> MarkDrawnForm {
        if analysis.isDense { return .underline }
        let coversNeighbour = analysis.neighbours.contains { coverage(of: $0, by: tightOutline.rect) > maximumNeighbourCoverage }
        return coversNeighbour ? .underline : .tightOutline
    }

    /// The underline under the target's text: from the span's left to right
    /// edge, centred 3 pt below its bottom, kept above halfway to the next
    /// line below and inside the display.
    public static func underline(for analysis: MarkDensityAnalysis, target: CGRect, display: CGRect) -> (start: CGPoint, end: CGPoint) {
        let span = analysis.textSpan ?? target
        var lineY = span.maxY + underlineGap + underlineStrokeWidth / 2
        for neighbour in analysis.neighbours where neighbour.minY >= span.maxY && neighbour.maxX > span.minX && neighbour.minX < span.maxX {
            lineY = min(lineY, (span.maxY + neighbour.minY) / 2)
        }
        let allowedRect = display.insetBy(dx: MarkLayout.edgeInset, dy: MarkLayout.edgeInset)
        lineY = min(max(lineY, allowedRect.minY), allowedRect.maxY)
        let startX = min(max(span.minX, allowedRect.minX), allowedRect.maxX)
        let endX = min(max(span.maxX, allowedRect.minX), allowedRect.maxX)
        return (CGPoint(x: startX, y: lineY), CGPoint(x: max(endX, startX + 1), y: lineY))
    }
}

// MARK: - Text obstacles from the grounding registry

public enum MarkTextObstacles {
    /// Roles whose frames are text on screen (fields and areas are controls).
    public static let textRoles: Set<GroundingRole> = [.text, .cell, .row, .link]
    /// Taller bounds are panels, not lines of text.
    public static let maximumTextHeight: CGFloat = 80

    /// Every text bound the marks should keep clear of: visible AX text-ish
    /// elements (not behind another window) and OCR lines.
    public static func collect(elements: [GroundingElement], ocrLines: [OCRLine]) -> [CGRect] {
        var bounds: [CGRect] = []
        for element in elements where !element.isBehind && (textRoles.contains(element.role) || element.source == .ocr) {
            let frame = element.visibleFrameCG
            if frame.area > 0 && frame.height <= maximumTextHeight { bounds.append(frame) }
        }
        for line in ocrLines where line.frameCG.area > 0 && line.frameCG.height <= maximumTextHeight {
            bounds.append(line.frameCG)
        }
        return bounds
    }

    /// The role hint for a mark on `element` (nil: an OCR-only or raw target).
    public static func targetRole(for element: GroundingElement?, isTextMatch: Bool) -> MarkTargetRole {
        if isTextMatch { return .text }
        guard let element else { return .unknown }
        if element.source == .ocr || textRoles.contains(element.role) { return .text }
        switch element.role {
        case .window, .image: return .unknown
        default: return .control
        }
    }
}
