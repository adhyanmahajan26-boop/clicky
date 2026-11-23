import Foundation
import Testing
@testable import ClickyCore

/// "Hey Vello" calls Vello (a call, with its apps); Pointer Assistant keeps its own names.
struct WakeTargetTests {
    let matcher = WakeWordMatcher()

    func phrase(_ text: String) -> String? {
        matcher.firstMatch(in: WakeWordMatcherTests.timedWords(text))?.phrase
    }

    @Test(arguments: ["hey vello find my mails", "hi velo, check my inbox", "hey theo what's new", "okay vello"])
    func velloNamesCallVello(_ text: String) throws {
        let matchedPhrase = try #require(phrase(text), "\(text)")
        #expect(WakeTarget.of(phrase: matchedPhrase, assistantName: "Vello") == .vello, "\(text)")
    }

    @Test(arguments: ["hey pointer open notes", "hey pointer assistant open notes", "hey pointers scroll down", "hey claudia open safari"])
    func pointerNamesWakePointerAssistant(_ text: String) throws {
        let matchedPhrase = try #require(phrase(text), "\(text)")
        #expect(WakeTarget.of(phrase: matchedPhrase, assistantName: "Vello") == .pointerAssistant, "\(text)")
    }

    @Test func pointerIsADefaultPhrase() {
        #expect(WakeWordMatcher.defaultPhrases.contains("hey pointer"))
        #expect(WakeWordMatcher.defaultPhrases.contains("hey vello"))
    }

    @Test(arguments: ["hey painter", "hey printer", "hey pointed"])
    func wordsNearPointerDontWake(_ text: String) {
        #expect(phrase(text) == nil, "\(text)")
    }

    @Test func theNameTheOwnerGaveVelloCallsVello() {
        #expect(WakeTarget.of(phrase: "hey jarvis", assistantName: "Jarvis") == .vello)
        #expect(WakeTarget.of(phrase: "hey jarvis", assistantName: "Vello") == .pointerAssistant)
        // Pointer Assistant's own names stay its own, whatever Vello is called.
        #expect(WakeTarget.of(phrase: "hey pointer", assistantName: "Pointer") == .pointerAssistant)
    }

    @Test func pointerAssistantTurnDropsTheRestOfItsName() {
        #expect(WakeTarget.turnText("assistant, open notes", for: .pointerAssistant) == "open notes")
        #expect(WakeTarget.turnText("Assistant open notes", for: .pointerAssistant) == "open notes")
        #expect(WakeTarget.turnText("assistant", for: .pointerAssistant) == "")
        #expect(WakeTarget.turnText("open the assistant panel", for: .pointerAssistant) == "open the assistant panel")
        #expect(WakeTarget.turnText(" find my mails ", for: .vello) == "find my mails")
    }
}
