//
//  PixelDrawing.swift
//  leanring-buddy
//
//  How a Pixel bot is drawn, in the design's 96-unit box (y down), from PixelParts and PixelFaces. The figure on screen
//  (CrewFigure), the menu bar icon and alert images all draw through here, so they can't drift apart. The look of each
//  piece follows kit/SPEC.md section 2 and the reference renderer web/theo-pixel.js.
//

import AppKit
import ClickyCore

enum PixelDrawing {
    static let box: CGFloat = 96
    /// Parts can poke a little out of the box (a hat's brim, the pencil), so images get this much room on every side.
    static let margin: CGFloat = 8

    enum Tier: Equatable {
        /// Under 22 pt: one big sign on a 7 x 5 grid.
        case micro
        /// 22 to 30 pt: no unlit lights, no glow, bigger lights.
        case lite
        /// 31 pt and up.
        case full

        init(size: CGFloat) {
            self = size < 22 ? .micro : size < 31 ? .lite : .full
        }
    }

    struct Finish {
        let top: UInt32
        let bottom: UInt32
        let dark: UInt32
        let rim: Double
    }

    static func finish(_ name: String) -> Finish {
        let value = PixelParts.finishes[name] ?? PixelParts.finishes["bone"] ?? (0xFFFFFF, 0xCDCDC9, 0xA5A5A2, 0.2)
        return Finish(top: value.top, bottom: value.bottom, dark: value.dark, rim: value.rim)
    }

    // MARK: Geometry

    static let shell = CGRect(x: 8, y: 13, width: 80, height: 68)
    static let shellRadius: CGFloat = 21
    static let screen = CGRect(x: 15, y: 21, width: 66, height: 50)
    static let screenRadius: CGFloat = 13
    static let led = CGPoint(x: 48, y: 76.3)
    static let ledRadius: CGFloat = 1.7
    /// Where the head turns and bobs from (`.hd` in the CSS).
    static let headOrigin = CGPoint(x: 48, y: 84)

    static func screenColor(_ state: PixelState) -> UInt32 {
        switch state {
        case .failed: return 0x12050A
        case .off: return 0x0C0C0E
        default: return 0x060607
        }
    }

    static func ledColor(_ state: PixelState) -> UInt32 {
        state == .idle || state == .off ? 0x3A3A41 : state.hex
    }

    static func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    // MARK: The lights

    struct LightPaths {
        /// Lights at full brightness.
        let full: CGPath
        /// Lights at half brightness ("o" in the data).
        let half: CGPath
        /// The glow behind every lit light, drawn at 20%. Empty when the tier or state has no glow.
        let bloom: CGPath
    }

    private struct Grid {
        let columns: Int
        let rows: Int
        let pitch: CGFloat
        let cell: CGFloat
        let radius: CGFloat
    }

    private static func grid(_ tier: Tier) -> Grid {
        switch tier {
        case .micro: return Grid(columns: 7, rows: 5, pitch: 8.6, cell: 7.2, radius: 1.6)
        case .lite: return Grid(columns: 13, rows: 9, pitch: 4.6, cell: 4.2, radius: 0.9)
        case .full: return Grid(columns: 13, rows: 9, pitch: 4.6, cell: 3.5, radius: 0.9)
        }
    }

    private static func cellRect(column: Int, row: Int, grid: Grid) -> CGRect {
        let x0 = 48 - CGFloat(grid.columns) * grid.pitch / 2 + (grid.pitch - grid.cell) / 2
        let y0 = 46 - CGFloat(grid.rows) * grid.pitch / 2 + (grid.pitch - grid.cell) / 2
        return CGRect(x: x0 + CGFloat(column) * grid.pitch, y: y0 + CGFloat(row) * grid.pitch, width: grid.cell, height: grid.cell)
    }

    private static var lightCache: [String: LightPaths] = [:]

