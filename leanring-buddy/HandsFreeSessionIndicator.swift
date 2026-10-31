//
//  HandsFreeSessionIndicator.swift
//  leanring-buddy
//
//  A small floating pill at the top of the screen shown for the whole
//  hands-free session, so it's always obvious the mic is open. Shows whether
//  Clicky is listening, paused, or thinking, the words it last heard, quick
//  feedback like "Saved capture 3", and how to end the session.
//
//  Click-through and non-activating, like the cursor overlay, so it never
//  steals focus. It's one of this app's windows, so screen captures exclude it.
//

import AppKit
import SwiftUI

final class HandsFreeSessionIndicatorManager {
    private var indicatorPanel: NSPanel?

    private static let indicatorWidth: CGFloat = 380
    private static let indicatorHeight: CGFloat = 56
    private static let gapBelowMenuBar: CGFloat = 8

    func showIndicator(companionManager: CompanionManager) {
        hideIndicator()

        let mouseLocation = NSEvent.mouseLocation
        guard let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            return
        }

        // visibleFrame excludes the menu bar, so maxY sits right under it.
        let indicatorFrame = NSRect(
            x: cursorScreen.visibleFrame.midX - Self.indicatorWidth / 2,
            y: cursorScreen.visibleFrame.maxY - Self.indicatorHeight - Self.gapBelowMenuBar,
            width: Self.indicatorWidth,
            height: Self.indicatorHeight
        )

        let panel = NSPanel(
            contentRect: indicatorFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: HandsFreeSessionIndicatorView(companionManager: companionManager))
        hostingView.frame = NSRect(origin: .zero, size: indicatorFrame.size)
        panel.contentView = hostingView

        panel.orderFrontRegardless()
        indicatorPanel = panel
    }

    func hideIndicator() {
        indicatorPanel?.orderOut(nil)
        indicatorPanel = nil
    }
}

private struct HandsFreeSessionIndicatorView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var isStatusDotPulsing = false

    private var sessionPhaseTitle: String {
        if companionManager.voiceState == .processing {
            return "Thinking…"
        }
        if companionManager.isHandsFreeSessionPaused {
            return "Paused"
        }
        return "Listening"
    }

    private var statusDotColor: Color {
        if companionManager.voiceState == .processing {
            return DS.Colors.accentText
        }
        if companionManager.isHandsFreeSessionPaused {
            return DS.Colors.warning
        }
        return DS.Colors.success
    }

    /// Feedback first ("Saved capture 3"), then what was last heard, then
    /// the default hint so the user always knows what they can say.
    private var sessionDetailText: String {
        if let handsFreeStatusMessage = companionManager.handsFreeStatusMessage {
            return handsFreeStatusMessage
        }
        if companionManager.isHandsFreeSessionPaused {
            return "Say “go” to continue · “done” to end"
        }
        let lastHeardText = companionManager.handsFreeLastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastHeardText.isEmpty {
            return "“\(lastHeardText)”"
        }
        return "Just talk · “wait” · “capture” · “done” · Esc to stop"
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusDotColor.opacity(0.7), radius: isStatusDotPulsing ? 6 : 2)
                .scaleEffect(isStatusDotPulsing ? 1.15 : 0.9)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isStatusDotPulsing)

            VStack(alignment: .leading, spacing: 2) {
                Text(sessionPhaseTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(sessionDetailText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 0)

            if companionManager.handsFreeSessionCaptureCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(companionManager.handsFreeSessionCaptureCount)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.96))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .onAppear {
            isStatusDotPulsing = true
        }
    }
}
