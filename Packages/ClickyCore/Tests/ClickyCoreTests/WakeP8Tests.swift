import AVFoundation
import Foundation
import Testing
@testable import ClickyCore

/// P8 wake word: error classes, near misses, locale choice, make-up gain,
/// the adaptive gate on synthetic levels, format conversion, the widened
/// matcher and the follow-up window (injected clock).
struct WakeP8DiagnosticsTests {
    @Test func benignErrorsAreClassed() {
        #expect(WakeRecognizerErrorClassifier.classify(domain: "kAFAssistantErrorDomain", code: 1110) == .noSpeech)
        #expect(WakeRecognizerErrorClassifier.classify(domain: "kAFAssistantErrorDomain", code: 216) == .cancelled)
        #expect(WakeRecognizerErrorClassifier.classify(domain: "kLSRErrorDomain", code: 301) == .cancelled)
        #expect(WakeRecognizerErrorClassifier.classify(domain: "kAFAssistantErrorDomain", code: 203) == .retry)
        #expect(WakeRecognizerErrorClassifier.classify(domain: "kAFAssistantErrorDomain", code: 1107) == .failure)
        #expect(WakeRecognizerErrorClassifier.classify(domain: "kAFAssistantErrorDomain", code: 1107).isBenign == false)
        #expect(WakeRecognizerErrorClass.noSpeech.isBenign)
        #expect(WakeRecognizerErrorClassifier.key(domain: "kAFAssistantErrorDomain", code: 1110) == "kAFAssistantErrorDomain:1110")
    }

    @Test func nearMissesKeepOnlyTheSecondWord() {
        var counter = WakeNearMissCounter()
        let matcher = WakeWordMatcher()
        counter.recordUnmatchedRequest(words: WakeWordMatcherTests.timedWords("hey cloud open my notes"), matcher: matcher)
        counter.recordUnmatchedRequest(words: WakeWordMatcherTests.timedWords("Hey, Cloud."), matcher: matcher)
        counter.recordUnmatchedRequest(words: WakeWordMatcherTests.timedWords("hi there"), matcher: matcher)
        // Not greetings, or the name itself: not counted.
        counter.recordUnmatchedRequest(words: WakeWordMatcherTests.timedWords("the weather is nice"), matcher: matcher)
        counter.recordUnmatchedRequest(words: WakeWordMatcherTests.timedWords("hey claudia"), matcher: matcher)
        #expect(counter.countsBySecondWord == ["cloud": 2, "there": 1])
        #expect(counter.displayCounts["hey cloud"] == 2)
        #expect(counter.totalCount == 3)
    }

    @Test func nearMissesAreCapped() {
        var counter = WakeNearMissCounter()
        for index in 0..<(WakeNearMissCounter.maximumDistinctWords + 5) { counter.record(secondWord: "word\(index)") }
        #expect(counter.countsBySecondWord.count == WakeNearMissCounter.maximumDistinctWords + 1)
        #expect(counter.countsBySecondWord["(other)"] == 5)
        counter.record(secondWord: String(repeating: "a", count: 50))
        #expect(counter.countsBySecondWord.keys.allSatisfy { $0.count <= WakeNearMissCounter.maximumWordLength })
    }

    @Test func localeSettingParses() {
        #expect(WakeLocaleSetting.parse(nil) == .automatic)
        #expect(WakeLocaleSetting.parse("auto") == .automatic)
        #expect(WakeLocaleSetting.parse("en_IN") == .fixed("en-IN"))
        #expect(WakeLocaleSetting.parse("EN-us") == .fixed("en-US"))
        #expect(WakeLocaleSetting.parse("fr-FR") == .automatic)
    }

