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

struct TheoPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    let close: () -> Void
    @State private var speechAllowed = SFSpeechRecognizer.authorizationStatus() == .authorized
    private let ticker = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !companionManager.allPermissionsGranted || !speechAllowed { permissionsCard }
            brainRow
            switches
            Text("Hold \(PushToTalkKeys.displayText) to talk, or say “hey \(ClickySettings.assistantName)”.")
                .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
            Divider().overlay(DS.Colors.borderSubtle)
            buttons
        }
        .padding(16)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).fill(DS.Colors.background))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .onReceive(ticker) { _ in speechAllowed = SFSpeechRecognizer.authorizationStatus() == .authorized }
    }

    private var statusText: String {
        if companionManager.isHandsFreeSessionActive { return "Hands-free: listening" }
        switch companionManager.voiceState {
        case .listening: return "Listening…"
        case .processing: return "Thinking…"
        case .responding: return "Answering…"
        case .idle: return companionManager.isSilentModeEnabled ? "Ready (silent)" : "Ready"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 0.93, green: 0.27, blue: 0.45), Color(red: 0.75, green: 0.27, blue: 0.9)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(ClickySettings.assistantName).font(.system(size: 15, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
                HStack(spacing: 5) {
                    Circle().fill(companionManager.voiceState == .idle ? DS.Colors.success : DS.Colors.accent).frame(width: 6, height: 6)
                    Text(statusText).font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary)
                }
            }
            Spacer()
            iconButton("macwindow", "Open Theo") { close(); TheoHomeWindowController.show(companionManager: companionManager) }
            iconButton("gearshape", "Settings") { close(); TheoHomeWindowController.show(companionManager: companionManager, tab: .settings) }
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Theo still needs").font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.warning)
            permissionRow("Microphone", companionManager.hasMicrophonePermission) { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
            permissionRow("Speech recognition", speechAllowed) { SFSpeechRecognizer.requestAuthorization { _ in } }
            permissionRow("Accessibility", companionManager.hasAccessibilityPermission) { TheoPermissions.askForAccessibility() }
            permissionRow("Screen recording", companionManager.hasScreenRecordingPermission) { TheoPermissions.askForScreenRecording() }
            if !companionManager.hasScreenContentPermission {
                permissionRow("Screen content", false) { companionManager.requestScreenContentPermission() }
            }
            if TheoPermissions.askedForScreenRecordingThisLaunch && !companionManager.hasScreenRecordingPermission {
                Button("Allowed it? Restart Theo") { TheoPermissions.relaunch() }.font(.system(size: 11))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).fill(DS.Colors.warning.opacity(0.08)))
    }

    private func permissionRow(_ title: String, _ granted: Bool, ask: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundColor(granted ? DS.Colors.success : DS.Colors.textTertiary)
            Text(title).font(.system(size: 12)).foregroundColor(DS.Colors.textPrimary)
            Spacer()
            if !granted {
                Button("Allow", action: ask).font(.system(size: 11, weight: .semibold)).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }

    private var brainRow: some View {
        let brain = BrainModel(setting: ClickyModels.main).provider
        let isReady = brain == .claude ? companionManager.isClaudeCodeSignedIn : BrainCLIRunner.locateExecutable(for: brain) != nil
        return Button(action: {
            companionManager.refreshClaudeCodeSignInStatus()
            if !isReady { close(); SetupGuideWindowController.show(companionManager: companionManager, step: .brain) }
        }) {
            HStack(spacing: 10) {
                Image(systemName: "brain").foregroundColor(DS.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(brain.displayName).font(.system(size: 12.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text(isReady ? companionManager.selectedModel : "Not connected: open the Setup guide")
                        .font(.system(size: 11)).foregroundColor(isReady ? DS.Colors.textTertiary : DS.Colors.warning).lineLimit(1)
                }
                Spacer()
                Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(isReady ? DS.Colors.success : DS.Colors.warning)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).fill(DS.Colors.surface))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 8) {
            switchRow("Speak answers", Binding(get: { !companionManager.isSilentModeEnabled }, set: { companionManager.setSilentModeEnabled(!$0) }))
            switchRow("Show the spark by my pointer", Binding(get: { companionManager.isClickyCursorEnabled }, set: { companionManager.setClickyCursorEnabled($0) }))
            switchRow("Hands-free conversation", Binding(get: { companionManager.isHandsFreeSessionActive }, set: { _ in companionManager.toggleHandsFreeSession() }))
            WakeWordSettingsRow(wakeWordController: companionManager.wakeWordController)
            CodeModeSettingsRow(codeModeController: companionManager.codeModeController)
        }
        .font(.system(size: 12.5))
        .foregroundColor(DS.Colors.textPrimary)
    }

    private func switchRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            chip("Agents", "person.3") { companionManager.showAgentsDashboard(activatesClicky: true) }
            chip("Setup guide", "wand.and.stars") { close(); SetupGuideWindowController.show(companionManager: companionManager) }
            chip("Diagnostics", "stethoscope") { close(); DiagnosticsWindowController.show(companionManager: companionManager) }
            Spacer()
            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power").foregroundColor(DS.Colors.destructiveText)
            }
            .buttonStyle(.plain).help("Quit Theo").pointerCursor()
        }
    }

    private func chip(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(DS.Colors.surface))
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary)
                .frame(width: 28, height: 28).background(Circle().fill(DS.Colors.surface))
        }
        .buttonStyle(.plain).help(help).pointerCursor()
    }
}
