//
//  GateEventMapping.swift
//  ClickyCore
//
//  Turns a real NSEvent on a review-panel button into the GateInputEvent
//  ClickGateLogic decides on: its kind (mouse down/up, Return), timestamp,
//  window number, the CGEvent's eventSourceUserData (Clicky's own synthetic
//  events carry SyntheticEventTag there), whether the app is active and
//  whether the press lands on the button. Anything else is not a gate input.
//

import AppKit
import CoreGraphics
import Foundation

public enum GateEventMapping {
    /// Return and keypad Enter.
    static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// nil for events the gate never sees (moves, scrolls, other buttons).
    public static func gateInput(from event: NSEvent, panelShownAt: TimeInterval, isAppActive: Bool, isOnTargetButton: Bool) -> GateInputEvent? {
        let kind: GateInputEvent.Kind
        switch event.type {
        case .leftMouseDown: kind = .mouseDown
        case .leftMouseUp: kind = .mouseUp
        case .keyDown: kind = .keyDown(isReturnKey: returnKeyCodes.contains(event.keyCode))
        default: return nil
        }
        return GateInputEvent(kind: kind, timestamp: event.timestamp, windowNumber: event.windowNumber,
                              eventSourceUserData: eventSourceUserData(of: event), isAppActive: isAppActive,
                              panelShownAt: panelShownAt, isOnTargetButton: isOnTargetButton)
    }

    public static func eventSourceUserData(of event: NSEvent) -> Int64 {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
    }
}

/// The one place Clicky makes input events. Every CGEvent it creates is
/// stamped with SyntheticEventTag, so the click gate always refuses it.
/// (No feature posts events yet; anything that does must come through here.)
public enum SyntheticEvents {
    public static func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventTag.value)
    }

    public static func mouseEvent(_ type: CGEventType, at locationCG: CGPoint, button: CGMouseButton = .left) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: locationCG, mouseButton: button) else { return nil }
        stamp(event)
        return event
    }

    public static func keyEvent(virtualKey: CGKeyCode, keyDown: Bool) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: virtualKey, keyDown: keyDown) else { return nil }
        stamp(event)
        return event
    }
}
