//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Theo's entry point. `--mcp` runs only the MCP server (for T3 Code's agents);
//  otherwise TheoAppDelegate brings up the menu-bar spark, the pill, the spark
//  overlay, the local control channels, and Theo's own window or Setup guide.
//

import ClickyCore
import ServiceManagement
import SwiftUI

@main
struct TheoApp: App {
    @NSApplicationDelegateAdaptor(TheoAppDelegate.self) private var delegate

    init() {
        TheoProfile.prepareAtLaunch()
        // AppKit and SwiftUI each add these to the Edit menu; the text fields still have them on right click.
        UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
        UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
        if CommandLine.arguments.contains("--mcp") { ClaudiaMCPServer.runForever() }
        // A moment's helper: hands the owner's focus back when the running app is refused (BackgroundInput).
        if let flag = CommandLine.arguments.firstIndex(of: "--bring-forward"), CommandLine.arguments.count > flag + 1,
           let processIdentifier = pid_t(CommandLine.arguments[flag + 1]) {
            NSRunningApplication(processIdentifier: processIdentifier)?.activate(options: [])
            exit(0)
        }
    }

    var body: some Scene {
        // Windows are made by the delegate; SwiftUI only needs a scene to exist.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { TheoSettingsWindowController.show() }
                    .keyboardShortcut(",", modifiers: .command)
                }
                // Nothing to show or hide from a View menu: the sidebar has its own place.
                CommandGroup(replacing: .sidebar) {}
                CommandGroup(replacing: .toolbar) {}
            }
    }
}

@MainActor
final class TheoAppDelegate: NSObject, NSApplicationDelegate {
    /// For the app menu's Settings… command.
    static var sharedCompanionManager: CompanionManager?

    private let companionManager = CompanionManager()
    private var menuBar: MenuBarPanelManager?
    private var pill: NotchPanelController?
    private var controlInbox: ClaudiaControlInbox?
    private var uiServer: ClaudiaUIServer?
    private var debugCommandInbox: DebugCommandInbox?

    /// Unit tests host the app; then nothing starts (no overlay, mic, event tap or servers).
    static var isHostingUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Started with `--background` (an update, a reinstall): the window opens behind whatever the owner is doing.
    static var launchedInBackground: Bool { CommandLine.arguments.contains("--background") }

    /// `--tab=bots` (or another home tab) opens the home window on that tab.
    static var launchTab: TheoHomeView.Tab? {
        CommandLine.arguments.first { $0.hasPrefix("--tab=") }.flatMap { TheoHomeView.Tab(rawValue: String($0.dropFirst(6))) }
    }

    /// Opened from Finder, Theo's console lines (barge-ins, voice errors, cut segments) went nowhere, so a
    /// cut-off answer left no trace. They go to ~/Library/Logs/Clicky/theo.log, started fresh past 20 MB.
    private static func keepConsoleLog() {
        // A closed pipe (a helper process that quit) must not take the app down with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        // Only when opened from Finder: a terminal, Xcode's console or a pipe keeps its own output.
        guard isatty(STDOUT_FILENO) == 0, ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] == nil,
              ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"].map({ $0.hasPrefix("application.") }) ?? true else { return }
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/theo.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? Int, size > 20_000_000 {
            try? FileManager.default.removeItem(at: log)
        }
        guard freopen(log.path, "a", stdout) != nil else { return }
        freopen(log.path, "a", stderr)
        // It holds what was said to Theo: readable by the owner only.
        chmod(log.path, 0o600)
        setvbuf(stdout, nil, _IOLBF, 0)
        print("—— Theo started \(Date()) ——")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PrismClient.warm()
        if Self.isHostingUnitTests { return }
        TheoFirstClick.install()
        Self.keepConsoleLog()
        CompanionManager.current = companionManager
        // The harnesses' PATH comes from a login shell; read it once now, off the main thread.
        Task.detached(priority: .utility) { _ = HarnessCatalog.loginShellPath }
        Task { @MainActor in HarnessCenter.shared.refresh() }
        // Started from a shell, Theo inherits its folder (PWD), and the command-line tools it runs
        // (Claude Code, OpenCode, helpers) then work there. A shell in Downloads or Documents means
        // a privacy prompt in Theo's name, so they always start from home instead.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        FileManager.default.changeCurrentDirectoryPath(home)
        setenv("PWD", home, 1)
        unsetenv("OLDPWD")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        print("✨ Theo \(version) starting")

