//
//  ClickyTeamTests.swift
//  ClickyCore
//

import Foundation
import Testing
@testable import ClickyCore

struct ClickyTeamTests {
    // MARK: Delegate tags

    @Test func routerEmitsADelegateAndSpeaksOnlyTheHeadsUp() {
        var router = ResponseRouter()
        let outputs = router.feed("on it, researcher's looking.\n[DELEGATE:researcher:find sources on vector databases: pros and cons]\n") + router.finish()
        let jobs = outputs.compactMap { output -> (ClickyDuty, String)? in
            if case .delegate(let duty, let task) = output { return (duty, task) }
            return nil
        }
        #expect(jobs.count == 1)
        #expect(jobs.first?.0 == .researcher)
        #expect(jobs.first?.1 == "find sources on vector databases: pros and cons")
        let spoken = outputs.compactMap { output -> String? in
            if case .narration(let text) = output { return text }
            return nil
        }.joined()
        #expect(spoken.contains("on it"))
        #expect(!spoken.contains("DELEGATE"))
    }

    @Test func aDelegateSplitAcrossChunksStillParses() {
        var router = ResponseRouter()
        var outputs: [ResponseRouterOutput] = []
        for character in "[DELEGATE:memory:remember the wifi is on floor 2]\nsaved." { outputs += router.feed(String(character)) }
        outputs += router.finish()
        #expect(outputs.contains(.delegate(duty: .memory, task: "remember the wifi is on floor 2")))
    }

    @Test func anUnknownDutyIsDroppedAndNeverSpoken() {
        var router = ResponseRouter()
        let outputs = router.feed("[DELEGATE:janitor:clean up]\n") + router.finish()
        #expect(!outputs.contains { if case .delegate = $0 { return true } else { return false } })
        #expect(!outputs.contains { if case .narration(let text) = $0 { return text.contains("janitor") } else { return false } })
    }

    @Test func historyLosesDelegateTags() {
        #expect(!HistoryTagRewriter.wordsForHistory("on it.\n[DELEGATE:runner:tell Ada to check]\n").contains("DELEGATE"))
    }

    // MARK: Orders

    @Test func ordersToClickyAreRecognised() {
        #expect(ClickyOrder.parse("Clicky, research vector databases") == "research vector databases")
        #expect(ClickyOrder.parse("hey clicky: point at the Save button") == "point at the Save button")
        #expect(ClickyOrder.parse("@Clicky remember this") == "remember this")
        #expect(ClickyOrder.parse("tell clicky to open chrome") == "open chrome")
        #expect(ClickyOrder.parse("clicky remember that I like tea") == "remember that I like tea")
    }

    @Test func aMessageThatOnlyMentionsClickyStaysAMessage() {
        #expect(ClickyOrder.parse("what does Clicky do?") == nil)
        #expect(ClickyOrder.parse("clicky is great") == nil)
        #expect(ClickyOrder.parse("Clicky,") == nil)
        #expect(ClickyOrder.parse("I asked clicky to do it") == nil)
    }

    @Test func tagsComeOutOfTheosReply() {
        let reply = "I'll have Clicky check.\n\n[CLICKY: point at the Save button]\n\nMeanwhile, here's the plan."
        let (text, orders) = ClickyOrder.extract(from: reply)
        #expect(orders == ["point at the Save button"])
        #expect(!text.contains("CLICKY"))
        #expect(text.contains("plan"))
    }

    @Test func aTagStillBeingWrittenStaysHidden() {
        #expect(ClickyOrder.withoutTags(streaming: "On it. [CLICKY: point at") == "On it. ")
        #expect(ClickyOrder.withoutTags(streaming: "On it. [CL") == "On it. ")
        #expect(ClickyOrder.withoutTags(streaming: "see [1] for more").contains("[1]"))
    }

    @Test func theVoiceNeverReadsAnOrderHoweverItIsSplit() {
        let reply = "I'll get Clicky on that. [CLICKY: point at the Save button] Anything else?"
        for size in [1, 2, 3, 5, 9, 200] {
            var stream = ClickyOrderStream()
            var speech = ""
            var orders: [String] = []
            var rest = Substring(reply)
            while !rest.isEmpty {
                let piece = rest.prefix(size)
                rest = rest.dropFirst(size)
                let out = stream.feed(String(piece))
                speech += out.speech
                orders += out.orders
            }
            let last = stream.finish()
            speech += last.speech
            orders += last.orders
            #expect(orders == ["point at the Save button"], "chunk size \(size)")
            #expect(speech == "I'll get Clicky on that.  Anything else?", "chunk size \(size)")
        }
    }

    @Test func otherBracketsStillGetRead() {
        var stream = ClickyOrderStream()
        let out = stream.feed("see [1] and [Clear] please")
        let last = stream.finish()
        #expect(out.speech + last.speech == "see [1] and [Clear] please")
        #expect(out.orders.isEmpty && last.orders.isEmpty)
    }

    // MARK: Runner

    @Test func runnerPlans() {
        #expect(ClickyRunnerPlan.parse("Hand to: Ada\n```handoff\nCheck the invoices.\n```") == .handOff(botName: "Ada", message: "Check the invoices."))
        #expect(ClickyRunnerPlan.parse("**Hand to:** @Ada\n\nCheck the invoices.") == .handOff(botName: "Ada", message: "Check the invoices."))
        #expect(ClickyRunnerPlan.parse("Project: Fix\nRepo: ~/x\n```prompt\nfix it\n```") == .coding)
        #expect(ClickyRunnerPlan.parse("Neither fits, there's nobody to ask.") == .nothing)
    }

    // MARK: Memory

