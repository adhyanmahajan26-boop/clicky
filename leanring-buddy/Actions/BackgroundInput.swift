//
//  BackgroundInput.swift
//  leanring-buddy
//
//  Input that never touches the owner's pointer or keyboard focus. When Theo has a
//  screen of its own, its actions go through here: AX actions first, then events
//  posted straight to the target process (CGEventPostToPid), which neither warps
//  the real cursor nor needs the app to be frontmost. Every event is made through
//  SyntheticEvents, so the physical-input monitor ignores it.
//
//  The old HID paths stay available behind the opt-in setting
//  "v2.actions.useRealPointer" (default off).
//

import AppKit
import ApplicationServices
import ClickyCore

@MainActor
enum BackgroundInput {
    /// The app Theo last opened or acted in. A key or scroll step with no element of its own goes there,
    /// never to whatever app the owner is using.
    nonisolated(unsafe) static var lastTheoApp: pid_t?

    /// `lastTheoApp` when it's still running, else the fallback.
    static func theoTarget(else fallback: pid_t?) -> pid_t? {
        if let pid = lastTheoApp, NSRunningApplication(processIdentifier: pid)?.isTerminated == false { return pid }
        return fallback
    }

    static let useRealPointerKey = "v2.actions.useRealPointer"

    /// The opt-in escape hatch: act with the real pointer / keyboard focus, as before.
    static var useRealPointer: Bool { UserDefaults.standard.bool(forKey: useRealPointerKey) }

    /// True when actions must stay off the owner's pointer and focus: Theo has a screen and the escape hatch is off.
    static var isActive: Bool { ClaudiaScreen.picked != nil && !useRealPointer }

    // MARK: Elements

    static let pressActionNames: [String] = [kAXPressAction as String, "AXOpen", "AXPick", kAXConfirmAction as String]

    /// The element under a point (Core Graphics coordinates), system-wide. Does not move anything.
    static func element(atCG point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success else { return nil }
        return hit
    }

    static func processIdentifier(of element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success, processIdentifier > 0 else { return nil }
        return processIdentifier
    }

    static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    /// AXPress / AXOpen / AXPick / AXConfirm on the element at the point, or the nearest ancestor that supports one.
    /// `expectedProcessIdentifier`: refuse when something else is covering the point.
    @discardableResult
    static func pressAt(_ point: CGPoint, expectedProcessIdentifier: pid_t? = nil) -> Bool {
        guard var current = element(atCG: point) else { return false }
        if let expectedProcessIdentifier, let hitProcessIdentifier = processIdentifier(of: current), hitProcessIdentifier != expectedProcessIdentifier { return false }
        for _ in 0..<8 {
            let names = ActionExecutor.actionNames(of: current)
            if let name = pressActionNames.first(where: names.contains),
               AXUIElementPerformAction(current, name as CFString) == .success {
                lastTheoApp = processIdentifier(of: current) ?? lastTheoApp
                return true
            }
            guard let next = parent(of: current) else { return false }
            current = next
        }
        return false
    }

    // MARK: Pointer events (to a process, no warp)

    /// A left click delivered to the process at a point. The real cursor stays where it is.
    static func postClick(processIdentifier: pid_t, at point: CGPoint) {
        lastTheoApp = processIdentifier
        for (type, clickState) in [(CGEventType.mouseMoved, 0), (.leftMouseDown, 1), (.leftMouseUp, 1)] {
            guard let event = SyntheticEvents.mouseEvent(type, at: point) else { continue }
            if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
            event.postToPid(processIdentifier)
        }
    }

    // MARK: Keys (to a process)

