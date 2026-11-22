import Testing
@testable import ClickyCore

struct CallTurnTakingTests {
    @Test func patienceDefaultsToASecondAndAHalfAndStaysInRange() {
        #expect(CallTurnPatience.seconds(saved: nil) == 1.5)
        #expect(CallTurnPatience.seconds(saved: 0) == 1.5)
        #expect(CallTurnPatience.seconds(saved: 0.3) == 0.5)
        #expect(CallTurnPatience.seconds(saved: 9) == 4.0)
        #expect(CallTurnPatience.seconds(saved: 2.5) == 2.5)
    }

    @Test func unfinishedWordsWaitLonger() {
        for words in ["So I was thinking that", "I want to build an app and", "Umm", "the thing is,", "Mujhe lagta hai ki", "Matlab", "and then the…", "Tell me about the?"] {
            #expect(CallTurnEnd.ending(of: words) == .soundsUnfinished, "\(words)")
            #expect(CallTurnEnd.waitSeconds(after: words, patienceSeconds: 2) == 3.0, "\(words)")
        }
    }

    @Test func questionsAndShortAnswersAreQuicker() {
        for words in ["What's the weather in Delhi?", "How about you?", "Yes.", "Thanks!", "okay", "That's it", "Theek hai"] {
            #expect(CallTurnEnd.ending(of: words) == .soundsComplete, "\(words)")
            #expect(CallTurnEnd.waitSeconds(after: words, patienceSeconds: 2) == 1.0, "\(words)")
        }
        // Never quicker than the floor, however impatient.
        #expect(CallTurnEnd.waitSeconds(after: "Yes", patienceSeconds: 1) == CallTurnEnd.shortestSeconds)
    }

    @Test func anOrdinarySentenceWaitsThePatience() {
        #expect(CallTurnEnd.ending(of: "I finished the report today.") == .plain)
        #expect(CallTurnEnd.waitSeconds(after: "I finished the report today.", patienceSeconds: 2.5) == 2.5)
        #expect(CallTurnEnd.waitSeconds(after: "", patienceSeconds: 2) == 2)
    }

    @Test func theLongestWaitIsCapped() {
        #expect(CallTurnEnd.waitSeconds(after: "and", patienceSeconds: 4) == CallTurnEnd.longestSeconds)
    }

    @Test func listenModeSwitches() {
        #expect(CallListenMode.command(in: "Listen mode.") == .start)
        #expect(CallListenMode.command(in: "Vello, listen mode please") == .start)
        #expect(CallListenMode.command(in: "okay just listen for a bit") == .start)
        #expect(CallListenMode.command(in: "Stop listen mode") == .stop)
        #expect(CallListenMode.command(in: "you can talk now") == .stop)
        #expect(CallListenMode.command(in: "Talk normally.") == .stop)
        // A long sentence that mentions it is just talk.
        #expect(CallListenMode.command(in: "I read an article yesterday about how a listen mode in apps could change the way people work") == nil)
        #expect(CallListenMode.command(in: "What's the time?") == nil)
    }

    @Test func spokenToInListenMode() {
        #expect(CallListenMode.isAddressed("Vello, what do you think?"))
        #expect(CallListenMode.isAddressed("Hey Vello tell me something"))
        #expect(CallListenMode.isAddressed("That's the plan, right Vello?"))
        #expect(CallListenMode.isAddressed("Wello what about the budget"))
        #expect(CallListenMode.isAddressed("So what do you think about that?"))
        #expect(CallListenMode.isAddressed("speak about the second idea"))
        #expect(CallListenMode.isAddressed("tumhe kya lagta hai"))
        #expect(!CallListenMode.isAddressed("The quarterly numbers came in higher than expected this time"))
        #expect(!CallListenMode.isAddressed("and then we went to the market"))
    }

    @Test func listenTranscriptSendsOnlyWhatsNew() {
        var transcript = CallListenTranscript()
        transcript.add("We should launch in March.")
        transcript.add("  ")
        transcript.add("The budget is ten lakh.")
        #expect(transcript.heard.count == 2)
        let first = transcript.messageForVello(asking: "Vello, what do you think?", owner: "Addy")
        #expect(first.contains("- We should launch in March."))
        #expect(first.contains("- The budget is ten lakh."))
        #expect(first.contains("Addy is now asking you: Vello, what do you think?"))
        #expect(!transcript.hasUnsent)
        transcript.add("Marketing wants more.")
        let second = transcript.messageForVello(asking: "and the budget?", owner: "Addy")
        #expect(second.contains("- Marketing wants more."))
        #expect(!second.contains("launch in March"))
        let third = transcript.messageForVello(asking: "anything else?", owner: OwnerName.unset)
        #expect(third.contains("Nothing new was heard"))
        #expect(third.contains("The owner is now asking you"))
    }

    @Test func aVeryLongListenLeavesOutTheOldest() {
        var transcript = CallListenTranscript()
        for index in 0..<400 { transcript.add("Line \(index) " + String(repeating: "x", count: 80)) }
        let message = transcript.messageForVello(asking: "sum it up", owner: "Addy")
        #expect(message.contains("earlier lines left out"))
        #expect(message.contains("Line 399"))
        #expect(!message.contains("- Line 0 "))
    }
}

extension CallTurnTakingTests {
    @Test func leavingListenModeSaysSo() {
        var transcript = CallListenTranscript()
        transcript.add("We should launch in March.")
        let message = transcript.messageForVello(asking: "so when do we launch?", owner: "Addy", staysInListenMode: false)
        #expect(message.contains("You were just in listen mode"))
        #expect(message.contains("Listen mode is over now"))
        #expect(!message.contains("You stay in listen mode"))
    }
}

extension CallTurnTakingTests {
    @Test func justListenOnlySwitchesWhenItEndsTheUtterance() {
        #expect(CallListenMode.command(in: "just listen") == .start)
        #expect(CallListenMode.command(in: "okay only listen please") == .start)
        #expect(CallListenMode.command(in: "Vello, listen only for now") == .start)
        // An ordinary turn that happens to hold the words is not the switch.
        #expect(CallListenMode.command(in: "just listen to me, open Safari") == nil)
        #expect(CallListenMode.command(in: "only listen to the first part and tell me") == nil)
        // Naming the mode still works anywhere in a short utterance.
        #expect(CallListenMode.command(in: "go into listen mode for this meeting") == .start)
    }

    @Test func vellosOwnWordsComingBackAreTold() {
        let said = "Sure, I'll get Pointer Assistant to open Safari and search for flights to Goa."
        #expect(CallEcho.soundsLikeVello("open Safari and search for flights", vellosRecentWords: said))
        #expect(CallEcho.soundsLikeVello("I'll get pointer assistant", vellosRecentWords: said))
        #expect(!CallEcho.soundsLikeVello("no wait, search for hotels in Delhi instead", vellosRecentWords: said))
        #expect(!CallEcho.soundsLikeVello("stop", vellosRecentWords: said))
        #expect(!CallEcho.soundsLikeVello("open Safari", vellosRecentWords: ""))
        #expect(!CallEcho.soundsLikeVello("", vellosRecentWords: said))
    }
}
