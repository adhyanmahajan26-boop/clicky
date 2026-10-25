//
//  CompanionSparkClickTarget.swift
//  leanring-buddy
//
//  Makes the companion spark (and its orbiting helper minis) clickable to
//  open the Agents dashboard without changing click-through anywhere else.
//  The overlay windows still ignore every mouse event; instead a tiny
//  borderless, non-activating panel sits exactly over the spark, and only
//  while the spark is holding still.
//
//  The spark normally follows the pointer at a fixed offset, so the pointer
//  could never reach it. Once the pointer has rested for a moment the spark
//  holds its place until the pointer moves more than `holdRadius` away from
//  where it rested, which leaves room to move onto it and click. Turned off
//  with v2.agents.sparkClickOpensDashboard.
//

import AppKit
import ClickyCore

@MainActor
final class CompanionSparkClickTarget {
    /// A real click on the spark (opens the dashboard).
    var onClick: (() -> Void)?

    /// How long the pointer must rest before the spark holds still.
    static let restSecondsBeforeHolding: TimeInterval = 0.6
    /// The spark sits about 43 pt from the pointer; leaving this radius
    /// around the resting point lets it follow again.
    static let holdRadius: CGFloat = 72
    /// The clickable square over the spark (covers the orbiting minis too).
    static let hitSquareSide: CGFloat = 46
    /// Pointer movement below this (per tick) doesn't count as moving.
    static let movementThreshold: CGFloat = 1.5
    /// The spark's visible radius: the panel takes clicks only while the pointer has rested this
    /// close to the spark's centre for `restSecondsBeforeHolding`; otherwise it is click-through.
    static let visibleSparkRadius: CGFloat = 16

    private var lastMouseLocation: CGPoint?
    private var lastMovementDate = Date()
    private var restingPointerLocation: CGPoint?
    private var heldSparkCenter: CGPoint?
    private var clickPanel: SparkClickPanel?
    private var isEnabledCache = ClickySettings.isAgentsSparkClickEnabled
    private var isEnabledCheckedAt = Date.distantPast
    private var fullScreenMediaCache = false
    private var fullScreenMediaCheckedAt = Date.distantPast

    /// Called every tick by the overlay of the screen the pointer is on,
    /// while the spark follows the pointer. Coordinates are global AppKit
    /// points. Returns where the spark should stay while it holds still, or
    /// nil to follow the pointer as usual.
    func sparkCenterWhileHolding(mouseLocation: CGPoint, followingSparkCenter: CGPoint, now: Date = Date()) -> CGPoint? {
        guard isEnabled(now: now) else {
            reset()
            return nil
        }
        if let lastMouseLocation, hypot(mouseLocation.x - lastMouseLocation.x, mouseLocation.y - lastMouseLocation.y) > Self.movementThreshold {
            lastMovementDate = now
        }
        lastMouseLocation = mouseLocation

        if let restingPointerLocation, let heldSparkCenter {
            if hypot(mouseLocation.x - restingPointerLocation.x, mouseLocation.y - restingPointerLocation.y) > Self.holdRadius {
                reset()
                return nil
            }
            // Click-through unless the pointer has rested on the spark itself.
            let isOnSpark = hypot(mouseLocation.x - heldSparkCenter.x, mouseLocation.y - heldSparkCenter.y) <= Self.visibleSparkRadius
            clickPanel?.ignoresMouseEvents = !(isOnSpark && now.timeIntervalSince(lastMovementDate) >= Self.restSecondsBeforeHolding)
            return heldSparkCenter
        }
        guard now.timeIntervalSince(lastMovementDate) >= Self.restSecondsBeforeHolding else { return nil }
        // Never over a full-screen browser or video player (the same rule as the notch): a show plays there.
        guard !isFullScreenMediaUnderPointer(mouseLocation, now: now) else { return nil }
        restingPointerLocation = mouseLocation
        heldSparkCenter = followingSparkCenter
        showClickPanel(centeredAt: followingSparkCenter)
        return followingSparkCenter
    }

    /// The spark isn't following the pointer (flying, pointing, listening,
    /// hidden): nothing to click, and the hold starts over.
    func reset() {
        restingPointerLocation = nil
        heldSparkCenter = nil
        clickPanel?.orderOut(nil)
    }

    /// Whether a full-screen browser / video player covers the pointer's display (re-checked at most once a second).
    private func isFullScreenMediaUnderPointer(_ mouseLocation: CGPoint, now: Date) -> Bool {
        guard now.timeIntervalSince(fullScreenMediaCheckedAt) > 1 else { return fullScreenMediaCache }
        fullScreenMediaCheckedAt = now
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }),
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            fullScreenMediaCache = false
            return false
        }
        let windowStack = WindowListReader.read(displays: ScreenTopology.current())
        fullScreenMediaCache = NotchFullScreenPolicy.isFullScreenAppCovering(
            displayBoundsCG: CGDisplayBounds(displayNumber.uint32Value), windows: windowStack.windows,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        return fullScreenMediaCache
    }

    /// The setting is re-read at most once a second (this runs at 60 Hz).
    private func isEnabled(now: Date) -> Bool {
        if now.timeIntervalSince(isEnabledCheckedAt) > 1 {
            isEnabledCache = ClickySettings.isAgentsSparkClickEnabled
            isEnabledCheckedAt = now
        }
        return isEnabledCache
    }

    private func showClickPanel(centeredAt sparkCenter: CGPoint) {
        let panel = clickPanel ?? makeClickPanel()
        clickPanel = panel
        let side = Self.hitSquareSide
        panel.setFrame(NSRect(x: sparkCenter.x - side / 2, y: sparkCenter.y - side / 2, width: side, height: side), display: false)
        panel.ignoresMouseEvents = true  // until the pointer rests on the spark
        // Ordered front without activating Clicky or taking key focus.
        panel.orderFrontRegardless()
    }

    private func makeClickPanel() -> SparkClickPanel {
        let panel = SparkClickPanel(contentRect: NSRect(x: 0, y: 0, width: Self.hitSquareSide, height: Self.hitSquareSide),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        // Click-through by default; it takes clicks only while the pointer rests on the spark.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let clickView = SparkClickView(frame: NSRect(x: 0, y: 0, width: Self.hitSquareSide, height: Self.hitSquareSide))
        clickView.onClick = { [weak self] in self?.onClick?() }
        panel.contentView = clickView
        return panel
    }
}

/// Never key or main: a click on it changes nobody's focus by itself.
private final class SparkClickPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Transparent; a pointing hand on hover; a left click calls `onClick`.
private final class SparkClickView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Almost invisible, so the window server always delivers the click here.
        NSColor(white: 0, alpha: 0.002).setFill()
        bounds.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
