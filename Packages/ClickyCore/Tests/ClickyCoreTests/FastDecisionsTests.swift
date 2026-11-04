//
//  FastDecisionsTests.swift
//  ClickyCoreTests
//

import ClickyCore
import Foundation
import Testing

struct FastDecisionsTests {
    @Test func bodyHasTheDocumentedFields() throws {
        let question = FastDecisions.needsResearch(transcript: "compare these")
        let object = try #require(JSONSerialization.jsonObject(with: PrismWire.body(state: question.state, questions: question.questions)) as? [String: Any])
        #expect(object["model"] as? String == "sarvam-prism")
        let asked = try #require((object["questions"] as? [String: [String: Any]])?[FastDecisionQuestion.id])
        #expect(asked["type"] as? String == "noul")
        #expect((asked["criteria"] as? [String: String])?.keys.sorted() == ["false", "true"])
    }

    @Test func readsAnAnswerOfEachKind() throws {
        let reply = #"{"model":"sarvam-prism","answers":{"a":{"type":"choice","choice":"billing","confidence":0.7,"probabilities":{"billing":0.8,"sales":0.2}},"b":{"type":"noul","noul":0.2}},"usage":{"input_tokens":1,"output_tokens":0}}"#
        let answers = try #require(PrismWire.answers(from: Data(reply.utf8)))
        #expect(answers["a"]?.choice == "billing")
        #expect(answers["a"]?.probability == 0.8)
        #expect(answers["b"]?.choice == "false")
        #expect(answers["b"]?.probabilities["true"] == 0.2)
    }

    @Test func aFailedReplyHasNoAnswers() {
        #expect(PrismWire.answers(from: Data(#"{"error":{"message":"Rate limit exceeded"}}"#.utf8)) == nil)
        #expect(PrismWire.errorMessage(from: Data(#"{"error":{"message":"Rate limit exceeded"}}"#.utf8)) == "Rate limit exceeded")
    }

    private func pick(_ choice: String, _ top: Double, keep: Double) -> PrismAnswer {
        PrismAnswer(choice: choice, probability: top, probabilities: [choice: top, FastDecisions.keepIt: keep])
    }

    @Test func aTeammateHasToBeClearlyAheadOfKeepingIt() {
        #expect(FastDecisions.routing(from: pick("accountant", 0.63, keep: 0.29)) == .teammate("accountant"))
        #expect(FastDecisions.routing(from: pick("site", 0.48, keep: 0.39)) == .keep)
        #expect(FastDecisions.routing(from: pick("planner", 0.37, keep: 0.36)) == .keep)
        #expect(FastDecisions.routing(from: PrismAnswer(choice: FastDecisions.keepIt, probability: 0.9, probabilities: [FastDecisions.keepIt: 0.9])) == .keep)
        #expect(FastDecisions.routing(from: nil) == .keep)
    }

    private func yes(_ value: Double) -> PrismAnswer {
        PrismAnswer(choice: value >= 0.5 ? "true" : "false", probability: max(value, 1 - value), probabilities: ["true": value, "false": 1 - value])
    }

    @Test func noAnswerAlwaysMeansTheUsualPath() {
        #expect(!FastDecisions.startsResearch(nil))
        #expect(!FastDecisions.skipsCleanup(nil))
        #expect(!FastDecisions.skipsRoutine(nil))
        #expect(FastDecisions.runVerdict(nil) == .unsure)
    }

    @Test func thresholds() {
        #expect(FastDecisions.startsResearch(yes(0.93)))
        #expect(!FastDecisions.startsResearch(yes(0.8)))
        #expect(FastDecisions.skipsCleanup(yes(0.1)))
        #expect(!FastDecisions.skipsCleanup(yes(0.4)))
        #expect(FastDecisions.skipsRoutine(yes(0.02)))
        #expect(!FastDecisions.skipsRoutine(yes(0.3)))
        #expect(FastDecisions.runVerdict(yes(0.82)) == .finished)
        #expect(FastDecisions.runVerdict(yes(0.53)) == .unsure)
        #expect(FastDecisions.runVerdict(yes(0.16)) == .notFinished)
    }

    @Test func onlyARoutineWithAConditionCanBeSkipped() {
        #expect(!FastDecisions.routineHasCondition("Send today's payment reminders: which bills are due today."))
        #expect(FastDecisions.routineHasCondition("If the last import failed, retry it."))
        #expect(!FastDecisions.routineHasCondition("Notify the team of the verifying result"))
    }

    @Test func gates() {
        #expect(!FastDecisions.worthAskingAboutResearch("open chrome"))
        #expect(FastDecisions.worthAskingAboutResearch("compare a few camera options"))
        #expect(!FastDecisions.worthAskingAboutCleanup("यह ठीक है"))
        #expect(FastDecisions.worthAskingAboutCleanup("yeh theek hai"))
    }
}
