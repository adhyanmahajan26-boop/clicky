//
//  MarkLayout.swift
//  ClickyCore
//
//  Where a mark's shape goes, in CG global points. Pure geometry: the
//  overlay only strokes what this returns.
//
//  Ring: pad = min(max(0.18·minSide, 4), 10), padded = target grown by pad.
//   - padded > 15% of the display → rounded box (radius 10)
//   - aspect > 3 or < 1/3 → pill (grown by q = max(pad, 0.21·minSide + 1.5);
//     the 0.21 keeps the target's corners ≥ 1.5 pt inside the round ends)
//   - else the ellipse through padded's corners (grown by w·k, h·k, k = (√2−1)/2)
//   - edge rule: a shape must stay inside display.insetBy(3); an ellipse that
//     doesn't fit becomes the pill if that fits, else a rounded box of
//     padded ∩ display.insetBy(3) (radius min(6, short side / 4)).
//  Arrow: 8 directions, L = 110 pt, chosen by preference + a pull toward the
//  screen centre with penalties for labels or tails off screen; the tip sits
//  exactly 6 pt (perpendicular) outside padded.
//

import CoreGraphics
import Foundation

public enum MarkShapeKind: String, Codable, Sendable {
    case ellipse
    case pill
    case roundedBox = "rbox"
}

public struct MarkShapeSpec: Equatable, Sendable {
    public let kind: MarkShapeKind
    public let rect: CGRect
    /// Corner radius (pill: half the short side; ellipse: unused, 0).
    public let cornerRadius: CGFloat

    public init(kind: MarkShapeKind, rect: CGRect, cornerRadius: CGFloat) {
        self.kind = kind
        self.rect = rect
        self.cornerRadius = cornerRadius
    }

    public var path: CGPath {
        switch kind {
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case .pill, .roundedBox:
            let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }

    /// Whether `point` is inside the shape (exact for all three kinds).
    public func contains(_ point: CGPoint) -> Bool {
        switch kind {
        case .ellipse:
            let semiAxisX = rect.width / 2
            let semiAxisY = rect.height / 2
            guard semiAxisX > 0, semiAxisY > 0 else { return false }
            let normalizedX = (point.x - rect.midX) / semiAxisX
            let normalizedY = (point.y - rect.midY) / semiAxisY
            return normalizedX * normalizedX + normalizedY * normalizedY <= 1
        case .pill, .roundedBox:
            return roundedRectSignedDistance(point) <= 0
        }
    }

    /// Distance from an inside point to the outline (≤ 0 when outside).
    /// Exact for pill/rounded box; for the ellipse a dense boundary sample.
    public func clearance(of point: CGPoint) -> CGFloat {
        switch kind {
        case .pill, .roundedBox:
            return -roundedRectSignedDistance(point)
        case .ellipse:
            guard contains(point) else { return 0 }
            func distance(at angle: CGFloat) -> CGFloat {
                hypot(rect.midX + rect.width / 2 * cos(angle) - point.x, rect.midY + rect.height / 2 * sin(angle) - point.y)
            }
            // Coarse sample, then golden-section refinement around the best one.
            let sampleCount = 1024
            let step = 2 * CGFloat.pi / CGFloat(sampleCount)
            let bestSample = (0..<sampleCount).min { distance(at: CGFloat($0) * step) < distance(at: CGFloat($1) * step) }!
            var lower = CGFloat(bestSample - 1) * step
            var upper = CGFloat(bestSample + 1) * step
            let goldenRatio = (sqrt(5) - 1) / 2
            for _ in 0..<60 {
                let first = upper - goldenRatio * (upper - lower)
                let second = lower + goldenRatio * (upper - lower)
                if distance(at: first) < distance(at: second) { upper = second } else { lower = first }
            }
            return distance(at: (lower + upper) / 2)
        }
    }

    /// Signed distance to the rounded rect outline (negative inside).
    private func roundedRectSignedDistance(_ point: CGPoint) -> CGFloat {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let halfWidth = rect.width / 2 - radius
        let halfHeight = rect.height / 2 - radius
        let offsetX = abs(point.x - rect.midX) - halfWidth
        let offsetY = abs(point.y - rect.midY) - halfHeight
        let outsideDistance = hypot(max(offsetX, 0), max(offsetY, 0))
        let insideDistance = min(max(offsetX, offsetY), 0)
        return outsideDistance + insideDistance - radius
    }
}

public struct ArrowSpec: Equatable, Sendable {
    /// Unit vector from the target toward the tail.
    public let direction: CGVector
    public let tail: CGPoint
    public let control: CGPoint
    public let tip: CGPoint
    public let headLeft: CGPoint
    public let headRight: CGPoint
    /// Where the arrow's label goes (beyond the tail), nil when no direction
    /// fits one; the caller then places it with LabelPlacer.
    public let labelRect: CGRect?
}

public enum MarkLayout {
    public static let arrowLength: CGFloat = 110
    public static let arrowTipGap: CGFloat = 6
    public static let arrowHeadLength: CGFloat = 14
    public static let arrowHeadSpreadRadians: CGFloat = 28 * .pi / 180
    public static let edgeInset: CGFloat = 3

