//
//  QwenP3Tests.swift
//  ClickyCoreTests
//
//  P3 (Qwen via mlx-serve) checks that need no audio and no server: the
//  supervisor decision for every branch, the watchdog / overrun maths, the
//  exact request body, WAV parsing, the TTS lexicon, the early first cut
//  for Qwen, the safety net, EchoGuard, speed steps, and the coordinator's
//  one-segment fallback. Extends the P2 tests in CaptionTests /
//  SpeechCoordinatorTests / NarrationSegmenterTests without repeating them.
//

import Foundation
import Testing
@testable import ClickyCore

// MARK: - Helpers

/// Tone bursts separated by silences, as Float PCM (24 kHz like mlx-serve).
private func toneBursts(_ bursts: [(seconds: Double, silenceAfter: Double)], lead: Double, sampleRate: Double = 24_000) -> PCMAudio {
    var samples = [Float](repeating: 0, count: Int(lead * sampleRate))
    for burst in bursts {
        for sampleIndex in 0..<Int(burst.seconds * sampleRate) {
            samples.append(0.3 * sin(Float(sampleIndex) * 2 * .pi * 220 / Float(sampleRate)))
        }
        samples += [Float](repeating: 0, count: Int(burst.silenceAfter * sampleRate))
    }
    return PCMAudio(samples: samples, sampleRate: sampleRate)
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

/// A RIFF/WAVE file. `formatTag` 1 = PCM, 3 = float, 0xFFFE = extensible.
private func wavFile(formatTag: UInt16, subFormat: UInt16? = nil, channels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16,
                     payload: [UInt8], dataSizeOverride: UInt32? = nil) -> Data {
    var fmt: [UInt8] = littleEndian(formatTag) + littleEndian(channels) + littleEndian(sampleRate)
    let blockAlign = channels * bitsPerSample / 8
    fmt += littleEndian(sampleRate * UInt32(blockAlign)) + littleEndian(blockAlign) + littleEndian(bitsPerSample)
    if let subFormat {
        fmt += littleEndian(UInt16(22)) + littleEndian(bitsPerSample) + littleEndian(UInt32(0)) + littleEndian(subFormat) + [UInt8](repeating: 0, count: 14)
    }
    var bytes: [UInt8] = Array("RIFF".utf8) + littleEndian(UInt32(4 + 8 + fmt.count + 8 + payload.count)) + Array("WAVE".utf8)
    bytes += Array("fmt ".utf8) + littleEndian(UInt32(fmt.count)) + fmt
    bytes += Array("data".utf8) + littleEndian(dataSizeOverride ?? UInt32(payload.count)) + payload
    return Data(bytes)
}

private func narrationSegments(_ text: String, options: NarrationSegmenter.Options, charByChar: Bool) -> [String] {
    var segmenter = NarrationSegmenter(options: options)
    var segments: [String] = []
    if charByChar {
        for character in text { segments += segmenter.feed(String(character)) }
    } else {
        segments += segmenter.feed(text)
    }
    return segments + segmenter.finish()
}

// MARK: - Supervisor

@Test func supervisorDecidesEveryBranch() {
    let installed = QwenSupervisor.Probe(isResponding: false, isBinaryInstalled: true)
    #expect(QwenSupervisor.decide(probe: installed, lsof: .loopbackOnly(processIDs: [44155])) == .adopt)
    // Adopted even while it's still loading (not answering yet).
    #expect(QwenSupervisor.decide(probe: QwenSupervisor.Probe(isResponding: true, isBinaryInstalled: false), lsof: .loopbackOnly(processIDs: [1])) == .adopt)
    #expect(QwenSupervisor.decide(probe: installed, lsof: .exposed(addresses: ["*:11234"])) == .unavailable(status: "Qwen unavailable: not loopback-only"))
    #expect(QwenSupervisor.decide(probe: installed, lsof: .none) == .spawn)
    #expect(QwenSupervisor.decide(probe: QwenSupervisor.Probe(isResponding: false, isBinaryInstalled: false), lsof: .none)
            == .unavailable(status: "Qwen unavailable: mlx-serve not found"))
    // Answering but invisible to lsof (another user's process): binding unknown.
    #expect(QwenSupervisor.decide(probe: QwenSupervisor.Probe(isResponding: true, isBinaryInstalled: true), lsof: .none)
            == .unavailable(status: "Qwen unavailable: not loopback-only"))
    // A debug port override is never spawned on.
    #expect(QwenSupervisor.decide(probe: QwenSupervisor.Probe(isResponding: false, isBinaryInstalled: true, isPortOverridden: true, port: 11299), lsof: .none)
            == .unavailable(status: "Qwen unavailable: nothing on port 11299"))
}

