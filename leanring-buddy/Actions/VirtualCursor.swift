//
//  VirtualCursor.swift
//  leanring-buddy
//
//  Theo's own cursor. When Theo acts on its own screen, the owner's real pointer
//  stays put; this click-through arrow (the app's accent gradient, with a small
//  "Theo" label) glides to the target, ripples on a click and shows dots while
//  typing, then fades after a few idle seconds.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

@MainActor
final class VirtualCursorModel: ObservableObject {
    /// Top-left based, in the overlay window's coordinates.
    @Published var position: CGPoint = .zero
    @Published var isVisible = false
    @Published var isTyping = false
    @Published var rippleID = 0
}

@MainActor
final class VirtualCursor {
    static let shared = VirtualCursor()

    let model = VirtualCursorModel()
    private var window: SparkOverlayWindow?
    private var windowDisplayID: CGDirectDisplayID?
    private var idleTask: Task<Void, Never>?
    private var animationGeneration = 0

    static let moveDuration: TimeInterval = 0.35
    static let idleSeconds: TimeInterval = 3

    /// The picked screen's bounds in Core Graphics (top-left) coordinates.
    private var displayBoundsCG: CGRect? {
        ClaudiaScreen.picked.map { CGDisplayBounds($0.displayID) }
    }

    // MARK: Driving

    /// Glides to a Core Graphics point (clamped onto Theo's screen). Returns when it has arrived.
    func move(toCG point: CGPoint) async {
        guard let screen = ClaudiaScreen.picked, let bounds = displayBoundsCG else { return }
        ensureWindow(on: screen)
        let local = CGPoint(x: min(max(point.x - bounds.minX, 0), bounds.width), y: min(max(point.y - bounds.minY, 0), bounds.height))
        cancelIdle()
        animationGeneration += 1
        let generation = animationGeneration
        if !model.isVisible {
            // First appearance: start a little up and to the left, so it visibly travels to the target.
            model.position = CGPoint(x: max(0, local.x - 140), y: max(0, local.y - 90))
            model.isVisible = true
        }
        let start = model.position
        let startTime = ProcessInfo.processInfo.systemUptime
        while true {
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - startTime) / Self.moveDuration)
            if generation != animationGeneration { return }
            let eased = progress < 0.5 ? 4 * progress * progress * progress : 1 - pow(-2 * progress + 2, 3) / 2
            model.position = CGPoint(x: start.x + (local.x - start.x) * eased, y: start.y + (local.y - start.y) * eased)
            if progress >= 1 { break }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        scheduleIdleHide()
    }

    /// A click ripple at the cursor, with a short beat so it reads before the click lands.
    func click() async {
        guard model.isVisible else { return }
        cancelIdle()
        model.rippleID += 1
        try? await Task.sleep(nanoseconds: 120_000_000)
        scheduleIdleHide()
    }

    func setTyping(_ isTyping: Bool) {
        guard model.isVisible || !isTyping else { return }
        model.isTyping = isTyping
        if isTyping { cancelIdle() } else { scheduleIdleHide() }
    }

    func hideNow() {
        cancelIdle()
        animationGeneration += 1
        model.isTyping = false
        model.isVisible = false
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        windowDisplayID = nil
    }

    // MARK: Window

    private func ensureWindow(on screen: NSScreen) {
        if let window, windowDisplayID == screen.displayID {
            if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
            window.orderFrontRegardless()
            return
        }
        window?.orderOut(nil)
        window?.contentView = nil
        let newWindow = SparkOverlayWindow(screen: screen)
        let host = NSHostingView(rootView: VirtualCursorView(model: model))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        newWindow.contentView = host
        newWindow.orderFrontRegardless()
        window = newWindow
        windowDisplayID = screen.displayID
    }

    private func cancelIdle() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func scheduleIdleHide() {
        cancelIdle()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.model.isTyping else { return }
            self.model.isVisible = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, !self.model.isVisible else { return }
            self.window?.orderOut(nil)
            self.window?.contentView = nil
            self.window = nil
            self.windowDisplayID = nil
        }
    }
}

// MARK: - View

private let virtualCursorGradient = LinearGradient(
    colors: [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 0.93, green: 0.27, blue: 0.45), Color(red: 0.75, green: 0.27, blue: 0.9)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

private struct VirtualCursorArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Tip at the top-left; a slightly asymmetric pointer so it reads as Theo's, not the system's.
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 19))
        path.addLine(to: CGPoint(x: 4.8, y: 14.6))
        path.addLine(to: CGPoint(x: 8.2, y: 22))
        path.addLine(to: CGPoint(x: 11.4, y: 20.6))
        path.addLine(to: CGPoint(x: 8.1, y: 13.4))
        path.addLine(to: CGPoint(x: 14.5, y: 13.4))
        path.closeSubpath()
        return path
    }
}

private struct VirtualCursorView: View {
    @ObservedObject var model: VirtualCursorModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            cursor
                .opacity(model.isVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: model.isVisible)
                .offset(x: model.position.x, y: model.position.y)
        }
        .allowsHitTesting(false)
    }

    private var cursor: some View {
        ZStack(alignment: .topLeading) {
            VirtualCursorRipple(trigger: model.rippleID)
                .frame(width: 0, height: 0)
            VirtualCursorArrow()
                .fill(virtualCursorGradient)
                .overlay(VirtualCursorArrow().stroke(Color.white, lineWidth: 1.4))
                .frame(width: 16, height: 23)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1.5)
            HStack(spacing: 4) {
                Text("Theo").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.white)
                if model.isTyping { VirtualCursorTypingDots() }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(virtualCursorGradient))
            .overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
            .offset(x: 14, y: 20)
        }
    }
}

private struct VirtualCursorRipple: View {
    let trigger: Int
    @State private var progress: CGFloat = 1

    var body: some View {
        Circle()
            .stroke(virtualCursorGradient, lineWidth: 3)
            .frame(width: 46, height: 46)
            .scaleEffect(0.25 + progress * 0.75)
            .opacity(Double(1 - progress))
            .onChange(of: trigger) { _ in
                progress = 0
                withAnimation(.easeOut(duration: 0.5)) { progress = 1 }
            }
    }
}

private struct VirtualCursorTypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 6
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(Color.white).frame(width: 3.5, height: 3.5)
                        .opacity(0.35 + 0.65 * max(0, sin(phase - Double(index) * 0.9)))
                }
            }
        }
    }
}
