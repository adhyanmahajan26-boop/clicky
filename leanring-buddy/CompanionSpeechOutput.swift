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

import ClickyCore
import Combine
import Foundation

@MainActor
final class CompanionSpeechOutput: ObservableObject {
    let systemVoiceClient = SystemVoiceTTSClient()
    let qwenLocalVoiceClient = QwenLocalTTSClient()
    private(set) lazy var qwenEngine = QwenSpeechEngine(client: qwenLocalVoiceClient)
    private(set) lazy var appleEngine = AppleSpeechEngine { [weak self] in self?.systemVoiceClient.voiceInUse }
    /// A second Mac-voice engine: the fallback behind Apple-as-primary.
    private(set) lazy var appleFallbackEngine = AppleSpeechEngine { [weak self] in self?.systemVoiceClient.voiceInUse }

    private static let usesQwenLocalVoiceUserDefaultsKey = "usesQwenLocalVoice"
    static let voicePreviewSentence = "Hey, I'm Clicky. This is how I'll sound when I answer you."

    /// Qwen is the default whenever MLX Core is installed.
    @Published private(set) var usesQwenLocalVoice: Bool =
        QwenLocalTTSClient.isAvailableOnThisMac
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

    /// A coordinator for one answer: the selected voice, the Mac voice behind it.
    func makeCoordinator(host: SpeechCoordinatorHost) -> SpeechCoordinator {
        activeCoordinator?.bargeIn(.newQuestion)
        let primary: SpeechEngine = usesQwenLocalVoice ? qwenEngine : appleEngine
        let fallback: SpeechEngine = usesQwenLocalVoice ? appleEngine : appleFallbackEngine
        let coordinator = SpeechCoordinator(primaryEngine: primary, fallbackEngine: fallback, host: host)
        activeCoordinator = coordinator
        return coordinator
    }

    /// Notes which voice spoke (for turn.json).
    func recordFinished(_ coordinator: SpeechCoordinator) {
        lastCoordinatorEngineName = coordinator.spokenEngineName
        lastCoordinatorUsedFallback = coordinator.didUseFallback
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
        usesQwenLocalVoice ? "qwen" : "system"
    }

    var isPlaying: Bool {
        qwenEngine.isPlaying || appleEngine.isPlaying || appleFallbackEngine.isPlaying
    }

    func stopPlayback() {
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
        Task {
            await qwenLocalVoiceClient.warmUp()
        }
    }

    func shutDown() {
        stopPlayback()
        qwenLocalVoiceClient.stopServerIfStartedByClicky()
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
