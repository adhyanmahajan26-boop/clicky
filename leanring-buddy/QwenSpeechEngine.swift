//
//  QwenSpeechEngine.swift
//  leanring-buddy
//
//  The Qwen voice as a SpeechEngine: a thin wrapper over QwenLocalTTSClient
//  (one WAV per caption segment) and the AVAudioPlayer it plays through.
//  mlx-serve doesn't stream audio, so the router cuts the first segment
//  early (NarrationSegmenter.Options.qwen) and the engine synthesizes
//  QwenTuning.lookahead (= 1) segment ahead of the one playing: a cancelled
//  request still keeps the server busy, so asking further ahead only
//  delays the next answer.
//
//  Qwen gives no word timestamps, so progress comes from WordTiming on the
//  ORIGINAL caption words (the server got the lexicon text): the WAV's real
//  duration and silences spread the words; the clock is the player's
//  currentTime (media time, so it stays right at any v2.voice.rate) plus
//  v2.caption.avOffsetMs. A POINT's "lead" progress looks 250 ms ahead.
//  Runaway audio (over 3x its estimate) stops at its last pause.
//
//  One voice per answer: a slow segment is waited for (the watchdog is
//  generous), never handed to another voice. Only a real failure (server
//  gone, refused, watchdog exceeded, unplayable audio) hands the failed
//  segment and the REST of the answer to the Mac voice (restOfAnswer: true)
//  and the supervisor checks the server.
//
//  stopNow: epoch++, cancel every task, clear the queue, stop the player.
//  Every async continuation checks the epoch it started in.
//
//  P6.4 "aec": while the AudioEngineHub's voice processing is on (decided
//  per answer), the WAV becomes one AVAudioPCMBuffer on the hub's player
//  node instead (rate via its time pitch, bypassed at 1); the clock is the
//  player node's sample time, still driving WordTiming.
//

import AVFoundation
import ClickyCore
import Foundation

@MainActor
final class QwenSpeechEngine: SpeechEngine {
    let name = "qwen"
    var callbacks = SpeechEngineCallbacks()

    private let client: QwenLocalTTSClient
    private let supervisor: QwenServerSupervisor
    private let audioEngineHub: AudioEngineHub?
    private lazy var sharedPlayerChannel: SharedEnginePlayerChannel? = {
        guard let audioEngineHub else { return nil }
        let playerChannel = audioEngineHub.makePlayerChannel()
        playerChannel.onSharedEngineStopped = { [weak self] in self?.sharedEngineDidStop() }
        return playerChannel
    }()
    private static let pointLeadSeconds: TimeInterval = 0.25

    private struct Prepared {
        let segment: CaptionSegment
        var audioTask: Task<Data, Error>?
    }

    /// Engine-local; never reset, so a stale continuation can't match a new answer.
    private var epoch = 0
    private var queue: [Prepared] = []
    private var currentSegment: CaptionSegment?
    private var currentPlayer: AVAudioPlayer?
    private var currentWordTimes: WordTimes?
    /// Media time at which runaway audio is cut (nil = play to the end).
    private var currentStopTime: TimeInterval?
    private var progressTimer: Timer?
    private var hasEndedAnswer = false
    private var isPaused = false
    private var isStartingNext = false

    /// This answer plays through the hub's shared engine (AEC on at its start).
    private var usesSharedEngineForAnswer = false
    /// The current segment is on the shared player node (not an AVAudioPlayer).
    private var isSharedPlaybackActive = false
    private var currentSharedAudioDuration: TimeInterval = 0
    private var currentSharedPlaybackRate: Double = 1
    /// Bumped whenever shared playback ends, so a late "played back" is ignored.
    private var sharedPlaybackGeneration = 0

    init(client: QwenLocalTTSClient, supervisor: QwenServerSupervisor, audioEngineHub: AudioEngineHub? = nil) {
        self.client = client
        self.supervisor = supervisor
        self.audioEngineHub = audioEngineHub
    }

    var isPlaying: Bool { currentPlayer?.isPlaying == true || isSharedPlaybackActive || !queue.isEmpty || isStartingNext }

    func begin(epoch: Int) {
        stopNow()
        hasEndedAnswer = false
        usesSharedEngineForAnswer = audioEngineHub?.isVoiceProcessingActive == true
    }

    func enqueue(_ segment: CaptionSegment) {
        queue.append(Prepared(segment: segment, audioTask: nil))
        prefetch()
        startNextIfIdle()
    }

    func endOfAnswer() {
        hasEndedAnswer = true
        reportAllPlayedIfDone()
    }

    func stopNow() {
        epoch += 1
        for prepared in queue { prepared.audioTask?.cancel() }
        queue = []
        progressTimer?.invalidate()
        progressTimer = nil
        currentPlayer?.stop()
        currentPlayer = nil
        if isSharedPlaybackActive { sharedPlayerChannel?.stop() }
        isSharedPlaybackActive = false
        sharedPlaybackGeneration += 1
        currentSegment = nil
        currentWordTimes = nil
        currentStopTime = nil
        isStartingNext = false
        isPaused = false
    }

