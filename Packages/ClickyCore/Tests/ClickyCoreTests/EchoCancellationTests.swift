//
//  EchoCancellationTests.swift
//  ClickyCoreTests
//
//  P6.4 "aec" echo mode, the pure parts only (no audio device is touched):
//  the 60 % partial-overlap echo filter, command words while playing,
//  Apple word markers → samples → characters, headphone routes, and the
//  mode fallback when voice processing throws.
//

import Foundation
import Testing
@testable import ClickyCore

private struct VoiceProcessingUnavailableError: Error {}

// MARK: - 60 % partial-overlap echo filter

@Test func echoFilterDropsPartialsMostlyMadeOfClickysRecentWords() {
    var echoGuard = EchoGuard()
    let speakingStart = Date(timeIntervalSince1970: 100)
    echoGuard.recordSpoken("Open the build settings and pick the release scheme.", at: speakingStart)
    let heardAt = speakingStart.addingTimeInterval(1)
    // 4 of the last 4 words were Clicky's.
    #expect(echoGuard.isLikelyEcho("pick the release scheme", at: heardAt))
    // 3 of 4 (75 %) still counts as echo.
    #expect(echoGuard.isLikelyEcho("so pick the banana scheme", at: heardAt))
    // Only the last 4 words matter: an old prefix of the user's own words doesn't save it.
    #expect(echoGuard.isLikelyEcho("what is my favourite colour the release scheme", at: heardAt))
    // 2 of 4 (50 %) is below 60 %: the user's own speech.
    #expect(!echoGuard.isLikelyEcho("what about the scheme", at: heardAt))
    #expect(!echoGuard.isLikelyEcho("how do I install python", at: heardAt))
}

@Test func echoFilterOverlapFractionIsExactlySixtyPercentRule() {
    let spokenWords: Set<String> = ["open", "the", "settings"]
    // Fewer than 4 words: all of them are judged.
    #expect(EchoGuard.trailingOverlapFraction(heardText: "open settings", spokenWords: spokenWords) == 1)
    // 2 of 4 = 0.5 → not echo.
    #expect(EchoGuard.trailingOverlapFraction(heardText: "please open my settings", spokenWords: spokenWords) == 0.5)
    #expect(!EchoGuard.isEcho(heardText: "please open my settings", spokenWords: spokenWords))
    // 3 of 5 words, but only the last 4 count: "open my the settings" → 3/4.
    #expect(EchoGuard.isEcho(heardText: "please open my the settings", spokenWords: spokenWords))
    // Punctuation and case don't matter.
    #expect(EchoGuard.isEcho(heardText: "Open, THE settings!", spokenWords: spokenWords))
    // Nothing heard, or nothing said: never echo.
    #expect(!EchoGuard.isEcho(heardText: "", spokenWords: spokenWords))
    #expect(!EchoGuard.isEcho(heardText: "open the settings", spokenWords: []))
}

@Test func echoFilterForgetsWordsOlderThanFourSeconds() {
    var echoGuard = EchoGuard()
    echoGuard.recordSpoken("pick the release scheme", at: Date(timeIntervalSince1970: 0))
    #expect(echoGuard.isLikelyEcho("pick the release scheme", at: Date(timeIntervalSince1970: 3.9)))
    #expect(!echoGuard.isLikelyEcho("pick the release scheme", at: Date(timeIntervalSince1970: 4.5)))
}

@Test func recordingTheSameTextAgainKeepsItRecent() {
    var echoGuard = EchoGuard()
    echoGuard.recordSpoken("a long sentence that keeps playing", at: Date(timeIntervalSince1970: 0))
    echoGuard.recordSpoken("a long sentence that keeps playing", at: Date(timeIntervalSince1970: 3))
    #expect(echoGuard.isLikelyEcho("sentence that keeps playing", at: Date(timeIntervalSince1970: 6)))
    #expect(echoGuard.recentSpokenWords(at: Date(timeIntervalSince1970: 6)).contains("long"))
    #expect(echoGuard.recentSpokenWords(at: Date(timeIntervalSince1970: 7.5)).isEmpty)
}