    /// The lights for one frame, in box units. `glow` adds the bloom (full tier only).
    static func lights(_ rows: [String], tier: Tier, glow: Bool) -> LightPaths {
        let key = "\(tier)|\(glow)|" + rows.joined(separator: "/")
        if let cached = lightCache[key] { return cached }
        let grid = grid(tier)
        let full = CGMutablePath()
        let half = CGMutablePath()
        let bloom = CGMutablePath()
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, character) in row.enumerated() where character != "." {
                let rect = cellRect(column: columnIndex, row: rowIndex, grid: grid)
                (character == "o" ? half : full).addRoundedRect(in: rect, cornerWidth: grid.radius, cornerHeight: grid.radius)
                if glow { bloom.addRoundedRect(in: rect.insetBy(dx: -1.6, dy: -1.6), cornerWidth: 2.4, cornerHeight: 2.4) }
            }
        }
        let paths = LightPaths(full: full, half: half, bloom: bloom)
        lightCache[key] = paths
        return paths
    }

    private static var unlitCache: CGPath?

    /// Every light, for the faint unlit grid on the full tier.
    static func unlit() -> CGPath {
        if let unlitCache { return unlitCache }
        let grid = grid(.full)
        let path = CGMutablePath()
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                path.addRoundedRect(in: cellRect(column: column, row: row, grid: grid), cornerWidth: grid.radius, cornerHeight: grid.radius)
            }
        }
        unlitCache = path
        return path
    }

    static func glows(_ state: PixelState, tier: Tier) -> Bool { tier == .full && state != .idle && state != .off }

    /// The rows on the screen for a state: the 13 x 9 frame, or the micro sign.
    static func rows(_ state: PixelState, eye: String, tier: Tier, frame: Int = 0) -> [String] {
        if tier == .micro { return PixelFaces.micro(state) }
        let loop = PixelFaces.frames(state, eye: eye)
        guard !loop.isEmpty else { return [] }
        return loop[frame % loop.count].rows
    }

    /// The awake eyes one row higher: a bot looking up at the pointer.
    static func lookingUp(eye: String) -> [String] {
        guard let first = PixelFaces.frames(.awake, eye: eye).first else { return [] }
        return Array(first.rows.dropFirst()) + [String(repeating: ".", count: PixelFaces.columns)]
    }

    // MARK: Drawing the body

    /// Draws markup from PixelParts with its colours filled in.
    static func drawParts(_ markup: String, look: PixelLook, finish: Finish, in context: CGContext) {
        guard !markup.isEmpty else { return }
        let tinted = markup.replacingOccurrences(of: "\"C\"", with: "\"\(hexString(look.trim))\"")
            .replacingOccurrences(of: "\"D\"", with: "\"\(hexString(finish.dark))\"")
        for element in SVGElement.parse(tinted) {
            if let fill = element.fill.flatMap(NSColor.init(svg:)) {
                context.addPath(element.path)
                context.setFillColor(fill.cgColor)
                context.fillPath()
            }
            if let stroke = element.stroke.flatMap(NSColor.init(svg:)) {
                context.addPath(element.path)
                context.setStrokeColor(stroke.cgColor)
                context.setLineWidth(element.strokeWidth ?? 1)
                context.setLineCap(element.lineCap == "round" ? .round : .butt)
                context.setLineJoin(element.lineJoin == "round" ? .round : .miter)
                context.setLineDash(phase: 0, lengths: element.dash)
                context.strokePath()
            }
        }
    }

    /// Feet, ears, antenna, shell and hat, then the dark recess the screen sits in.
    static func drawBack(look: PixelLook, isDark: Bool, in context: CGContext) {
        let finish = finish(look.finish)
        let dark = NSColor(hex: finish.dark).cgColor
        context.setFillColor(dark)
        for foot in [CGRect(x: 24, y: 78, width: 15, height: 10), CGRect(x: 57, y: 78, width: 15, height: 10)] {
            context.addPath(rounded(foot, 4))
        }
        if look.top != "headset" {
            for ear in [CGRect(x: 3.5, y: 38, width: 8, height: 18), CGRect(x: 84.5, y: 38, width: 8, height: 18)] {
                context.addPath(rounded(ear, 4))
            }
        }
        context.fillPath()
        if !look.hasHat { drawParts(PixelParts.top[look.top] ?? "", look: look, finish: finish, in: context) }

        // The shell: its finish top to bottom, a soft highlight from the top left, a shade low down, and a thin rim.
        let shellPath = rounded(shell, shellRadius)
        context.saveGState()
        context.addPath(shellPath)
        context.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        if let body = CGGradient(colorsSpace: space, colors: [NSColor(hex: finish.top).cgColor, NSColor(hex: finish.bottom).cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(body, start: CGPoint(x: 0, y: shell.minY), end: CGPoint(x: 0, y: shell.maxY), options: [])
        }
        // radialGradient cx .3 cy .08 r .75 in the shell's box: an ellipse, so draw a circle under a stretch.
        if let highlight = CGGradient(colorsSpace: space, colors: [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                      locations: [0, 0.6, 1]) {
            context.saveGState()
            context.translateBy(x: shell.minX + shell.width * 0.3, y: shell.minY + shell.height * 0.08)
            context.scaleBy(x: shell.width, y: shell.height)
            context.drawRadialGradient(highlight, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 0.75, options: [])
            context.restoreGState()
        }
        if let shade = CGGradient(colorsSpace: space, colors: [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.28).cgColor] as CFArray, locations: [0.55, 1]) {
            context.drawLinearGradient(shade, start: CGPoint(x: 0, y: shell.minY), end: CGPoint(x: 0, y: shell.maxY), options: [.drawsBeforeStartLocation])
        }
        context.restoreGState()
        let rimRect = CGRect(x: 8.5, y: 13.5, width: 79, height: 67)
        context.addPath(rounded(rimRect, 20.5))
        context.setStrokeColor(NSColor(white: 1, alpha: finish.rim).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [])
        context.strokePath()
        if !isDark {
            // On white, a light bot needs an outer edge or it melts into the page.
            context.addPath(rounded(rimRect, 20.5))
            context.setStrokeColor(NSColor(white: 0, alpha: 0.16).cgColor)
            context.strokePath()
        }
        if look.hasHat { drawParts(PixelParts.hat[look.top] ?? "", look: look, finish: finish, in: context) }
        context.addPath(rounded(CGRect(x: 13.2, y: 19.2, width: 69.6, height: 53.6), 14.6))
        context.setFillColor(NSColor(white: 0, alpha: 0.3).cgColor)
        context.fillPath()
    }

    /// The glare across the glass and its rim, then the extra (not on the micro tier).
    static func drawFront(look: PixelLook, tier: Tier, in context: CGContext) {
        context.saveGState()
        context.addPath(rounded(screen, screenRadius))
        context.clip()
        let glare = CGMutablePath()
        glare.move(to: CGPoint(x: 21, y: 21))
        glare.addLine(to: CGPoint(x: 41, y: 21))
        glare.addLine(to: CGPoint(x: 25, y: 71))
        glare.addLine(to: CGPoint(x: 5, y: 71))
        glare.closeSubpath()
        context.addPath(glare)
        context.setFillColor(NSColor(white: 1, alpha: 0.045).cgColor)
        context.fillPath()
        context.restoreGState()
        context.addPath(rounded(screen, screenRadius))
        context.setStrokeColor(NSColor(white: 1, alpha: 0.1).cgColor)
        context.setLineWidth(0.8)
        context.setLineDash(phase: 0, lengths: [])
        context.strokePath()
        if tier != .micro { drawParts(PixelParts.extra[look.extra] ?? "", look: look, finish: finish(look.finish), in: context) }
    }

    /// A whole face as one still: for the menu bar, alerts and anything else that isn't a live figure.
    static func drawFace(look: PixelLook, state: PixelState, size: CGFloat, isDark: Bool, rows: [String]? = nil, in context: CGContext) {
        let tier = Tier(size: size)
        context.saveGState()
        if state == .off { context.setAlpha(0.45) } else if state == .idle { context.setAlpha(0.82) }
        drawBack(look: look, isDark: isDark, in: context)
        context.addPath(rounded(screen, screenRadius))
        context.setFillColor(NSColor(hex: screenColor(state)).cgColor)
        context.fillPath()
        if tier == .full, state != .off {
            context.addPath(unlit())
            context.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor)
            context.fillPath()
        }
        let lit = lights(rows ?? Self.rows(state, eye: look.eye, tier: tier), tier: tier, glow: glows(state, tier: tier))
        let color = NSColor(hex: state.hex)
        context.addPath(lit.bloom)
        context.setFillColor(color.withAlphaComponent(0.2).cgColor)
        context.fillPath()
        context.addPath(lit.full)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.addPath(lit.half)
        context.setFillColor(color.withAlphaComponent(0.5).cgColor)
        context.fillPath()
        if tier != .micro {
            context.addEllipse(in: CGRect(x: led.x - ledRadius, y: led.y - ledRadius, width: ledRadius * 2, height: ledRadius * 2))
            context.setFillColor(NSColor(hex: ledColor(state)).cgColor)
            context.fillPath()
        }
        drawFront(look: look, tier: tier, in: context)
        context.restoreGState()
    }

    /// Draws into a bitmap `points` wide (plus the margin) at `scale`, with the 96-unit box set up y-down.
    static func image(points: CGFloat, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        let unit = points / box
        let side = Int(((box + margin * 2) * unit * scale).rounded(.up))
        guard side > 0, let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: unit * scale, y: -unit * scale)
        context.translateBy(x: margin, y: margin)
        draw(context)
        return context.makeImage()
    }

    /// A still face as an image, `size` points square (the margin is trimmed back off).
    static func faceImage(look: PixelLook, state: PixelState, size: CGFloat, isDark: Bool, scale: CGFloat = 2) -> NSImage {
        let unit = size / box
        let side = Int((size * scale).rounded(.up))
        let image = NSImage(size: NSSize(width: size, height: size))
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: unit * scale, y: -unit * scale)
        drawFace(look: look, state: state, size: size, isDark: isDark, in: context)
        if let cgImage = context.makeImage() { image.addRepresentation(NSBitmapImageRep(cgImage: cgImage)) }
        return image
    }

    static func hexString(_ value: UInt32) -> String { String(format: "#%06X", value) }
}

