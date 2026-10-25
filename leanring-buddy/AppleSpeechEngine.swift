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
//  actually finishes.
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

    init(voiceProvider: @escaping () -> AVSpeechSynthesisVoice?) {
        self.voiceProvider = voiceProvider
        super.init()
        synthesizer.delegate = self
    }

    var isPlaying: Bool { synthesizer.isSpeaking || !pending.isEmpty }

    func begin(epoch: Int) {
        stopNow()
        hasEndedAnswer = false
    }

    func enqueue(_ segment: CaptionSegment) {
        let utterance = AVSpeechUtterance(string: segment.speech)
        utterance.voice = voiceProvider()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Self.rateMultiplier
        pending.append((utterance, segment))
        synthesizer.speak(utterance)
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
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }

    private var voiceKey: String {
        "\(voiceProvider()?.identifier ?? "default")|\(Self.rateMultiplier)"
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
        guard hasEndedAnswer, pending.isEmpty, current == nil else { return }
        callbacks.onAllPlayed()
    }
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
