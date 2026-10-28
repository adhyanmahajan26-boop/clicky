//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    init() {
        // `--mcp`: Claudia's MCP server for T3 Code and its agents (no UI; talks to the running Claudia).
        if CommandLine.arguments.contains("--mcp") { ClaudiaMCPServer.runForever() }
    }

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    /// The pill at the top centre of the screen (v2.notch.*).
    private var notchPanelController: NotchPanelController?
    private let companionManager = CompanionManager()
    private var controlInbox: ClaudiaControlInbox?
    /// Claudia's UI page (T3 Code's Claudia section), on 127.0.0.1 only.
    private var uiServer: ClaudiaUIServer?
    #if DEBUG
    private var debugCommandInbox: DebugCommandInbox?
    #endif

    /// True when the app is only hosting unit tests. Then it must stay inert:
    /// no overlays, event tap, mic, voice server or debug inbox.
    static var isHostingUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingUnitTests else {
            print("🧪 Clicky: hosting unit tests, not starting the companion")
            return
        }

        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        notchPanelController = NotchPanelController(companionManager: companionManager)
        notchPanelController?.start()
        #if DEBUG
        debugCommandInbox = DebugCommandInbox(companionManager: companionManager)
        debugCommandInbox?.start()
        #endif
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // Claudia inside T3 Code: the `claudia` MCP server talks to this running app through the control inbox.
        controlInbox = ClaudiaControlInbox(companionManager: companionManager)
        controlInbox?.start()
        if let controlInbox {
            uiServer = ClaudiaUIServer(controlInbox: controlInbox, companionManager: companionManager)
            uiServer?.start()
        }
        if SetupWindowController.isNeededAtLaunch {
            showSetupWindow()
        }
    }

    /// Opening Clicky again while it runs (its menu-bar icon may be hidden
    /// behind the notch) brings back Setup and the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isHostingUnitTests else { return false }
        showSetupWindow()
        return false
    }

    private func showSetupWindow() {
        SetupWindowController.show(companionManager: companionManager) { [weak self] in
            self?.menuBarPanelManager?.showPanelOnLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isHostingUnitTests else { return }
        notchPanelController?.stop()
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }
}
