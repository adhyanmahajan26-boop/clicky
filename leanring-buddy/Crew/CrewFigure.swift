//
//  CrewFigure.swift
//  leanring-buddy
//
//  A bot's avatar: a small screen with a face made of lights (the Pixel design, kit/SPEC.md). CrewAvatar is the one entry
//  point every screen draws a bot through. The body is drawn once per look and size into two images; the lights are three
//  shape layers whose frames are a discrete Core Animation keyframe loop, and the head's nod, hop or sway is a layer
//  animation too. Nothing runs per frame on the app's side, so a window full of bots costs next to nothing.
//

import AppKit
import ClickyCore
import QuartzCore
import SwiftUI

/// What the view tells the layer tree about one figure.
struct CrewAvatar: View {
    let look: CrewLook
    let size: CGFloat
    var pose: PixelState = .awake
    /// The state changes on its own at this time, without the owner redrawing (`done` fading back to resting).
    var poseUntil: (date: Date, then: PixelState)? = nil
    /// Small tiles that shouldn't move (mosaics, option grids): the first frame and no head motion.
    var moves = true
    /// Tap to boop, hover to look up.
    var interactive = true
    /// Dims the figure, for previews. A bot that is off uses the `off` state instead.
    var dimmed = false
    /// The status badge over the bottom right corner (working, needs you, failed, done).
    var badge = true
    /// For the accessibility label, "<Name>: <state word>".
    var name: String? = nil
    /// The surface behind the bot, which the badge's ring is drawn in. Defaults to the window background.
    var ring: Color? = nil

    init(look: CrewLook, size: CGFloat, pose: PixelState = .awake, poseUntil: (date: Date, then: PixelState)? = nil, moves: Bool = true,
         interactive: Bool = true, dimmed: Bool = false, badge: Bool = true, name: String? = nil, ring: Color? = nil) {
        self.look = look
        self.size = size
        self.pose = pose
        self.poseUntil = poseUntil
        self.moves = moves
        self.interactive = interactive
        self.dimmed = dimmed
        self.badge = badge
        self.name = name
        self.ring = ring
    }

    /// The old poses still work, mapped across (`needs` is yellow now; only failed is red).
    init(look: CrewLook, size: CGFloat, crewPose: CrewPose, moves: Bool = true, interactive: Bool = true, dimmed: Bool = false, badge: Bool = true) {
        self.init(look: look, size: size, pose: PixelState(crewPose), moves: moves, interactive: interactive, dimmed: dimmed, badge: badge)
    }

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let figure = CrewFigureRepresentable(look: look.pixel, size: size, state: pose, stateUntil: poseUntil, moves: moves, interactive: interactive,
                                             isDark: scheme == .dark, hovering: hovering, badge: badge, ring: ring)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.45 : 1)
            // The drawing itself lets clicks through, so a button around it needs this to know it's there.
            .contentShape(Rectangle())
        let labelled = Group {
            if let name {
                figure.accessibilityElement().accessibilityLabel("\(name): \(pose.label)").accessibilityAddTraits(.isImage)
            } else {
                figure.accessibilityHidden(true)
            }
        }
        if interactive {
            labelled.onHover { hovering = $0 }
        } else {
            labelled
        }
    }
}

private struct CrewFigureRepresentable: NSViewRepresentable {
    let look: PixelLook
    let size: CGFloat
    let state: PixelState
    let stateUntil: (date: Date, then: PixelState)?
    let moves: Bool
    let interactive: Bool
    let isDark: Bool
    let hovering: Bool
    let badge: Bool
    let ring: Color?

    func makeNSView(context: Context) -> CrewFigureNSView {
        let view = CrewFigureNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: CrewFigureNSView, context: Context) { update(view) }

    private func update(_ view: CrewFigureNSView) {
        view.ringColor = ring.map { NSColor($0) }
        view.configure(look: look, size: size, isDark: isDark, moves: moves, badge: badge)
        view.setState(state, until: stateUntil)
        view.setHovering(hovering)
        view.isBoopable = interactive
    }
}

