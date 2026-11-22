//
//  TeamBuildOrder.swift
//  ClickyCore
//
//  How the CEO makes new bots and categories, picks their managers and moves bots between them, when the owner asks
//  for it in chat. The CEO writes one ```team block
//  with JSON; the app takes it out of the shown answer, checks the owner's own words asked for new bots or categories,
//  and makes them. Pure parsing and rules only: the app's `BotsStore.buildTeamFromChat` does the making. The Windows and
//  Linux app has the same rules in `crossplatform/crates/theo-core/src/team_build.rs`.
//

import Foundation

public struct TeamBuildOrder: Equatable, Sendable {
    public struct NewCategory: Equatable, Sendable {
        public var name: String
        public var purpose: String?
        /// The bot who manages it, by name, or `noManager` for everyone reporting to the CEO. Nil: left as it is.
        public var manager: String?
        public init(name: String, purpose: String? = nil, manager: String? = nil) {
            self.name = name
            self.purpose = purpose
            self.manager = manager
        }

        /// The manager a category is given when it should have none.
        public static let noManager = "none"
        public var wantsNoManager: Bool { manager.map { TeamBuildOrder.sameName($0, Self.noManager) } ?? false }
    }

    public struct NewBot: Equatable, Sendable {
        public var name: String
        /// One line on what it does: its description in the sidebar.
        public var does: String
        /// Its own instructions. Empty: Vello writes "You are <name>. <does>".
        public var instructions: String
        /// The category it joins, by name (a bot that already exists is moved there). Nil: it sits under "Other bots".
        public var category: String?
        /// The model it runs on, as the owner or the CEO said it ("haiku", "Claude Opus 5.5", an exact id). Nil: the brain's
        /// usual starting model, or, for a bot that already exists, the model it has. Matched by `TeamBuildBrains`.
        public var model: String?
        /// The brain it runs on ("Claude Code", "Codex", "OpenAI"). Nil: the maker's own brain, or one that has `model`.
        public var brain: String?
        public init(name: String, does: String, instructions: String = "", category: String? = nil, model: String? = nil, brain: String? = nil) {
            self.name = name
            self.does = does
            self.instructions = instructions
            self.category = category
            self.model = model
            self.brain = brain
        }
    }

    public var categories: [NewCategory]
    public var bots: [NewBot]
    /// Ready-made teams to add whole, by name ("Research Desk"): `ReadyMadeTeams.expanding` turns each into its category
    /// and bots.
    public var readyMadeTeams: [String]

    public init(categories: [NewCategory] = [], bots: [NewBot] = [], readyMadeTeams: [String] = []) {
        self.categories = categories
        self.bots = bots
        self.readyMadeTeams = readyMadeTeams
    }

    public var isEmpty: Bool { categories.isEmpty && bots.isEmpty && readyMadeTeams.isEmpty }

    /// One owner message can't flood the sidebar: at most this many new bots and categories from one answer. Enough for a
    /// manager and a squad of workers in one go.
    public static let mostBots = 20
    public static let mostCategories = 6
    static let longestBotName = 40
    static let longestCategoryName = 80
    static let longestDoes = 200
    static let longestInstructions = 4000
    static let longestModelWords = 80

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

