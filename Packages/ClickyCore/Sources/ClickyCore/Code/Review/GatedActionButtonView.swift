//
//  GatedActionButtonView.swift
//  ClickyCore
//
//  The review panel's action button. It is an NSView, not a SwiftUI Button,
//  because the decision needs the real NSEvents: each mouseDown/mouseUp is
//  mapped (GateEventMapping) and fed to ClickGateLogic with the panel's
//  window number, whether the app is active and the panel key, the event's
//  eventSourceUserData and when the panel was shown. No click-through
//  (acceptsFirstMouse is false). Hold actions fill up over 1.5 s while
//  pressed; Return or voice only arm the button (a 5 s highlight).
//

import AppKit
import QuartzCore
import SwiftUI

public final class GatedActionButtonView: NSView {
    public var gatedAction: GatedAction { didSet { if gatedAction != oldValue { gate = nil } } }
    public var title: String { didSet { titleField.stringValue = displayTitle } }
    public var isEnabled = true { didSet { updateAppearance() } }
    public var isPrimary = false { didSet { updateAppearance() } }
    /// When the panel became visible, on NSEvent's clock (systemUptime).
    public var panelShownAtProvider: () -> TimeInterval = { 0 }
    public var onApproved: () -> Void = {}
    public var onDecision: (ClickGateDecision) -> Void = { _ in }

    private var gate: ClickGateLogic?
    private let fillLayer = CALayer()
    private let titleField = NSTextField(labelWithString: "")
    private var armExpiryTimer: Timer?

    public init(gatedAction: GatedAction, title: String) {
        self.gatedAction = gatedAction
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        fillLayer.anchorPoint = CGPoint(x: 0, y: 0)
        fillLayer.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
        layer?.addSublayer(fillLayer)
        titleField.alignment = .center
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8)
        ])
        titleField.stringValue = displayTitle
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var displayTitle: String { gatedAction.requiresHold ? "\(title) (hold)" : title }

    public override var intrinsicContentSize: NSSize { NSSize(width: max(120, titleField.intrinsicContentSize.width + 28), height: 30) }

    /// A click on an inactive panel only activates it; it never presses the button.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame.size.height = bounds.height
        CATransaction.commit()
    }

    // MARK: - Events

    public override func mouseDown(with event: NSEvent) { feed(event) }
    public override func mouseUp(with event: NSEvent) { feed(event) }

    /// Return on the panel: arms (highlights) this button; a click is still needed.
    public func armFromKeyboard(_ event: NSEvent) { feed(event) }

    /// Voice ("approve"): arms only.
    public func armFromVoice() {
        guard var currentGate = ensureGate() else { return }
        let decision = currentGate.handle(GateInputEvent(kind: .voice, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? -1,
                                                         panelShownAt: panelShownAtProvider()))
        gate = currentGate
        apply(decision)
    }

    private func feed(_ event: NSEvent) {
        guard isEnabled, var currentGate = ensureGate() else {
            resetFill()
            return
        }
        let locationInView = convert(event.locationInWindow, from: nil)
        let isAppActive = NSApp?.isActive == true && window?.isKeyWindow == true
        guard let gateInput = GateEventMapping.gateInput(from: event, panelShownAt: panelShownAtProvider(), isAppActive: isAppActive,
                                                         isOnTargetButton: bounds.contains(locationInView)) else { return }
        let decision = currentGate.handle(gateInput)
        gate = currentGate
        apply(decision)
    }

    private func ensureGate() -> ClickGateLogic? {
        if let gate { return gate }
        guard let window else { return nil }
        let newGate = ClickGateLogic(action: gatedAction, panelWindowNumber: window.windowNumber)
        gate = newGate
        return newGate
    }

    private func apply(_ decision: ClickGateDecision) {
        onDecision(decision)
        switch decision {
        case .pressStarted:
            if gatedAction.requiresHold { startFill() }
        case .approved:
            resetFill()
            setArmed(false)
            onApproved()
        case .armed(let expiresAt):
            setArmed(true)
            armExpiryTimer?.invalidate()
            let remaining = max(0.1, expiresAt - ProcessInfo.processInfo.systemUptime)
            armExpiryTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setArmed(false) }
            }
        case .rejected:
            resetFill()
        }
    }

    // MARK: - Appearance

    private var isArmed = false

    private func setArmed(_ armed: Bool) {
        isArmed = armed
        updateAppearance()
    }

    private func startFill() {
        fillLayer.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = 0
        animation.toValue = bounds.width
        animation.duration = ClickGateLogic.minimumHoldDuration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        fillLayer.add(animation, forKey: "hold")
    }

    private func resetFill() {
        fillLayer.removeAllAnimations()
    }

    private func updateAppearance() {
        let accent = NSColor.systemBlue
        let baseColor: NSColor = isPrimary ? accent : NSColor.windowBackgroundColor.blended(withFraction: 0.12, of: .labelColor) ?? .darkGray
        layer?.backgroundColor = (isEnabled ? baseColor : baseColor.withAlphaComponent(0.35)).cgColor
        layer?.borderColor = (isArmed ? NSColor.systemYellow : NSColor.separatorColor).cgColor
        layer?.borderWidth = isArmed ? 2.5 : 1
        fillLayer.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        titleField.textColor = isPrimary ? .white : .labelColor
        titleField.alphaValue = isEnabled ? 1 : 0.5
        setAccessibilityEnabled(isEnabled)
    }
}

/// SwiftUI wrapper for the panel.
public struct GatedActionButton: NSViewRepresentable {
    public var button: CodeReviewContent.ActionButton
    public var isEnabled: Bool
    public var panelShownAtProvider: () -> TimeInterval
    public var onApproved: () -> Void
    public var onViewCreated: (String, GatedActionButtonView) -> Void

    public init(button: CodeReviewContent.ActionButton, isEnabled: Bool, panelShownAtProvider: @escaping () -> TimeInterval,
                onApproved: @escaping () -> Void, onViewCreated: @escaping (String, GatedActionButtonView) -> Void = { _, _ in }) {
        self.button = button
        self.isEnabled = isEnabled
        self.panelShownAtProvider = panelShownAtProvider
        self.onApproved = onApproved
        self.onViewCreated = onViewCreated
    }

    public func makeNSView(context: Context) -> GatedActionButtonView {
        let view = GatedActionButtonView(gatedAction: button.gatedAction, title: button.title)
        update(view)
        onViewCreated(button.id, view)
        return view
    }

    public func updateNSView(_ view: GatedActionButtonView, context: Context) {
        update(view)
    }

    private func update(_ view: GatedActionButtonView) {
        view.gatedAction = button.gatedAction
        view.title = button.title
        view.isPrimary = button.isPrimary
        view.isEnabled = isEnabled
        view.panelShownAtProvider = panelShownAtProvider
        view.onApproved = onApproved
    }
}