    // MARK: Ring

    public static func pad(for target: CGRect) -> CGFloat {
        min(max(0.18 * min(target.width, target.height), 4), 10)
    }

    public static func padded(_ target: CGRect) -> CGRect {
        let targetPad = pad(for: target)
        return target.insetBy(dx: -targetPad, dy: -targetPad)
    }

    public static func ring(target: CGRect, display: CGRect) -> MarkShapeSpec {
        let targetPad = pad(for: target)
        let paddedRect = target.insetBy(dx: -targetPad, dy: -targetPad)
        let allowedRect = display.insetBy(dx: edgeInset, dy: edgeInset)

        let preferredShape: MarkShapeSpec
        let aspectRatio = target.height > 0 ? target.width / target.height : .infinity
        if paddedRect.area > 0.15 * display.area {
            preferredShape = MarkShapeSpec(kind: .roundedBox, rect: paddedRect, cornerRadius: 10)
        } else if aspectRatio > 3 || aspectRatio < 1.0 / 3 {
            preferredShape = pill(target: target, pad: targetPad)
        } else {
            let growth = (sqrt(2) - 1) / 2
            let ellipseRect = paddedRect.insetBy(dx: -paddedRect.width * growth, dy: -paddedRect.height * growth)
            preferredShape = MarkShapeSpec(kind: .ellipse, rect: ellipseRect, cornerRadius: 0)
        }
        if allowedRect.contains(preferredShape.rect) { return preferredShape }

        if preferredShape.kind == .ellipse {
            let pillShape = pill(target: target, pad: targetPad)
            if allowedRect.contains(pillShape.rect) { return pillShape }
        }
        let clippedRect = paddedRect.intersection(allowedRect)
        guard !clippedRect.isNull, clippedRect.width > 0, clippedRect.height > 0 else {
            // Target entirely off the drawable area: a small box at the nearest spot.
            let nearestPoint = CGPoint(x: min(max(target.midX, allowedRect.minX + 4), allowedRect.maxX - 4),
                                       y: min(max(target.midY, allowedRect.minY + 4), allowedRect.maxY - 4))
            return MarkShapeSpec(kind: .roundedBox, rect: CGRect(x: nearestPoint.x - 4, y: nearestPoint.y - 4, width: 8, height: 8), cornerRadius: 2)
        }
        return MarkShapeSpec(kind: .roundedBox, rect: clippedRect, cornerRadius: clippedCornerRadius(clippedRect, keeping: target.center))
    }

    /// min(6, short side / 4), reduced when the target's centre sits in a
    /// corner so the rounding never cuts it off.
    static func clippedCornerRadius(_ rect: CGRect, keeping point: CGPoint) -> CGFloat {
        var radius = min(6, min(rect.width, rect.height) / 4)
        let distanceX = min(point.x - rect.minX, rect.maxX - point.x)
        let distanceY = min(point.y - rect.minY, rect.maxY - point.y)
        if distanceX < radius && distanceY < radius { radius = max(0, max(distanceX, distanceY)) }
        return radius
    }

