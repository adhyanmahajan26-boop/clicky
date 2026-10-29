import Foundation
import Testing
@testable import ClickyCore

private let P = "\u{E000}"

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

// MARK: - CaptionParser

private let captionFragments = [
    "Click Share", " then pick ", "**bold**", "_italic_", "`code`", "`a very long inline code span here`", "PR #12", " ", ", ", ". ",
    "\n- first item", "\n* second", "\n1. third", "\n| a | b |", "\n```\nlet x = 1\n```\n", "https://example.com/a/b", "[docs](https://x.y)",
    "😀", "👩‍💻", "❤️", "日本語", "é", "e\u{301}", "©", P, "Command-Shift-P", "1,284.50", "\n"
]

@Test func captionParserPropertiesOnRandomStrings() {
    var generator = SeededRandom(state: 7)
    for caseIndex in 0..<1000 {
        let fragmentCount = Int.random(in: 1...10, using: &generator)
        let raw = (0..<fragmentCount).map { _ in captionFragments.randomElement(using: &generator)! }.joined()
        let segment = CaptionParser.parse(raw, id: caseIndex, firstTagIndex: 0)
        let speechCharacters = Array(segment.speech)
        let displayCharacters = Array(segment.display)
        // Every spoken run is the identical characters of the display.
        for piece in segment.pieces {
            #expect(piece.speechRange.upperBound <= speechCharacters.count)
            #expect(piece.displayStart + piece.speechRange.count <= displayCharacters.count)
            let spoken = String(speechCharacters[piece.speechRange])
            let shown = String(displayCharacters[piece.displayStart..<(piece.displayStart + piece.speechRange.count)])
            #expect(spoken == shown, "piece mismatch in \(raw.debugDescription)")
        }
        // Never spoken: fences, bullets' markers, table lines, URLs, emoji, placeholders.
        #expect(!segment.speech.contains("```"))
        #expect(!segment.speech.contains("let x = 1"))
        #expect(!segment.speech.contains("| a |"))
        #expect(!segment.speech.contains("https://"))
        #expect(!segment.speech.contains("😀") && !segment.display.contains("😀") && !segment.display.contains("\u{200D}") && !segment.display.contains("\u{FE0F}"))
        #expect(!segment.speech.contains(P) && !segment.display.contains(P))
        #expect(!segment.speech.contains("**"))
        #expect(!segment.speech.contains("a very long inline code span here"))
        // Anchors: one per placeholder, offsets inside the speech, in order.
        #expect(segment.anchors.count == raw.filter { $0 == ResponseRouter.placeholder }.count)
        #expect(segment.anchors.map(\.speechOffset) == segment.anchors.map(\.speechOffset).sorted())
        for anchor in segment.anchors {
            #expect(anchor.speechOffset <= segment.speechLength)
            #expect(anchor.prevWordStart <= anchor.speechOffset)
        }
        // Reveal never runs backwards.
        var lastReveal = 0
        for spoken in 0...segment.speechLength {
            let reveal = segment.displayRevealCount(spokenCharacters: spoken)
            #expect(reveal >= lastReveal)
            lastReveal = reveal
        }
        #expect(segment.displayRevealCount(spokenCharacters: segment.speechLength) == segment.display.count)
    }
}

@Test func captionParserExactOffsetsAndKeptText() {
    let segment = CaptionParser.parse("Click Share \(P) in the toolbar, then PR #12 \(P).", id: 1, firstTagIndex: 5)
    #expect(segment.speech == "Click Share  in the toolbar, then PR #12 .")
    #expect(segment.anchors.map(\.tagIndex) == [5, 6])
    #expect(segment.anchors[0].speechOffset == "Click Share ".count)
    #expect(segment.anchors[0].prevWordStart == "Click ".count)
    #expect(segment.speech.contains("PR #12"))

    let listSegment = CaptionParser.parse("Steps:\n- open **File**\n- pick [Export](https://x.y)", id: 2, firstTagIndex: 0)
    #expect(listSegment.display == "Steps:\n• open File\n• pick Export")
    #expect(listSegment.speech == "Steps: open File pick Export")

    let fenceSegment = CaptionParser.parse("Run this:\n```\nswift build\n```", id: 3, firstTagIndex: 0)
    #expect(fenceSegment.speech == "Run this:")
    #expect(fenceSegment.display.contains("swift build"))
    #expect(!fenceSegment.monospacedRanges.isEmpty)
}

