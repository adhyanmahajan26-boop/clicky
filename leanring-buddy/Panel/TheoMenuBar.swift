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
    /// Grounding's capture warm-up saw other apps' windows (screen content is allowed).
    static let clickyScreenContentSeen = Notification.Name("clickyScreenContentSeen")
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
    private var faceUpdater: MenuBarFaceUpdater?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        if !TheoProfile.isTest { makeStatusItem() }
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // The micro face of the most urgent state, and how many bots are in it.
            button.target = self
            button.action = #selector(toggle)
            faceUpdater = MenuBarFaceUpdater(button: button)
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
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            // The test profile has no menu-bar icon: the panel opens at the top right of Theo's screen.
            if let screen = ClaudiaScreen.picked {
                let size = window.contentView?.fittingSize ?? window.frame.size
                window.setFrame(NSRect(x: screen.visibleFrame.maxX - size.width - 12, y: screen.visibleFrame.maxY - size.height - 12, width: size.width, height: size.height), display: true)
            }
            return
        }
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
            MenuBarUrgentRows(close: close)
            if !companionManager.allPermissionsGranted || !speechAllowed { permissionsBanner }
            ClickyMacSwitch()
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
            // Theo's own face, in the most urgent state of the team (the same face the menu bar shows).
            if let theo = BotsStore.shared.primary {
                CrewAvatar(look: theo.crewLook, size: 30, pose: isBusy ? .listening : MenuBarFace.summary().state, interactive: false, name: theo.name, ring: DS.Colors.background)
                    .frame(width: 30, height: 30)
            }
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
            roundButton("phone.fill", "Call Theo") { close(); TheoCallController.start() }
        }
    }

    // MARK: Permissions

    /// A permission Theo doesn't have: its name, its symbol, whether macOS has asked yet, and what the one button does.
    private var missing: [(name: String, symbol: String, asked: Bool, action: () -> Void)] {
        var items: [(name: String, symbol: String, asked: Bool, action: () -> Void)] = []
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if !companionManager.hasMicrophonePermission {
            items.append(("Microphone", "mic.fill", micStatus != .notDetermined, { AVCaptureDevice.requestAccess(for: .audio) { _ in } }))
        }
        if !speechAllowed {
            items.append(("Speech", "waveform", SFSpeechRecognizer.authorizationStatus() != .notDetermined, { SFSpeechRecognizer.requestAuthorization { _ in } }))
        }
        if !companionManager.hasAccessibilityPermission { items.append(("Accessibility", "accessibility", true, { _ = TheoPermissions.askForAccessibility() })) }
        if !companionManager.hasScreenRecordingPermission { items.append(("Screen recording", "rectangle.dashed.badge.record", true, { _ = TheoPermissions.askForScreenRecording() })) }
        if !companionManager.hasScreenContentPermission { items.append(("Screen access", "macwindow", true, { companionManager.requestScreenContentPermission() })) }
        return items
    }

    /// The Mac permissions Theo still needs, as rows: app tile, name, pill, one button. Only the owner can flip these.
    private var permissionsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mac permissions").font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("\(missing.count)").font(.system(size: 12, weight: .semibold)).foregroundColor(PixelTone.needs.text)
            }
            ForEach(missing, id: \.name) { item in
                HStack(spacing: 10) {
                    AppTile(symbol: item.symbol, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.system(size: 12.5, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                        StatusPill(text: item.asked ? "Needs you" : "Not asked", tone: item.asked ? .warn : .neutral)
                    }
                    Spacer(minLength: 4)
                    Button(item.asked ? "Open Settings" : "Allow") {
                        // A test never asks for a permission: it records what the button would do.
                        if TheoProfile.isTest { TheoOpen.record("permission \(item.name)") } else { item.action() }
                    }
                    .buttonStyle(.theo(.secondary, .small))
                }
            }
            if TheoPermissions.askedForScreenRecordingThisLaunch && !companionManager.hasScreenRecordingPermission {
                Button("Allowed screen recording? Restart \(ClickySettings.assistantName)") { TheoPermissions.relaunch() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PixelTone.needs.cardBorder, lineWidth: 1))
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
            tile("Agents", "Activity", "person.3.fill", isOn: false) {
                close(); companionManager.showAgentsDashboard(activatesClicky: true)
            }
        }
    }

    private func tile(_ title: String, _ detail: String, _ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(isOn ? DS.Colors.accent : Color.white.opacity(0.1))
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(isOn ? .white : DS.Colors.textSecondary)
                        .symbolEffect(.bounce, options: DS.Motion.isReduced ? .nonRepeating.speed(100) : .default, value: isOn)
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
        let logos: [BrainProvider: String] = [.claude: "claude", .codex: "codex", .cursor: "cursor", .opencode: "opencode"]
        let short: [BrainProvider: String] = [.claude: "Claude", .codex: "ChatGPT", .cursor: "Cursor", .opencode: "OpenCode"]
        let state = signIn.states[current] ?? .checking
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(BrainProvider.allCases, id: \.self) { provider in
                    let providerState = signIn.states[provider] ?? .checking
                    Button(action: { switchBrain(to: provider) }) {
                        VStack(spacing: 4) {
                            BrandLogo(id: logos[provider] ?? "", size: 16, plain: true)
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
                    Button("Sign in") { close(); TheoSettingsWindowController.show(section: .coding) }
                        .buttonStyle(.borderedProminent).controlSize(.mini).tint(DS.Colors.accent)
                } else if state == .notInstalled {
                    Button("Set up") { close(); SetupGuideWindowController.show(companionManager: companionManager, step: .harnesses) }
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
            Text("Speaks with").font(.system(size: 12.5)).foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Menu {
                Button(action: { speech.selectQwenLocalVoice() }) {
                    if speech.usesQwenLocalVoice { Label("Theo's voice", systemImage: "checkmark") } else { Text("Theo's voice") }
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
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? DS.Colors.accent : DS.Colors.hover, lineWidth: selected ? 2 : 1))
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
            link("All settings") { close(); TheoSettingsWindowController.show() }
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
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPulsing || DS.Motion.isReduced)) { timeline in
            let phase = isPulsing && !DS.Motion.isReduced ? (sin(timeline.date.timeIntervalSinceReferenceDate * 5) + 1) / 2 : 0
            ZStack {
                Circle().fill(color.opacity(0.35)).frame(width: 6 + 6 * phase, height: 6 + 6 * phase)
                Circle().fill(color).frame(width: 6, height: 6)
            }
            .frame(width: 12, height: 12)
        }
    }
}

