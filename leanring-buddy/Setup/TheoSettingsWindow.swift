//
//  TheoSettingsWindow.swift
//  leanring-buddy
//
//  Settings in a window of their own (⌘,), System Settings style: a list of
//  sections and grouped forms, out of the way of the chats.
//

import AppKit
import SwiftUI

@MainActor
enum TheoSettingsWindowController {
    private static var window: NSWindow?

    static func show(section: SettingsTab.Section = .look) {
        guard let manager = CompanionManager.current else { return }
        let content = SettingsTab(companionManager: manager, section: section)
            .frame(minWidth: 820, minHeight: 600)
            .background(DS.Colors.background)
            .preferredColorScheme(.dark)
        if let window {
            // Already open: just bring it forward, so a half-typed key isn't lost.
            _ = content
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        } else {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            created.title = "Settings"
            created.titlebarAppearsTransparent = true
            created.isReleasedWhenClosed = false
            created.contentView = FirstMouseHostingView(rootView: content)
            created.center()
            ClaudiaScreen.place(created)
            created.setFrameAutosaveName("TheoSettings")
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