    static func pill(target: CGRect, pad targetPad: CGFloat) -> MarkShapeSpec {
        let growth = max(targetPad, 0.21 * min(target.width, target.height) + 1.5)
        let pillRect = target.insetBy(dx: -growth, dy: -growth)
        return MarkShapeSpec(kind: .pill, rect: pillRect, cornerRadius: min(pillRect.width, pillRect.height) / 2)
    }

    /// The `box` style: padded, radius 8, with the same edge rule.
    public static func box(target: CGRect, display: CGRect) -> MarkShapeSpec {
        let paddedRect = padded(target)
        let allowedRect = display.insetBy(dx: edgeInset, dy: edgeInset)
        if allowedRect.contains(paddedRect) { return MarkShapeSpec(kind: .roundedBox, rect: paddedRect, cornerRadius: 8) }
        let clippedRect = paddedRect.intersection(allowedRect)
        guard !clippedRect.isNull, clippedRect.width > 0, clippedRect.height > 0 else { return ring(target: target, display: display) }
        return MarkShapeSpec(kind: .roundedBox, rect: clippedRect, cornerRadius: clippedCornerRadius(clippedRect, keeping: target.center))
    }

    /// Isolated controls on a density-aware scene: a rounded box only
    /// `MarkDensity.tightPad` (3 pt) outside the target, radius
    /// min(8, short side / 2) (a pill for short targets), with the edge rule.
    /// Radius ≤ 8 with a 3 pt pad keeps the target's corners inside.
    public static func tightOutline(target: CGRect, display: CGRect) -> MarkShapeSpec {
        let paddedRect = target.insetBy(dx: -MarkDensity.tightPad, dy: -MarkDensity.tightPad)
        let allowedRect = display.insetBy(dx: edgeInset, dy: edgeInset)
        var shapeRect = paddedRect
        if !allowedRect.contains(paddedRect) {
            let clippedRect = paddedRect.intersection(allowedRect)
            guard !clippedRect.isNull, clippedRect.width > 0, clippedRect.height > 0 else { return ring(target: target, display: display) }
            shapeRect = clippedRect
        }
        let radius = min(8, min(shapeRect.width, shapeRect.height) / 2)
        let kind: MarkShapeKind = radius >= min(shapeRect.width, shapeRect.height) / 2 - 1e-6 ? .pill : .roundedBox
        return MarkShapeSpec(kind: kind, rect: shapeRect, cornerRadius: radius)
    }

    // MARK: Arrow

    /// The 8 tail directions, most preferred first: from the upper left like
    /// a cursor, then the other diagonals, then the sides.
    public static let arrowDirections: [CGVector] = {
        let diagonal = 1 / sqrt(2.0)
        return [
            CGVector(dx: -diagonal, dy: -diagonal), CGVector(dx: diagonal, dy: -diagonal),
            CGVector(dx: -diagonal, dy: diagonal), CGVector(dx: diagonal, dy: diagonal),
            CGVector(dx: -1, dy: 0), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1), CGVector(dx: 0, dy: 1)
        ]
    }()

    /// Tip on the ray from padded's centre along `direction`, exactly
    /// `arrowTipGap` outside the side it exits through (perpendicular).
    public static func arrowTip(padded paddedRect: CGRect, direction: CGVector) -> CGPoint {
        let center = paddedRect.center
        let unitX = direction.dx
        let unitY = direction.dy
        let scaleToSideX = abs(unitX) > 1e-6 ? (paddedRect.width / 2) / abs(unitX) : .infinity
        let scaleToSideY = abs(unitY) > 1e-6 ? (paddedRect.height / 2) / abs(unitY) : .infinity
        let scale = min(scaleToSideX, scaleToSideY) + arrowTipGap / (scaleToSideX <= scaleToSideY ? abs(unitX) : abs(unitY))
        return CGPoint(x: center.x + unitX * scale, y: center.y + unitY * scale)
    }

