//
//  ReadyMadeTeams.swift
//  ClickyCore
//
//  Ready-made teams: a whole category at once, a manager and the bots who report to it, added in one click from
//  Settings › Bot teams or by asking the CEO in chat. Vello ships a few (`builtIn`, from `ReadyMadeTeamsCatalog`); the
//  owner can change any of them, make their own, save a category they already have as one, and pass them around as a
//  file. Adding one goes through the same `TeamBuildOrder` a ```team block does, so the bots are made exactly as the CEO
//  makes them. Pure rules only: the app's `ReadyMadeTeamLibrary` keeps the owner's changes and `BotsStore.addReadyMadeTeam`
//  makes the bots. The Windows and Linux app has the same rules in `crossplatform/crates/theo-core/src/ready_teams.rs`.
//

import Foundation

public struct ReadyMadeTeam: Codable, Equatable, Identifiable, Sendable {
    /// One bot on the team, as it'll be made.
    public struct Member: Codable, Equatable, Sendable {
        public var name: String
        /// One line on its job: its description in the sidebar.
        public var does: String
        /// Its own instructions. Empty: Vello writes "You are <name>. <does>".
        public var instructions: String
        /// The model it runs on, in the words a ```team block takes ("haiku", "Claude Opus 5.5"). Nil: the usual model.
        public var model: String?
        /// The brain it runs on ("Claude Code", "Codex", "OpenAI"). Nil: the CEO's brain.
        public var brain: String?

        public init(name: String, does: String, instructions: String = "", model: String? = nil, brain: String? = nil) {
            self.name = name
            self.does = does
            self.instructions = instructions
            self.model = model
            self.brain = brain
        }
    }

    /// Stays the same when the team is renamed: a built-in team's id says which one the owner changed.
    public var id: String
    public var name: String
    /// One line on what the team is for. It's the category's purpose.
    public var purpose: String
    public var manager: Member
    public var workers: [Member]

    public init(id: String, name: String, purpose: String, manager: Member, workers: [Member]) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.manager = manager
        self.workers = workers
    }

    /// The manager first, then the bots who report to it.
    public var members: [Member] { [manager] + workers }
}

public enum ReadyMadeTeams {
    /// A team is one category: its manager and at most this many bots under it, as many as one ```team block may make.
    public static let mostWorkers = TeamBuildOrder.mostBots - 1
    /// At most this many ready-made teams from one answer in chat, as many categories as a block may make.
    public static let mostTeamsAtOnce = TeamBuildOrder.mostCategories

    /// The teams Vello ships with, in the order Settings shows them.
    public static let builtIn: [ReadyMadeTeam] = {
        guard let file = try? JSONDecoder().decode(TeamsFile.self, from: Data(catalogJSON.utf8)) else { return [] }
        return file.teams
    }()

    public static func isBuiltIn(_ id: String) -> Bool { builtIn.contains { $0.id == id } }

    /// The built-in team with that id as Vello ships it, for Reset.
    public static func original(_ id: String) -> ReadyMadeTeam? { builtIn.first { $0.id == id } }

    // MARK: - The owner's library

    /// What the owner changed, as it's saved: their versions of built-in teams (same id), their own teams, and the built-in
    /// teams they removed.
    public struct Saved: Codable, Equatable, Sendable {
        public var teams: [ReadyMadeTeam]
        public var hiddenBuiltInIDs: [String]
        public init(teams: [ReadyMadeTeam] = [], hiddenBuiltInIDs: [String] = []) {
            self.teams = teams
            self.hiddenBuiltInIDs = hiddenBuiltInIDs
        }
    }

    /// The teams Settings lists: the built-in ones in Vello's order (the owner's version where they changed one, none they
    /// removed), then the owner's own in the order they were made.
    public static func library(_ saved: Saved) -> [ReadyMadeTeam] {
        let shipped = builtIn.compactMap { team -> ReadyMadeTeam? in
            if saved.hiddenBuiltInIDs.contains(team.id) { return nil }
            return saved.teams.first { $0.id == team.id } ?? team
        }
        return shipped + saved.teams.filter { !isBuiltIn($0.id) }
    }

    /// Whether the owner changed this built-in team from how Vello ships it.
    public static func isChanged(_ team: ReadyMadeTeam) -> Bool {
        guard let original = original(team.id) else { return false }
        return original != team
    }