@Test func spokenCharactersHandlesSurrogatesZWJCJKAndCombiningMarks() {
    for (text, utf16Offset, expected) in [
        ("a😀b", 1, 1), ("a😀b", 2, 2), ("a😀b", 3, 2), ("a😀b", 4, 3),
        ("日本語です", 2, 2), ("cafe\u{301} ok", 5, 4), ("cafe\u{301} ok", 6, 5), ("cafe\u{301} ok", 4, 4),
        ("x👩‍👩‍👧y", 3, 2)
    ] as [(String, Int, Int)] {
        let segment = CaptionSegment(id: 0, display: text, speech: text, pieces: [], anchors: [], wordRanges: [], monospacedRanges: [], boardStep: nil)
        #expect(segment.spokenCharacters(throughUTF16: utf16Offset) == expected, "\(text.debugDescription) @\(utf16Offset)")
    }
}

// MARK: - CaptionTimeline

@Test func timelineNeverGoesBackwardsOnAppleCallbackSequences() {
    // Real-world AVSpeechSynthesizer quirks: skipped ranges, 2 ms bursts, ranges that go backwards.
    let sequences: [[Int]] = [
        [5, 11, 18, 24, 31],
        [5, 5, 5, 11, 3, 18, 2, 24],
        [0, 40, 12, 41, 41, 39, 50],
        [10, 9, 8, 7, 30]
    ]
    for sequence in sequences {
        var timeline = CaptionTimeline(totalCharacters: 50)
        var last = 0
        for spoken in sequence {
            timeline.applyExact(spoken)
            #expect(timeline.revealed >= last)
            last = timeline.revealed
        }
    }
}

@Test func timelineEstimatesCatchUpWithinFiftyMilliseconds() {
    var generator = SeededRandom(state: 99)
    var timeline = CaptionTimeline(totalCharacters: 2000)
    var estimate = 0
    for _ in 0..<300 {
        estimate += Int.random(in: 0...40, using: &generator)
        timeline.applyEstimate(estimate)
        var ticks = 0
        var last = timeline.revealed
        while !timeline.isCaughtUp {
            timeline.tick()
            #expect(timeline.revealed >= last)
            last = timeline.revealed
            ticks += 1
        }
        #expect(Double(ticks) / CaptionTimeline.ticksPerSecond <= 0.050 + 1e-9, "took \(ticks) ticks")
    }
}

// MARK: - Word timing (synthetic audio)

/// Tone bursts separated by silences, as Float PCM.
private func syntheticSpeech(bursts: [(seconds: Double, silenceAfter: Double)], lead: Double, sampleRate: Double = 24_000) -> PCMAudio {
    var samples = [Float](repeating: 0, count: Int(lead * sampleRate))
    for burst in bursts {
        for sampleIndex in 0..<Int(burst.seconds * sampleRate) {
            samples.append(0.3 * sin(Float(sampleIndex) * 2 * .pi * 220 / Float(sampleRate)))
        }
        samples += [Float](repeating: 0, count: Int(burst.silenceAfter * sampleRate))
    }
    return PCMAudio(samples: samples, sampleRate: sampleRate)
}

@Test func silenceBoundsAreWithinTenMilliseconds() {
    let audio = syntheticSpeech(bursts: [(0.5, 0.2), (0.4, 0.33)], lead: 0.27)
    let bounds = WordTiming.silenceBounds(audio)
    #expect(abs(bounds.lead - 0.27) <= 0.010)
    #expect(abs(bounds.tail - 0.33) <= 0.010)
}

@Test func wordTimesSpanExactlyTheSpeech() {
    let audio = syntheticSpeech(bursts: [(0.6, 0.25), (0.5, 0.15)], lead: 0.12)
    let speech = "Click the Share button. Then pick PDF."
    let wordRanges = CaptionParser.parse(speech, id: 0, firstTagIndex: 0).wordRanges
    let times = WordTiming.wordTimes(speech: speech, wordRanges: wordRanges, audio: audio)
    #expect(times.starts.count == wordRanges.count)
    let total = times.ends.last! - times.starts.first!
    #expect(abs(total - (audio.duration - times.lead - times.tail)) <= 0.001)
    #expect(times.starts == times.starts.sorted())
    // "Then" starts in (snapped to the middle of) the 250 ms pause after "button."
    let thenIndex = 4
    let pauseMidpoint = 0.12 + 0.6 + 0.125
    #expect(abs(times.starts[thenIndex] - pauseMidpoint) <= 0.02, "then at \(times.starts[thenIndex])")
}

