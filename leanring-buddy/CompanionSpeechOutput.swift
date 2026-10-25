//
//  CompanionSpeechOutput.swift
//  leanring-buddy
//
//  The one speech output CompanionManager talks to. It speaks with the local
//  Qwen voice when it's selected and available, and falls back to the built-in
//  Mac voice whenever Qwen can't answer (MLX Core missing, server down), so
//  Clicky never goes silent.
//

import Combine
import Foundation

@MainActor
final class CompanionSpeechOutput: ObservableObject {
    let systemVoiceClient = SystemVoiceTTSClient()
    let qwenLocalVoiceClient = QwenLocalTTSClient()

    private static let usesQwenLocalVoiceUserDefaultsKey = "usesQwenLocalVoice"
    static let voicePreviewSentence = "Hey, I'm Clicky. This is how I'll sound when I answer you."

    /// Qwen is the default whenever MLX Core is installed.
    @Published private(set) var usesQwenLocalVoice: Bool =
        QwenLocalTTSClient.isAvailableOnThisMac
            && (UserDefaults.standard.object(forKey: CompanionSpeechOutput.usesQwenLocalVoiceUserDefaultsKey) as? Bool ?? true)

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
    private(set) var lastSpeechEngineName: String?
    private(set) var didLastSpeechFallBack = false

    func speakText(_ text: String) async throws {
        didLastSpeechFallBack = false
        if usesQwenLocalVoice {
            do {
                try await qwenLocalVoiceClient.speakText(text)
                lastSpeechEngineName = "qwen"
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("⚠️ Qwen voice unavailable, using the Mac voice: \(error.localizedDescription)")
                didLastSpeechFallBack = true
            }
        }
        try await systemVoiceClient.speakText(text)
        lastSpeechEngineName = "system"
    }

    /// The engine a new answer would use right now, for the debug ping.
    var currentEngineName: String {
        usesQwenLocalVoice ? "qwen" : "system"
    }

    var isPlaying: Bool {
        qwenLocalVoiceClient.isPlaying || systemVoiceClient.isPlaying
    }

    func stopPlayback() {
        qwenLocalVoiceClient.stopPlayback()
        systemVoiceClient.stopPlayback()
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
