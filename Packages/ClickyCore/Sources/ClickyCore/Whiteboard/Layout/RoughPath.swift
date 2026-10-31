//
//  RoughPath.swift
//  ClickyCore
//
//  Hand-drawn strokes for the whiteboard: a port of rough.js's line
//  (`_line` / `_doubleLine`), linear path, curve and ellipse generators.
//  Every stroke is drawn twice with different random offsets, as rough.js
//  does. Roughness 1, bowing 1, maxRandomnessOffset 2; long lines get a
//  roughness gain going 1 → 0.4 between 200 and 500 pt. Ellipses use 12
//  points (rough.js's ellipse algorithm, step count fixed at 12).
//
//  Deterministic per element: the RNG is rough.js's Park–Miller variant
//  (seed = seed · 48271 wrapping, value = (seed & 0x7fffffff) / 2^31),
//  seeded with FNV-1a-32 of the element id. Never `hashValue` (it is
//  randomised per process).
//
//  Ported from rough.js — https://github.com/rough-stuff/rough
//  MIT License. Copyright (c) 2019 Preet Shihn.
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the
//  "Software"), to deal in the Software without restriction, including
//  without limitation the rights to use, copy, modify, merge, publish,
//  distribute, sublicense, and/or sell copies of the Software, and to permit
//  persons to whom the Software is furnished to do so, subject to the
//  following conditions: The above copyright notice and this permission
//  notice shall be included in all copies or substantial portions of the
//  Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
//

import CoreGraphics
import Foundation

public struct RoughOptions: Equatable, Sendable {
    public var roughness: Double = 1
    public var bowing: Double = 1
    public var maxRandomnessOffset: Double = 2
    public var curveFitting: Double = 0.95
    public var curveTightness: Double = 0
    public var ellipsePointCount: Int = 12

    public init() {}
}

public enum RoughPathOp: Equatable, Sendable {
    case move(CGPoint)
    case curve(control1: CGPoint, control2: CGPoint, end: CGPoint)
}

/// rough.js `Random`: Park–Miller with multiplier 48271 on 32 bits.
public struct RoughRandom: Equatable, Sendable {
    public private(set) var seed: UInt32

    public init(seed: UInt32) {
        self.seed = seed == 0 ? 1 : seed
    }

    public mutating func next() -> Double {
        seed = seed &* 48271
        return Double(seed & 0x7fff_ffff) / 2_147_483_648
    }
}

public struct RoughGenerator {
    public let baseSeed: UInt32
    public let options: RoughOptions
    private var random: RoughRandom

    public init(seed: UInt32, options: RoughOptions = RoughOptions()) {
        self.baseSeed = seed
        self.options = options
        self.random = RoughRandom(seed: seed)
    }

    public init(elementID: String, options: RoughOptions = RoughOptions()) {
        self.init(seed: RoughPath.fnv1a32(elementID), options: options)
    }

    // MARK: rough.js helpers

    private mutating func offset(_ minimum: Double, _ maximum: Double, gain: Double = 1) -> Double {
        options.roughness * gain * (random.next() * (maximum - minimum) + minimum)
    }

    private mutating func offsetOpt(_ value: Double, gain: Double = 1) -> Double {
        offset(-value, value, gain: gain)
    }

    private static func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    /// rough.js `_line`: one bowed cubic from (x1, y1) to (x2, y2).
    private mutating func singleLine(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, move: Bool, overlay: Bool) -> [RoughPathOp] {
        let lengthSquared = (x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2)
        let length = lengthSquared.squareRoot()
        let roughnessGain: Double
        if length < 200 {
            roughnessGain = 1
        } else if length > 500 {
            roughnessGain = 0.4
        } else {
            roughnessGain = -0.0016668 * length + 1.233334
        }
        var randomnessOffset = options.maxRandomnessOffset
        if randomnessOffset * randomnessOffset * 100 > lengthSquared { randomnessOffset = length / 10 }
        let halfOffset = randomnessOffset / 2
        let divergePoint = 0.2 + random.next() * 0.2
        var midDisplacementX = options.bowing * options.maxRandomnessOffset * (y2 - y1) / 200
        var midDisplacementY = options.bowing * options.maxRandomnessOffset * (x1 - x2) / 200
        midDisplacementX = offsetOpt(midDisplacementX, gain: roughnessGain)
        midDisplacementY = offsetOpt(midDisplacementY, gain: roughnessGain)
        let jitter = overlay ? halfOffset : randomnessOffset
        var ops: [RoughPathOp] = []
        if move {
            let moveX = x1 + offsetOpt(jitter, gain: roughnessGain)
            let moveY = y1 + offsetOpt(jitter, gain: roughnessGain)
            ops.append(.move(Self.point(moveX, moveY)))
        }
        let control1X = midDisplacementX + x1 + (x2 - x1) * divergePoint + offsetOpt(jitter, gain: roughnessGain)
        let control1Y = midDisplacementY + y1 + (y2 - y1) * divergePoint + offsetOpt(jitter, gain: roughnessGain)
        let control2X = midDisplacementX + x1 + 2 * (x2 - x1) * divergePoint + offsetOpt(jitter, gain: roughnessGain)
        let control2Y = midDisplacementY + y1 + 2 * (y2 - y1) * divergePoint + offsetOpt(jitter, gain: roughnessGain)
        let endX = x2 + offsetOpt(jitter, gain: roughnessGain)
        let endY = y2 + offsetOpt(jitter, gain: roughnessGain)
        ops.append(.curve(control1: Self.point(control1X, control1Y), control2: Self.point(control2X, control2Y), end: Self.point(endX, endY)))
        return ops
    }