    /// The JSON inside the block: {"categories": [{"name", "purpose"?, "manager"?}], "bots": [{"name", "does", "instructions"?,
    /// "category"?, "model"?, "brain"?}], "teams": ["a ready-made team's name"]}.
    public static func parse(_ body: String) -> TeamBuildOrder? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        var order = TeamBuildOrder()
        for entry in object["categories"] as? [[String: Any]] ?? [] {
            guard let name = cleaned(entry["name"], longest: longestCategoryName) else { continue }
            guard !order.categories.contains(where: { sameName($0.name, name) }) else { continue }
            order.categories.append(NewCategory(name: name, purpose: cleaned(entry["purpose"], longest: longestDoes),
                                                manager: cleaned(entry["manager"], longest: longestBotName)))
        }
        for entry in object["bots"] as? [[String: Any]] ?? [] {
            guard let name = cleaned(entry["name"], longest: longestBotName) else { continue }
            guard !order.bots.contains(where: { sameName($0.name, name) }) else { continue }
            let does = cleaned(entry["does"] ?? entry["description"], longest: longestDoes) ?? ""
            let instructions = cleaned(entry["instructions"], longest: longestInstructions) ?? ""
            let category = cleaned(entry["category"], longest: longestCategoryName)
            let model = cleaned(entry["model"], longest: longestModelWords)
            let brain = cleaned(entry["brain"] ?? entry["engine"], longest: longestModelWords)
            order.bots.append(NewBot(name: name, does: does, instructions: instructions, category: category, model: model, brain: brain))
        }
        // A bot's category that the block didn't list is made too, so "a bot in a new Sales category" works in one go.
        for bot in order.bots {
            guard let category = bot.category, !order.categories.contains(where: { sameName($0.name, category) }) else { continue }
            order.categories.append(NewCategory(name: category))
        }
        // Ready-made teams by name, or as {"name": …}.
        for entry in object["teams"] as? [Any] ?? [] {
            let named: Any = (entry as? [String: Any])?["name"] ?? entry
            guard let name = cleaned(named, longest: longestCategoryName),
                  !order.readyMadeTeams.contains(where: { sameName($0, name) }) else { continue }
            order.readyMadeTeams.append(name)
        }
        order.categories = Array(order.categories.prefix(mostCategories))
        order.bots = Array(order.bots.prefix(mostBots))
        order.readyMadeTeams = Array(order.readyMadeTeams.prefix(ReadyMadeTeams.mostTeamsAtOnce))
        return order.isEmpty ? nil : order
    }

    /// One bot made from a block, for Vello's note: its name, its category's name and the words for its model ("Claude
    /// Haiku 5.5"; empty when no model was asked for).
    public struct MadeBot: Equatable, Sendable {
        public var name: String
        public var category: String?
        public var modelWords: String
        public init(name: String, category: String? = nil, modelWords: String = "") {
            self.name = name
            self.category = category
            self.modelWords = modelWords
        }
    }

    /// "Vello made the bot Rex in Sales." or, for many, grouped so a squad reads in one line: "Vello made 11 bots in Super
    /// Digger Squad: Digger Boss on Claude Opus 5.5; Digger 1, … and Digger 10 on Claude Haiku 5.5."
    public static func madeBotsSentence(_ made: [MadeBot]) -> String {
        guard made.count > 1 else {
            guard let only = made.first else { return "" }
            return "Vello made the bot \(only.name)" + (only.category.map { " in \($0)" } ?? "") + (only.modelWords.isEmpty ? "" : " on \(only.modelWords)") + "."
        }
        // In the order they came: categories, then models within each.
        var categoryOrder: [String?] = []
        for bot in made where !categoryOrder.contains(where: { $0 == bot.category }) { categoryOrder.append(bot.category) }
        func names(in category: String?) -> String {
            let members = made.filter { $0.category == category }
            var modelOrder: [String] = []
            for bot in members where !modelOrder.contains(bot.modelWords) { modelOrder.append(bot.modelWords) }
            return modelOrder.map { model in
                listedInWords(members.filter { $0.modelWords == model }.map(\.name)) + (model.isEmpty ? "" : " on \(model)")
            }.joined(separator: "; ")
        }
        if categoryOrder.count == 1, let category = categoryOrder[0] {
            return "Vello made \(made.count) bots in \(category): \(names(in: category))."
        }
        let parts = categoryOrder.map { category in category.map { "in \($0), \(names(in: $0))" } ?? "outside any category, \(names(in: nil))" }
        return "Vello made \(made.count) bots: " + parts.joined(separator: "; ") + "."
    }

    /// "A", "A and B", "A, B and C".
    public static func listedInWords(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
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
        let things = #"(bots?|agents?|assistants?|categor(y|ies)|teams?|departments?|helpers?|employees?|members?|squads?|crews?|desks?|studios?|office)"#
        let patterns = [
            // "make a bot", "create two new agents", "add a Sales category", "set up a research team", "hire an assistant"
            #"\b(make|makes|making|made|create|creates|creating|add|adding|set\s+up|setup|build|start|spin\s+up|hire|need|want|get|give\s+me)\b[^.?!\n]{0,60}\b"# + things + #"\b"#,
            // "new bot", "new category", "another agent"
            #"\b(new|another|more|extra)\s+([a-z-]+\s+){0,3}"# + things + #"\b"#,
            // "a bot that writes posts", "a bot for my inbox", "an agent to sort mail"
            #"\b(a|an)\s+([a-z-]+\s+){0,3}(bot|agent|assistant)\s+(that|which|who|for|to)\b"#,
            // "make Penny the manager of Growth", "put Ada in charge of Sales", "Rex should lead the team"
            #"\b(make|set|put|assign|appoint|promote|let|turn|have|change|switch)\b[^.?!\n]{0,60}\b(manager|lead|head|boss|in\s+charge)\b"#,
            #"\b(should|to|will|can)\s+(manage|lead|head|run)\b"#,
            #"\bno\s+(manager|lead|boss)\b"#,
            // "move Penny to Sales", "put Rex into Growth"
            #"\b(move|put|file|shift|transfer)\b[^.?!\n]{0,60}\b(to|into|under|in)\b"#,
            // "switch Rex to Haiku", "Penny should use Opus", "run the workers on Codex"
            #"\b(set|switch|change|move|put|use|uses|using|run|runs|make|give)\b[^.?!\n]{0,60}\b(models?|brains?|opus|sonnet|haiku|fable|gpt[-\w.]*|gemini|grok|codex|cursor|opencode|claude)\b"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}
