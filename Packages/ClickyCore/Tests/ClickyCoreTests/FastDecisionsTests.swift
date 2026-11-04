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

    private func routed(_ choice: String, _ top: Double, job: Double?) -> FastDecisions.Routing {
        var answers = [FastDecisionQuestion.id: PrismAnswer(choice: choice, probability: top, probabilities: [choice: top])]
        if let job { answers[FastDecisions.teamsJobID] = PrismAnswer(choice: job >= 0.5 ? "true" : "false", probability: max(job, 1 - job), probabilities: ["true": job, "false": 1 - job]) }
        return FastDecisions.routing(from: answers)
    }

    @Test func aTeammateNeedsBothAnswersToBeClear() {
        #expect(routed("accountant", 0.95, job: 0.95) == .teammate("accountant"))
        #expect(routed("accountant", 0.95, job: 0.2) == .keep)
        #expect(routed("accountant", 0.4, job: 0.95) == .keep)
        #expect(routed("accountant", 0.95, job: nil) == .keep)
        #expect(routed(FastDecisions.keepIt, 0.95, job: 0.95) == .keep)
        #expect(FastDecisions.routing(from: nil) == .keep)
    }

    @Test func routingAsksBothQuestionsOfOneState() {
        let team = [FastDecisionTeammate(id: "a", name: "A", job: "Invoices"), FastDecisionTeammate(id: "b", name: "B", job: "Mail")]
        let question = FastDecisions.whoTakesIt(message: "hello", leader: "Theo", team: team)
        #expect(Set(question.questions.keys) == [FastDecisionQuestion.id, FastDecisions.teamsJobID])
        #expect(question.question.criteria.keys.sorted() == ["a", "b"])
        #expect(question.state.contains("Invoices"))
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

    @Test func whatCountsAsARequestToPress() {
        #expect(FastDecisions.pressRequest("press Continue") == ["press continue"])
        #expect(FastDecisions.pressRequest("Clicky, please click the blue button then press save") == ["click the blue button", "press save"])
        #expect(FastDecisions.pressRequest("press this and that") == ["press this", "that"])
        #expect(FastDecisions.pressRequest("continue wala button dabao") != nil)
        #expect(FastDecisions.pressRequest("how do I press continue?") == nil)
        #expect(FastDecisions.pressRequest("what does this button do") == nil)
        #expect(FastDecisions.pressRequest("the press release is out") == nil)
    }

    @Test func aLabelTwoItemsShareIsNeverClear() {
        let options = [FastPressOption(id: "1", role: "btn", label: "Continue", app: "Chrome"), FastPressOption(id: "2", role: "btn", label: "Continue", app: "Chrome"),
                       FastPressOption(id: "3", role: "btn", label: "Back", app: "Chrome")]
        func answers(_ id: String, _ one: Double) -> [String: PrismAnswer] {
            [FastDecisionQuestion.id: PrismAnswer(choice: id, probability: 0.95, probabilities: [id: 0.95]),
             FastDecisions.namesOneID: PrismAnswer(choice: "true", probability: one, probabilities: ["true": one])]
        }
        #expect(FastDecisions.pressPick(from: answers("1", 0.95), options: options) == nil)
        #expect(FastDecisions.pressPick(from: answers("3", 0.95), options: options)?.label == "Back")
        #expect(FastDecisions.pressPick(from: answers("3", 0.3), options: options) == nil)
        #expect(FastDecisions.pressPick(from: nil, options: options) == nil)
    }
}
