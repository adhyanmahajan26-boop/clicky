import Testing
@testable import ClickyCore

struct ActionBookingTierTests {
    private func tier(label: String, said: String) -> ActionTier {
        let target = ActionTargetFacts(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "Flights", role: "AXButton", label: label)
        return ActionTierClassifier.classify(.click(elementID: 1), target: target, context: ActionTurnContext(ownerTranscript: said)).tier
    }

    @Test func continueOnABookingTaskNeedsAYesWhenTheOwnerAskedToBeAsked() {
        // The bug: Clicky pressed Continue under "Book with IndiGo" after saying it would ask first.
        #expect(tier(label: "Continue", said: "Hold a seat on this flight, ask me first") == .confirm)
        // Hands-free (2026-11-24): an onward step is only the countdown; the buttons that book or pay still wait for a yes.
        #expect(tier(label: "Next", said: "Book me a ticket to Goa") == .countdown)
        #expect(tier(label: "Book with IndiGo", said: "Book me a ticket to Goa") == .confirm)
        #expect(tier(label: "Pay now", said: "Book me a ticket to Goa and pay for it") == .confirm)
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
