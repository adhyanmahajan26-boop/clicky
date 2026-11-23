//
//  CallAnyBot.swift
//  ClickyCore
//
//  Voice calls with any bot, not only Vello's own. Vello keeps its call controls ([CLICKY: …], [POINTER: …],
//  [ROUTINE: …], [TELL: Vello: …]); another bot only talks. These are the pure parts: what a bot is told on a call
//  (`CallPromptText`), which brain answers for it (`CallBrainChoice`) and the stream that keeps its bracket lines out of
//  the voice (`CallBracketLineStream`).
//

import Foundation

/// What a bot is told on a call.
public enum CallPromptText {
    /// How to talk on a call. The same words for Vello and for any other bot.
    public static func talkingRules(owner: String) -> String {
        """
        You are on a live voice call with \(owner) right now. Everything you write is read aloud at once by a voice.
        Talk the way a friend does on the phone: warm, relaxed and natural, in everyday words with contractions. Usually one to three short sentences. Start with the answer; your first sentence should be short, because it's spoken while you're still writing the rest.
        Sound like a person, not an assistant: react the way people do when it fits ("oh nice", "hmm", "fair enough"), but don't open every reply the same way, don't repeat back what \(owner) said, and skip filler like "great question" or "I'd be happy to help". Ask at most one question back, and only when you need the answer.
        No markdown, lists, headings, code, emoji or stage directions. Spell out what's awkward to read aloud. Numbers are fine.
        \(OwnerName.startingSentence(owner)) may cut in at any time. If a message starts where your last answer was cut off, just carry on with what they said.
        """
    }

    /// The call how-to for any bot but Vello's own: it only talks. Vello's controls aren't offered, and anything it writes
    /// in square brackets is taken out before the voice (`CallBracketLineStream`).
    public static func otherBotHowTo(owner: String) -> String {
        "On this call you only talk. You can't run anything, use your apps, tools or files, or hand work to anyone from here, " +
            "and nothing you write in square brackets reaches anyone, so don't write tags or control lines. " +
            "If \(owner) asks for something that needs your tools or apps, say so in a sentence: they can ask you in your text chat, where this whole call will be saved."
    }

    /// One line of a bot's text chat before the call.
    public struct ChatLine: Equatable, Sendable {
        public var isFromOwner: Bool
        public var text: String

        public init(isFromOwner: Bool, text: String) {
            self.isFromOwner = isFromOwner
            self.text = text
        }
    }

    /// The end of the bot's own text chat, as Vello's call prompt has it: the last six lines, each on one line.
    public static func recentChat(botName: String, owner: String, lines: [ChatLine]) -> String? {
        let shown = lines.suffix(6).map { line -> String in
            let who = line.isFromOwner ? OwnerName.startingSentence(owner) : botName
            return "\(who): " + String(line.text.replacingOccurrences(of: "\n", with: " ").prefix(240))
        }
        guard !shown.isEmpty else { return nil }
        return "The end of your text chat with \(owner), before this call:\n" + shown.joined(separator: "\n")
    }

    /// Everything a bot that isn't Vello's own is told for a call: its name and instructions, how to talk, that it only
    /// talks, the language, who it reports to, its memory and the end of its own chat.
    /// `instructions`: the bot's own, with its nature after them (`BotOwnFiles.personaHead`).
    public static func otherBot(name: String, instructions: String, owner: String, languageRule: String,
                                reportingLines: [String] = [], memorySection: String? = nil, recentChat lines: [ChatLine] = []) -> String {
        let ownInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        // Its name first, unless its instructions already start with it.
        var parts = ownInstructions.lowercased().hasPrefix("you are \(name.lowercased())") ? [] : ["You are \(name)."]
        if !ownInstructions.isEmpty { parts.append(ownInstructions) }
        var rules = talkingRules(owner: owner) + "\n" + otherBotHowTo(owner: owner)
        if !languageRule.isEmpty { rules += "\n" + languageRule }
        parts.append(rules)
        parts += reportingLines
        if let memorySection, !memorySection.isEmpty { parts.append(memorySection) }
        if let chat = recentChat(botName: name, owner: owner, lines: lines) { parts.append(chat) }
        return parts.joined(separator: "\n\n")
    }

    /// The call's first turn: a hello in a few words.
    public static func hello(owner: String) -> String {
        OwnerName.isUnset(owner)
            ? "(The call just connected. Say hello in a few words and stop there.)"
            : "(The call just connected. Say hello to \(owner) in a few words and stop there.)"
    }
}