final class CrewFigureNSView: NSView {
    private var look = PixelLook(finish: "bone", trim: 0xFF7A45, eye: "block", top: "none", extra: "none")
    private var size: CGFloat = 0
    private var isDark = true
    private var moves = true
    private var showsBadge = true
    private var built = false
    private(set) var state: PixelState = .awake
    private var stateUntilWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var lookingUp = false
    /// Clicks reach the figure through CrewDriver's event monitor, so a figure inside a button leaves the button working.
    var isBoopable = true
    /// The surface behind the bot; nil means the window's background.
    var ringColor: NSColor? {
        didSet { if ringColor != oldValue, built { applyBadge() } }
    }

    // MARK: Layers

    private let container = CALayer()
    /// One hop when booped.
    private let boopLayer = CALayer()
    /// The head: everything that nods, hops, sways or tilts together.
    private let headLayer = CALayer()
    private let backLayer = CALayer()
    private let screenLayer = CAShapeLayer()
    private let unlitLayer = CAShapeLayer()
    private let bloomLayer = CAShapeLayer()
    private let fullLayer = CAShapeLayer()
    private let halfLayer = CAShapeLayer()
    private let ledLayer = CAShapeLayer()
    private let frontLayer = CALayer()
    private let badgeLayer = PixelBadgeLayer()

    private var tier: PixelDrawing.Tier { PixelDrawing.Tier(size: size) }
    private var unit: CGFloat { size / PixelDrawing.box }
    private var animates: Bool { moves && DS.Motion.level != .off }

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
        for sublayer in [boopLayer, headLayer, backLayer, screenLayer, unlitLayer, bloomLayer, fullLayer, halfLayer, ledLayer, frontLayer] {
            sublayer.anchorPoint = .zero
            sublayer.position = .zero
            sublayer.actions = ["contents": NSNull(), "path": NSNull(), "opacity": NSNull(), "transform": NSNull(), "fillColor": NSNull(), "hidden": NSNull()]
        }
        badgeLayer.actions = ["transform": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
        container.addSublayer(boopLayer)
        boopLayer.addSublayer(headLayer)
        [backLayer, screenLayer, unlitLayer, bloomLayer, fullLayer, halfLayer, ledLayer, frontLayer].forEach(headLayer.addSublayer)
        container.addSublayer(badgeLayer)
        halfLayer.opacity = 0.5
        bloomLayer.opacity = 0.2
        unlitLayer.fillColor = NSColor(white: 1, alpha: 0.06).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            CrewDriver.shared.remove(self)
        } else {
            CrewDriver.shared.add(self)
            if built { rebuild() }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if built { rebuild() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if built { applyBadge() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        CATransaction.commit()
    }

    // MARK: Setting it up

    func configure(look: PixelLook, size: CGFloat, isDark: Bool, moves: Bool, badge: Bool) {
        let changed = !built || look != self.look || size != self.size || isDark != self.isDark || moves != self.moves || badge != showsBadge
        guard changed else { return }
        self.look = look
        self.size = size
        self.isDark = isDark
        self.moves = moves
        showsBadge = badge
        built = true
        rebuild()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func setState(_ state: PixelState, until: (date: Date, then: PixelState)?) {
        scheduleStateChange(until)
        guard state != self.state else { return }
        self.state = state
        guard built else { return }
        applyState(blankFirst: true)
    }

    private func scheduleStateChange(_ until: (date: Date, then: PixelState)?) {
        stateUntilWork?.cancel()
        stateUntilWork = nil
        guard let until else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state != until.then else { return }
            self.state = until.then
            self.applyState(blankFirst: true)
        }
        stateUntilWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until.date.timeIntervalSinceNow), execute: work)
    }