    private func store() -> ClickyMemoryStore {
        ClickyMemoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("clicky-memory-\(UUID().uuidString)"))
    }

    @Test func oneWordCommandsAreNotKept() {
        let memory = store()
        #expect(memory.append("stop", kind: .said) == nil)
        #expect(memory.append("volume forty", kind: .said) == nil)
        #expect(memory.append("my sister's birthday is in March", kind: .said) != nil)
        #expect(memory.entries().count == 1)
    }

    @Test func secretsAreNeverWritten() {
        let memory = store()
        let saved = memory.append("the api key is sk-abcdefghijklmnopqrstuvwx and my card is 4242 4242 4242 4242", kind: .said)
        #expect(saved?.text.contains("sk-") == false)
        #expect(saved?.text.contains("4242") == false)
        #expect(memory.entries().first?.text.contains("[hidden]") == true)
    }

    @Test func searchFindsTheBestMatchFirst() {
        let memory = store()
        let start = Date(timeIntervalSince1970: 1_000_000)
        memory.append("the wifi password lives in the kitchen drawer", kind: .said, at: start)
        memory.append("my sister's birthday is on the third of March", kind: .said, at: start.addingTimeInterval(10))
        memory.append("book a table for the birthday dinner in March", kind: .said, at: start.addingTimeInterval(20))
        let hits = memory.search("what did I say about my sister's birthday")
        #expect(hits.first?.text.contains("sister") == true)
        #expect(hits.count == 2)
        #expect(memory.search("kitchen").count == 1)
        #expect(memory.search("volcano").isEmpty)
    }

    @Test func summariesCountFromTheLastOne() {
        let memory = store()
        let start = Date(timeIntervalSince1970: 1_000_000)
        memory.append("first thing worth keeping here", kind: .said, at: start)
        memory.append("- a summary", kind: .summary, at: start.addingTimeInterval(5))
        memory.append("second thing worth keeping here", kind: .said, at: start.addingTimeInterval(10))
        #expect(memory.unsummarised().map(\.text) == ["second thing worth keeping here"])
        #expect(memory.context().contains("a summary"))
    }

    @Test func tasksForMemoryAreClassified() {
        #expect(ClickyMemoryTask.classify("remember that I like tea") == .remember("I like tea"))
        #expect(ClickyMemoryTask.classify("Save this: the door code") == .remember("the door code"))
        #expect(ClickyMemoryTask.classify("remember what I said about tea") == .find("remember what I said about tea"))
        #expect(ClickyMemoryTask.classify("what did I say about tea") == .find("what did I say about tea"))
        #expect(ClickyMemoryTask.classify("summarise the week") == .summarise)
        #expect(ClickyMemoryTask.classify("Priya's birthday is in March") == .remember("Priya's birthday is in March"))
        #expect(ClickyMemoryTask.classify("when is Priya's birthday?") == .find("when is Priya's birthday?"))
    }

    // MARK: The team

    @Test func theTeamIsOnHaikuWithItsOwnFaces() {
        #expect(ClickyDuty.model == ClickyModels.haiku)
        #expect(Set(ClickyDuty.allCases.map(\.avatar)).count == 3)
        #expect(Set(ClickyDuty.allCases.map(\.botID)).count == 3)
    }

    @Test func thePromptNamesEveryDutyAndWhoIsAbove() {
        let section = ClickyTeamPrompts.teamSection(names: [.memory: "Memo", .researcher: "Researcher"], ceoName: "Theo")
        #expect(section.contains("\"Memo\""))
        #expect(section.contains("a helper"))
        #expect(section.contains("[DELEGATE:runner:"))
        #expect(section.contains("theo"))
    }
}

@Suite struct TheoTellTests {
    @Test func tellOrdersComeOutWithNameAndMessage() {
        let taken = ClickyOrder.extract(from: "Sending it over. [TELL: IT guys: write the prompt from Clicky's data] [CLICKY: point at Save]")
        #expect(taken.text == "Sending it over.")
        #expect(taken.orders.count == 2)
        let target = ClickyOrder.tellTarget(in: taken.orders[0])
        #expect(target?.name == "IT guys")
        #expect(target?.message == "write the prompt from Clicky's data")
        #expect(ClickyOrder.tellTarget(in: taken.orders[1]) == nil)
    }

    @Test func theVoiceNeverReadsATellOrder() {
        var stream = ClickyOrderStream()
        var speech = ""
        var orders: [String] = []
        for character in "On it. [TELL: project manager: send the brief] Done." {
            let out = stream.feed(String(character))
            speech += out.speech
            orders += out.orders
        }
        let rest = stream.finish()
        speech += rest.speech
        orders += rest.orders
        #expect(speech == "On it.  Done.")
        #expect(ClickyOrder.tellTarget(in: orders[0])?.name == "project manager")
    }

    @Test func memoryFindsTheTeamsWorkAndClickyHearsAboutIt() {
        let memory = ClickyMemoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let text = ClickyMemoryStore.teamWorkText(worker: "Researcher", task: "research the James Webb telescope", result: "Webb sees early galaxies.", savedPath: "/notes/webb.md")
        memory.append(text, kind: .teamWork)
        #expect(memory.search("James Webb").first?.text.contains("early galaxies") == true)
        #expect(memory.context().contains("/notes/webb.md"))
        #expect(memory.unsummarised().isEmpty)
    }

    @Test func gatheringWorkIsASearchNotSomethingToSave() {
        if case .find = ClickyMemoryTask.classify("gather everything the team collected") {} else { Issue.record("should be a find") }
        if case .find = ClickyMemoryTask.classify("collect all the data from Clicky's bots") {} else { Issue.record("should be a find") }
    }
}
