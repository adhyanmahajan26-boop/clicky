import Foundation
import Testing
@testable import ClickyCore

/// P7 wake word: the matcher on transcript fixtures (timed and untimed),
/// the gate, the spoken switch, the end-of-speech rule, the listener state,
/// the energy gate and the CPU window.
struct WakeWordMatcherTests {
    let matcher = WakeWordMatcher()

    /// Words spaced like speech: each word 0.3 s, 0.1 s apart; a "|" in the text is a 0.8 s pause.
    static func timedWords(_ text: String) -> [WakeTranscriptWord] {
        var words: [WakeTranscriptWord] = []
        var clock: TimeInterval = 0.2
        for token in text.split(separator: " ") {
            if token == "|" { clock += 0.8; continue }
            words.append(WakeTranscriptWord(text: String(token), startSeconds: clock, endSeconds: clock + 0.3))
            clock += 0.4
        }
        return words
    }

    func match(_ text: String) -> WakeWordMatch? { matcher.firstMatch(in: Self.timedWords(text)) }

    @Test(arguments: [
        "hey claudia", "Hey Claudia", "hey, Claudia.", "hey cloudia", "hey clodia", "hey claudio", "hey klaudia", "hey claudya",
        "hi claudia", "okay claudia", "OK Claudia", "hay claudia", "hey clawdia", "hey cloud ia", "hey clau dia", "hey claudia's"
    ])
    func claudiaVariantsWake(_ text: String) {
        #expect(match(text)?.phrase == "hey claudia", "\(text)")
    }

    @Test(arguments: ["hey clicky", "Hey Clicky!", "hey clickey", "hey kliki", "hi clicky", "okay clicky", "hey klicky", "hey clickie", "hey click y"])
    func clickyVariantsWake(_ text: String) {
        #expect(match(text)?.phrase == "hey clicky", "\(text)")
    }

    @Test(arguments: [
        "hey claude open", "hey claude", "claudia is my friend", "my friend claudia", "i told claudia hey",
        "and then hey claudia said", "hey click on that", "hey clicks", "hey there", "clicky", "claudia",
        "hey nicky", "hey ricky", "hey mickey", "hey sticky", "hey cloud", "the weather is nice today", "a claudia",
        "hey claudine", "hey clarity"
    ])
    func nonWakePhrasesDoNotWake(_ text: String) {
        #expect(match(text) == nil, "\(text)")
    }

    @Test func remainderIsTheStartOfTheTurn() {
        #expect(match("hey claudia, open notes")?.remainderText == "open notes")
        #expect(match("hey claudia what's on my screen")?.remainderText == "what's on my screen")
        #expect(match("hey clicky")?.remainderText == "")
        #expect(match("okay cloud ia - send this to my project")?.remainderText == "send this to my project")
    }

    @Test func phraseAfterAPauseStartsANewSegment() {
        // "and then | hey claudia": the 0.8 s pause makes "hey" a segment start.
        let afterPause = match("and then | hey claudia open notes")
        #expect(afterPause?.phrase == "hey claudia")
        #expect(afterPause?.remainderText == "open notes")
        #expect(afterPause?.wordRange == 2..<4)
        // Same words with no pause: mid-sentence, ignored.
        #expect(match("and then hey claudia open notes") == nil)
    }

    @Test func pauseThresholdIsSixTenths() {
        let shortPause = [WakeTranscriptWord(text: "so", startSeconds: 0, endSeconds: 0.3),
                          WakeTranscriptWord(text: "hey", startSeconds: 0.85, endSeconds: 1.0),
                          WakeTranscriptWord(text: "claudia", startSeconds: 1.1, endSeconds: 1.5)]
        #expect(matcher.firstMatch(in: shortPause) == nil)
        var longPause = shortPause
        longPause[1].startSeconds = 0.9
        longPause[1].endSeconds = 1.0
        #expect(matcher.firstMatch(in: longPause)?.phraseEndSeconds == 1.5)
    }

    @Test func untimedWordsAreOneSegment() {
        #expect(matcher.firstMatch(in: WakeWordMatcher.untimedWords(in: "hey claudia open notes"))?.remainderText == "open notes")
        #expect(matcher.firstMatch(in: WakeWordMatcher.untimedWords(in: "so hey claudia open notes")) == nil)
    }

