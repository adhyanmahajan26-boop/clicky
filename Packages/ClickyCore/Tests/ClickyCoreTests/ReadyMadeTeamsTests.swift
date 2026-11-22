import Foundation
import Testing
@testable import ClickyCore

struct ReadyMadeTeamsTests {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theCatalogIsTheSameFileWindowsReads() throws {
        let windowsFile = Self.repoRoot.appendingPathComponent("crossplatform/crates/theo-core/src/ready_teams.json")
        let windows = try String(contentsOf: windowsFile, encoding: .utf8)
        #expect(windows.trimmingCharacters(in: .whitespacesAndNewlines) == ReadyMadeTeams.catalogJSON.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func everyBuiltInTeamHasAManagerAndBotsWithTheirOwnNames() {
        #expect(ReadyMadeTeams.builtIn.count >= 8)
        var allNames: [String] = []
        for team in ReadyMadeTeams.builtIn {
            #expect(ReadyMadeTeams.problem(with: team) == nil, "\(team.name): \(ReadyMadeTeams.problem(with: team) ?? "")")
            #expect(!team.workers.isEmpty)
            #expect(!team.purpose.isEmpty)
            #expect(ReadyMadeTeams.tidied(team) == team, "\(team.name) is longer than a team block keeps")
            for member in team.members {
                #expect(member.instructions.hasPrefix("You are \(member.name)"), "\(member.name)")
                // Saved with the bot, so it never names a person: the owner's name comes from Settings each turn.
                #expect(!member.instructions.contains("Addy"))
                allNames.append(member.name.lowercased())
            }
        }
        // No two ready-made bots share a name, so adding several teams never numbers one.
        #expect(Set(allNames).count == allNames.count)
        // Pointer Assistant's own helpers keep their names.
        #expect(!allNames.contains("researcher") && !allNames.contains("memory") && !allNames.contains("runner"))
        #expect(ReadyMadeTeams.builtIn.contains { $0.name == "Super Digger Squad" && $0.manager.name == "Digger Boss" })
    }

    @Test func addingATeamMakesItsCategoryWithItsManagerFirst() {
        let team = ReadyMadeTeams.builtIn.first { $0.id == "research" }!
        let order = ReadyMadeTeams.order(for: team, existingBotNames: ["Vello", "Memory"], existingCategoryNames: ["Pointer Assistant"])
        #expect(order.categories == [.init(name: "Research Desk", purpose: team.purpose, manager: "Research Lead")])
        #expect(order.bots.map(\.name) == ["Research Lead", "Web Scout", "Fact Checker", "Brief Writer"])
        #expect(order.bots.allSatisfy { $0.category == "Research Desk" })
        #expect(order.bots[1].instructions == team.workers[0].instructions)
    }

    @Test func addingATeamAgainNumbersItsNamesAndNeverMovesABot() {
        let team = ReadyMadeTeams.builtIn.first { $0.id == "research" }!
        let order = ReadyMadeTeams.order(for: team, existingBotNames: ["research lead", "Web Scout", "Web Scout 2"],
                                         existingCategoryNames: ["Research Desk"])
        #expect(order.categories.first?.name == "Research Desk 2")
        #expect(order.categories.first?.manager == "Research Lead 2")
        #expect(order.bots.map(\.name) == ["Research Lead 2", "Web Scout 3", "Fact Checker", "Brief Writer"])
        #expect(order.bots[1].instructions.hasPrefix("You are Web Scout 3 on the Research Desk 2."))
        // The second manager hands work to the second team, not the first.
        #expect(order.bots[0].instructions.contains("Web Scout 3 finds sources"))
        #expect(order.bots[0].instructions.hasPrefix("You are Research Lead 2, the manager of the Research Desk 2."))
        #expect(order.bots[2].instructions == team.workers[1].instructions.replacingOccurrences(of: "Research Desk", with: "Research Desk 2"))
    }

