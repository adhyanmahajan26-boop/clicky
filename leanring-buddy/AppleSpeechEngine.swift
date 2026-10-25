//
//  AppleSpeechEngine.swift
//  leanring-buddy
//
//  The built-in Mac voice as a SpeechEngine. AVSpeechSynthesizer queues the
//  utterances; each is kept (strongly) with its caption segment and matched
//  back by identity (===) in the delegate callbacks, which hop to the main
//  queue. willSpeakRange gives exact progress (NSMaxRange, forward only).
//  Some voices never send ranges: if none arrives within 600 ms the engine
//  estimates from a running average of seconds per character for that
//  voice and rate (seeded at 0.065), capped at 90 % until the utterance
//  actually finishes. The rate follows v2.voice.rate ("slower"/"faster").
//
//  P6.4 "aec": while the AudioEngineHub's voice processing is on (decided
//  per answer), segments are rendered with write(_:toBufferCallback:
//  toMarkerCallback:) one at a time and the buffers scheduled on the hub's
//  player node, so the canceller hears them. Word markers (byteSampleOffset
//  → frames → characters, SpeechWordMarkerTimeline) against the player
//  node's sample time give exact caption progress.
//

import AVFoundation
import ClickyCore
import Foundation

@MainActor
final class AppleSpeechEngine: NSObject, SpeechEngine {
    let name = "system"
    var callbacks = SpeechEngineCallbacks()

    private let synthesizer = AVSpeechSynthesizer()
    private let voiceProvider: () -> AVSpeechSynthesisVoice?
    private static let rateMultiplier: Float = 0.95
    private static let rangeTimeoutSeconds: TimeInterval = 0.6
    private static let estimateCap = 0.9

    private var pending: [(utterance: AVSpeechUtterance, segment: CaptionSegment)] = []
    private var current: (utterance: AVSpeechUtterance, segment: CaptionSegment, startDate: Date, hasRanges: Bool)?
    private var estimateTimer: Timer?
    private var hasEndedAnswer = false
    /// Seconds per character, by "voice identifier|rate".
    private static var secondsPerCharacterByVoice: [String: Double] = [:]

    // MARK: Shared engine ("aec")

    private let audioEngineHub: AudioEngineHub?
    /// Renders utterances to buffers (no delegate: its events belong to `synthesizer`).
    private let bufferWritingSynthesizer = AVSpeechSynthesizer()
    private lazy var sharedPlayerChannel: SharedEnginePlayerChannel? = {
        guard let audioEngineHub else { return nil }
        let playerChannel = audioEngineHub.makePlayerChannel()
        playerChannel.onSharedEngineStopped = { [weak self] in self?.sharedEngineDidStop() }
        return playerChannel
    }()
    private var usesSharedEngineForAnswer = false
    private var sharedQueue: [CaptionSegment] = []
    private var sharedPlayback: SharedUtterancePlayback?
    private var sharedPlaybackGeneration = 0
    private var sharedProgressTimer: Timer?
    private var isSharedPlaybackPaused = false
    private static let estimateCapWithoutMarkers = 0.9

    init(voiceProvider: @escaping () -> AVSpeechSynthesisVoice?, audioEngineHub: AudioEngineHub? = nil) {
        self.voiceProvider = voiceProvider
        self.audioEngineHub = audioEngineHub
        super.init()
        synthesizer.delegate = self
    }

    var isPlaying: Bool { synthesizer.isSpeaking || !pending.isEmpty || sharedPlayback != nil || !sharedQueue.isEmpty }

    func begin(epoch: Int) {
        stopNow()
        hasEndedAnswer = false
        usesSharedEngineForAnswer = audioEngineHub?.isVoiceProcessingActive == true
    }

    func enqueue(_ segment: CaptionSegment) {
        if usesSharedEngineForAnswer, audioEngineHub?.isVoiceProcessingActive == true {
            sharedQueue.append(segment)
            startNextSharedSegmentIfIdle()
            return
        }
        let utterance = makeUtterance(for: segment)
        pending.append((utterance, segment))
        synthesizer.speak(utterance)
    }

