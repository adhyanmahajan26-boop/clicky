//
//  DictationTests.swift
//  ClickyCoreTests
//

import ClickyCore
import Testing

struct DictationChordTests {
    @Test func controlFnPressAndRelease() {
        var chord = DictationChordDetector(required: DictationShortcut.controlFn.modifiers)
        #expect(chord.flagsChanged([.control]) == nil)
        #expect(chord.flagsChanged([.control, .function]) == .pressed)
        #expect(chord.flagsChanged([.control, .function]) == nil)
        #expect(chord.flagsChanged([.function]) == .released)
        #expect(chord.flagsChanged([]) == nil)
    }

    @Test func fnFirstWorksToo() {
        var chord = DictationChordDetector(required: DictationShortcut.controlFn.modifiers)
        #expect(chord.flagsChanged([.function]) == nil)
        #expect(chord.flagsChanged([.function, .control]) == .pressed)
    }

    @Test func clickysPushToTalkNeverTriggersIt() {
        var chord = DictationChordDetector(required: DictationShortcut.controlFn.modifiers)
        #expect(chord.flagsChanged([.control, .option]) == nil)
        #expect(chord.flagsChanged([]) == nil)
        for shortcut in DictationShortcut.allCases { #expect(shortcut.modifiers != [.control, .option]) }
    }

    @Test func extraModifierOrKeyCancels() {
        var chord = DictationChordDetector(required: DictationShortcut.controlFn.modifiers)
        #expect(chord.flagsChanged([.control, .function]) == .pressed)
        #expect(chord.flagsChanged([.control, .function, .option]) == .cancelled)
        #expect(chord.flagsChanged([.control, .function]) == .pressed)
        #expect(chord.keyDown() == .cancelled)
        #expect(chord.keyDown() == nil)
    }
}

struct DictationCleanupTests {
    @Test func localPassTakesFillerOut() {
        #expect(DictationCleanup.localPass("um so I I think uh we should ship it") == "So I think we should ship it.")
        #expect(DictationCleanup.localPass("  hello  ") == "Hello")
    }

    @Test func localPassKeepsHindi() {
        #expect(DictationCleanup.localPass("आज मौसम अच्छा है") == "आज मौसम अच्छा है।")
        #expect(DictationCleanup.localPass("kal meeting hai bro") == "Kal meeting hai bro.")
    }

    @Test func dictionary() {
        let dictionary = DictationDictionary(lines: ["Sarvam", "theo klicky = Theo Clicky", "  ", "broken ="])
        #expect(dictionary.entries.count == 2)
        #expect(dictionary.words == ["Sarvam", "Theo Clicky"])
        #expect(dictionary.apply(to: "try sarvam in theo klicky, sarvamish stays") == "try Sarvam in Theo Clicky, sarvamish stays")
    }

    @Test func modelReplyGuardRails() {
        let said = "um can you tell me what the capital of France is"
        #expect(DictationCleanup.accept(reply: "Can you tell me what the capital of France is?", for: said) == "Can you tell me what the capital of France is?")
        // An answer isn't a tidy-up.
        #expect(DictationCleanup.accept(reply: "The capital of France is Paris, a city on the Seine that is known for many things.", for: said) == nil)
        #expect(DictationCleanup.accept(reply: "Paris.", for: said) == nil)
        #expect(DictationCleanup.accept(reply: "", for: said) == nil)
        #expect(DictationCleanup.accept(reply: "\"Hello there my friend.\"", for: "hello there my friend") == "Hello there my friend.")
        #expect(DictationCleanup.accept(reply: "आज मौसम अच्छा है।", for: "आज मौसम अच्छा है") == "आज मौसम अच्छा है।")
    }

