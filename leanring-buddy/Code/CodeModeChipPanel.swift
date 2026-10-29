//
//  CodeModeChipPanel.swift
//  leanring-buddy
//
//  The one-click "Turn on code mode" chip. Shown when the main brain asked
//  for [CODEMODE:on] but the user never said "code mode" (CodeModeToggle
//  refused it). A small non-activating panel that never becomes key, so
//  the user keeps typing where they were and no key or voice reaches it.
//  Only a real mouse press + release on the chip (CodeModeChipGate:
//  synthetic-tagged events refused, nothing in the first 0.5 s, same
//  window, 15 s lifetime, used once) turns Code mode on. "Not now" (or
//  waiting) just hides it.
//

import AppKit
import ClickyCore

/// Never key, never main: clicks reach it without stealing focus.
final class CodeModeChipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The chip itself: an NSView so the gate sees the real NSEvents.
final class CodeModeChipButtonView: NSView {
    var gate: CodeModeChipGate?
    var onTurnOn: () -> Void = {}
    var onRejected: (CodeModeChipRejection) -> Void = { _ in }
    private let titleField = NSTextField(labelWithString: "Turn on code mode")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.systemBlue.cgColor
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .white
        titleField.alignment = .center
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Turn on code mode")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The panel is never key, so the first click must reach the chip; the
    /// gate's 0.5 s minimum stops a click that was already on its way.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { feed(event, kind: .mouseDown) }
    override func mouseUp(with event: NSEvent) { feed(event, kind: .mouseUp) }

    private func feed(_ event: NSEvent, kind: CodeModeChipInput.Kind) {
        guard var currentGate = gate else { return }
        let isOnChip = bounds.contains(convert(event.locationInWindow, from: nil))
        let input = CodeModeChipInput(kind: kind, timestamp: event.timestamp, windowNumber: event.windowNumber,
                                      eventSourceUserData: GateEventMapping.eventSourceUserData(of: event), isOnChip: isOnChip)
        let decision = currentGate.handle(input)
        gate = currentGate
        switch decision {
        case .turnOn: onTurnOn()
        case .rejected(let rejection): onRejected(rejection)
        case .pressStarted: break
        }
        layer?.backgroundColor = (decision == .pressStarted ? NSColor.systemBlue.blended(withFraction: 0.25, of: .black) ?? .systemBlue : .systemBlue).cgColor
    }
}

@MainActor
final class CodeModeChipController: NSObject {
    /// Called once when a real click turned it on.
    var onTurnOn: () -> Void = {}
    /// For the controller's event log.
    var onLog: (String) -> Void = { _ in }

    private var panel: CodeModeChipPanel?
    private var chipView: CodeModeChipButtonView?
    private var hideTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let size = panel.frame.size
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: screenFrame.maxX - size.width - 16, y: screenFrame.maxY - size.height - 16))
        panel.orderFrontRegardless()
        chipView?.gate = CodeModeChipGate(windowNumber: panel.windowNumber, shownAt: ProcessInfo.processInfo.systemUptime)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CodeModeChipGate.lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        chipView?.gate = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> CodeModeChipPanel {
        let size = NSSize(width: 300, height: 92)
        let panel = CodeModeChipPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                                      backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let explanation = NSTextField(wrappingLabelWithString: "This needs code mode. Click to turn it on, or say \"turn on code mode\".")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.frame = NSRect(x: 12, y: 50, width: size.width - 24, height: 32)
        background.addSubview(explanation)

        let chip = CodeModeChipButtonView(frame: NSRect(x: 12, y: 10, width: 180, height: 30))
        chip.onTurnOn = { [weak self] in
            guard let self else { return }
            self.onLog("code mode chip: real click → on")
            self.hide()
            self.onTurnOn()
        }
        chip.onRejected = { [weak self] rejection in self?.onLog("code mode chip: click refused (\(rejection))") }
        background.addSubview(chip)
        chipView = chip

        let dismissButton = NSButton(title: "Not now", target: nil, action: nil)
        dismissButton.bezelStyle = .rounded
        dismissButton.frame = NSRect(x: size.width - 12 - 90, y: 10, width: 90, height: 30)
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        background.addSubview(dismissButton)

        panel.contentView = background
        return panel
    }

    @objc private func dismissClicked() {
        onLog("code mode chip: dismissed")
        hide()
    }
}
