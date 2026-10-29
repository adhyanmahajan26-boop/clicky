//
//  ClaudeCompanionView.swift
//  leanring-buddy
//
//  The companion that follows the mouse: a Claude-style orange spark (the
//  "coordinator"). It breathes gently while idle and spins while it's
//  thinking. Each running worker (from a CompanionActivitySource) shows up as
//  a miniature spark orbiting the big one, spinning while it works and fading
//  out when it's done.
//
//  Everything is drawn in code, no logo image files. The spark shape itself
//  (ClaudeSparkShape) lives in ClickyCore so the notch pill draws the same mark.
//
//  Performance: the breathing, the thinking spin, the orbit and the minis'
//  spin are Core Animation animations on plain CALayers, so they run in the
//  render server and cost the app nothing per frame. (They used to be a
//  TimelineView(.animation) that re-evaluated and re-laid-out the whole
//  full-screen overlay hosting view at display rate, ~20% of a core even
//  with the pointer still.) SwiftUI only calls updateNSView when an input
//  changes: thinking on/off, the worker list, opacity or the flight scale.
//

import AppKit
import ClickyCore
import QuartzCore
import SwiftUI

struct ClaudeCompanionView: NSViewRepresentable {
    /// True while the coordinator is waiting on Claude (the old spinner state).
    let isCoordinatorThinking: Bool
    /// Workers currently running (at most 4). Finished workers are left out,
    /// which is what makes their mini fade away.
    let activeCompanionWorkers: [CompanionWorkerActivity]
    /// Off-screen companions drop their animations entirely.
    let isAnimationRunning: Bool
    /// The companion's opacity (applied to the layers, faded over `opacityFadeSeconds`).
    var opacity: Double = 1
    var opacityFadeSeconds: Double = 0.25
    /// Grows to ~1.3 mid-flight; above 1 also adds the flight glow.
    var flightScale: CGFloat = 1

    static let coordinatorSparkDiameter: CGFloat = 24
    static let workerSparkDiameter: CGFloat = 10
    static let workerOrbitRadius: CGFloat = 25

    static let coordinatorThinkingSpinDegreesPerSecond: Double = 220
    static let idleBreathingCycleSeconds: Double = 3.2
    static let idleBreathingAmplitude: Double = 0.06
    static let workerSpinDegreesPerSecond: Double = 400
    static let workerOrbitDegreesPerSecond: Double = 70

    /// Big enough to hold the orbit plus the minis' glow.
    static var companionFrameDiameter: CGFloat {
        (workerOrbitRadius + workerSparkDiameter) * 2 + 8
    }

    /// 1 worker sits at the top, 2 are opposite each other, 3 form a
    /// triangle, 4 a cross.
    static func evenlySpacedOrbitSlotDegrees(workerIndex: Int, activeWorkerCount: Int) -> Double {
        guard activeWorkerCount > 0 else { return -90 }
        return -90 + Double(workerIndex) * (360 / Double(activeWorkerCount))
    }

    func makeNSView(context: Context) -> CompanionSparkLayerView {
        CompanionSparkLayerView(frame: NSRect(x: 0, y: 0, width: Self.companionFrameDiameter, height: Self.companionFrameDiameter))
    }

    func updateNSView(_ view: CompanionSparkLayerView, context: Context) {
        OverlayPerfMonitor.shared.note(.companionLayerUpdates)
        view.apply(CompanionSparkLayerView.Configuration(
            isThinking: isCoordinatorThinking,
            workerIDs: activeCompanionWorkers.map(\.id),
            isAnimationRunning: isAnimationRunning,
            opacity: opacity,
            opacityFadeSeconds: opacityFadeSeconds,
            flightScale: flightScale
        ))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CompanionSparkLayerView, context: Context) -> CGSize? {
        CGSize(width: Self.companionFrameDiameter, height: Self.companionFrameDiameter)
    }
}

/// The CA layer tree behind ClaudeCompanionView. Layers are standalone
/// sublayers of the view's backing layer (never view-backed), so AppKit
/// never rewrites their transforms; implicit actions are disabled
/// everywhere except where a fade is wanted.
final class CompanionSparkLayerView: NSView {
    struct Configuration: Equatable {
        var isThinking: Bool
        var workerIDs: [String]
        var isAnimationRunning: Bool
        var opacity: Double
        var opacityFadeSeconds: Double
        var flightScale: CGFloat
    }

    private let companionLayer = CALayer()
    private let coordinatorLayer = CAShapeLayer()
    private let orbitLayer = CALayer()
    /// One per worker: a full-size layer rotated to the worker's slot, holding the mini.
    private var workerSlotLayers: [String: CALayer] = [:]
    private var workerSlotDegrees: [String: Double] = [:]
    private var configuration: Configuration?
    /// +1 when the layer space is y-down (as SwiftUI draws), -1 when y-up;
    /// angles are multiplied by it so everything turns clockwise on screen as before.
    private var clockwiseSign: CGFloat = 1

