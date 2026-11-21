//
//  TeamBuildOrder.swift
//  ClickyCore
//
//  How the CEO makes new bots, categories and group chats, picks managers, moves bots between categories, and renames a
//  bot or changes its instructions, description, model or memory, when the owner asks for it in chat. The CEO writes one ```team block
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
        /// Its own instructions. Empty: Vello writes "You are <name>. <does>". For a bot that exists, given ones replace its own.
        public var instructions: String
        /// The category it joins, by name (a bot that already exists is moved there). Nil: it sits under "Other bots".
        public var category: String?
        /// The model it runs on, as the owner or the CEO said it ("haiku", "Claude Opus 5.5", an exact id). Nil: the brain's
        /// usual starting model, or, for a bot that already exists, the model it has. Matched by `TeamBuildBrains`.
        public var model: String?
        /// The brain it runs on ("Claude Code", "Codex", "OpenAI"). Nil: the maker's own brain, or one that has `model`.
        public var brain: String?
        /// A bot that exists gets this name instead ("rename"). Ignored for a new bot.
        public var newName: String?
        /// What it should remember: a new bot's memory file starts with it, a bot that exists has it added to its own (unless
        /// its memory already holds it).
        public var memory: String?
        public init(name: String, does: String, instructions: String = "", category: String? = nil, model: String? = nil,
                    brain: String? = nil, newName: String? = nil, memory: String? = nil) {
            self.name = name
            self.does = does
            self.instructions = instructions
            self.category = category
            self.model = model
            self.brain = brain
            self.newName = newName
            self.memory = memory
        }
    }

    /// A group chat: bots talking in one room, the head reading the owner's message first and wrapping up. One that exists
    /// (by name) gets the head named and the members listed added.
    public struct NewGroup: Equatable, Sendable {
        public var name: String
        /// The bot at its head, by name. Nil: the first member. Two to six bots in all.
        public var head: String?
        /// Its other bots, by name.
        public var members: [String]
        public init(name: String, head: String? = nil, members: [String] = []) {
            self.name = name
            self.head = head
            self.members = members
        }
    }

    public var categories: [NewCategory]
    public var bots: [NewBot]
    public var groups: [NewGroup]

    public init(categories: [NewCategory] = [], bots: [NewBot] = [], groups: [NewGroup] = []) {
        self.categories = categories
        self.bots = bots
        self.groups = groups
    }

    public var isEmpty: Bool { categories.isEmpty && bots.isEmpty && groups.isEmpty }

    /// One owner message can't flood the sidebar: at most this many new bots and categories from one answer. Enough for a
    /// manager and a squad of workers in one go.
    public static let mostBots = 20
    public static let mostCategories = 6
    public static let mostGroups = 6
    /// A group chat's bots, its head included: two to six, as the New group sheet allows.
    public static let mostGroupMembers = 6
    public static let fewestGroupMembers = 2
    static let longestBotName = 80
    static let longestCategoryName = 80
    static let longestDoes = 200
    /// Long enough for a whole playbook: a bot's instructions go into its prompt as they are.
    public static let longestInstructions = 30000
    public static let longestMemory = 20000
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
    /// "category"?, "model"?, "brain"?, "rename"?, "memory"?}], "groups": [{"name", "head"?, "members"}]}.
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
            let newName = cleaned(entry["rename"] ?? entry["newName"] ?? entry["new_name"], longest: longestBotName)
                .flatMap { sameName($0, name) ? nil : $0 }
            let memory = cleaned(entry["memory"], longest: longestMemory)
            order.bots.append(NewBot(name: name, does: does, instructions: instructions, category: category, model: model, brain: brain,
                                     newName: newName, memory: memory))
        }
        for entry in object["groups"] as? [[String: Any]] ?? [] {
            guard let name = cleaned(entry["name"], longest: longestCategoryName) else { continue }
            guard !order.groups.contains(where: { sameName($0.name, name) }) else { continue }
            let head = cleaned(entry["head"] ?? entry["lead"], longest: longestBotName)
            var members: [String] = []
            for member in (entry["members"] as? [Any] ?? []).compactMap({ cleaned($0, longest: longestBotName) }) {
                guard !members.contains(where: { sameName($0, member) }), !(head.map { sameName($0, member) } ?? false) else { continue }
                members.append(member)
            }
            members = Array(members.prefix(head == nil ? mostGroupMembers : mostGroupMembers - 1))
            guard members.count + (head == nil ? 0 : 1) >= fewestGroupMembers else { continue }
            order.groups.append(NewGroup(name: name, head: head, members: members))
        }
        // A bot's category that the block didn't list is made too, so "a bot in a new Sales category" works in one go.
        for bot in order.bots {
            guard let category = bot.category, !order.categories.contains(where: { sameName($0.name, category) }) else { continue }
            order.categories.append(NewCategory(name: category))
        }
        order.categories = Array(order.categories.prefix(mostCategories))
        order.bots = Array(order.bots.prefix(mostBots))
        order.groups = Array(order.groups.prefix(mostGroups))
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
        if categoryOrder.count == 1 {
            guard let category = categoryOrder[0] else { return "Vello made \(made.count) bots: \(names(in: nil))." }
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

    /// `memory` with `added` at its end, or nil when it already holds it (so saying it twice doesn't write it twice).
    public static func memory(_ memory: String, adding added: String) -> String? {
        let wanted = added.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !memory.contains(wanted) else { return nil }
        let kept = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? wanted + "\n" : kept + "\n\n" + wanted + "\n"
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
        let things = #"(bots?|agents?|assistants?|categor(y|ies)|teams?|departments?|helpers?|employees?|members?|group\s*chats?|groups?)"#
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
            // "rename Rex to Max", "call Penny 'Ledger' from now on"
            #"\b(rename|renames|renaming|re-name)\b"#,
            #"\b(call|name)\s+\w+[^.?!\n]{0,40}\b(instead|from\s+now\s+on)\b"#,
            // "change Rex's instructions", "give Ada a better prompt", "update the digger's description"
            #"\b(set|change|changes|update|updates|replace|rewrite|rewrites|edit|edits|give|fix|improve|improves|write|tweak|tune)\b[^.?!\n]{0,60}\b(instructions?|prompts?|system\s+prompts?|descriptions?|persona)\b"#,
            // "save this to Rex's memory", "Ada should remember that", "add the sources to their memory"
            #"\b(save|saves|add|adds|write|writes|put|store|stores|set|give|seed|update)\b[^.?!\n]{0,60}\b(memory|memories)\b"#,
            #"\b(should|to|must|always)\s+remember\b"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}