@Test func syllableCounting() {
    #expect(WordTiming.syllables(in: "PR") == 2)
    #expect(WordTiming.syllables(in: "URL") == 3)
    #expect(WordTiming.syllables(in: "42") == 3)   // for-ty-two
    #expect(WordTiming.syllables(in: "日本語") == 3)
    #expect(WordTiming.syllables(in: "button") == 2)
    #expect(WordTiming.pauseWeight(after: ". ") == 2)
    #expect(WordTiming.pauseWeight(after: ", ") == 1)
    #expect(WordTiming.pauseWeight(after: " ") == 0)
}

// MARK: - Stream

private func line(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

@Test func lineReaderSplitsOnlyOnNewlineBytes() {
    var reader = LineReader()
    // A delta containing U+2028 must stay one line.
    let event = line(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "one\u{2028}two"]]])
    var lines = reader.append(event.prefix(10))
    lines += reader.append(event.dropFirst(10) + Data([0x0A]))
    #expect(lines.count == 1)
    #expect(CLIStreamEvent.parse(lines[0]) == .textDelta("one\u{2028}two"))
    // A trailing line without newline comes out at finish.
    _ = reader.append(Data("partial".utf8))
    #expect(reader.finish() == Data("partial".utf8))
}

@Test func lineReaderDropsOversizedLines() {
    var reader = LineReader()
    let big = Data(repeating: 0x61, count: LineReader.maximumLineBytes + 10)
    #expect(reader.append(big).isEmpty)
    #expect(reader.append(Data("x\nok\n".utf8)) == [Data("ok".utf8)])
    #expect(reader.droppedOversizedLineCount == 1)
}

@Test func supervisorHandlesEveryEnding() {
    // EOF without a result.
    var eofSupervisor = CLIStreamSupervisor()
    _ = eofSupervisor.handle(.textDelta("hi"), hasSpokenAnything: false)
    #expect(eofSupervisor.endOfStream() == [.fail(.endedWithoutResult)])
    #expect(CLIStreamFailure.endedWithoutResult.spokenMessage == "Claude stopped unexpectedly.")

    // A second message_start: reset if nothing spoken, else just logged.
    var resetSupervisor = CLIStreamSupervisor()
    _ = resetSupervisor.handle(.messageStart(id: "a"), hasSpokenAnything: false)
    _ = resetSupervisor.handle(.textDelta("hel"), hasSpokenAnything: false)
    #expect(resetSupervisor.handle(.messageStart(id: "b"), hasSpokenAnything: false) == [.reset])
    var logSupervisor = CLIStreamSupervisor()
    _ = logSupervisor.handle(.messageStart(id: "a"), hasSpokenAnything: false)
    #expect(logSupervisor.handle(.messageStart(id: "b"), hasSpokenAnything: true) == [.logMessageStart(id: "b")])

    // Usage limit (with reset time) and is_error.
    var limitSupervisor = CLIStreamSupervisor()
    let limitActions = limitSupervisor.handle(.result(text: "Claude AI usage limit reached|1761400800", isError: true, subtype: nil), hasSpokenAnything: false)
    guard case .fail(.usageLimit(let resetDescription))? = limitActions.first else {
        Issue.record("no usage limit: \(limitActions)")
        return
    }
    #expect(resetDescription?.hasPrefix("at ") == true)
    var errorSupervisor = CLIStreamSupervisor()
    #expect(errorSupervisor.handle(.result(text: "Overloaded", isError: true, subtype: "error"), hasSpokenAnything: false) == [.fail(.reportedError("Overloaded"))])
    #expect(CLIStreamFailure.usageLimit(in: "You've hit your limit · resets 3pm (Asia/Kolkata)") == nil
            || CLIStreamFailure.usageLimit(in: "usage limit reached, resets 3pm") == .usageLimit(resetDescription: "3pm"))

    // Stall.
    var stallSupervisor = CLIStreamSupervisor()
    #expect(stallSupervisor.stalled() == [.fail(.stalled)])
    // The assistant message's text is ignored (parsed as .other).
    #expect(CLIStreamEvent.parse(line(["type": "assistant", "message": ["content": [["type": "text", "text": "dup"]]]])) == .other)
}
