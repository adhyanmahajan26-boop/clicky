//
//  SarvamSpeechEngine.swift
//  leanring-buddy
//
//  Speaks caption segments through Sarvam Bulbul (REST, one WAV per segment)
//  and plays them with AVAudioPlayer. Same shape as QwenSpeechEngine: one
//  segment synthesized ahead, word progress spread over the WAV's real
//  duration (WordTiming), stopNow bumps an epoch so late results are dropped.
//  Any failure hands the failed segment and the rest of the answer to the
//  fallback voice (onFailure restOfAnswer: true).
//
//  Selected by UserDefaults "v2.voice.engine" == "sarvam" with a saved key
//  (see SarvamVoiceSettings.isActive). Settings: v2.voice.sarvam.speaker
//  (default "shubh"), .language ("hi-IN" | "en-IN" | "hinglish"), .model
//  (default "bulbul:v4-flash"), .pace (default 1.0).
//

import AVFoundation
import ClickyCore
import Foundation

enum SarvamVoiceSettings_Keys {
    static let engine = "v2.voice.engine"
    static let speaker = "v2.voice.sarvam.speaker"
    static let language = "v2.voice.sarvam.language"
    static let model = "v2.voice.sarvam.model"
    static let pace = "v2.voice.sarvam.pace"
}

/// Current Sarvam voice settings, read at call time.
enum SarvamVoiceConfig {
    static var isSelected: Bool { UserDefaults.standard.string(forKey: SarvamVoiceSettings_Keys.engine) == "sarvam" }
    static var isActive: Bool { isSelected && ProviderKeychain.get("sarvam") != nil }
    static var speaker: String { UserDefaults.standard.string(forKey: SarvamVoiceSettings_Keys.speaker) ?? "shubh" }
    static var language: String { UserDefaults.standard.string(forKey: SarvamVoiceSettings_Keys.language) ?? "hi-IN" }
    static var model: String { UserDefaults.standard.string(forKey: SarvamVoiceSettings_Keys.model) ?? "bulbul:v4-flash" }
    static var pace: Double {
        let stored = UserDefaults.standard.object(forKey: SarvamVoiceSettings_Keys.pace) as? Double ?? 1.0
        return SarvamClient.clampPace(stored)
    }
}

/// A voice in the cloud: one audio file per caption segment, played with AVAudioPlayer. Sarvam and ElevenLabs.
@MainActor
final class SarvamSpeechEngine: SpeechEngine {
    let name: String
    var callbacks = SpeechEngineCallbacks()
    private let synthesize: @Sendable (String) async throws -> Data

    /// Sarvam Bulbul by default.
    init(name: String = "sarvam", synthesize: (@Sendable (String) async throws -> Data)? = nil) {
        self.name = name
        self.synthesize = synthesize ?? { speech in
            let (language, speaker, model, pace) = await MainActor.run {
                (SarvamVoiceConfig.language, SarvamVoiceConfig.speaker, SarvamVoiceConfig.model, SarvamVoiceConfig.pace)
            }
            guard let client = SarvamClient.fromKeychain() else { throw SarvamError.missingKey }
            return try await client.synthesize(text: speech, languageSetting: language, speaker: speaker, model: model, pace: pace)
        }
    }

    private struct Prepared {
        let segment: CaptionSegment
        var audioTask: Task<Data, Error>?
    }

    private static let lookahead = 1
    private static let pointLeadSeconds: TimeInterval = 0.25

    private var epoch = 0
    private var queue: [Prepared] = []
    private var currentSegment: CaptionSegment?
    private var currentPlayer: AVAudioPlayer?
    private var currentWordTimes: WordTimes?
    private var progressTimer: Timer?
    private var hasEndedAnswer = false
    private var isPaused = false
    private var isStartingNext = false

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

    private func prefetch() {
        for index in queue.indices.prefix(Self.lookahead) where queue[index].audioTask == nil {
            queue[index].audioTask = makeAudioTask(for: queue[index].segment.speech)
        }
    }

    private func makeAudioTask(for speech: String) -> Task<Data, Error> {
        let synthesize = self.synthesize
        return Task { try await synthesize(speech) }
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
            player.enableRate = true
            player.prepareToPlay()
            player.rate = Float(ClickySettings.voiceRate)
            if CompanionSpeechOutput.isZeroVolumeForTests { player.volume = 0 }
            currentWordTimes = PCMAudio(wavData: audioData).map {
                WordTiming.wordTimes(speech: segment.speech, wordRanges: segment.wordRanges, audio: $0)
            }
            currentPlayer = player
            currentSegment = segment
            player.play()
            callbacks.onSegmentStart(segment.id)
            startProgressTimer()
        } catch {
            fail(error, failedSegment: segment)
        }
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
        guard let segment = currentSegment, let player = currentPlayer else { return }
        if !player.isPlaying && !isPaused {
            finishCurrentSegment()
            return
        }
        let clock = player.currentTime + ClickySettings.captionAVOffsetMilliseconds / 1000
        let total = segment.speechLength
        let lead = Self.pointLeadSeconds * Double(player.rate)
        if let wordTimes = currentWordTimes {
            let spoken = wordTimes.spokenCharacters(at: clock, wordRanges: segment.wordRanges, totalCharacters: total)
            let leadSpoken = wordTimes.spokenCharacters(at: clock + lead, wordRanges: segment.wordRanges, totalCharacters: total)
            callbacks.onProgress(segment.id, spoken, leadSpoken, false)
        } else if player.duration > 0 {
            let fraction = min(1, clock / player.duration)
            callbacks.onProgress(segment.id, Int(Double(total) * fraction), Int(Double(total) * min(1, (clock + lead) / player.duration)), false)
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

    private func fail(_ error: Error, failedSegment: CaptionSegment) {
        // Never log the key; SarvamError descriptions contain only server messages.
        print("\(name) voice failed, falling back for the rest of this answer: \(error.localizedDescription)")
        let failEpoch = epoch
        let unspoken = [failedSegment] + queue.map(\.segment)
        for prepared in queue { prepared.audioTask?.cancel() }
        queue = []
        callbacks.onFailure(unspoken, true)
        guard epoch == failEpoch else { return }
        prefetch()
        startNextIfIdle()
        reportAllPlayedIfDone()
    }
}
