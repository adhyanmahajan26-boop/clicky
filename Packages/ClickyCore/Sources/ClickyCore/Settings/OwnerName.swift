//
//  OwnerName.swift
//  ClickyCore
//
//  What the bots call the person Theo works for. It's one setting (`ClickySettings.ownerName`), asked for in first-run
//  setup and changeable in Settings › General. Until it's set, every prompt says "the owner". These are the pure rules:
//  how a saved name is read, how it starts a sentence, what setup suggests, and the one-time migration for a Mac that
//  finished setup back when the name was built in.
//

import Foundation

public enum OwnerName {
    /// What prompts say before the owner has given a name.
    public static let unset = "the owner"

    /// Longer names are cut: the name goes into many prompts.
    public static let maximumLength = 40

    /// The name every prompt used before it became a setting. Only the one-time migration below uses it, so a Mac that
    /// finished setup before this change keeps calling its owner what its bots already know them as.
    public static let nameBeforeItWasASetting = "Addy"

    /// A saved name, tidied; "the owner" when nothing usable is saved.
    public static func resolved(saved: String?) -> String {
        let trimmed = (saved ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unset }
        return String(trimmed.prefix(maximumLength))
    }

    public static func isUnset(_ ownerName: String) -> Bool { ownerName == unset }

    /// The name at the start of a sentence: "The owner sees…" rather than "the owner sees…". A real name is left as written.
    public static func startingSentence(_ ownerName: String) -> String {
        guard isUnset(ownerName) else { return ownerName }
        return "The owner"
    }

    /// How bots refer to the owner: by name, or they, never he or she.
    public static func pronounLine(_ ownerName: String) -> String {
        isUnset(ownerName)
            ? "Call the owner they, never he or she."
            : "Call the owner \(ownerName), or they, never he or she."
    }

    /// What setup's name field starts with: the first word of the computer account's full name ("Sam Rivera" → "Sam"),
    /// else the account name itself, capitalised. Empty when neither gives anything usable.
    public static func suggestion(fullUserName: String, accountName: String) -> String {
        let firstWordOfFullName = fullUserName.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        if !firstWordOfFullName.isEmpty { return String(firstWordOfFullName.prefix(maximumLength)) }
        let trimmedAccountName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccountName.isEmpty, trimmedAccountName != "root" else { return "" }
        let capitalisedAccountName = trimmedAccountName.prefix(1).uppercased() + trimmedAccountName.dropFirst()
        return String(capitalisedAccountName.prefix(maximumLength))
    }

    /// The name to save once at launch, or nil to leave things as they are. A Mac that finished setup before the name was
    /// a setting gets the name its bots were always told, so nothing they say changes. A new install gets nothing here:
    /// setup asks. Anything already saved, even an empty name the owner cleared on purpose, is never touched.
    public static func migratedName(savedValueExists: Bool, setupCompleted: Bool) -> String? {
        guard !savedValueExists, setupCompleted else { return nil }
        return nameBeforeItWasASetting
    }
}
