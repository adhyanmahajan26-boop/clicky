//
//  ContextBudget.swift
//  ClickyCore
//
//  How much of a conversation fits in the model a bot or a call is using. There used to be fixed caps (60 messages
//  on an API key, 8 turns on another command-line agent, a call starting with six lines of chat), so a long call or
//  chat forgot its start even on a model with room for far more (Addy, 23 Nov: "we need a full talking AI").
//  Now the room is the model's own context window, less what its answer and the instructions need, and what no
//  longer fits is summed up by the model itself (`ConversationCompaction`) rather than dropped.
//

import Foundation

public enum ContextBudget {
    /// Characters per token, on the safe side: English runs about four, Hindi in Devanagari nearer two.
    public static let charactersPerToken = 3.0
    /// A local server (LM Studio, Ollama) that didn't say how much it loaded: LM Studio's own default is 4,096,
    /// and most people raise it, so this is the small side of what's usual.
    public static let unknownLocalWindowTokens = 8_192
    /// The most kept word for word before the oldest part is summed up. A model with a million tokens could take more,
    /// but every turn sends all of it again, and a call should start speaking within a second or two.
    public static let longestLiveHistoryCharacters = 240_000

    /// The context window of `model` in tokens. `reportedTokens`: what the server said it loaded, which wins.
    public static func windowTokens(model: String, isLocalServer: Bool, reportedTokens: Int? = nil) -> Int {
        if let reportedTokens, reportedTokens > 0 { return reportedTokens }
        if isLocalServer { return unknownLocalWindowTokens }
        let name = model.lowercased()
        if name.contains("gemini") { return 1_000_000 }
        if name.contains("claude") || name.contains("sonnet") || name.contains("opus") || name.contains("haiku") || name.contains("fable") { return 200_000 }
        if name.contains("gpt-5") || name.contains("gpt-4.1") { return 400_000 }
        if name.contains("sarvam") { return 32_000 }
        return 128_000
    }

    /// Tokens kept for the answer: a thinking model's room, but never more than a quarter of a small window.
    public static func answerTokens(windowTokens: Int, wantedAnswerTokens: Int) -> Int {
        min(wantedAnswerTokens, max(512, windowTokens / 4))
    }

    /// How many characters of earlier conversation may be sent with a turn, word for word.
    /// `instructionsCharacters`: the system prompt that goes with every turn.
    public static func historyCharacters(windowTokens: Int, answerTokens: Int, instructionsCharacters: Int) -> Int {
        let instructionsTokens = Int(Double(instructionsCharacters) / charactersPerToken)
        // A tenth spare: our count is an estimate, and the server's own wrapping costs a little.
        let spareTokens = max(256, windowTokens / 10)
        let roomTokens = windowTokens - answerTokens - instructionsTokens - spareTokens
        let roomCharacters = Int(Double(max(0, roomTokens)) * charactersPerToken)
        return max(2_000, min(longestLiveHistoryCharacters, roomCharacters))
    }

    /// How much of the chat a call starts with: a quarter of the room, so the call itself has the rest, and at most
    /// about 13,000 words, so the first answer still comes in a second or two.
    public static func callCarryOverCharacters(historyCharacters: Int) -> Int {
        max(2_000, min(40_000, historyCharacters / 4))
    }
}

/// When a conversation outgrows its room, the oldest part is summed up by the same model into one summary that goes
/// first, and the newest part stays word for word. A summary from before goes into the next one, so nothing said is
/// ever simply dropped, however long the chat or call runs.
public enum ConversationCompaction {
    public struct Message: Equatable, Sendable {
        public var role: String
        public var text: String

        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// The start of the user message that carries a summary.
    public static let summaryMarker = "(Summary of the earlier part of this conversation"
    /// The assistant's line after it, so turns still take turns (user, assistant) for the APIs that insist.
    public static let summaryAcknowledgement = "Got it, I have the earlier part in mind."
    /// The longest a summary may be.
    public static let longestSummaryCharacters = 8_000

    public static func isSummary(_ message: Message) -> Bool {
        message.role == "user" && message.text.hasPrefix(summaryMarker)
    }

    public static func totalCharacters(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + $1.text.count }
    }

    /// What to sum up: the first `count` messages, leaving the newest half of the room word for word, starting at a
    /// user message. Nil while everything fits, or when there is nothing old enough to sum up.
    public static func partToSummarize(_ messages: [Message], roomCharacters: Int) -> Int? {
        guard totalCharacters(messages) > roomCharacters, messages.count >= 4 else { return nil }
        var keptCharacters = 0
        var firstKept = messages.count
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            let withThisOne = keptCharacters + messages[index].text.count
            // The latest exchange always stays word for word; past that, half the room.
            if withThisOne > roomCharacters / 2 && firstKept <= messages.count - 2 { break }
            keptCharacters = withThisOne
            firstKept = index
        }
        // The kept part starts with the owner's turn.
        while firstKept > 0 && messages[firstKept].role != "user" { firstKept -= 1 }
        return firstKept >= 2 ? firstKept : nil
    }

    /// The request to the model: the part to sum up, earlier summary included.
    public static func summaryRequest(for part: [Message], owner: String) -> String {
        let ownerWord = OwnerName.isUnset(owner) ? "the owner" : owner
        let transcript = part.map { message -> String in
            if isSummary(message) { return "Earlier summary:\n" + message.text }
            return (message.role == "user" ? "\(OwnerName.startingSentence(owner)): " : "You: ") + message.text
        }.joined(separator: "\n\n")
        return """
        Below is the earlier part of your conversation with \(ownerWord). It no longer fits word for word, so write the summary you'll keep instead.
        Keep every fact, name, number, date, decision, promise, preference and open question, who said what where it matters, \
        and anything \(ownerWord) asked you to remember or do. Drop greetings and filler. Plain sentences, in the language the conversation used, \
        at most about \(longestSummaryCharacters / 6) words. Write only the summary.

        \(transcript)
        """
    }

    /// The conversation with its first `count` messages replaced by the summary.
    public static func replacing(_ messages: [Message], firstCount count: Int, withSummary summary: String) -> [Message] {
        let trimmed = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(longestSummaryCharacters))
        let summaryMessage = Message(role: "user", text: summaryMarker + ", written by you to remember it:\n" + trimmed + ")")
        return [summaryMessage, Message(role: "assistant", text: summaryAcknowledgement)] + messages.dropFirst(count)
    }

    /// What goes with a turn when a summary isn't ready yet: the summary (if any) and the newest messages that fit,
    /// starting at a user message. Never more than `roomCharacters`, so the model's window can't overflow.
    public static func fitting(_ messages: [Message], roomCharacters: Int) -> [Message] {
        guard totalCharacters(messages) > roomCharacters else { return messages }
        var head: [Message] = []
        var rest = messages[...]
        if let first = messages.first, isSummary(first) {
            head = Array(messages.prefix(2))
            rest = messages.dropFirst(2)
        }
        var used = totalCharacters(head)
        var kept: [Message] = []
        for message in rest.reversed() {
            if !kept.isEmpty && used + message.text.count > roomCharacters { break }
            kept.insert(message, at: 0)
            used += message.text.count
        }
        while kept.count > 1 && kept.first?.role != "user" { kept.removeFirst() }
        // The one newest message alone can be too long; its end is what's being answered.
        if let only = kept.first, kept.count == 1, used > roomCharacters {
            kept = [Message(role: only.role, text: String(only.text.suffix(max(1_000, roomCharacters - totalCharacters(head)))))]
        }
        return head + kept
    }
}