    /// On hover, a calm bot's eyes look up for a moment.
    func setHovering(_ hovering: Bool) {
        guard hovering, !lookingUp, built, tier != .micro, [.awake, .idle, .done].contains(state) else { return }
        lookingUp = true
        applyLights(rows: PixelDrawing.lookingUp(eye: look.eye), state: .awake)
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lookingUp = false
            self.applyState(blankFirst: false)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    /// One hop.
    func boop() {
        guard animates else { return }
        let hop = CAKeyframeAnimation(keyPath: "transform")
        hop.values = [0, -6, 0, -2.4, 0].map { NSValue(caTransform3D: CATransform3DMakeTranslation(0, $0 * unit, 0)) }
        hop.keyTimes = [0, 0.3, 0.6, 0.8, 1]
        hop.duration = 0.6
        hop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        boopLayer.add(hop, forKey: "boop")
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let scale = window?.backingScaleFactor ?? 2
        let margin = PixelDrawing.margin * unit
        let imageFrame = CGRect(x: -margin, y: -margin, width: size + margin * 2, height: size + margin * 2)
        for sublayer in [boopLayer, headLayer] {
            sublayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        }
        let drawnLook = look
        let drawnIsDark = isDark
        let drawnTier = tier
        backLayer.frame = imageFrame
        backLayer.contentsScale = scale
        backLayer.contents = PixelDrawing.image(points: size, scale: scale) { PixelDrawing.drawBack(look: drawnLook, isDark: drawnIsDark, in: $0) }
        frontLayer.frame = imageFrame
        frontLayer.contentsScale = scale
        frontLayer.contents = PixelDrawing.image(points: size, scale: scale) { PixelDrawing.drawFront(look: drawnLook, tier: drawnTier, in: $0) }
        var toPoints = CGAffineTransform(scaleX: unit, y: unit)
        let screenPath = PixelDrawing.rounded(PixelDrawing.screen, PixelDrawing.screenRadius)
        screenLayer.path = screenPath.copy(using: &toPoints)
        let unlit = PixelDrawing.unlit()
        unlitLayer.path = unlit.copy(using: &toPoints)
        let ledRect = CGRect(x: PixelDrawing.led.x - PixelDrawing.ledRadius, y: PixelDrawing.led.y - PixelDrawing.ledRadius,
                             width: PixelDrawing.ledRadius * 2, height: PixelDrawing.ledRadius * 2)
        ledLayer.path = CGPath(ellipseIn: ledRect, transform: &toPoints)
        for sublayer in [screenLayer, unlitLayer, bloomLayer, fullLayer, halfLayer, ledLayer] {
            sublayer.contentsScale = scale
        }
        applyState(blankFirst: false)
    }

    // MARK: State

    private func applyState(blankFirst: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        screenLayer.fillColor = NSColor(hex: PixelDrawing.screenColor(state)).cgColor
        unlitLayer.isHidden = tier != .full || state == .off
        ledLayer.isHidden = tier == .micro
        ledLayer.fillColor = NSColor(hex: PixelDrawing.ledColor(state)).cgColor
        headLayer.opacity = state == .off ? 0.45 : state == .idle ? 0.82 : 1
        applyLoop(blankFirst: blankFirst && animates)
        applyHeadMotion()
        applyBadge()
    }

    private func applyLights(rows: [String], state: PixelState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for sublayer in [bloomLayer, fullLayer, halfLayer] { sublayer.removeAnimation(forKey: "frames") }
        let paths = scaled(PixelDrawing.lights(rows, tier: tier, glow: PixelDrawing.glows(state, tier: tier)))
        let color = NSColor(hex: state.hex).cgColor
        for sublayer in [bloomLayer, fullLayer, halfLayer] { sublayer.fillColor = color }
        fullLayer.path = paths.full
        halfLayer.path = paths.half
        bloomLayer.path = paths.bloom
    }

    private func scaled(_ paths: PixelDrawing.LightPaths) -> PixelDrawing.LightPaths {
        var toPoints = CGAffineTransform(scaleX: unit, y: unit)
        return PixelDrawing.LightPaths(full: paths.full.copy(using: &toPoints) ?? paths.full, half: paths.half.copy(using: &toPoints) ?? paths.half,
                                       bloom: paths.bloom.copy(using: &toPoints) ?? paths.bloom)
    }

    /// The face's frames as one discrete keyframe loop per light layer. With `blankFirst` the screen is dark for 80 ms,
    /// then the new loop starts at zero.
    private func applyLoop(blankFirst: Bool) {
        let color = NSColor(hex: state.hex).cgColor
        for sublayer in [bloomLayer, fullLayer, halfLayer] {
            sublayer.removeAnimation(forKey: "frames")
            sublayer.fillColor = color
        }
        let glow = PixelDrawing.glows(state, tier: tier)
        let loop = tier == .micro ? [] : PixelFaces.frames(state, eye: look.eye)
        guard animates, loop.count > 1 else {
            let first = scaled(PixelDrawing.lights(PixelDrawing.rows(state, eye: look.eye, tier: tier), tier: tier, glow: glow))
            fullLayer.path = first.full
            halfLayer.path = first.half
            bloomLayer.path = first.bloom
            return
        }
        let frames = loop.map { scaled(PixelDrawing.lights($0.rows, tier: tier, glow: glow)) }
        let total = Double(loop.reduce(0) { $0 + $1.milliseconds })
        var keyTimes: [NSNumber] = [0]
        var elapsed = 0.0
        for frame in loop {
            elapsed += Double(frame.milliseconds)
            keyTimes.append(NSNumber(value: elapsed / total))
        }
        let empty = CGMutablePath()
        let begin = blankFirst ? fullLayer.convertTime(CACurrentMediaTime(), from: nil) + 0.08 : 0
        for (sublayer, pick) in [(fullLayer, \PixelDrawing.LightPaths.full), (halfLayer, \.half), (bloomLayer, \.bloom)] as [(CAShapeLayer, KeyPath<PixelDrawing.LightPaths, CGPath>)] {
            // The model value shows before the loop begins: blank during the 80 ms, the first frame otherwise.
            sublayer.path = blankFirst ? empty : frames[0][keyPath: pick]
            let animation = CAKeyframeAnimation(keyPath: "path")
            animation.values = frames.map { $0[keyPath: pick] }
            animation.keyTimes = keyTimes
            animation.calculationMode = .discrete
            animation.duration = total / 1000
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            if blankFirst { animation.beginTime = begin }
            sublayer.add(animation, forKey: "frames")
        }
    }

    /// The head: nod while working, hop while it needs you, tilt when failed, sway when done, breathe asleep.
    private func applyHeadMotion() {
        headLayer.removeAnimation(forKey: "head")
        ledLayer.removeAnimation(forKey: "led")
        // Failed is a still pose, so it shows even with motion off.
        headLayer.transform = state == .failed ? about(PixelDrawing.headOrigin, CGAffineTransform(rotationAngle: -6 * .pi / 180)) : CATransform3DIdentity
        guard animates, tier != .micro else { return }
        func move(_ y: CGFloat) -> NSValue { NSValue(caTransform3D: CATransform3DMakeTranslation(0, y * unit, 0)) }
        func turn(_ degrees: CGFloat) -> NSValue { NSValue(caTransform3D: about(PixelDrawing.headOrigin, CGAffineTransform(rotationAngle: degrees * .pi / 180))) }
        switch state {
        case .working, .thinking:
            add(headLayer, "head", path: "transform", values: [move(0), move(1.3), move(0)], times: [0, 0.5, 1], seconds: 1.52)
            add(ledLayer, "led", path: "opacity", values: [1, 0.35, 1], times: [0, 0.5, 1], seconds: 1.52)
        case .talking:
            add(headLayer, "head", path: "transform", values: [move(0), move(1.3), move(0)], times: [0, 0.5, 1], seconds: 0.78)
        case .needs:
            add(headLayer, "head", path: "transform", values: [move(0), move(0), move(-6), move(0), move(-2.4), move(0), move(0)],
                times: [0, 0.62, 0.72, 0.82, 0.89, 0.96, 1], seconds: 2.7)
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 0.2]
            blink.keyTimes = [0, 0.5, 1]
            blink.calculationMode = .discrete
            blink.duration = 0.9
            blink.repeatCount = .infinity
            blink.isRemovedOnCompletion = false
            ledLayer.add(blink, forKey: "led")
        case .done:
            add(headLayer, "head", path: "transform", values: [turn(-2.4), turn(2.4), turn(-2.4)], times: [0, 0.5, 1], seconds: 3.2)
        case .idle:
            add(headLayer, "head", path: "transform", values: [move(0), move(1.6), move(0)], times: [0, 0.5, 1], seconds: 4.4)
        default:
            break
        }
    }