// MARK: - Badges

/// The four badge shapes (pixel-faces.json → badges), plus the plain dot and moon pills use when there is no badge.
enum PixelBadgeKind: String {
    case spin, ask, x, tick

    init?(state: PixelState) {
        switch state {
        case .working, .thinking: self = .spin
        case .needs: self = .ask
        case .failed: self = .x
        case .done: self = .tick
        default: return nil
        }
    }

    var shapeMarkup: String {
        switch self {
        case .spin, .tick: return #"<circle cx="12" cy="12" r="10.5"/>"#
        case .ask: return #"<path d="M12 1.500a10.500 10.500 0 1 1-6.300 18.900L1.300 22.800l1.600-5.500A10.500 10.500 0 0 1 12 1.500z"/>"#
        case .x: return #"<rect x="1.500" y="1.500" width="21" height="21" rx="6.500"/>"#
        }
    }

    var glyphMarkup: String {
        switch self {
        case .spin: return #"<path d="M12 5.800a6.200 6.200 0 1 0 6.200 6.200"/>"#
        case .ask: return #"<path d="M9.200 9a3 3 0 1 1 4.500 2.600c-1 .6-1.500 1.200-1.500 2.300"/><path d="M12.200 17.300v.1"/>"#
        case .x: return #"<path d="M8.200 8.200l7.600 7.600M15.800 8.200l-7.600 7.600"/>"#
        case .tick: return #"<path d="M7.300 12.500l3.300 3.300 6.300-7"/>"#
        }
    }

