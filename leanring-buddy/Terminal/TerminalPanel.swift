//
//  TerminalPanel.swift
//  leanring-buddy
//
//  Hosts a TerminalSession's live terminal view in SwiftUI, and pops it out into its own window. The same
//  NSView is reparented between hosts, so the pop-out shows the running session, not a copy.
//

import AppKit
import SwiftTerm
import SwiftUI

/// A terminal view host that gives the session's view the whole bounds.
final class TerminalHostView: NSView {
    override var isFlipped: Bool { true }

    func adopt(_ terminal: NSView) {
        guard terminal.superview !== self else { return }
        terminal.removeFromSuperview()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
    }
}

struct TerminalPanel: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(hex: 0x0E0E10, alpha: 1).cgColor
        host.adopt(session.view)
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        // Only take the view back when no other host (the pop-out window) has it.
        if session.view.superview == nil { host.adopt(session.view) }
    }

    static func dismantleNSView(_ host: TerminalHostView, coordinator: ()) {
        // Leave the view with its session; the next host adopts it.
        for sub in host.subviews where sub is LocalProcessTerminalView { sub.removeFromSuperview() }
    }
}

/// The pop-out window around a session's terminal.
@MainActor
enum TerminalWindowController {
    private static var windows: [String: NSWindow] = [:]

    /// Shows the live session in its own window (bringing an existing one forward).
    static func pop(sessionID: String) {
        guard let session = TerminalSessions.shared.session(for: sessionID) else { return }
        if let existing = windows[sessionID] {
            (existing.contentView as? TerminalHostView)?.adopt(session.view)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(hex: 0x0E0E10, alpha: 1).cgColor
        host.adopt(session.view)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = session.title
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(hex: 0x0E0E10, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        windows[sessionID] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                windows[sessionID] = nil
                host.subviews.forEach { $0.removeFromSuperview() }
            }
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(session.view)
        NSApp.activate(ignoringOtherApps: true)
    }
}
