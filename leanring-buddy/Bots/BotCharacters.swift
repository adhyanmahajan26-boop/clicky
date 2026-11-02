//
//  BotCharacters.swift
//  leanring-buddy
//
//  The bots' avatars: sixteen little characters, each with its own silhouette, eyes, top and gradient, drawn in
//  code so they stay sharp from a 20 pt sidebar row to the 120 pt call screen. A bot keeps one in `NativeBot.avatar`.
//  Theo and Clicky keep their own marks (BotFace's visor, ClickyAvatar).
//
//  At rest they blink and glance now and then. While a bot works it bobs, its eyes glow and its character does its
//  own thing: the ring orbits, the wings flap, the ghost's hem ripples.
//

import SwiftUI

enum BotCharacter: String, CaseIterable, Identifiable {
    case pebble, bolt, orbit, moth, tank, sprout, spark, cloud, ghost, owl, cube, drop, shield, cat, gem, tube

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pebble: return "Pebble"
        case .bolt: return "Bolt"
        case .orbit: return "Orbit"
        case .moth: return "Moth"
        case .tank: return "Tread"
        case .sprout: return "Sprout"
        case .spark: return "Spark"
        case .cloud: return "Cloud"
        case .ghost: return "Boo"
        case .owl: return "Owl"
        case .cube: return "Cube"
        case .drop: return "Drop"
        case .shield: return "Guard"
        case .cat: return "Ginger"
        case .gem: return "Gem"
        case .tube: return "Tube"
        }
    }

    /// The gradient of its body, light to dark. Accents around the avatar (the working ring) use these too.
    var colors: (UInt32, UInt32) {
        switch self {
        case .pebble: return (0x6EEBD6, 0x0E8F86)
        case .bolt: return (0xFCC93A, 0xE85D10)
        case .orbit: return (0x8E97FA, 0x6226D3)
        case .moth: return (0xFC7F93, 0xB9165A)
        case .tank: return (0x9FAEC2, 0x465468)
        case .sprout: return (0xD8F99B, 0x5E9E0C)
        case .spark: return (0xFFD166, 0xEE3F8F)
        case .cloud: return (0xEAF6FF, 0x45B5F5)
        case .ghost: return (0xEEDCFF, 0x8E5EF7)
        case .owl: return (0xD9A671, 0x8A3E0F)
        case .cube: return (0x7FB5FB, 0x1D4ED8)
        case .drop: return (0x7BEAFB, 0x0A6AA6)
        case .shield: return (0xF97A7A, 0x971A1A)
        case .cat: return (0xFFB76B, 0xD6480C)
        case .gem: return (0x27D6EE, 0xA74CF5)
        case .tube: return (0xF4F1EC, 0xA29C94)
        }
    }

    /// The character a bot wears: its pick, else one chosen from its id so it never changes.
    static func of(_ bot: NativeBot) -> BotCharacter {
        if let picked = bot.avatar.flatMap(BotCharacter.init(rawValue:)) { return picked }
        return fromSeed(bot.id)
    }

    static func fromSeed(_ seed: String) -> BotCharacter {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return allCases[Int(hash % UInt64(allCases.count))]
    }

    /// A look nobody else has yet, starting from `preferred`, so a team doesn't end up with twins.
    static func firstFree(preferring preferred: BotCharacter?, among bots: [NativeBot]) -> BotCharacter {
        let taken = Set(bots.compactMap(\.avatar))
        let order = (preferred.map { [$0] } ?? []) + allCases
        return order.first { !taken.contains($0.rawValue) } ?? preferred ?? .pebble
    }
}

/// One character, drawn. `time` nil draws it still.
struct BotCharacterView: View {
    let character: BotCharacter
    let size: CGFloat
    var working = false
    var time: Double? = nil
    var phase: Double = 0