    @Test func customPhrasesAreUsedAndOneWordPhrasesSkipped() {
        let customMatcher = WakeWordMatcher(phrases: ["hello computer", "jarvis", "  "])
        #expect(customMatcher.phraseTexts == ["hello computer"])
        #expect(customMatcher.firstMatch(in: Self.timedWords("hello computer lights"))?.remainderText == "lights")
        #expect(customMatcher.firstMatch(in: Self.timedWords("hello computor"))?.phrase == "hello computer")
        // "hello" isn't one of the interchangeable greetings, so "hey computer" doesn't count.
        #expect(customMatcher.firstMatch(in: Self.timedWords("hey computer")) == nil)
        #expect(customMatcher.firstMatch(in: Self.timedWords("jarvis lights")) == nil)
        #expect(WakeWordMatcher(phrases: []).firstMatch(in: Self.timedWords("hey claudia")) == nil)
    }

    @Test func nameWordsInSpokenTextAreFound() {
        #expect(matcher.containsNameWord(["you", "can", "call", "me", "claudia"]))
        #expect(matcher.containsNameWord(["clickey"]))
        #expect(!matcher.containsNameWord(["claude", "said", "click", "here"]))
    }

    @Test func soundKeyAndEditDistance() {
        #expect(WakeWordMatcher.soundKey("klaudia") == WakeWordMatcher.soundKey("claudia"))
        #expect(WakeWordMatcher.soundKey("clickey") == WakeWordMatcher.soundKey("clicky"))
        #expect(WakeWordMatcher.editDistance("claude", "claudia") == 2)
        #expect(WakeWordMatcher.editDistance("", "abc") == 3)
    }
}

struct WakeWordGateTests {
    let matcher = WakeWordMatcher()
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func firesThenDebouncesForTwoSeconds() {
        var gate = WakeWordGate()
        #expect(gate.decide(at: start, isClickySpeaking: false, lastClickySpeechEndDate: nil, recentClickySpokenWords: [], matcher: matcher) == .fire)
        #expect(gate.decide(at: start.addingTimeInterval(1.9), isClickySpeaking: false, lastClickySpeechEndDate: nil, recentClickySpokenWords: [], matcher: matcher) == .ignoredDebounce)
        #expect(gate.decide(at: start.addingTimeInterval(2.1), isClickySpeaking: false, lastClickySpeechEndDate: nil, recentClickySpokenWords: [], matcher: matcher) == .fire)
    }

    @Test func ignoredWhileAndJustAfterClickySpeaks() {
        var gate = WakeWordGate()
        #expect(gate.decide(at: start, isClickySpeaking: true, lastClickySpeechEndDate: nil, recentClickySpokenWords: [], matcher: matcher) == .ignoredWhileSpeaking)
        #expect(gate.decide(at: start, isClickySpeaking: false, lastClickySpeechEndDate: start.addingTimeInterval(-1.4), recentClickySpokenWords: [], matcher: matcher) == .ignoredJustAfterSpeaking)
        #expect(gate.decide(at: start, isClickySpeaking: false, lastClickySpeechEndDate: start.addingTimeInterval(-1.6), recentClickySpokenWords: [], matcher: matcher) == .fire)
        // Ignored matches never start the debounce.
        #expect(gate.lastFireDate == start)
    }

    @Test func ignoredWhenClickyJustSaidTheName() {
        var gate = WakeWordGate()
        let decision = gate.decide(at: start, isClickySpeaking: false, lastClickySpeechEndDate: start.addingTimeInterval(-3),
                                   recentClickySpokenWords: ["hey", "im", "clicky"], matcher: matcher)
        #expect(decision == .ignoredEcho)
        #expect(gate.lastFireDate == nil)
    }

    @Test func echoGuardWordsFeedTheGate() {
        var echoGuard = EchoGuard()
        echoGuard.recordSpoken("Hey, I'm Clicky. This is how I'll sound.", at: start)
        var gate = WakeWordGate()
        #expect(gate.decide(at: start.addingTimeInterval(2), isClickySpeaking: false, lastClickySpeechEndDate: start,
                            recentClickySpokenWords: echoGuard.recentSpokenWords(at: start.addingTimeInterval(2)), matcher: matcher) == .ignoredEcho)
        #expect(gate.decide(at: start.addingTimeInterval(5), isClickySpeaking: false, lastClickySpeechEndDate: start,
                            recentClickySpokenWords: echoGuard.recentSpokenWords(at: start.addingTimeInterval(5)), matcher: matcher) == .fire)
    }
}

