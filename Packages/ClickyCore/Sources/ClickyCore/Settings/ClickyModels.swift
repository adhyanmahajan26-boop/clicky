//
//  ClickyModels.swift
//  ClickyCore
//
//  Which Claude model each part of Clicky runs on, by exact model id.
//  Claude Code's aliases ("haiku", "sonnet") resolve differently across
//  CLI versions and sign-ins (a fresh Mac answered with an older Haiku),
//  so Clicky always passes a full id. Setup lets the owner pick each one.
//

import Foundation

public enum ClickyModels {
    public struct Option: Hashable, Sendable {
        public let identifier: String
        public let label: String
    }

    public static let opus = "claude-opus-5-5"
    public static let sonnet = "claude-sonnet-5-5"
    public static let haiku = "claude-haiku-5-5"
    public static let fable = "claude-fable-5-1"

    public static let options: [Option] = [
        Option(identifier: opus, label: "Opus 5.5 (smartest)"),
        Option(identifier: sonnet, label: "Sonnet 5.5 (balanced)"),
        Option(identifier: haiku, label: "Haiku 5.5 (fastest)"),
        Option(identifier: fable, label: "Fable 5.1")
    ]

    /// A Claude Code alias becomes the newest id in that family; ids pass through.
    public static func resolve(_ aliasOrIdentifier: String) -> String {
        let trimmed = aliasOrIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "", "sonnet": return sonnet
        case "opus": return opus
        case "haiku": return haiku
        case "fable": return fable
        default: return trimmed
        }
    }

    private static var defaults: UserDefaults { .standard }

    /// The model that answers (the panel's Model row; pre-v2 key).
    public static var main: String {
        get { resolve(defaults.string(forKey: ClickySettings.LegacyKeys.selectedClaudeCodeModelAlias) ?? sonnet) }
        set { defaults.set(resolve(newValue), forKey: ClickySettings.LegacyKeys.selectedClaudeCodeModelAlias) }
    }

    /// Helper workers, research pages, mark checks, the board's sections and Clicky's team. Until the owner picks one
    /// it's a cheap model of the main brain (`HelperBrain.cheapModel`): Haiku on Claude, the main model on anything else.
    public static var helper: String {
        get {
            let saved = defaults.string(forKey: ClickySettings.Keys.modelsHelper)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return saved.isEmpty ? HelperBrain.cheapModel(forMain: main) : resolve(saved)
        }
        set { defaults.set(resolve(newValue), forKey: ClickySettings.Keys.modelsHelper) }
    }

    /// Whether the owner (or Setup) ever saved a helper model.
    public static var helperWasChosen: Bool {
        !(defaults.string(forKey: ClickySettings.Keys.modelsHelper)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Once, for a Mac that finished setup before helpers followed the brain: helpers there always ran on Haiku, so that
    /// is written down as the owner's choice and nothing changes for them. A new Mac never gets this.
    public static func keepEarlierHelperDefaultOnce(setupWasCompleted: Bool, in store: UserDefaults = .standard) {
        let doneKey = "v4.models.helperDefaultKept"
        guard !store.bool(forKey: doneKey) else { return }
        store.set(true, forKey: doneKey)
        let saved = store.string(forKey: ClickySettings.Keys.modelsHelper)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard setupWasCompleted, saved.isEmpty else { return }
        store.set(haiku, forKey: ClickySettings.Keys.modelsHelper)
    }

    /// The Claude Code agent that edits code.
    public static var code: String {
        get { resolve(defaults.string(forKey: ClickySettings.Keys.modelsCode) ?? sonnet) }
        set { defaults.set(resolve(newValue), forKey: ClickySettings.Keys.modelsCode) }
    }
}