    private func add(_ target: CALayer, _ key: String, path: String, values: [Any], times: [Double], seconds: Double) {
        let animation = CAKeyframeAnimation(keyPath: path)
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.duration = seconds
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(animation, forKey: key)
    }

    /// A transform about a point in the 96-unit box.
    private func about(_ point: CGPoint, _ inner: CGAffineTransform) -> CATransform3D {
        let x = point.x * unit
        let y = point.y * unit
        let place = CGAffineTransform(translationX: -x, y: -y).concatenating(inner).concatenating(CGAffineTransform(translationX: x, y: y))
        return CATransform3DMakeAffineTransform(place)
    }

    // MARK: Badge

    /// 42% of the bot (30% at 88 pt and up, 50% under 31 pt) over the bottom right corner, ringed in the surface colour.
    private func applyBadge() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let kind = showsBadge ? PixelBadgeKind(state: state) : nil
        let ring: CGColor = {
            var resolved = NSColor(hex: isDark ? 0x000000 : 0xFFFFFF).cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = (ringColor ?? NSColor(DS.Colors.background)).cgColor
            }
            return resolved
        }()
        let fraction: CGFloat
        let right: CGFloat
        let bottom: CGFloat
        if size >= 88 {
            (fraction, right, bottom) = (0.3, -0.02, 0)
        } else if tier != .full {
            (fraction, right, bottom) = (0.5, -0.16, -0.14)
        } else {
            (fraction, right, bottom) = (0.42, -0.09, -0.07)
        }
        let side = max(size * fraction, tier == .full ? 12 : 0)
        badgeLayer.configure(tone: kind == nil ? nil : PixelTone(state: state), side: side, ring: ring, isDark: isDark, animated: animates)
        badgeLayer.anchorPoint = CGPoint(x: 0.3, y: 0.8)
        badgeLayer.frame = CGRect(x: size * (1 - right) - side, y: size * (1 - bottom) - side, width: side, height: side)
    }

    // MARK: Driver

    /// Checks whether this figure is showing, for the test command and the Studio meter.
    func refreshPlacement() {
        guard let window, window.isVisible, CrewDriver.shared.forcesVisible || window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else {
            isOnScreen = false
            return
        }
        isOnScreen = true
    }

    /// Motion was switched on or off (Settings › Look, Reduce Motion).
    func motionChanged() {
        guard built else { return }
        applyState(blankFirst: false)
    }
}