/// Which brain answers a call with a bot that isn't Vello's own: that bot's own engine and model, or plain words for
/// why it can't take the call and what fixes it.
public enum CallBrainChoice: Equatable, Sendable {
    case use(brainSetting: String)
    case cannotCall(String)

    /// `engineName`: the bot's engine as the owner knows it ("Codex", "LM Studio", "Grok").
    public static func forBot(named name: String, engine: BotEngineChoice, engineName: String, inventory: BrainInventory) -> CallBrainChoice {
        guard let setting = engine.brainSetting else {
            return .cannotCall("\(name) thinks with \(engineName), which can't take a voice call yet. Pick another engine in \(name)'s settings (Claude, Codex, Cursor, OpenCode or an API key) and call again.")
        }
        if inventory.isUsable(setting) { return .use(brainSetting: setting) }
        let provider = BrainModel(setting: setting).provider
        if provider == .api {
            return .cannotCall("\(name) thinks with \(engineName), which isn't answering here. \(BrainTrouble.signInFix(for: .api)) If it's a server on this Mac, like LM Studio, start it. Or pick another engine in \(name)'s settings.")
        }
        let signIn = BrainTrouble.signInFix(for: provider)
        let signInLowercased = signIn.prefix(1).lowercased() + signIn.dropFirst()
        return .cannotCall("\(name) thinks with \(engineName), which isn't ready on this Mac. \(BrainTrouble.installFix(for: provider)) If it's installed but signed out, \(signInLowercased)")
    }
}

/// Another bot on a call has none of Vello's call controls: every bracket line it writes ([TELL: …], [FILE: …],
/// [CLICKY: …], [POINTER: …], [SILENT]) comes out of what's spoken and shown, wherever a streamed piece splits it.
/// A markdown link's "[words](…)" isn't a tag and stays.
public struct CallBracketLineStream: Sendable {
    private var held = ""
    /// The longest tag name looked for ("SAVE FILE", "DELEGATE").
    private static let longestHead = 16
    private static let maximumHeld = 1600
    /// Tags with no colon that are dropped too.
    private static let bareTags: Set<String> = ["SILENT"]

    public init() {}

    public mutating func feed(_ delta: String) -> String {
        held += delta
        return drain(isFinal: false)
    }

    public mutating func finish() -> String { drain(isFinal: true) }

    /// The bracket lines out of a whole reply at once.
    public static func strip(_ text: String) -> String {
        var stream = CallBracketLineStream()
        return stream.feed(text) + stream.finish()
    }

    private mutating func drain(isFinal: Bool) -> String {
        var speech = ""
        while let open = held.firstIndex(of: "[") {
            speech += held[..<open]
            held = String(held[open...])
            switch Self.classify(held) {
            case .notATag:
                speech.append(held.removeFirst())
            case .incomplete(let hasColon):
                if isFinal || held.count > Self.maximumHeld {
                    // Never closed: a tag is dropped rather than read out, anything else is said as written.
                    if !hasColon { speech += held }
                    held = ""
                }
                return speech
            case .closed(let end):
                held = String(held[held.index(after: end)...])
            }
        }
        speech += held
        held = ""
        return speech
    }

    private enum Shape: Equatable { case notATag, incomplete(hasColon: Bool), closed(end: String.Index) }

    /// `text` starts with "[": a tag ("[NAME: …]" with a name in capitals, or a bare one like "[SILENT]"), one still
    /// arriving, or neither.
    private static func classify(_ text: String) -> Shape {
        var index = text.index(after: text.startIndex)
        var head = ""
        while index < text.endIndex, head.count <= longestHead {
            let character = text[index]
            guard character.isUppercase || character == " " || character == "_" || (character == "-" && !head.isEmpty) else { break }
            head.append(character)
            index = text.index(after: index)
        }
        let name = head.trimmingCharacters(in: .whitespaces)
        guard index < text.endIndex else {
            // Still arriving: hold it while it could become a tag name.
            return head.count <= longestHead ? .incomplete(hasColon: false) : .notATag
        }
        let letters = name.filter(\.isLetter)
        switch text[index] {
        case ":":
            guard letters.count >= 2 else { return .notATag }
            guard let close = text[index...].firstIndex(of: "]") else { return .incomplete(hasColon: true) }
            return .closed(end: close)
        case "]":
            return bareTags.contains(name) ? .closed(end: index) : .notATag
        default:
            return .notATag
        }
    }
}