    /// rough.js `_doubleLine`: the line twice (full, then half jitter).
    public mutating func line(from start: CGPoint, to end: CGPoint) -> [RoughPathOp] {
        let x1 = Double(start.x), y1 = Double(start.y), x2 = Double(end.x), y2 = Double(end.y)
        return singleLine(x1, y1, x2, y2, move: true, overlay: false) + singleLine(x1, y1, x2, y2, move: true, overlay: true)
    }

    /// rough.js `linearPath` / `polygon`.
    public mutating func linearPath(_ points: [CGPoint], closed: Bool) -> [RoughPathOp] {
        guard points.count > 1 else { return [] }
        var ops: [RoughPathOp] = []
        for index in 0..<(points.count - 1) { ops += line(from: points[index], to: points[index + 1]) }
        if closed { ops += line(from: points[points.count - 1], to: points[0]) }
        return ops
    }

    public mutating func rectangle(_ rect: CGRect) -> [RoughPathOp] {
        linearPath([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)], closed: true)
    }

    /// rough.js `_curve`: Catmull-Rom (tightness 0) through `points`,
    /// starting at the second point (the first only steers).
    private func curveOps(_ points: [(Double, Double)]) -> [RoughPathOp] {
        guard points.count > 3 else { return [] }
        let tightness = 1 - options.curveTightness
        var ops: [RoughPathOp] = [.move(Self.point(points[1].0, points[1].1))]
        var index = 1
        while index + 2 < points.count {
            let current = points[index]
            let control1 = Self.point(current.0 + (tightness * points[index + 1].0 - tightness * points[index - 1].0) / 6,
                                      current.1 + (tightness * points[index + 1].1 - tightness * points[index - 1].1) / 6)
            let control2 = Self.point(points[index + 2].0 + (tightness * points[index].0 - tightness * points[index + 2].0) / 6,
                                      points[index + 2].1 + (tightness * points[index].1 - tightness * points[index + 2].1) / 6)
            ops.append(.curve(control1: control1, control2: control2, end: Self.point(points[index + 2].0, points[index + 2].1)))
            index += 1
        }
        return ops
    }

    /// rough.js `_curveWithOffset`: every knot jittered, ends doubled.
    private mutating func curveWithOffset(_ points: [CGPoint], offset jitter: Double) -> [RoughPathOp] {
        guard let firstPoint = points.first else { return [] }
        var jittered: [(Double, Double)] = []
        for _ in 0..<2 {
            let jitteredX = Double(firstPoint.x) + offsetOpt(jitter)
            let jitteredY = Double(firstPoint.y) + offsetOpt(jitter)
            jittered.append((jitteredX, jitteredY))
        }
        for index in 1..<max(1, points.count) {
            let jitteredX = Double(points[index].x) + offsetOpt(jitter)
            let jitteredY = Double(points[index].y) + offsetOpt(jitter)
            jittered.append((jitteredX, jitteredY))
            if index == points.count - 1 {
                let repeatX = Double(points[index].x) + offsetOpt(jitter)
                let repeatY = Double(points[index].y) + offsetOpt(jitter)
                jittered.append((repeatX, repeatY))
            }
        }
        return curveOps(jittered)
    }

    /// rough.js `curve`: two passes, the second on seed + 1 (rough.js's
    /// cloneOptionsAlterSeed).
    public mutating func curve(through points: [CGPoint]) -> [RoughPathOp] {
        guard points.count >= 2 else { return [] }
        let firstPass = curveWithOffset(points, offset: 1 * (1 + options.roughness * 0.2))
        var secondPassGenerator = RoughGenerator(seed: baseSeed &+ 1, options: options)
        let secondPass = secondPassGenerator.curveWithOffset(points, offset: 1.5 * (1 + options.roughness * 0.22))
        return firstPass + secondPass
    }

    /// rough.js `_computeEllipsePoints` (rough path; core points unused).
    private mutating func ellipsePoints(increment: Double, centerX: Double, centerY: Double, radiusX: Double, radiusY: Double,
                                        offset jitter: Double, overlap: Double) -> [(Double, Double)] {
        var allPoints: [(Double, Double)] = []
        let radialOffset = offsetOpt(0.5) - Double.pi / 2
        func appendPoint(_ radiusFactor: Double, _ angle: Double) {
            let pointX = offsetOpt(jitter) + centerX + radiusFactor * radiusX * cos(angle)
            let pointY = offsetOpt(jitter) + centerY + radiusFactor * radiusY * sin(angle)
            allPoints.append((pointX, pointY))
        }
        appendPoint(0.9, radialOffset - increment)
        let endAngle = Double.pi * 2 + radialOffset - 0.01
        var angle = radialOffset
        while angle < endAngle {
            appendPoint(1, angle)
            angle += increment
        }
        appendPoint(1, radialOffset + Double.pi * 2 + overlap * 0.5)
        appendPoint(0.98, radialOffset + overlap)
        appendPoint(0.9, radialOffset + overlap * 0.5)
        return allPoints
    }

    /// rough.js `ellipse` (generateEllipseParams + ellipseWithParams), 12 points.
    public mutating func ellipse(in rect: CGRect) -> [RoughPathOp] {
        let increment = Double.pi * 2 / Double(max(3, options.ellipsePointCount))
        var radiusX = abs(Double(rect.width) / 2)
        var radiusY = abs(Double(rect.height) / 2)
        let curveFitRandomness = 1 - options.curveFitting
        radiusX += offsetOpt(radiusX * curveFitRandomness)
        radiusY += offsetOpt(radiusY * curveFitRandomness)
        let innerOffset = offset(0.4, 1)
        let overlap = increment * offset(0.1, innerOffset)
        let centerX = Double(rect.midX), centerY = Double(rect.midY)
        let firstPoints = ellipsePoints(increment: increment, centerX: centerX, centerY: centerY, radiusX: radiusX, radiusY: radiusY, offset: 1, overlap: overlap)
        let secondPoints = ellipsePoints(increment: increment, centerX: centerX, centerY: centerY, radiusX: radiusX, radiusY: radiusY, offset: 1.5, overlap: 0)
        return curveOps(firstPoints) + curveOps(secondPoints)
    }

    /// Two short rough strokes back from `tip`, away from `toward`.
    public mutating func arrowhead(tip: CGPoint, comingFrom toward: CGPoint, length: CGFloat = 14, spreadRadians: CGFloat = 0.45) -> [RoughPathOp] {
        let baseAngle = atan2(toward.y - tip.y, toward.x - tip.x)
        let leftEnd = CGPoint(x: tip.x + length * cos(baseAngle + spreadRadians), y: tip.y + length * sin(baseAngle + spreadRadians))
        let rightEnd = CGPoint(x: tip.x + length * cos(baseAngle - spreadRadians), y: tip.y + length * sin(baseAngle - spreadRadians))
        return line(from: leftEnd, to: tip) + line(from: rightEnd, to: tip)
    }
}

