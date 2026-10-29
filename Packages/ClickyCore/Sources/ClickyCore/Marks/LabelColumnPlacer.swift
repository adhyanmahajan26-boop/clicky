//
//  LabelColumnPlacer.swift
//  ClickyCore
//
//  Puts mark labels in clear space and connects each to its mark with a thin
//  leader arrow, instead of parking them on neighbouring rows.
//
//  All labels of a display share ONE column, stacked in their targets' y
//  order (so the leaders never cross), each as close to its target's row as
//  the obstacles allow (pushed down past anything it would touch, 4 pt
//  apart). Candidate columns, searched outward:
//   1. right of the rows' text: 28 pt past the furthest text end on any
//      labelled row, then stepping right (24 pt) through the window's empty
//      right area;
//   2. the margin just outside the window's right edge;
//   3. the left gutter inside the window, then outside its left edge.
//  The cheapest column (total leader length) with ZERO overlap wins: no
//  label touches text, another mark, another label or the companion. With
//  none clean the caller falls back to LabelPlacer's least-overlap anchors.
//  Long leaders are fine; overlap is not.
//
//  Leader: a straight 1.5 pt line from the label's near edge to 6 pt off
//  the target (its text / outline), with a small head; skipped when the
//  label is already within 14 pt of the target.
//

import CoreGraphics
import Foundation

public struct LeaderSpec: Equatable, Sendable {
    public let start: CGPoint
    public let tip: CGPoint
    public let headLeft: CGPoint
    public let headRight: CGPoint
}

