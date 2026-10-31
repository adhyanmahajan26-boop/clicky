//
//  TheoMenuBar.swift
//  leanring-buddy
//
//  Theo's menu-bar spark and the small panel under it: what Theo is doing,
//  anything that still needs a permission, the brain, a few quick switches,
//  and the ways into Theo's window, the Setup guide and Settings.
//

import AppKit
import AVFoundation
import ClickyCore
import Combine
import Speech
import SwiftUI

extension Notification.Name {
    /// Anything can ask the panel to close (push-to-talk, a turn starting…).
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    /// Opens the panel (debug command showPanel).
    static let theoShowPanel = Notification.Name("theoShowPanel")
}

/// A borderless panel that can take clicks without stealing focus from the app in front.
private final class TheoPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private let companionManager: CompanionManager
    private var statusItem: NSStatusItem?
    private var panel: TheoPanelWindow?
    private var outsideClickMonitor: Any?
    private var dismissObserver: NSObjectProtocol?
    private var showObserver: NSObjectProtocol?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        makeStatusItem()
        dismissObserver = NotificationCenter.default.addObserver(forName: .clickyDismissPanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        showObserver = NotificationCenter.default.addObserver(forName: .theoShowPanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
    }

    func showPanelOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.show() }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Theo")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(toggle)
        }
        statusItem = item
    }

    @objc private func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        startWatchingOutsideClicks()
    }

    private func hide() {
        panel?.orderOut(nil)
        stopWatchingOutsideClicks()
    }

    private func makePanel() -> TheoPanelWindow {
        let window = TheoPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = FirstMouseHostingView(rootView: TheoPanelView(companionManager: companionManager, close: { [weak self] in self?.hide() }))
        host.sizingOptions = [.preferredContentSize]
        window.contentView = host
        return window
    }

    /// Right under the spark in the menu bar, kept on screen.
    private func place(_ window: NSWindow) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = window.contentView?.fittingSize ?? window.frame.size
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        window.setFrame(NSRect(x: x, y: buttonFrame.minY - size.height - 6, width: size.width, height: size.height), display: true)
    }

    private func startWatchingOutsideClicks() {
        stopWatchingOutsideClicks()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}

// MARK: - The panel