    @Test func autoLocaleSwitchesAwayFromAFailingOneAtMostEveryTenMinutes() {
        var selector = WakeLocaleSelector(setting: .automatic, candidates: ["en_IN", "en-US"])
        #expect(selector.currentLocale == "en_IN")
        let start = Date(timeIntervalSince1970: 1_000_000)
        var switched: String?
        for index in 0..<WakeLocaleSelector.windowSize {
            switched = selector.record(locale: "en_IN", failed: index % 4 != 0, at: start.addingTimeInterval(Double(index))) ?? switched
        }
        #expect(switched == "en-US")
        #expect(selector.currentLocale == "en-US")
        #expect(selector.switchLog.count == 1)
        // en-US fails even more, but within 10 minutes nothing switches.
        for index in 0..<WakeLocaleSelector.windowSize {
            #expect(selector.record(locale: "en-US", failed: true, at: start.addingTimeInterval(100 + Double(index))) == nil)
        }
        // After 10 minutes: back to en_IN only if it was clearly better (it wasn't: 75% vs 100% → yes, 25 points better).
        let later = start.addingTimeInterval(WakeLocaleSelector.minimumSecondsBetweenSwitches + 200)
        #expect(selector.record(locale: "en-US", failed: true, at: later) == "en_IN")
    }

    @Test func fixedLocaleNeverSwitches() {
        var selector = WakeLocaleSelector(setting: .fixed("en-US"), candidates: ["en_IN", "en-US"])
        #expect(selector.currentLocale == "en-US")
        for index in 0..<30 {
            #expect(selector.record(locale: "en-US", failed: true, at: Date(timeIntervalSince1970: Double(index) * 1000)) == nil)
        }
    }

    @Test func healthyLocaleStays() {
        var selector = WakeLocaleSelector(setting: .automatic, candidates: ["en_IN", "en-US"])
        for index in 0..<40 {
            #expect(selector.record(locale: "en_IN", failed: index % 5 == 0, at: Date(timeIntervalSince1970: Double(index) * 1000)) == nil)
        }
    }

    @Test func makeUpGainLiftsAQuietMicOnly() {
        var gain = WakeInputGain()
        #expect(gain.gainDecibels == 0)
        gain.observeSpeech(levelDecibels: -50, durationSeconds: 0.1)
        #expect(gain.gainDecibels == WakeInputGain.maximumGainDecibels)
        var loudGain = WakeInputGain()
        loudGain.observeSpeech(levelDecibels: -20, durationSeconds: 0.1)
        #expect(loudGain.gainDecibels == 0)
        var mediumGain = WakeInputGain()
        mediumGain.observeSpeech(levelDecibels: -36, durationSeconds: 0.1)
        #expect(abs(mediumGain.gainDecibels - 10) < 0.01)
        var samples: [Float] = [0.5, -0.5, 0.01]
        samples.withUnsafeMutableBufferPointer { WakeInputGain.apply(linearGain: 4, to: $0) }
        #expect(samples == [1, -1, 0.04])
    }
}

struct AdaptiveGateTests {
    static let bufferSeconds: TimeInterval = 0.085

    func run(_ gate: inout EnergyVoiceActivityGate, level: Double, seconds: TimeInterval) -> [EnergyVoiceActivityGate.Transition] {
        var transitions: [EnergyVoiceActivityGate.Transition] = []
        for _ in 0..<Int((seconds / Self.bufferSeconds).rounded()) {
            if let transition = gate.process(levelDecibels: level, durationSeconds: Self.bufferSeconds) { transitions.append(transition) }
        }
        return transitions
    }

    /// The C270 case: a -76 dB room, speech across the desk at -58 dB. The old fixed -58 dB bar
    /// sat right at the speech level; the adaptive threshold sits 8 dB over the room.
    @Test func quietWebcamMicOpensOnDistantSpeech() {
        var gate = EnergyVoiceActivityGate()
        #expect(run(&gate, level: -76, seconds: 5).isEmpty)
        #expect(abs(gate.noiseFloorDecibels - -76) < 0.01)
        #expect(gate.openThresholdDecibels == -68)
        #expect(run(&gate, level: -61, seconds: 0.5) == [.opened])
        #expect(run(&gate, level: -76, seconds: 1.5) == [.closed])
        #expect(gate.lastOpenPeakDecibels == -61)
    }

    @Test func floorFollowsTheRoomUpAndDown() {
        var gate = EnergyVoiceActivityGate()
        _ = run(&gate, level: -50, seconds: 12)
        #expect(abs(gate.noiseFloorDecibels - -50) < 0.01)
        #expect(!gate.isOpen)
        // Speech over a noisy room still opens (8 dB over it).
        #expect(run(&gate, level: -40, seconds: 0.3) == [.opened])
        _ = run(&gate, level: -70, seconds: 12)
        #expect(abs(gate.noiseFloorDecibels - -70) < 0.01)
    }

