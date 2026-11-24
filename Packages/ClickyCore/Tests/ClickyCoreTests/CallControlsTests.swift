import Testing
@testable import ClickyCore

struct CallControlsTests {
    private func streamed(_ reply: String, size: Int) -> (speech: String, controls: [CallControl]) {
        var stream = CallControlStream()
        var speech = ""
        var controls: [CallControl] = []
        var rest = Substring(reply)
        while !rest.isEmpty {
            let piece = rest.prefix(size)
            rest = rest.dropFirst(size)
            let out = stream.feed(String(piece))
            speech += out.speech
            controls += out.controls
        }
        let last = stream.finish()
        return (speech + last.speech, controls + last.controls)
    }

    @Test func switchesAreTakenOutWhereverTheReplySplits() {
        let reply = "Turning it on now. [POINTER: on] And your morning brief. [ROUTINE: Morning brief] [CLICKY: open Codex]"
        for size in [1, 2, 3, 5, 9, 200] {
            let out = streamed(reply, size: size)
            #expect(out.controls == [.pointerAssistant(turnOn: true), .runRoutine(name: "Morning brief")], "chunk size \(size)")
            #expect(out.speech == "Turning it on now.  And your morning brief.  [CLICKY: open Codex]", "chunk size \(size)")
        }
    }

    @Test func otherBracketsAndPointTagsPassThrough() {
        let out = streamed("see [1], [Point] and [POINT:10,20:Save] and [Pointer Assistant] please", size: 3)
        #expect(out.controls.isEmpty)
        #expect(out.speech == "see [1], [Point] and [POINT:10,20:Save] and [Pointer Assistant] please")
    }

    @Test func offAndPlaceholdersAndUnclosedTags() {
        #expect(streamed("Done. [POINTER: off]", size: 4).controls == [.pointerAssistant(turnOn: false)])
        let placeholder = streamed("Say [POINTER: on or off] like that", size: 4)
        #expect(placeholder.controls.isEmpty)
        #expect(placeholder.speech == "Say  like that")
        let unclosed = streamed("Okay. [ROUTINE: Morning", size: 4)
        #expect(unclosed.controls.isEmpty)
        #expect(unclosed.speech == "Okay. ")
        #expect(CallControlStream.extract(from: "Sure [ROUTINE: its name]").controls.isEmpty)
    }

    @Test func routinesAreFoundLoosely() {
        let names = ["Morning brief", "Weekly invoices", "Check inbox"]
        #expect(CallControl.routine(named: "morning brief", among: names) == 0)
        #expect(CallControl.routine(named: "the weekly invoices one", among: names) == 1)
        #expect(CallControl.routine(named: "invoices", among: names) == 1)
        #expect(CallControl.routine(named: "Check-Inbox", among: names) == 2)
        #expect(CallControl.routine(named: "brief", among: ["Morning brief", "Evening brief"]) == nil)
        #expect(CallControl.routine(named: "anything", among: []) == nil)
    }

    @Test func ownChatOnACall() {
        #expect(CallOwnChat.meansOwnChat("Vello", ceoName: "Vello"))
        #expect(CallOwnChat.meansOwnChat("yourself", ceoName: "Vello"))
        #expect(CallOwnChat.meansOwnChat("Jarvis", ceoName: "Jarvis"))
        #expect(!CallOwnChat.meansOwnChat("Researcher", ceoName: "Vello"))
        #expect(!CallOwnChat.meansOwnChat("", ceoName: "Vello"))
        #expect(CallOwnChat.ownerMessage(ownerWordsNewestFirst: "what does it say\nopen my notion roadmap") == "On our call: open my notion roadmap what does it say")
        #expect(CallOwnChat.ownerMessage(ownerWordsNewestFirst: "  \n ") == "")
        #expect(CallOwnChat.report(answer: "**Roadmap**: ship it.\n```json\n{}\n```") == "Your text chat answered: Roadmap: ship it.")
        #expect(CallOwnChat.report(answer: "").hasPrefix("Your text chat finished"))
        #expect(CallOwnChat.taskNote(task: "read the roadmap", owner: "Priya").contains("Priya"))
    }

    @Test func openingACodingAgentToPromptItCounts() {
        #expect(CodingHarnessWords.asksToSendToCode("open codex in clicky and tell it to fix the notch"))
        #expect(CodingHarnessWords.asksToSendToCode("open claude code in my folder and prompt it to add tests"))
        #expect(CodingHarnessWords.asksToSendToCode("prompt claude code in clicky to fix the build"))
        #expect(!CodingHarnessWords.asksToSendToCode("open codex"))
        #expect(!CodingHarnessWords.asksToSendToCode("what is a good prompt"))
    }

    @Test func groupAndPassAreTakenOutWhereverTheReplySplits() {
        for size in [1, 2, 3, 7, 200] {
            let pass = streamed("[PASS]", size: size)
            #expect(pass.controls == [.stayQuiet], "chunk size \(size)")
            #expect(pass.speech.isEmpty, "chunk size \(size)")
            let group = streamed("Got it, I'm in the Space with you. [GROUP: on]", size: size)
            #expect(group.controls == [.groupMode(turnOn: true)], "chunk size \(size)")
            #expect(group.speech == "Got it, I'm in the Space with you. ", "chunk size \(size)")
        }
        #expect(streamed("Just us. [GROUP: off]", size: 3).controls == [.groupMode(turnOn: false)])
        // Words that only look like the tags are spoken as written.
        let words = streamed("[Pass the salt] and [PASSWORD] and [Group photo]", size: 4)
        #expect(words.controls.isEmpty)
        #expect(words.speech == "[Pass the salt] and [PASSWORD] and [Group photo]")
    }

    @Test func callHowToNamesTheNewLines() {
        let howTo = ClickyTeamPrompts.callHowTo(owner: "Priya", ownChatApps: ["Notion", "Gmail"])
        #expect(howTo.contains("[POINTER: off]"))
        #expect(howTo.contains("[GROUP: on]"))
        #expect(howTo.contains("[LOOK]"))
        #expect(howTo.contains("<actions>"))
        #expect(!howTo.contains("[CLICKY:"))
        #expect(ClickyTeamPrompts.callHowTo(owner: "Priya", hasHands: false).contains("[POINTER: on]"))
        #expect(howTo.contains("[ROUTINE:"))
        #expect(howTo.contains("[TELL: Vello:"))
        #expect(howTo.contains("Notion, Gmail"))
        #expect(!ClickyTeamPrompts.callHowTo(owner: "Priya").contains("Its apps:"))
    }
}
