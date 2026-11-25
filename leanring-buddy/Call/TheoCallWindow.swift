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

    /// Opens the window and starts the call, or brings the running call forward. `botID` nil is Vello's own bot; any other
    /// bot gets a call of its own. One call at a time: asking for another while one runs brings up the running one.
    /// `activates` false leaves focus alone. `openingWords`: what the owner already said ("hey vello, find my mails from
    /// Sam" → "find my mails from Sam"), the call's first turn instead of the hello.
    static func start(botID: String? = nil, activates: Bool = true, openingWords: String = "", ownAccount: XAccountSetup? = nil) {
        if let window, isActive {
            if activates { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
            window.orderFrontRegardless()
            session?.takeOwnerWordsFromOutside(openingWords)
            return
        }
        guard let manager = CompanionManager.current else { return }
        let isLive = !TheoProfile.isTest
        // A Space on Vello's own account never uses the mic.
        if isLive, ownAccount == nil, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { MainActor.assumeIsolated { if granted { start(botID: botID, activates: activates, openingWords: openingWords) } } }
            }
            return
        }
        // Clicky stops talking and listening for the length of the call.
        manager.speechOutputClient.stopPlayback()
        manager.speechOutputClient.audioEngineHub.claimMicrophone(for: .call)
        CompanionSpeechOutput.isZeroVolumeForTests = TheoProfile.isTest || CompanionSpeechOutput.isZeroVolumeForTests
        let session = TheoCallSession(store: BotsStore.shared, hub: manager.speechOutputClient.audioEngineHub, isLive: isLive, botID: botID,
                                      ownAccount: ownAccount)
        self.session = session
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 660),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        created.title = session.isOwnAccount ? "\(session.botName) in an X Space" : "Call with \(session.botName)"
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
        session.start(openingWords: openingWords)
    }

    /// "Join a Space as Vello": opens the Space's link (if one was pasted) in the bot's browser, then runs the call on
    /// Vello's own X account, hearing only that browser and speaking into its virtual mic. A person taps Join and Request
    /// to speak there; Vello never touches the page. Nil when it started, else why it didn't.
    @discardableResult
    static func joinSpaceAsVello(link: URL?, activates: Bool = true) -> String? {
        if isActive {
            if let window { window.orderFrontRegardless() }
            return session?.isOwnAccount == true ? nil : "A call is going on now. End it first."
        }
        let setup = XAccountSettings.setup()
        guard setup.browser != nil, setup.browserAppURL != nil else {
            return "Pick the bot's browser in Settings › Voice › Vello's X account first."
        }
        if let link { XAccountSettings.openBotBrowser(link: link) }
        start(activates: activates, ownAccount: setup)
        return nil
    }

    static func end() {
        guard let session, session.state != .ended else { return }
        session.end()
        CompanionManager.current?.speechOutputClient.audioEngineHub.releaseMicrophone(for: .call)
        window?.orderOut(nil)
        window = nil
    }

    static var windowNumber: Int? { window?.windowNumber }
    static var windowTitle: String? { window?.title }
}

struct TheoCallView: View {
    @ObservedObject var session: TheoCallSession
    let onEnd: () -> Void
    @ObservedObject private var store = BotsStore.shared
    /// The call's own settings, right in the call: they were only in Settings › Voice, where they were hard to find.
    @AppStorage(CallTurnPatience.settingKey) private var callPatienceSeconds = CallTurnPatience.defaultSeconds
    @AppStorage(CallNearVoice.settingKey) private var nearVoiceOnly = true

