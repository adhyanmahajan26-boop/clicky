import Testing
@testable import ClickyCore

struct ActionBookingTierTests {
    private func tier(label: String, said: String) -> ActionTier {
        let target = ActionTargetFacts(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "Flights", role: "AXButton", label: label)
        return ActionTierClassifier.classify(.click(elementID: 1), target: target, context: ActionTurnContext(ownerTranscript: said)).tier
    }

    @Test func continueOnABookingTaskNeedsAYes() {
        // The bug: Clicky pressed Continue under "Book with IndiGo" after saying it would ask first.
        #expect(tier(label: "Continue", said: "Hold a seat on this flight, ask me first") == .confirm)
        #expect(tier(label: "Next", said: "Book me a ticket to Goa") == .confirm)
    }

    @Test func buttonsThatBookNeedAYesWhateverTheTask() {
        #expect(tier(label: "Book with IndiGo", said: "open that") == .confirm)
        #expect(tier(label: "Hold fare", said: "open that") == .confirm)
        #expect(tier(label: "Continue to payment", said: "open that") == .confirm)
    }

    @Test func aContinueOnAnythingElseStaysAsItWas() {
        #expect(tier(label: "Continue", said: "Set up my new notes app") != .confirm)
    }
}
