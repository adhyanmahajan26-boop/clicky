//
//  QwenSpeechEngine.swift
//  leanring-buddy
//
//  The Qwen voice as a SpeechEngine: a thin wrapper over QwenLocalTTSClient
//  (the mlx-serve server and its synthesis call) and the AVAudioPlayer it
//  already played through. Each caption segment is synthesized as soon as
//  it's queued, one segment ahead of playback, so the first words play
//  while Claude is still writing the rest.
//
//  Qwen gives no word timestamps, so progress comes from WordTiming: the
//  WAV's real duration and silences spread the words; the clock is the
//  player's currentTime plus v2.caption.avOffsetMs. A POINT's "lead"
//  progress looks 250 ms ahead so the companion arrives with the word.
//  If synthesis fails, the unspoken segments go back to the coordinator
//  (onFailure), which hands them to the Apple voice.
//

import AVFoundation
import ClickyCore
import Foundation

@MainActor
final class QwenSpeechEngine: SpeechEngine {
    let name = "qwen"
    var callbacks = SpeechEngineCallbacks()

    private let client: QwenLocalTTSClient
    private static let pointLeadSeconds: TimeInterval = 0.25

    private struct Prepared {
        let segment: CaptionSegment
        var audioTask: Task<Data, Error>?
    }

    private var epoch = 0
    private var queue: [Prepared] = []
    private var currentSegment: CaptionSegment?
    private var currentPlayer: AVAudioPlayer?
    private var currentWordTimes: WordTimes?
    private var progressTimer: Timer?
    private var hasEndedAnswer = false
    private var isPaused = false
    private var isStartingNext = false

    init(client: QwenLocalTTSClient) {
        self.client = client
    }

    var isPlaying: Bool { currentPlayer?.isPlaying == true || !queue.isEmpty || isStartingNext }

    func begin(epoch: Int) {
        stopNow()
        self.epoch = epoch
        hasEndedAnswer = false
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
        currentSegment = nil
        currentWordTimes = nil
        isStartingNext = false
        isPaused = false
    }

    func pause() {
        isPaused = true
        currentPlayer?.pause()
    }

    func resume() {
        isPaused = false
        currentPlayer?.play()
        startNextIfIdle()
    }

    // MARK: - Pipeline

    /// Synthesis for the next segment to play and the one after it.
    private func prefetch() {
        for queueIndex in queue.indices.prefix(2) where queue[queueIndex].audioTask == nil {
            let text = queue[queueIndex].segment.speech
            let client = client
            queue[queueIndex].audioTask = Task { @MainActor in
                try await client.ensureServerIsRunning()
                return try await client.synthesizeSpeech(for: text)
            }
        }
    }

    private func startNextIfIdle() {
        guard currentSegment == nil, !isStartingNext, !isPaused, let next = queue.first else { return }
        isStartingNext = true
        let startEpoch = epoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            let audioData: Data
            do {
                audioData = try await (next.audioTask ?? Task { try await self.client.synthesizeSpeech(for: next.segment.speech) }).value
            } catch {
                guard self.epoch == startEpoch else { return }
                self.isStartingNext = false
                self.fail(error)
                return
            }
            guard self.epoch == startEpoch else { return }
            self.isStartingNext = false
            self.queue.removeFirst()
            self.prefetch()
            self.play(next.segment, audioData: audioData)
        }
    }

    private func play(_ segment: CaptionSegment, audioData: Data) {
        do {
            let player = try AVAudioPlayer(data: audioData)
            currentPlayer = player
            currentSegment = segment
            currentWordTimes = PCMAudio(wavData: audioData).map {
                WordTiming.wordTimes(speech: segment.speech, wordRanges: segment.wordRanges, audio: $0)
            }
            player.play()
            callbacks.onSegmentStart(segment.id)
            progressTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportProgress() }
            }
            RunLoop.main.add(timer, forMode: .common)
            progressTimer = timer
        } catch {
            fail(error)
        }
    }

    private func reportProgress() {
        guard let player = currentPlayer, let segment = currentSegment else { return }
        if !player.isPlaying && !isPaused {
            finishCurrentSegment()
            return
        }
        let clock = player.currentTime + ClickySettings.captionAVOffsetMilliseconds / 1000
        let total = segment.speechLength
        if let wordTimes = currentWordTimes {
            let spoken = wordTimes.spokenCharacters(at: clock, wordRanges: segment.wordRanges, totalCharacters: total)
            let leadSpoken = wordTimes.spokenCharacters(at: clock + Self.pointLeadSeconds, wordRanges: segment.wordRanges, totalCharacters: total)
            callbacks.onProgress(segment.id, spoken, leadSpoken, false)
        } else if player.duration > 0 {
            // No parsable WAV: proportional estimate.
            let fraction = min(1, clock / player.duration)
            callbacks.onProgress(segment.id, Int(Double(total) * fraction), Int(Double(total) * min(1, (clock + Self.pointLeadSeconds) / player.duration)), false)
        }
    }

    private func finishCurrentSegment() {
        guard let segment = currentSegment else { return }
        progressTimer?.invalidate()
        progressTimer = nil
        currentPlayer = nil
        currentSegment = nil
        currentWordTimes = nil
        callbacks.onSegmentEnd(segment.id)
        startNextIfIdle()
        reportAllPlayedIfDone()
    }

    private func reportAllPlayedIfDone() {
        guard hasEndedAnswer, queue.isEmpty, currentSegment == nil, !isStartingNext else { return }
        callbacks.onAllPlayed()
    }

    /// Hands every unspoken segment back. A server that can't be reached
    /// loses the rest of the answer; a single bad response only that segment.
    private func fail(_ error: Error) {
        print("⚠️ Qwen voice failed, handing over to the Mac voice: \(error.localizedDescription)")
        let isServerGone = error is URLError || (error as? QwenLocalTTSError) != nil
        let unspoken: [CaptionSegment]
        if isServerGone {
            unspoken = queue.map(\.segment)
            for prepared in queue { prepared.audioTask?.cancel() }
            queue = []
        } else {
            unspoken = queue.isEmpty ? [] : [queue.removeFirst().segment]
            prefetch()
        }
        callbacks.onFailure(unspoken, isServerGone)
        startNextIfIdle()
        reportAllPlayedIfDone()
    }
}