@Test func supervisorParsesLsof() {
    let header = "COMMAND     PID          USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME\n"
    let loopback = header + "mlx-serve 44155 adhyanmahajan    5u  IPv4 0x9d68bfd166c36532      0t0  TCP 127.0.0.1:11234 (LISTEN)\n"
    #expect(QwenSupervisor.listener(fromLsof: loopback) == .loopbackOnly(processIDs: [44155]))
    let loopbackSix = header + "mlx-serve 7 me 6u IPv6 0x1 0t0 TCP [::1]:11234 (LISTEN)\n"
    #expect(QwenSupervisor.listener(fromLsof: loopbackSix) == .loopbackOnly(processIDs: [7]))
    let wildcard = header + "mlx-serve 9 me 5u IPv4 0x1 0t0 TCP *:11234 (LISTEN)\n"
    #expect(QwenSupervisor.listener(fromLsof: wildcard) == .exposed(addresses: ["*:11234"]))
    let anySix = header + "mlx-serve 9 me 5u IPv6 0x1 0t0 TCP [::]:11234 (LISTEN)\n"
    #expect(QwenSupervisor.listener(fromLsof: anySix) == .exposed(addresses: ["[::]:11234"]))
    let lan = header + "python3 3 me 5u IPv4 0x1 0t0 TCP 192.168.1.20:11234 (LISTEN)\n"
    #expect(QwenSupervisor.listener(fromLsof: lan) == .exposed(addresses: ["192.168.1.20:11234"]))
    // Loopback plus an exposed socket is exposed.
    #expect(QwenSupervisor.listener(fromLsof: loopback + "mlx-serve 44155 me 6u IPv4 0x2 0t0 TCP 0.0.0.0:11234 (LISTEN)\n")
            == .exposed(addresses: ["0.0.0.0:11234"]))
    #expect(QwenSupervisor.listener(fromLsof: "") == .none)
}