    /// `saved` with `team` kept: a built-in team the same as Vello's is just Vello's again.
    public static func saving(_ team: ReadyMadeTeam, into saved: Saved) -> Saved {
        var result = saved
        result.hiddenBuiltInIDs.removeAll { $0 == team.id }
        if let index = result.teams.firstIndex(where: { $0.id == team.id }) {
            result.teams[index] = team
        } else {
            result.teams.append(team)
        }
        if let original = original(team.id), original == team { result.teams.removeAll { $0.id == team.id } }
        return result
    }

    /// `saved` without the team: the owner's own team goes, and a built-in one is hidden until it's put back.
    public static func removing(_ id: String, from saved: Saved) -> Saved {
        var result = saved
        result.teams.removeAll { $0.id == id }
        if isBuiltIn(id), !result.hiddenBuiltInIDs.contains(id) { result.hiddenBuiltInIDs.append(id) }
        return result
    }

    /// `saved` with a built-in team as Vello ships it again, shown again if it was removed.
    public static func resetting(_ id: String, in saved: Saved) -> Saved {
        var result = saved
        result.teams.removeAll { $0.id == id }
        result.hiddenBuiltInIDs.removeAll { $0 == id }
        return result
    }

    /// `saved` with every built-in team shown and as Vello ships it; the owner's own teams stay.
    public static func restoringBuiltIns(in saved: Saved) -> Saved {
        Saved(teams: saved.teams.filter { !isBuiltIn($0.id) }, hiddenBuiltInIDs: [])
    }

    /// A new id for an owner's team, not used by any team in `library`.
    public static func newID(for name: String, among library: [ReadyMadeTeam]) -> String {
        let slug = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let base = "own-" + (slug.isEmpty ? "team" : String(slug.prefix(40)))
        var candidate = base
        var number = 2
        while library.contains(where: { $0.id == candidate }) || isBuiltIn(candidate) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    // MARK: - Checking and tidying

    /// The team with every field trimmed and cut to the lengths a ```team block keeps, and empty bots left out.
    public static func tidied(_ team: ReadyMadeTeam) -> ReadyMadeTeam {
        func tidy(_ member: ReadyMadeTeam.Member) -> ReadyMadeTeam.Member {
            ReadyMadeTeam.Member(name: oneLine(member.name, longest: TeamBuildOrder.longestBotName),
                                 does: oneLine(member.does, longest: TeamBuildOrder.longestDoes),
                                 instructions: String(member.instructions.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TeamBuildOrder.longestInstructions)),
                                 model: member.model.map { oneLine($0, longest: TeamBuildOrder.longestModelWords) }.flatMap { $0.isEmpty ? nil : $0 },
                                 brain: member.brain.map { oneLine($0, longest: TeamBuildOrder.longestModelWords) }.flatMap { $0.isEmpty ? nil : $0 })
        }
        let workers = team.workers.map(tidy).filter { !$0.name.isEmpty || !$0.does.isEmpty || !$0.instructions.isEmpty }
        return ReadyMadeTeam(id: team.id, name: oneLine(team.name, longest: TeamBuildOrder.longestCategoryName),
                             purpose: oneLine(team.purpose, longest: TeamBuildOrder.longestDoes),
                             manager: tidy(team.manager), workers: workers)
    }

    /// What's wrong with a team before it can be saved or added, in a sentence; nil when it's fine.
    public static func problem(with team: ReadyMadeTeam) -> String? {
        let team = tidied(team)
        if team.name.isEmpty { return "Give the team a name." }
        if team.manager.name.isEmpty { return "Give the manager a name." }
        if let unnamed = team.workers.firstIndex(where: { $0.name.isEmpty }) { return "Bot \(unnamed + 1) needs a name." }
        if team.workers.count > mostWorkers { return "A team can have at most \(mostWorkers) bots under its manager." }
        var seen: [String] = []
        for member in team.members {
            if seen.contains(where: { TeamBuildOrder.sameName($0, member.name) }) { return "Two bots are called \(member.name). Give each its own name." }
            seen.append(member.name)
        }
        for member in team.members where reservedNames.contains(where: { TeamBuildOrder.sameName($0, member.name) }) {
            return "\(member.name) is a name Vello keeps for itself. Pick another."
        }
        return nil
    }

