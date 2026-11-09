//
//  DevDecisionsTests.swift
//  ClickyCoreTests
//

import ClickyCore
import Foundation
import Testing

struct DevDecisionsTests {
    let crew = [
        DevBotCard(id: "fe", name: "Mira", job: "Builds the web UI: pages, components, styles and the browser side", recentTasks: ["Add a footer"], runsOn: "OpenCode"),
        DevBotCard(id: "be", name: "Ravi", job: "Builds the API, the database and the server side of the app", recentTasks: [], runsOn: "OpenCode"),
        DevBotCard(id: "kadi", name: "Kadi", job: "Your kadi ninda bot")
    ]

    func choice(_ pick: String, _ p: Double, others: [String: Double] = [:]) -> PrismAnswer {
        PrismAnswer(choice: pick, probability: p, probabilities: others.merging([pick: p]) { a, _ in a })
    }

    func noul(_ yes: Double) -> PrismAnswer {
        PrismAnswer(choice: yes >= 0.5 ? "true" : "false", probability: max(yes, 1 - yes), probabilities: ["true": yes, "false": 1 - yes])
    }

    // MARK: Cards

    @Test func aCardCarriesJobRecentTasksAndHarness() {
        let line = crew[0].line
        #expect(line.contains("Mira: Builds the web UI"))
        #expect(line.contains("recent tasks: Add a footer"))
        #expect(line.contains("runs on OpenCode"))
    }

    @Test func aVagueBotWithNoHistoryIsThin() {
        #expect(crew[2].isThin)
        #expect(!crew[0].isThin)
        // A vague job is fine once it has done a few tasks.
        #expect(!DevBotCard(id: "k", name: "Kadi", job: "Your kadi ninda bot", recentTasks: ["Fix the footer", "Fix the header"]).isThin)
    }

    // MARK: Assign

    @Test func assignAlwaysOffersTheLead() {
        let question = DevDecisions.assign(task: "Add a dark mode toggle", lead: "Theo", cards: crew)
        #expect(question.question.criteria.keys.sorted() == ["be", "fe", "kadi", "lead"])
        #expect(question.alsoAsk[DevDecisions.ownerID]?.kind == .noul)
        #expect(question.state.contains("Mira: Builds the web UI"))
    }

    @Test func aSurePickOfAFullCardStands() {
        let verdict = DevDecisions.assignVerdict([FastDecisionQuestion.id: choice("fe", 0.95), DevDecisions.ownerID: noul(0.9)], cards: crew, engine: .prism)
        #expect(verdict == DevVerdict(option: "fe", confidence: 0.9, stands: true))
    }

    @Test func aThinCardNeverStandsHoweverSureTheAnswer() {
        let verdict = DevDecisions.assignVerdict([FastDecisionQuestion.id: choice("kadi", 0.99), DevDecisions.ownerID: noul(0.99)], cards: crew, engine: .prism)
        #expect(verdict?.stands == false)
    }

    @Test func wityNeedsAHigherLineThanPrism() {
        let answers = [FastDecisionQuestion.id: choice("be", 0.85), DevDecisions.ownerID: noul(0.9)]
        #expect(DevDecisions.assignVerdict(answers, cards: crew, engine: .prism)?.stands == true)
        #expect(DevDecisions.assignVerdict(answers, cards: crew, engine: .wity)?.stands == false)
        #expect(DevDecisions.assignVerdict(answers, cards: crew, engine: .wityThinking)?.stands == false)
    }

    @Test func notOwnedByOneBotGoesToSonnet() {
        let verdict = DevDecisions.assignVerdict([FastDecisionQuestion.id: choice("fe", 0.95), DevDecisions.ownerID: noul(0.4)], cards: crew, engine: .prism)
        #expect(verdict?.stands == false)
    }