    @Test func aNumberedNameCountsOn() {
        #expect(ReadyMadeTeams.uniqueName("Research Desk 2", taken: ["Research Desk 2"], longest: 80) == "Research Desk 3")
        #expect(ReadyMadeTeams.uniqueName("Desk 2024", taken: ["Desk 2024"], longest: 80) == "Desk 2024 2")
    }

    @Test func aNumberedNameStaysUnderTheLimit() {
        let long = String(repeating: "x", count: 40)
        let name = ReadyMadeTeams.uniqueName(long, taken: [long], longest: 40)
        #expect(name.count == 40)
        #expect(name.hasSuffix(" 2"))
    }

    @Test func theLibraryKeepsTheOwnersChangesAndOwnTeams() {
        var saved = ReadyMadeTeams.Saved()
        var research = ReadyMadeTeams.builtIn.first { $0.id == "research" }!
        research.name = "My Research"
        research.workers.removeLast()
        saved = ReadyMadeTeams.saving(research, into: saved)
        let own = ReadyMadeTeam(id: ReadyMadeTeams.newID(for: "Garden Club", among: ReadyMadeTeams.library(saved)), name: "Garden Club",
                                purpose: "Plants", manager: .init(name: "Head Gardener", does: "Plans the beds"),
                                workers: [.init(name: "Weeder", does: "Pulls weeds")])
        #expect(own.id == "own-garden-club")
        saved = ReadyMadeTeams.saving(own, into: saved)
        saved = ReadyMadeTeams.removing("money", from: saved)

        let library = ReadyMadeTeams.library(saved)
        #expect(library.first?.name == "My Research")
        #expect(ReadyMadeTeams.isChanged(library[0]))
        #expect(!library.contains { $0.id == "money" })
        #expect(library.last == own)
        #expect(library.count == ReadyMadeTeams.builtIn.count)

        // Reset puts Vello's own back; a removed one comes back too.
        saved = ReadyMadeTeams.resetting("research", in: saved)
        saved = ReadyMadeTeams.resetting("money", in: saved)
        #expect(ReadyMadeTeams.library(saved).first == ReadyMadeTeams.original("research"))
        #expect(ReadyMadeTeams.library(saved).contains { $0.id == "money" })
        // Removing the owner's own team deletes it for good.
        saved = ReadyMadeTeams.removing(own.id, from: saved)
        #expect(saved.teams.isEmpty && saved.hiddenBuiltInIDs.isEmpty)
    }

    @Test func savingABuiltInTeamUnchangedKeepsNothing() {
        let saved = ReadyMadeTeams.saving(ReadyMadeTeams.builtIn[0], into: ReadyMadeTeams.Saved())
        #expect(saved.teams.isEmpty)
    }

    @Test func problemsAreSaidInASentence() {
        let fine = ReadyMadeTeams.builtIn[0]
        var unnamed = fine
        unnamed.name = "  "
        #expect(ReadyMadeTeams.problem(with: unnamed) == "Give the team a name.")
        var twins = fine
        twins.workers.append(.init(name: fine.manager.name.uppercased(), does: "Same name"))
        #expect(ReadyMadeTeams.problem(with: twins)?.hasPrefix("Two bots are called") == true)
        var vello = fine
        vello.workers.append(.init(name: "vello", does: "Pretends"))
        #expect(ReadyMadeTeams.problem(with: vello)?.contains("keeps for itself") == true)
        var crowd = fine
        crowd.workers = (1...20).map { .init(name: "Worker \($0)", does: "Works") }
        #expect(ReadyMadeTeams.problem(with: crowd)?.hasPrefix("A team can have at most 19") == true)
        // An empty bot row in the editor is left out rather than refused.
        var blankRow = fine
        blankRow.workers.append(.init(name: "", does: ""))
        #expect(ReadyMadeTeams.problem(with: blankRow) == nil)
        #expect(ReadyMadeTeams.tidied(blankRow).workers.count == fine.workers.count)
    }

