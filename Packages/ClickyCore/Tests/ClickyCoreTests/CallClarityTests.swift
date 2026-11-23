import Foundation
import Testing
@testable import ClickyCore

/// Calls with a bot on a local model, Air, 24 Nov: the same words three times in one turn, a question asked twice with an
/// answer the owner never heard, and "Observer" not counting as its name.
struct CallClarityTests {
    @Test func theSameStretchHandedOverAgainIsNotAddedTwice() {
        let held = "देखो राम भाई मैं कह रहा था तुम्हें सपोर्ट"
        #expect(CallHeldWords.adding("देखो राम भाई मैं कह रहा था तुम्हें सपोर्ट", to: held) == held)
        // A part of it, with different punctuation, is still a repeat.
        #expect(CallHeldWords.adding("मैं कह रहा था,", to: held) == held)
        #expect(CallHeldWords.adding("Open Safari.", to: "open safari") == "open safari")
    }

    @Test func wordsCarryingOnFromTheEndAddOnlyTheRest() {
        #expect(CallHeldWords.adding("kya scene hai aaj ka plan", to: "bhai kya scene hai") == "bhai kya scene hai aaj ka plan")
        // One shared word is chance, so the words are added as they are.
        #expect(CallHeldWords.adding("hai na", to: "accha hai") == "accha hai hai na")
    }

    @Test func newWordsAreAddedAsBefore() {
        #expect(CallHeldWords.adding("what do you think", to: "marriage is a bad deal") == "marriage is a bad deal what do you think")
        #expect(CallHeldWords.adding("hello there", to: "") == "hello there")
        #expect(CallHeldWords.adding("  ", to: "hello") == "hello")
    }

    private struct Message: Equatable {
        let role: String
        let text: String
    }

    @Test func aTurnAskedAgainLeavesTheConversation() {
        let earlier = [Message(role: "user", text: "hi"), Message(role: "assistant", text: "Hey Addy.")]
        // Its answer had been written and saved before the owner went on.
        let answered = earlier + [Message(role: "user", text: "is marriage worth it"), Message(role: "assistant", text: "Men were first, but")]
        #expect(ForgottenTurn.dropping(turnText: "is marriage worth it", from: answered, role: { $0.role }, text: { $0.text }) == earlier)
        // Only the question was there.
        let asked = earlier + [Message(role: "user", text: "is marriage worth it")]
        #expect(ForgottenTurn.dropping(turnText: "is marriage worth it", from: asked, role: { $0.role }, text: { $0.text }) == earlier)
        // Another turn's messages are never touched.
        #expect(ForgottenTurn.dropping(turnText: "something else", from: answered, role: { $0.role }, text: { $0.text }) == answered)
        #expect(ForgottenTurn.dropping(turnText: "hi", from: answered, role: { $0.role }, text: { $0.text }) == answered)
        #expect(ForgottenTurn.dropping(turnText: "x", from: [Message](), role: { $0.role }, text: { $0.text }).isEmpty)
    }

    @Test func aBotAnswersToAWordOfItsName() {
        let names = CallListenMode.names(forBotNamed: "Super Neutral Observer")
        #expect(names.contains("super neutral observer"))
        #expect(names.contains("observer"))
        #expect(names.contains("neutral"))
        #expect(!names.contains("super"))
        #expect(CallListenMode.callsVelloByName("Observer, what's the main point here?", assistantNames: names))
        #expect(CallListenMode.isAddressed("so what do you make of it, observer", assistantNames: names))
        #expect(!CallListenMode.callsVelloByName("that was super fun yesterday", assistantNames: names))
        // Vello's own call keeps its usual names.
        #expect(CallListenMode.names(forBotNamed: nil) == CallListenMode.defaultAssistantNames)
        #expect(CallListenMode.names(forBotNamed: "Vello").contains("vello"))
    }
}