    /// The shape and glyph in the 24-unit box.
    var shape: CGPath { Self.combined(shapeMarkup) }
    var glyph: CGPath { Self.combined(glyphMarkup) }

    private static func combined(_ markup: String) -> CGPath {
        let path = CGMutablePath()
        SVGElement.parse(markup).forEach { path.addPath($0.path) }
        return path
    }
}

/// What a badge or pill says, which sets its colours.
enum PixelTone {
    case working, ok, needs, failed, done, checking, quiet

    var fill: UInt32 {
        switch self {
        case .working, .ok: return 0x22D391
        case .needs: return 0xFFD938
        case .failed: return 0xFF4A5E
        case .done: return 0xF4F4F5
        case .checking: return 0x8C8C96
        case .quiet: return 0x6E6E78
        }
    }

    var ink: UInt32 {
        switch self {
        case .working, .ok: return 0x04150E
        case .needs: return 0x221A00
        case .failed: return 0x2B050A
        case .done, .checking, .quiet: return 0x0B0B0C
        }
    }

    var badge: PixelBadgeKind? {
        switch self {
        case .working, .checking: return .spin
        case .ok, .done: return .tick
        case .needs: return .ask
        case .failed: return .x
        case .quiet: return nil
        }
    }

    init(state: PixelState) {
        switch state {
        case .working, .thinking: self = .working
        case .needs: self = .needs
        case .failed: self = .failed
        case .done: self = .done
        default: self = .quiet
        }
    }
}

