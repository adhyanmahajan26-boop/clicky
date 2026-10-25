//
//  TypeCardPanelController.swift
//  leanring-buddy
//
//  The NSPanel that hosts the "Type this for me" card (TypeCardView in
//  ClickyCore). It is non-activating — the target app stays frontmost, so
//  its focused field stays the target — but can become key, so the user's
//  Return reaches it. Return/Enter key events are taken out of the normal
//  event flow and handed to the controller's confirm gate (they never reach
//  a SwiftUI button); Esc cancels. Placed just below the caret, converted
//  from CG to AppKit through ScreenTopology only.
//

import AppKit
import ClickyCore
import SwiftUI

/// Key-capable, non-activating panel that routes Return and Esc to closures.
final class TypeCardPanel: NSPanel {
    var onReturnKeyEvent: ((NSEvent) -> Void)?
    var onEscapeKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if TypeConfirmEventMapping.isReturnKey(event) {
            onReturnKeyEvent?(event)
            return
        }
        if event.type == .keyDown, event.keyCode == TypeConfirmEventMapping.escapeKeyCode {
            onEscapeKey?()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class TypeCardPanelController: NSObject, NSWindowDelegate {
    var onReturnKeyEvent: ((NSEvent) -> Void)?
    var onEscapeKey: (() -> Void)?
    /// The card lost key status while showing (the user clicked elsewhere).
    var onResignKey: (() -> Void)?
    private var panel: TypeCardPanel?
    private var isHidingOnPurpose = false

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the card for `state` under the caret; returns when it became visible (systemUptime).
    @discardableResult
    func show(state: TypeCardState, caretRectCG: CGRect?) -> TimeInterval {
        let panel = panel ?? makePanel()
        self.panel = panel
        let hostingView = NSHostingView(rootView: TypeCardView(state: state))
        panel.contentView = hostingView
        let cardSize = hostingView.fittingSize
        let flipHeight = ScreenTopology.mainDisplayHeight
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let caretAppKit: CGRect
        if let caretRectCG {
            caretAppKit = ScreenTopology.appKit(fromCG: caretRectCG, flipH: flipHeight)
        } else {
            let mouseLocation = NSEvent.mouseLocation
            caretAppKit = CGRect(x: mouseLocation.x, y: mouseLocation.y, width: 1, height: 1)
        }
        panel.setFrame(TypeCardPlacement.frame(caretAppKit: caretAppKit, cardSize: cardSize, visibleFrames: visibleFrames), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        return ProcessInfo.processInfo.systemUptime
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        isHidingOnPurpose = true
        panel.orderOut(nil)
        isHidingOnPurpose = false
    }

    private func makePanel() -> TypeCardPanel {
        let panel = TypeCardPanel(contentRect: NSRect(x: 0, y: 0, width: TypeCardView.cardWidth, height: 200),
                                  styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.onReturnKeyEvent = { [weak self] event in self?.onReturnKeyEvent?(event) }
        panel.onEscapeKey = { [weak self] in self?.onEscapeKey?() }
        panel.delegate = self
        return panel
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !isHidingOnPurpose, isVisible else { return }
            onResignKey?()
        }
    }
}