    static func keyFlags(for combo: ActionKeyCombo) -> CGEventFlags {
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    static func postKey(processIdentifier: pid_t, combo: ActionKeyCombo) {
        let flags = keyFlags(for: combo)
        for isKeyDown in [true, false] {
            guard let event = SyntheticEvents.keyEvent(virtualKey: CGKeyCode(combo.virtualKeyCode), keyDown: isKeyDown) else { continue }
            event.flags = flags
            event.postToPid(processIdentifier)
        }
    }

    /// Unicode text as key events to the process, in short chunks. False when the text can't be typed this way.
    @discardableResult
    static func typeUnicode(processIdentifier: pid_t, text: String, isCancelled: () -> Bool = { false }) async -> Bool {
        lastTheoApp = processIdentifier
        guard let chunks = UnicodeTypingChunker.chunks(of: text) else { return false }
        for chunk in chunks {
            if isCancelled() { return true }
            for event in TypeForMeSyntheticEvents.unicodeEvents(for: chunk) { event.postToPid(processIdentifier) }
            try? await Task.sleep(nanoseconds: ActionExecutor.delayBetweenUnicodeChunks)
        }
        return true
    }

    // MARK: Scrolling

    /// Scrolls whatever is under `point` in the process. `verticalLines` > 0 scrolls up (content moves down),
    /// `horizontalLines` > 0 scrolls left. Order: the scroll area's scroll bar (AXValue), then a pid-posted wheel event.
    /// Returns the method used.
    @discardableResult
    static func scroll(processIdentifier: pid_t, at point: CGPoint, verticalLines: Int32, horizontalLines: Int32 = 0) -> String? {
        if scrollBar(at: point, verticalLines: verticalLines, horizontalLines: horizontalLines, expectedProcessIdentifier: processIdentifier) { return "ax scroll bar" }
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line, wheelCount: 2,
                                  wheel1: verticalLines, wheel2: horizontalLines, wheel3: 0) else { return nil }
        SyntheticEvents.stamp(event)
        event.location = point
        event.postToPid(processIdentifier)
        return "pid scroll wheel"
    }

    /// A pixel scroll at a point for whichever process owns the window there (positive = further down the page).
    @discardableResult
    static func scroll(atCG point: CGPoint, pixels: Int) -> Bool {
        guard let hit = element(atCG: point), let owner = processIdentifier(of: hit),
              let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel, wheelCount: 1,
                                  wheel1: Int32(clamping: -pixels), wheel2: 0, wheel3: 0) else { return false }
        SyntheticEvents.stamp(event)
        event.location = point
        event.postToPid(owner)
        return true
    }

    /// Reveals an element in its scroll area (the right tool for "scroll to this").
    @discardableResult
    static func scrollToVisible(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, "AXScrollToVisible" as CFString) == .success
    }

    /// Moves the nearest scroll area's scroll bar. Roughly 6% of the track per three lines.
    private static func scrollBar(at point: CGPoint, verticalLines: Int32, horizontalLines: Int32,
                                  expectedProcessIdentifier: pid_t? = nil) -> Bool {
        guard var current = element(atCG: point) else { return false }
        // Something else covering the point (the owner's window) isn't scrolled.
        if let expectedProcessIdentifier, let hit = processIdentifier(of: current), hit != expectedProcessIdentifier { return false }
        for _ in 0..<12 {
            if TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: current) == "AXScrollArea" { break }
            guard let next = parent(of: current) else { return false }
            current = next
        }
        guard TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: current) == "AXScrollArea" else { return false }
        var moved = false
        for (attribute, lines, sign) in [("AXVerticalScrollBar", verticalLines, -1.0), ("AXHorizontalScrollBar", horizontalLines, -1.0)] where lines != 0 {
            var barValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, attribute as CFString, &barValue) == .success, let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID() else { continue }
            // swiftlint:disable:next force_cast
            let bar = barValue as! AXUIElement
            var valueObject: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &valueObject) == .success, let number = valueObject as? NSNumber else { continue }
            let newValue = min(1, max(0, number.doubleValue + sign * Double(lines) * 0.02))
            if AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: newValue)) == .success { moved = true }
        }
        return moved
    }

    // MARK: Keeping the owner's focus

    /// What was in front before Theo opened or touched something, so it can be put back.
    struct FrontmostSnapshot {
        let application: NSRunningApplication?
        static func capture() -> FrontmostSnapshot { FrontmostSnapshot(application: NSWorkspace.shared.frontmostApplication) }

        /// Puts the previous app back in front if `touchedProcessIdentifier` (the app Theo just opened) took the front.
        /// Checked a few times, since a fresh app or window can grab focus a moment after it appears.
        func restore(ifStolenBy touchedProcessIdentifiers: [pid_t]) {
            if let opened = touchedProcessIdentifiers.last { BackgroundInput.lastTheoApp = opened }
            guard let previous = application, !previous.isTerminated else { return }
            Task { @MainActor in
                for delay in [0.25, 0.6, 1.2, 2.4] as [Double] {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let current = NSWorkspace.shared.frontmostApplication, !previous.isTerminated else { return }
                    // The owner moved on to some other app themselves: leave it.
                    if current.processIdentifier != previous.processIdentifier && !touchedProcessIdentifiers.contains(current.processIdentifier) { return }
                    // The owner clicked or typed since: whatever is in front now is their choice.
                    if CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) < delay { return }
                    guard current.processIdentifier != previous.processIdentifier else { continue }
                    previous.activate(options: [])
                }
            }
        }
    }
}