    func pause() {
        isPaused = true
        currentPlayer?.pause()
        if isSharedPlaybackActive { sharedPlayerChannel?.pause() }
    }

    func resume() {
        isPaused = false
        currentPlayer?.play()
        if isSharedPlaybackActive { sharedPlayerChannel?.resume() }
        startNextIfIdle()
    }

    // MARK: - Pipeline

    /// Synthesis for the next segment(s) to play: QwenTuning.lookahead of them.
    private func prefetch() {
        for queueIndex in queue.indices.prefix(QwenTuning.lookahead) where queue[queueIndex].audioTask == nil {
            queue[queueIndex].audioTask = makeAudioTask(for: queue[queueIndex].segment.speech)
        }
    }

    private func makeAudioTask(for speech: String) -> Task<Data, Error> {
        let client = client
        let supervisor = supervisor
        return Task { @MainActor in
            // A server still starting gets as long as one request would.
            guard await supervisor.waitUntilReady(timeoutSeconds: QwenTuning.watchdogSeconds(characters: speech.count)) else {
                throw QwenLocalTTSError(message: supervisor.status)
            }
            return try await client.synthesizeSpeech(for: speech)
        }
    }

    private func startNextIfIdle() {
        guard currentSegment == nil, !isStartingNext, !isPaused, let next = queue.first else { return }
        isStartingNext = true
        let startEpoch = epoch
        let audioTask = next.audioTask ?? makeAudioTask(for: next.segment.speech)
        Task { @MainActor [weak self] in
            let result: Result<Data, Error>
            do { result = .success(try await audioTask.value) } catch { result = .failure(error) }
            guard let self, self.epoch == startEpoch else { return }
            self.isStartingNext = false
            if !self.queue.isEmpty { self.queue.removeFirst() }
            switch result {
            case .success(let audioData):
                self.prefetch()
                self.play(next.segment, audioData: audioData)
            case .failure(let error):
                self.fail(error, failedSegment: next.segment)
            }
        }
    }

    private func play(_ segment: CaptionSegment, audioData: Data) {
        if usesSharedEngineForAnswer, audioEngineHub?.isVoiceProcessingActive == true,
           playThroughSharedEngine(segment, audioData: audioData) {
            return
        }
        do {
            let player = try AVAudioPlayer(data: audioData)
            // Rate must be enabled before prepareToPlay.
            player.enableRate = true
            player.prepareToPlay()
            player.rate = Float(ClickySettings.voiceRate)
            var stopTime: TimeInterval?
            currentWordTimes = PCMAudio(wavData: audioData).map { decodedAudio in
                var spokenAudio = decodedAudio
                if let cutTime = WordTiming.overrunCutTime(decodedAudio, characters: segment.speechLength) {
                    print("✂️ Qwen audio ran \(String(format: "%.1f", decodedAudio.duration)) s for \(segment.speechLength) chars; cut at \(String(format: "%.2f", cutTime)) s")
                    stopTime = cutTime
                    spokenAudio = decodedAudio.prefix(seconds: cutTime)
                }
                return WordTiming.wordTimes(speech: segment.speech, wordRanges: segment.wordRanges, audio: spokenAudio)
            }
            currentStopTime = stopTime
            currentPlayer = player
            currentSegment = segment
            player.play()
            callbacks.onSegmentStart(segment.id)
            startProgressTimer()
        } catch {
            fail(error, failedSegment: segment)
        }
    }

    /// "aec": the WAV as one buffer on the shared engine's player node.
    /// False (nothing started) if it can't be decoded or scheduled; the
    /// AVAudioPlayer path then plays it.
    private func playThroughSharedEngine(_ segment: CaptionSegment, audioData: Data) -> Bool {
        guard let sharedPlayerChannel, let decodedAudio = PCMAudio(wavData: audioData) else { return false }
        var spokenAudio = decodedAudio
        if let cutTime = WordTiming.overrunCutTime(decodedAudio, characters: segment.speechLength) {
            print("✂️ Qwen audio ran \(String(format: "%.1f", decodedAudio.duration)) s for \(segment.speechLength) chars; cut at \(String(format: "%.2f", cutTime)) s")
            spokenAudio = decodedAudio.prefix(seconds: cutTime)
        }
        guard let audioBuffer = Self.makePCMBuffer(from: spokenAudio) else { return false }
        let playbackRate = ClickySettings.voiceRate
        sharedPlaybackGeneration += 1
        let playbackGeneration = sharedPlaybackGeneration
        sharedPlayerChannel.startSegment(rate: playbackRate)
        let isScheduled = sharedPlayerChannel.schedule(audioBuffer) { [weak self] in
            guard let self, self.sharedPlaybackGeneration == playbackGeneration else { return }
            self.finishCurrentSegment()
        }
        guard isScheduled else { return false }
        currentWordTimes = WordTiming.wordTimes(speech: segment.speech, wordRanges: segment.wordRanges, audio: spokenAudio)
        currentStopTime = nil
        currentSharedAudioDuration = spokenAudio.duration
        currentSharedPlaybackRate = playbackRate
        isSharedPlaybackActive = true
        currentSegment = segment
        callbacks.onSegmentStart(segment.id)
        startProgressTimer()
        return true
    }

