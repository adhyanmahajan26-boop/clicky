//
//  WakeTarget.swift
//  ClickyCore
//
//  Who a wake phrase calls. "Hey Vello" used to wake Pointer Assistant, which
//  works on the screen and has no apps: "hey vello, find my mails" went to the
//  one helper that can't read mail (Air, 23 Nov), and never reached Vello,
//  which has Gmail and the other apps. Now Vello's names call Vello (a call
//  starts with what was said after the name), and Pointer Assistant keeps its
//  own: "hey pointer", "hey clicky", "hey claudia".
//

import Foundation

public enum WakeTarget: String, Equatable, Sendable {
    /// A call with Vello, the bot with the apps.
    case vello
    /// Pointer Assistant: the spark, the screen and actions on it.
    case pointerAssistant

    /// Names that call Vello: its own, its old one, and whatever the owner named it.
    public static let velloNames: Set<String> = ["vello", "theo"]

    /// The target of a matched phrase ("hey vello" → `.vello`). `assistantName` is the name the owner gave Vello
    /// (Settings), so "hey <that name>" calls Vello too. Everything else wakes Pointer Assistant, as before.
    public static func of(phrase: String, assistantName: String) -> WakeTarget {
        guard let name = WakeWordMatcher.normalizedWords(in: phrase).last else { return .pointerAssistant }
        let ownNames = velloNames.union(WakeWordMatcher.normalizedWords(in: assistantName).suffix(1))
        // The owner may have named Vello after one of Pointer Assistant's names; Pointer Assistant keeps those.
        if pointerAssistantNames.contains(name) { return .pointerAssistant }
        return ownNames.contains(name) ? .vello : .pointerAssistant
    }

    /// Names that always mean Pointer Assistant.
    public static let pointerAssistantNames: Set<String> = ["pointer", "clicky", "claudia"]

    /// What the owner asked, without the rest of Pointer Assistant's name: "hey pointer assistant, open notes" matches on
    /// "pointer", and the turn would start with "assistant".
    public static func turnText(_ text: String, for target: WakeTarget) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target == .pointerAssistant else { return trimmed }
        let words = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let firstWord = words.first, WakeWordMatcher.normalizedWord(String(firstWord)) == "assistant" else { return trimmed }
        return WakeWordMatcher.trimmedRemainder(words.count > 1 ? String(words[1]) : "")
    }
}