    /// Label rect just beyond the tail, along the arrow's direction.
    static func arrowLabelRect(tail: CGPoint, direction: CGVector, labelSize: CGSize) -> CGRect {
        // Distance from the label centre to its edge along the direction, plus a gap.
        let halfExtentX = abs(direction.dx) > 1e-6 ? (labelSize.width / 2) / abs(direction.dx) : .infinity
        let halfExtentY = abs(direction.dy) > 1e-6 ? (labelSize.height / 2) / abs(direction.dy) : .infinity
        let distanceToCenter = min(halfExtentX, halfExtentY) + 6
        let labelCenter = CGPoint(x: tail.x + direction.dx * distanceToCenter, y: tail.y + direction.dy * distanceToCenter)
        return CGRect(x: labelCenter.x - labelSize.width / 2, y: labelCenter.y - labelSize.height / 2, width: labelSize.width, height: labelSize.height)
    }

    /// The part of the ray start + t·direction (t ≥ 0) inside `rect`, as a
    /// t interval, or nil if the ray misses it.
    static func rayInterval(through rect: CGRect, from start: CGPoint, along direction: CGVector) -> ClosedRange<CGFloat>? {
        var enter: CGFloat = 0
        var exit = CGFloat.greatestFiniteMagnitude
        for (origin, delta, lower, upper) in [(start.x, direction.dx, rect.minX, rect.maxX), (start.y, direction.dy, rect.minY, rect.maxY)] {
            if abs(delta) < 1e-9 {
                guard origin >= lower && origin <= upper else { return nil }
            } else {
                let first = (lower - origin) / delta
                let second = (upper - origin) / delta
                enter = max(enter, min(first, second))
                exit = min(exit, max(first, second))
            }
        }
        return enter <= exit ? enter...exit : nil
    }

    public static func arrow(target: CGRect, visible: CGRect, labelSize: CGSize?, obstacles: [CGRect] = []) -> ArrowSpec {
        let paddedRect = padded(target)
        let labelArea = visible.insetBy(dx: 8, dy: 8)
        let tailArea = visible.insetBy(dx: 1, dy: 1)
        let visibleCenter = visible.center

        var bestCost = Double.greatestFiniteMagnitude
        var bestSpec: ArrowSpec?
        for (preferenceIndex, direction) in arrowDirections.enumerated() {
            let tip = arrowTip(padded: paddedRect, direction: direction)
            // The tail is L out from the tip, moved along the ray to stay on
            // screen (shorter when the screen ends, longer when the tip is
            // under the menu bar or Dock).
            let tailRange = rayInterval(through: tailArea, from: tip, along: direction)
            let shaftLength = tailRange.map { min(max(arrowLength, $0.lowerBound), $0.upperBound) } ?? 0
            let tail = CGPoint(x: tip.x + direction.dx * shaftLength, y: tip.y + direction.dy * shaftLength)
            let labelRect = labelSize.map { arrowLabelRect(tail: tail, direction: direction, labelSize: $0) }

            var cost = Double(preferenceIndex)
            // Centre pull: tails pointing toward the screen centre read better.
            let toCenterX = visibleCenter.x - paddedRect.midX
            let toCenterY = visibleCenter.y - paddedRect.midY
            let toCenterLength = max(1, hypot(toCenterX, toCenterY))
            cost -= 3 * Double((direction.dx * toCenterX + direction.dy * toCenterY) / toCenterLength)
            if abs(shaftLength - arrowLength) > 0.5 { cost += 300 }
            if tailRange == nil { cost += 1000 }
            var labelFits = true
            if let labelRect {
                if !labelArea.contains(labelRect) { cost += 1000; labelFits = false }
                if labelRect.intersects(paddedRect) { cost += 500; labelFits = false }
                cost += 50 * Double(obstacles.filter { $0.intersects(labelRect) }.count)
            }
            guard cost < bestCost else { continue }
            bestCost = cost
            bestSpec = makeArrowSpec(direction: direction, tail: tail, tip: tip, shaftLength: shaftLength,
                                     labelRect: labelFits ? labelRect : nil)
        }
        return bestSpec!
    }