    private static func makePCMBuffer(from audio: PCMAudio) -> AVAudioPCMBuffer? {
        guard !audio.samples.isEmpty,
              let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
              let audioBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(audio.samples.count)),
              let channelSamples = audioBuffer.floatChannelData?[0] else { return nil }
        audio.samples.withUnsafeBufferPointer { samplePointer in
            guard let sampleBaseAddress = samplePointer.baseAddress else { return }
            channelSamples.update(from: sampleBaseAddress, count: audio.samples.count)
        }
        audioBuffer.frameLength = AVAudioFrameCount(audio.samples.count)
        return audioBuffer
    }

    /// The hub stopped under us (hands-free ended): this segment is over;
    /// later ones play through AVAudioPlayer.
    private func sharedEngineDidStop() {
        guard isSharedPlaybackActive else { return }
        finishCurrentSegment()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func reportProgress() {
        guard let segment = currentSegment else { return }
        let mediaTime: TimeInterval
        let mediaDuration: TimeInterval
        let playbackRate: Double
        if isSharedPlaybackActive {
            guard let sharedPlayerChannel, sharedPlayerChannel.isEngineRunning else {
                finishCurrentSegment()
                return
            }
            // The player node's sample time is media time too (before the time pitch).
            mediaTime = min(sharedPlayerChannel.playedSeconds, currentSharedAudioDuration)
            mediaDuration = currentSharedAudioDuration
            playbackRate = currentSharedPlaybackRate
        } else {
            guard let player = currentPlayer else { return }
            if let currentStopTime, player.currentTime >= currentStopTime {
                player.stop()
                finishCurrentSegment()
                return
            }
            if !player.isPlaying && !isPaused {
                finishCurrentSegment()
                return
            }
            mediaTime = player.currentTime
            mediaDuration = player.duration
            playbackRate = Double(player.rate)
        }
        // Media time: captions stay on the words at any rate.
        let clock = mediaTime + ClickySettings.captionAVOffsetMilliseconds / 1000
        let total = segment.speechLength
        let leadSeconds = Self.pointLeadSeconds * playbackRate
        if let wordTimes = currentWordTimes {
            let spoken = wordTimes.spokenCharacters(at: clock, wordRanges: segment.wordRanges, totalCharacters: total)
            let leadSpoken = wordTimes.spokenCharacters(at: clock + leadSeconds, wordRanges: segment.wordRanges, totalCharacters: total)
            callbacks.onProgress(segment.id, spoken, leadSpoken, false)
        } else if mediaDuration > 0 {
            // No parsable WAV: proportional estimate.
            let fraction = min(1, clock / mediaDuration)
            callbacks.onProgress(segment.id, Int(Double(total) * fraction), Int(Double(total) * min(1, (clock + leadSeconds) / mediaDuration)), false)
        }
    }

    private func finishCurrentSegment() {
        guard let segment = currentSegment else { return }
        progressTimer?.invalidate()
        progressTimer = nil
        currentPlayer = nil
        isSharedPlaybackActive = false
        sharedPlaybackGeneration += 1
        currentSegment = nil
        currentWordTimes = nil
        currentStopTime = nil
        callbacks.onSegmentEnd(segment.id)
        startNextIfIdle()
        reportAllPlayedIfDone()
    }

    private func reportAllPlayedIfDone() {
        guard hasEndedAnswer, queue.isEmpty, currentSegment == nil, !isStartingNext else { return }
        callbacks.onAllPlayed()
    }

    /// Hands `failedSegment` (already off the queue) and everything queued
    /// back: the rest of this answer is spoken by the Mac voice, so voices
    /// never alternate within an answer.
    private func fail(_ error: Error, failedSegment: CaptionSegment) {
        print("⚠️ Qwen voice failed, the Mac voice speaks the rest of this answer: \(error.localizedDescription)")
        let failEpoch = epoch
        let unspoken = [failedSegment] + queue.map(\.segment)
        for prepared in queue { prepared.audioTask?.cancel() }
        queue = []
        if error is URLError || error is QwenLocalTTSError || error is QwenSlowSynthesisError {
            supervisor.serverMayHaveDied()
        }
        callbacks.onFailure(unspoken, true)
        // The coordinator may have stopped us (taking the queue back).
        guard epoch == failEpoch else { return }
        prefetch()
        startNextIfIdle()
        reportAllPlayedIfDone()
    }
}