    @Test func theLeadKeepsAVagueTask() {
        let verdict = DevDecisions.assignVerdict([FastDecisionQuestion.id: choice("lead", 0.5), DevDecisions.ownerID: noul(0.1)], cards: crew, engine: .wity)
        #expect(verdict == DevVerdict(option: "lead", confidence: 0.5, stands: true))
    }

    @Test func wityGetsAShortlistOfTheClosestBots() {
        var many = (0..<200).map { DevBotCard(id: "b\($0)", name: "Bot \($0)", job: "Writes poems about weather and cats") }
        many.append(DevBotCard(id: "db", name: "Dee", job: "Owns the database migrations and the users table"))
        let short = DevDecisions.shortlist(many, for: "Add a migration for the users table", atMost: DevDecisionPolicy.wityOptionsAtMost - 1)
        #expect(short.count == 127)
        #expect(short.first?.id == "db")
        #expect(DevDecisions.shortlist(crew, for: "x", atMost: 127) == crew)
    }

    // MARK: Hold

    @Test func holdIsLowBarToHoldAndHighBarToGo() {
        #expect(DevDecisions.holdVerdict([FastDecisionQuestion.id: noul(0.6)], engine: .prism) == DevVerdict(option: "hold", confidence: 0.6, stands: true))
        #expect(DevDecisions.holdVerdict([FastDecisionQuestion.id: noul(0.05)], engine: .prism)?.option == "go")
        #expect(DevDecisions.holdVerdict([FastDecisionQuestion.id: noul(0.3)], engine: .prism)?.stands == false)
        #expect(DevDecisions.holdVerdict(nil, engine: .prism) == nil)
    }

    @Test func holdNamesForcePushAndDroppingData() {
        let question = DevDecisions.hold(task: "force push to main", project: "shop")
        #expect(question.question.criteria["true"]?.contains("force-pushing") == true)
        #expect(question.question.criteria["true"]?.contains("dropping") == true)
    }

    // MARK: Place

    @Test func placeIsOnlyAskedWithRunsGoing() {
        #expect(DevDecisions.place(task: "x", live: []) == nil)
        let question = DevDecisions.place(task: "Add a sort option", live: [DevLiveRun(id: "r1", title: "Add a filter", prompt: "in src/list.ts", botName: "Mira")])
        #expect(question?.question.criteria.keys.sorted() == ["after:r1", "new", "share:r1"])
    }

    @Test func placementOptionsRoundTrip() {
        for placement in [DevPlacement.newWorktree, .share(runID: "r1"), .after(runID: "r2")] {
            #expect(DevPlacement(option: placement.option) == placement)
        }
        #expect(DevPlacement.after(runID: "r").runsInParallel == false)
        #expect(DevPlacement.share(runID: "r").runsInParallel)
        #expect(DevPlacement(option: "nonsense") == nil)
    }

    @Test func aClosePlaceCallGoesToSonnet() {
        let close = DevDecisions.placeVerdict([FastDecisionQuestion.id: choice("new", 0.62, others: ["share:r1": 0.35])])
        #expect(close?.stands == false)
        let clear = DevDecisions.placeVerdict([FastDecisionQuestion.id: choice("after:r1", 0.9, others: ["new": 0.05])])
        #expect(clear == DevVerdict(option: "after:r1", confidence: 0.9, stands: true))
    }

    // MARK: Runner and run done

    @Test func runnerTiers() {
        #expect(DevDecisions.runnerVerdict([FastDecisionQuestion.id: noul(0.8)])?.option == "strong")
        #expect(DevDecisions.runnerVerdict([FastDecisionQuestion.id: noul(0.1)])?.option == "light")
        #expect(DevDecisions.runnerVerdict([FastDecisionQuestion.id: noul(0.5)])?.stands == false)
    }

    @Test func runDoneVerdicts() {
        #expect(DevDecisions.runDoneVerdict([FastDecisionQuestion.id: noul(0.9)])?.option == "finished")
        #expect(DevDecisions.runDoneVerdict([FastDecisionQuestion.id: noul(0.1)])?.option == "unfinished")
        #expect(DevDecisions.runDoneVerdict([FastDecisionQuestion.id: noul(0.5)])?.stands == false)
    }