    static func makeArrowSpec(direction: CGVector, tail: CGPoint, tip: CGPoint, shaftLength: CGFloat, labelRect: CGRect?) -> ArrowSpec {
        let midpoint = CGPoint(x: (tail.x + tip.x) / 2, y: (tail.y + tip.y) / 2)
        // Perpendicular bow of 0.15·L.
        let bow = 0.15 * shaftLength
        let control = CGPoint(x: midpoint.x - direction.dy * bow, y: midpoint.y + direction.dx * bow)
        // Head along the curve's tangent at the tip (control → tip).
        var tangentX = tip.x - control.x
        var tangentY = tip.y - control.y
        let tangentLength = hypot(tangentX, tangentY)
        if tangentLength > 1e-6 {
            tangentX /= tangentLength
            tangentY /= tangentLength
        } else {
            tangentX = -direction.dx
            tangentY = -direction.dy
        }
        let backAngle = atan2(-tangentY, -tangentX)
        let headLeft = CGPoint(x: tip.x + arrowHeadLength * cos(backAngle + arrowHeadSpreadRadians),
                               y: tip.y + arrowHeadLength * sin(backAngle + arrowHeadSpreadRadians))
        let headRight = CGPoint(x: tip.x + arrowHeadLength * cos(backAngle - arrowHeadSpreadRadians),
                                y: tip.y + arrowHeadLength * sin(backAngle - arrowHeadSpreadRadians))
        return ArrowSpec(direction: direction, tail: tail, control: control, tip: tip, headLeft: headLeft, headRight: headRight, labelRect: labelRect)
    }

    // MARK: Steps, underline, spot

    public static let stepDiscDiameter: CGFloat = 26

    /// Centre of a step's numbered disc: just outside the ring's top-left,
    /// kept inside `visible`.
    public static func stepDiscCenter(ring: MarkShapeSpec, visible: CGRect) -> CGPoint {
        let diagonal = 1 / sqrt(2.0)
        let outlinePoint: CGPoint
        switch ring.kind {
        case .ellipse:
            outlinePoint = CGPoint(x: ring.rect.midX - ring.rect.width / 2 * diagonal, y: ring.rect.midY - ring.rect.height / 2 * diagonal)
        case .pill, .roundedBox:
            let radius = min(ring.cornerRadius, ring.rect.width / 2, ring.rect.height / 2)
            outlinePoint = CGPoint(x: ring.rect.minX + radius * (1 - diagonal), y: ring.rect.minY + radius * (1 - diagonal))
        }
        let discRadius = stepDiscDiameter / 2
        let center = CGPoint(x: outlinePoint.x - discRadius * diagonal, y: outlinePoint.y - discRadius * diagonal)
        let discArea = visible.insetBy(dx: discRadius + 2, dy: discRadius + 2)
        return CGPoint(x: min(max(center.x, discArea.minX), discArea.maxX), y: min(max(center.y, discArea.minY), discArea.maxY))
    }

    /// The underline: 3 pt, from the words' left to right edge, at maxY + 2.
    public static func underline(target: CGRect, display: CGRect) -> (start: CGPoint, end: CGPoint) {
        let allowedRect = display.insetBy(dx: edgeInset, dy: edgeInset)
        let lineY = min(max(target.maxY + 2, allowedRect.minY), allowedRect.maxY)
        let startX = min(max(target.minX, allowedRect.minX), allowedRect.maxX)
        let endX = min(max(target.maxX, allowedRect.minX), allowedRect.maxX)
        return (CGPoint(x: startX, y: lineY), CGPoint(x: max(endX, startX + 1), y: lineY))
    }
}
