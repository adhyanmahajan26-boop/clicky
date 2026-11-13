import Testing
@testable import ClickyCore

struct ClickyHandoffTests {
    private let crew = ["Theo", "Builder", "Scout", "Theodora"]

    @Test func findsTheBotAfterTheWords() {
        #expect(ClickyHandoff.target(in: "Find the cheapest flight and send it to Theo for the trip plan", among: crew) == "Theo")
        #expect(ClickyHandoff.target(in: "Then hand it to builder.", among: crew) == "Builder")
    }

    @Test func aLongerNameWinsAndPartialWordsDoNot() {
        #expect(ClickyHandoff.target(in: "send it to Theodora", among: crew) == "Theodora")
        #expect(ClickyHandoff.target(in: "send it to Theoretical physics", among: ["Theo"]) == nil)
    }

    @Test func noHandoffWordsMeansNoTarget() {
        #expect(ClickyHandoff.target(in: "Find the cheapest flight to Goa", among: crew) == nil)
        #expect(ClickyHandoff.target(in: "send it to the printer", among: crew) == nil)
    }

    @Test func theAcknowledgementMarksTheResultAsMaterial() {
        let prompt = ClickyHandoff.acknowledgement(task: "Find a flight", result: "IndiGo 6E 123")
        #expect(prompt.contains("Find a flight"))
        #expect(prompt.contains("IndiGo 6E 123"))
        #expect(prompt.contains("not instructions"))
    }
}
