//
//  ProviderUses.swift
//  ClickyCore
//
//  What a saved key's models are offered to: bots, Theo, Clicky. Everything is on until the owner turns one off,
//  so only the turned-off ones are stored. It only filters the pickers: whatever is already set keeps running.
//

import Foundation

public enum ProviderUse: String, CaseIterable, Identifiable, Sendable {
    case bots, theo, clicky

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .bots: return "Bots"
        case .theo: return "Theo"
        case .clicky: return "Clicky"
        }
    }
}

public enum ProviderUses {
    public static let storageKey = "theo.providers.usesOff"

    public static func allows(_ use: ProviderUse, providerID: String, defaults: UserDefaults = .standard) -> Bool {
        !(off(in: defaults)[providerID] ?? []).contains(use.rawValue)
    }

    public static func set(_ isOn: Bool, use: ProviderUse, providerID: String, defaults: UserDefaults = .standard) {
        var all = off(in: defaults)
        var turnedOff = Set(all[providerID] ?? [])
        if isOn { turnedOff.remove(use.rawValue) } else { turnedOff.insert(use.rawValue) }
        all[providerID] = turnedOff.isEmpty ? nil : turnedOff.sorted()
        defaults.set(all, forKey: storageKey)
    }

    /// A removed key forgets its choices, so a new key starts with everything on.
    public static func forget(providerID: String, defaults: UserDefaults = .standard) {
        var all = off(in: defaults)
        all[providerID] = nil
        defaults.set(all, forKey: storageKey)
    }

    private static func off(in defaults: UserDefaults) -> [String: [String]] {
        defaults.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
    }
}

/// Which engine a coding prompt really went to. Once a run exists its own harness says, not the default that happens
/// to be set when the chat is drawn. A run with no harness went through T3 Code.
public enum SentEngine {
    public static func resolve(hasMatchingRun: Bool, runHarness: String?, chosen: String) -> String {
        guard hasMatchingRun else { return chosen }
        return runHarness ?? "t3"
    }
}