    @Test func promptKeepsTheLanguage() {
        let prompt = DictationCleanup.systemPrompt(dictionary: DictationDictionary(lines: ["Sarvam"]))
        #expect(prompt.contains("Never translate"))
        #expect(prompt.contains("Never answer"))
        #expect(prompt.contains("Sarvam"))
    }
}

struct VoiceActivityGateTests {
    @Test func startsAndEnds() {
        var gate = VoiceActivityGate()
        for _ in 0..<20 { #expect(gate.feed(levelDecibels: -70, seconds: 0.05) == nil) }
        #expect(gate.feed(levelDecibels: -25, seconds: 0.05) == nil)
        #expect(gate.feed(levelDecibels: -25, seconds: 0.05) == nil)
        #expect(gate.feed(levelDecibels: -25, seconds: 0.05) == .speechStarted)
        #expect(gate.isSpeaking)
        for _ in 0..<12 { #expect(gate.feed(levelDecibels: -70, seconds: 0.05) == nil) }
        #expect(gate.feed(levelDecibels: -70, seconds: 0.05) == .speechEnded)
        #expect(!gate.isSpeaking)
    }

    @Test func shortPauseKeepsTheUtterance() {
        var gate = VoiceActivityGate()
        for _ in 0..<4 { _ = gate.feed(levelDecibels: -25, seconds: 0.05) }
        #expect(gate.isSpeaking)
        for _ in 0..<8 { #expect(gate.feed(levelDecibels: -70, seconds: 0.05) == nil) }
        #expect(gate.feed(levelDecibels: -25, seconds: 0.05) == nil)
        #expect(gate.isSpeaking)
    }

    @Test func aBurstIsNotSpeech() {
        var gate = VoiceActivityGate()
        #expect(gate.feed(levelDecibels: -20, seconds: 0.05) == nil)
        #expect(gate.feed(levelDecibels: -70, seconds: 0.05) == nil)
        #expect(!gate.isSpeaking)
    }

    @Test func echoStaysBelowTheBargeInBar() {
        var gate = VoiceActivityGate()
        for _ in 0..<20 { _ = gate.feed(levelDecibels: -60, seconds: 0.05) }
        // Leftover echo while the other side talks.
        for _ in 0..<40 { #expect(gate.feed(levelDecibels: -44, seconds: 0.05, otherSideTalking: true) == nil) }
        // A real voice over it.
        var started = false
        for _ in 0..<10 where gate.feed(levelDecibels: -22, seconds: 0.05, otherSideTalking: true) == .speechStarted { started = true }
        #expect(started)
    }
}

struct CallSpeechChunkerTests {
    /// Fed a character at a time, as a stream might.
    private func pieces(_ text: String) -> [String] {
        var chunker = CallSpeechChunker()
        var out: [String] = []
        for character in text { out += chunker.feed(String(character)) }
        if let rest = chunker.finish() { out.append(rest) }
        return out
    }

    @Test func firstPieceIsAnEarlyClause() {
        let out = pieces("Well, the capital of France, as you know, is Paris. It sits on the Seine and has about two million people.")
        #expect(out.first == "Well, the capital of France,")
        #expect(out.count >= 3)
        #expect(out.joined(separator: " ") == "Well, the capital of France, as you know, is Paris. It sits on the Seine and has about two million people.")
    }

    @Test func shortAnswerStaysWhole() {
        #expect(pieces("It's 4.") == ["It's 4."])
    }

    @Test func noCutInsideNumbersOrAbbreviations() {
        let out = pieces("Version 3.5 shipped, e.g. on Friday with Dr. Rao. Everything looks fine to me now.")
        #expect(!out.contains { $0.hasSuffix("3.") || $0.hasSuffix("e.g.") || $0.hasSuffix("Dr.") })
    }

    @Test func hindiDanda() {
        let out = pieces("आज मौसम बहुत अच्छा है। कल बारिश हो सकती है, तो छाता ले जाना।")
        #expect(out.first == "आज मौसम बहुत अच्छा है।")
        #expect(out.count == 2)
    }

    @Test func aFinishedSentenceFlushesAfterAPause() {
        var chunker = CallSpeechChunker()
        #expect(chunker.feed("The capital of France is Paris.").isEmpty)
        #expect(chunker.flushFinishedSentence() == "The capital of France is Paris.")
        #expect(chunker.finish() == nil)
        var notYet = CallSpeechChunker()
        #expect(notYet.feed("The capital of").isEmpty)
        #expect(notYet.flushFinishedSentence() == nil)
    }

    @Test func aLongFirstSentenceWithNoClauseIsCutAtASpace() {
        let out = pieces("This sentence just keeps going on and on without any comma at all until it finally ends somewhere far away.")
        #expect((out.first?.count ?? 0) <= CallSpeechChunker.firstPieceMaximum)
        #expect(out.count == 2)
    }
}