    var body: some View {
        VStack(spacing: 0) {
            header
            CallAvatar(session: session, theo: session.bot ?? store.primary).frame(height: 214)
            Text(stateLine).font(.system(size: 14, weight: .medium)).foregroundColor(DS.Colors.textSecondary).animation(nil, value: session.state)
                .lineLimit(1)
            if session.isOwnAccount {
                OwnAccountStrip(session: session)
            } else if session.isGroupMode {
                Text("Group mode: everyone counts, and \(session.botName) joins in when it fits")
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1).padding(.top, 2)
            } else if session.isListenMode {
                Text("Say “\(session.botName), what do you think?” when you want an answer")
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1).padding(.top, 2)
            }
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
            Menu {
                Section("Patience: how long \(session.botName) waits after you stop") {
                    ForEach(Self.patienceChoices, id: \.self) { seconds in
                        Button {
                            callPatienceSeconds = seconds
                        } label: {
                            if abs(CallTurnPatience.seconds(saved: callPatienceSeconds) - seconds) < 0.01 {
                                Label(Self.patienceTitle(seconds), systemImage: "checkmark")
                            } else {
                                Text(Self.patienceTitle(seconds))
                            }
                        }
                    }
                }
                Section {
                    Toggle("Only hear voices near the Mac", isOn: $nearVoiceOnly)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "timer").font(.system(size: 11))
                    Text(String(format: "%.1f s", CallTurnPatience.seconds(saved: callPatienceSeconds))).font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textSecondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Patience, and whether voices across the room count")
            .pointerCursor()
        }
        .padding(.leading, 76).padding(.trailing, 16).frame(height: 38)
    }

    private static let patienceChoices: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0]

    private static func patienceTitle(_ seconds: Double) -> String {
        let number = String(format: "%.1f s", seconds)
        if seconds == CallTurnPatience.defaultSeconds { return number + " (usual)" }
        return seconds < CallTurnPatience.defaultSeconds ? number + " (quicker)" : number + " (lets you think)"
    }

    private var stateLine: String {
        switch session.state {
        case .connecting: return "Connecting…"
        case .listening:
            if session.isMuted { return session.isOwnAccount ? "Not hearing the Space" : "You're muted" }
            if session.isOwnAccount { return "Listening to the Space" }
            return session.isListenMode ? "Just listening" : "Listening"
        case .userSpeaking:
            if session.isOwnAccount { return "\(session.currentSpeaker ?? "Someone") is talking" }
            return session.isListenMode ? "Just listening" : "Go on"
        case .thinking: return "Thinking"
        case .speaking: return session.isOwnAccount ? "\(session.botName) is talking in the Space" : "\(session.botName) is talking. Just talk to cut in."
        case .ended: return "Call ended"
        }
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.lines) { line in
                        CallLineView(line: line, botName: session.botName, isOwnAccount: session.isOwnAccount).id(line.id)
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
                .buttonStyle(.plain).help(session.isOwnAccount ? (session.isMuted ? "Hear the Space again" : "Stop hearing the Space") : (session.isMuted ? "Unmute" : "Mute"))
                .keyboardShortcut("m", modifiers: .command)
                .pointerCursor()
                // A Space on Vello's own account is always in group mode, and never in Listen mode.
                if !session.isOwnAccount {
                    Button { session.setListenMode(!session.isListenMode) } label: {
                        Image(systemName: "ear").font(.system(size: 19, weight: .semibold))
                            .foregroundColor(session.isListenMode ? Color(hex: 0x17181C) : DS.Colors.textPrimary)
                            .frame(width: 58, height: 58)
                            .background(Circle().fill(session.isListenMode ? Color.white : DS.Colors.hover))
                            .overlay(Circle().strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(session.isListenMode
                          ? "Listen mode is on: \(session.botName) only listens until you ask it something. Click to talk normally."
                          : "Listen mode: \(session.botName) only listens and keeps track, and answers when you ask. You can also say “listen mode”.")
                    .keyboardShortcut("l", modifiers: .command)
                    .pointerCursor()
                    Button { session.setGroupMode(!session.isGroupMode) } label: {
                        Image(systemName: "person.3").font(.system(size: 17, weight: .semibold))
                            .foregroundColor(session.isGroupMode ? Color(hex: 0x17181C) : DS.Colors.textPrimary)
                            .frame(width: 58, height: 58)
                            .background(Circle().fill(session.isGroupMode ? Color.white : DS.Colors.hover))
                            .overlay(Circle().strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(session.isGroupMode
                          ? "Group mode is on: \(session.botName) hears everyone and joins in when it fits. Click for just the two of you."
                          : "Group mode, for an X Space or a room with other people: \(session.botName) hears everyone and joins in when it fits. You can also say “group mode”.")
                    .keyboardShortcut("g", modifiers: .command)
                    .pointerCursor()
                }
                Button(action: onEnd) {
                    Image(systemName: "phone.down.fill").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color(hex: 0xE5484D)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help(session.isOwnAccount ? "Leave the Space: Vello stops hearing and speaking" : "End the call").keyboardShortcut(.cancelAction)
                .pointerCursor()
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

/// A Space on Vello's own account: which account, how loud the bot's browser is, who's talking, and the two taps that
/// are the owner's to make.
private struct OwnAccountStrip: View {
    @ObservedObject var session: TheoCallSession

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10))
                Text("In the Space as \(session.ownAccount?.handle.isEmpty == false ? session.ownAccount!.handle : "Vello's own account")")
                Text("·")
                Text("Hearing")
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Colors.hover)
                        Capsule().fill(Color(hex: 0x6EE7A0)).frame(width: proxy.size.width * (session.isMuted ? 0 : session.micLevel))
                    }
                }
                .frame(width: 54, height: 5)
            }
            .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
            Text(session.currentSpeaker.map { "Talking now: \($0)" } ?? CallOwnAccount.joinNote)
                .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
        }
        .padding(.top, 2)
    }
}

private struct CallLineView: View {
    let line: TheoCallSession.Line
    let botName: String
    var isOwnAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.who == .addy ? (line.wasOnlyHeard ? "Heard" : (line.isGroupTalk ? (isOwnAccount ? "The Space" : "The group") : "You")) : botName).font(.system(size: 10.5, weight: .semibold))
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
