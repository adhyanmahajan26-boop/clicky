//
//  CrewFigure.swift
//  leanring-buddy
//
//  A bot's avatar: a little robot built from vector layers, redrawn only when its look or size changes. Motion only moves
//  layers (no redrawing), so a window full of bots costs next to nothing, and CrewDriver stops touching those off screen.
//
//  The motion follows the design's figTick: eyes and head go toward the pointer on springs, the antenna wobbles from the
//  head's speed, and with the pointer still each bot glances around on its own schedule.
//

import AppKit
import ClickyCore
import CoreText
import QuartzCore
import SwiftUI

/// What the view tells the layer tree about one figure.
struct CrewAvatar: View {
    let look: CrewLook
    let size: CGFloat
    var pose: CrewPose = .awake
    /// Pose changes on its own at this time, without the owner redrawing (`done` fading back to resting).
    var poseUntil: (date: Date, then: CrewPose)? = nil
    /// Small tiles that shouldn't move (mosaics, a big list of options).
    var moves = true
    /// Tap to boop, hover to look up.
    var interactive = true
    /// Dims the figure, for a bot that's switched off.
    var dimmed = false

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let figure = CrewFigureRepresentable(look: look, size: size, pose: pose, poseUntil: poseUntil, moves: moves, interactive: interactive, isDark: scheme == .dark, hovering: hovering)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.45 : 1)
            // The drawing itself lets clicks through, so a button around it needs this to know it's there.
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        if interactive {
            figure.onHover { hovering = $0 }
        } else {
            figure
        }
    }
}

private struct CrewFigureRepresentable: NSViewRepresentable {
    let look: CrewLook
    let size: CGFloat
    let pose: CrewPose
    let poseUntil: (date: Date, then: CrewPose)?
    let moves: Bool
    let interactive: Bool
    let isDark: Bool
    let hovering: Bool

    func makeNSView(context: Context) -> CrewFigureNSView {
        let view = CrewFigureNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: CrewFigureNSView, context: Context) { update(view) }

    private func update(_ view: CrewFigureNSView) {
        view.configure(look: look, size: size, isDark: isDark, moves: moves)
        view.setPose(pose, until: poseUntil)
        view.setHovering(hovering)
        view.isBoopable = interactive
    }
}

final class CrewFigureNSView: NSView {
    private var look = CrewLook()
    private var size: CGFloat = 0
    private var isDark = true
    private var moves = true
    private(set) var pose: CrewPose = .awake
    private var poseUntil: (date: Date, then: CrewPose)?
    /// Clicks reach the figure through CrewDriver's event monitor, so a figure inside a button leaves the button working.
    var isBoopable = true

    // MARK: Layers

    private let container = CALayer()
    private let lookLayer = CALayer()
    /// Runs the pose's loop (nod, doze, jiggle) in Core Animation, so it costs the app nothing per frame.
    private let loopLayer = CALayer()
    private let headGroup = CALayer()
    private let eyesGroup = CALayer()
    private let openGroup = CALayer()
    private let blinkGroup = CALayer()
    private let hatGroup = CALayer()
    private let antennaLift = CALayer()
    private let antennaGroup = CALayer()
    private let shutLayer = CAShapeLayer()
    private let happyLayer = CAShapeLayer()
    private let alertLayer = CAShapeLayer()
    private let mouth = CAShapeLayer()
    private let progressTrack = CAShapeLayer()
    private let progressFill = CAShapeLayer()
    private let screen = CAShapeLayer()
    private let snooze = CAShapeLayer()
    private var eyeLayers: [CAShapeLayer] = []
    private var tips: [CAShapeLayer] = []
    private var flag: CAShapeLayer?
    private var arrow: CAShapeLayer?
    private var pencil: CALayer?

    // MARK: Motion state (the design's figTick values, in 48-unit box units and degrees)