    /// The look picked in Setup (v2.spark.style); its colours, shape and spin speed.
    private var style = ClickySettings.sparkStyle
    private var fillColor: CGColor { CompanionIconStyle.color(style.fillHex) }
    private var glowColor: CGColor { CompanionIconStyle.color(style.glowHex) }
    private var styleObserver: NSObjectProtocol?
    private static let breathingKey = "breathing"
    private static let spinKey = "spin"
    private static let orbitKey = "orbit"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        companionLayer.masksToBounds = false
        orbitLayer.masksToBounds = false
        companionLayer.addSublayer(orbitLayer)
        companionLayer.addSublayer(coordinatorLayer)
        layer?.addSublayer(companionLayer)
        companionLayer.shadowOffset = .zero
        companionLayer.shadowOpacity = 0
        coordinatorLayer.shadowOffset = .zero
        applyStyleColors()
        layoutLayers()
        // A new style from Setup: reshape and recolour everything in place.
        styleObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, ClickySettings.sparkStyle != self.style else { return }
                self.style = ClickySettings.sparkStyle
                self.applyStyleColors()
                self.lastLayoutKey = nil
                self.layoutLayers()
                if let configuration = self.configuration { self.applyAnimations(for: configuration) }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyStyleColors() {
        withoutActions {
            companionLayer.shadowColor = glowColor
            coordinatorLayer.fillColor = fillColor
            coordinatorLayer.shadowColor = glowColor
            for slotLayer in workerSlotLayers.values {
                guard let miniLayer = slotLayer.sublayers?.first as? CAShapeLayer else { continue }
                miniLayer.fillColor = fillColor
                miniLayer.shadowColor = glowColor
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutLayers()
        if let configuration { applyAnimations(for: configuration) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for shapeLayer in allShapeLayers() { shapeLayer.contentsScale = scale }
    }

    // MARK: - Geometry

    private var lastLayoutKey: (size: CGSize, isYDown: Bool)?

    private func layoutLayers() {
        let layoutKey = (size: bounds.size, isYDown: companionLayer.contentsAreFlipped())
        if let lastLayoutKey, lastLayoutKey.size == layoutKey.size, lastLayoutKey.isYDown == layoutKey.isYDown { return }
        lastLayoutKey = layoutKey
        withoutActions {
            // bounds + position, not frame: the layer may carry the flight scale.
            companionLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            companionLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            orbitLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            orbitLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            let isYDown = companionLayer.contentsAreFlipped()
            let newSign: CGFloat = isYDown ? 1 : -1
            let signChanged = newSign != clockwiseSign
            clockwiseSign = newSign
            let coordinatorSide = ClaudeCompanionView.coordinatorSparkDiameter
            coordinatorLayer.bounds = CGRect(x: 0, y: 0, width: coordinatorSide, height: coordinatorSide)
            coordinatorLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            coordinatorLayer.path = Self.sparkPath(side: coordinatorSide, isYDown: isYDown, style: style)
            coordinatorLayer.shadowPath = coordinatorLayer.path
            for (workerID, slotLayer) in workerSlotLayers {
                slotLayer.bounds = CGRect(origin: .zero, size: bounds.size)
                slotLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
                if let miniLayer = slotLayer.sublayers?.first as? CAShapeLayer {
                    layoutMini(miniLayer, isYDown: isYDown)
                }
                if signChanged, let degrees = workerSlotDegrees[workerID] {
                    slotLayer.setValue(radians(degrees), forKeyPath: "transform.rotation.z")
                }
            }
            if signChanged, let configuration { applyAnimations(for: configuration) }
        }
    }

    private func layoutMini(_ miniLayer: CAShapeLayer, isYDown: Bool) {
        let side = ClaudeCompanionView.workerSparkDiameter
        miniLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        miniLayer.position = CGPoint(x: bounds.midX + ClaudeCompanionView.workerOrbitRadius, y: bounds.midY)
        miniLayer.path = Self.sparkPath(side: side, isYDown: isYDown, style: style)
        miniLayer.shadowPath = miniLayer.path
    }

    /// ClaudeSparkShape's path; flipped vertically when the layer space is y-up
    /// so the uneven rays look exactly as SwiftUI drew them.
    private static func sparkPath(side: CGFloat, isYDown: Bool, style: CompanionIconStyle) -> CGPath {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let path = style.path(in: rect)
        guard !isYDown else { return path }
        var flip = CGAffineTransform(translationX: 0, y: side).scaledBy(x: 1, y: -1)
        return path.copy(using: &flip) ?? path
    }

    private func radians(_ degrees: Double) -> CGFloat {
        CGFloat(degrees * .pi / 180) * clockwiseSign
    }

    // MARK: - Configuration

    func apply(_ newConfiguration: Configuration) {
        let previous = configuration
        guard newConfiguration != previous else { return }
        configuration = newConfiguration

        // Opacity: faded like the SwiftUI .opacity + .animation it replaces.
        if previous?.opacity != newConfiguration.opacity {
            let duration = previous == nil ? 0 : newConfiguration.opacityFadeSeconds
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
            CATransaction.setDisableActions(duration == 0)
            companionLayer.opacity = Float(newConfiguration.opacity)
            CATransaction.commit()
        }

        // Flight scale + glow: set per frame by the flight timer, never implicitly animated.
        if previous?.flightScale != newConfiguration.flightScale {
            withoutActions {
                let scale = newConfiguration.flightScale
                // The standalone layer's anchor is its centre, so this scales in place.
                companionLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
                companionLayer.shadowRadius = max(0, (scale - 1) * 20)
                companionLayer.shadowOpacity = scale > 1.0001 ? 0.8 : 0
            }
        }

        if previous?.isThinking != newConfiguration.isThinking {
            CATransaction.begin()
            CATransaction.setAnimationDuration(previous == nil ? 0 : 0.25)
            CATransaction.setDisableActions(previous == nil)
            coordinatorLayer.shadowOpacity = newConfiguration.isThinking ? 0.9 : 0.6
            coordinatorLayer.shadowRadius = newConfiguration.isThinking ? 9 : 6
            CATransaction.commit()
        }

        if previous?.workerIDs != newConfiguration.workerIDs {
            updateWorkers(from: previous?.workerIDs ?? [], to: newConfiguration.workerIDs)
        }

        let wasVisible = (previous?.opacity ?? 0) > 0
        let isVisible = newConfiguration.opacity > 0
        if previous?.isThinking != newConfiguration.isThinking
            || previous?.isAnimationRunning != newConfiguration.isAnimationRunning
            || previous?.workerIDs.isEmpty != newConfiguration.workerIDs.isEmpty
            || (!wasVisible && isVisible) {
            applyAnimations(for: newConfiguration)
        } else if wasVisible && !isVisible {
            // Keep breathing through the fade-out, then stop (nothing to show).
            DispatchQueue.main.asyncAfter(deadline: .now() + newConfiguration.opacityFadeSeconds + 0.05) { [weak self] in
                guard let self, let configuration = self.configuration, configuration.opacity == 0 else { return }
                self.applyAnimations(for: configuration)
            }
        }
    }

    // MARK: - Animations (render server)

    /// Breathing while idle, spinning while thinking, orbit while workers run.
    /// Nothing runs while the companion is off this screen or fully transparent.
    private func applyAnimations(for configuration: Configuration) {
        let isLive = configuration.isAnimationRunning && configuration.opacity > 0 && window != nil
        coordinatorLayer.removeAnimation(forKey: Self.breathingKey)
        coordinatorLayer.removeAnimation(forKey: Self.spinKey)
        orbitLayer.removeAnimation(forKey: Self.orbitKey)
        for slotLayer in workerSlotLayers.values {
            (slotLayer.sublayers?.first)?.removeAnimation(forKey: Self.spinKey)
        }
        guard isLive else { return }

        if configuration.isThinking {
            coordinatorLayer.add(Self.spin(degreesPerSecond: ClaudeCompanionView.coordinatorThinkingSpinDegreesPerSecond * style.spinSpeedMultiplier, sign: clockwiseSign), forKey: Self.spinKey)
        } else {
            let breathing = CABasicAnimation(keyPath: "transform.scale")
            breathing.fromValue = 1 - ClaudeCompanionView.idleBreathingAmplitude
            breathing.toValue = 1 + ClaudeCompanionView.idleBreathingAmplitude
            breathing.duration = ClaudeCompanionView.idleBreathingCycleSeconds / 2
            breathing.autoreverses = true
            breathing.repeatCount = .infinity
            breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)  // ≈ the old sine
            coordinatorLayer.add(breathing, forKey: Self.breathingKey)
        }

        if !configuration.workerIDs.isEmpty {
            orbitLayer.add(Self.spin(degreesPerSecond: ClaudeCompanionView.workerOrbitDegreesPerSecond, sign: clockwiseSign), forKey: Self.orbitKey)
            for slotLayer in workerSlotLayers.values {
                (slotLayer.sublayers?.first)?.add(Self.spin(degreesPerSecond: ClaudeCompanionView.workerSpinDegreesPerSecond, sign: clockwiseSign), forKey: Self.spinKey)
            }
        }
    }

    private static func spin(degreesPerSecond: Double, sign: CGFloat) -> CABasicAnimation {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double(sign) * 2 * .pi
        spin.duration = 360 / degreesPerSecond
        spin.repeatCount = .infinity
        spin.isAdditive = true
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        return spin
    }

    // MARK: - Workers

    /// Joins pop in (opacity + scale from 0.2), leaves fade out, and every
    /// mini springs to its new evenly spaced slot (the old
    /// .spring(response: 0.55, dampingFraction: 0.8)).
    private func updateWorkers(from oldIDs: [String], to newIDs: [String]) {
        let isYDown = companionLayer.contentsAreFlipped()
        let newIDSet = Set(newIDs)

        for workerID in oldIDs where !newIDSet.contains(workerID) {
            guard let slotLayer = workerSlotLayers.removeValue(forKey: workerID) else { continue }
            workerSlotDegrees[workerID] = nil
            CATransaction.begin()
            CATransaction.setCompletionBlock { slotLayer.removeFromSuperlayer() }
            let fade = Self.popAnimation(appearing: false)
            slotLayer.add(fade, forKey: "leave")
            withoutActions { slotLayer.opacity = 0 }
            CATransaction.commit()
        }

        for (workerIndex, workerID) in newIDs.enumerated() {
            let targetDegrees = ClaudeCompanionView.evenlySpacedOrbitSlotDegrees(workerIndex: workerIndex, activeWorkerCount: newIDs.count)
            if let slotLayer = workerSlotLayers[workerID] {
                guard let oldDegrees = workerSlotDegrees[workerID], oldDegrees != targetDegrees else { continue }
                let respace = CASpringAnimation(keyPath: "transform.rotation.z")
                Self.configureSpring(respace)
                respace.fromValue = radians(oldDegrees)
                respace.toValue = radians(targetDegrees)
                respace.duration = respace.settlingDuration
                withoutActions { slotLayer.setValue(radians(targetDegrees), forKeyPath: "transform.rotation.z") }
                slotLayer.add(respace, forKey: "respace")
                workerSlotDegrees[workerID] = targetDegrees
            } else {
                let slotLayer = CALayer()
                slotLayer.masksToBounds = false
                let miniLayer = CAShapeLayer()
                miniLayer.fillColor = fillColor
                miniLayer.shadowColor = glowColor
                miniLayer.shadowOffset = .zero
                miniLayer.shadowOpacity = 0.7
                miniLayer.shadowRadius = 4
                miniLayer.contentsScale = window?.backingScaleFactor ?? 2
                withoutActions {
                    slotLayer.bounds = CGRect(origin: .zero, size: bounds.size)
                    slotLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
                    layoutMini(miniLayer, isYDown: isYDown)
                    slotLayer.addSublayer(miniLayer)
                    slotLayer.setValue(radians(targetDegrees), forKeyPath: "transform.rotation.z")
                    orbitLayer.addSublayer(slotLayer)
                }
                slotLayer.add(Self.popAnimation(appearing: true), forKey: "join")
                workerSlotLayers[workerID] = slotLayer
                workerSlotDegrees[workerID] = targetDegrees
                if let configuration, configuration.isAnimationRunning, configuration.opacity > 0, window != nil {
                    miniLayer.add(Self.spin(degreesPerSecond: ClaudeCompanionView.workerSpinDegreesPerSecond, sign: clockwiseSign), forKey: Self.spinKey)
                }
            }
        }
    }

    /// .transition(.opacity.combined(with: .scale(scale: 0.2))) under the spring.
    private static func popAnimation(appearing: Bool) -> CAAnimation {
        let fade = CASpringAnimation(keyPath: "opacity")
        configureSpring(fade)
        fade.fromValue = appearing ? 0 : 1
        fade.toValue = appearing ? 1 : 0
        let group = CAAnimationGroup()
        group.animations = [fade]
        group.duration = fade.settlingDuration
        group.fillMode = .both
        group.isRemovedOnCompletion = true
        if appearing {
            // Scale via sublayerTransform so the slot's rotation is untouched; like the
            // SwiftUI transition it scales about the orbit centre.
            let grow = CASpringAnimation(keyPath: "sublayerTransform.scale")
            configureSpring(grow)
            grow.fromValue = 0.2
            grow.toValue = 1
            group.animations?.append(grow)
        } else {
            let shrink = CABasicAnimation(keyPath: "sublayerTransform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.2
            shrink.duration = 0.3
            group.animations?.append(shrink)
        }
        return group
    }

    /// SwiftUI's .spring(response: 0.55, dampingFraction: 0.8) in CA terms.
    private static func configureSpring(_ spring: CASpringAnimation) {
        let response = 0.55
        let dampingFraction = 0.8
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * dampingFraction / response
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
    }

    // MARK: - Helpers

    private func allShapeLayers() -> [CAShapeLayer] {
        [coordinatorLayer] + workerSlotLayers.values.compactMap { $0.sublayers?.first as? CAShapeLayer }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