    // MARK: Sonnet and Wity

    @Test func sonnetPromptListsEveryOptionAndAsksForJSON() {
        let question = DevDecisions.assign(task: "Add a dark mode toggle", lead: "Theo", cards: crew)
        let prompt = DevDecisions.sonnetPrompt(question)
        #expect(prompt.contains("Question \"decision\""))
        #expect(prompt.contains("Question \"oneOwner\""))
        #expect(prompt.contains("  fe: It's Mira's work"))
        #expect(prompt.contains("one line of JSON"))
    }

    @Test func sonnetsLineReadsAsAnswers() throws {
        let question = DevDecisions.assign(task: "Add a dark mode toggle", lead: "Theo", cards: crew)
        let answers = try #require(DevDecisions.sonnetAnswers("Sure.\n{\"decision\": \"fe\", \"oneOwner\": true, \"confidence\": 0.9}", question: question))
        #expect(answers[FastDecisionQuestion.id]?.choice == "fe")
        #expect(answers[DevDecisions.ownerID]?.choice == "true")
        // An option that isn't on the list is no answer.
        #expect(DevDecisions.sonnetAnswers("{\"decision\": \"nobody\", \"confidence\": 1}", question: question) == nil)
        #expect(DevDecisions.sonnetAnswers("I can't tell", question: question) == nil)
    }

    @Test func sonnetHoldReadsTrueAsHold() throws {
        let question = DevDecisions.hold(task: "drop the users table", project: "shop")
        let answers = DevDecisions.sonnetAnswers("{\"decision\": true, \"confidence\": 0.95}", question: question)
        #expect(DevDecisions.holdVerdict(answers, engine: .sonnet)?.option == "hold")
    }

    @Test func wityBodyHasReasoningOffAndNoModel() throws {
        let question = DevDecisions.runner(task: "Rename a field")
        let object = try #require(JSONSerialization.jsonObject(with: DevDecisions.wityBody(question)) as? [String: Any])
        #expect(object["reasoning"] as? String == "off")
        #expect(object["model"] == nil)
        let thinking = try #require(JSONSerialization.jsonObject(with: DevDecisions.wityBody(question, thinking: true)) as? [String: Any])
        #expect(thinking["reasoning"] as? String == "auto")
        #expect((object["questions"] as? [String: Any])?.keys.contains("decision") == true)
    }

    @Test func wityAnswersReadLikePrisms() throws {
        let reply = #"{"model":"wity-1","answers":{"decision":{"type":"choice","choice":"fe","probabilities":{"fe":0.99,"be":0.01},"confidence":0.99},"oneOwner":{"type":"noul","noul":0.93}},"metadata":{"reasoning":"off","elapsed_ms":98.5}}"#
        let answers = try #require(PrismWire.answers(from: Data(reply.utf8)))
        #expect(DevDecisions.assignVerdict(answers, cards: crew, engine: .wity)?.option == "fe")
    }

    @Test func optionCountIsTheWidestQuestion() {
        #expect(DevDecisions.optionCount(DevDecisions.assign(task: "x", lead: "Theo", cards: crew)) == 4)
        #expect(DevDecisions.optionCount(DevDecisions.runner(task: "x")) == 2)
    }

    @Test func everyDecisionHasItsOwnSetting() {
        #expect(Set(DevDecisionKind.allCases.map(\.settingKey)).count == DevDecisionKind.allCases.count)
        #expect(DevDecisionKind.assign.settingKey == "v4.decider.assign")
    }

    @Test func logLinesRoundTrip() throws {
        let line = DevDecisionLog(at: Date(timeIntervalSince1970: 1), kind: "assign", engine: "prism", model: "sarvam-prism", task: "Dark mode", options: ["fe", "lead"], answer: "fe", confidence: 0.9, ms: 150, handedTo: nil)
        let back = try JSONDecoder().decode(DevDecisionLog.self, from: JSONEncoder().encode(line))
        #expect(back == line)
    }