    private var eyeX: CGFloat = 0, eyeY: CGFloat = 0
    private var turn: CGFloat = 0, turnSpeed: CGFloat = 0
    private var wobble: CGFloat = 0, wobbleSpeed: CGFloat = 0
    private var glanceX: CGFloat = 0, glanceY: CGFloat = 0
    private var nextGlance: Double = 0
    private var nextBlink: Double = 0
    private var boopStart: Double = -10
    private var hover: CGFloat = 0
    private var hoverTarget: CGFloat = 0
    private let phase = Double.random(in: 0..<20)
    private var currentLevel: TheoMotionLevel = .lively
    private var installedLevel: TheoMotionLevel = .lively
    private var installedPose: CrewPose = .awake
    private var loopsInstalled = false

    /// Where the figure's face is on screen, refreshed now and then by the driver.
    fileprivate(set) var faceOnScreen: CGPoint?
    fileprivate(set) var isOnScreen = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A layer-hosting view: AppKit leaves this tree to us.
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = false
        container.isGeometryFlipped = true
        container.anchorPoint = .zero
        layer?.addSublayer(container)
        nextGlance = CACurrentMediaTime() + Double.random(in: 0..<2.5)
        nextBlink = CACurrentMediaTime() + Double.random(in: 1..<5)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
        if window == nil { CrewDriver.shared.remove(self) } else if moves { CrewDriver.shared.add(self) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        CATransaction.commit()
    }

