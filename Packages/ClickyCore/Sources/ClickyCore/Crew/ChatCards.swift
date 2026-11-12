//
//  ChatCards.swift
//  ClickyCore
//
//  What a bot's message turns into, with no views: a long answer becomes a brief card, a [CHOOSE: …] tag a prompt card,
//  and a coding run's phase the five steps on its run card.
//

import Foundation

/// A long answer, plan or doc, read as an article.
public struct BriefCard: Equatable, Sendable {
    public let title: String
    public let excerpt: String
    public let sections: [String]
    public let minutes: Int
    /// "Brief", "Plan" or "Doc".
    public let kind: String

    /// Long enough, and with some structure: a heading or several paragraphs. Short chat answers stay chat.
    public static let minimumCharacters = 900

    public static func parse(_ text: String) -> BriefCard? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return nil }
        // Code and a run's prompt stay as they are; those have their own cards.
        guard !trimmed.contains("```prompt") else { return nil }
        let lines = trimmed.components(separatedBy: .newlines)
        var headings: [String] = []
        var paragraphs: [String] = []
        var inFence = false
        var body = ""
        for line in lines {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if clean.hasPrefix("#") {
                if !body.isEmpty { paragraphs.append(body); body = "" }
                headings.append(clean.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
            } else if clean.isEmpty {
                if !body.isEmpty { paragraphs.append(body); body = "" }
            } else if !clean.hasPrefix("-"), !clean.hasPrefix("*"), !clean.hasPrefix("|") {
                body += (body.isEmpty ? "" : " ") + clean
            }
        }
        if !body.isEmpty { paragraphs.append(body) }
        guard !headings.isEmpty || paragraphs.count >= 4 else { return nil }
        let opensWithTitle = lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("#") == true
        let title = opensWithTitle ? headings[0] : fallbackTitle(from: paragraphs.first ?? trimmed)
        let sections = Array((opensWithTitle ? Array(headings.dropFirst()) : headings).prefix(5))
        let words = trimmed.split { $0.isWhitespace }.count
        let lowered = title.lowercased()
        let kind = lowered.contains("plan") ? "Plan" : lowered.contains("doc") ? "Doc" : "Brief"
        return BriefCard(title: strip(title), excerpt: strip(paragraphs.first(where: { $0 != title }) ?? ""),
                         sections: sections.map(strip), minutes: max(1, Int((Double(words) / 220).rounded(.up))), kind: kind)
    }

    private static func fallbackTitle(from paragraph: String) -> String {
        let first = paragraph.split(whereSeparator: { ".!?:".contains($0) }).first.map(String.init) ?? paragraph
        let words = first.split(separator: " ")
        return words.count > 12 ? words.prefix(12).joined(separator: " ") + "…" : first
    }

    private static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "__", with: "")
    }
}

/// `[CHOOSE: How should each screen be split? | Side by side: Best for code | Stacked: Better for timelines]` in a bot's
/// message: one decision for the owner, with the options as tiles.
public struct BotCallPrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let title: String
        public let detail: String
    }

    public let question: String
    public let options: [Option]
    /// The message with the tag taken out.
    public let remainingText: String

    public static let autoPickMinutes = 10

    public static func parse(_ text: String) -> BotCallPrompt? {
        guard let open = text.range(of: "[CHOOSE:"), let close = text.range(of: "]", range: open.upperBound..<text.endIndex) else { return nil }
        let parts = text[open.upperBound..<close.lowerBound].split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 3, !parts[0].isEmpty else { return nil }
        let options = parts.dropFirst().prefix(4).compactMap { part -> Option? in
            guard !part.isEmpty else { return nil }
            guard let colon = part.firstIndex(of: ":") else { return Option(title: part, detail: "") }
            return Option(title: part[..<colon].trimmingCharacters(in: .whitespaces),
                          detail: part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        guard options.count >= 2 else { return nil }
        let rest = (text[..<open.lowerBound] + text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return BotCallPrompt(question: parts[0], options: options, remainingText: rest)
    }
}

/// The run card's bar: Branch, Code, Tests, Push, PR.
public enum RunSteps {
    public static let titles = ["Branch", "Code", "Tests", "Push", "PR"]

    /// Finished steps are green, the current one half green, a step waiting on the owner yellow, the step that failed red.
    public enum Fill: Equatable, Sendable { case done, active, todo, waiting, failed }

    /// `phase` is the run's, `stage` what it's doing while it reports ("tests", "push", "pr"). A stopped run shows how far it
    /// got without calling anything failed.
    public static func fills(phase: String, stage: String?, stopped: Bool = false) -> [Fill] {
        let current = ["tests": 2, "push": 3, "pr": 4][stage ?? ""] ?? 1
        switch phase {
        case "done": return Array(repeating: .done, count: 5)
        case "reporting":
            let active = ["tests": 2, "push": 3, "pr": 4][stage ?? "tests"] ?? 2
            return (0..<5).map { $0 < active ? .done : $0 == active ? .active : .todo }
        case "waiting":
            return (0..<5).map { $0 < current ? .done : $0 == current ? .waiting : .todo }
        case "failed":
            return (0..<5).map { $0 < current ? .done : $0 == current ? (stopped ? .todo : .failed) : .todo }
        default:
            return [.done, .active, .todo, .todo, .todo]
        }
    }
}