public enum RoughPath {
    /// FNV-1a, 32-bit, over the UTF-8 bytes ("a" → 0xe40c292c).
    public static func fnv1a32(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    public static func cgPath(_ ops: [RoughPathOp]) -> CGPath {
        let mutablePath = CGMutablePath()
        var hasCurrentPoint = false
        for op in ops {
            switch op {
            case .move(let point):
                mutablePath.move(to: point)
                hasCurrentPoint = true
            case .curve(let control1, let control2, let end):
                if !hasCurrentPoint {
                    mutablePath.move(to: end)
                    hasCurrentPoint = true
                }
                mutablePath.addCurve(to: end, control1: control1, control2: control2)
            }
        }
        return mutablePath
    }

    public static func line(from start: CGPoint, to end: CGPoint, id: String) -> CGPath {
        var generator = RoughGenerator(elementID: id)
        return cgPath(generator.line(from: start, to: end))
    }

    public static func rectangle(_ rect: CGRect, id: String) -> CGPath {
        var generator = RoughGenerator(elementID: id)
        return cgPath(generator.rectangle(rect))
    }

    public static func ellipse(in rect: CGRect, id: String) -> CGPath {
        var generator = RoughGenerator(elementID: id)
        return cgPath(generator.ellipse(in: rect))
    }

    public static func curve(through points: [CGPoint], id: String) -> CGPath {
        var generator = RoughGenerator(elementID: id)
        return cgPath(generator.curve(through: points))
    }

    /// A node's outline (box or ellipse), seeded by its id.
    public static func outlineOps(of element: WBPlacedElement) -> [RoughPathOp] {
        var generator = RoughGenerator(elementID: element.id)
        switch element.shape {
        case .rectangle: return generator.rectangle(element.rect)
        case .ellipse: return generator.ellipse(in: element.rect)
        }
    }

    /// An edge's spline plus arrowhead at `to`, seeded by `id` (e.g.
    /// "from>to#index").
    public static func edgeOps(of edge: WBPlacedEdge, id: String) -> [RoughPathOp] {
        var generator = RoughGenerator(elementID: id)
        var ops = generator.curve(through: edge.points)
        if let lastSegment = edge.segments.last {
            let tangentSource = lastSegment.control2 == lastSegment.end ? lastSegment.start : lastSegment.control2
            ops += generator.arrowhead(tip: lastSegment.end, comingFrom: tangentSource)
        }
        return ops
    }

    public static func edgeID(of edge: WBPlacedEdge) -> String { "\(edge.from)>\(edge.to)#\(edge.edgeIndex)" }
}
