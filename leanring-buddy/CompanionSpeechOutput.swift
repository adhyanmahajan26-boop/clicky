//
//  CompanionSpeechOutput.swift
//  leanring-buddy
//
//  Owns Clicky's voices (the local Qwen voice and the built-in Mac voice,
//  each a SpeechEngine) and hands out a SpeechCoordinator per answer with
//  the selected voice first and the Mac voice as its fallback, so Clicky
//  never goes silent. Short one-off lines (errors, hands-free status, voice
//  preview) go through the same path via speakText.
//
//  Qwen is the primary only while its supervisor hasn't ruled the server
//  out. Clicky's mlx-serve keeps running after quit (the next launch
//  adopts it). The echo tail (isPlayingOrEchoTail) keeps the mic's words
//  counted as Clicky's own until output latency + 0.25 s after the audio.
//
//  P6.4: owns the AudioEngineHub the hands-free mic shares with the voices
//  in "aec" echo mode (each voice gets its own player node on it).
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class CompanionSpeechOutput: ObservableObject {
    let systemVoiceClient = SystemVoiceTTSClient()
    let qwenLocalVoiceClient = QwenLocalTTSClient()
    /// The mic + voices engine for "aec" (idle unless hands-free runs with AEC on).
    let audioEngineHub = AudioEngineHub()
    private(set) lazy var qwenServerSupervisor = QwenServerSupervisor(client: qwenLocalVoiceClient)
    private(set) lazy var qwenEngine = QwenSpeechEngine(client: qwenLocalVoiceClient, supervisor: qwenServerSupervisor, audioEngineHub: audioEngineHub)
    private(set) lazy var appleEngine = AppleSpeechEngine(voiceProvider: { [weak self] in self?.systemVoiceClient.voiceInUse }, audioEngineHub: audioEngineHub)
    /// A second Mac-voice engine: the fallback behind Apple-as-primary.
    private(set) lazy var appleFallbackEngine = AppleSpeechEngine(voiceProvider: { [weak self] in self?.systemVoiceClient.voiceInUse }, audioEngineHub: audioEngineHub)

    private static let usesQwenLocalVoiceUserDefaultsKey = "usesQwenLocalVoice"
    static let voicePreviewSentence = "Hey, I'm Claudia. This is how I'll sound when I answer you."

    /// Qwen is the default whenever MLX Core is installed.
    @Published private(set) var usesQwenLocalVoice: Bool =
        QwenLocalTTSClient.isAvailable
            && (UserDefaults.standard.object(forKey: CompanionSpeechOutput.usesQwenLocalVoiceUserDefaultsKey) as? Bool ?? true)

    /// The coordinator currently speaking (an answer or a one-off line).
    private(set) weak var activeCoordinator: SpeechCoordinator?
    private var standaloneHosts: [StandaloneSpeechHost] = []

    func selectQwenLocalVoice() {
        usesQwenLocalVoice = true
        UserDefaults.standard.set(true, forKey: Self.usesQwenLocalVoiceUserDefaultsKey)
        warmUpIfNeeded()
    }

    /// nil picks the best installed Mac voice automatically.
    func selectSystemVoice(identifier voiceIdentifier: String?) {
        stopPlayback()
        usesQwenLocalVoice = false
        UserDefaults.standard.set(false, forKey: Self.usesQwenLocalVoiceUserDefaultsKey)
        systemVoiceClient.selectVoice(identifier: voiceIdentifier)
    }

    /// Which engine spoke the most recent answer ("qwen" or "system"), and
    /// whether that was a fallback from Qwen. Read by the turn logger.
    var lastSpeechEngineName: String? { lastCoordinatorEngineName }
    var didLastSpeechFallBack: Bool { lastCoordinatorUsedFallback }
    private var lastCoordinatorEngineName: String?
    private var lastCoordinatorUsedFallback = false

    /// Qwen speaks the next answer (selected, and its server not ruled out).
    var isQwenPrimary: Bool {
        usesQwenLocalVoice && !qwenServerSupervisor.isUnavailable
    }

    /// Qwen's first WAV only arrives whole, so its first segment is cut early.
    var narrationSegmenterOptions: NarrationSegmenter.Options {
        isQwenPrimary ? .qwen : NarrationSegmenter.Options()
    }

    /// A coordinator for one answer: the selected voice, the Mac voice behind it.
    private let readingPaceEngine = ReadingPaceSpeechEngine()
    /// A second one: the coordinator gives primary and fallback their own callbacks.
    private let readingPaceFallbackEngine = ReadingPaceSpeechEngine()

    func makeCoordinator(host: SpeechCoordinatorHost) -> SpeechCoordinator {
        activeCoordinator?.bargeIn(.newQuestion)
        let usesQwen = isQwenPrimary
        var primary: SpeechEngine = usesQwen ? qwenEngine : appleEngine
        var fallback: SpeechEngine = usesQwen ? appleEngine : appleFallbackEngine
        // Silent mode: nothing is spoken, but captions, marks and board steps
        // keep the rhythm of a spoken answer (paced at reading speed).
        if ClickySettings.isSilentModeEnabled {
            primary = readingPaceEngine
            fallback = readingPaceFallbackEngine
        }
        let coordinator = SpeechCoordinator(primaryEngine: primary, fallbackEngine: fallback, host: host)
        activeCoordinator = coordinator
        return coordinator
    }

    /// Notes which voice spoke (for turn.json) and starts the echo tail.
    func recordFinished(_ coordinator: SpeechCoordinator) {
        lastCoordinatorEngineName = coordinator.spokenEngineName
        lastCoordinatorUsedFallback = coordinator.didUseFallback
        lastSpeechEndDate = Date()
        lastFinishedEchoGuard = coordinator.echoGuard
    }

    /// When Clicky last stopped talking (the wake word waits 1.5 s after it).
    private(set) var lastSpeechEndDate: Date?
    /// The last finished answer's spoken words (its coordinator may be gone already).
    private var lastFinishedEchoGuard = EchoGuard()

    /// Every word Clicky said in the EchoGuard window (4 s) before `date`:
    /// the wake word ignores a name the mic may have heard from the speaker.
    func recentSpokenWords(at date: Date) -> Set<String> {
        let activeWords = activeCoordinator?.echoGuard.recentSpokenWords(at: date) ?? []
        return activeWords.union(lastFinishedEchoGuard.recentSpokenWords(at: date))
    }

    /// Speaking, or within the echo tail after it (output latency + 0.25 s):
    /// what the mic hears now is still likely Clicky's own voice.
    var isPlayingOrEchoTail: Bool {
        if isPlaying { return true }
        guard let lastSpeechEndDate else { return false }
        return Date().timeIntervalSince(lastSpeechEndDate) < QwenTuning.echoTailSeconds
    }

    /// Speaks a one-off line (no tags). Returns once it's queued.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        let host = StandaloneSpeechHost()
        standaloneHosts.append(host)
        let coordinator = makeCoordinator(host: host)
        host.onFinished = { [weak self, weak coordinator, weak host] in
            guard let self else { return }
            if let coordinator { self.recordFinished(coordinator) }
            self.standaloneHosts.removeAll { $0 === host }
        }
        host.coordinator = coordinator
        coordinator.beginAnswer()
        coordinator.enqueue(CaptionParser.parse(text, id: 1, firstTagIndex: 0))
        coordinator.streamDidFinish(spawnedWorkers: false)
    }

    /// The engine a new answer would use right now, for the debug ping.
    var currentEngineName: String {
        isQwenPrimary ? "qwen" : "system"
    }

    var isPlaying: Bool {
        qwenEngine.isPlaying || appleEngine.isPlaying || appleFallbackEngine.isPlaying
    }

    /// Silences every voice at once (push-to-talk key-down, before the barge-in).
    func stopVoicesNow() {
        if isPlaying { lastSpeechEndDate = Date() }
        qwenEngine.stopNow()
        appleEngine.stopNow()
        appleFallbackEngine.stopNow()
    }

    func stopPlayback() {
        if isPlaying { lastSpeechEndDate = Date() }
        activeCoordinator?.bargeIn(.newQuestion)
        qwenEngine.stopNow()
        appleEngine.stopNow()
        appleFallbackEngine.stopNow()
    }

    func previewVoice() {
        Task {
            try? await speakText(Self.voicePreviewSentence)
        }
    }

    /// Loads the Qwen model in the background at launch so the first answer
    /// doesn't wait for it.
    func warmUpIfNeeded() {
        guard usesQwenLocalVoice else { return }
        qwenServerSupervisor.start()
    }

    /// Stops the voices. A server Clicky started stays up for the next launch.
    func shutDown() {
        stopPlayback()
    }

    /// One step slower or faster for both voices (v2.voice.rate); returns the new rate.
    @discardableResult
    func stepVoiceRate(faster: Bool) -> Double {
        let newRate = QwenTuning.steppedRate(from: ClickySettings.voiceRate, faster: faster)
        ClickySettings.voiceRate = newRate
        return newRate
    }
}

/// Host for one-off lines: no tags, no history, no bubble.
@MainActor
private final class StandaloneSpeechHost: SpeechCoordinatorHost {
    weak var coordinator: SpeechCoordinator?
    var onFinished: (() -> Void)?

    func cancelClaudeAndWorkers() {}
    func fireTag(index: Int) {}
    func dropUnfiredTags(_ tagIndexes: [Int]) {}
    func captionDidChange(_ caption: CaptionState) {}
    func answerDidFinish(historyText: String, wasInterrupted: Bool) { onFinished?() }
    func speakApology(_ text: String) {}
    func log(_ event: String) {}
}
