//
//  OwnerProfile.swift
//  ClickyCore
//
//  "About you": one file about the owner that every bot reads (Hermes's and OpenClaw's USER.md). The owner writes it in
//  Settings › About; a bot adds a fact with an `[ABOUT YOU: …]` line, only on a turn the owner's own words started.
//

import Foundation

public enum OwnerProfile {
    public static let fileName = "about-you.md"
    /// Characters that go into every prompt. Hermes keeps 1,375 for USER.md; this holds a little more.
    public static let limit = 3_000

    /// The section every bot's persona carries, right after its own instructions and nature. Over the limit, the start goes in.
    public static func section(_ text: String, path: String, owner: String) -> String {
        let who = OwnerName.isUnset(owner) ? "the owner" : owner
        let body = withoutComment(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let howTo = "When \(who) tells you something lasting about themselves (their work, the people around them, what they like, how they want answers), " +
            "end your reply with one line \(tagExample) and Vello adds it here for every bot. Only facts they told you; never secrets, keys or passwords."
        guard !body.isEmpty else {
            return "About \(who): nothing is saved yet (\(path), shared by every bot). " + howTo
        }
        let shown = body.count > limit ? String(body.prefix(limit)) + "\n[… cut at \(limit) characters …]" : body
        return "About \(who), shared by every bot (\(path)):\n<about-owner>\n\(shown)\n</about-owner>\n" + howTo
    }

    public static let tagExample = "[ABOUT YOU: one short fact]"

    /// `[ABOUT YOU: …]` lines taken out of a reply: the reply without them, and the facts, trimmed, empty ones left out.
    public static func extract(from reply: String) -> (text: String, facts: [String]) {
        var facts: [String] = []
        var kept: [String] = []
        for line in reply.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fact = fact(inLine: trimmed) {
                if !fact.isEmpty { facts.append(fact) }
                continue
            }
            kept.append(line)
        }
        guard !facts.isEmpty || kept.count != reply.components(separatedBy: "\n").count else { return (reply, []) }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), facts)
    }

    private static func fact(inLine line: String) -> String? {
        let upper = line.uppercased()
        guard upper.hasPrefix("[ABOUT YOU:") || upper.hasPrefix("[ABOUT ME:"), line.hasSuffix("]") else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let inside = line[line.index(after: colon)..<line.index(before: line.endIndex)]
        return String(inside.trimmingCharacters(in: .whitespaces).prefix(300))
    }

    public enum Addition: Equatable, Sendable {
        /// The new text, and the facts that went in.
        case added(text: String, facts: [String])
        /// Every fact was already there.
        case alreadyKnown
        /// It would go over the limit: nothing was added.
        case full
    }

    /// The file with the facts added as "- " lines at its end, each only once (any case, any punctuation at the end).
    public static func adding(_ facts: [String], to text: String) -> Addition {
        let existing = Set(text.components(separatedBy: "\n").map(normalised))
        var seen = existing
        var new: [String] = []
        for fact in facts {
            let key = normalised(fact)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            new.append(fact)
        }
        guard !new.isEmpty else { return .alreadyKnown }
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty { result += "\n" }
        result += new.map { "- " + $0 }.joined(separator: "\n") + "\n"
        guard withoutComment(result).count <= limit else { return .full }
        return .added(text: result, facts: new)
    }

    /// The note the chat shows when a bot added to the profile, so the owner sees what was saved and where to change it.
    public static func addedNote(facts: [String]) -> String {
        let list = facts.map { "\"\($0)\"" }.joined(separator: ", ")
        return "Saved to About you, which every bot reads: \(list). Change or remove it in Settings › About."
    }

    public static let fullNote = "About you is full, so nothing new was saved. Tidy it in Settings › About."

    /// What a new file starts with: a comment saying what it's for, which bots never see.
    public static let newFile = "<!-- About you: every bot reads this. Write what they should know about you, one line each. -->\n"

    /// The text without a first-line `<!-- … -->` comment.
    public static func withoutComment(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("<!--"), first.hasSuffix("-->") else { return text }
        return lines.dropFirst().joined(separator: "\n")
    }

    static func normalised(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("- ") || text.hasPrefix("* ") { text = String(text.dropFirst(2)) }
        while let last = text.last, ".!;,".contains(last) { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
