//
//  WBLayoutGeometry.swift
//  ClickyCore
//
//  Small exact geometry shared by the whiteboard layout: where a ray from a
//  node's centre leaves its outline (box or ellipse), Catmull-Rom knots to
//  cubic Béziers, strict rect overlap, and the ±12 pt label nudge search.
//

import CoreGraphics
import Foundation

enum WBLayoutGeometry {
    /// Rects that only touch (or overlap by less than this) don't count.
    static let overlapTolerance: CGFloat = 0.01

    static func overlaps(_ first: CGRect, _ second: CGRect) -> Bool {
        first.minX < second.maxX - overlapTolerance && second.minX < first.maxX - overlapTolerance &&
            first.minY < second.maxY - overlapTolerance && second.minY < first.maxY - overlapTolerance
    }

    static func overlapArea(_ rect: CGRect, _ obstacles: [CGRect]) -> CGFloat {
        obstacles.reduce(CGFloat(0)) { total, obstacle in
            let intersection = obstacle.intersection(rect)
            return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
        }
    }

    static func transform(_ rect: CGRect, scale: CGFloat, offset: CGVector) -> CGRect {
        CGRect(x: rect.minX * scale + offset.dx, y: rect.minY * scale + offset.dy, width: rect.width * scale, height: rect.height * scale)
    }

    /// Where the ray from `rect`'s centre toward `point` crosses the shape's
    /// outline: exact ray-box / ray-ellipse intersection.
    static func borderPoint(of rect: CGRect, shape: WBNodeShape, toward point: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let deltaX = point.x - center.x
        let deltaY = point.y - center.y
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        guard (deltaX != 0 || deltaY != 0), halfWidth > 0, halfHeight > 0 else {
            return CGPoint(x: center.x, y: rect.maxY)
        }
        let parameter: CGFloat
        switch shape {
        case .rectangle:
            let horizontalParameter = deltaX == 0 ? CGFloat.infinity : halfWidth / abs(deltaX)
            let verticalParameter = deltaY == 0 ? CGFloat.infinity : halfHeight / abs(deltaY)
            parameter = min(horizontalParameter, verticalParameter)
        case .ellipse:
            let normalizedX = deltaX / halfWidth
            let normalizedY = deltaY / halfHeight
            parameter = 1 / (normalizedX * normalizedX + normalizedY * normalizedY).squareRoot()
        }
        return CGPoint(x: center.x + deltaX * parameter, y: center.y + deltaY * parameter)
    }

    /// Uniform Catmull-Rom through `knots` (end knots doubled), as Béziers.
    static func catmullRomSegments(through knots: [CGPoint]) -> [WBCubicSegment] {
        guard knots.count >= 2 else { return [] }
        var segments: [WBCubicSegment] = []
        segments.reserveCapacity(knots.count - 1)
        for index in 0..<(knots.count - 1) {
            let previous = index == 0 ? knots[0] : knots[index - 1]
            let start = knots[index]
            let end = knots[index + 1]
            let next = index + 2 < knots.count ? knots[index + 2] : knots[index + 1]
            let control1 = CGPoint(x: start.x + (end.x - previous.x) / 6, y: start.y + (end.y - previous.y) / 6)
            let control2 = CGPoint(x: end.x - (next.x - start.x) / 6, y: end.y - (next.y - start.y) / 6)
            segments.append(WBCubicSegment(start: start, control1: control1, control2: control2, end: end))
        }
        return segments
    }

    /// The label anchor: the middle of the middle segment ((n−1)/2), so a
    /// label always sits in a gap between layers, never on a dummy node.
    static func labelSegmentIndex(segmentCount: Int) -> Int { max(0, (segmentCount - 1) / 2) }

    static func labelAnchor(of segments: [WBCubicSegment]) -> CGPoint? {
        guard !segments.isEmpty else { return nil }
        return segments[labelSegmentIndex(segmentCount: segments.count)].point(at: 0.5)
    }

    static let labelNudgeStep: CGFloat = 12
    static let labelNudgeRings = 12
    static let labelFallbackRings = 40

    /// Centred on `anchor`; on collision nudged ±12 pt (vertical, horizontal,
    /// then diagonal, ring by ring); else the least-overlapping candidate.
    static func placeLabel(size: CGSize, at anchor: CGPoint, obstacles: [CGRect]) -> CGRect {
        let centeredRect = CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        func isClean(_ rect: CGRect) -> Bool { !obstacles.contains { overlaps($0, rect) } }
        if isClean(centeredRect) { return centeredRect }
        var bestRect = centeredRect
        var bestOverlap = overlapArea(centeredRect, obstacles)
        for ring in 1...labelFallbackRings {
            let distance = CGFloat(ring) * labelNudgeStep
            let offsets: [CGVector] = [
                CGVector(dx: 0, dy: distance), CGVector(dx: 0, dy: -distance),
                CGVector(dx: distance, dy: 0), CGVector(dx: -distance, dy: 0),
                CGVector(dx: distance, dy: distance), CGVector(dx: -distance, dy: distance),
                CGVector(dx: distance, dy: -distance), CGVector(dx: -distance, dy: -distance)
            ]
            for offset in offsets {
                let candidateRect = centeredRect.offsetBy(dx: offset.dx, dy: offset.dy)
                if isClean(candidateRect) { return candidateRect }
                let candidateOverlap = overlapArea(candidateRect, obstacles)
                if candidateOverlap < bestOverlap {
                    bestOverlap = candidateOverlap
                    bestRect = candidateRect
                }
            }
        }
        return bestRect
    }

    /// Union of every point and control point (a Bézier stays in their hull).
    static func bounds(of segments: [WBCubicSegment]) -> CGRect {
        var result = CGRect.null
        for segment in segments {
            for point in [segment.start, segment.control1, segment.control2, segment.end] {
                result = result.union(CGRect(origin: point, size: .zero))
            }
        }
        return result
    }
}