// MARK: - Command words while playing

@Test func onlyStopWaitAndClickyStopCountWhilePlaying() {
    var echoGuard = EchoGuard()
    let speakingStart = Date(timeIntervalSince1970: 50)
    echoGuard.recordSpoken("Here is how the build settings work.", at: speakingStart)
    let heardAt = speakingStart.addingTimeInterval(1)
    #expect(echoGuard.acceptsWhilePlaying("Stop", at: heardAt))
    #expect(echoGuard.acceptsWhilePlaying("wait.", at: heardAt))
    #expect(echoGuard.acceptsWhilePlaying("Clicky, stop!", at: heardAt))
    // A sentence that merely contains a command word doesn't count while playing.
    #expect(!echoGuard.acceptsWhilePlaying("please wait for me", at: heardAt))
    #expect(!echoGuard.acceptsWhilePlaying("stop the build", at: heardAt))
    #expect(!echoGuard.acceptsWhilePlaying("next", at: heardAt))
    #expect(!echoGuard.acceptsWhilePlaying("", at: heardAt))
}

@Test func commandWordClickyJustSaidIsIgnoredWhilePlaying() {
    var echoGuard = EchoGuard()
    echoGuard.recordSpoken("Wait for the build to finish.", at: Date(timeIntervalSince1970: 0))
    #expect(!echoGuard.acceptsWhilePlaying("wait", at: Date(timeIntervalSince1970: 2)))
    #expect(echoGuard.acceptsWhilePlaying("stop", at: Date(timeIntervalSince1970: 2)))
    #expect(echoGuard.acceptsWhilePlaying("wait", at: Date(timeIntervalSince1970: 5)))
}

@MainActor
@Test func coordinatorBargesInOnlyOnAcceptedCommandsInEchoCancelledMode() {
    let qwen = MockSpeechEngine(name: "qwen")
    let apple = MockSpeechEngine(name: "system")
    let host = EchoTestHost()
    let coordinator = SpeechCoordinator(primaryEngine: qwen, fallbackEngine: apple, host: host)
    var clock = Date(timeIntervalSince1970: 1_000)
    coordinator.now = { clock }
    coordinator.beginAnswer()
    let segment = CaptionParser.parse("Wait until the build finishes, then open it.", id: 1, firstTagIndex: 0)
    coordinator.enqueue(segment)
    qwen.callbacks.onSegmentStart(segment.id)
    clock = clock.addingTimeInterval(1)
    #expect(coordinator.isLikelyEcho("the build finishes then"))
    #expect(!coordinator.isLikelyEcho("what time is it now"))
    #expect(!coordinator.heardWhileSpeakingWithEchoCancellation("wait"))
    #expect(!coordinator.heardWhileSpeakingWithEchoCancellation("please stop talking"))
    #expect(!host.wasInterrupted)
    #expect(coordinator.heardWhileSpeakingWithEchoCancellation("clicky stop"))
    #expect(host.wasInterrupted)
}

@MainActor
private final class EchoTestHost: SpeechCoordinatorHost {
    var wasInterrupted = false
    func cancelClaudeAndWorkers() {}
    func fireTag(index: Int) {}
    func dropUnfiredTags(_ tagIndexes: [Int]) {}
    func captionDidChange(_ caption: CaptionState) {}
    func answerDidFinish(historyText: String, wasInterrupted: Bool) { self.wasInterrupted = wasInterrupted }
    func speakApology(_ text: String) {}
    func log(_ event: String) {}
}

// MARK: - Apple word markers → samples → characters

