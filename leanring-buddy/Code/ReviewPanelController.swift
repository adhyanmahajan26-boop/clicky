//
//  ReviewPanelController.swift
//  leanring-buddy
//
//  The NSPanel that hosts Code mode's ReviewPanelView (ClickyCore). It is a
//  real key panel (the click gate requires the app active and this window
//  key), floats above other windows, and records when it was shown so the
//  gate can refuse clicks in its first 0.5 s. Return arms the primary
//  button (a click is still needed); Esc goes to the Close/Cancel action.
//

import AppKit
import ClickyCore
import SwiftUI

/// Key-capable panel that forwards Return instead of acting on it.
final class ReviewPanel: NSPanel {
    var onReturnKey: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturnKey?(event)
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class ReviewPanelController {
    let state: ReviewPanelState
    var onReturnKey: ((NSEvent) -> Void)?
    private var panel: ReviewPanel?

    init(state: ReviewPanelState) {
        self.state = state
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(mode: ReviewPanelState.Mode) {
        state.mode = mode
        let panel = panel ?? makePanel()
        self.panel = panel
        let isReview = mode == .review
        let targetSize: NSSize
        switch mode {
        case .review: targetSize = NSSize(width: 780, height: 760)
        case .opening: targetSize = NSSize(width: 560, height: 260)
        default: targetSize = NSSize(width: 440, height: 220)
        }
        if !panel.isVisible || panel.frame.size != targetSize {
            let screenFrame = ClaudiaScreen.forClaudiasWindows?.visibleFrame ?? .zero
            let origin = NSPoint(x: screenFrame.midX - targetSize.width / 2, y: screenFrame.midY - targetSize.height / 2)
            panel.setFrame(NSRect(origin: origin, size: targetSize), display: true)
        }
        panel.title = isReview ? "Clicky — Review before sending" : "Clicky"
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Every mode change restarts the gate's 0.5 s no-click window.
        state.panelShownAt = ProcessInfo.processInfo.systemUptime
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Live progress: shown in the top-right corner without activating
    /// Clicky or taking key focus (the user keeps typing where they were).
    /// Later calls only update the card.
    func showProgress(_ snapshot: CodeTaskProgressSnapshot) {
        let mode = ReviewPanelState.Mode.working(snapshot)
        if isVisible, case .working = state.mode {
            state.mode = mode
            return
        }
        state.mode = mode
        let panel = panel ?? makePanel()
        self.panel = panel
        let targetSize = NSSize(width: 440, height: 250)
        let screenFrame = ClaudiaScreen.forClaudiasWindows?.visibleFrame ?? .zero
        let origin = NSPoint(x: screenFrame.maxX - targetSize.width - 16, y: screenFrame.maxY - targetSize.height - 16)
        panel.setFrame(NSRect(origin: origin, size: targetSize), display: true)
        panel.title = "Clicky — Working"
        panel.orderFrontRegardless()
        state.panelShownAt = ProcessInfo.processInfo.systemUptime
    }

    private func makePanel() -> ReviewPanel {
        let panel = ReviewPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 760),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ReviewPanelView(state: state))
        panel.onReturnKey = { [weak self] event in self?.onReturnKey?(event) }
        panel.delegate = closeObserver
        closeObserver.onClose = { [weak self] in self?.state.onCancel() }
        return panel
    }

    private let closeObserver = ReviewPanelCloseObserver()
}

/// The title-bar close button counts as Close.
private final class ReviewPanelCloseObserver: NSObject, NSWindowDelegate {
    var onClose: () -> Void = {}

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
