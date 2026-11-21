//
//  TeamBuildOrder.swift
//  ClickyCore
//
//  How the CEO makes new bots and categories when the owner asks for them in chat. The CEO writes one ```team block
//  with JSON; the app takes it out of the shown answer, checks the owner's own words asked for new bots or categories,
//  and makes them. Pure parsing and rules only: the app's `BotsStore.buildTeamFromChat` does the making. The Windows and
//  Linux app has the same rules in `crossplatform/crates/theo-core/src/team_build.rs`.
//

import Foundation

public struct TeamBuildOrder: Equatable, Sendable {
    public struct NewCategory: Equatable, Sendable {
        public var name: String
        public var purpose: String?
        public init(name: String, purpose: String? = nil) {
            self.name = name
            self.purpose = purpose
        }
    }

    public struct NewBot: Equatable, Sendable {
        public var name: String
        /// One line on what it does: its description in the sidebar.
        public var does: String
        /// Its own instructions. Empty: Vello writes "You are <name>. <does>".
        public var instructions: String
        /// The category it joins, by name. Nil: it sits under "Other bots".
        public var category: String?
        public init(name: String, does: String, instructions: String = "", category: String? = nil) {
            self.name = name
            self.does = does
            self.instructions = instructions
            self.category = category
        }
    }

    public var categories: [NewCategory]
    public var bots: [NewBot]

    public init(categories: [NewCategory] = [], bots: [NewBot] = []) {
        self.categories = categories
        self.bots = bots
    }

    public var isEmpty: Bool { categories.isEmpty && bots.isEmpty }

    /// One owner message can't flood the sidebar: at most this many new bots and categories from one answer.
    public static let mostBots = 5
    public static let mostCategories = 3
    static let longestBotName = 40
    static let longestCategoryName = 80
    static let longestDoes = 200
    static let longestInstructions = 4000

    /// The answer without its ```team block, and the order the block holds (nil when there's none, or nothing usable in it).
    public static func extract(from text: String) -> (text: String, order: TeamBuildOrder?) {
        guard let start = text.range(of: "```team") else { return (text, nil) }
        let afterFence = text[start.upperBound...]
        // The fence's language must be exactly "team", not "teammates" or the like.
        if let next = afterFence.first, !next.isNewline, !next.isWhitespace { return (text, nil) }
        guard let end = afterFence.range(of: "```") else { return (text, nil) }
        let body = String(afterFence[..<end.lowerBound])
        let shown = (String(text[..<start.lowerBound]) + String(afterFence[end.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (shown, parse(body))
    }

    /// The JSON inside the block: {"categories": [{"name", "purpose"?}], "bots": [{"name", "does", "instructions"?, "category"?}]}.
    public static func parse(_ body: String) -> TeamBuildOrder? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        var order = TeamBuildOrder()
        for entry in object["categories"] as? [[String: Any]] ?? [] {
            guard let name = cleaned(entry["name"], longest: longestCategoryName) else { continue }
            guard !order.categories.contains(where: { sameName($0.name, name) }) else { continue }
            order.categories.append(NewCategory(name: name, purpose: cleaned(entry["purpose"], longest: longestDoes)))
        }
        for entry in object["bots"] as? [[String: Any]] ?? [] {
            guard let name = cleaned(entry["name"], longest: longestBotName) else { continue }
            guard !order.bots.contains(where: { sameName($0.name, name) }) else { continue }
            let does = cleaned(entry["does"] ?? entry["description"], longest: longestDoes) ?? ""
            let instructions = cleaned(entry["instructions"], longest: longestInstructions) ?? ""
            let category = cleaned(entry["category"], longest: longestCategoryName)
            order.bots.append(NewBot(name: name, does: does, instructions: instructions, category: category))
        }
        // A bot's category that the block didn't list is made too, so "a bot in a new Sales category" works in one go.
        for bot in order.bots {
            guard let category = bot.category, !order.categories.contains(where: { sameName($0.name, category) }) else { continue }
            order.categories.append(NewCategory(name: category))
        }
        order.categories = Array(order.categories.prefix(mostCategories))
        order.bots = Array(order.bots.prefix(mostBots))
        return order.isEmpty ? nil : order
    }

    /// The instructions a new bot starts with.
    public static func instructions(for bot: NewBot) -> String {
        if !bot.instructions.isEmpty { return bot.instructions }
        return bot.does.isEmpty ? "You are \(bot.name)." : "You are \(bot.name). \(bot.does)"
    }

    /// Names match without regard to case or spaces at the ends.
    public static func sameName(_ first: String, _ second: String) -> Bool {
        first.trimmingCharacters(in: .whitespaces).lowercased() == second.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func cleaned(_ value: Any?, longest: Int) -> String? {
        guard let text = value as? String else { return nil }
        let oneLine = longest > longestDoes ? text : text.replacingOccurrences(of: "\n", with: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(longest))
    }
}

/// Whether the owner's own words asked for new bots or categories. A block the CEO wrote without that (a page told it to,
/// a routine's run, another bot asked) is said in the chat and dropped, as a routine block is.
public enum TeamBuildIntent {
    public static func ownerAsked(_ text: String) -> Bool {
        guard !RoutineIntent.isRoutineRun(text) else { return false }
        let lower = text.lowercased()
        let things = #"(bots?|agents?|assistants?|categor(y|ies)|teams?|departments?|helpers?|employees?|members?)"#
        let patterns = [
            // "make a bot", "create two new agents", "add a Sales category", "set up a research team", "hire an assistant"
            #"\b(make|makes|making|made|create|creates|creating|add|adding|set\s+up|setup|build|start|spin\s+up|hire|need|want|get|give\s+me)\b[^.?!\n]{0,60}\b"# + things + #"\b"#,
            // "new bot", "new category", "another agent"
            #"\b(new|another|more|extra)\s+([a-z-]+\s+){0,3}"# + things + #"\b"#,
            // "a bot that writes posts", "a bot for my inbox", "an agent to sort mail"
            #"\b(a|an)\s+([a-z-]+\s+){0,3}(bot|agent|assistant)\s+(that|which|who|for|to)\b"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}