    var body: some View {
        Canvas { context, canvas in
            var painter = CharacterPainter(context: context, w: canvas.width, character: character, working: working, time: time, phase: phase)
            painter.draw()
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

private struct CharacterPainter {
    var context: GraphicsContext
    let w: CGFloat
    let character: BotCharacter
    let working: Bool
    let time: Double?
    let phase: Double

    private var moving: Bool { time != nil }
    private var t: Double { (time ?? 0) + phase }
    /// Small tiles leave out the fine lines; they would only be noise.
    private var detailed: Bool { w >= 28 }

    /// Eyes closing for a blink: 1 open, near 0 shut.
    private var blink: CGFloat {
        guard moving else { return 1 }
        let period = BotFace.blinkPeriod(phase)
        let into = t.truncatingRemainder(dividingBy: period)
        return into < BotFace.blinkSeconds ? max(0.12, abs(into - 0.08) / 0.08) : 1
    }

    /// Where the eyes look, in units of the tile.
    private var glance: CGFloat {
        guard moving else { return 0 }
        if working { return CGFloat(sin(t * 3.2)) * 0.03 }
        let slot = Int(t / BotFace.glanceSeconds) % 4
        return [0, 0.028, 0, -0.028][slot]
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * w) }
    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x * w, y: y * w, width: width * w, height: height * w)
    }
    private func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: rect(x - r, y - r, r * 2, r * 2))
    }
    private func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: rect(x - rx, y - ry, rx * 2, ry * 2))
    }
    private func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> Path {
        Path(roundedRect: rect(x, y, width, height), cornerRadius: radius * w, style: .continuous)
    }

    /// A closed polygon with rounded corners.
    private func polygon(_ points: [(CGFloat, CGFloat)], corner: CGFloat) -> Path {
        var path = Path()
        let scaled = points.map { p($0.0, $0.1) }
        guard scaled.count > 2 else { return path }
        let last = scaled[scaled.count - 1]
        let first = scaled[0]
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for index in scaled.indices {
            let current = scaled[index]
            let next = scaled[(index + 1) % scaled.count]
            path.addArc(tangent1End: current, tangent2End: next, radius: corner * w)
        }
        path.closeSubpath()
        return path
    }

    private func gradient(_ from: UInt32, _ to: UInt32, _ start: CGPoint? = nil, _ end: CGPoint? = nil) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [Color(hex: from), Color(hex: to)]), startPoint: start ?? p(0.2, 0.05), endPoint: end ?? p(0.8, 0.98))
    }

    /// The body: its gradient, a soft light from above, some weight below and a thin rim.
    private func body(_ shape: Path, rim: Double = 0.2) {
        var layer = context
        layer.fill(shape, with: gradient(character.colors.0, character.colors.1))
        var clipped = layer
        clipped.clip(to: shape)
        clipped.fill(Path(ellipseIn: rect(0.1, -0.22, 0.8, 0.56)), with: .color(.white.opacity(0.13)))
        clipped.fill(Path(ellipseIn: rect(-0.1, 0.76, 1.2, 0.5)), with: .color(.black.opacity(0.08)))
        layer.stroke(shape, with: .color(.white.opacity(rim)), lineWidth: max(0.6, w * 0.016))
    }

    /// Everything drawn inside this moves with the eyes: the blink and the glance.
    private func eyes(centerY: CGFloat, _ draw: (inout GraphicsContext) -> Void) {
        var layer = context
        let cy = centerY * w
        layer.translateBy(x: glance * w, y: cy)
        layer.scaleBy(x: 1, y: blink)
        layer.translateBy(x: 0, y: -cy)
        if working { layer.addFilter(.shadow(color: Color(hex: character.colors.0).opacity(0.9), radius: w * 0.05)) }
        draw(&layer)
    }

    private func cartoonEyes(_ context: inout GraphicsContext, x1: CGFloat, x2: CGFloat, y: CGFloat, r: CGFloat, ink: Color = Color(hex: 0x14161C)) {
        for x in [x1, x2] {
            context.fill(circle(x, y, r), with: .color(.white))
            context.fill(circle(x + glance * 0.6, y + r * 0.08, r * 0.56), with: .color(ink))
            if detailed { context.fill(circle(x + glance * 0.6 + r * 0.2, y - r * 0.18, r * 0.17), with: .color(.white)) }
        }
    }

    private func smile(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Color, width: CGFloat = 0.03, from: Double = 25, to: Double = 155) {
        var path = Path()
        path.addArc(center: p(x, y), radius: r * w, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(1, width * w), lineCap: .round))
    }

    private func arcEye(_ context: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Color, width: CGFloat = 0.038) {
        var path = Path()
        path.addArc(center: p(x, y + r * 0.45), radius: r * w, startAngle: .degrees(205), endAngle: .degrees(335), clockwise: false)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(1.1, width * w), lineCap: .round))
    }

    /// Talking while it works: a little mouth opening and closing.
    private func talkingMouth(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ color: Color) {
        let open = (CGFloat(sin(t * 11)) * 0.5 + 0.5) * 0.05 + 0.014
        context.fill(rounded(x - width / 2, y - open / 2, width, open, open / 2), with: .color(color))
    }

    mutating func draw() {
        // While it works the whole character bobs.
        if moving && working { context.translateBy(x: 0, y: CGFloat(sin(t * 2)) * w * 0.018) }
        switch character {
        case .pebble: pebble()
        case .bolt: bolt()
        case .orbit: orbit()
        case .moth: moth()
        case .tank: tank()
        case .sprout: sprout()
        case .spark: spark()
        case .cloud: cloud()
        case .ghost: ghost()
        case .owl: owl()
        case .cube: cube()
        case .drop: drop()
        case .shield: shield()
        case .cat: cat()
        case .gem: gem()
        case .tube: tube()
        }
    }

    // MARK: - The characters

    /// A smooth round stone, big friendly eyes and rosy cheeks.
    private func pebble() {
        body(rounded(0.09, 0.13, 0.82, 0.76, 0.34))
        eyes(centerY: 0.44) { cartoonEyes(&$0, x1: 0.35, x2: 0.65, y: 0.44, r: 0.115) }
        if detailed {
            context.fill(ellipse(0.22, 0.6, 0.055, 0.035), with: .color(Color(hex: 0xFF8FA3).opacity(0.65)))
            context.fill(ellipse(0.78, 0.6, 0.055, 0.035), with: .color(Color(hex: 0xFF8FA3).opacity(0.65)))
        }
        if working && moving { talkingMouth(0.5, 0.68, 0.11, Color(hex: 0x0B3B3A)) } else { smile(0.5, 0.58, 0.085, Color(hex: 0x0B3B3A)) }
    }

    /// A hexagonal head under a lightning bolt, with a glowing visor.
    private func bolt() {
        let flicker = moving && working ? 0.75 + 0.25 * sin(t * 15) : 1
        context.fill(polygon([(0.56, 0.0), (0.42, 0.14), (0.5, 0.15), (0.43, 0.27), (0.6, 0.12), (0.51, 0.11)], corner: 0.008),
                     with: .color(Color(hex: 0xFFF3B0).opacity(flicker)))
        body(polygon([(0.5, 0.17), (0.9, 0.36), (0.9, 0.76), (0.5, 0.97), (0.1, 0.76), (0.1, 0.36)], corner: 0.06))
        context.fill(rounded(0.2, 0.41, 0.6, 0.2, 0.09), with: .color(Color(hex: 0x2B1608)))
        eyes(centerY: 0.51) { layer in
            layer.fill(rounded(0.26, 0.47, 0.48, 0.08, 0.04), with: .color(Color(hex: 0xFFD84D)))
            layer.fill(rounded(0.33, 0.48, 0.1, 0.06, 0.03), with: .color(.white))
            layer.fill(rounded(0.57, 0.48, 0.1, 0.06, 0.03), with: .color(.white))
        }
        if detailed {
            for index in 0..<3 {
                context.fill(rounded(0.4 + CGFloat(index) * 0.075, 0.71, 0.05, 0.06, 0.012), with: .color(Color(hex: 0x2B1608).opacity(0.65)))
            }
        }
    }

    /// A little planet with one big eye and a ring going round it.
    private func orbit() {
        let tilt = moving && working ? t * 1.3 : 0
        let ring = ellipse(0.5, 0.5, 0.47, 0.125).applying(ringTransform(tilt))
        let hideFront = Path(CGRect(x: 0, y: 0, width: w, height: w))
        var behind = context
        behind.clip(to: Path(ellipseIn: rect(-0.4, -0.5, 1.8, 1.0)).applying(ringTransform(tilt)).intersection(hideFront))
        behind.stroke(ring, with: .color(Color(hex: 0xD6CCFF)), lineWidth: max(1.2, w * 0.042))
        body(circle(0.5, 0.5, 0.33))
        var front = context
        front.clip(to: Path(rect(-0.5, 0.5, 2, 1)).applying(ringTransform(tilt)))
        front.stroke(ring, with: .color(Color(hex: 0xE9E4FF)), lineWidth: max(1.2, w * 0.042))
        eyes(centerY: 0.47) { layer in
            layer.fill(circle(0.5, 0.47, 0.145), with: .color(.white))
            layer.fill(circle(0.5 + glance * 0.7, 0.47, 0.09), with: .color(Color(hex: 0x4C1DB5)))
            layer.fill(circle(0.5 + glance * 0.7, 0.47, 0.046), with: .color(Color(hex: 0x120733)))
            if detailed { layer.fill(circle(0.53 + glance * 0.7, 0.44, 0.022), with: .color(.white)) }
        }
    }

    private func ringTransform(_ spin: Double) -> CGAffineTransform {
        let centre = p(0.5, 0.5)
        return CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: -0.32 + sin(spin) * 0.12)
            .translatedBy(x: -centre.x, y: -centre.y)
    }

    /// A soft dome with wings, feathery feelers and sleepy eyes.
    private func moth() {
        let flap = moving && working ? CGFloat(sin(t * 9)) * 0.03 : 0
        for (x, sign) in [(CGFloat(0.16), CGFloat(-1)), (CGFloat(0.84), CGFloat(1))] {
            let wing = ellipse(x + sign * flap, 0.55, 0.15 + flap, 0.27)
            context.fill(wing, with: gradient(0xFFD0DA, 0xF0568A))
            context.stroke(wing, with: .color(.white.opacity(0.25)), lineWidth: max(0.5, w * 0.012))
        }
        for (start, control, end) in [((0.42, 0.26), (0.36, 0.04), (0.2, 0.1)), ((0.58, 0.26), (0.64, 0.04), (0.8, 0.1))] as [((CGFloat, CGFloat), (CGFloat, CGFloat), (CGFloat, CGFloat))] {
            var feeler = Path()
            feeler.move(to: p(start.0, start.1))
            feeler.addQuadCurve(to: p(end.0, end.1), control: p(control.0, control.1))
            context.stroke(feeler, with: .color(Color(hex: 0xFFC2CF)), style: StrokeStyle(lineWidth: max(1, w * 0.028), lineCap: .round))
            context.fill(ellipse(end.0, end.1, 0.05, 0.035), with: .color(Color(hex: 0xFFC2CF)))
        }
        var dome = Path()
        dome.move(to: p(0.23, 0.82))
        dome.addCurve(to: p(0.77, 0.82), control1: p(0.14, 0.14), control2: p(0.86, 0.14))
        dome.addQuadCurve(to: p(0.23, 0.82), control: p(0.5, 0.97))
        dome.closeSubpath()
        body(dome)
        eyes(centerY: 0.53) { layer in
            for x in [CGFloat(0.39), 0.61] {
                layer.fill(circle(x, 0.53, 0.082), with: .color(.white))
                layer.fill(circle(x + glance * 0.5, 0.55, 0.05), with: .color(Color(hex: 0x3A0B22)))
                // The lid.
                layer.fill(Path(rect(x - 0.09, 0.44, 0.18, 0.085)), with: .color(Color(hex: 0xE34C78)))
            }
        }
        smile(0.5, 0.62, 0.05, Color(hex: 0x4A0D2B), width: 0.024)
    }

    /// A blocky little machine on treads, square lime eyes and a grille.
    private func tank() {
        context.fill(rounded(0.42, 0.06, 0.16, 0.12, 0.03), with: .color(Color(hex: 0x6B7A8F)))
        context.fill(circle(0.5, 0.06, 0.04), with: .color(Color(hex: 0xBEF264).opacity(moving && working ? 0.5 + 0.5 * sin(t * 7) : 1)))
        context.fill(rounded(0.03, 0.34, 0.1, 0.22, 0.04), with: .color(Color(hex: 0x56637A)))
        context.fill(rounded(0.87, 0.34, 0.1, 0.22, 0.04), with: .color(Color(hex: 0x56637A)))
        body(rounded(0.1, 0.16, 0.8, 0.56, 0.1))
        // Treads.
        context.fill(rounded(0.13, 0.75, 0.74, 0.2, 0.1), with: .color(Color(hex: 0x262C38)))
        if detailed {
            for index in 0..<4 {
                let x = 0.255 + CGFloat(index) * 0.163
                context.fill(circle(x, 0.85, 0.052), with: .color(Color(hex: 0x8794A8)))
            }
        }
        context.fill(rounded(0.19, 0.27, 0.62, 0.22, 0.05), with: .color(Color(hex: 0x1B2029)))
        eyes(centerY: 0.38) { layer in
            for x in [CGFloat(0.29), 0.57] {
                layer.fill(rounded(x, 0.32, 0.14, 0.12, 0.022), with: .color(Color(hex: 0xBEF264)))
            }
        }
        if detailed {
            for index in 0..<5 {
                context.fill(rounded(0.33 + CGFloat(index) * 0.075, 0.56, 0.035, 0.09, 0.012), with: .color(Color(hex: 0x1B2029).opacity(0.65)))
            }
        }
    }

    /// A round seed with two leaves growing from its head.
    private func sprout() {
        let sway = moving ? CGFloat(sin(t * (working ? 4 : 0.9))) * 0.018 : 0
        var stem = Path()
        stem.move(to: p(0.5, 0.3))
        stem.addQuadCurve(to: p(0.5 + sway, 0.14), control: p(0.47, 0.22))
        context.stroke(stem, with: .color(Color(hex: 0x15803D)), style: StrokeStyle(lineWidth: max(1.2, w * 0.04), lineCap: .round))
        let tip = (0.5 + sway, CGFloat(0.15))
        var left = Path()
        left.move(to: p(tip.0, tip.1))
        left.addCurve(to: p(tip.0 - 0.27, tip.1 - 0.05), control1: p(tip.0 - 0.06, tip.1 - 0.16), control2: p(tip.0 - 0.22, tip.1 - 0.15))
        left.addCurve(to: p(tip.0, tip.1), control1: p(tip.0 - 0.2, tip.1 + 0.08), control2: p(tip.0 - 0.07, tip.1 + 0.07))
        context.fill(left, with: gradient(0x4ADE80, 0x15803D, p(tip.0 - 0.27, tip.1 - 0.1), p(tip.0, tip.1)))
        var right = Path()
        right.move(to: p(tip.0, tip.1))
        right.addCurve(to: p(tip.0 + 0.3, tip.1 - 0.1), control1: p(tip.0 + 0.06, tip.1 - 0.15), control2: p(tip.0 + 0.24, tip.1 - 0.2))
        right.addCurve(to: p(tip.0, tip.1), control1: p(tip.0 + 0.24, tip.1 + 0.05), control2: p(tip.0 + 0.08, tip.1 + 0.08))
        context.fill(right, with: gradient(0x86EFAC, 0x16A34A, p(tip.0 + 0.3, tip.1 - 0.12), p(tip.0, tip.1)))
        body(ellipse(0.5, 0.62, 0.37, 0.34))
        eyes(centerY: 0.56) { layer in
            arcEye(&layer, 0.37, 0.56, 0.075, Color(hex: 0x1F3A0A))
            arcEye(&layer, 0.63, 0.56, 0.075, Color(hex: 0x1F3A0A))
        }
        if working && moving { talkingMouth(0.5, 0.74, 0.11, Color(hex: 0x1F3A0A)) } else {
            context.fill(ellipse(0.5, 0.72, 0.06, 0.042), with: .color(Color(hex: 0x1F3A0A)))
            if detailed { context.fill(ellipse(0.5, 0.735, 0.034, 0.02), with: .color(Color(hex: 0xFB7185))) }
        }
    }

    /// A bursting star with wide-open eyes and a tiny "oh".
    private func spark() {
        let spin = moving && working ? t * 0.9 : 0
        var points: [(CGFloat, CGFloat)] = []
        let tips = 10
        for index in 0..<(tips * 2) {
            let radius: CGFloat = index.isMultiple(of: 2) ? 0.5 : 0.31
            let angle = Double(index) * .pi / Double(tips) - .pi / 2 + spin
            points.append((0.5 + CGFloat(cos(angle)) * radius, 0.5 + CGFloat(sin(angle)) * radius))
        }
        body(polygon(points, corner: 0.022))
        eyes(centerY: 0.46) { layer in
            for x in [CGFloat(0.39), 0.61] {
                layer.fill(ellipse(x, 0.46, 0.058, 0.08), with: .color(Color(hex: 0x3D0B2A)))
                if detailed { layer.fill(circle(x + 0.016, 0.43, 0.02), with: .color(.white)) }
            }
        }
        context.fill(circle(0.5, 0.62, working && moving ? 0.022 + 0.026 * (CGFloat(sin(t * 11)) * 0.5 + 0.5) : 0.033), with: .color(Color(hex: 0x3D0B2A)))
    }

    /// A puffy cloud, eyes closed, quite content.
    private func cloud() {
        var puff = Path()
        puff.addPath(rounded(0.06, 0.48, 0.88, 0.38, 0.19))
        puff.addPath(circle(0.32, 0.47, 0.2))
        puff.addPath(circle(0.58, 0.37, 0.25))
        puff.addPath(circle(0.77, 0.54, 0.16))
        let shape = puff.normalized(eoFill: false)
        body(shape, rim: 0.5)
        let ink = Color(hex: 0x12436B)
        eyes(centerY: 0.56) { layer in
            arcEye(&layer, 0.37, 0.56, 0.07, ink)
            arcEye(&layer, 0.63, 0.56, 0.07, ink)
        }
        if detailed {
            context.fill(ellipse(0.26, 0.68, 0.05, 0.03), with: .color(Color(hex: 0xFF9CB5).opacity(0.75)))
            context.fill(ellipse(0.74, 0.68, 0.05, 0.03), with: .color(Color(hex: 0xFF9CB5).opacity(0.75)))
        }
        if working && moving { talkingMouth(0.5, 0.71, 0.1, ink) } else { smile(0.5, 0.64, 0.055, ink, width: 0.026) }
    }

    /// A small friendly ghost whose hem ripples while it works.
    private func ghost() {
        let ripple = moving && working ? CGFloat(sin(t * 6)) * 0.02 : 0
        var shape = Path()
        shape.move(to: p(0.13, 0.9 + ripple))
        shape.addLine(to: p(0.13, 0.46))
        shape.addCurve(to: p(0.87, 0.46), control1: p(0.13, -0.02), control2: p(0.87, -0.02))
        shape.addLine(to: p(0.87, 0.9 - ripple))
        shape.addQuadCurve(to: p(0.68, 0.9 + ripple), control: p(0.775, 0.76 - ripple))
        shape.addQuadCurve(to: p(0.5, 0.9 - ripple), control: p(0.59, 1.02 + ripple))
        shape.addQuadCurve(to: p(0.32, 0.9 + ripple), control: p(0.41, 0.76 - ripple))
        shape.addQuadCurve(to: p(0.13, 0.9 + ripple), control: p(0.225, 1.02 + ripple))
        shape.closeSubpath()
        body(shape, rim: 0.4)
        eyes(centerY: 0.43) { layer in
            for x in [CGFloat(0.37), 0.63] {
                layer.fill(ellipse(x, 0.43, 0.066, 0.1), with: .color(Color(hex: 0x1E1033)))
                if detailed { layer.fill(circle(x + 0.018, 0.39, 0.022), with: .color(.white)) }
            }
        }
        context.fill(ellipse(0.5, 0.61, 0.038, working && moving ? 0.03 + 0.02 * (CGFloat(sin(t * 11)) * 0.5 + 0.5) : 0.03), with: .color(Color(hex: 0x1E1033)))
    }

    /// An owl: ear tufts, huge round eyes, a small beak, a feathered chest.
    private func owl() {
        let shape = polygon([(0.13, 0.03), (0.33, 0.17), (0.67, 0.17), (0.87, 0.03), (0.93, 0.56), (0.76, 0.95), (0.24, 0.95), (0.07, 0.56)], corner: 0.11)
        body(shape)
        if detailed {
            for row in 0..<2 {
                for column in 0..<(3 - row) {
                    let x = 0.36 + CGFloat(column) * 0.14 + CGFloat(row) * 0.07
                    let y = 0.74 + CGFloat(row) * 0.09
                    var feather = Path()
                    feather.addArc(center: p(x, y), radius: 0.05 * w, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
                    context.stroke(feather, with: .color(Color(hex: 0xFBE0B8).opacity(0.65)), style: StrokeStyle(lineWidth: max(0.7, w * 0.018), lineCap: .round))
                }
            }
        }
        for x in [CGFloat(0.33), 0.67] { context.fill(circle(x, 0.43, 0.185), with: .color(Color(hex: 0xFBE8CE))) }
        eyes(centerY: 0.43) { layer in
            for x in [CGFloat(0.33), 0.67] {
                layer.fill(circle(x, 0.43, 0.115), with: .color(Color(hex: 0xF59E0B)))
                layer.fill(circle(x + glance * 0.7, 0.43, 0.072), with: .color(Color(hex: 0x1A0F05)))
                if detailed { layer.fill(circle(x + glance * 0.7 + 0.024, 0.405, 0.022), with: .color(.white)) }
            }
        }
        context.fill(polygon([(0.44, 0.52), (0.56, 0.52), (0.5, 0.65)], corner: 0.012), with: .color(Color(hex: 0xF97316)))
    }

    /// An isometric block looking two ways at once, an eye on each face.
    private func cube() {
        let top = polygon([(0.5, 0.05), (0.92, 0.27), (0.5, 0.49), (0.08, 0.27)], corner: 0.03)
        let left = polygon([(0.08, 0.31), (0.48, 0.53), (0.48, 0.96), (0.08, 0.74)], corner: 0.03)
        let right = polygon([(0.92, 0.31), (0.52, 0.53), (0.52, 0.96), (0.92, 0.74)], corner: 0.03)
        context.fill(top, with: gradient(0xC4DEFF, 0x7FB5FB))
        context.fill(left, with: gradient(0x5B9BF8, 0x2563EB))
        context.fill(right, with: gradient(0x2F6BEA, 0x1538A8))
        eyes(centerY: 0.61) { layer in
            for (x, y) in [(CGFloat(0.29), CGFloat(0.59)), (0.71, 0.59)] {
                layer.fill(ellipse(x, y, 0.065, 0.082), with: .color(.white))
                layer.fill(circle(x + glance * 0.6, y + 0.01, 0.034), with: .color(Color(hex: 0x0A1A44)))
            }
        }
        if working && moving { talkingMouth(0.5, 0.8, 0.09, .white.opacity(0.92)) } else {
            var mouth = Path()
            mouth.move(to: p(0.38, 0.72)); mouth.addLine(to: p(0.5, 0.8)); mouth.addLine(to: p(0.62, 0.72))
            context.stroke(mouth, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: max(1, w * 0.026), lineCap: .round, lineJoin: .round))
        }
    }

    /// A water drop, winking, with a bright streak of light.
    private func drop() {
        var shape = Path()
        shape.move(to: p(0.5, 0.02))
        shape.addCurve(to: p(0.86, 0.62), control1: p(0.62, 0.22), control2: p(0.86, 0.38))
        shape.addCurve(to: p(0.14, 0.62), control1: p(0.86, 1.12), control2: p(0.14, 1.12))
        shape.addCurve(to: p(0.5, 0.02), control1: p(0.14, 0.38), control2: p(0.38, 0.22))
        shape.closeSubpath()
        body(shape, rim: 0.3)
        if detailed {
            var streak = Path()
            streak.move(to: p(0.3, 0.46))
            streak.addQuadCurve(to: p(0.23, 0.68), control: p(0.23, 0.56))
            context.stroke(streak, with: .color(.white.opacity(0.65)), style: StrokeStyle(lineWidth: max(1, w * 0.032), lineCap: .round))
        }
        let ink = Color(hex: 0x05283F)
        eyes(centerY: 0.58) { layer in
            arcEye(&layer, 0.38, 0.58, 0.065, ink)
            layer.fill(circle(0.63, 0.58, 0.055), with: .color(ink))
            if detailed { layer.fill(circle(0.645, 0.565, 0.016), with: .color(.white)) }
        }
        if working && moving { talkingMouth(0.5, 0.75, 0.1, ink) } else { smile(0.5, 0.67, 0.06, ink, width: 0.028) }
    }

    /// A heraldic shield with stern, glowing slits.
    private func shield() {
        var shape = Path()
        shape.move(to: p(0.5, 0.02))
        shape.addLine(to: p(0.88, 0.14))
        shape.addCurve(to: p(0.5, 0.98), control1: p(0.92, 0.56), control2: p(0.74, 0.86))
        shape.addCurve(to: p(0.12, 0.14), control1: p(0.26, 0.86), control2: p(0.08, 0.56))
        shape.closeSubpath()
        body(shape)
        if detailed {
            var band = Path()
            band.move(to: p(0.5, 0.05)); band.addLine(to: p(0.5, 0.95))
            context.stroke(band, with: .color(.white.opacity(0.14)), lineWidth: w * 0.05)
        }
        eyes(centerY: 0.41) { layer in
            layer.fill(polygon([(0.2, 0.34), (0.45, 0.42), (0.43, 0.49), (0.21, 0.43)], corner: 0.012), with: .color(Color(hex: 0xFFE27A)))
            layer.fill(polygon([(0.8, 0.34), (0.55, 0.42), (0.57, 0.49), (0.79, 0.43)], corner: 0.012), with: .color(Color(hex: 0xFFE27A)))
        }
        if working && moving { talkingMouth(0.5, 0.67, 0.14, Color(hex: 0x3D0606)) } else {
            context.fill(rounded(0.41, 0.645, 0.18, 0.04, 0.02), with: .color(Color(hex: 0x3D0606)))
        }
    }

    /// A ginger cat: pointed ears, almond eyes, a pink nose and whiskers.
    private func cat() {
        let twitch = moving && working ? CGFloat(sin(t * 8)) * 0.012 : 0
        for points in [[(0.12, 0.42), (0.14 - twitch, 0.04), (0.45, 0.24)], [(0.88, 0.42), (0.86 + twitch, 0.04), (0.55, 0.24)]] as [[(CGFloat, CGFloat)]] {
            context.fill(polygon(points, corner: 0.03), with: gradient(0xFFB76B, 0xE8631B))
        }
        if detailed {
            context.fill(polygon([(0.19, 0.3), (0.2 - twitch, 0.14), (0.34, 0.24)], corner: 0.015), with: .color(Color(hex: 0xFFC6C6)))
            context.fill(polygon([(0.81, 0.3), (0.8 + twitch, 0.14), (0.66, 0.24)], corner: 0.015), with: .color(Color(hex: 0xFFC6C6)))
        }
        body(ellipse(0.5, 0.58, 0.42, 0.37))
        if detailed {
            for x in [CGFloat(0.42), 0.5, 0.58] {
                context.fill(rounded(x - 0.018, 0.21, 0.036, 0.12, 0.018), with: .color(Color(hex: 0xB43A08).opacity(0.7)))
            }
        }
        eyes(centerY: 0.53) { layer in
            for x in [CGFloat(0.33), 0.67] {
                layer.fill(ellipse(x, 0.53, 0.092, 0.07), with: .color(Color(hex: 0xD9F99D)))
                layer.fill(ellipse(x + glance * 0.6, 0.53, 0.024, 0.066), with: .color(Color(hex: 0x14210A)))
            }
        }
        context.fill(polygon([(0.46, 0.65), (0.54, 0.65), (0.5, 0.7)], corner: 0.008), with: .color(Color(hex: 0xFF8FA3)))
        if detailed {
            for (x1, x2, y1, y2) in [(0.25, 0.04, 0.7, 0.67), (0.25, 0.05, 0.75, 0.78), (0.75, 0.96, 0.7, 0.67), (0.75, 0.95, 0.75, 0.78)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                var whisker = Path()
                whisker.move(to: p(x1, y1)); whisker.addLine(to: p(x2, y2))
                context.stroke(whisker, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: max(0.6, w * 0.012), lineCap: .round))
            }
        }
        smile(0.46, 0.69, 0.04, Color(hex: 0x5A1D04), width: 0.018, from: 10, to: 150)
        smile(0.54, 0.69, 0.04, Color(hex: 0x5A1D04), width: 0.018, from: 30, to: 170)
    }

    /// A cut gem whose facets catch the light, with a sparkle while it works.
    private func gem() {
        let outline = polygon([(0.24, 0.12), (0.76, 0.12), (0.97, 0.37), (0.5, 0.97), (0.03, 0.37)], corner: 0.022)
        context.fill(outline, with: gradient(0x27D6EE, 0xA74CF5))
        var clipped = context
        clipped.clip(to: outline)
        let facets: [([(CGFloat, CGFloat)], Double)] = [
            ([(0.24, 0.12), (0.5, 0.12), (0.34, 0.37), (0.03, 0.37)], 0.26),
            ([(0.5, 0.12), (0.76, 0.12), (0.97, 0.37), (0.66, 0.37)], 0.1),
            ([(0.34, 0.37), (0.66, 0.37), (0.5, 0.97)], 0.14),
            ([(0.03, 0.37), (0.34, 0.37), (0.5, 0.97)], 0.03),
        ]
        for (points, light) in facets {
            var facet = Path()
            facet.addLines(points.map { p($0.0, $0.1) })
            facet.closeSubpath()
            clipped.fill(facet, with: .color(.white.opacity(light)))
        }
        clipped.fill(Path(rect(0, 0.37, 1, 0.012)), with: .color(.white.opacity(0.25)))
        context.stroke(outline, with: .color(.white.opacity(0.35)), lineWidth: max(0.6, w * 0.016))
        eyes(centerY: 0.47) { layer in
            for x in [CGFloat(0.39), 0.61] {
                layer.fill(circle(x, 0.47, 0.058), with: .color(Color(hex: 0x12062B)))
                if detailed { layer.fill(circle(x + 0.016, 0.455, 0.017), with: .color(.white)) }
            }
        }
        smile(0.5, 0.54, 0.05, Color(hex: 0x12062B), width: 0.024)
        if detailed {
            let shine = moving && working ? 0.5 + 0.5 * sin(t * 5) : 0.9
            var sparkle = Path()
            let centre = (x: CGFloat(0.8), y: CGFloat(0.16))
            sparkle.addLines([p(centre.x, centre.y - 0.08), p(centre.x + 0.018, centre.y - 0.018), p(centre.x + 0.08, centre.y), p(centre.x + 0.018, centre.y + 0.018),
                              p(centre.x, centre.y + 0.08), p(centre.x - 0.018, centre.y + 0.018), p(centre.x - 0.08, centre.y), p(centre.x - 0.018, centre.y - 0.018)])
            sparkle.closeSubpath()
            context.fill(sparkle, with: .color(.white.opacity(shine)))
        }
    }

    /// An old cream TV with rabbit ears and a green face on its screen.
    private func tube() {
        for end in [(CGFloat(0.26), CGFloat(0.03)), (0.74, 0.03)] {
            var ear = Path()
            ear.move(to: p(0.5, 0.22)); ear.addLine(to: p(end.0, end.1))
            context.stroke(ear, with: .color(Color(hex: 0x8C8680)), style: StrokeStyle(lineWidth: max(1, w * 0.026), lineCap: .round))
            context.fill(circle(end.0, end.1, 0.028), with: .color(Color(hex: 0xE1DAD0)))
        }
        body(rounded(0.06, 0.2, 0.88, 0.66, 0.1), rim: 0.5)
        context.fill(rounded(0.25, 0.86, 0.14, 0.09, 0.02), with: .color(Color(hex: 0x7C766F)))
        context.fill(rounded(0.61, 0.86, 0.14, 0.09, 0.02), with: .color(Color(hex: 0x7C766F)))
        let screen = rounded(0.13, 0.27, 0.58, 0.52, 0.08)
        context.fill(screen, with: gradient(0x0E3B22, 0x03140B))
        if detailed {
            for (y, color) in [(CGFloat(0.36), 0xE85D10), (0.52, 0x8C8680), (0.66, 0x8C8680)] as [(CGFloat, UInt32)] {
                context.fill(circle(0.83, y, 0.042), with: .color(Color(hex: color)))
            }
            var lines = context
            lines.clip(to: screen)
            let scroll = moving && working ? CGFloat((t * 0.25).truncatingRemainder(dividingBy: 0.06)) : 0
            for index in 0..<10 {
                lines.fill(Path(rect(0.13, 0.27 + CGFloat(index) * 0.06 + scroll, 0.58, 0.012)), with: .color(.black.opacity(0.26)))
            }
        }
        let green = Color(hex: 0x4ADE80)
        eyes(centerY: 0.45) { layer in
            for x in [CGFloat(0.28), 0.48] {
                layer.fill(Path(rect(x, 0.39, 0.075, 0.11)), with: .color(green))
            }
        }
        if working && moving {
            talkingMouth(0.42, 0.63, 0.18, green)
        } else {
            context.fill(Path(rect(0.31, 0.6, 0.22, 0.045)), with: .color(green))
            context.fill(Path(rect(0.27, 0.56, 0.045, 0.045)), with: .color(green))
            context.fill(Path(rect(0.525, 0.56, 0.045, 0.045)), with: .color(green))
        }
    }
}