    private func makeUtterance(for segment: CaptionSegment) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: segment.speech)
        utterance.voice = voiceProvider()
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, Self.utteranceRate)
        return utterance
    }

    func endOfAnswer() {
        hasEndedAnswer = true
        reportAllPlayedIfDone()
    }

    func stopNow() {
        pending = []
        current = nil
        estimateTimer?.invalidate()
        estimateTimer = nil
        synthesizer.stopSpeaking(at: .immediate)
        stopSharedPlayback()
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
        isSharedPlaybackPaused = true
        if sharedPlayback != nil { sharedPlayerChannel?.pause() }
    }

    func resume() {
        synthesizer.continueSpeaking()
        isSharedPlaybackPaused = false
        if sharedPlayback != nil { sharedPlayerChannel?.resume() }
        startNextSharedSegmentIfIdle()
    }

    private static var utteranceRate: Float {
        AVSpeechUtteranceDefaultSpeechRate * rateMultiplier * Float(ClickySettings.voiceRate)
    }

    private var voiceKey: String {
        "\(voiceProvider()?.identifier ?? "default")|\(Self.utteranceRate)"
    }

    // MARK: - Delegate events (main actor)

    fileprivate func didStart(_ utterance: AVSpeechUtterance) {
        guard let pendingIndex = pending.firstIndex(where: { $0.utterance === utterance }) else { return }
        let segment = pending.remove(at: pendingIndex).segment
        current = (utterance, segment, Date(), false)
        callbacks.onSegmentStart(segment.id)
        startEstimateTimer()
    }

    fileprivate func willSpeak(_ range: NSRange, of utterance: AVSpeechUtterance) {
        guard var playing = current, playing.utterance === utterance else { return }
        playing.hasRanges = true
        current = playing
        let spoken = playing.segment.spokenCharacters(throughUTF16: NSMaxRange(range))
        // POINTs fire with Apple's own word callback: lead = the word being spoken.
        callbacks.onProgress(playing.segment.id, spoken, spoken, true)
    }

    fileprivate func didFinish(_ utterance: AVSpeechUtterance) {
        guard let playing = current, playing.utterance === utterance else { return }
        let elapsed = Date().timeIntervalSince(playing.startDate)
        let characterCount = max(1, playing.segment.speechLength)
        let previous = Self.secondsPerCharacterByVoice[voiceKey] ?? 0.065
        Self.secondsPerCharacterByVoice[voiceKey] = 0.7 * previous + 0.3 * (elapsed / Double(characterCount))
        estimateTimer?.invalidate()
        estimateTimer = nil
        current = nil
        callbacks.onSegmentEnd(playing.segment.id)
        reportAllPlayedIfDone()
    }

    fileprivate func didCancel(_ utterance: AVSpeechUtterance) {
        if current?.utterance === utterance { current = nil }
        pending.removeAll { $0.utterance === utterance }
    }

    private func startEstimateTimer() {
        estimateTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportEstimate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        estimateTimer = timer
    }

    private func reportEstimate() {
        guard let playing = current, !playing.hasRanges else {
            estimateTimer?.invalidate()
            estimateTimer = nil
            return
        }
        let elapsed = Date().timeIntervalSince(playing.startDate)
        guard elapsed >= Self.rangeTimeoutSeconds else { return }
        let secondsPerCharacter = Self.secondsPerCharacterByVoice[voiceKey] ?? 0.065
        let total = playing.segment.speechLength
        let estimate = min(Int(Double(total) * Self.estimateCap), Int(elapsed / secondsPerCharacter))
        callbacks.onProgress(playing.segment.id, estimate, estimate, false)
    }

    private func reportAllPlayedIfDone() {
        guard hasEndedAnswer, pending.isEmpty, current == nil, sharedQueue.isEmpty, sharedPlayback == nil else { return }
        callbacks.onAllPlayed()
    }

    // MARK: - Shared engine playback ("aec")

    private func startNextSharedSegmentIfIdle() {
        guard usesSharedEngineForAnswer, sharedPlayback == nil, !isSharedPlaybackPaused,
              let sharedPlayerChannel, !sharedQueue.isEmpty else { return }
        let segment = sharedQueue.removeFirst()
        let utterance = makeUtterance(for: segment)
        sharedPlaybackGeneration += 1
        let playbackGeneration = sharedPlaybackGeneration
        sharedPlayback = SharedUtterancePlayback(segment: segment, generation: playbackGeneration)
        sharedPlayerChannel.startSegment(rate: 1) // the utterance rate already has v2.voice.rate
        bufferWritingSynthesizer.write(
            utterance,
            toBufferCallback: Self.makeBufferCallback(appleSpeechEngine: self, playbackGeneration: playbackGeneration),
            toMarkerCallback: Self.makeMarkerCallback(appleSpeechEngine: self, playbackGeneration: playbackGeneration)
        )
    }

    fileprivate func sharedSynthesizerDidWrite(_ audioBuffer: AVAudioBuffer, playbackGeneration: Int) {
        guard let playback = sharedPlayback, playback.generation == playbackGeneration else { return }
        guard let pcmBuffer = audioBuffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0 else {
            // An empty buffer ends the utterance.
            playback.hasFinishedSynthesis = true
            finishSharedSegmentIfPlayedOut()
            return
        }
        if playback.bytesPerFrame == 0 {
            playback.sourceSampleRate = pcmBuffer.format.sampleRate
            playback.bytesPerFrame = Int(pcmBuffer.format.streamDescription.pointee.mBytesPerFrame)
            playback.applyPendingWordMarkers()
        }
        let isScheduled = sharedPlayerChannel?.schedule(pcmBuffer) { [weak self, weak playback] in
            guard let self, let playback, self.sharedPlayback === playback else { return }
            playback.playedBufferCount += 1
            self.finishSharedSegmentIfPlayedOut()
        } ?? false
        guard isScheduled else {
            print("⚠️ Mac voice: shared engine unavailable, speaking the rest normally")
            moveSharedSegmentsToSynthesizer(includingCurrent: !playback.hasStarted)
            return
        }
        playback.scheduledBufferCount += 1
        playback.scheduledSourceFrames += Int(pcmBuffer.frameLength)
        if !playback.hasStarted {
            playback.hasStarted = true
            callbacks.onSegmentStart(playback.segment.id)
            startSharedProgressTimer()
        }
    }

    fileprivate func sharedSynthesizerDidMark(_ wordMarkers: [WordMarkerValues], playbackGeneration: Int) {
        guard let playback = sharedPlayback, playback.generation == playbackGeneration else { return }
        playback.pendingWordMarkers.append(contentsOf: wordMarkers)
        if playback.bytesPerFrame > 0 { playback.applyPendingWordMarkers() }
    }

    private func finishSharedSegmentIfPlayedOut() {
        guard let playback = sharedPlayback, playback.hasFinishedSynthesis,
              playback.playedBufferCount >= playback.scheduledBufferCount else { return }
        finishSharedSegment(playback)
    }

    private func finishSharedSegment(_ playback: SharedUtterancePlayback) {
        sharedProgressTimer?.invalidate()
        sharedProgressTimer = nil
        sharedPlayback = nil
        callbacks.onSegmentEnd(playback.segment.id)
        startNextSharedSegmentIfIdle()
        reportAllPlayedIfDone()
    }

    private func startSharedProgressTimer() {
        sharedProgressTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportSharedProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sharedProgressTimer = timer
    }

    private func reportSharedProgress() {
        guard let playback = sharedPlayback, playback.hasStarted, let sharedPlayerChannel else { return }
        guard sharedPlayerChannel.isEngineRunning else {
            finishSharedSegment(playback)
            return
        }
        let sourceSample = SpeechWordMarkerTimeline.sourceSample(
            playbackSample: sharedPlayerChannel.playedSampleTime,
            playbackSampleRate: SharedEnginePlayerChannel.playbackFormat.sampleRate,
            sourceSampleRate: playback.sourceSampleRate
        )
        let segment = playback.segment
        if !playback.wordMarkerTimeline.isEmpty {
            // Exact: the word whose first sample has played (lead = the same, like willSpeakRange).
            let spoken = playback.wordMarkerTimeline.spokenCharacters(atSourceSample: sourceSample, segment: segment)
            callbacks.onProgress(segment.id, spoken, spoken, true)
        } else if playback.scheduledSourceFrames > 0 {
            // A voice without markers: share of the audio rendered so far.
            let cap = playback.hasFinishedSynthesis ? 1 : Self.estimateCapWithoutMarkers
            let fraction = min(cap, Double(sourceSample) / Double(playback.scheduledSourceFrames))
            let estimate = Int(Double(segment.speechLength) * fraction)
            callbacks.onProgress(segment.id, estimate, estimate, false)
        }
    }

    private func stopSharedPlayback() {
        sharedPlaybackGeneration += 1
        sharedQueue = []
        sharedPlayback = nil
        sharedProgressTimer?.invalidate()
        sharedProgressTimer = nil
        isSharedPlaybackPaused = false
        guard audioEngineHub != nil else { return }
        bufferWritingSynthesizer.stopSpeaking(at: .immediate)
        sharedPlayerChannel?.stop()
    }

    /// The hub stopped (hands-free ended): the current segment ends here
    /// and anything still queued is spoken the normal way.
    private func sharedEngineDidStop() {
        guard sharedPlayback != nil || !sharedQueue.isEmpty else { return }
        moveSharedSegmentsToSynthesizer(includingCurrent: false)
    }

    private func moveSharedSegmentsToSynthesizer(includingCurrent: Bool) {
        let unplayedCurrent = includingCurrent ? sharedPlayback?.segment : nil
        let interruptedPlayback = includingCurrent ? nil : sharedPlayback
        let remainingSegments = sharedQueue
        usesSharedEngineForAnswer = false
        sharedPlaybackGeneration += 1
        sharedQueue = []
        sharedPlayback = nil
        sharedProgressTimer?.invalidate()
        sharedProgressTimer = nil
        bufferWritingSynthesizer.stopSpeaking(at: .immediate)
        sharedPlayerChannel?.stop()
        if let interruptedPlayback {
            if !interruptedPlayback.hasStarted { callbacks.onSegmentStart(interruptedPlayback.segment.id) }
            callbacks.onSegmentEnd(interruptedPlayback.segment.id)
        }
        for segment in [unplayedCurrent].compactMap({ $0 }) + remainingSegments {
            enqueue(segment)
        }
        reportAllPlayedIfDone()
    }

    // MARK: - Off-main-thread write callbacks

    /// Built nonisolated: the synthesizer calls these on its own queue.
    /// They hop to the main queue in order (buffers must stay in order).
    private nonisolated static func makeBufferCallback(appleSpeechEngine: AppleSpeechEngine, playbackGeneration: Int) -> AVSpeechSynthesizer.BufferCallback {
        return { [weak appleSpeechEngine] audioBuffer in
            guard let appleSpeechEngine else { return }
            let box = AudioBufferBox(audioBuffer: audioBuffer, appleSpeechEngine: appleSpeechEngine)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.appleSpeechEngine.sharedSynthesizerDidWrite(box.audioBuffer, playbackGeneration: playbackGeneration) }
            }
        }
    }

    private nonisolated static func makeMarkerCallback(appleSpeechEngine: AppleSpeechEngine, playbackGeneration: Int) -> AVSpeechSynthesizer.MarkerCallback {
        return { [weak appleSpeechEngine] speechMarkers in
            guard let appleSpeechEngine else { return }
            let wordMarkers = speechMarkers.filter { $0.mark == .word }.map {
                WordMarkerValues(byteSampleOffset: $0.byteSampleOffset, utf16Location: $0.textRange.location, utf16Length: $0.textRange.length)
            }
            guard !wordMarkers.isEmpty else { return }
            let box = EngineBox(appleSpeechEngine: appleSpeechEngine)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.appleSpeechEngine.sharedSynthesizerDidMark(wordMarkers, playbackGeneration: playbackGeneration) }
            }
        }
    }
}