    private func applyScale() {
        let scale = window?.backingScaleFactor ?? 2
        func walk(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.sublayers?.forEach(walk)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        walk(container)
        CATransaction.commit()
    }

    // MARK: Setting it up

    func configure(look: CrewLook, size: CGFloat, isDark: Bool, moves: Bool) {
        let changed = look != self.look || size != self.size || isDark != self.isDark || container.sublayers == nil
        self.moves = moves
        currentLevel = moves ? DS.Motion.level : .off
        guard changed else { return }
        self.look = look
        self.size = size
        self.isDark = isDark
        rebuild()
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyPose()
        applyMotion(now: CACurrentMediaTime())
        wasMoving = true
    }

    func setPose(_ pose: CrewPose, until: (date: Date, then: CrewPose)?) {
        poseUntil = until
        guard pose != self.pose else { return }
        self.pose = pose
        applyPose()
        applyMotion(now: CACurrentMediaTime())
    }

    func setHovering(_ hovering: Bool) {
        let target: CGFloat = hovering ? 1 : 0
        guard target != hoverTarget else { return }
        hoverTarget = target
        CrewDriver.shared.hurry()
    }

    func boop() {
        boopStart = CACurrentMediaTime()
        turnSpeed += (Bool.random() ? -1 : 1) * 4
        applyPose()
        CrewDriver.shared.hurry()
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        [lookLayer, loopLayer, headGroup, eyesGroup, openGroup, blinkGroup, hatGroup, antennaLift, antennaGroup].forEach {
            $0.sublayers?.forEach { $0.removeFromSuperlayer() }
            $0.anchorPoint = .zero
            $0.bounds = .zero
            $0.position = .zero
            $0.actions = nil
        }
        eyeLayers = []
        tips = []
        flag = nil
        arrow = nil
        pencil = nil

        let k = size / 48
        let shell = NSColor(hex: look.shellHex)
        let glow = NSColor(hex: CrewLook.hex(look.glow))
        let accessory = CrewLook.hex(look.hatColor)
        let mixed: NSColor = {
            if look.isDarkShell { return shell.mixed(with: .white, amount: 0.2) }
            return shell.mixed(with: .black, amount: isDark ? 0.28 : 0.16)
        }()
        let edge: NSColor = look.isDarkShell ? NSColor.white.withAlphaComponent(0.2) : isDark ? .clear : NSColor.black.withAlphaComponent(0.16)

        container.addSublayer(fill("M11 48c0-6.2 5.8-9.4 13-9.4s13 3.2 13 9.4z", mixed, k))
        let extraIsNeck = [.tie, .bowtie, .scarf].contains(look.extra)
        let extraColor = CrewLook.hex(look.extraColor)
        let extraLayers = shapes(CrewParts.extra(look.extra), color: extraColor, k: k)
        if extraIsNeck { extraLayers.forEach(container.addSublayer) }

        container.addSublayer(lookLayer)
        lookLayer.addSublayer(loopLayer)
        loopLayer.addSublayer(headGroup)
        if look.hat != .headset {
            headGroup.addSublayer(rounded(3.6, 17.5, 4.4, 9.5, 2.2, mixed, k))
            headGroup.addSublayer(rounded(40, 17.5, 4.4, 9.5, 2.2, mixed, k))
        }
        let head = rounded(7, 8, 34, 28.5, 11.5, shell, k)
        head.strokeColor = edge.cgColor
        head.lineWidth = k
        headGroup.addSublayer(head)
        configureShape(screen, CGPath(roundedRect: CGRect(x: 11 * k, y: 12.8 * k, width: 26 * k, height: 17.6 * k), cornerWidth: 6.6 * k, cornerHeight: 6.6 * k, transform: nil), fill: NSColor(hex: 0x060606))
        headGroup.addSublayer(screen)
        headGroup.addSublayer(rounded(13, 14.2, 9, 2, 1, NSColor.white.withAlphaComponent(0.07), k))

        // The face. Eyes in the screen-glow colour, with their glow.
        headGroup.addSublayer(eyesGroup)
        eyesGroup.addSublayer(openGroup)
        openGroup.addSublayer(blinkGroup)
        for element in SVGElement.parse(CrewParts.eyes(look.eyes)) {
            let eye = CAShapeLayer()
            configureShape(eye, scaled(element.path, k), fill: glow)
            addGlow(eye, glow, k)
            blinkGroup.addSublayer(eye)
            eyeLayers.append(eye)
        }
        for (layer, data) in [(shutLayer, CrewParts.shut), (happyLayer, CrewParts.happy), (alertLayer, CrewParts.alert)] {
            configureShape(layer, scaled(SVGPath.cgPath(data), k), fill: nil)
            layer.strokeColor = glow.cgColor
            layer.lineWidth = 1.8 * k
            layer.lineCap = .round
            addGlow(layer, glow, k)
            eyesGroup.addSublayer(layer)
        }
        configureShape(mouth, roundedPath(22.2, 26.4, 3.6, 1.4, 0.7, k), fill: glow)
        mouth.opacity = 0.8
        headGroup.addSublayer(mouth)
        configureShape(progressTrack, roundedPath(15, 26.5, 18, 1.6, 0.8, k), fill: NSColor.white.withAlphaComponent(0.12))
        configureShape(progressFill, roundedPath(15, 26.5, 18, 1.6, 0.8, k), fill: glow)
        headGroup.addSublayer(progressTrack)
        headGroup.addSublayer(progressFill)

        if look.extra == .glasses { extraLayers.forEach(headGroup.addSublayer) }
        headGroup.addSublayer(hatGroup)
        shapes(CrewParts.hat(look.hat), color: accessory, k: k).forEach(hatGroup.addSublayer)

        headGroup.addSublayer(antennaLift)
        antennaLift.transform = CATransform3DMakeTranslation(0, CGFloat(look.antennaLift) * k, 0)
        antennaLift.addSublayer(antennaGroup)
        for element in SVGElement.parse(CrewParts.antenna(look.antenna).replacingOccurrences(of: "\"C\"", with: "\"\(look.glow)\"")) {
            let layer = shape(element, k: k)
            antennaGroup.addSublayer(layer)
            if element.has("tip") { tips.append(layer) }
            if element.has("flag") { flag = layer }
            if element.has("arrow") { arrow = layer }
        }
        if look.extra == .badge || look.extra == .pencil {
            let group = CALayer()
            group.anchorPoint = .zero
            group.bounds = .zero
            group.position = .zero
            extraLayers.forEach(group.addSublayer)
            headGroup.addSublayer(group)
            if look.extra == .pencil { pencil = group }
        }

        configureShape(snooze, Self.letterZ(at: CGPoint(x: 36 * k, y: 6 * k), size: 7 * k), fill: NSColor(hex: isDark ? 0x5C5C63 : 0xA3A3A9))
        container.addSublayer(snooze)
        applyScale()
        // New layers have no animations yet.
        loopsInstalled = false
    }

    private func shapes(_ markup: String, color: UInt32, k: CGFloat) -> [CAShapeLayer] {
        let hex = String(format: "#%06x", color)
        return SVGElement.parse(markup.replacingOccurrences(of: "\"C\"", with: "\"\(hex)\"")).map { shape($0, k: k) }
    }

    private func shape(_ element: SVGElement, k: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        let filled = element.fill.flatMap(NSColor.init(svg:))
        configureShape(layer, scaled(element.path, k), fill: filled)
        if let stroke = element.stroke.flatMap(NSColor.init(svg:)) {
            layer.strokeColor = stroke.cgColor
            layer.lineWidth = (element.strokeWidth ?? 1) * k
            layer.lineCap = element.lineCap == "round" ? .round : .butt
            layer.lineJoin = element.lineJoin == "round" ? .round : .miter
            if !element.dash.isEmpty { layer.lineDashPattern = element.dash.map { NSNumber(value: Double($0 * k)) } }
        }
        return layer
    }

    private func fill(_ data: String, _ color: NSColor, _ k: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        configureShape(layer, scaled(SVGPath.cgPath(data), k), fill: color)
        return layer
    }

    private func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: NSColor, _ k: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        configureShape(layer, roundedPath(x, y, w, h, r, k), fill: color)
        return layer
    }