struct WakeListeningCommandTests {
    @Test(arguments: ["stop listening", "Stop listening.", "hey claudia, stop listening please", "pause listening", "turn off the wake word"])
    func stopPhrases(_ text: String) {
        #expect(WakeListeningCommand.parse(text) == .stopListening)
    }

    @Test(arguments: ["start listening", "Start listening again", "okay clicky resume listening", "listen again"])
    func startPhrases(_ text: String) {
        #expect(WakeListeningCommand.parse(text) == .startListening)
    }

    @Test(arguments: ["stop listening to music", "start listening to this podcast", "listening", "", "hey claudia"])
    func otherSentencesAreNotCommands(_ text: String) {
        #expect(WakeListeningCommand.parse(text) == nil)
    }
}

struct WakeListenerStateTests {
    @Test func offReasonsComeBeforePauses() {
        #expect(WakeWordConditions(isEnabledInSettings: false, isMicrophoneInUseByAnotherApp: true).state == .off(.disabledInSettings))
        #expect(WakeWordConditions(isOnDeviceRecognitionSupported: false).state == .off(.onDeviceRecognitionUnsupported))
        #expect(WakeWordConditions(isSpeechRecognitionAuthorized: false, isScreenLocked: true).state == .off(.speechRecognitionNotAuthorized))
        #expect(WakeWordConditions(hasUsablePhrases: false).state == .off(.noUsablePhrases))
    }

    @Test func pausesAndArmed() {
        #expect(WakeWordConditions().state == .armed)
        #expect(WakeWordConditions(isCapturingTurn: true).state == .capturing)
        #expect(WakeWordConditions(isMicrophoneInUseByAnotherApp: true).state == .paused(.microphoneInUseByAnotherApp))
        #expect(WakeWordConditions(isScreenLocked: true).state == .paused(.screenLocked))
        #expect(WakeWordConditions(isSystemAsleep: true).state == .paused(.systemAsleep))
        #expect(WakeWordConditions(isMicrophoneInUseByAnotherApp: true, isPushToTalkCapturing: true).state == .paused(.yieldedToPushToTalk))
        #expect(WakeWordConditions(isHandsFreeCapturing: true).state == .paused(.yieldedToHandsFree))
        #expect(WakeWordConditions(didAudioEngineFail: true).state == .paused(.audioEngineFailed))
        #expect(WakeWordConditions(isDefaultInputBluetooth: true).state == .paused(.bluetoothMicrophone))
        #expect(WakeWordConditions(isMicrophoneInUseByAnotherApp: true, isDefaultInputBluetooth: true).state == .paused(.microphoneInUseByAnotherApp))
    }

    @Test func micAndNotchIndicator() {
        #expect(WakeWordListenerState.armed.wantsMicrophone)
        #expect(WakeWordListenerState.capturing.wantsMicrophone)
        #expect(!WakeWordListenerState.paused(.screenLocked).wantsMicrophone)
        #expect(NotchWakeIndicator.indicator(for: .armed) == .armed)
        #expect(NotchWakeIndicator.indicator(for: .capturing) == .armed)
        #expect(NotchWakeIndicator.indicator(for: .paused(.microphoneInUseByAnotherApp)) == .paused)
        #expect(NotchWakeIndicator.indicator(for: .off(.disabledInSettings)) == .hidden)
        for reason in WakeWordInactiveReason.allCases { #expect(!reason.displayText.isEmpty) }
        #expect(WakeWordInactiveReason.screenLocked.isPause && !WakeWordInactiveReason.disabledInSettings.isPause)
    }

    @Test func notchContentCarriesTheIndicator() {
        let content = NotchStatus.content(phase: .idle, store: AgentStore(), captionText: nil, isCodeModeOn: false, selectedAgentID: nil,
                                          now: Date(), wakeIndicator: .paused, canCancel: { _ in false }, canOpenReview: { _ in false })
        #expect(content.wakeIndicator == .paused)
        #expect(NotchContent().wakeIndicator == .hidden)
    }
}

struct UtteranceEndRuleTests {
    @Test func finishedAfterSilenceWithText() {
        #expect(!UtteranceEndRule.isFinished(heardText: "", secondsSinceLastChange: 5))
        #expect(!UtteranceEndRule.isFinished(heardText: "open notes", secondsSinceLastChange: 1.0))
        #expect(UtteranceEndRule.isFinished(heardText: "open notes", secondsSinceLastChange: 1.1))
    }
}

struct EnergyVoiceActivityGateTests {
    static let bufferSeconds: TimeInterval = 0.02