/// Theo at a glance: status, quick switches you can flip in one click, the brain and voice,
/// and a short row of ways in. Laid out like Control Center: tiles, then two pickers.
struct TheoPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var speech: CompanionSpeechOutput
    @ObservedObject private var catalog = BrainCatalog.shared
    @ObservedObject private var signIn = BrainSignIn.shared
    @ObservedObject private var wake: WakeWordController
    @ObservedObject private var code: CodeModeController
    @ObservedObject private var look = LookSettings.shared
    let close: () -> Void
    @State private var speechAllowed = SFSpeechRecognizer.authorizationStatus() == .authorized
    private let ticker = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init(companionManager: CompanionManager, close: @escaping () -> Void) {
        self.companionManager = companionManager
        self.speech = companionManager.speechOutputClient
        self.wake = companionManager.wakeWordController
        self.code = companionManager.codeModeController
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !companionManager.allPermissionsGranted || !speechAllowed { permissionsBanner }
            tiles
            cursorRow
            brainSwitcher
            voicePicker
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface))
            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.background))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .onReceive(ticker) { _ in speechAllowed = SFSpeechRecognizer.authorizationStatus() == .authorized }
        .onAppear { catalog.load(); signIn.refresh() }
    }

    // MARK: Header

    private var status: (text: String, color: Color) {
        if companionManager.isHandsFreeSessionActive { return ("Listening hands-free", DS.Colors.accent) }
        switch companionManager.voiceState {
        case .listening: return ("Listening…", DS.Colors.accent)
        case .processing: return ("Thinking…", DS.Colors.accent)
        case .responding: return ("Answering…", DS.Colors.accent)
        case .idle: return (wake.isEnabled ? "Say “hey \(ClickySettings.assistantName)”" : "Ready", DS.Colors.success)
        }
    }

    private var isBusy: Bool { companionManager.voiceState != .idle || companionManager.isHandsFreeSessionActive || companionManager.isCompanionCoordinatorThinking }

    private var header: some View {
        HStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isBusy)) { timeline in
                let spin = isBusy ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2 * 360 : 0
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 0.93, green: 0.27, blue: 0.45)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: DS.Colors.accent.opacity(isBusy ? 0.8 : 0.25), radius: isBusy ? 10 : 4)
                    CompanionIconShape(style: ClickySettings.sparkStyle).fill(Color.white).frame(width: 15, height: 15).rotationEffect(.degrees(spin))
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(ClickySettings.assistantName).font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                HStack(spacing: 5) {
                    PulsingDot(color: status.color, isPulsing: isBusy)
                    Text(status.text).font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                        .contentTransition(.opacity).animation(.easeOut(duration: 0.2), value: status.text)
                }
            }
            Spacer()
            roundButton("macwindow", "Open Theo") { close(); TheoHomeWindowController.show(companionManager: companionManager) }
        }
    }

    // MARK: Permissions

    private var missing: [(String, () -> Void)] {
        var items: [(String, () -> Void)] = []
        if !companionManager.hasMicrophonePermission { items.append(("Microphone", { AVCaptureDevice.requestAccess(for: .audio) { _ in } })) }
        if !speechAllowed { items.append(("Speech", { SFSpeechRecognizer.requestAuthorization { _ in } })) }
        if !companionManager.hasAccessibilityPermission { items.append(("Accessibility", { TheoPermissions.askForAccessibility() })) }
        if !companionManager.hasScreenRecordingPermission { items.append(("Screen recording", { TheoPermissions.askForScreenRecording() })) }
        if !companionManager.hasScreenContentPermission { items.append(("Screen content", { companionManager.requestScreenContentPermission() })) }
        return items
    }

    private var permissionsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(ClickySettings.assistantName) needs a couple of things", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.warning)
            FlowRow(missing.map(\.0)) { title in
                Button(title) { missing.first { $0.0 == title }?.1() }
                    .font(.system(size: 11, weight: .medium)).buttonStyle(.borderedProminent).tint(DS.Colors.warning).controlSize(.small)
            }
            if TheoPermissions.askedForScreenRecordingThisLaunch && !companionManager.hasScreenRecordingPermission {
                Button("Allowed screen recording? Restart \(ClickySettings.assistantName)") { TheoPermissions.relaunch() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.warning.opacity(0.1)))
    }

    // MARK: Tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            tile("Voice", companionManager.isSilentModeEnabled ? "Silent" : "Talks back",
                 companionManager.isSilentModeEnabled ? "speaker.slash.fill" : "speaker.wave.2.fill", isOn: !companionManager.isSilentModeEnabled) {
                companionManager.setSilentModeEnabled(!companionManager.isSilentModeEnabled)
            }
            tile("Wake word", wake.isEnabled ? "“hey \(ClickySettings.assistantName)”" : "Off",
                 "ear.fill", isOn: wake.isEnabled) {
                wake.setEnabled(!wake.isEnabled)
            }
            tile("Hands-free", companionManager.isHandsFreeSessionActive ? "On, just talk" : "Off",
                 "waveform", isOn: companionManager.isHandsFreeSessionActive) {
                companionManager.toggleHandsFreeSession()
            }
            tile("Spark", companionManager.isClickyCursorEnabled ? "By my pointer" : "Hidden",
                 "sparkle", isOn: companionManager.isClickyCursorEnabled) {
                companionManager.setClickyCursorEnabled(!companionManager.isClickyCursorEnabled)
            }
            tile("Code mode", code.isEnabled ? "On" : "Off",
                 "chevron.left.forwardslash.chevron.right", isOn: code.isEnabled) {
                code.setEnabled(!code.isEnabled)
            }
            tile("Agents", "What's running", "person.3.fill", isOn: false) {
                close(); companionManager.showAgentsDashboard(activatesClicky: true)
            }
            tile("Bots", "Chat with your bots", "bubble.left.and.bubble.right.fill", isOn: false) {
                close(); companionManager.showBotsWindow()
            }
        }
    }

    private func tile(_ title: String, _ detail: String, _ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(isOn ? DS.Colors.accent : Color.white.opacity(0.1))
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(isOn ? .white : DS.Colors.textSecondary)
                        .symbolEffect(.bounce, value: isOn)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text(detail).font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
        }
        .buttonStyle(TileButtonStyle(isOn: isOn))
        .pointerCursor()
    }

    // MARK: Brain and voice

    /// Which agent Theo thinks with. These are the same sign-ins T3 Code uses, so if a brain works in T3 Code it works here.
    private var brainSwitcher: some View {
        let current = BrainModel(setting: companionManager.selectedModel).provider
        let symbols: [BrainProvider: String] = [.claude: "asterisk", .codex: "hexagon", .cursor: "cursorarrow.rays", .opencode: "chevron.left.forwardslash.chevron.right"]
        let short: [BrainProvider: String] = [.claude: "Claude", .codex: "ChatGPT", .cursor: "Cursor", .opencode: "OpenCode"]
        let state = signIn.states[current] ?? .checking
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(BrainProvider.allCases, id: \.self) { provider in
                    let providerState = signIn.states[provider] ?? .checking
                    Button(action: { switchBrain(to: provider) }) {
                        VStack(spacing: 4) {
                            Image(systemName: symbols[provider] ?? "circle").font(.system(size: 14, weight: .semibold))
                            Text(short[provider] ?? "").font(.system(size: 10, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(providerState.isReady ? DS.Colors.success : (providerState == .checking ? DS.Colors.textTertiary : DS.Colors.warning))
                                .frame(width: 6, height: 6).padding(5)
                        }
                    }
                    .buttonStyle(TileButtonStyle(isOn: provider == current))
                    .help("\(provider.displayName): \(providerState.label)")
                    .pointerCursor()
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: current)
            HStack(spacing: 8) {
                Text(state.isReady ? "Signed in" : state.label).font(.system(size: 11)).foregroundColor(state.isReady ? DS.Colors.success : DS.Colors.warning).help(state.label)
                if state == .signedOut {
                    Button("Sign in") { SetupModel.runInTerminal(current.signInCommand) }
                        .buttonStyle(.borderedProminent).controlSize(.mini).tint(DS.Colors.accent)
                } else if state == .notInstalled {
                    Button("Set up") { close(); SetupGuideWindowController.show(companionManager: companionManager, step: .brain) }
                        .buttonStyle(.borderedProminent).controlSize(.mini).tint(DS.Colors.accent)
                }
                Spacer()
                Menu {
                    ForEach(catalog.models[current] ?? [], id: \.self) { identifier in
                        let setting = BrainModel(provider: current, modelIdentifier: identifier).setting
                        Button(action: { companionManager.setSelectedModel(setting) }) {
                            if setting == companionManager.selectedModel { Label(catalog.label(for: setting), systemImage: "checkmark") }
                            else { Text(catalog.label(for: setting)) }
                        }
                    }
                } label: {
                    Text(catalog.label(for: companionManager.selectedModel)).font(.system(size: 11.5, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface))
    }

    private func switchBrain(to provider: BrainProvider) {
        guard provider != BrainModel(setting: companionManager.selectedModel).provider else { return }
        catalog.load()
        guard let model = catalog.defaultModel(for: provider) else { return }
        companionManager.setSelectedModel(model)
        // Helpers follow the brain (Haiku when it's Claude).
        ClickyModels.helper = provider == .claude ? ClickyModels.haiku : model
        signIn.refresh(force: true)
    }

    private var voicePicker: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.wave.2").frame(width: 20).foregroundColor(DS.Colors.textSecondary)
            Text("Voice").font(.system(size: 12.5)).foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Menu {
                Button(action: { speech.selectQwenLocalVoice() }) {
                    if speech.usesQwenLocalVoice { Label("Theo's voice (Qwen)", systemImage: "checkmark") } else { Text("Theo's voice (Qwen)") }
                }
                Button(action: { speech.selectSystemVoice(identifier: nil) }) {
                    if !speech.usesQwenLocalVoice { Label("Mac voice", systemImage: "checkmark") } else { Text("Mac voice") }
                }
                Divider()
                Button("More voices…") { close(); companionManager.voiceGalleryController.showWindow(activatesClicky: true) }
            } label: {
                Text(speech.usesQwenLocalVoice ? "Theo's voice" : "Mac voice").font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Cursor

    /// Every spark style as a small tile: one click changes the cursor.
    private var cursorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cursor").font(.system(size: 12.5)).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text(look.sparkStyle.displayName).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(CompanionIconStyle.allCases, id: \.self) { style in
                    let selected = look.sparkStyle == style
                    Button(action: { look.sparkStyle = style }) {
                        CompanionIconPreview(style: style)
                            .frame(width: 20, height: 20)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.55)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? DS.Colors.accent : Color.white.opacity(0.06), lineWidth: selected ? 2 : 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(style.displayName).pointerCursor()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            link("All settings") { close(); TheoHomeWindowController.show(companionManager: companionManager, tab: .settings) }
            link("Setup guide") { close(); SetupGuideWindowController.show(companionManager: companionManager) }
            link("Diagnostics") { close(); DiagnosticsWindowController.show(companionManager: companionManager) }
            Spacer()
            link("Quit") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 4)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary).pointerCursor()
    }

    private func roundButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                .frame(width: 28, height: 28).background(Circle().fill(DS.Colors.surface))
        }
        .buttonStyle(.plain).help(help).pointerCursor()
    }
}

