//
//  ActionConfirmCard.swift
//  leanring-buddy
//
//  P7: the card for a confirm-tier step ("Press “Send” in Mail?"). Never
//  key, never activating, so the owner's app keeps focus. Confirm counts
//  only for a real mouse click (ActionConfirmClickGate: Clicky's own tagged
//  events never count, nor a click in the card's first 0.5 s — the same
//  rules as the code-mode click gate). The spoken "yes" goes through
//  ActionTaskController instead. Return on the card does nothing.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

final class ActionConfirmCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ActionConfirmHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ActionConfirmCardModel: ObservableObject {
    @Published var title = ""
    @Published var detail = ""
}

@MainActor
final class ActionConfirmCardController {
    var onConfirm: () -> Void = {}
    var onCancel: () -> Void = {}

    private let model = ActionConfirmCardModel()
    private var panel: ActionConfirmCardPanel?
    private var shownAt: TimeInterval = 0
    private(set) var isVisible = false

    func show(title: String, detail: String) {
        model.title = title
        model.detail = detail
        let panel = panel ?? makePanel()
        self.panel = panel
        let size = NSSize(width: 360, height: 124)
        let screenFrame = ClaudiaScreen.forClaudiasWindows?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screenFrame.maxX - size.width - 16, y: screenFrame.maxY - size.height - 16, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        shownAt = ProcessInfo.processInfo.systemUptime
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    private func isAcceptableClick() -> Bool {
        let userData = NSApp.currentEvent?.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        return ActionConfirmClickGate.accepts(eventSourceUserData: userData, secondsSinceShown: ProcessInfo.processInfo.systemUptime - shownAt)
    }

    private func makePanel() -> ActionConfirmCardPanel {
        let panel = ActionConfirmCardPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 124), styleMask: [.nonactivatingPanel, .borderless],
                                           backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        let cardView = ActionConfirmCardView(model: model, onConfirm: { [weak self] in
            guard let self, self.isAcceptableClick() else { return }
            self.onConfirm()
        }, onCancel: { [weak self] in
            guard let self, self.isAcceptableClick() else { return }
            self.onCancel()
        })
        panel.contentView = ActionConfirmHostingView(rootView: cardView)
        return panel
    }
}

private struct ActionConfirmCardView: View {
    @ObservedObject var model: ActionConfirmCardModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundColor(.orange)
                Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            Text(model.detail).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
            Text("Say \u{201C}yes\u{201D} or click Confirm. Anything else cancels.").font(.system(size: 10.5)).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .onHover { isHovering in if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                Button("Confirm", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .onHover { isHovering in if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ActionConfirmBackground())
    }
}

private struct ActionConfirmBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