    private func roundedPath(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ k: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x * k, y: y * k, width: w * k, height: h * k), cornerWidth: r * k, cornerHeight: r * k, transform: nil)
    }

    private func scaled(_ path: CGPath, _ k: CGFloat) -> CGPath {
        var scale = CGAffineTransform(scaleX: k, y: k)
        return path.copy(using: &scale) ?? path
    }

    private func configureShape(_ layer: CAShapeLayer, _ path: CGPath, fill: NSColor?) {
        layer.anchorPoint = .zero
        layer.bounds = .zero
        layer.position = .zero
        layer.path = path
        layer.fillColor = fill?.cgColor
        layer.strokeColor = nil
        layer.isHidden = false
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
    }

    private func addGlow(_ layer: CAShapeLayer, _ color: NSColor, _ k: CGFloat) {
        layer.shadowColor = color.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 1.6 * k
        layer.shadowOffset = .zero
    }

    private static func letterZ(at point: CGPoint, size: CGFloat) -> CGPath {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        var character: UniChar = 0x7A
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var place = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: point.x, ty: point.y)
        return CTFontCreatePathForGlyph(font, glyph, &place) ?? CGMutablePath()
    }

    // MARK: Pose

    private var isBooping: Bool { CACurrentMediaTime() - boopStart < 0.7 }
    private var boopWasShowing = false
    private var wasMoving = true

    /// Which face shows. The face is the same set of layers for every pose; this picks.
    private func applyPose() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let needs = pose == .needs
        let color = needs ? NSColor(hex: 0xFF5A5A) : NSColor(hex: CrewLook.hex(look.glow))
        for layer in eyeLayers {
            layer.fillColor = color.cgColor
            layer.shadowColor = color.cgColor
        }
        for layer in [shutLayer, happyLayer, alertLayer] {
            layer.strokeColor = color.cgColor
            layer.shadowColor = color.cgColor
        }
        mouth.fillColor = color.cgColor
        progressFill.fillColor = color.cgColor
        screen.fillColor = NSColor(hex: needs ? 0x2A0707 : 0x060606).cgColor
        let booping = isBooping
        let face: CrewPose = booping ? .done : pose
        openGroup.isHidden = face == .sleep || face == .done || face == .needs
        shutLayer.isHidden = face != .sleep
        happyLayer.isHidden = face != .done
        alertLayer.isHidden = face != .needs
        let dim: Float = face == .sleep ? 0.45 : 1
        eyeLayers.forEach { $0.opacity = dim }
        shutLayer.opacity = dim
        let working = pose == .working
        mouth.isHidden = working
        progressTrack.isHidden = !working
        progressFill.isHidden = !working
        snooze.isHidden = pose != .sleep
        mouth.transform = pose == .done ? about(24, 27.1, CGAffineTransform(scaleX: 1.5, y: 1)) : CATransform3DIdentity
        progressFill.transform = working ? about(15, 27.3, CGAffineTransform(scaleX: 0.55, y: 1)) : CATransform3DIdentity
        if pose == .sleep {
            snooze.opacity = 0.8
            snooze.transform = CATransform3DIdentity
        }
        installLoops()
    }

    /// Everything that loops, handed to Core Animation. Lively gets all of it; Calm only what says something (the progress
    /// bar, a talking mouth, the little z); Off and Reduce Motion hold still.
    private func installLoops() {
        let level = moves ? DS.Motion.level : .off
        guard level != installedLevel || pose != installedPose || !loopsInstalled else { return }
        installedLevel = level
        installedPose = pose
        loopsInstalled = true
        let k = size / 48
        for layer in [loopLayer, mouth, progressFill, snooze, pencil].compactMap({ $0 }) + tips + [flag, arrow].compactMap({ $0 }) { layer.removeAllAnimations() }
        guard level != .off else { return }

        switch pose {
        case .working:
            add(progressFill, "transform", values: [about(15, 27.3, CGAffineTransform(scaleX: 0.1, y: 1)), about(15, 27.3, CGAffineTransform(scaleX: 1, y: 1))], times: [0, 1], seconds: 1.8)
        case .talking:
            add(mouth, "transform", values: [about(24, 27.1, CGAffineTransform(scaleX: 0.8, y: 1)), about(24, 27.1, CGAffineTransform(scaleX: 1.5, y: 2.6))], times: [0, 1], seconds: 0.32, reverses: true)
        case .sleep:
            add(snooze, "transform", values: [CATransform3DMakeTranslation(0, 2 * k, 0), CATransform3DMakeTranslation(3 * k, -4 * k, 0)], times: [0, 1], seconds: 2.4, linear: true)
            add(snooze, "opacity", values: [0, 1, 0], times: [0, 0.4, 1], seconds: 2.4, linear: true)
        default: break
        }
        guard level == .lively else { return }

        func head(_ angle: CGFloat, _ y: CGFloat = 0) -> CATransform3D {
            about(24, 40, CGAffineTransform(translationX: 0, y: y * k).rotated(by: angle * .pi / 180))
        }
        switch pose {
        case .sleep:
            add(loopLayer, "transform", values: [head(0), head(4, 0.6), head(0)], times: [0, 0.5, 1], seconds: 3.6)
        case .working:
            add(loopLayer, "transform", values: [head(0), head(-3, 0.8), head(2), head(0)], times: [0, 0.3, 0.6, 1], seconds: 1.2)
        case .needs:
            add(loopLayer, "transform", values: [head(0), head(0), head(9), head(-8), head(5), head(-2), head(0)], times: [0, 0.72, 0.78, 0.84, 0.9, 0.95, 1], seconds: 2.4)
        default: break
        }
        for tip in tips { add(tip, "opacity", values: [1, 0.25, 1], times: [0, 0.5, 1], seconds: 1.8) }
        if let flag {
            let skew = CGAffineTransform(a: 0.85, b: tan(-12 * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            add(flag, "transform", values: [CATransform3DIdentity, about(24.6, 3.5, skew)], times: [0, 1], seconds: pose == .working ? 0.6 : 1.4, reverses: true)
        }
        if let arrow {
            add(arrow, "transform", values: [CATransform3DIdentity, CATransform3DMakeTranslation(0, -1.2 * k, 0), CATransform3DIdentity], times: [0, 0.5, 1], seconds: 1.4)
        }
        if let pencil, pose == .working {
            add(pencil, "transform", values: [CATransform3DIdentity, about(39, 12, CGAffineTransform(translationX: 0, y: -k).rotated(by: 8 * .pi / 180))], times: [0, 1], seconds: 0.5, reverses: true)
        }
    }

    private func add(_ layer: CALayer, _ keyPath: String, values: [Any], times: [Double], seconds: Double, reverses: Bool = false, linear: Bool = false) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values.map { value -> Any in
            if let transform = value as? CATransform3D { return NSValue(caTransform3D: transform) }
            return value
        }
        animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.duration = seconds
        animation.autoreverses = reverses
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // Each bot on its own beat.
        animation.timeOffset = phase.truncatingRemainder(dividingBy: seconds * (reverses ? 2 : 1))
        animation.timingFunction = CAMediaTimingFunction(name: linear ? .linear : .easeInEaseOut)
        layer.add(animation, forKey: keyPath)
    }

    private func blink() {
        let animation = CAKeyframeAnimation(keyPath: "transform")
        let shut = about(24, 21.5, CGAffineTransform(scaleX: 1, y: 0.12))
        animation.values = [NSValue(caTransform3D: CATransform3DIdentity), NSValue(caTransform3D: shut), NSValue(caTransform3D: CATransform3DIdentity)]
        animation.keyTimes = [0, 0.5, 1]
        animation.duration = 0.14
        blinkGroup.add(animation, forKey: "blink")
    }

    // MARK: Motion

    /// Checks whether this figure is showing and where. Run a few times a second, not every frame.
    func refreshPlacement() {
        guard let window, window.isVisible, CrewDriver.shared.forcesVisible || window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else {
            isOnScreen = false
            return
        }
        isOnScreen = true
        let center = convert(NSPoint(x: bounds.midX, y: bounds.midY + bounds.height * 0.08), to: nil)
        faceOnScreen = window.convertPoint(toScreen: center)
    }

    /// One tick of the springs. `pointer` is global (Cocoa, y up); `pointerIsFresh` means it moved in the last 2.2 s;
    /// `steps` is how many 1/60 s steps to run. Says whether the figure is still moving.
    @discardableResult
    func step(now: Double, pointer: CGPoint?, pointerIsFresh: Bool, steps: Int, level: TheoMotionLevel) -> Bool {
        currentLevel = level
        if let until = poseUntil, Date() >= until.date {
            poseUntil = nil
            pose = until.then
            applyPose()
        }
        var dx: CGFloat
        var dy: CGFloat
        if pointerIsFresh, let pointer, let face = faceOnScreen {
            dx = pointer.x - face.x
            dy = face.y - pointer.y
        } else {
            if level == .lively, now > nextGlance {
                glanceX = .random(in: -220...220)
                glanceY = .random(in: -84...140)
                nextGlance = now + 1.2 + Double.random(in: 0..<3.8)
            } else if level != .lively {
                glanceX = 0
                glanceY = 0
            }
            dx = glanceX
            dy = glanceY
        }
        let distance = max(hypot(dx, dy), 1)
        let reach = min(1, distance / 260)
        var targetX = dx / distance * reach * 2.5
        var targetY = dy / distance * reach * 1.7
        var targetTurn = dx / distance * reach * 8
        if pose == .sleep {
            targetX = 0
            targetY = 1
            targetTurn = 0
        }
        if pose == .working {
            targetY = 1.6
            targetTurn *= 0.3
        }
        for _ in 0..<max(1, steps) {
            eyeX += (targetX - eyeX) * 0.2
            eyeY += (targetY - eyeY) * 0.2
            turnSpeed += (targetTurn - turn) * 0.07
            turnSpeed *= 0.8
            turn += turnSpeed
            wobbleSpeed += (-turnSpeed * 7 - wobble) * 0.12
            wobbleSpeed *= 0.86
            wobble += wobbleSpeed
            hover += (hoverTarget - hover) * 0.14
        }
        if now > nextBlink, pose != .sleep, !openGroup.isHidden {
            blink()
            nextBlink = now + Double.random(in: 2.2...6.5)
        }
        let booping = now - boopStart < 0.75
        let moving = booping || abs(targetX - eyeX) > 0.02 || abs(targetY - eyeY) > 0.02 || abs(targetTurn - turn) > 0.03 || abs(turnSpeed) > 0.01
            || abs(wobble) > 0.03 || abs(wobbleSpeed) > 0.01 || abs(hoverTarget - hover) > 0.005
        if moving || wasMoving { applyMotion(now: now) }
        wasMoving = moving
        return moving
    }

    /// Springs and the boop. The loops run themselves (installLoops).
    private func applyMotion(now: Double) {
        let k = size / 48
        let boopAge = now - boopStart
        let booping = boopAge < 0.7
        if !booping, boopWasShowing {
            boopWasShowing = false
            applyPose()
        }
        boopWasShowing = booping

        var head = CGAffineTransform(translationX: 0, y: -1.5 * hover * k)
        if booping {
            let p = boopAge / 0.7
            let y = CrewKeys.value(progress: p, times: [0, 0.25, 0.55, 1], values: [0, 1, -5, 0])
            let sx = CrewKeys.value(progress: p, times: [0, 0.25, 0.55, 1], values: [1, 1.08, 0.96, 1])
            let sy = CrewKeys.value(progress: p, times: [0, 0.25, 0.55, 1], values: [1, 0.9, 1.05, 1])
            head = CGAffineTransform(translationX: 0, y: y * k).scaledBy(x: sx, y: sy)
        }
        var hat = CGAffineTransform(translationX: 0, y: -1.2 * hover * k).rotated(by: -4 * hover * .pi / 180)
        if booping {
            let p = boopAge / 0.7
            let y = CrewKeys.value(progress: p, times: [0, 0.2, 0.5, 1], values: [0, 0, -4, 0])
            let angle = CrewKeys.value(progress: p, times: [0, 0.2, 0.5, 1], values: [0, 0, -8, 0])
            hat = CGAffineTransform(translationX: 0, y: y * k).rotated(by: angle * .pi / 180)
        }
        let open = 1 + 0.15 * hover

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Only what moved is touched: an untouched layer costs nothing to composite.
        set(lookLayer, about(24, 40, CGAffineTransform(rotationAngle: turn * .pi / 180), k: k))
        set(headGroup, about(24, 40, head, k: k))
        set(hatGroup, about(24, 14, hat, k: k))
        set(antennaGroup, about(24, 9, CGAffineTransform(rotationAngle: wobble * .pi / 180), k: k))
        set(eyesGroup, CATransform3DMakeTranslation(eyeX * k, eyeY * k, 0))
        set(openGroup, about(24, 21.5, CGAffineTransform(scaleX: open, y: open), k: k))
    }

    private func set(_ layer: CALayer, _ transform: CATransform3D) {
        let now = layer.transform
        // Under a hundredth of a point moves nothing you could see.
        if abs(now.m11 - transform.m11) < 0.0005, abs(now.m12 - transform.m12) < 0.0005, abs(now.m21 - transform.m21) < 0.0005,
           abs(now.m22 - transform.m22) < 0.0005, abs(now.m41 - transform.m41) < 0.01, abs(now.m42 - transform.m42) < 0.01 { return }
        layer.transform = transform
    }

    /// A transform around a point in the 48-unit box.
    private func about(_ x: CGFloat, _ y: CGFloat, _ inner: CGAffineTransform, k: CGFloat? = nil) -> CATransform3D {
        let k = k ?? size / 48
        let place = CGAffineTransform(translationX: -x * k, y: -y * k).concatenating(inner).concatenating(CGAffineTransform(translationX: x * k, y: y * k))
        return CATransform3DMakeAffineTransform(place)
    }
}

