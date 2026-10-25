//
//  TypeForMePolicy.swift
//  ClickyCore
//
//  P6.2: whether Clicky may type into the focused field at all. Typing is
//  refused (the card offers Copy only) when the feature is off, secure
//  event input is on anywhere (a password prompt), the field is a secure
//  text field, the target is Clicky itself, the app is on the blocked list
//  (password managers, Keychain Access), or nothing is focused. Terminals
//  are allowed but need a second confirm and never get line breaks.
//

import Foundation

public enum TypeForMeRefusal: Equatable, Sendable {
    case featureDisabled
    case secureEventInput
    case secureTextField
    case ownApplication
    case blockedApplication(bundleIdentifier: String)
    case noFocusedField

    /// One line for the card.
    public var cardExplanation: String {
        switch self {
        case .featureDisabled: return "Typing is off (Settings › Type this for me). You can copy it."
        case .secureEventInput: return "A password prompt has secure input on — Clicky won't type."
        case .secureTextField: return "That's a password field — Clicky never types there."
        case .ownApplication: return "The focused field belongs to Clicky."
        case .blockedApplication: return "Clicky doesn't type into this app."
        case .noFocusedField: return "No text field has focus."
        }
    }
}

/// Everything the refusal rules look at, read once when the card opens
/// (and again just before inserting).
public struct TypeForMeTargetFacts: Equatable, Sendable {
    public var isFeatureEnabled: Bool
    public var isSecureEventInputEnabled: Bool
    public var bundleIdentifier: String?
    public var processIdentifier: Int32
    public var hasFocusedElement: Bool
    public var focusedElementRole: String?
    public var focusedElementSubrole: String?

    public init(isFeatureEnabled: Bool, isSecureEventInputEnabled: Bool, bundleIdentifier: String?, processIdentifier: Int32,
                hasFocusedElement: Bool, focusedElementRole: String?, focusedElementSubrole: String?) {
        self.isFeatureEnabled = isFeatureEnabled
        self.isSecureEventInputEnabled = isSecureEventInputEnabled
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.hasFocusedElement = hasFocusedElement
        self.focusedElementRole = focusedElementRole
        self.focusedElementSubrole = focusedElementSubrole
    }
}

public enum TypeForMePolicy {
    public static let secureTextFieldSubrole = "AXSecureTextField"

    /// Terminal, iTerm2, Warp, Ghostty: second confirm, no line breaks.
    public static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty"
    ]

    public static func isTerminal(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    /// How many confirms the target needs (terminals: two).
    public static func requiredConfirmCount(bundleIdentifier: String?) -> Int {
        isTerminal(bundleIdentifier: bundleIdentifier) ? 2 : 1
    }

    /// nil = typing is allowed. The first matching rule wins, safest first.
    public static func refusal(for facts: TypeForMeTargetFacts, ownBundleIdentifier: String?, ownProcessIdentifier: Int32,
                               blockedBundleIdentifiers: Set<String>) -> TypeForMeRefusal? {
        if facts.isSecureEventInputEnabled { return .secureEventInput }
        if facts.focusedElementSubrole == secureTextFieldSubrole { return .secureTextField }
        if facts.processIdentifier == ownProcessIdentifier { return .ownApplication }
        if let bundleIdentifier = facts.bundleIdentifier {
            if let ownBundleIdentifier, bundleIdentifier == ownBundleIdentifier { return .ownApplication }
            if blockedBundleIdentifiers.contains(bundleIdentifier) { return .blockedApplication(bundleIdentifier: bundleIdentifier) }
        }
        if !facts.isFeatureEnabled { return .featureDisabled }
        if !facts.hasFocusedElement { return .noFocusedField }
        return nil
    }

    /// The card's "how" line.
    public static func insertionMethodDescription(isTerminal: Bool, isSingleLine: Bool) -> String {
        if isTerminal { return "Paste into the terminal (line breaks removed, press Return twice)" }
        return isSingleLine ? "AX insert, else paste, else type" : "AX insert, else paste"
    }

    /// Short role names for the card ("AXTextArea" → "text area").
    public static func readableRole(_ role: String?) -> String {
        switch role {
        case "AXTextField": return "text field"
        case "AXTextArea": return "text area"
        case "AXComboBox": return "combo box"
        case "AXSearchField": return "search field"
        case "AXWebArea": return "web page"
        case .some(let role) where role.hasPrefix("AX"): return String(role.dropFirst(2)).lowercased()
        case .some(let role): return role
        case .none: return "unknown field"
        }
    }
}
