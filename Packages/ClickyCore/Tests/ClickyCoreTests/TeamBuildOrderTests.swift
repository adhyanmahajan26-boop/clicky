import Foundation
import Testing
@testable import ClickyCore

struct TeamBuildOrderTests {
    @Test func takesTheBlockOutAndReadsIt() {
        let answer = """
        I'll set up a Marketing team with a writer.
        ```team
        {"categories": [{"name": "Marketing", "purpose": "Launch posts and ads"}],
         "bots": [{"name": "Ada", "does": "Writes launch posts", "instructions": "You are Ada. Write launch posts.", "category": "Marketing"}]}
        ```
        """
        let taken = TeamBuildOrder.extract(from: answer)
        #expect(taken.text == "I'll set up a Marketing team with a writer.")
        #expect(taken.order?.categories == [.init(name: "Marketing", purpose: "Launch posts and ads")])
        #expect(taken.order?.bots == [.init(name: "Ada", does: "Writes launch posts", instructions: "You are Ada. Write launch posts.", category: "Marketing")])
    }

    @Test func aBotsCategoryIsMadeTooWhenTheBlockDidntListIt() {
        let order = TeamBuildOrder.parse(#"{"bots": [{"name": "Rex", "does": "Chases leads", "category": "Sales"}]}"#)
        #expect(order?.categories.map(\.name) == ["Sales"])
        #expect(order?.bots.first?.category == "Sales")
    }

    @Test func aCategoryOnItsOwn() {
        let order = TeamBuildOrder.parse(#"{"categories": [{"name": "  Research  "}]}"#)
        #expect(order?.categories == [.init(name: "Research")])
        #expect(order?.bots.isEmpty == true)
    }

    @Test func nothingUsableIsNoOrder() {
        #expect(TeamBuildOrder.parse(#"{"bots": [{"name": "  "}]}"#) == nil)
        #expect(TeamBuildOrder.parse("not json") == nil)
        #expect(TeamBuildOrder.extract(from: "No block here.").order == nil)
    }

    @Test func otherFencesAreLeftAlone() {
        let answer = "```teammates\n{\"bots\": [{\"name\": \"Ada\"}]}\n```"
        let taken = TeamBuildOrder.extract(from: answer)
        #expect(taken.order == nil)
        #expect(taken.text == answer)
    }

    @Test func oneAnswerCantFloodTheSidebar() {
        let bots = (1...30).map { #"{"name": "Bot \#($0)"}"# }.joined(separator: ",")
        let categories = (1...10).map { #"{"name": "Team \#($0)"}"# }.joined(separator: ",")
        let order = TeamBuildOrder.parse(#"{"bots": [\#(bots)], "categories": [\#(categories)]}"#)
        #expect(order?.bots.count == TeamBuildOrder.mostBots)
        #expect(order?.categories.count == TeamBuildOrder.mostCategories)
    }

    @Test func aManagerAndTenWorkersFitInOneAnswer() {
        let workers = (1...10).map { #"{"name": "Digger \#($0)", "category": "Super Digger Squad", "model": "haiku"}"# }
        let boss = #"{"name": "Digger Boss", "category": "Super Digger Squad", "model": "Claude Opus 5.5"}"#
        let order = TeamBuildOrder.parse(#"{"categories": [{"name": "Super Digger Squad", "manager": "Digger Boss"}], "bots": [\#(([boss] + workers).joined(separator: ","))]}"#)
        #expect(order?.bots.count == 11)
        #expect(order?.bots.first?.model == "Claude Opus 5.5")
        #expect(order?.bots.last?.model == "haiku")
    }

    @Test func aSquadReadsInOneLine() {
        let squad = [TeamBuildOrder.MadeBot(name: "Boss", category: "Squad", modelWords: "Claude Opus 5.5")] +
            (1...3).map { TeamBuildOrder.MadeBot(name: "Digger \($0)", category: "Squad", modelWords: "Claude Haiku 5.5") }
        #expect(TeamBuildOrder.madeBotsSentence(squad) == "Vello made 4 bots in Squad: Boss on Claude Opus 5.5; Digger 1, Digger 2 and Digger 3 on Claude Haiku 5.5.")
        #expect(TeamBuildOrder.madeBotsSentence([.init(name: "Rex", category: "Sales")]) == "Vello made the bot Rex in Sales.")
        #expect(TeamBuildOrder.madeBotsSentence([.init(name: "Ada", category: "Growth"), .init(name: "Rex", category: "Sales"), .init(name: "Bo")])
                == "Vello made 3 bots: in Growth, Ada; in Sales, Rex; outside any category, Bo.")
        #expect(TeamBuildOrder.madeBotsSentence([.init(name: "Ada"), .init(name: "Bo")]) == "Vello made 2 bots: Ada and Bo.")
    }

    @Test func aBotCanNameItsBrain() {
        let order = TeamBuildOrder.parse(#"{"bots": [{"name": "Rex", "engine": "Codex", "model": "gpt-6"}]}"#)
        #expect(order?.bots.first?.brain == "Codex")
        #expect(order?.bots.first?.model == "gpt-6")
    }

    @Test func theSameNameTwiceIsOneBot() {
        let order = TeamBuildOrder.parse(#"{"bots": [{"name": "Ada"}, {"name": "ada "}]}"#)
        #expect(order?.bots.count == 1)
    }

    @Test func instructionsFallBackToTheJob() {
        #expect(TeamBuildOrder.instructions(for: .init(name: "Ada", does: "Writes posts.")) == "You are Ada. Writes posts.")
        #expect(TeamBuildOrder.instructions(for: .init(name: "Ada", does: "")) == "You are Ada.")
        #expect(TeamBuildOrder.instructions(for: .init(name: "Ada", does: "x", instructions: "Be brief.")) == "Be brief.")
    }

    @Test func theOwnerAskingForBotsOrCategories() {
        for words in ["make a new bot that writes my posts", "Can you create a Sales category?", "add two agents to research competitors",
                      "set up a marketing team with a writer and a designer", "I need a bot for my inbox", "new category: Finance",
                      "hire an assistant to sort my mail", "spin up 3 bots for the launch"] {
            #expect(TeamBuildIntent.ownerAsked(words), "\(words)")
        }
    }

    @Test func otherWordsDontAsk() {
        for words in ["what did the team do today?", "summarise my inbox", "write me a launch post",
                      "\(RoutineIntent.runPrefix): make a new bot"] {
            #expect(!TeamBuildIntent.ownerAsked(words), "\(words)")
        }
    }

    @Test func aCategoryCanNameItsManager() {
        let order = TeamBuildOrder.parse(#"{"categories": [{"name": "Growth", "manager": "Penny"}, {"name": "Sales", "manager": "None"}]}"#)
        #expect(order?.categories.first?.manager == "Penny")
        #expect(order?.categories.first?.wantsNoManager == false)
        #expect(order?.categories.last?.wantsNoManager == true)
    }

    @Test func theOwnerAskingForManagersOrMoves() {
        for words in ["switch Rex to Haiku", "Penny should use Opus 5.5", "run the workers on Codex",
                      "make Penny the manager of Growth", "put Ada in charge of Sales", "Rex should lead the marketing team",
                      "Growth needs no manager", "move Penny to Sales", "assign a manager to every team"] {
            #expect(TeamBuildIntent.ownerAsked(words), "\(words)")
        }
    }

    @Test func theCEOIsToldHow() {
        let howTo = BotProtocol.teamBuildHowTo(owner: "the owner")
        #expect(howTo.contains("```team"))
        #expect(howTo.contains("own words"))
        #expect(howTo.contains("\"manager\": \"none\""))
        #expect(howTo.contains("\"groups\": [{\"name\""))
        #expect(howTo.contains("\"rename\""))
        #expect(howTo.contains("\"memory\""))
        #expect(howTo.contains("30000 characters"))
    }

    @Test func aGroupChatWithAHeadAndMembers() {
        let order = TeamBuildOrder.parse(#"{"groups": [{"name": "Launch room", "head": "Ada", "members": ["Rex", "Bo", "ada", "rex"]}]}"#)
        #expect(order?.groups == [.init(name: "Launch room", head: "Ada", members: ["Rex", "Bo"])])
        #expect(order?.bots.isEmpty == true)
    }

    @Test func aGroupChatNeedsTwoBotsAndHoldsSix() {
        #expect(TeamBuildOrder.parse(#"{"groups": [{"name": "Alone", "head": "Ada"}]}"#) == nil)
        #expect(TeamBuildOrder.parse(#"{"groups": [{"name": "Pair", "members": ["Ada", "Rex"]}]}"#)?.groups.first?.head == nil)
        let crowd = (1...10).map { "\"Bot \($0)\"" }.joined(separator: ", ")
        let withHead = TeamBuildOrder.parse(#"{"groups": [{"name": "Crowd", "head": "Boss", "members": ["# + crowd + "]}]}")
        #expect(withHead?.groups.first?.members.count == 5)
        let withoutHead = TeamBuildOrder.parse(#"{"groups": [{"name": "Crowd", "members": ["# + crowd + "]}]}")
        #expect(withoutHead?.groups.first?.members.count == 6)
        let many = (1...10).map { #"{"name": "Room \#($0)", "members": ["Ada", "Rex"]}"# }.joined(separator: ", ")
        #expect(TeamBuildOrder.parse(#"{"groups": ["# + many + "]}")?.groups.count == TeamBuildOrder.mostGroups)
    }

    @Test func aBotCanBeRenamedAndRemember() {
        let order = TeamBuildOrder.parse(#"{"bots": [{"name": "Rex", "rename": "Max", "memory": "The owner trades on NSE.\nUse NSE bhavcopy first."}, {"name": "Bo", "newName": "bo"}]}"#)
        #expect(order?.bots.first?.newName == "Max")
        #expect(order?.bots.first?.memory == "The owner trades on NSE.\nUse NSE bhavcopy first.")
        // The same name in other letters is no rename.
        #expect(order?.bots.last?.newName == nil)
    }

    @Test func longInstructionsAndNamesStayWhole() {
        let playbook = String(repeating: "Check the exchange's own data first, then two other sources.\n", count: 400)
        #expect(playbook.count > 20000)
        let name = "Global Super Digger Squad Lead for Commodities and Trade Data"
        let body = try! JSONSerialization.data(withJSONObject: ["bots": [["name": name, "instructions": playbook]]])
        let order = TeamBuildOrder.parse(String(decoding: body, as: UTF8.self))
        #expect(order?.bots.first?.name == name)
        #expect(order?.bots.first?.instructions == playbook.trimmingCharacters(in: .whitespacesAndNewlines))
        let tooLong = String(repeating: "a", count: 40000)
        let capped = try! JSONSerialization.data(withJSONObject: ["bots": [["name": "Ada", "instructions": tooLong]]])
        #expect(TeamBuildOrder.parse(String(decoding: capped, as: UTF8.self))?.bots.first?.instructions.count == TeamBuildOrder.longestInstructions)
    }

    @Test func memoryIsAddedOnce() {
        #expect(TeamBuildOrder.memory("", adding: "  Use NSE first. ") == "Use NSE first.\n")
        #expect(TeamBuildOrder.memory("Old line.\n", adding: "Use NSE first.") == "Old line.\n\nUse NSE first.\n")
        #expect(TeamBuildOrder.memory("Old line.\n\nUse NSE first.\n", adding: "Use NSE first.") == nil)
        #expect(TeamBuildOrder.memory("Old line.", adding: "   ") == nil)
    }

    @Test func theOwnerAskingForGroupsRenamesAndMemory() {
        for words in ["make a group chat with Ada and Rex", "set up a group with the diggers", "rename Rex to Max",
                      "call Penny Ledger from now on", "change Rex's instructions", "give Ada a better prompt",
                      "update the digger's description", "fix the prompt of the squad", "save this to Rex's memory",
                      "Ada should remember that I trade on NSE", "add the sources to their memory"] {
            #expect(TeamBuildIntent.ownerAsked(words), "\(words)")
        }
        for words in ["what's in my memory?", "do you remember yesterday?", "summarise the group's day"] {
            #expect(!TeamBuildIntent.ownerAsked(words), "\(words)")
        }
    }
}

struct TeamBuildBrainsTests {
    static let claude = TeamBuildBrains.Brain(engine: "claude", label: "Claude Code", models: [
        .init(id: "claude-opus-5-5", label: "Claude Opus 5.5"), .init(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5"),
        .init(id: "claude-haiku-5-5", label: "Claude Haiku 5.5"), .init(id: "claude-haiku-4-5", label: "Claude Haiku 4.5"),
    ])
    static let codex = TeamBuildBrains.Brain(engine: "codex", label: "Codex")
    static let openAI = TeamBuildBrains.Brain(engine: "api:openai", label: "OpenAI", models: [.init(id: "gpt-6"), .init(id: "gpt-6-mini")])
    static let here = [claude, codex, openAI]

    @Test func modelsByTheirWords() {
        #expect(TeamBuildBrains.matchModel("haiku", among: Self.claude.models)?.id == "claude-haiku-5-5")
        #expect(TeamBuildBrains.matchModel("Claude Opus 5.5", among: Self.claude.models)?.id == "claude-opus-5-5")
        #expect(TeamBuildBrains.matchModel("haiku 4.5", among: Self.claude.models)?.id == "claude-haiku-4-5")
        #expect(TeamBuildBrains.matchModel("CLAUDE-SONNET-5-5", among: Self.claude.models)?.id == "claude-sonnet-5-5")
        #expect(TeamBuildBrains.matchModel("gpt-6", among: Self.openAI.models)?.id == "gpt-6")
        #expect(TeamBuildBrains.matchModel("opus 4.1", among: Self.claude.models) == nil)
    }

    @Test func brainsByTheirNames() {
        #expect(TeamBuildBrains.matchBrain("Claude Code", among: Self.here)?.engine == "claude")
        #expect(TeamBuildBrains.matchBrain("codex", among: Self.here)?.engine == "codex")
        #expect(TeamBuildBrains.matchBrain("OpenAI API key", among: Self.here)?.engine == "api:openai")
        #expect(TeamBuildBrains.matchBrain("Gemini", among: Self.here) == nil)
    }

    @Test func aModelOnTheMakersBrain() {
        #expect(TeamBuildBrains.pick(brain: nil, model: "haiku", makerEngine: "claude", among: Self.here) == .init(engine: "claude", model: "claude-haiku-5-5"))
        #expect(TeamBuildBrains.pick(brain: nil, model: nil, makerEngine: "claude", among: Self.here) == .init(engine: "claude"))
    }

    @Test func aModelOnlyAnotherBrainHasMovesThere() {
        #expect(TeamBuildBrains.pick(brain: nil, model: "gpt-6-mini", makerEngine: "claude", among: Self.here) == .init(engine: "api:openai", model: "gpt-6-mini"))
        #expect(TeamBuildBrains.pick(brain: nil, model: "opus", makerEngine: "codex", among: [Self.codex, Self.claude]) == .init(engine: "claude", model: "claude-opus-5-5"))
    }

    @Test func aBrainWithoutAListTakesAnExactID() {
        #expect(TeamBuildBrains.pick(brain: nil, model: "gpt-6", makerEngine: "codex", among: [Self.codex, Self.openAI]) == .init(engine: "codex", model: "gpt-6"))
        #expect(TeamBuildBrains.pick(brain: "Codex", model: "gpt-6-codex", makerEngine: "claude", among: Self.here) == .init(engine: "codex", model: "gpt-6-codex"))
    }

    @Test func whatIsntHereIsSaid() {
        let noBrain = TeamBuildBrains.pick(brain: "Gemini", model: nil, makerEngine: "claude", among: Self.here)
        #expect(noBrain.engine == "claude")
        #expect(noBrain.trouble == "there's no brain called Gemini set up here")
        let noModel = TeamBuildBrains.pick(brain: "Claude Code", model: "Opus 4.1", makerEngine: "claude", among: Self.here)
        #expect(noModel == .init(engine: "claude", model: nil, trouble: "Claude Code has no model called Opus 4.1"))
    }
}
