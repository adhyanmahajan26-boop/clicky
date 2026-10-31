//
//  BotsSnapshot.swift
//  leanring-buddy
//
//  `--render-bots=<folder>` draws the Bots screens into PNGs offscreen (the
//  Project room, Theo's chat, Connectors), for checking the layout without
//  capturing the screen. Nothing is shown and nothing on screen is read.
//

import AppKit
import SwiftUI

@MainActor
enum BotsSnapshot {
    static func renderIfAsked() {
        guard let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--render-bots=") }) else { return }
        let folder = URL(fileURLWithPath: (String(flag.dropFirst("--render-bots=".count)) as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = BotsStore.shared
        var panes: [(String, BotsPane)] = [("room", .team), ("connectors", .connectors), ("clicky", .clicky), ("routines", .routines)]
        for group in store.groups where group.id != BotGroup.projectID && group.headID != nil { panes.append(("group-\(group.id)", .group(group.id))) }
        if let theo = store.primary { panes.append(("theo", .bot(theo.id))) }
        Task {
            // The home window's tabs too, at the same size.
            if let manager = CompanionManager.current {
                for tab in TheoHomeView.Tab.shown where tab != .bots {
                    await render(TheoHomeView(companionManager: manager, initialTab: tab), to: folder.appendingPathComponent("home-\(tab.rawValue).png"))
                }
            }
            for (name, pane) in panes {
                let selection = BotsSelection()
                selection.pane = pane
                let host = NSHostingView(rootView: BotsRootView(store: store, selection: selection).frame(width: 1280, height: 820))
                host.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                host.layoutSubtreeIfNeeded()
                // Let the chat scroll to its end and animations settle.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
                window.contentView = nil
            }
            print("🖼️ Bots screens rendered to \(folder.path)")
        }
    }

    private static func render<Content: View>(_ view: Content, to file: URL) async {
        let host = NSHostingView(rootView: view.frame(width: 1280, height: 820))
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        window.contentView = nil
    }
}
