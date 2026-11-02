//
//  SVGPath.swift
//  ClickyCore
//
//  A small parser for SVG path strings, so icons and crew parts can be kept as the design's own path data and drawn as
//  vectors at any size. Handles M L H V C S Q T A Z, relative and absolute, with the design's compact number forms.
//

import CoreGraphics
import Foundation

public enum SVGPath {
    public static func cgPath(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(data)
        var command: Character = " "
        var current = CGPoint.zero
        var start = CGPoint.zero
        // The last control point, for S and T.
        var control: CGPoint?
        while let next = scanner.nextCommand(after: command) {
            command = next
            let relative = command.isLowercase
            let origin = relative ? current : .zero
            func x(_ value: CGFloat) -> CGFloat { value + origin.x }
            func y(_ value: CGFloat) -> CGFloat { value + origin.y }
            switch command.uppercased() {
            case "M":
                guard let px = scanner.number(), let py = scanner.number() else { return path }
                current = CGPoint(x: x(px), y: y(py))
                start = current
                path.move(to: current)
                control = nil
                // Further pairs after a move are lines.
                command = relative ? "l" : "L"
            case "L":
                guard let px = scanner.number(), let py = scanner.number() else { return path }
                current = CGPoint(x: x(px), y: y(py))
                path.addLine(to: current)
                control = nil
            case "H":
                guard let px = scanner.number() else { return path }
                current.x = x(px)
                path.addLine(to: current)
                control = nil
            case "V":
                guard let py = scanner.number() else { return path }
                current.y = y(py)
                path.addLine(to: current)
                control = nil
            case "C":
                guard let a = scanner.number(), let b = scanner.number(), let c = scanner.number(), let d = scanner.number(),
                      let e = scanner.number(), let f = scanner.number() else { return path }
                let second = CGPoint(x: x(c), y: y(d))
                let end = CGPoint(x: x(e), y: y(f))
                path.addCurve(to: end, control1: CGPoint(x: x(a), y: y(b)), control2: second)
                current = end
                control = second
            case "S":
                guard let c = scanner.number(), let d = scanner.number(), let e = scanner.number(), let f = scanner.number() else { return path }
                let first = control.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let second = CGPoint(x: x(c), y: y(d))
                let end = CGPoint(x: x(e), y: y(f))
                path.addCurve(to: end, control1: first, control2: second)
                current = end
                control = second
            case "Q":
                guard let a = scanner.number(), let b = scanner.number(), let c = scanner.number(), let d = scanner.number() else { return path }
                let pivot = CGPoint(x: x(a), y: y(b))
                let end = CGPoint(x: x(c), y: y(d))
                path.addQuadCurve(to: end, control: pivot)
                current = end
                control = pivot
            case "T":
                guard let c = scanner.number(), let d = scanner.number() else { return path }
                let pivot = control.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = CGPoint(x: x(c), y: y(d))
                path.addQuadCurve(to: end, control: pivot)
                current = end
                control = pivot
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let e = scanner.number(), let f = scanner.number() else { return path }
                let end = CGPoint(x: x(e), y: y(f))
                addArc(to: path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
                control = nil
            case "Z":
                path.closeSubpath()
                current = start
                control = nil
            default:
                return path
            }
        }
        return path
    }

    /// An SVG arc as cubic curves (the endpoint-to-centre conversion from the SVG spec, appendix F.6).
    private static func addArc(to path: CGMutablePath, from: CGPoint, to: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        guard from != to else { return }
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0 else { path.addLine(to: to); return }
        let phi = rotation * .pi / 180
        let (sinPhi, cosPhi) = (sin(phi), cos(phi))
        let dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let scale = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if scale > 1 { rx *= sqrt(scale); ry *= sqrt(scale) }
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let factor = (large == sweep ? -1 : 1) * sqrt(numerator / max(denominator, 1e-9))
        let cxp = factor * rx * y1 / ry, cyp = -factor * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (from.x + to.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (from.y + to.y) / 2
        let startAngle = atan2((y1 - cyp) / ry, (x1 - cxp) / rx)
        var delta = atan2((-y1 - cyp) / ry, (-x1 - cxp) / rx) - startAngle
        if sweep && delta < 0 { delta += 2 * .pi }
        if !sweep && delta > 0 { delta -= 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let handle = 4.0 / 3.0 * tan(step / 4)
        var angle = startAngle
        func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
            CGPoint(x: cosPhi * rx * px - sinPhi * ry * py + cx, y: sinPhi * rx * px + cosPhi * ry * py + cy)
        }
        for index in 0..<segments {
            let next = angle + step
            let end = index == segments - 1 ? to : point(cos(next), sin(next))
            path.addCurve(to: end,
                          control1: point(cos(angle) - handle * sin(angle), sin(angle) + handle * cos(angle)),
                          control2: point(cos(next) + handle * sin(next), sin(next) - handle * cos(next)))
            angle = next
        }
    }

    private struct Scanner {
        private let bytes: [UInt8]
        private var index = 0

        init(_ text: String) { bytes = Array(text.utf8) }

        private mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 44 || bytes[index] == 10 || bytes[index] == 9 { index += 1 }
        }

        /// A new command letter, or the last one again when more numbers follow it.
        mutating func nextCommand(after last: Character) -> Character? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) {
                index += 1
                return Character(UnicodeScalar(byte))
            }
            return last == " " || last == "z" || last == "Z" ? nil : last
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
            var seenDot = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= 48 && byte <= 57 { index += 1; continue }
                if byte == 46 && !seenDot { seenDot = true; index += 1; continue }
                break
            }
            guard index > begin, let text = String(bytes: bytes[begin..<index], encoding: .ascii), let value = Double(text) else { return nil }
            return CGFloat(value)
        }

        /// Arc flags are single digits and may touch what follows: "a5 5 0 017 6".
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == 48 || bytes[index] == 49 else { return nil }
            defer { index += 1 }
            return bytes[index] == 49
        }
    }
}