    func run(_ gate: inout EnergyVoiceActivityGate, level: Double, seconds: TimeInterval) -> [EnergyVoiceActivityGate.Transition] {
        var transitions: [EnergyVoiceActivityGate.Transition] = []
        for _ in 0..<Int((seconds / Self.bufferSeconds).rounded()) {
            if let transition = gate.process(levelDecibels: level, durationSeconds: Self.bufferSeconds) { transitions.append(transition) }
        }
        return transitions
    }

    @Test func staysClosedInSilenceAndOpensOnSpeech() {
        var gate = EnergyVoiceActivityGate()
        #expect(run(&gate, level: -70, seconds: 3).isEmpty)
        #expect(!gate.isOpen)
        #expect(run(&gate, level: -30, seconds: 0.2) == [.opened])
        #expect(gate.isOpen)
        // Short pauses inside speech don't close it; 1.2 s of quiet does.
        #expect(run(&gate, level: -70, seconds: 0.8).isEmpty)
        #expect(run(&gate, level: -30, seconds: 0.5).isEmpty)
        #expect(run(&gate, level: -70, seconds: 1.4) == [.closed])
    }

    @Test func digitalSilenceUsesTheAbsoluteFloor() {
        var gate = EnergyVoiceActivityGate()
        #expect(run(&gate, level: -120, seconds: 1).isEmpty)
        #expect(gate.openThresholdDecibels == gate.absoluteOpenFloorDecibels)
        // Below the absolute floor nothing opens, however quiet it was before.
        #expect(run(&gate, level: -78, seconds: 0.5).isEmpty)
        #expect(run(&gate, level: -25, seconds: 0.1) == [.opened])
    }

    @Test func steadyNoiseRaisesTheFloorSlowly() {
        var gate = EnergyVoiceActivityGate()
        _ = run(&gate, level: -70, seconds: 1)
        // A steady fan at -45 dB opens the gate first, then the floor creeps up.
        _ = run(&gate, level: -45, seconds: 60)
        #expect(gate.noiseFloorDecibels > -50)
        #expect(!gate.isOpen)
    }

    @Test func rmsOfFullScaleSquareWaveIsZeroDecibels() {
        let samples: [Float] = [1, -1, 1, -1]
        let level = samples.withUnsafeBufferPointer { EnergyVoiceActivityGate.rmsDecibels(samples: $0) }
        #expect(abs(level) < 0.001)
        let silence: [Float] = [0, 0]
        #expect(silence.withUnsafeBufferPointer { EnergyVoiceActivityGate.rmsDecibels(samples: $0) } == -120)
    }
}

struct ProcessCPUUsageWindowTests {
    @Test func percentIsTheSlopeOverTheLastMinute() {
        var window = ProcessCPUUsageWindow()
        #expect(window.percent == nil)
        window.record(wallSeconds: 0, cpuSeconds: 0)
        window.record(wallSeconds: 0.5, cpuSeconds: 0.1)
        #expect(window.percent == nil)
        // 2 % of a core for two minutes, then 10 %.
        for second in stride(from: 2.0, through: 120, by: 2) { window.record(wallSeconds: second, cpuSeconds: second * 0.02) }
        #expect(abs((window.percent ?? 0) - 2) < 0.01)
        var cpuSeconds = 120 * 0.02
        for second in stride(from: 122.0, through: 240, by: 2) {
            cpuSeconds += 2 * 0.1
            window.record(wallSeconds: second, cpuSeconds: cpuSeconds)
        }
        #expect(abs((window.percent ?? 0) - 10) < 0.5)
        #expect(window.spanSeconds >= 60 && window.spanSeconds <= 62)
    }
}

/// Live finding: the en-IN on-device recognizer returned "Hey Claudia what's on my screen" as ONE
/// segment, and the word-by-word matcher never fired.
@Test func multiWordSegmentsAreSplitBeforeMatching() {
    let segment = WakeTranscriptWord(text: "Hey Claudia what's on my screen", startSeconds: 0.4, endSeconds: 2.0)
    let words = WakeWordRecognitionPipeline.splitIntoWords([segment])
    #expect(words.map(\.text) == ["Hey", "Claudia", "what's", "on", "my", "screen"])
    #expect(abs(words.first!.startSeconds - 0.4) < 0.0001 && abs(words.last!.endSeconds - 2.0) < 0.0001)
    let match = WakeWordMatcher().firstMatch(in: words)
    #expect(match?.phrase == "hey claudia")
    #expect(match?.remainderText.lowercased() == "what's on my screen")
}