// MARK: - The menu bar face

/// What the menu bar icon shows: calm is Theo's `awake` micro face with no count; otherwise the most urgent of failed,
/// needs you and working, with how many bots are in it.
enum MenuBarFace {
    struct Summary: Equatable {
        let state: PixelState
        let count: Int
    }

    @MainActor
    static func summary(store: BotsStore = .shared) -> Summary {
        let states = (store.bots + [store.clickyBot]).filter(\.isOn).map { store.pixelState(of: $0).state }
        for urgent in [PixelState.failed, .needs] {
            let count = states.filter { $0 == urgent }.count
            if count > 0 { return Summary(state: urgent, count: count) }
        }
        let working = states.filter { $0.lane == .working }.count
        if working > 0 { return Summary(state: .working, count: working) }
        return Summary(state: .awake, count: 0)
    }

    /// The micro face as a menu bar image: a bone shell on a dark menu bar, onyx on a light one.
    static func image(for state: PixelState, darkMenuBar: Bool) -> NSImage {
        let look = PixelLook(finish: darkMenuBar ? "bone" : "onyx", trim: 0xFF7A45, eye: "block", top: "none", extra: "none")
        let image = PixelDrawing.faceImage(look: look, state: state, size: 18, isDark: darkMenuBar, scale: 3)
        image.isTemplate = false
        image.accessibilityDescription = "Theo: \(state.label)"
        return image
    }
}