/// CSS-style keyframes.
enum CrewKeys {
    static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    static func value(at clock: Double, seconds: Double, times: [Double], values: [CGFloat]) -> CGFloat {
        value(progress: (clock / seconds).truncatingRemainder(dividingBy: 1), times: times, values: values)
    }

    static func value(progress: Double, times: [Double], values: [CGFloat]) -> CGFloat {
        guard let upper = times.firstIndex(where: { $0 >= progress }), upper > 0 else { return values.first ?? 0 }
        let span = times[upper] - times[upper - 1]
        let amount = span > 0 ? smooth((progress - times[upper - 1]) / span) : 1
        return values[upper - 1] + (values[upper] - values[upper - 1]) * amount
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
        let parts = text.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        self.init(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts[3])
    }

    func mixed(with other: NSColor, amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: other) ?? self
    }
}

/// The one clock behind every figure. It only runs while a figure is showing: figures in hidden or covered windows, or
/// scrolled away, cost nothing, and Motion Off (or Reduce Motion) stops it altogether.
@MainActor
final class CrewDriver {
    static let shared = CrewDriver()

    private let figures = NSHashTable<CrewFigureNSView>.weakObjects()
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var tickCount = 0
    private var lastPlacement: Double = 0
    private var interval: TimeInterval = 0
    private var lastPointer: CGPoint?
    private var pointerMovedAt: Double = -100
    private var observers: [NSObjectProtocol] = []
    /// A test pointer (global coordinates), so eye-following can be checked without moving the real one.
    var testPointer: CGPoint? {
        didSet { if testPointer != nil { pointerMovedAt = CACurrentMediaTime() } }
    }
    /// The test profile's window can sit behind others while being screenshotted.
    var forcesVisible = TheoProfile.isTest