/// Buttons that wrap onto more lines when they don't fit.
private struct FlowRow<Content: View>: View {
    let items: [String]
    let content: (String) -> Content
    init(_ items: [String], @ViewBuilder content: @escaping (String) -> Content) {
        self.items = items
        self.content = content
    }
    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) { ForEach(row, id: \.self) { content($0) } }
            }
        }
    }
}

/// A tile that lifts a little under the pointer, sinks when pressed, and fills when on.
struct TileButtonStyle: ButtonStyle {
    let isOn: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isOn ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn ? DS.Colors.accent.opacity(0.18) : DS.Colors.surface.opacity(isHovering ? 1.6 : 1))
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isOn ? DS.Colors.accent.opacity(0.55) : Color.white.opacity(isHovering ? 0.12 : 0.04), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovering ? 1.02 : 1))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// A status dot that breathes while Theo is busy.
struct PulsingDot: View {
    let color: Color
    let isPulsing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPulsing)) { timeline in
            let phase = isPulsing ? (sin(timeline.date.timeIntervalSinceReferenceDate * 5) + 1) / 2 : 0
            ZStack {
                Circle().fill(color.opacity(0.35)).frame(width: 6 + 6 * phase, height: 6 + 6 * phase)
                Circle().fill(color).frame(width: 6, height: 6)
            }
            .frame(width: 12, height: 12)
        }
    }
}