    @Test func pausesBetweenWordsKeepTheFloorLow() {
        var gate = EnergyVoiceActivityGate()
        _ = run(&gate, level: -75, seconds: 3)
        // 8 s of talking: words at -55 with short gaps at the room level.
        for _ in 0..<16 {
            _ = run(&gate, level: -55, seconds: 0.35)
            _ = run(&gate, level: -75, seconds: 0.15)
        }
        #expect(gate.noiseFloorDecibels < -70)
        #expect(gate.isOpen)
    }

    @Test func digitalSilenceIsNotRoomNoise() {
        var gate = EnergyVoiceActivityGate()
        _ = run(&gate, level: -74, seconds: 4)
        _ = run(&gate, level: -120, seconds: 3)
        #expect(abs(gate.noiseFloorDecibels - -74) < 0.01)
    }

    @Test func percentile() {
        #expect(EnergyVoiceActivityGate.percentileLevel([], percentile: 0.2) == nil)
        #expect(EnergyVoiceActivityGate.percentileLevel([-10, -20, -30, -40, -50], percentile: 0.2) == -50)
        #expect(EnergyVoiceActivityGate.percentileLevel([-10, -20, -30, -40, -50, -60, -70, -80, -90, -100, -110], percentile: 0.2) == -90)
    }
}

struct WakeAudioFormatTests {
    @Test func planMatchesTheMic() {
        #expect(WakeAudioFormatPlan.plan(for: WakeAudioInputDescription(sampleRate: 48_000, channelCount: 1, isFloat32: true, isInterleaved: false)) == .passThrough)
        guard case .convert(let reasons) = WakeAudioFormatPlan.plan(for: WakeAudioInputDescription(sampleRate: 16_000, channelCount: 2, isFloat32: false, isInterleaved: true)) else {
            Issue.record("16 kHz stereo int should convert")
            return
        }
        #expect(reasons.contains("resample 16000→48000"))
        #expect(reasons.contains("downmix 2→1"))
        #expect(reasons.contains("to float32"))
        #expect(WakeAudioFormatPlan.plan(for: WakeAudioInputDescription(sampleRate: 0, channelCount: 1, isFloat32: true, isInterleaved: false)) == .unusable)
        #expect(WakeAudioFormatPlan.outputCapacity(inputFrames: 1600, inputSampleRate: 16_000) == 4800 + 64)
    }

    @Test func sixteenKilohertzIntegerIsConvertedToFortyEightKilohertzFloat() throws {
        let inputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let converter = WakeAudioFormatConverter()
        var totalOutputFrames = 0
        var lastOutput: AVAudioPCMBuffer?
        for chunkIndex in 0..<10 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1600))
            buffer.frameLength = 1600
            let samples = try #require(buffer.int16ChannelData)
            for frame in 0..<1600 {
                let time = Double(chunkIndex * 1600 + frame) / 16_000
                samples[0][frame] = Int16(sin(2 * .pi * 440 * time) * 8000)
            }
            let output = try #require(converter.convert(buffer))
            #expect(output.format == WakeAudioFormatConverter.targetFormat)
            totalOutputFrames += Int(output.frameLength)
            lastOutput = output
        }
        // 1 s in, about 1 s out (the resampler holds back a few frames).
        #expect(abs(totalOutputFrames - 48_000) < 600)
        let output = try #require(lastOutput)
        let level = WakeWordRecognitionPipeline.levelDecibels(of: output)
        // 8000/32768 sine ≈ -15 dBFS RMS.
        #expect(abs(level - -15.2) < 1.5)
    }

    @Test func stereoIsDownmixed() throws {
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4800))
        buffer.frameLength = 4800
        for frame in 0..<4800 {
            buffer.floatChannelData![0][frame] = 0.25
            buffer.floatChannelData![1][frame] = 0.25
        }
        let output = try #require(WakeAudioFormatConverter().convert(buffer))
        #expect(output.format.channelCount == 1)
        #expect(output.frameLength > 4000)
    }

    @Test func targetFormatPassesThroughUntouched() throws {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: WakeAudioFormatConverter.targetFormat, frameCapacity: 480))
        buffer.frameLength = 480
        let converter = WakeAudioFormatConverter()
        #expect(converter.convert(buffer) === buffer)
        #expect(converter.lastPlan == .passThrough)
    }
}