/// One AVSpeechSynthesisMarker's plain values (it isn't Sendable).
nonisolated struct WordMarkerValues: Sendable {
    let byteSampleOffset: Int
    let utf16Location: Int
    let utf16Length: Int
}

/// One segment being written and played on the shared engine.
@MainActor
private final class SharedUtterancePlayback {
    let segment: CaptionSegment
    let generation: Int
    var wordMarkerTimeline = SpeechWordMarkerTimeline()
    /// Markers that arrived before the buffer format (bytes per frame) was known.
    var pendingWordMarkers: [WordMarkerValues] = []
    var sourceSampleRate: Double = 0
    var bytesPerFrame = 0
    var scheduledBufferCount = 0
    var playedBufferCount = 0
    var scheduledSourceFrames = 0
    var hasFinishedSynthesis = false
    var hasStarted = false

    init(segment: CaptionSegment, generation: Int) {
        self.segment = segment
        self.generation = generation
    }

    func applyPendingWordMarkers() {
        for wordMarker in pendingWordMarkers {
            wordMarkerTimeline.addWordMarker(byteSampleOffset: wordMarker.byteSampleOffset, bytesPerFrame: bytesPerFrame,
                                             utf16Location: wordMarker.utf16Location, utf16Length: wordMarker.utf16Length)
        }
        pendingWordMarkers = []
    }
}

/// Carries a synthesizer buffer to the main queue (used only there).
private nonisolated struct AudioBufferBox: @unchecked Sendable {
    let audioBuffer: AVAudioBuffer
    let appleSpeechEngine: AppleSpeechEngine
}

private nonisolated struct EngineBox: @unchecked Sendable {
    let appleSpeechEngine: AppleSpeechEngine
}

extension AppleSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let box = UtteranceBox(utterance: utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.didStart(box.utterance) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let box = UtteranceBox(utterance: utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.willSpeak(characterRange, of: box.utterance) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let box = UtteranceBox(utterance: utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.didFinish(box.utterance) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let box = UtteranceBox(utterance: utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.didCancel(box.utterance) } }
    }
}

/// Carries an utterance from the synthesizer's thread to the main queue
/// (it's only compared by identity there).
private struct UtteranceBox: @unchecked Sendable {
    let utterance: AVSpeechUtterance
}