    /// Names a ready-made bot can't take: Vello and Pointer Assistant themselves.
    static let reservedNames = ["Vello", "Theo", "Pointer Assistant", "Clicky"]

    // MARK: - Adding a team

    /// The ```team order that makes `team` as a new category with its manager and bots. A name that's taken (a category or
    /// bot already in the sidebar) gets a number ("Research Desk 2", "Web Scout 2"), so adding a team never moves or changes
    /// a bot the owner already has, and adding the same team twice makes a second copy.
    public static func order(for team: ReadyMadeTeam, existingBotNames: [String], existingCategoryNames: [String]) -> TeamBuildOrder {
        let team = tidied(team)
        let categoryName = uniqueName(team.name, taken: existingCategoryNames, longest: TeamBuildOrder.longestCategoryName)
        var takenBotNames = existingBotNames + reservedNames
        var names: [String] = []
        for member in team.members {
            let name = uniqueName(member.name, taken: takenBotNames, longest: TeamBuildOrder.longestBotName)
            takenBotNames.append(name)
            names.append(name)
        }
        // Every name that got a number changes in every bot's instructions, so a second Research Lead tells the second Web
        // Scout, not the first.
        var renames = zip(team.members.map(\.name), names).filter { $0.0 != $0.1 }.map { (old: $0.0, new: $0.1) }
        if categoryName != team.name { renames.append((old: team.name, new: categoryName)) }
        let bots = zip(team.members, names).map { member, name in
            TeamBuildOrder.NewBot(name: name, does: member.does, instructions: renamed(member.instructions, renames: renames),
                                  category: categoryName, model: member.model, brain: member.brain)
        }
        let managerName = names.first ?? team.manager.name
        return TeamBuildOrder(categories: [TeamBuildOrder.NewCategory(name: categoryName, purpose: team.purpose.isEmpty ? nil : team.purpose, manager: managerName)],
                              bots: bots)
    }

    /// A ```team block's order with the ready-made teams it named added in: each one's category and bots, named so they
    /// don't clash with what's there or with each other. `missing` holds the names no team in `library` has.
    public static func expanding(_ order: TeamBuildOrder, library: [ReadyMadeTeam], existingBotNames: [String],
                                 existingCategoryNames: [String]) -> (order: TeamBuildOrder, missing: [String]) {
        guard !order.readyMadeTeams.isEmpty else { return (order, []) }
        var result = order
        result.readyMadeTeams = []
        var missing: [String] = []
        var botNames = existingBotNames + order.bots.map(\.name)
        var categoryNames = existingCategoryNames + order.categories.map(\.name)
        for wanted in order.readyMadeTeams {
            guard let team = find(wanted, in: library) else { missing.append(wanted); continue }
            let made = self.order(for: team, existingBotNames: botNames, existingCategoryNames: categoryNames)
            result.categories += made.categories
            result.bots += made.bots
            botNames += made.bots.map(\.name)
            categoryNames += made.categories.map(\.name)
        }
        return (result, missing)
    }

    /// The team a name or id asks for: its name, its id, or its name without a leading "the" or a trailing "team".
    public static func find(_ asked: String, in library: [ReadyMadeTeam]) -> ReadyMadeTeam? {
        func plain(_ text: String) -> String {
            var words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if words.first == "the" { words.removeFirst() }
            if words.count > 1, words.last == "team" { words.removeLast() }
            return words.joined(separator: " ")
        }
        if let exact = library.first(where: { TeamBuildOrder.sameName($0.name, asked) || $0.id == asked }) { return exact }
        let wanted = plain(asked)
        guard !wanted.isEmpty else { return nil }
        return library.first { plain($0.name) == wanted }
    }