@Test func supervisorPicksTheLoadedModelAndRespawnsOncePerMinute() {
    let models: [[String: Any]] = [
        ["id": "ddalcu/Qwen-Image-2.1-MLX-Serve-8bit", "loaded": true],
        ["id": "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", "loaded": false],
        ["id": "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "loaded": true]
    ]
    #expect(QwenSupervisor.ttsModelIdentifier(fromModels: models) == "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")
    // With a reference clip Clicky always asks for Base (the only model that clones).
    #expect(QwenTuning.modelIdentifier(hasReferenceClip: true, loadedModelIdentifier: QwenTuning.customVoiceModelIdentifier) == QwenTuning.defaultModelIdentifier)
    #expect(QwenTuning.modelIdentifier(hasReferenceClip: false, loadedModelIdentifier: QwenTuning.customVoiceModelIdentifier) == QwenTuning.customVoiceModelIdentifier)
    #expect(QwenSupervisor.ttsModelIdentifier(fromModels: []) == QwenTuning.defaultModelIdentifier)
    #expect(!QwenSupervisor.supportsSpeakers(modelIdentifier: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"))
    #expect(QwenSupervisor.supportsSpeakers(modelIdentifier: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"))
    let spawned = Date(timeIntervalSince1970: 1000)
    #expect(QwenSupervisor.mayRespawn(lastSpawnDate: nil, now: spawned))
    #expect(!QwenSupervisor.mayRespawn(lastSpawnDate: spawned, now: spawned.addingTimeInterval(59)))
    #expect(QwenSupervisor.mayRespawn(lastSpawnDate: spawned, now: spawned.addingTimeInterval(60)))
}

// MARK: - Tuning

@Test func watchdogAndOverrunFormulas() {
    #expect(QwenTuning.lookahead == 1)
    // Generous: a slow segment is waited for, never swapped to another voice.
    #expect(QwenTuning.watchdogSeconds(characters: 0) == 20)
    #expect(QwenTuning.watchdogSeconds(characters: 30) == 20)
    #expect(abs(QwenTuning.watchdogSeconds(characters: 300) - (10 + 3 * 20)) < 1e-9)
    #expect(QwenTuning.maxTokens(characters: 15) == 80)
    // Normal audio is never cut; 3x the estimate is.
    let normal = toneBursts([(1.0, 0)], lead: 0.1)
    #expect(WordTiming.overrunCutTime(normal, characters: 15) == nil)
    // 15 chars → limit 3 s. Pauses at 1.0–1.3 s and 2.5–2.8 s; the last before 3 s wins.
    let runaway = toneBursts([(1.0, 0.3), (1.2, 0.3), (5.0, 0)], lead: 0)
    let cut = WordTiming.overrunCutTime(runaway, characters: 15)
    #expect(cut != nil && abs(cut! - 2.5) <= 0.011, "cut at \(String(describing: cut))")
    // No pause before the limit: cut at the limit.
    let noPause = toneBursts([(8.0, 0)], lead: 0)
    #expect(WordTiming.overrunCutTime(noPause, characters: 15) == 3.0)
    #expect(abs(runaway.prefix(seconds: 2.5).duration - 2.5) < 1e-6)
}

@Test func requestBodyHasExactlyTheProbedKeys() throws {
    let body = QwenTuning.requestBody(model: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", speech: "Open PR #12 on GitHub.",
                                      referenceClipBase64: "UklGRg==")
    // One fixed voice: Base + the reference clip; never speaker/instruct (mlx-serve ignores them).
    #expect(Set(body.keys) == ["model", "input", "ref_audio", "language", "response_format", "max_tokens"])
    #expect(body["model"] as? String == QwenTuning.defaultModelIdentifier)
    #expect(body["ref_audio"] as? String == "UklGRg==")
    #expect(body["input"] as? String == "Open P R number 12 on Git Hub.")
    #expect(body["response_format"] as? String == "wav")
    #expect(body["language"] as? String == "English")
    #expect(body["max_tokens"] as? Int == 50 + 2 * "Open P R number 12 on Git Hub.".count)
    // Serializable as sent.
    let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    #expect(String(decoding: json, as: UTF8.self).hasPrefix(#"{"input":"#))
}

@Test func voiceRateStepsThroughFourSpeeds() {
    #expect(QwenTuning.steppedRate(from: 1.0, faster: true) == 1.15)
    #expect(QwenTuning.steppedRate(from: 1.15, faster: true) == 1.3)
    #expect(QwenTuning.steppedRate(from: 1.3, faster: true) == 1.3)
    #expect(QwenTuning.steppedRate(from: 1.0, faster: false) == 0.85)
    #expect(QwenTuning.steppedRate(from: 0.85, faster: false) == 0.85)
    #expect(QwenTuning.nearestRate(to: 1.21) == 1.15)
    #expect(QwenTuning.speakers.count == 9 && QwenTuning.englishNativeSpeakers == ["Ryan", "Aiden"])
}

// MARK: - WAV and timing

@Test func wavHeadersParse() {
    // mlx-serve: 16-bit PCM mono 24 kHz.
    let pcm16 = wavFile(formatTag: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16,
                        payload: littleEndian(Int16(16384)) + littleEndian(Int16(-16384)))
    let mono = PCMAudio(wavData: pcm16)
    #expect(mono?.sampleRate == 24_000 && mono?.samples == [0.5, -0.5])
    // Stereo averages channels.
    let stereo = wavFile(formatTag: 1, channels: 2, sampleRate: 48_000, bitsPerSample: 16,
                         payload: littleEndian(Int16(16384)) + littleEndian(Int16(0)))
    #expect(PCMAudio(wavData: stereo)?.samples == [0.25])
    // 32-bit float and WAVE_FORMAT_EXTENSIBLE (float sub-format).
    let floatPayload = littleEndian(Float(0.75).bitPattern)
    #expect(PCMAudio(wavData: wavFile(formatTag: 3, channels: 1, sampleRate: 24_000, bitsPerSample: 32, payload: floatPayload))?.samples == [0.75])
    #expect(PCMAudio(wavData: wavFile(formatTag: 0xFFFE, subFormat: 3, channels: 1, sampleRate: 24_000, bitsPerSample: 32, payload: floatPayload))?.samples == [0.75])
    // A streaming writer's 0xFFFFFFFF data size reads to the end.
    let streamed = wavFile(formatTag: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16,
                           payload: littleEndian(Int16(0)) + littleEndian(Int16(0)) + littleEndian(Int16(0)), dataSizeOverride: 0xFFFF_FFFF)
    #expect(PCMAudio(wavData: streamed)?.samples.count == 3)
    // Not a WAV (an mp3 or a JSON error) → nil, so the engine falls back to a proportional estimate.
    #expect(PCMAudio(wavData: Data("ID3\u{03}rest".utf8)) == nil)
    #expect(PCMAudio(wavData: Data(#"{"error":"bad"}"#.utf8)) == nil)
    // 8-bit PCM isn't supported.
    #expect(PCMAudio(wavData: wavFile(formatTag: 1, channels: 1, sampleRate: 8000, bitsPerSample: 8, payload: [128, 128])) == nil)
}

@Test func silenceBoundsOfAllSilenceAndOfTrimmedAudio() {
    let silent = PCMAudio(samples: [Float](repeating: 0, count: 2400), sampleRate: 24_000)
    let bounds = WordTiming.silenceBounds(silent)
    #expect(abs(bounds.lead - 0.1) < 1e-9 && bounds.tail == 0)
    #expect(WordTiming.pauses(silent).isEmpty)
    // Trimming at a pause start leaves that pause as the tail.
    let audio = toneBursts([(0.5, 0.3), (0.5, 0)], lead: 0.2)
    let trimmed = audio.prefix(seconds: 0.85)
    #expect(abs(WordTiming.silenceBounds(trimmed).tail - 0.15) <= 0.011)
}

@Test func wordTimesAreMonotonicWeightCommasAndSnap() {
    // One continuous burst (no pauses): pure syllable + punctuation weights.
    let speech = "Open the pull request, go to Files changed."
    let wordRanges = CaptionParser.parse(speech, id: 0, firstTagIndex: 0).wordRanges
    let flat = toneBursts([(3.0, 0)], lead: 0.1)
    let times = WordTiming.wordTimes(speech: speech, wordRanges: wordRanges, audio: flat)
    #expect(times.starts == times.starts.sorted())
    for wordIndex in wordRanges.indices { #expect(times.ends[wordIndex] >= times.starts[wordIndex]) }
    #expect(abs(times.starts[0] - 0.1) <= 0.011)
    #expect(abs(times.ends.last! - flat.duration) <= 0.011)
    // The comma after "request" adds one unit of pause; "the"→"pull" has none.
    let gapAfterComma = times.starts[4] - times.ends[3]
    let gapWithoutPunctuation = times.starts[2] - times.ends[1]
    #expect(gapWithoutPunctuation < 1e-9)
    let unit = (times.ends[1] - times.starts[1]) // "the" = 1 syllable
    #expect(abs(gapAfterComma - unit) < 1e-6)
    // Spoken characters never go backwards and reach the total at the end.
    var previous = 0
    for step in 0...40 {
        let spoken = times.spokenCharacters(at: Double(step) * 0.08, wordRanges: wordRanges, totalCharacters: speech.count)
        #expect(spoken >= previous)
        previous = spoken
    }
    #expect(previous == speech.count)
    // A real pause after "request," snaps "go" onto its midpoint.
    let paused = toneBursts([(1.2, 0.3), (1.2, 0)], lead: 0.1)
    let snapped = WordTiming.wordTimes(speech: speech, wordRanges: wordRanges, audio: paused)
    #expect(abs(snapped.starts[4] - (0.1 + 1.2 + 0.15)) <= 0.02, "go at \(snapped.starts[4])")
    #expect(snapped.starts == snapped.starts.sorted())
}

@Test func wordTimingStaysOnTheOriginalCaptionWords() {
    // The caption has "PR #12" (2 words); the TTS hears "P R number 12".
    let caption = CaptionParser.parse("Open PR #12 now.", id: 0, firstTagIndex: 0)
    let times = WordTiming.wordTimes(speech: caption.speech, wordRanges: caption.wordRanges, audio: toneBursts([(2.0, 0)], lead: 0))
    #expect(times.starts.count == caption.wordRanges.count)
    #expect(WordTiming.syllables(in: "PR") == 2)
    #expect(WordTiming.syllables(in: "#12") == 1) // "twelve"
}

// MARK: - Lexicon

@Test func lexiconRespellsOnlyForTTS() {
    #expect(Lexicon.apply("Open #12") == "Open number 12")
    #expect(Lexicon.apply("Merge the PR.") == "Merge the P R.")
    #expect(Lexicon.apply("Open GitHub") == "Open Git Hub")
    #expect(Lexicon.apply("Build in Xcode") == "Build in X code")
    #expect(Lexicon.apply("A SwiftUI view") == "A Swift U I view")
    #expect(Lexicon.apply("Paste the JSON") == "Paste the Jason")
    #expect(Lexicon.apply("Hold Ctrl+Option") == "Hold Control Option")
    #expect(Lexicon.apply("Hold Control + Option") == "Hold Control Option")
    #expect(Lexicon.apply("Update to v2.1 today") == "Update to version 2.1 today")
    // Words that only contain the patterns are left alone.
    #expect(Lexicon.apply("Prepare the PRD and the jsonl print") == "Prepare the PRD and the jsonl print")
    #expect(Lexicon.apply("Open PR #12 on GitHub") == "Open P R number 12 on Git Hub")
}

// MARK: - Segmenter (Qwen options)

@Test func qwenSegmenterCutsTheFirstClauseEarly() {
    let sentence = "Open the pull request, go to Files changed, and check the build."
    let qwenSegments = narrationSegments(sentence, options: .qwen, charByChar: false)
    #expect(qwenSegments.first == "Open the pull request, go to Files changed, ")
    #expect(qwenSegments.joined() == sentence)
    #expect(narrationSegments(sentence, options: .qwen, charByChar: true) == qwenSegments)
    // Default options: today's behaviour (a 64-char first sentence isn't cut).
    #expect(narrationSegments(sentence, options: NarrationSegmenter.Options(), charByChar: false) == [sentence])
    #expect(NarrationSegmenter.Options() == NarrationSegmenter.Options(firstCutMinChars: 24, firstCutMinSentenceLen: 80))
    // A comma before 16 characters isn't a cut.
    let short = "Okay, found it. Now click the Run button at the top."
    #expect(narrationSegments(short, options: .qwen, charByChar: false).first == "Okay, found it. ")
}

@Test func qwenSegmenterCharByCharEqualsWhole() {
    for vector in segmenterVectors + ["Open the pull request, go to Files changed, and check the build."] {
        let whole = narrationSegments(vector, options: .qwen, charByChar: false)
        let chars = narrationSegments(vector, options: .qwen, charByChar: true)
        #expect(chars == whole, "differs for: \(vector)\nwhole: \(whole)\nchars: \(chars)")
        #expect(whole.joined() == vector, "lost text for: \(vector)")
    }
}

// MARK: - Safety net and echo

@Test func safetyNetKeepsRealNumbersAndStripsLiveIDs() {
    let liveIDs: Set<Int> = [12, 42, 57]
    #expect(SpeechSafetyNet.clean("Open PR #12 first.", liveElementIDs: liveIDs) == .init(speechText: "Open PR #12 first.", leakCount: 0))
    #expect(SpeechSafetyNet.clean("That's issue #42.", liveElementIDs: liveIDs) == .init(speechText: "That's issue #42.", leakCount: 0))
    #expect(SpeechSafetyNet.clean("Now click #57 to save.", liveElementIDs: liveIDs) == .init(speechText: "Now click to save.", leakCount: 1))
    // #99 isn't a live id: kept.
    #expect(SpeechSafetyNet.clean("Click #99.", liveElementIDs: liveIDs).leakCount == 0)
}

@Test func echoGuardAcceptsOnlyRealStopAndWait() {
    var guardState = EchoGuard()
    let start = Date(timeIntervalSince1970: 0)
    #expect(guardState.accepts("stop", at: start))
    #expect(guardState.accepts("clicky stop", at: start))
    #expect(guardState.accepts("wait", at: start))
    // Ordinary words never barge in.
    #expect(!guardState.accepts("open the settings", at: start))
    guardState.recordSpoken("Don't stop the build yet.", at: start)
    #expect(!guardState.accepts("stop", at: start.addingTimeInterval(2)))
    #expect(guardState.accepts("wait", at: start.addingTimeInterval(2)))
    #expect(guardState.accepts("stop", at: start.addingTimeInterval(4.5)))
    #expect(abs(QwenTuning.echoTailSeconds - (QwenTuning.audioOutputLatencySeconds + 0.25)) < 1e-9)
}

// MARK: - Coordinator fallback

@MainActor
@Test func slowSegmentFallsBackAloneAndQueuedOnesWait() {
    let sharedLog = SharedLog()
    let qwen = MockSpeechEngine(name: "qwen", sharedLog: sharedLog)
    let apple = MockSpeechEngine(name: "apple", sharedLog: sharedLog)
    let host = MockCoordinatorHost(sharedLog: sharedLog)
    let coordinator = SpeechCoordinator(primaryEngine: qwen, fallbackEngine: apple, host: host)
    coordinator.beginAnswer()
    let first = CaptionParser.parse("Open the pull request, ", id: 1, firstTagIndex: 0)
    let second = CaptionParser.parse("go to Files changed.", id: 2, firstTagIndex: 0)
    let third = CaptionParser.parse("Then check the build.", id: 3, firstTagIndex: 0)
    coordinator.enqueue(first)
    coordinator.enqueue(second)
    // Segment 1 timed out (watchdog): Qwen hands back only it.
    qwen.queued.removeFirst()
    qwen.callbacks.onFailure([first], false)
    #expect(apple.queued.map(\.id) == [1])
    #expect(qwen.queued.isEmpty, "segment 2 must not play over Apple")
    coordinator.enqueue(third)
    #expect(qwen.queued.isEmpty)
    apple.playNext()
    // Apple is done: back to Qwen, in order.
    #expect(qwen.queued.map(\.id) == [2, 3])
    coordinator.streamDidFinish(spawnedWorkers: false)
    qwen.playNext()
    qwen.playNext()
    #expect(host.history == "Open the pull request, go to Files changed.Then check the build.")
    #expect(coordinator.didUseFallback)
}

@MainActor
@Test func deadServerHandsTheRestOfTheAnswerToApple() {
    let sharedLog = SharedLog()
    let qwen = MockSpeechEngine(name: "qwen", sharedLog: sharedLog)
    let apple = MockSpeechEngine(name: "apple", sharedLog: sharedLog)
    let host = MockCoordinatorHost(sharedLog: sharedLog)
    let coordinator = SpeechCoordinator(primaryEngine: qwen, fallbackEngine: apple, host: host)
    coordinator.beginAnswer()
    let first = CaptionParser.parse("One. ", id: 1, firstTagIndex: 0)
    let second = CaptionParser.parse("Two.", id: 2, firstTagIndex: 0)
    coordinator.enqueue(first)
    qwen.playNext()
    coordinator.enqueue(second)
    qwen.queued.removeAll()
    qwen.callbacks.onFailure([second], true)
    coordinator.enqueue(CaptionParser.parse("Three.", id: 3, firstTagIndex: 0))
    #expect(apple.queued.map(\.id) == [2, 3])
    #expect(qwen.queued.isEmpty)
    coordinator.streamDidFinish(spawnedWorkers: false)
    apple.playNext()
    apple.playNext()
    #expect(host.history == "One. Two.Three.")
}

@Test func requestBodyWithoutAClipHasNoReference() {
    let body = QwenTuning.requestBody(model: QwenTuning.defaultModelIdentifier, speech: "Hi.", referenceClipBase64: nil)
    #expect(body["ref_audio"] == nil)
    #expect(body["speaker"] == nil && body["instruct"] == nil)
}

private func testWAV(samples: [Int16], rate: UInt32 = 1000) -> Data {
    var data = Data("RIFF".utf8)
    func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    put32(UInt32(36 + samples.count * 2))
    data.append(contentsOf: Data("WAVEfmt ".utf8))
    put32(16); put16(1); put16(1); put32(rate); put32(rate * 2); put16(2); put16(16)
    data.append(contentsOf: Data("data".utf8))
    put32(UInt32(samples.count * 2))
    samples.forEach { put16(UInt16(bitPattern: $0)) }
    return data
}

@Test func leadingSilenceIsTrimmedDownToAShortLeadIn() {
    let wav = testWAV(samples: Array(repeating: 0, count: 600) + Array(repeating: 9000, count: 100))
    let trimmed = QwenTuning.trimmingLeadingSilence(wav: wav)
    // 50 samples of lead-in (0.05 s at 1 kHz) and all of the sound.
    #expect(trimmed.count == 44 + (50 + 100) * 2)
    #expect(trimmed[40] == UInt8((50 + 100) * 2 & 0xFF))
    #expect(Int(trimmed[4]) | Int(trimmed[5]) << 8 == trimmed.count - 8)
}

@Test func wavsThatCantBeTrimmedComeBackUntouched() {
    let silent = testWAV(samples: Array(repeating: 0, count: 100))
    #expect(QwenTuning.trimmingLeadingSilence(wav: silent) == silent)
    let startsLoud = testWAV(samples: Array(repeating: 9000, count: 100))
    #expect(QwenTuning.trimmingLeadingSilence(wav: startsLoud) == startsLoud)
    let notPCM = Data("not a wav file at all, just some bytes that are long enough".utf8)
    #expect(QwenTuning.trimmingLeadingSilence(wav: notPCM) == notPCM)
}
