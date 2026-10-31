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
        if CommandLine.arguments.contains("--mcp") { ClaudiaMCPServer.runForever() }
    }

    var body: some Scene {
        // Windows are made by the delegate; SwiftUI only needs a scene to exist.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        guard let companionManager = TheoAppDelegate.sharedCompanionManager else { return }
                        TheoHomeWindowController.show(companionManager: companionManager, tab: .settings)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
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
    #if DEBUG
    private var debugCommandInbox: DebugCommandInbox?
    #endif

    /// Unit tests host the app; then nothing starts (no overlay, mic, event tap or servers).
    static var isHostingUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// `--tab=bots` (or another home tab) opens the home window on that tab.
    static var launchTab: TheoHomeView.Tab? {
        CommandLine.arguments.first { $0.hasPrefix("--tab=") }.flatMap { TheoHomeView.Tab(rawValue: String($0.dropFirst(6))) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isHostingUnitTests { return }
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
        companionManager.start()
        pill = NotchPanelController(companionManager: companionManager)
        pill?.start()
        #if DEBUG
        debugCommandInbox = DebugCommandInbox(companionManager: companionManager)
        debugCommandInbox?.start()
        #endif

        // T3 Code talks to the running Theo through the control inbox (MCP) and the local page server.
        let inbox = ClaudiaControlInbox(companionManager: companionManager)
        inbox.start()
        controlInbox = inbox
        uiServer = ClaudiaUIServer(controlInbox: inbox, companionManager: companionManager)
        uiServer?.start()

        openAtLogin()

        // A Dock app with its own window, unless that's turned off in Settings.
        NSApp.setActivationPolicy(ClickySettings.showsInDock ? .regular : .accessory)
        if SetupGuideWindowController.isNeededAtLaunch {
            SetupGuideWindowController.show(companionManager: companionManager)
        } else if ClickySettings.showsInDock || Self.launchTab != nil {
            TheoHomeWindowController.show(companionManager: companionManager, tab: Self.launchTab ?? .home)
        }
        if !companionManager.allPermissionsGranted { menuBar?.showPanelOnLaunch() }
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