struct WakeP8MatcherTests {
    let matcher = WakeWordMatcher()

    func match(_ text: String) -> WakeWordMatch? { matcher.firstMatch(in: WakeWordMatcherTests.timedWords(text)) }

    /// en-IN partials that split or bend the name.
    @Test(arguments: ["hey cloud ya", "hey cloud yeah", "hey cloud yah", "hey cloudy a", "hey claw dia", "hey clau di a", "hai claudia",
                      "he claudia", "hey clow dia"])
    func indianEnglishSplitsWake(_ text: String) {
        #expect(match(text)?.phrase == "hey claudia", "\(text)")
    }

    @Test(arguments: ["hey cloud is down", "hey cloud open", "hey cloud", "hey claude yeah", "hey claude ya know", "hey clouds are nice",
                      "hey click on it", "he clicked on it", "a cloud ya", "hey cloud and", "hey clo said"])
    func conservativeSplitsDoNotWake(_ text: String) {
        #expect(match(text) == nil, "\(text)")
    }

    @Test func remainderAfterASplitName() {
        #expect(match("hey cloud yeah open notes")?.remainderText == "open notes")
        #expect(match("hey clau di a what time is it")?.remainderText == "what time is it")
    }
}

struct WakeFollowUpWindowTests {
    let start = Date(timeIntervalSince1970: 2_000_000)

    @Test func opensAfterTheAnswerAndEndsOnSilence() {
        var window = WakeFollowUpWindow()
        #expect(!window.isOpen)
        window.answerFinished(at: start)
        #expect(!window.isOpen, "no wake turn was sent")
        window.turnSent()
        #expect(!window.isOpen)
        window.answerFinished(at: start)
        #expect(window.isOpen && window.showsListening)
        #expect(window.tick(now: start.addingTimeInterval(9.9)) == nil)
        #expect(window.tick(now: start.addingTimeInterval(10)) == .silence)
        #expect(!window.isOpen)
        #expect(window.lastEndReason == .silence)
    }

    @Test func aCommandRestartsTheCycle() {
        var window = WakeFollowUpWindow()
        window.turnSent()
        window.answerFinished(at: start)
        let didStart = window.commandSpeechStarted(at: start.addingTimeInterval(4))
        #expect(didStart)
        // No deadline while the command is being heard.
        #expect(window.tick(now: start.addingTimeInterval(12)) == nil)
        #expect(window.commandHeard("volume up", at: start.addingTimeInterval(13), recentClickySpokenWords: []) == .command("volume up"))
        #expect(window.phase == .awaitingAnswer)
        window.answerFinished(at: start.addingTimeInterval(14))
        #expect(window.tick(now: start.addingTimeInterval(23.9)) == nil)
        #expect(window.tick(now: start.addingTimeInterval(24)) == .silence)
    }

    @Test(arguments: ["that's all", "Thanks, that's it.", "thank you that's all", "no thanks", "never mind", "ok thanks", "hey claudia that's all"])
    func endPhrasesClose(_ text: String) {
        var window = WakeFollowUpWindow()
        window.turnSent()
        window.answerFinished(at: start)
        window.commandSpeechStarted(at: start.addingTimeInterval(1))
        #expect(window.commandHeard(text, at: start.addingTimeInterval(2), recentClickySpokenWords: []) == .ended(.thatsAll), "\(text)")
        #expect(!window.isOpen)
    }

    @Test(arguments: ["that's all the files in the folder?", "thanks for the summary, now open notes", "is that all"])
    func sentencesWithEndWordsAreCommands(_ text: String) {
        #expect(!WakeFollowUpEndPhrase.isEndPhrase(text), "\(text)")
    }