/// A badge as layers: ring, fill, glyph. The spin and the "?" pulse run in Core Animation, so they cost nothing per frame.
final class PixelBadgeLayer: CALayer {
    private let ring = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let glyph = CAShapeLayer()
    private(set) var tone: PixelTone?
    private var side: CGFloat = 0
    private var ringColor: CGColor?
    private var isDark = true
    private var animated = true

    override init() {
        super.init()
        anchorPoint = .zero
        for layer in [ring, fillLayer, glyph] {
            layer.anchorPoint = .zero
            layer.position = .zero
            addSublayer(layer)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `side` is the badge box in points; the 24-unit shape sits inside the CSS's -2.5…26.5 viewBox. A nil ring leaves it out.
    func configure(tone: PixelTone?, side: CGFloat, ring ringColor: CGColor?, isDark: Bool, animated: Bool) {
        let changed = tone != self.tone || side != self.side || ringColor != self.ringColor || isDark != self.isDark || animated != self.animated
        guard changed else { return }
        self.tone = tone
        self.side = side
        self.ringColor = ringColor
        self.isDark = isDark
        self.animated = animated
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        removeAllAnimations()
        glyph.removeAllAnimations()
        guard let tone, let kind = tone.badge else {
            isHidden = true
            return
        }
        isHidden = false
        let unit = side / 29
        var place = CGAffineTransform(scaleX: unit, y: unit).translatedBy(x: 2.5, y: 2.5)
        let shape = kind.shape.copy(using: &place) ?? kind.shape
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ring.path = shape
        ring.fillColor = nil
        ring.strokeColor = ringColor
        ring.lineWidth = 4.6 * unit
        ring.lineJoin = .round
        ring.isHidden = ringColor == nil
        // On white, Done turns dark with a white tick so it doesn't vanish.
        let darkDone = tone == .done && !isDark
        fillLayer.path = shape
        fillLayer.fillColor = NSColor(hex: darkDone ? 0x0B0B0C : tone.fill).cgColor
        // The glyph sits in its own frame so it can turn about the badge's centre.
        glyph.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        glyph.anchorPoint = CGPoint(x: (12 + 2.5) / 29, y: (12 + 2.5) / 29)
        glyph.position = CGPoint(x: side * glyph.anchorPoint.x, y: side * glyph.anchorPoint.y)
        glyph.path = kind.glyph.copy(using: &place)
        glyph.fillColor = nil
        glyph.strokeColor = NSColor(hex: darkDone ? 0xFFFFFF : tone.ink).cgColor
        glyph.lineWidth = 2.7 * unit
        glyph.lineCap = .round
        glyph.lineJoin = .round
        guard animated else { return }
        if kind == .spin {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            // The layer tree is flipped (y down) in the figure but not in a pill; either way it turns once a loop.
            spin.toValue = Double.pi * 2
            spin.duration = 1.1
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            glyph.add(spin, forKey: "spin")
        } else if kind == .ask {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1
            pulse.toValue = 1.13
            pulse.duration = 1.15
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.isRemovedOnCompletion = false
            add(pulse, forKey: "pulse")
        }
    }
}

extension NSColor {
    /// `#rrggbb`, `rgba(r,g,b,a)` or `none`.
    convenience init?(svg text: String) {
        if text.hasPrefix("#") {
            self.init(hex: CrewLook.hex(text))
            return
        }
        guard text.hasPrefix("rgba(") else { return nil }
        let parts = text.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        self.init(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts[3])
    }
}
