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

    /// Helper workers, research pages, mark checks and the board's sections.
    public static var helper: String {
        get { resolve(defaults.string(forKey: ClickySettings.Keys.modelsHelper) ?? haiku) }
        set { defaults.set(resolve(newValue), forKey: ClickySettings.Keys.modelsHelper) }
    }

    /// The Claude Code agent that edits code.
    public static var code: String {
        get { resolve(defaults.string(forKey: ClickySettings.Keys.modelsCode) ?? sonnet) }
        set { defaults.set(resolve(newValue), forKey: ClickySettings.Keys.modelsCode) }
    }
}
