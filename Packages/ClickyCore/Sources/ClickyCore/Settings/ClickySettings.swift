//
//  ClickySettings.swift
//  ClickyCore
//
//  Clicky v2 settings. New keys use the `v2.` prefix; keys that existed
//  before v2 are reused by their original names (listed in LegacyKeys) so
//  nobody loses their choices.
//

import Foundation

public enum ClickySettings {
    /// Pre-v2 keys, reused as-is (see docs/v2/INVENTORY.md).
    public enum LegacyKeys {
        public static let usesQwenLocalVoice = "usesQwenLocalVoice"
        public static let selectedSpeechVoiceIdentifier = "selectedSpeechVoiceIdentifier"
        public static let selectedClaudeCodeModelAlias = "selectedClaudeCodeModelAlias"
        public static let isClickyCursorEnabled = "isClickyCursorEnabled"
        public static let handsFreeEchoCancellationDisabled = "handsFreeEchoCancellationDisabled"
    }

    public enum Keys {
        public static let groundingEnabled = "v2.grounding.enabled"
        public static let groundingImageTier = "v2.grounding.imageTier"
        public static let groundingProbe = "v2.grounding.probe"
        /// Bool, default true: draw id badges on the images (A/B switch).
        public static let groundingBadges = "v2.grounding.badges"
        /// [String] bundle ids whose field values are never read.
        public static let groundingValueBlockedBundleIDs = "v2.grounding.valueBlockedBundleIDs"
    }

    /// Password managers and Keychain: never read their field values.
    public static let defaultValueBlockedBundleIDs = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.agilebits.onepassword7", "com.1password.1password",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
        "com.callpod.keepermac.lite", "com.nordpass.macos.NordPass", "in.sinew.Enpass-Desktop"
    ]

    public static var valueBlockedBundleIDs: Set<String> {
        Set(defaults.stringArray(forKey: Keys.groundingValueBlockedBundleIDs) ?? defaultValueBlockedBundleIDs)
    }

    public static var areBadgesEnabled: Bool {
        defaults.object(forKey: Keys.groundingBadges) as? Bool ?? true
    }

    public enum ImageTierSetting: String, Sendable {
        case auto
        case high
        case standard

        /// The tier the cursor screen is sent at.
        public var cursorScreenTier: ImageTier { self == .standard ? .standard : .high }
    }

    /// One model's tier-probe result.
    public struct ProbeRecord: Codable, Equatable, Sendable {
        /// Set when the model sees less than we send; images get capped to it.
        public var effectiveMaxEdge: Int?
        /// The sizes probed, e.g. ["2576x1078", "1920x1080"].
        public var sizes: [String]
        /// Worst error in pixels across the probes that passed.
        public var error: Double
        public var date: Date
        /// Why effectiveMaxEdge is set (e.g. "CLI downscale").
        public var reason: String?

        public init(effectiveMaxEdge: Int?, sizes: [String], error: Double, date: Date, reason: String? = nil) {
            self.effectiveMaxEdge = effectiveMaxEdge
            self.sizes = sizes
            self.error = error
            self.date = date
            self.reason = reason
        }
    }

    private static var defaults: UserDefaults { .standard }

    /// The saved preference. The startup geometry self-check can turn
    /// grounding off for one session without ever writing this.
    public static var isGroundingEnabled: Bool {
        defaults.object(forKey: Keys.groundingEnabled) as? Bool ?? true
    }

    public static var imageTier: ImageTierSetting {
        ImageTierSetting(rawValue: defaults.string(forKey: Keys.groundingImageTier) ?? "") ?? .auto
    }

    /// Tier-probe results keyed by resolved model id.
    public static var probeRecords: [String: ProbeRecord] {
        get {
            guard let probeData = defaults.data(forKey: Keys.groundingProbe) else { return [:] }
            return (try? JSONDecoder().decode([String: ProbeRecord].self, from: probeData)) ?? [:]
        }
        set {
            guard let probeData = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(probeData, forKey: Keys.groundingProbe)
        }
    }

    public static func effectiveMaxEdge(forModelIdentifier modelIdentifier: String?) -> Int? {
        guard let modelIdentifier else { return nil }
        return probeRecords[modelIdentifier]?.effectiveMaxEdge
    }
}
