//
//  ActionEnterPolicy.swift
//  ClickyCore
//
//  P8: when Clicky may press Return / Enter for the owner, and the two
//  follow-up memories that make "press enter" work as a second sentence.
//
//   - ActionEnterIntent: did the owner ask for Return / send? Explicit
//     phrases ("press enter", "hit return", "send it", "submit", "enter
//     dabao", "bhej do"…) count anywhere. Speech recognition mangles a bare
//     "press enter" ("Present for me too", "Press Centre"), so short
//     utterances (≤ 4 words) whose only real words are an ASR look-alike
//     ("present", "press centre", "press inter", "president"…) also count —
//     but only when the model's step really is a Return.
//   - ActionSafariFollowUp: the owner naming Safari ("type … in Safari")
//     keeps covering that same Safari window for 2 minutes, so the follow-up
//     "press enter" isn't refused for not naming Safari again. Never covers a
//     window showing Netflix unless he says Netflix.
//   - ActionTerminalForeground: what runs in the front terminal tab. Claude
//     Code's prompt is a chat box (typing + Enter allowed like one); a plain
//     shell is refused.
//

import Foundation

public enum ActionEnterIntent {
    /// Count anywhere in the owner's words (whole words, case-insensitive).
    static let explicitPhrases = [
        // English
        "press enter", "hit enter", "press return", "hit return", "enter key", "return key", "and enter", "then enter", "press the enter",
        "hit the enter", "press the return", "hit the return", "tap enter", "push enter", "press inter", "hit inter", "press entre", "hit entre",
        "send it", "and send", "then send", "send the message", "send that", "send this", "submit", "and post it", "post it",
        // Hindi / Hinglish (romanised)
        "enter dabao", "enter daba do", "enter dabado", "enter dabaa do", "enter dabaiye", "enter daba", "enter karo", "enter kar do", "enter kardo",
        "enter kariye", "enter press karo", "enter press kar do", "enter press kardo", "enter maro", "enter maaro", "enter maar do", "press enter karo",
        "bhej do", "bhejdo", "bhej de", "bhejo", "bhej dijiye", "send kar do", "send kardo", "send karo", "send kar de", "submit karo", "submit kar do",
        // Hindi (Devanagari)
        "एंटर दबाओ", "एंटर दबा दो", "एंटर करो", "एंटर कर दो", "एंटर प्रेस करो", "भेज दो", "भेजो", "सेंड कर दो", "सेंड करो"
    ]

    /// ASR look-alikes of "press enter" / "enter" / "send": only in a short
    /// utterance whose other words are filler, and only for a Return step.
    static let lookAlikeHeads: [[String]] = [
        ["press", "center"], ["press", "centre"], ["press", "the", "center"], ["press", "the", "centre"], ["present"], ["presents"], ["president"],
        ["press", "entre"], ["press", "inter"], ["press", "under"], ["press", "enter"], ["hit", "center"], ["hit", "centre"], ["hit", "inter"],
        ["hit", "under"], ["precenter"], ["precentre"], ["pressenter"], ["press", "and", "enter"], ["press", "return"], ["press", "a", "return"],
        ["enter"], ["return"], ["send"], ["submit"], ["inter"], ["entre"], ["center"], ["centre"]
    ]
    /// Words that may surround a look-alike ("Present for me too").
    static let shortFillerWords: Set<String> = [
        "for", "me", "too", "to", "two", "it", "now", "please", "again", "once", "more", "the", "key", "button", "clicky", "hey", "ok", "okay",
        "just", "and", "then", "also", "yeah", "yes", "so", "um", "uh", "that", "karo", "kar", "do", "na", "bhai", "ji"
    ]
    public static let maximumShortUtteranceWords = 4

    /// The owner asked for Return (or a send). `stepPressesReturn`: the step being
    /// decided is a Return (type enter:true or key return) — only then do the ASR
    /// look-alikes count.
    public static func ownerAsked(_ transcript: String, stepPressesReturn: Bool) -> Bool {
        if ActionWordMatch.containsWord(in: transcript, anyOf: explicitPhrases) { return true }
        guard stepPressesReturn else { return false }
        return matchesShortLookAlike(transcript)
    }

    static func matchesShortLookAlike(_ transcript: String) -> Bool {
        let words = ActionConfirmReply.normalizedWords(transcript)
        guard !words.isEmpty, words.count <= maximumShortUtteranceWords else { return false }
        for head in lookAlikeHeads where head.count <= words.count {
            for start in 0...(words.count - head.count) where Array(words[start..<(start + head.count)]) == head {
                let rest = words[..<start] + words[(start + head.count)...]
                if rest.allSatisfy({ shortFillerWords.contains($0) }) { return true }
            }
        }
        return false
    }
}

/// "Type it in Safari" keeps covering that Safari window for follow-ups.
public struct ActionSafariFollowUp: Equatable, Sendable {
    public static let lifetime: TimeInterval = 120

    public struct Grant: Equatable, Sendable {
        /// The Safari window (CGWindowID) he meant; nil = whichever Safari window (unknown then).
        public var windowIdentifier: UInt32?
        public var grantedAt: Date

        public init(windowIdentifier: UInt32?, grantedAt: Date) {
            self.windowIdentifier = windowIdentifier
            self.grantedAt = grantedAt
        }
    }

    public private(set) var grants: [Grant] = []

    public init(grants: [Grant] = []) {
        self.grants = grants
    }

    /// The owner named Safari (in a task or in conversation) while this window was Safari's front one.
    public mutating func noteOwnerNamedSafari(windowIdentifier: UInt32?, at date: Date) {
        grants.removeAll { $0.windowIdentifier == windowIdentifier || date.timeIntervalSince($0.grantedAt) > Self.lifetime }
        grants.append(Grant(windowIdentifier: windowIdentifier, grantedAt: date))
        if grants.count > 8 { grants.removeFirst(grants.count - 8) }
    }

    /// True when a recent naming covers this Safari target. Netflix windows only when he said Netflix now.
    public func covers(_ target: ActionTargetFacts, ownerNamedNetflix: Bool, at now: Date) -> Bool {
        guard ActionTierClassifier.isSafari(target) else { return false }
        if ActionTierClassifier.showsNetflix(target) && !ownerNamedNetflix { return false }
        return grants.contains { grant in
            let age = now.timeIntervalSince(grant.grantedAt)
            guard age >= 0, age <= Self.lifetime else { return false }
            guard let grantedWindow = grant.windowIdentifier else { return true }
            return target.windowIdentifier == grantedWindow
        }
    }
}

/// What runs in the front terminal tab (nil in facts = couldn't tell).
public enum ActionTerminalForeground: Equatable, Sendable {
    /// Claude Code's prompt: a chat box.
    case claudeCode
    /// A plain shell prompt.
    case shell
    /// Some other program (vim, top…).
    case otherCommand(String)
}