    // MARK: Calibrated lines

    @Test func calibratedLinesReplaceTheDefaultsPerEngine() {
        let lines = DevDecisionLines(["prism": ["hold": 0.75, "runner": 0.6], "wity": ["hold": 0.97]])
        let go = DevVerdict(option: "go", confidence: 0.8, stands: false)
        #expect(lines.apply(go, engine: .prism, kind: .hold)?.stands == true)
        #expect(lines.apply(go, engine: .wity, kind: .hold)?.stands == false)
        // No line for this engine and decision: the default verdict is kept as it was.
        #expect(lines.apply(go, engine: .wityThinking, kind: .hold) == go)
        #expect(lines.apply(DevVerdict(option: "strong", confidence: 0.61, stands: false), engine: .prism, kind: .runner)?.stands == true)
    }

    @Test func aHoldAlwaysStandsAndAThinPickNever() {
        let lines = DevDecisionLines(["prism": ["hold": 0.99, "assign": 0.5]])
        #expect(lines.apply(DevVerdict(option: "hold", confidence: 0.55, stands: false), engine: .prism, kind: .hold)?.stands == true)
        #expect(lines.apply(DevVerdict(option: "kadi", confidence: 0.99, stands: true), engine: .prism, kind: .assign, thin: true)?.stands == false)
    }

    @Test func aLineAboveOneAlwaysHandsOver() {
        let lines = DevDecisionLines(["wity": ["place": 1.01]])
        #expect(lines.apply(DevVerdict(option: "new", confidence: 1.0, stands: true), engine: .wity, kind: .place)?.stands == false)
    }

    @Test func linesRoundTripAsJSON() throws {
        let lines = DevDecisionLines(["prism": ["hold": 0.75]])
        #expect(try JSONDecoder().decode(DevDecisionLines.self, from: JSONEncoder().encode(lines)) == lines)
    }

    // MARK: Usage logging

    @Test func fastRepliesCarryTheirUsage() throws {
        let reply = #"{"model":"wity-1","answers":{"decision":{"type":"noul","noul":0.1}},"usage":{"input_tokens":252,"output_tokens":0}}"#
        let usage = try #require(DevCallUsage.fromFastReply(Data(reply.utf8)))
        #expect(usage == DevCallUsage(modelID: "wity-1", inputTokens: 252, outputTokens: 0))
        #expect(DevCallUsage.fromFastReply(Data(#"{"answers":{}}"#.utf8)) == nil)
    }

    @Test func claudeJSONGivesTheTextUsageAndModel() throws {
        let reply = #"{"type":"result","result":"{\"decision\": false, \"confidence\": 0.9}","usage":{"input_tokens":2,"output_tokens":19,"cache_read_input_tokens":649,"cache_creation_input_tokens":2726,"cache_creation":{"ephemeral_1h_input_tokens":2726,"ephemeral_5m_input_tokens":0}},"modelUsage":{"claude-sonnet-5-5":{}}}"#
        let parsed = try #require(DevCallUsage.fromClaudeJSON(reply))
        #expect(parsed.result.contains("decision"))
        #expect(parsed.usage == DevCallUsage(modelID: "claude-sonnet-5-5", inputTokens: 2, outputTokens: 19, cacheReadTokens: 649, cacheWriteTokens: 2726, cacheWrite1hTokens: 2726))
    }

    @Test func oldLogLinesWithoutUsageStillRead() throws {
        let old = #"{"at":0,"kind":"hold","engine":"prism","model":"sarvam-prism","task":"x","options":["false","true"],"answer":"go","confidence":0.9,"ms":200}"#
        let line = try JSONDecoder().decode(DevDecisionLog.self, from: Data(old.utf8))
        #expect(line.usage == nil)
    }
}
