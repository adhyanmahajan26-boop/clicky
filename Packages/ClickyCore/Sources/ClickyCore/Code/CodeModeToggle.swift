//
//  CodeModeToggle.swift
//  ClickyCore
//
//  The spoken Code-mode switch. Code mode (v2.code.enabled) stays off by
//  default; the main brain turns it on or off with a tag in its answer:
//    [CODEMODE:on]   the user said "turn on code mode" (or asked for coding work)
//    [CODEMODE:off]  the user said "turn off code mode"
//  The tag is never spoken (ResponseRouter strips it). The app honours "on"
//  only when the user's own words ask for it, so text
//  on screen can't switch Code mode on by itself. Turning it on changes no
//  gate: local edits still happen in a worktree and anything outward still
//  needs a click in the review panel.
//  "Asks for it" is strict: the transcript of that turn must say "code
//  mode" / "coding mode" (`transcriptMentionsCodeMode`, with a few ASR near
//  misses). A tag without those words is refused, logged, and the app shows
//  a small "Turn on code mode" chip that only a real mouse click turns on
//  (CodeModeChipGate).
//

import Foundation

public enum CodeModeToggle {
    /// The exact tags the prompt asks for.
    public static let onTag = "[CODEMODE:on]"
    public static let offTag = "[CODEMODE:off]"

    /// "[CODEMODE:on]" → true, "[ codemode: OFF ]" → false; anything else → nil.
    public static func parse(_ rawTag: String) -> Bool? {
        var body = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("["), body.hasSuffix("]") else { return nil }
        body = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard body.uppercased().hasPrefix("CODEMODE:") else { return nil }
        let value = body.dropFirst("CODEMODE:".count).trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// The compact line that is always in the prompt while Code mode is off,
    /// so Claude never answers "I can't access your repo".
    public static let offPromptLine = """
        code mode:
        you can work on the user's code — answer questions about a local repo, make changes in an isolated git worktree, fix PR review comments or failing CI, and open PRs after they click approve — through clicky's code mode, which is off right now. never say you can't access their repo or code. when the user asks for coding work in a repo or project (including "this repo" or "this project" on screen), or says "turn on code mode", add [CODEMODE:on] at the end. if their words say "code mode" (e.g. "turn on code mode"), say one short line like "turning on code mode, one sec."; clicky turns it on and then handles the request. otherwise say one short line like "that needs code mode. click turn on code mode, or say turn on code mode." — clicky only switches it on when the user says "code mode" or clicks. the tag is never spoken.
        """

    /// The line added to the code section while Code mode is on.
    public static let onPromptLine = "code mode is on. if the user says \"turn off code mode\", say \"okay, code mode is off.\" and add [CODEMODE:off]."

    // MARK: - Deciding what to do with the tag

    /// First word of a spoken "code mode" (with the ASR mishearings seen in practice).
    private static let codeModeFirstWords: Set<String> = ["code", "coding", "codeing", "cold", "coat", "kode", "koding"]
    /// Second word.
    private static let codeModeSecondWords: Set<String> = ["mode", "mod", "modes"]
    /// The phrase run together by the recogniser.
    private static let codeModeJoinedWords: Set<String> = ["codemode", "codingmode", "codemodes", "coldmode", "coatmode", "kodemode"]

    /// Lowercased words of [a-z0-9] runs.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The transcript without anything that looks like a Clicky tag
    /// ("[CODEMODE:on]", "[POINT:…]"): speech never contains brackets, so a
    /// tag in the transcript can only be pasted or injected text.
    static func withoutTags(_ transcript: String) -> String {
        transcript.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
    }

    /// True only when the user's own words say "code mode" or "coding mode"
    /// (also "code-mode", "codemode", and the near misses "cold mode",
    /// "coat mode", "coding mod"). Words about coding alone ("fix this
    /// bug", "code"), "decode more", and anything that was only on screen
    /// never count. Only the spoken transcript of that turn is passed here.
    public static func transcriptMentionsCodeMode(_ transcript: String) -> Bool {
        let transcriptWords = words(withoutTags(transcript))
        if transcriptWords.contains(where: codeModeJoinedWords.contains) { return true }
        for (firstWord, secondWord) in zip(transcriptWords, transcriptWords.dropFirst())
        where codeModeFirstWords.contains(firstWord) && codeModeSecondWords.contains(secondWord) {
            return true
        }
        return false
    }

    private static let togglePhraseWords: Set<String> = [
        "turn", "switch", "on", "off", "enable", "disable", "start", "activate", "code", "coding", "cold", "coat", "mod", "mode", "codemode", "codingmode", "please", "clicky", "hey", "can",
        "you", "could", "would", "the", "now", "ok", "okay", "go", "into", "to", "put", "me", "in", "get", "and", "just", "for"
    ]

    /// True when the transcript asks for more than the switch itself
    /// ("turn on code mode and fix utils.py"), so the request is run again
    /// once Code mode is on. "turn on code mode" alone → false.
    public static func shouldContinueRequest(afterTurningOn transcript: String) -> Bool {
        let remainingWords = words(transcript).filter { !togglePhraseWords.contains($0) }
        return remainingWords.count >= 2
    }

    /// What Clicky does with one tag.
    public enum Decision: Equatable, Sendable {
        /// Switch on (persist v2.code.enabled = true); `continueRequest`: ask Claude the same thing again with Code mode on.
        case turnOn(continueRequest: Bool)
        case turnOff
        /// Already in that state: nothing to do.
        case unchanged
        /// "on" without the user saying "code mode": not switched on. The app
        /// offers a one-click "Turn on code mode" chip instead (a real click only).
        case refused
    }

    public static func decide(isOn requestedOn: Bool, isCurrentlyOn: Bool, transcript: String) -> Decision {
        if requestedOn == isCurrentlyOn { return .unchanged }
        if !requestedOn { return .turnOff }
        guard transcriptMentionsCodeMode(transcript) else { return .refused }
        return .turnOn(continueRequest: shouldContinueRequest(afterTurningOn: transcript))
    }
}
