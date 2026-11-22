//
//  ReadyMadeTeamLibrary.swift
//  leanring-buddy
//
//  The ready-made teams on this Mac, for Settings › Bot teams and the CEO: Vello's own (ClickyCore `ReadyMadeTeams.builtIn`)
//  with the owner's changes, and the owner's own teams. Saved as `ready-made-teams.json` beside the bots. The rules are
//  pure in ClickyCore `ReadyMadeTeams`; `BotsStore.addReadyMadeTeam` makes a team's bots.
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class ReadyMadeTeamLibrary: ObservableObject {
    static let shared = ReadyMadeTeamLibrary()

    @Published private(set) var saved: ReadyMadeTeams.Saved

    private var file: URL { BotsStore.shared.folder.appendingPathComponent("ready-made-teams.json") }

    private init() {
        saved = ReadyMadeTeams.Saved()
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(ReadyMadeTeams.Saved.self, from: data) {
            saved = decoded
        }
    }

    /// Every team Settings lists, in its order.
    var teams: [ReadyMadeTeam] { ReadyMadeTeams.library(saved) }

    func team(_ id: String) -> ReadyMadeTeam? { teams.first { $0.id == id } }

    /// Whether Vello ships the built-in teams the owner removed, so Settings can offer them back.
    var hasRemovedBuiltIns: Bool { !saved.hiddenBuiltInIDs.isEmpty }

    /// Keeps a team as the owner edited it. Returns what's wrong with it instead, when something is.
    @discardableResult
    func save(_ team: ReadyMadeTeam) -> String? {
        if let problem = ReadyMadeTeams.problem(with: team) { return problem }
        write(ReadyMadeTeams.saving(ReadyMadeTeams.tidied(team), into: saved))
        return nil
    }

    func remove(_ id: String) { write(ReadyMadeTeams.removing(id, from: saved)) }

    func reset(_ id: String) { write(ReadyMadeTeams.resetting(id, in: saved)) }

    func restoreBuiltIns() { write(ReadyMadeTeams.restoringBuiltIns(in: saved)) }

    /// A blank team for the owner to fill in: a manager and one bot under it.
    func blankTeam() -> ReadyMadeTeam {
        ReadyMadeTeam(id: ReadyMadeTeams.newID(for: "New team", among: teams), name: "", purpose: "",
                      manager: .init(name: "", does: ""), workers: [.init(name: "", does: "")])
    }

    /// Keeps a copy of a team as one of the owner's own, under a free name ("Research Desk copy").
    @discardableResult
    func duplicate(_ team: ReadyMadeTeam) -> ReadyMadeTeam {
        var copy = team
        copy.name = ReadyMadeTeams.uniqueName(team.name + " copy", taken: teams.map(\.name), longest: 80)
        copy.id = ReadyMadeTeams.newID(for: copy.name, among: teams)
        write(ReadyMadeTeams.saving(copy, into: saved))
        return copy
    }

    /// Saves a category from the sidebar as a team of the owner's own, with every bot's description, instructions and
    /// model, so the whole category can be added again or sent to someone. Nil when it has no bots of its own.
    @discardableResult
    func saveCategory(_ sectionID: String, store: BotsStore) -> ReadyMadeTeam? {
        guard let section = store.category(sectionID) else { return nil }
        let members = store.members(of: section).filter { !$0.primary && $0.owner == nil && $0.id != BotsStore.clickyID }
            .map { bot in ReadyMadeTeam.Member(name: bot.name, does: bot.description, instructions: bot.instructions, model: bot.model.isEmpty ? nil : bot.model) }
        let manager = section.leaderID.flatMap { store.bot($0) }.flatMap { leader in members.first { $0.name == leader.name } }
        let name = ReadyMadeTeams.uniqueName(section.name, taken: teams.map(\.name), longest: 80)
        guard let team = ReadyMadeTeams.team(fromCategory: name, purpose: section.purpose, manager: manager, members: members,
                                             id: ReadyMadeTeams.newID(for: name, among: teams)) else { return nil }
        write(ReadyMadeTeams.saving(team, into: saved))
        return team
    }

    /// Reads a team file into the library as the owner's own teams, each under a free name and id, so it never replaces a
    /// team that's here. Returns the teams it added (empty when the file had none).
    func importFile(_ url: URL) -> [ReadyMadeTeam] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var added: [ReadyMadeTeam] = []
        var next = saved
        for var team in ReadyMadeTeams.teams(fromFile: data) where ReadyMadeTeams.problem(with: team) == nil {
            let library = ReadyMadeTeams.library(next)
            team.name = ReadyMadeTeams.uniqueName(team.name, taken: library.map(\.name), longest: 80)
            team.id = ReadyMadeTeams.newID(for: team.name, among: library)
            next = ReadyMadeTeams.saving(team, into: next)
            added.append(team)
        }
        if !added.isEmpty { write(next) }
        return added
    }

    /// Writes teams to a file someone can import on another Mac or on Windows.
    func export(_ teams: [ReadyMadeTeam], to url: URL) -> Bool {
        (try? ReadyMadeTeams.fileData(teams).write(to: url, options: .atomic)) != nil
    }

    private func write(_ next: ReadyMadeTeams.Saved) {
        saved = next
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(next) { try? data.write(to: file, options: .atomic) }
    }
}
