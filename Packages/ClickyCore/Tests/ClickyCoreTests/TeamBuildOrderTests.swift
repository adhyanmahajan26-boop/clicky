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
        let bots = (1...9).map { #"{"name": "Bot \#($0)"}"# }.joined(separator: ",")
        let categories = (1...6).map { #"{"name": "Team \#($0)"}"# }.joined(separator: ",")
        let order = TeamBuildOrder.parse(#"{"bots": [\#(bots)], "categories": [\#(categories)]}"#)
        #expect(order?.bots.count == TeamBuildOrder.mostBots)
        #expect(order?.categories.count == TeamBuildOrder.mostCategories)
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
        for words in ["make Penny the manager of Growth", "put Ada in charge of Sales", "Rex should lead the marketing team",
                      "Growth needs no manager", "move Penny to Sales", "assign a manager to every team"] {
            #expect(TeamBuildIntent.ownerAsked(words), "\(words)")
        }
    }

    @Test func theCEOIsToldHow() {
        let howTo = BotProtocol.teamBuildHowTo(owner: "the owner")
        #expect(howTo.contains("```team"))
        #expect(howTo.contains("own words"))
        #expect(howTo.contains("\"manager\": \"none\""))
    }
}