/// Keeps the status item's face and count in step with the bots, without redrawing on every streamed word.
@MainActor
final class MenuBarFaceUpdater {
    private weak var button: NSStatusBarButton?
    private var cancellables: Set<AnyCancellable> = []
    private var shown: (MenuBarFace.Summary, Bool)?

    init(button: NSStatusBarButton) {
        self.button = button
        BotsStore.shared.objectWillChange
            .merge(with: ConnectorHealth.shared.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        Timer.publish(every: 20, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.update() }.store(in: &cancellables)
        update()
    }

    func update() {
        guard let button else { return }
        let summary = MenuBarFace.summary()
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let shown, shown.0 == summary, shown.1 == dark { return }
        shown = (summary, dark)
        button.image = MenuBarFace.image(for: summary.state, darkMenuBar: dark)
        button.imagePosition = .imageLeading
        button.title = summary.count > 0 ? " \(summary.count)" : ""
        button.toolTip = summary.count > 0 ? "\(summary.count) \(summary.state == .working ? "working" : summary.state.label.lowercased())" : "Theo"
    }
}

/// Needs you and Failed, at the top of the panel: the bot, one line, one button.
struct MenuBarUrgentRows: View {
    @ObservedObject private var store = BotsStore.shared
    @ObservedObject private var health = ConnectorHealth.shared
    let close: () -> Void

    var body: some View {
        let needing = store.bots.filter { $0.isOn && store.pixelState(of: $0).state == .needs }
        let failed = store.bots.filter { store.pixelState(of: $0).state == .failed }
        let working = store.bots.filter { store.pixelState(of: $0).state.lane == .working }
        if !needing.isEmpty || !failed.isEmpty || !working.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !needing.isEmpty {
                    heading("Needs you", count: needing.count, color: PixelTone.needs.text)
                    ForEach(needing) { bot in row(bot, state: .needs, line: line(bot), button: buttonTitle(bot)) }
                }
                if !failed.isEmpty {
                    heading("Failed", count: failed.count, color: PixelTone.failed.text)
                    ForEach(failed) { bot in row(bot, state: .failed, line: bot.lastFailure?.firstSentence ?? "It stopped", button: "Fix") }
                }
                if !working.isEmpty {
                    Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1).padding(.vertical, 2)
                    ForEach(working.prefix(3)) { bot in row(bot, state: store.pixelState(of: bot).state, line: store.liveStatus(of: bot), button: nil) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface))
        }
    }

    private func line(_ bot: NativeBot) -> String {
        if let connector = health.blockingConnector(of: bot.id) { return "Sign in to \(connector.name)" }
        return store.liveStatus(of: bot).replacingOccurrences(of: "Needs you · ", with: "")
    }

    private func buttonTitle(_ bot: NativeBot) -> String {
        health.blockingConnector(of: bot.id) != nil ? "Sign in" : "Open"
    }

    private func heading(_ title: String, count: Int, color: Color) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Text("\(count)").font(.system(size: 12, weight: .semibold)).foregroundColor(color)
        }
    }

    private func row(_ bot: NativeBot, state: PixelState, line: String, button: String?) -> some View {
        HStack(spacing: 10) {
            CrewAvatar(look: bot.crewLook, size: 30, pose: state, interactive: false, name: bot.name, ring: DS.Colors.surface)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                Text(line).font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let button {
                Button(button) { act(bot, button: button) }
                    .buttonStyle(.theo(button == "Sign in" ? .primary : .secondary, .small))
            }
        }
    }

    private func act(_ bot: NativeBot, button: String) {
        if button == "Sign in", let connector = health.blockingConnector(of: bot.id) {
            Task { _ = await health.signIn(connector, forBot: bot) }
            return
        }
        close()
        if let manager = CompanionManager.current { TheoHomeWindowController.show(companionManager: manager) }
        NotificationCenter.default.post(name: .theoOpenBot, object: bot.id)
    }
}
