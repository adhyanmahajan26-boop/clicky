//
//  NotchVisibility.swift
//  ClickyCore
//
//  When the notch pill is shown, and the hover state machine that expands
//  and collapses it.
//
//  Full screen: a full-screen app (its own Space, or a borderless window
//  like a game or a video player) has an ordinary layer-0 window that covers
//  its whole display, menu bar strip included; a zoomed or maximised window
//  never does, because it stops below the menu bar. The app reads the
//  on-screen window list (CGWindowListCopyWindowInfo: bounds, layer and
//  owner pid need no extra permission) and asks `isFullScreenAppCovering`.
//

import CoreGraphics
import Foundation

public enum NotchFullScreenPolicy {
    /// Bounds within this many points of the display count as covering it.
    static let coverageTolerance: CGFloat = 1

    /// True when the display is covered by a full-screen window: the topmost
    /// app window (layer 0) on that display covers it, or the frontmost app
    /// has a layer-0 window covering it (a picture-in-picture or other small
    /// window of the same app on top doesn't change that). `windows` are
    /// front to back without Clicky's own (WindowStack.windows).
    /// Apps whose full-screen windows hide the pill: browsers and video players (a show or a film).
    /// A full-screen editor or chat app (the owner keeps Claude full screen) keeps the pill.
    public static let mediaOwnerNames: Set<String> = [
        "Safari", "Google Chrome", "Chrome", "Arc", "Firefox", "Brave Browser", "Microsoft Edge", "Opera", "Orion",
        "QuickTime Player", "TV", "IINA", "VLC", "Infuse", "Plex", "Netflix", "YouTube", "Prime Video", "Disney+", "Music"
    ]

    public static func isFullScreenAppCovering(displayBoundsCG: CGRect, windows: [WindowInfo], frontmostProcessIdentifier: pid_t?,
                                               onlyOwners: Set<String>? = mediaOwnerNames) -> Bool {
        let appWindowsOnDisplay = windows.filter { window in
            window.layer == 0 && window.alpha > 0.01 && window.boundsCG.intersection(displayBoundsCG).area > 0
        }.filter { window in onlyOwners.map { $0.contains(window.ownerName) } ?? true }
        if let topmostWindow = appWindowsOnDisplay.first, covers(topmostWindow.boundsCG, displayBoundsCG) {
            return true
        }
        guard let frontmostProcessIdentifier else { return false }
        return appWindowsOnDisplay.contains { $0.processIdentifier == frontmostProcessIdentifier && covers($0.boundsCG, displayBoundsCG) }
    }

    static func covers(_ windowBounds: CGRect, _ displayBounds: CGRect) -> Bool {
        windowBounds.minX <= displayBounds.minX + coverageTolerance
            && windowBounds.minY <= displayBounds.minY + coverageTolerance
            && windowBounds.maxX >= displayBounds.maxX - coverageTolerance
            && windowBounds.maxY >= displayBounds.maxY - coverageTolerance
    }

    /// The pill is shown when it's turned on, and (with hide-over-full-screen
    /// on, the default) no full-screen app covers its display.
    public static func shouldShowNotch(isEnabled: Bool, hidesOverFullScreen: Bool, isFullScreenAppCovering: Bool) -> Bool {
        guard isEnabled else { return false }
        return !(hidesOverFullScreen && isFullScreenAppCovering)
    }
}

/// Collapsed ⇄ expanded. The pointer entering the pill (or a click on it)
/// expands it at once; leaving it starts a 0.4 s grace, and the pill
/// collapses only if the pointer is still outside when the grace is over.
/// Time comes from the injected clock (seconds, monotonic), so tests never sleep.
public struct NotchPresentationStateMachine {
    public enum Presentation: Equatable, Sendable {
        case collapsed
        case expanded
    }

    public static let collapseGraceSeconds: TimeInterval = 0.4

    public private(set) var presentation: Presentation = .collapsed
    public private(set) var isPointerInside = false
    /// When the pointer left the expanded pill (nil while it's inside or collapsed).
    public private(set) var pointerLeftAt: TimeInterval?
    private let clock: () -> TimeInterval

    public init(clock: @escaping () -> TimeInterval) {
        self.clock = clock
    }

    public var isExpanded: Bool { presentation == .expanded }

    /// When `update()` should run next to collapse the pill (nil: nothing pending).
    public var collapseDeadline: TimeInterval? {
        pointerLeftAt.map { $0 + Self.collapseGraceSeconds }
    }

    /// The pointer moved onto the pill: expand, and forget any pending collapse.
    public mutating func pointerEntered() {
        isPointerInside = true
        pointerLeftAt = nil
        presentation = .expanded
    }

    /// The pointer left the pill: the grace starts now.
    public mutating func pointerExited() {
        guard isPointerInside || pointerLeftAt == nil else { return }
        isPointerInside = false
        if presentation == .expanded { pointerLeftAt = clock() }
    }

    /// A click on the pill expands it (the same as hovering).
    public mutating func clicked() {
        presentation = .expanded
        if !isPointerInside && pointerLeftAt == nil { pointerLeftAt = clock() }
    }

    /// Collapses once the grace is over with the pointer still outside.
    /// Returns true when the presentation changed.
    @discardableResult
    public mutating func update() -> Bool {
        guard presentation == .expanded, !isPointerInside, let pointerLeftAt else { return false }
        // A hair of tolerance so 0.39 s + 0.01 s of clock arithmetic counts as the full grace.
        guard clock() - pointerLeftAt >= Self.collapseGraceSeconds - 1e-9 else { return false }
        presentation = .collapsed
        self.pointerLeftAt = nil
        return true
    }

    /// The pill was hidden (full screen, turned off, moved displays): collapsed, nothing pending.
    public mutating func reset() {
        presentation = .collapsed
        isPointerInside = false
        pointerLeftAt = nil
    }
}
