//
//  AgentsWindowController.swift
//  leanring-buddy
//
//  The "Agents" window: a normal titled, resizable NSWindow hosting
//  ClickyCore's AgentsDashboardView through an NSHostingController. It is
//  only ordered front when the user opens it (menu bar "Agents…", the
//  spark click, or "show agents" by voice); live updates just re-render
//  the SwiftUI view, never order, move or focus the window. Until the user
//  moves or resizes it, it opens centred on the display with the cursor;
//  after that the frame is remembered with a frame autosave name.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

/// The sidebar selection (kept while the window is closed).
@MainActor
final class AgentsSelectionModel: ObservableObject {
    @Published var selectedAgentID: String?
}

@MainActor
final class AgentsWindowController: NSObject, NSWindowDelegate {
    static let frameAutosaveName = "ClickyAgentsWindow"
    static let defaultContentSize = NSSize(width: 980, height: 640)

    private let agentsCenter: AgentsCenter
    private let actions: AgentsDashboardActions
    private let selection = AgentsSelectionModel()
    private var window: NSWindow?
    /// True while Clicky itself sets the frame (so it isn't taken as the user moving it).
    private var isPlacingWindow = false

    init(agentsCenter: AgentsCenter, actions: AgentsDashboardActions) {
        self.agentsCenter = agentsCenter
        self.actions = actions
    }

    var isVisible: Bool { window?.isVisible == true }

    /// AppKit stores an autosaved frame under this defaults key once the
    /// autosave name is set, which only happens after the user moved or
    /// resized the window.
    private static var hasUserPlacedWindow: Bool {
        UserDefaults.standard.object(forKey: "NSWindow Frame \(frameAutosaveName)") != nil
    }

    /// Shows the window for a user action. `activatesClicky` brings Clicky
    /// forward and makes the window key (a click); voice requests only order
    /// it front so whatever the user is typing in keeps focus.
    func show(selecting agentID: String? = nil, activatesClicky: Bool) {
        if let agentID { selection.selectedAgentID = agentID }
        let agentsWindow = window ?? makeWindow()
        window = agentsWindow
        if !agentsWindow.isVisible && !Self.hasUserPlacedWindow {
            centerOnCursorDisplay(agentsWindow)
        }
        if activatesClicky {
            NSApp.activate(ignoringOtherApps: true)
            agentsWindow.makeKeyAndOrderFront(nil)
        } else {
            agentsWindow.orderFrontRegardless()
        }
    }

    func close() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: AgentsDashboardHostView(agentsCenter: agentsCenter, selection: selection, actions: actions))
        // The window keeps the size the user gave it; SwiftUI never resizes it.
        hostingController.sizingOptions = []
        let agentsWindow = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
        agentsWindow.contentViewController = hostingController
        agentsWindow.title = "Agents"
        agentsWindow.isReleasedWhenClosed = false
        agentsWindow.hidesOnDeactivate = false
        agentsWindow.contentMinSize = NSSize(width: AgentsDashboardView.minimumSize.width, height: AgentsDashboardView.minimumSize.height)
        agentsWindow.collectionBehavior = [.fullScreenAuxiliary]
        agentsWindow.delegate = self
        isPlacingWindow = true
        agentsWindow.setContentSize(Self.defaultContentSize)
        if Self.hasUserPlacedWindow {
            // Restores the frame the user left it at.
            agentsWindow.setFrameAutosaveName(Self.frameAutosaveName)
        }
        isPlacingWindow = false
        return agentsWindow
    }

    /// Centred on the visible frame of the display the cursor is on.
    private func centerOnCursorDisplay(_ agentsWindow: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        guard let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.screens.first else { return }
        let visibleFrame = cursorScreen.visibleFrame
        var windowFrame = agentsWindow.frame
        windowFrame.size.width = min(windowFrame.width, visibleFrame.width)
        windowFrame.size.height = min(windowFrame.height, visibleFrame.height)
        windowFrame.origin = NSPoint(x: visibleFrame.midX - windowFrame.width / 2, y: visibleFrame.midY - windowFrame.height / 2)
        isPlacingWindow = true
        agentsWindow.setFrame(windowFrame, display: false)
        isPlacingWindow = false
    }

    // MARK: - NSWindowDelegate

    /// The user dragged it: from now on its frame is remembered.
    func windowDidMove(_ notification: Notification) {
        rememberFrameAfterUserPlacement()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberFrameAfterUserPlacement()
    }

    private func rememberFrameAfterUserPlacement() {
        guard !isPlacingWindow, let window, window.isVisible, window.frameAutosaveName.isEmpty else { return }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.saveFrame(usingName: Self.frameAutosaveName)
    }
}

/// Re-renders the dashboard on every store change and once a second for
/// the elapsed times. Only state changes here; the window is left alone.
private struct AgentsDashboardHostView: View {
    @ObservedObject var agentsCenter: AgentsCenter
    @ObservedObject var selection: AgentsSelectionModel
    let actions: AgentsDashboardActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timelineContext in
            AgentsDashboardView(store: agentsCenter.store, selectedAgentID: $selection.selectedAgentID, now: timelineContext.date, actions: actions)
        }
    }
}