@Test func byteSampleOffsetConvertsToFramesOfTheBufferFormat() {
    // 16-bit mono: 2 bytes per frame; 32-bit float mono: 4.
    #expect(SpeechWordMarkerTimeline.sampleOffset(byteSampleOffset: 44_100, bytesPerFrame: 2) == 22_050)
    #expect(SpeechWordMarkerTimeline.sampleOffset(byteSampleOffset: 88_200, bytesPerFrame: 4) == 22_050)
    #expect(SpeechWordMarkerTimeline.sampleOffset(byteSampleOffset: 7, bytesPerFrame: 2) == 3)
    #expect(SpeechWordMarkerTimeline.sampleOffset(byteSampleOffset: -10, bytesPerFrame: 2) == 0)
    #expect(SpeechWordMarkerTimeline.sampleOffset(byteSampleOffset: 100, bytesPerFrame: 0) == 100)
}

@Test func playbackSamplesMapBackToSourceFrames() {
    // The player runs at 48 kHz, the synthesizer wrote 22.05 kHz.
    #expect(SpeechWordMarkerTimeline.sourceSample(playbackSample: 48_000, playbackSampleRate: 48_000, sourceSampleRate: 22_050) == 22_050)
    #expect(SpeechWordMarkerTimeline.sourceSample(playbackSample: 24_000, playbackSampleRate: 48_000, sourceSampleRate: 22_050) == 11_025)
    #expect(SpeechWordMarkerTimeline.sourceSample(playbackSample: -5, playbackSampleRate: 48_000, sourceSampleRate: 22_050) == 0)
}

@Test func wordMarkersDriveCharacterProgressExactly() {
    let segment = CaptionParser.parse("Hello there, wide world.", id: 1, firstTagIndex: 0)
    let speech = segment.speech as NSString
    var timeline = SpeechWordMarkerTimeline()
    // Markers in bytes of 16-bit mono at 22.05 kHz; one callback out of order.
    let words = ["Hello", "there", "wide", "world"]
    let wordStartSeconds = [0.0, 0.4, 0.9, 1.3]
    for (word, startSeconds) in zip(words, wordStartSeconds).reversed() {
        let range = speech.range(of: word)
        timeline.addWordMarker(byteSampleOffset: Int(startSeconds * 22_050) * 2, bytesPerFrame: 2,
                               utf16Location: range.location, utf16Length: range.length)
    }
    #expect(timeline.entries.map(\.sourceSampleOffset) == [0, 8_820, 19_845, 28_665])
    // Before "there" starts: "Hello" is the word being spoken.
    #expect(timeline.spokenCharacters(atSourceSample: 100, segment: segment) == 5)
    // From the first sample of "there".
    #expect(timeline.spokenCharacters(atSourceSample: 8_820, segment: segment) == "Hello there".count)
    #expect(timeline.spokenCharacters(atSourceSample: 20_000, segment: segment) == "Hello there, wide".count)
    #expect(timeline.spokenCharacters(atSourceSample: 1_000_000, segment: segment) == "Hello there, wide world".count)
    // Through a 48 kHz player: 1.0 s played = 22 050 source frames → "wide".
    let sourceSample = SpeechWordMarkerTimeline.sourceSample(playbackSample: 48_000, playbackSampleRate: 48_000, sourceSampleRate: 22_050)
    #expect(timeline.spokenCharacters(atSourceSample: sourceSample, segment: segment) == "Hello there, wide".count)
    #expect(SpeechWordMarkerTimeline().spokenUTF16(atSourceSample: 5_000) == 0)
}

@Test func wordMarkersCountWholeCharactersAcrossUTF16() {
    // "café 👋 now": the emoji is 2 UTF-16 units but one Character.
    let segment = CaptionParser.parse("café 👋 now", id: 1, firstTagIndex: 0)
    let speech = segment.speech as NSString
    var timeline = SpeechWordMarkerTimeline()
    let nowRange = speech.range(of: "now")
    timeline.addWordMarker(byteSampleOffset: 0, bytesPerFrame: 2, utf16Location: 0, utf16Length: 4)
    timeline.addWordMarker(byteSampleOffset: 2_000, bytesPerFrame: 2, utf16Location: nowRange.location, utf16Length: nowRange.length)
    #expect(timeline.spokenCharacters(atSourceSample: 10, segment: segment) == 4)
    #expect(timeline.spokenCharacters(atSourceSample: 1_000, segment: segment) == segment.speech.count)
}

