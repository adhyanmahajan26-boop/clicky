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

import AVFoundation
import ClickyCore
import Foundation

@MainActor
final class QwenSpeechEngine: SpeechEngine {
    let name = "qwen"
    var callbacks = SpeechEngineCallbacks()

    private let client: QwenLocalTTSClient
    private let supervisor: QwenServerSupervisor
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

    init(client: QwenLocalTTSClient, supervisor: QwenServerSupervisor) {
        self.client = client
        self.supervisor = supervisor
    }

    var isPlaying: Bool { currentPlayer?.isPlaying == true || !queue.isEmpty || isStartingNext }

    func begin(epoch: Int) {
        stopNow()
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
        currentStopTime = nil
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
            progressTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportProgress() }
            }
            RunLoop.main.add(timer, forMode: .common)
            progressTimer = timer
        } catch {
            fail(error, failedSegment: segment)
        }
    }

    private func reportProgress() {
        guard let player = currentPlayer, let segment = currentSegment else { return }
        if let currentStopTime, player.currentTime >= currentStopTime {
            player.stop()
            finishCurrentSegment()
            return
        }
        if !player.isPlaying && !isPaused {
            finishCurrentSegment()
            return
        }
        // currentTime is media time: captions stay on the words at any rate.
        let clock = player.currentTime + ClickySettings.captionAVOffsetMilliseconds / 1000
        let total = segment.speechLength
        let leadSeconds = Self.pointLeadSeconds * Double(player.rate)
        if let wordTimes = currentWordTimes {
            let spoken = wordTimes.spokenCharacters(at: clock, wordRanges: segment.wordRanges, totalCharacters: total)
            let leadSpoken = wordTimes.spokenCharacters(at: clock + leadSeconds, wordRanges: segment.wordRanges, totalCharacters: total)
            callbacks.onProgress(segment.id, spoken, leadSpoken, false)
        } else if player.duration > 0 {
            // No parsable WAV: proportional estimate.
            let fraction = min(1, clock / player.duration)
            callbacks.onProgress(segment.id, Int(Double(total) * fraction), Int(Double(total) * min(1, (clock + leadSeconds) / player.duration)), false)
        }
    }

    private func finishCurrentSegment() {
        guard let segment = currentSegment else { return }
        progressTimer?.invalidate()
        progressTimer = nil
        currentPlayer = nil
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
