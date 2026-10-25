//
//  TypeForMeEvents.swift
//  ClickyCore
//
//  The event plumbing of "Type this for me". Real NSEvents on the card map
//  to TypeConfirmInput (Return and keypad Enter keyDown/keyUp with their
//  auto-repeat flag, mouse down/up on the Type button, and the CGEvent's
//  eventSourceUserData so Clicky's own events never confirm). The events
//  Clicky posts to insert text — ⌘V with flags exactly [.maskCommand], and
//  unicode-string key events with no flags — are made here, each stamped
//  with SyntheticEventTag through SyntheticEvents. Return/Enter is never
//  synthesized.
//

import AppKit
import CoreGraphics
import Foundation

public enum TypeConfirmEventMapping {
    static let returnKeyCodes: Set<UInt16> = [36, 76]
    public static let escapeKeyCode: UInt16 = 53

    public static func isReturnKey(_ event: NSEvent) -> Bool {
        (event.type == .keyDown || event.type == .keyUp) && returnKeyCodes.contains(event.keyCode)
    }

    /// nil for anything that isn't a Return key event or a Type-button mouse event.
    public static func confirmInput(from event: NSEvent, isOnTypeButton: Bool = false) -> TypeConfirmInput? {
        let kind: TypeConfirmInput.Kind
        switch event.type {
        case .keyDown where returnKeyCodes.contains(event.keyCode): kind = .returnKeyDown(isRepeat: event.isARepeat)
        case .keyUp where returnKeyCodes.contains(event.keyCode): kind = .returnKeyUp
        case .leftMouseDown: kind = .mouseDown(isOnTypeButton: isOnTypeButton)
        case .leftMouseUp: kind = .mouseUp(isOnTypeButton: isOnTypeButton)
        default: return nil
        }
        return TypeConfirmInput(kind: kind, timestamp: event.timestamp, eventSourceUserData: GateEventMapping.eventSourceUserData(of: event))
    }

    /// Physical input that aborts an insertion in progress (Clicky's own tagged events don't).
    public static func isPhysicalInterruption(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            return !SyntheticEventTag.isTagged(userData: GateEventMapping.eventSourceUserData(of: event))
        default:
            return false
        }
    }
}

public enum TypeForMeSyntheticEvents {
    /// kVK_ANSI_V.
    static let virtualKeyV: CGKeyCode = 9

    /// ⌘V down and up, flags exactly [.maskCommand], tagged.
    public static func commandVEvents() -> [CGEvent] {
        [true, false].compactMap { isKeyDown in
            guard let event = SyntheticEvents.keyEvent(virtualKey: virtualKeyV, keyDown: isKeyDown) else { return nil }
            event.flags = .maskCommand
            return event
        }
    }

    /// One chunk (≤ 20 UTF-16 units, whole Characters) as a key down/up
    /// pair with no modifier flags, tagged.
    public static func unicodeEvents(for chunk: String) -> [CGEvent] {
        let utf16Units = Array(chunk.utf16)
        guard !utf16Units.isEmpty, utf16Units.count <= TypeForMeText.maximumUTF16UnitsPerEvent else { return [] }
        return [true, false].compactMap { isKeyDown in
            guard let event = SyntheticEvents.keyEvent(virtualKey: 0, keyDown: isKeyDown) else { return nil }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            return event
        }
    }

    /// No ⌃⌥⌘⇧ held.
    public static func areNoModifiersHeld(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty
    }
}
