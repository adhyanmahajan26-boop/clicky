//
//  VelloHands.swift
//  leanring-buddy
//
//  Whether Vello can see and use the screen on a call. Vello's hands are the same machinery Pointer Assistant used
//  (the spark, the grounding, the step runner), so they're on when that product is on and actions are allowed, and
//  `[POINTER: on|off]` on a call switches them the way it used to switch Pointer Assistant.
//

import AppKit
import ClickyCore

@MainActor
enum VelloHands {
    /// On when the screen product is on, this Mac is the one that does screen work, and actions aren't switched off.
    static var isOn: Bool {
        TheoProducts.isOn(.clicky) && ClickySettings.isActionsEnabled && TheoLink.shared.clickyRunsHere
    }

    /// Badge numbers belong to the screen they were drawn on: after this long, steps that name them look again first.
    static let badgeNumbersLastSeconds: TimeInterval = 45

    /// `[POINTER: on|off]` from a call. On also brings the spark out, so pointing shows.
    static func set(_ turnOn: Bool) {
        let products = TheoProducts.shared
        if products.isOn(.clicky) != turnOn { products.set(.clicky, on: turnOn) }
        if turnOn {
            if !ClickySettings.isActionsEnabled { UserDefaults.standard.set(true, forKey: ClickySettings.Keys.actionsEnabled) }
            if let manager = CompanionManager.current, !manager.isClickyCursorEnabled { manager.setClickyCursorEnabled(true) }
        }
    }
}