        Self.sharedCompanionManager = companionManager
        menuBar = MenuBarPanelManager(companionManager: companionManager)
        // The test profile is only the windows: no mic, key tap, spark overlay or pill alongside the real Theo.
        if !TheoProfile.isTest {
            companionManager.start()
            pill = NotchPanelController(companionManager: companionManager)
            pill?.start()
        }
        // The test tools' way in, only when asked for (it can run answers and actions).
        var startsDebugInbox = CommandLine.arguments.contains("--debug-inbox")
        #if DEBUG
        startsDebugInbox = true
        #endif
        if startsDebugInbox {
            debugCommandInbox = DebugCommandInbox(companionManager: companionManager)
            debugCommandInbox?.start()
        }

        // T3 Code talks to the running Theo through the control inbox (MCP) and the local page server.
        let inbox = ClaudiaControlInbox(companionManager: companionManager)
        inbox.start()
        controlInbox = inbox
        // Theo's local API for scripts on this Mac, only when the owner turned it on.
        TheoGateway.shared.apply()
        TheoHooks.fire(.appStarted, ["bots": BotsStore.shared.bots.count, "profile": TheoProfile.isTest ? "test" : "real"])
        if !TheoProfile.isTest || ClaudiaUIServer.port != 0 {
            uiServer = ClaudiaUIServer(controlInbox: inbox, companionManager: companionManager)
            uiServer?.start()
        }
        if !TheoProfile.isTest { openAtLogin() }

        // The hidden screens come up when a bot first needs one. Making them moves a monitor, so not on every launch.

        // A Dock app with its own window, unless that's turned off in Settings.
        NSApp.setActivationPolicy(ClickySettings.showsInDock && !TheoProfile.isTest ? .regular : .accessory)
        if SetupGuideWindowController.isNeededAtLaunch {
            SetupGuideWindowController.show(companionManager: companionManager, activates: !Self.launchedInBackground)
        } else if ClickySettings.showsInDock || Self.launchTab != nil || TheoProfile.isTest {
            TheoHomeWindowController.show(companionManager: companionManager, tab: Self.launchTab ?? .home, activates: !Self.launchedInBackground)
        }
        if !companionManager.allPermissionsGranted && !TheoProfile.isTest && !Self.launchedInBackground { menuBar?.showPanelOnLaunch() }
        BotsSnapshot.renderIfAsked()
        // `--bot-say=<bot id>:<message>` opens that bot's chat and sends the message (a quick check of
        // a bot from Terminal).
        if let say = CommandLine.arguments.first(where: { $0.hasPrefix("--bot-say=") }) {
            let value = String(say.dropFirst("--bot-say=".count))
            if let colon = value.firstIndex(of: ":") {
                let botID = String(value[..<colon])
                BotsSelection.shared.pane = botID == BotsStore.teamID ? .team : .bot(botID)
                TheoHomeWindowController.show(companionManager: companionManager, tab: .bots)
                let text = String(value[value.index(after: colon)...])
                if botID == BotsStore.teamID { BotsStore.shared.sendToTeam(text) } else { BotsStore.shared.send(text, to: botID) }
            }
        }
    }

    /// Clicking the Dock icon (or opening Theo again) brings back its window, or the guide if setup isn't done.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Self.isHostingUnitTests { return false }
        if ClickySettings.isSetupCompleted {
            TheoHomeWindowController.show(companionManager: companionManager)
        } else {
            SetupGuideWindowController.show(companionManager: companionManager)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        StudioController.shared.shutDown()
        if Self.isHostingUnitTests { return }
        pill?.stop()
        companionManager.stop()
    }

    /// Starts Theo at login (listed under System Settings › General › Login Items, where it can be turned off).
    private func openAtLogin() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do { try service.register() } catch { print("⚠️ Theo couldn't add itself to Login Items: \(error)") }
    }
}
