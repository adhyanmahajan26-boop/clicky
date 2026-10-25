//
//  CodeModeToggle.swift
//  ClickyCore
//
//  The spoken Code-mode switch. Code mode (v2.code.enabled) stays off by
//  default; the main brain turns it on or off with a tag in its answer:
//    [CODEMODE:on]   the user asked for coding work, or said "turn on code mode"
//    [CODEMODE:off]  the user said "turn off code mode"
//  The tag is never spoken (ResponseRouter strips it). The app honours "on"
//  only when the user's own words ask for it (`userAskedForCoding`), so text
//  on screen can't switch Code mode on by itself. Turning it on changes no
//  gate: local edits still happen in a worktree and anything outward still
//  needs a click in the review panel.
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
        you can work on the user's code — answer questions about a local repo, make changes in an isolated git worktree, fix PR review comments or failing CI, and open PRs after they click approve — through clicky's code mode, which is off right now. never say you can't access their repo or code. when the user asks for coding work in a repo or project (including "this repo" or "this project" on screen), or says "turn on code mode", say one short line like "turning on code mode, one sec." and add [CODEMODE:on] at the end. the tag is never spoken. clicky turns code mode on and then handles the request.
        """

    /// The line added to the code section while Code mode is on.
    public static let onPromptLine = "code mode is on. if the user says \"turn off code mode\", say \"okay, code mode is off.\" and add [CODEMODE:off]."

    // MARK: - Deciding what to do with the tag

    private static let codingWords: Set<String> = [
        "code", "coding", "codemode", "repo", "repos", "repository", "project", "projects", "pr", "prs", "pull", "branch", "commit", "commits",
        "bug", "bugs", "fix", "test", "tests", "function", "functions", "file", "files", "refactor", "implement", "build", "ci", "merge",
        "review", "github", "worktree", "agent", "agents", "script", "class", "method", "compile", "error", "errors", "codebase", "studio",
        "rename", "feature", "edit", "change", "changes", "python", "swift", "javascript", "typescript", "rust", "go", "program"
    ]

    /// Lowercased words of [a-z0-9] runs.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The user's own words mention code mode or coding work. Only then is
    /// an [CODEMODE:on] tag honoured.
    public static func userAskedForCoding(_ transcript: String) -> Bool {
        let transcriptWords = words(transcript)
        if transcriptWords.contains(where: codingWords.contains) { return true }
        let joined = transcriptWords.joined(separator: " ")
        return joined.contains("code mode") || joined.contains("sub agent") || joined.contains("live code")
    }

    private static let togglePhraseWords: Set<String> = [
        "turn", "switch", "on", "off", "enable", "disable", "start", "activate", "code", "mode", "codemode", "please", "clicky", "hey", "can",
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
        /// "on" without the user asking for coding (e.g. text on screen): ignored.
        case refused
    }

    public static func decide(isOn requestedOn: Bool, isCurrentlyOn: Bool, transcript: String) -> Decision {
        if requestedOn == isCurrentlyOn { return .unchanged }
        if !requestedOn { return .turnOff }
        guard userAskedForCoding(transcript) else { return .refused }
        return .turnOn(continueRequest: shouldContinueRequest(afterTurningOn: transcript))
    }
}
