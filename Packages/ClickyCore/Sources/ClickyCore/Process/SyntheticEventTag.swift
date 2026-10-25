//
//  SyntheticEventTag.swift
//  ClickyCore
//
//  The marker on every input event Clicky makes itself, so its own clicks
//  can never be mistaken for the user's.
//

import Foundation

public enum SyntheticEventTag {
    /// "CLICKY" in ASCII. Clicky stamps this on every CGEvent it synthesizes
    /// (as the event's eventSourceUserData field), and the click gate rejects
    /// any event carrying it, so a synthesized click can't approve itself.
    public static let value: Int64 = 0x434C49434B59

    /// True when an event's eventSourceUserData says Clicky made it.
    public static func isTagged(userData: Int64) -> Bool {
        userData == value
    }
}