    @Test func aTeamFileRoundTrips() {
        let teams = Array(ReadyMadeTeams.builtIn.prefix(2))
        let data = ReadyMadeTeams.fileData(teams)
        #expect(String(data: data, encoding: .utf8)?.contains(#""kind" : "vello-bot-teams""#) == true)
        #expect(ReadyMadeTeams.teams(fromFile: data) == teams)
    }

    @Test func oneTeamOnItsOwnOrATeamBlockReadsToo() {
        let one = try! JSONEncoder().encode(ReadyMadeTeams.builtIn[0])
        #expect(ReadyMadeTeams.teams(fromFile: one) == [ReadyMadeTeams.builtIn[0]])

        let block = #"{"categories": [{"name": "Sales", "manager": "Rex"}], "bots": [{"name": "Ada", "does": "Writes", "category": "Sales"}, {"name": "Rex", "does": "Leads", "category": "Sales", "model": "opus"}]}"#
        let fromBlock = ReadyMadeTeams.teams(fromFile: Data(block.utf8))
        #expect(fromBlock.count == 1)
        #expect(fromBlock.first?.manager.name == "Rex")
        #expect(fromBlock.first?.manager.model == "opus")
        #expect(fromBlock.first?.workers.map(\.name) == ["Ada"])
        #expect(ReadyMadeTeams.teams(fromFile: Data("not json".utf8)).isEmpty)
    }

    @Test func aCategoryWithoutAManagerIsLedByItsFirstBot() {
        let team = ReadyMadeTeams.team(fromCategory: "Ops", purpose: nil, manager: nil,
                                       members: [.init(name: "Ivy", does: "Plans"), .init(name: "Max", does: "Does")], id: "own-ops")
        #expect(team?.manager.name == "Ivy")
        #expect(team?.workers.map(\.name) == ["Max"])
        #expect(ReadyMadeTeams.team(fromCategory: "Empty", purpose: nil, manager: nil, members: [], id: "own-empty") == nil)
    }

    @Test func aTeamBlockCanNameReadyMadeTeams() {
        let order = TeamBuildOrder.parse(#"{"teams": ["Research Desk", {"name": "the sales team"}, "Research Desk"]}"#)
        #expect(order?.readyMadeTeams == ["Research Desk", "the sales team"])
        #expect(order?.isEmpty == false)
    }

    @Test func expandingAddsEachTeamAndSaysWhichWereMissing() {
        let order = TeamBuildOrder(bots: [.init(name: "Web Scout", does: "Mine")], readyMadeTeams: ["research desk", "the sales team", "Moon Base"])
        let expanded = ReadyMadeTeams.expanding(order, library: ReadyMadeTeams.builtIn, existingBotNames: ["Vello"], existingCategoryNames: [])
        #expect(expanded.missing == ["Moon Base"])
        #expect(expanded.order.readyMadeTeams.isEmpty)
        #expect(expanded.order.categories.map(\.name) == ["Research Desk", "Sales Team"])
        // The block's own Web Scout keeps its name; the team's gets a number.
        #expect(expanded.order.bots.map(\.name).prefix(3) == ["Web Scout", "Research Lead", "Web Scout 2"])
    }

    @Test func theCEOIsToldTheTeamsByName() {
        let howTo = BotProtocol.teamBuildHowTo(owner: "the owner", readyMadeTeams: ["Research Desk", "Sales Team"])
        #expect(howTo.contains("Research Desk and Sales Team"))
        #expect(howTo.contains(#"{"teams": ["Research Desk"]}"#))
        #expect(BotProtocol.teamBuildHowTo(owner: "the owner") == BotProtocol.teamBuildHowTo(owner: "the owner", readyMadeTeams: []))
        #expect(!BotProtocol.teamBuildHowTo(owner: "the owner").contains("Ready-made"))
    }

    @Test func askingForASquadOrADeskCountsAsAskingForBots() {
        #expect(TeamBuildIntent.ownerAsked("add the Super Digger Squad"))
        #expect(TeamBuildIntent.ownerAsked("set up the money desk please"))
    }
}