    @Test func echoIsIgnoredAndTheWindowStays() {
        var window = WakeFollowUpWindow()
        window.turnSent()
        window.answerFinished(at: start)
        window.commandSpeechStarted(at: start.addingTimeInterval(1))
        let clickySaid: Set<String> = ["the", "weather", "in", "pune", "is", "sunny", "today"]
        #expect(window.commandHeard("weather in pune is sunny", at: start.addingTimeInterval(3), recentClickySpokenWords: clickySaid) == .ignored(reason: "echo"))
        #expect(window.isOpen)
        // Same deadline as before the echo.
        #expect(window.tick(now: start.addingTimeInterval(9)) == nil)
        #expect(window.tick(now: start.addingTimeInterval(10)) == .silence)
    }

    @Test func shortCommandsAreNeverEcho() {
        #expect(!FollowUpEchoGuard.isLikelyEcho("next song", recentClickySpokenWords: ["next", "song"]))
        #expect(FollowUpEchoGuard.isLikelyEcho("here is the next song", recentClickySpokenWords: ["here", "is", "the", "next", "song"]))
        #expect(!FollowUpEchoGuard.isLikelyEcho("open my notes app", recentClickySpokenWords: ["the", "weather"]))
    }

    @Test func abandonedSpeechResumesListening() {
        var window = WakeFollowUpWindow()
        window.turnSent()
        window.answerFinished(at: start)
        window.commandSpeechStarted(at: start.addingTimeInterval(9.5))
        window.commandAbandoned(at: start.addingTimeInterval(14))
        // At least two more seconds after an abandoned stretch.
        #expect(window.isOpen)
        #expect(window.tick(now: start.addingTimeInterval(15.9)) == nil)
        #expect(window.tick(now: start.addingTimeInterval(16)) == .silence)
    }

    @Test func cancelCloses() {
        var window = WakeFollowUpWindow()
        window.turnSent()
        window.answerFinished(at: start)
        window.cancel()
        #expect(!window.isOpen)
        #expect(window.lastEndReason == .cancelled)
        let didStart = window.commandSpeechStarted(at: start.addingTimeInterval(1))
        #expect(!didStart)
    }

    @Test func speechAfterTheDeadlineIsNotAFollowUp() {
        var window = WakeFollowUpWindow(listenSeconds: 5)
        window.turnSent()
        window.answerFinished(at: start)
        let didStart = window.commandSpeechStarted(at: start.addingTimeInterval(6))
        #expect(!didStart)
    }
}

// MARK: - P9 barge-in

@Test func standaloneStopWordsInterrupt() {
    for phrase in ["stop", "Stop!", "wait", "claudia stop", "hey clicky stop", "stop it", "ruko", "bas", "stop talking", "hold on"] {
        #expect(WakeStopCommand.isStopUtterance(phrase.split(separator: " ").map(String.init)), "\(phrase)")
    }
    for phrase in ["stop the music on spotify please", "don't stop believing", "wait until tomorrow then", "the bus stop is near", "next"] {
        #expect(!WakeStopCommand.isStopUtterance(phrase.split(separator: " ").map(String.init)), "\(phrase)")
    }
}

@Test func stopIsIgnoredWhenClickyJustSaidIt() {
    #expect(!WakeStopCommand.isStopUtterance(["stop"], recentClickySpokenWords: ["press", "stop", "to", "end"]))
    #expect(WakeStopCommand.isStopUtterance(["wait"], recentClickySpokenWords: ["press", "stop", "to", "end"]))
}

@Test func wakeWordInterruptsSpeechWhenBargeInIsOn() {
    var gate = WakeWordGate()
    let matcher = WakeWordMatcher()
    let now = Date()
    #expect(gate.decide(at: now, isClickySpeaking: true, lastClickySpeechEndDate: nil, recentClickySpokenWords: [], matcher: matcher) == .ignoredWhileSpeaking)
    #expect(gate.decide(at: now, isClickySpeaking: true, lastClickySpeechEndDate: nil, recentClickySpokenWords: [], matcher: matcher, allowsBargeIn: true) == .fire)
    var echoGate = WakeWordGate()
    #expect(echoGate.decide(at: now, isClickySpeaking: true, lastClickySpeechEndDate: nil, recentClickySpokenWords: ["claudia"], matcher: matcher, allowsBargeIn: true) == .ignoredEcho)
}