    private init() {
        installClickMonitor()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        })
    }

    func add(_ figure: CrewFigureNSView) {
        figures.add(figure)
        figure.refreshPlacement()
        wake()
    }

    func remove(_ figure: CrewFigureNSView) {
        figures.remove(figure)
        if figures.count == 0 { schedule(0) }
    }

    /// A click anywhere in Theo: any figure under it gets booped, and the click carries on to whatever's there.
    private func installClickMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { CrewDriver.shared.boop(at: event.locationInWindow, in: event.window) }
            return event
        }
    }

    func boop(at point: NSPoint, in window: NSWindow?) {
        guard let window else { return }
        for figure in figures.allObjects where figure.window === window && figure.isBoopable {
            let box = figure.convert(figure.bounds, to: nil)
            if box.contains(point) { figure.boop() }
        }
    }

    /// Figures that are showing, for tests and the Studio meter.
    var showingCount: Int { figures.allObjects.filter(\.isOnScreen).count }
    var isRunning: Bool { timer != nil && interval < 0.5 }

    private func wake() {
        guard figures.count > 0 else { return schedule(0) }
        let level = DS.Motion.level
        guard level != .off else { return schedule(0) }
        figures.allObjects.forEach { $0.refreshPlacement() }
        schedule(showingCount > 0 ? (level == .calm ? Self.calmInterval : Self.fastInterval) : Self.hiddenInterval)
    }

    /// Something's about to move (a boop, a hover): don't wait for the slow tick.
    func hurry() {
        if interval > 0, interval < Self.hiddenInterval { schedule(Self.fastInterval) }
    }

    private static let fastInterval: TimeInterval = 1.0 / 30
    private static let calmInterval: TimeInterval = 1.0 / 20
    /// Everyone settled and the pointer still: only checking whether a glance or a blink is due.
    private static let restingInterval: TimeInterval = 1.0 / 5
    /// Calm has no idle glances, so there's almost nothing to check for.
    private static let calmRestingInterval: TimeInterval = 0.8
    private static let hiddenInterval: TimeInterval = 1

    private func schedule(_ seconds: TimeInterval) {
        guard seconds != interval || (seconds > 0 && timer == nil) else { return }
        interval = seconds
        timer?.invalidate()
        timer = nil
        guard seconds > 0 else { return }
        lastTick = CACurrentMediaTime()
        let next = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = seconds * 0.2
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let level = DS.Motion.level
        tickCount += 1
        let all = figures.allObjects
        if now - lastPlacement > 0.3 || interval >= Self.hiddenInterval {
            lastPlacement = now
            all.forEach { $0.refreshPlacement() }
            guard level != .off, all.contains(where: \.isOnScreen) else {
                schedule(level == .off ? 0 : Self.hiddenInterval)
                return
            }
        }
        let pointer = testPointer ?? NSEvent.mouseLocation
        if pointer != lastPointer {
            lastPointer = pointer
            pointerMovedAt = now
        }
        // Calm: nobody's eyes chase the pointer, so moving the mouse doesn't redraw every figure in the window.
        let fresh = level == .lively && now - pointerMovedAt < 2.2
        let steps = min(12, max(1, Int(((now - lastTick) * 60).rounded())))
        lastTick = now
        var anyMoving = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for figure in all where figure.isOnScreen {
            if figure.step(now: now, pointer: pointer, pointerIsFresh: fresh, steps: steps, level: level) { anyMoving = true }
        }
        CATransaction.commit()
        schedule(anyMoving ? (level == .calm ? Self.calmInterval : Self.fastInterval) : (level == .calm ? Self.calmRestingInterval : Self.restingInterval))
    }
}
