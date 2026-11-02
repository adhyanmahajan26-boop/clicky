//
//  TheoCallWindow.swift
//  leanring-buddy
//
//  The call window: Theo's face with rings that follow the voice, what's being said as it's said, mute and end.
//

import AppKit
import AVFoundation
import ClickyCore
import SwiftUI

@MainActor
enum TheoCallController {
    private static var window: NSWindow?
    private(set) static var session: TheoCallSession?

    static var isActive: Bool { session != nil && session?.state != .ended }

    /// Opens the window and starts the call, or brings the running call forward. `activates` false leaves focus alone.
    static func start(activates: Bool = true) {
        if let window, isActive {
            if activates { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
            window.orderFrontRegardless()
            return
        }
        guard let manager = CompanionManager.current else { return }
        let isLive = !TheoProfile.isTest
        if isLive, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { MainActor.assumeIsolated { if granted { start(activates: activates) } } }
            }
            return
        }
        // Clicky stops talking and listening for the length of the call.
        manager.speechOutputClient.stopPlayback()
        manager.speechOutputClient.audioEngineHub.claimMicrophone(for: .call)
        CompanionSpeechOutput.isZeroVolumeForTests = TheoProfile.isTest || CompanionSpeechOutput.isZeroVolumeForTests
        let session = TheoCallSession(store: BotsStore.shared, hub: manager.speechOutputClient.audioEngineHub, isLive: isLive)
        self.session = session
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 660),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        created.title = "Call with Theo"
        created.titleVisibility = .hidden
        created.titlebarAppearsTransparent = true
        created.isReleasedWhenClosed = false
        created.isMovableByWindowBackground = true
        created.contentView = FirstMouseHostingView(rootView: TheoCallView(session: session, onEnd: { end() }))
        created.center()
        ClaudiaScreen.place(created)
        window = created
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: created, queue: .main) { _ in
            MainActor.assumeIsolated { end() }
        }
        if activates { NSApp.activate(ignoringOtherApps: true); created.makeKeyAndOrderFront(nil) }
        created.orderFrontRegardless()
        session.start()
    }

    static func end() {
        guard let session, session.state != .ended else { return }
        session.end()
        CompanionManager.current?.speechOutputClient.audioEngineHub.releaseMicrophone(for: .call)
        window?.orderOut(nil)
        window = nil
    }

    static var windowNumber: Int? { window?.windowNumber }
}

struct TheoCallView: View {
    @ObservedObject var session: TheoCallSession
    let onEnd: () -> Void
    @ObservedObject private var store = BotsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            CallAvatar(session: session, theo: store.primary).frame(height: 214)
            Text(stateLine).font(.system(size: 14, weight: .medium)).foregroundColor(DS.Colors.textSecondary).animation(nil, value: session.state)
            transcript
            if let problem = session.problem {
                Text(problem).font(.system(size: 11)).foregroundColor(DS.Colors.warning).padding(.horizontal, 22).padding(.bottom, 4)
                    .multilineTextAlignment(.center).lineLimit(2)
            }
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.background)
        .modifier(TheoAppearanceRoot())
    }

    private var header: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(session.startedAt))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Menu {
                ForEach(CallSettings.Language.allCases) { language in
                    Button(language.title) { session.changeLanguage(language) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 11))
                    Text(session.language.title).font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textSecondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.leading, 76).padding(.trailing, 16).frame(height: 38)
    }

    private var stateLine: String {
        switch session.state {
        case .connecting: return "Connecting…"
        case .listening: return session.isMuted ? "You're muted" : "Listening"
        case .userSpeaking: return "Go on"
        case .thinking: return "Thinking"
        case .speaking: return "Theo is talking. Just talk to cut in."
        case .ended: return "Call ended"
        }
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.lines) { line in
                        CallLineView(line: line).id(line.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 22).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.lines) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 28) {
                Button { session.setMuted(!session.isMuted) } label: {
                    Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill").font(.system(size: 19, weight: .semibold))
                        .foregroundColor(session.isMuted ? Color(hex: 0x17181C) : DS.Colors.textPrimary)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(session.isMuted ? Color.white : DS.Colors.hover))
                        .overlay(Circle().strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help(session.isMuted ? "Unmute" : "Mute").keyboardShortcut("m", modifiers: .command)
                Button(action: onEnd) {
                    Image(systemName: "phone.down.fill").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color(hex: 0xE5484D)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help("End the call").keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 6) {
                Text("Ears: \(session.earsName)")
                Text("·")
                Text("Voice: \(session.voiceName)")
                if let first = session.lastFirstAudio {
                    Text("·")
                    Text(String(format: "first sound %.1f s", first))
                }
            }
            .font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
        }
        .padding(.top, 8).padding(.bottom, 18)
    }
}

private struct CallLineView: View {
    let line: TheoCallSession.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.who == .addy ? "You" : "Theo").font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(line.who == .addy ? DS.Colors.textTertiary : DS.Colors.accentText)
            if line.text.isEmpty && line.isLive {
                TypingDots()
            } else {
                Text(line.text + (line.wasCut ? " —" : "")).font(.system(size: 14))
                    .foregroundColor(line.who == .addy && line.isLive ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Theo's face with rings: they follow the voice when it talks, the mic when Addy does, and turn slowly while it thinks.
private struct CallAvatar: View {
    @ObservedObject var session: TheoCallSession
    let theo: NativeBot?
    @State private var smoothed: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let level = currentLevel(t)
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    let grow = CGFloat(index + 1) * (5 + level * 11)
                    Circle()
                        .stroke(ringColor.opacity(0.32 - Double(index) * 0.09), lineWidth: 2)
                        .frame(width: 124 + grow * 2, height: 124 + grow * 2)
                }
                if session.state == .thinking {
                    Circle().trim(from: 0, to: 0.24)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 142, height: 142)
                        .rotationEffect(.degrees(t * 220))
                }
                if let theo {
                    BotAvatar(bot: theo, size: 112, state: session.state == .speaking || session.state == .thinking ? .typing : .idle)
                }
            }
        }
    }

    private func currentLevel(_ t: Double) -> CGFloat {
        switch session.state {
        case .speaking: return 0.45 + 0.35 * CGFloat(abs(sin(t * 5.1)) * 0.6 + abs(sin(t * 2.3)) * 0.4)
        case .userSpeaking, .listening: return session.isMuted ? 0 : session.micLevel
        case .thinking: return 0.15
        default: return 0
        }
    }

    private var ringColor: Color {
        switch session.state {
        case .speaking, .thinking: return DS.Colors.accent
        case .userSpeaking: return Color(hex: 0x6EE7A0)
        default: return DS.Colors.textTertiary
        }
    }
}