// MARK: - Headphone routes

@Test func headphoneRoutesAreClassifiedFromTransportAndDataSource() {
    let builtIn = AudioOutputRouteClassifier.fourCharacterCode("bltn")
    let usb = AudioOutputRouteClassifier.fourCharacterCode("usb ")
    let internalSpeaker = AudioOutputRouteClassifier.fourCharacterCode("ispk")
    #expect(AudioOutputRouteClassifier.fourCharacterCode("blue") == 0x626C_7565)
    // Bluetooth and BLE: headphones (AirPods etc.).
    #expect(AudioOutputRouteClassifier.isHeadphoneRoute(transportType: AudioOutputRouteClassifier.bluetoothTransportType, dataSource: nil))
    #expect(AudioOutputRouteClassifier.isHeadphoneRoute(transportType: AudioOutputRouteClassifier.bluetoothLowEnergyTransportType, dataSource: nil))
    // Built-in output on the headphone jack.
    #expect(AudioOutputRouteClassifier.isHeadphoneRoute(transportType: builtIn, dataSource: AudioOutputRouteClassifier.headphonesCode))
    #expect(AudioOutputRouteClassifier.isHeadphoneRoute(transportType: AudioOutputRouteClassifier.headphonesCode, dataSource: nil))
    // Speakers.
    #expect(!AudioOutputRouteClassifier.isHeadphoneRoute(transportType: builtIn, dataSource: internalSpeaker))
    #expect(!AudioOutputRouteClassifier.isHeadphoneRoute(transportType: usb, dataSource: nil))
    // Unknown: speakers (echo cancellation stays on).
    #expect(!AudioOutputRouteClassifier.isHeadphoneRoute(transportType: nil, dataSource: nil))
}

// MARK: - Mode decision

@Test func echoModeFallsBackToHalfDuplexWhenVoiceProcessingThrows() {
    var logLines: [String] = []
    let resolvedMode = EchoCancellationPolicy.resolvedMode(
        requestedMode: .aec, isHeadphoneRoute: false,
        enableVoiceProcessing: { throw VoiceProcessingUnavailableError() },
        log: { logLines.append($0) })
    #expect(resolvedMode == .halfDuplex)
    #expect(logLines.count == 1 && logLines[0].contains("halfDuplex"))
}

@Test func echoModeDecisionCoversSpeakersHeadphonesAndOtherModes() {
    var enableCallCount = 0
    let enable: () throws -> Void = { enableCallCount += 1 }
    #expect(EchoCancellationPolicy.resolvedMode(requestedMode: .aec, isHeadphoneRoute: false, enableVoiceProcessing: enable, log: { _ in }) == .aec)
    #expect(enableCallCount == 1)
    // Headphones: no cancellation needed, voice processing never touched.
    #expect(EchoCancellationPolicy.resolvedMode(requestedMode: .aec, isHeadphoneRoute: true, enableVoiceProcessing: enable, log: { _ in }) == .open)
    // open / halfDuplex are unchanged and never enable anything.
    #expect(EchoCancellationPolicy.resolvedMode(requestedMode: .open, isHeadphoneRoute: false, enableVoiceProcessing: enable, log: { _ in }) == .open)
    #expect(EchoCancellationPolicy.resolvedMode(requestedMode: .halfDuplex, isHeadphoneRoute: false, enableVoiceProcessing: enable, log: { _ in }) == .halfDuplex)
    #expect(enableCallCount == 1)
    #expect(EchoCancellationPolicy.shouldEnableVoiceProcessing(requestedMode: .aec, isHeadphoneRoute: false))
    #expect(!EchoCancellationPolicy.shouldEnableVoiceProcessing(requestedMode: .open, isHeadphoneRoute: false))
    #expect(ClickySettings.EchoMode(rawValue: "aec") == .aec)
}
