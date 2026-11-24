import Foundation
import Testing
@testable import ClickyCore

struct CallGroupModeTests {
    @Test func shortWordsSwitchGroupModeOnAndOff() {
        for words in ["group mode", "Vello, group mode please", "we're in an X space now", "you're on a Twitter Space", "space mode", "sab se baat karo", "X की space में हैं"] {
            #expect(CallGroupMode.command(in: words) == .start, "\(words)")
        }
        for words in ["group mode off", "stop group mode", "just us now", "the space is over", "talk normally"] {
            #expect(CallGroupMode.command(in: words) == .stop, "\(words)")
        }
        // Ordinary talk, and long talk that only mentions a Space, are left to the brain.
        for words in ["what's the weather", "I need some space on my desk", "we were in the space of two days",
                      "so yesterday I was listening to an X space about startups and they said something about funding and runway"] {
            #expect(CallGroupMode.command(in: words) == nil, "\(words)")
        }
    }

    @Test func aGroupTurnIsLetGoAtShortPausesAndNeverOverSomeone() {
        #expect(CallGroupMode.waitSeconds(ownWait: 1.5, isAddressed: false) == 1.0)
        #expect(CallGroupMode.waitSeconds(ownWait: 2.5, isAddressed: true) == 0.7)
        #expect(CallGroupMode.waitSeconds(ownWait: 0.6, isAddressed: false) == 0.6)
        // Someone talking: never, however long it's been held.
        #expect(!CallGroupMode.releasesTurn(someoneIsTalking: true, secondsSinceVoiceStopped: 9, secondsSincePartialWords: 9, waitSeconds: 1, secondsHeld: 60))
        // A pause as long as the wait.
        #expect(CallGroupMode.releasesTurn(someoneIsTalking: false, secondsSinceVoiceStopped: 1.0, secondsSincePartialWords: nil, waitSeconds: 1, secondsHeld: 2))
        #expect(!CallGroupMode.releasesTurn(someoneIsTalking: false, secondsSinceVoiceStopped: 0.4, secondsSincePartialWords: nil, waitSeconds: 1, secondsHeld: 2))
        // Talk that has run on for a while goes at its first short gap, so Vello keeps up with a lively Space.
        #expect(CallGroupMode.releasesTurn(someoneIsTalking: false, secondsSinceVoiceStopped: 0.4, secondsSincePartialWords: 0.1, waitSeconds: 1, secondsHeld: 15))
        #expect(!CallGroupMode.releasesTurn(someoneIsTalking: false, secondsSinceVoiceStopped: 0.1, secondsSincePartialWords: 0.1, waitSeconds: 1, secondsHeld: 15))
    }

    @Test func linesAreJoinedBySpeakerAndLabelled() {
        var lines: [CallGroupMode.HeardLine] = []
        lines = CallGroupMode.adding("Vello, say hi", isOwner: true, to: lines)
        lines = CallGroupMode.adding("to everyone", isOwner: true, to: lines)
        lines = CallGroupMode.adding("Hi Velo, how are you?", isOwner: false, to: lines)
        lines = CallGroupMode.adding("  ", isOwner: true, to: lines)
        #expect(lines == [.init(isOwner: true, text: "Vello, say hi to everyone"), .init(isOwner: false, text: "Hi Velo, how are you?")])
        #expect(CallGroupMode.labelled(lines, owner: "Addy") == "Addy: Vello, say hi to everyone\nSomeone: Hi Velo, how are you?")
        #expect(CallGroupMode.labelled(lines, owner: "") == "Owner: Vello, say hi to everyone\nSomeone: Hi Velo, how are you?")
    }

    @Test func theBrainIsToldWhoSpokeAndHowToStayQuiet() {
        let lines = [CallGroupMode.HeardLine(isOwner: false, text: "Velo, rate my singing out of ten")]
        let message = CallGroupMode.message(lines: lines, owner: "Addy", botName: "Vello", isAddressed: true)
        #expect(message.contains("Someone: Velo, rate my singing out of ten"))
        #expect(message.contains("X Space"))
        #expect(message.contains("[PASS]"))
        #expect(message.contains("never say you're staying quiet"))
        #expect(message.contains("Fellow"))
        #expect(message.hasSuffix("You were just spoken to, so answer.)"))
        let unaddressed = CallGroupMode.message(lines: lines, owner: "Addy", botName: "Observer", isAddressed: false)
        #expect(!unaddressed.contains("You were just spoken to"))
        #expect(unaddressed.contains("(Observer)"))
    }

    @Test func passIsFoundHoweverItIsWritten() {
        #expect(CallGroupMode.saysPass("[PASS]"))
        #expect(CallGroupMode.saysPass(" [ pass ] "))
        #expect(CallGroupMode.saysPass("Hmm.\n[PASS]"))
        #expect(!CallGroupMode.saysPass("Pass me the salt"))
        #expect(!CallGroupMode.saysPass("[PASSWORD]"))
    }

    @Test func switchingIsAcknowledgedInTheCallsLanguage() {
        #expect(CallGroupMode.acknowledgement(turnOn: true, speaksHindi: false, readsDevanagari: false).hasPrefix("Okay, I'm in"))
        #expect(CallGroupMode.acknowledgement(turnOn: true, speaksHindi: true, readsDevanagari: true).contains("सबके साथ"))
        #expect(CallGroupMode.acknowledgement(turnOn: false, speaksHindi: true, readsDevanagari: false) == "Theek hai, ab sirf hum dono.")
    }
}