public enum LabelColumnPlacer {
    public static let columnGap: CGFloat = 28
    public static let columnStep: CGFloat = 24
    public static let stackSpacing: CGFloat = 4
    public static let leaderTargetGap: CGFloat = 6
    public static let leaderLabelGap: CGFloat = 3
    public static let minimumLeaderLength: CGFloat = 14
    public static let leaderHeadLength: CGFloat = 7
    public static let leaderHeadSpreadRadians: CGFloat = 28 * .pi / 180
    public static let leaderLineWidth: CGFloat = 1.5

    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let size: CGSize
        /// What the label points at: the text span plus its underline, or the outline.
        public let attachRect: CGRect
        public init(id: UUID, size: CGSize, attachRect: CGRect) {
            self.id = id
            self.size = size
            self.attachRect = attachRect
        }
    }

    enum Side { case right, left }

    /// `obstacles`: text bounds, other marks' geometry, labels already
    /// placed, the companion. `region`: the target's window (else the
    /// display's visible frame); `visible`: labels stay inside its inset 8.
    public static func placeColumn(_ requests: [Request], obstacles: [CGRect], region: CGRect, visible: CGRect) -> [UUID: CGRect]? {
        guard !requests.isEmpty else { return [:] }
        let allowed = visible.insetBy(dx: LabelPlacer.screenMargin, dy: LabelPlacer.screenMargin)
        let sorted = requests.sorted { $0.attachRect.midY < $1.attachRect.midY }
        let widest = sorted.map(\.size.width).max() ?? 0

        // How far the labelled rows' content reaches, either side.
        func rowBand(_ request: Request) -> [CGRect] {
            let attach = request.attachRect
            return obstacles.filter { $0.maxY > attach.minY && $0.minY < attach.maxY && $0.maxX > region.minX && $0.minX < region.maxX }
        }
        let rowEnd = sorted.map { request in rowBand(request).map(\.maxX).reduce(request.attachRect.maxX, max) }.max()!
        let rowStart = sorted.map { request in rowBand(request).map(\.minX).reduce(request.attachRect.minX, min) }.min()!

        var candidates: [(Side, CGFloat)] = []
        var columnX = rowEnd + columnGap
        repeat {
            candidates.append((.right, columnX))
            columnX += columnStep
        } while columnX + widest <= region.maxX - LabelPlacer.screenMargin
        candidates.append((.right, region.maxX + 12))
        var columnRightX = rowStart - columnGap
        while columnRightX - widest >= region.minX + LabelPlacer.screenMargin {
            candidates.append((.left, columnRightX))
            columnRightX -= columnStep
        }
        candidates.append((.left, region.minX - 12))

        var best: (cost: CGFloat, rects: [UUID: CGRect])?
        for (side, edgeX) in candidates {
            guard let rects = stack(sorted, side: side, edgeX: edgeX, obstacles: obstacles, allowed: allowed) else { continue }
            let cost = sorted.reduce(CGFloat(0)) { total, request in
                guard let labelRect = rects[request.id] else { return total }
                let start = leaderStart(label: labelRect, attach: request.attachRect)
                return total + distance(from: start, to: request.attachRect.insetBy(dx: -leaderTargetGap, dy: -leaderTargetGap))
            }
            if best == nil || cost < best!.cost - 0.5 { best = (cost, rects) }
        }
        return best?.rects
    }

    /// Stacks the labels (already in y order) in a column; nil when one
    /// can't be placed without overlap inside `allowed`.
    static func stack(_ sorted: [Request], side: Side, edgeX: CGFloat, obstacles: [CGRect], allowed: CGRect) -> [UUID: CGRect]? {
        var placed: [UUID: CGRect] = [:]
        var blockers = obstacles
        var previousMaxY = -CGFloat.greatestFiniteMagnitude
        for request in sorted {
            let originX = side == .right ? edgeX : edgeX - request.size.width
            var originY = max(request.attachRect.midY - request.size.height / 2, previousMaxY + stackSpacing, allowed.minY)
            var labelRect = CGRect(origin: CGPoint(x: originX, y: originY), size: request.size)
            guard labelRect.minX >= allowed.minX, labelRect.maxX <= allowed.maxX else { return nil }
            for _ in 0..<400 {
                let hits = blockers.filter { $0.intersects(labelRect) }
                guard let lowest = hits.map(\.maxY).max() else { break }
                originY = lowest + stackSpacing
                labelRect.origin.y = originY
            }
            guard labelRect.maxY <= allowed.maxY, !blockers.contains(where: { $0.intersects(labelRect) }) else { return nil }
            placed[request.id] = labelRect
            blockers.append(labelRect)
            previousMaxY = labelRect.maxY
        }
        return placed
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    /// Where the leader leaves the label: the edge facing the target.
    static func leaderStart(label: CGRect, attach: CGRect) -> CGPoint {
        if label.minX >= attach.maxX { return CGPoint(x: label.minX - leaderLabelGap, y: label.midY) }
        if label.maxX <= attach.minX { return CGPoint(x: label.maxX + leaderLabelGap, y: label.midY) }
        let x = attach.midX.clamped(label.minX + 8, label.maxX - 8)
        return label.midY < attach.midY ? CGPoint(x: x, y: label.maxY + leaderLabelGap) : CGPoint(x: x, y: label.minY - leaderLabelGap)
    }

    /// The leader from `label` to 6 pt off `attach`, nil when they're close.
    public static func leader(label: CGRect, attach: CGRect) -> LeaderSpec? {
        let start = leaderStart(label: label, attach: attach)
        let ring = attach.insetBy(dx: -leaderTargetGap, dy: -leaderTargetGap)
        guard !ring.contains(start) else { return nil }
        let tip = CGPoint(x: start.x.clamped(ring.minX, ring.maxX), y: start.y.clamped(ring.minY, ring.maxY))
        let length = hypot(start.x - tip.x, start.y - tip.y)
        guard length >= minimumLeaderLength else { return nil }
        let backAngle = atan2(start.y - tip.y, start.x - tip.x)
        let headLeft = CGPoint(x: tip.x + leaderHeadLength * cos(backAngle + leaderHeadSpreadRadians),
                               y: tip.y + leaderHeadLength * sin(backAngle + leaderHeadSpreadRadians))
        let headRight = CGPoint(x: tip.x + leaderHeadLength * cos(backAngle - leaderHeadSpreadRadians),
                                y: tip.y + leaderHeadLength * sin(backAngle - leaderHeadSpreadRadians))
        return LeaderSpec(start: start, tip: tip, headLeft: headLeft, headRight: headRight)
    }
}

extension CGFloat {
    func clamped(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        lower <= upper ? Swift.min(Swift.max(self, lower), upper) : (lower + upper) / 2
    }
}
