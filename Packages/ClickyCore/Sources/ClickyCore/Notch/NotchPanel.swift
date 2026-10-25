//
//  NotchPanel.swift
//  ClickyCore
//
//  The notch pill's window: a borderless, non-activating panel that can
//  never become key or main, so hovering or clicking it never takes focus
//  from whatever the user is in (the hover tracking area is .activeAlways
//  and needs no key status). It sits just above the menu bar, on every
//  Space, out of Cmd-` cycling and Mission Control. It joins full-screen
//  Spaces only when v2.notch.hideOverFullscreen is off.
//

#if canImport(AppKit)
import AppKit

public final class NotchPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Just above the menu bar (mainMenu is 24, statusBar 25), below the
    /// cursor overlay (screenSaver) so the companion spark still draws over it.
    public static let windowLevel = NSWindow.Level.statusBar

    public static func collectionBehavior(showsOverFullScreenApps: Bool) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if showsOverFullScreenApps { behavior.insert(.fullScreenAuxiliary) }
        return behavior
    }

    /// A configured panel; nothing is ordered on screen here.
    @MainActor
    public static func make(contentRect: CGRect, showsOverFullScreenApps: Bool) -> NotchPanel {
        let panel = NotchPanel(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = windowLevel
        panel.collectionBehavior = collectionBehavior(showsOverFullScreenApps: showsOverFullScreenApps)
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        return panel
    }
}
#endif