/// Keeps track of every figure: boops from clicks, and motion settings. The faces themselves loop in Core Animation, so
/// there is no per-frame timer at all.
@MainActor
final class CrewDriver {
    static let shared = CrewDriver()

    private let figures = NSHashTable<CrewFigureNSView>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    private var lastLevel = DS.Motion.level
    /// Kept for the test command; Pixel eyes don't follow the pointer.
    var testPointer: CGPoint?
    /// The test profile's window can sit behind others while being screenshotted.
    var forcesVisible = TheoProfile.isTest

    private init() {
        installClickMonitor()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.motionMayHaveChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.motionMayHaveChanged() }
        })
    }

    func add(_ figure: CrewFigureNSView) {
        figures.add(figure)
        figure.refreshPlacement()
    }

    func remove(_ figure: CrewFigureNSView) {
        figures.remove(figure)
    }

    private func motionMayHaveChanged() {
        let level = DS.Motion.level
        guard level != lastLevel else { return }
        lastLevel = level
        figures.allObjects.forEach { $0.motionChanged() }
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
    var showingCount: Int {
        let all = figures.allObjects
        all.forEach { $0.refreshPlacement() }
        return all.filter(\.isOnScreen).count
    }

    /// No app-side timer runs for the faces any more; everything loops in Core Animation.
    var isRunning: Bool { false }
}
