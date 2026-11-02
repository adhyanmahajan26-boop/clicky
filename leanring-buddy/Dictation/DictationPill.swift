//
//  DictationPill.swift
//  leanring-buddy
//
//  The small floating pill while dictating: near the bottom centre of the active screen, a live waveform while the
//  keys are held, a brief "Transcribing", then gone. It never takes focus or clicks: it's only there to look at.
//

import AppKit
import ClickyCore
import SwiftUI

@MainActor
final class DictationPillController {
    private unowned let controller: DictationController
    private var panel: NSPanel?
    private static let size = NSSize(width: 236, height: 46)
    private static let bottomGap: CGFloat = 54

    init(controller: DictationController) {
        self.controller = controller
    }

    var windowNumber: Int? { panel?.isVisible == true ? panel?.windowNumber : nil }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let frame = (Self.activeScreen() ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + Self.bottomGap))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = "Dictation"
        panel.contentView = NSHostingView(rootView: DictationPillView(controller: controller))
        return panel
    }

    /// The screen of the window being typed in: its focused window if Accessibility can say, else the pointer's screen.
    private static func activeScreen() -> NSScreen? {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
           let focused = ActionExecutor.focusedWindow(processIdentifier: app.processIdentifier), let frame = TypeForMeAccessibility.frameCG(of: focused) {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let centre = NSPoint(x: frame.midX, y: primaryHeight - frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) }) { return screen }
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) }
    }
}

struct DictationPillView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .listening:
                Image(systemName: "mic.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: 0xFF8A5B))
                DictationWaveform(levels: controller.levels)
            case .transcribing:
                ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 14, height: 14).tint(.white)
                Text("Transcribing").font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.9))
                Spacer(minLength: 0)
            case .typed:
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(Color(hex: 0x6EE7A0))
                Text("Typed").font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.9))
                Spacer(minLength: 0)
            case .failed(let message):
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundColor(Color(hex: 0xFBBF24))
                Text(message).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.9)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 236, height: 46)
        .background(Capsule().fill(Color(hex: 0x17181C).opacity(0.96)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .clipShape(Capsule())
    }
}

/// Bars that follow the voice, newest on the right.
struct DictationWaveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule().fill(Color.white.opacity(0.35 + 0.65 * Double(index) / Double(max(levels.count - 1, 1))))
                    .frame(width: 3, height: 4 + 22 * level)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.linear(duration: 0.06), value: levels)
    }
}