/// A flat list of the shapes in a bit of SVG markup: `<path>`, `<circle>`, `<ellipse>`, `<rect>` and `<g>` with
/// transforms. The icons and crew parts are kept as the design's own markup and read through this.
public struct SVGElement {
    public let path: CGPath
    public let classes: [String]
    public let fill: String?
    public let stroke: String?
    public let strokeWidth: CGFloat?
    public let lineCap: String?
    public let lineJoin: String?
    public let dash: [CGFloat]

    public func has(_ name: String) -> Bool { classes.contains(name) }

    private struct Inherited {
        var transform = CGAffineTransform.identity
        var classes: [String] = []
        var fill: String?
        var stroke: String?
        var strokeWidth: CGFloat?
        var lineCap: String?
        var lineJoin: String?
    }

    public static func parse(_ markup: String) -> [SVGElement] {
        var elements: [SVGElement] = []
        var stack = [Inherited()]
        var rest = Substring(markup)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let tag = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            if tag.hasPrefix("/") {
                if stack.count > 1 { stack.removeLast() }
                continue
            }
            let selfClosing = tag.hasSuffix("/")
            let body = selfClosing ? tag.dropLast() : tag
            let name = String(body.prefix { $0 != " " })
            let attributes = parseAttributes(body.dropFirst(name.count))
            var state = stack[stack.count - 1]
            if let transform = attributes["transform"] { state.transform = parseTransform(transform).concatenating(state.transform) }
            if let classes = attributes["class"] { state.classes = name == "g" ? state.classes + classes.split(separator: " ").map(String.init) : classes.split(separator: " ").map(String.init) }
            state.fill = attributes["fill"] ?? state.fill
            state.stroke = attributes["stroke"] ?? state.stroke
            state.strokeWidth = attributes["stroke-width"].flatMap { Double($0) }.map { CGFloat($0) } ?? state.strokeWidth
            state.lineCap = attributes["stroke-linecap"] ?? state.lineCap
            state.lineJoin = attributes["stroke-linejoin"] ?? state.lineJoin
            if name == "g" {
                if !selfClosing { stack.append(state) }
                continue
            }
            func number(_ key: String) -> CGFloat { attributes[key].flatMap { Double($0) }.map { CGFloat($0) } ?? 0 }
            let shape: CGPath
            switch name {
            case "path": shape = SVGPath.cgPath(attributes["d"] ?? "")
            case "circle":
                let r = number("r")
                shape = CGPath(ellipseIn: CGRect(x: number("cx") - r, y: number("cy") - r, width: r * 2, height: r * 2), transform: nil)
            case "ellipse":
                let (rx, ry) = (number("rx"), number("ry"))
                shape = CGPath(ellipseIn: CGRect(x: number("cx") - rx, y: number("cy") - ry, width: rx * 2, height: ry * 2), transform: nil)
            case "rect":
                let box = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
                let r = min(number("rx"), min(box.width, box.height) / 2)
                shape = CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
            default: continue
            }
            var transform = state.transform
            let dash = (attributes["stroke-dasharray"] ?? "").split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
            elements.append(SVGElement(path: shape.copy(using: &transform) ?? shape, classes: state.classes, fill: state.fill, stroke: state.stroke,
                                       strokeWidth: state.strokeWidth, lineCap: state.lineCap, lineJoin: state.lineJoin, dash: dash))
        }
        return elements
    }

    private static func parseAttributes(_ text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var rest = text
        while let equals = rest.firstIndex(of: "=") {
            let key = rest[..<equals].trimmingCharacters(in: .whitespaces)
            let afterEquals = rest[rest.index(after: equals)...]
            guard let quote = afterEquals.firstIndex(of: "\""), let end = afterEquals[afterEquals.index(after: quote)...].firstIndex(of: "\"") else { break }
            result[key] = String(afterEquals[afterEquals.index(after: quote)..<end])
            rest = afterEquals[afterEquals.index(after: end)...]
        }
        return result
    }

    /// `rotate(a cx cy)`, `translate(x y)`, `scale(s)`, in the order SVG applies them.
    private static func parseTransform(_ text: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: .whitespaces)
            let values = rest[rest.index(after: open)..<close].split { $0 == " " || $0 == "," }.compactMap { Double($0) }.map { CGFloat($0) }
            var step = CGAffineTransform.identity
            switch name {
            case "translate": step = CGAffineTransform(translationX: values.first ?? 0, y: values.count > 1 ? values[1] : 0)
            case "scale": step = CGAffineTransform(scaleX: values.first ?? 1, y: values.count > 1 ? values[1] : (values.first ?? 1))
            case "rotate":
                let angle = (values.first ?? 0) * .pi / 180
                if values.count >= 3 {
                    step = CGAffineTransform(translationX: -values[1], y: -values[2]).concatenating(CGAffineTransform(rotationAngle: angle))
                        .concatenating(CGAffineTransform(translationX: values[1], y: values[2]))
                } else {
                    step = CGAffineTransform(rotationAngle: angle)
                }
            default: break
            }
            result = step.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}
