//
//  FastDecisionsTests.swift
//  ClickyCoreTests
//

import ClickyCore
import Foundation
import Testing

struct FastDecisionsTests {
    @Test func bodyHasTheDocumentedFields() throws {
        let question = FastDecisions.dictationNeedsCleanup(text: "compare these")
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

    private func yes(_ value: Double) -> PrismAnswer {
        PrismAnswer(choice: value >= 0.5 ? "true" : "false", probability: max(value, 1 - value), probabilities: ["true": value, "false": 1 - value])
    }

    @Test func noAnswerAlwaysMeansTheUsualPath() {
        #expect(!FastDecisions.skipsCleanup(nil))
    }

    @Test func thresholds() {
        #expect(FastDecisions.skipsCleanup(yes(0.1)))
        #expect(!FastDecisions.skipsCleanup(yes(0.4)))
    }

    @Test func gates() {
        #expect(!FastDecisions.worthAskingAboutCleanup("यह ठीक है"))
        #expect(FastDecisions.worthAskingAboutCleanup("yeh theek hai"))
    }

    @Test func whatCountsAsARequestToPress() {
        #expect(FastDecisions.pressRequest("press Continue") == ["press continue"])
        #expect(FastDecisions.pressRequest("Clicky, please click the blue button then press save") == ["click the blue button", "press save"])
        #expect(FastDecisions.pressRequest("press this and that") == ["press this", "press that"])
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
        let close = [FastDecisionQuestion.id: PrismAnswer(choice: "3", probability: 0.47, probabilities: ["3": 0.47, "1": 0.3]),
                     FastDecisions.namesOneID: PrismAnswer(choice: "true", probability: 0.95, probabilities: ["true": 0.95])]
        #expect(FastDecisions.pressPick(from: close, options: options) == nil)
    }
}