    /// `name`, or `name 2`, `name 3`, … when one is taken (names match without regard to case). A name that already ends in
    /// a number counts on from it: "Research Desk 2" taken gives "Research Desk 3", not "Research Desk 2 2".
    public static func uniqueName(_ name: String, taken: [String], longest: Int) -> String {
        let isTaken: (String) -> Bool = { candidate in taken.contains { TeamBuildOrder.sameName($0, candidate) } }
        guard isTaken(name) else { return name }
        var base = name
        var number = 2
        if let space = name.lastIndex(of: " ") {
            let stem = name[..<space].trimmingCharacters(in: .whitespaces)
            let tail = name[name.index(after: space)...]
            if !stem.isEmpty, !tail.isEmpty, tail.count <= 3, tail.allSatisfy({ $0.isASCII && $0.isNumber }), let counted = Int(tail) {
                base = stem
                number = counted + 1
            }
        }
        while true {
            let suffix = " \(number)"
            let candidate = String(base.prefix(max(1, longest - suffix.count))).trimmingCharacters(in: .whitespaces) + suffix
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// `instructions` with each old name swapped for its new one, as a whole name only ("Web Scout" but not "Web Scouting"
    /// or a "Web Scout 2" that's already numbered). Longest names first, so "Research Desk" changes before "Research".
    static func renamed(_ instructions: String, renames: [(old: String, new: String)]) -> String {
        guard !instructions.isEmpty else { return instructions }
        var result = instructions
        for rename in renames.sorted(by: { $0.old.count > $1.old.count }) where !rename.old.isEmpty {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: rename.old) + #"(?![\p{L}\p{N}]|\s\d)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: rename.new))
        }
        return result
    }

    // MARK: - From a category the owner already has

    /// A team made from a category in the sidebar, to keep and add again: its manager (or, with none, its first bot) and the
    /// rest. Nil when the category has no bots.
    public static func team(fromCategory name: String, purpose: String?, manager: ReadyMadeTeam.Member?, members: [ReadyMadeTeam.Member],
                            id: String) -> ReadyMadeTeam? {
        var others = members
        let lead: ReadyMadeTeam.Member
        if let manager {
            lead = manager
            others.removeAll { TeamBuildOrder.sameName($0.name, manager.name) }
        } else {
            guard !others.isEmpty else { return nil }
            lead = others.removeFirst()
        }
        return tidied(ReadyMadeTeam(id: id, name: name, purpose: purpose ?? "", manager: lead, workers: Array(others.prefix(mostWorkers))))
    }

    // MARK: - Files

    /// A team file, to keep or send to someone: {"kind": "vello-bot-teams", "version": 1, "teams": [...]}.
    struct TeamsFile: Codable {
        var kind: String?
        var version: Int?
        var teams: [ReadyMadeTeam]
    }

    public static let fileKind = "vello-bot-teams"
    public static let fileExtension = "json"

    public static func fileData(_ teams: [ReadyMadeTeam]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(TeamsFile(kind: fileKind, version: 1, teams: teams))) ?? Data()
    }

    /// The teams in a file: a team file, one team on its own, or a ```team block's JSON (each category with its bots
    /// becomes a team, its named manager or else its first bot leading). Each comes back tidied; teams with no usable
    /// manager are left out. Empty when nothing in it is a team.
    public static func teams(fromFile data: Data) -> [ReadyMadeTeam] {
        let decoder = JSONDecoder()
        var found: [ReadyMadeTeam] = []
        if let file = try? decoder.decode(TeamsFile.self, from: data) {
            found = file.teams
        } else if let one = try? decoder.decode(ReadyMadeTeam.self, from: data) {
            found = [one]
        } else if let body = String(data: data, encoding: .utf8), let order = TeamBuildOrder.parse(body) {
            found = teams(from: order)
        }
        return found.map(tidied).filter { !$0.name.isEmpty && !$0.manager.name.isEmpty }
    }

    /// Each category of a ```team order as a team.
    static func teams(from order: TeamBuildOrder) -> [ReadyMadeTeam] {
        order.categories.compactMap { category -> ReadyMadeTeam? in
            let members = order.bots.filter { bot in bot.category.map { TeamBuildOrder.sameName($0, category.name) } ?? false }
                .map { ReadyMadeTeam.Member(name: $0.name, does: $0.does, instructions: $0.instructions, model: $0.model, brain: $0.brain) }
            let manager = category.wantsNoManager ? nil : category.manager.flatMap { name in members.first { TeamBuildOrder.sameName($0.name, name) } }
            return team(fromCategory: category.name, purpose: category.purpose, manager: manager, members: members, id: "")
        }
    }

    private static func oneLine(_ text: String, longest: Int) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(longest))
    }
}
