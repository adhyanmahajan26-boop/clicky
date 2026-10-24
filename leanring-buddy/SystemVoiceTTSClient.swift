//
//  SystemVoiceTTSClient.swift
//  leanring-buddy
//
//  Speaks responses with the Mac's built-in voices via AVSpeechSynthesizer.
//  Free, offline, and needs no API key — replaces ElevenLabs as the default
//  in this personal build. Mirrors ElevenLabsTTSClient's surface
//  (speakText / isPlaying / stopPlayback) so callers can swap between them.
//

import AVFoundation
import Foundation

@MainActor
final class SystemVoiceTTSClient {
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// The best-sounding installed English voice. Premium and enhanced voices
    /// sound far more natural than the compact default, so prefer those when
    /// the user has downloaded them in System Settings > Accessibility > Spoken Content.
    private lazy var preferredVoice: AVSpeechSynthesisVoice? = {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let currentLanguageCode = AVSpeechSynthesisVoice.currentLanguageCode()

        func bestVoice(withQuality voiceQuality: AVSpeechSynthesisVoiceQuality) -> AVSpeechSynthesisVoice? {
            let voicesOfQuality = englishVoices.filter { $0.quality == voiceQuality }
            return voicesOfQuality.first(where: { $0.language == currentLanguageCode }) ?? voicesOfQuality.first
        }

        return bestVoice(withQuality: .premium)
            ?? bestVoice(withQuality: .enhanced)
            ?? AVSpeechSynthesisVoice(language: currentLanguageCode)
    }()

    /// Starts speaking `text` and returns once speech has begun, matching
    /// ElevenLabsTTSClient which returns right after playback starts.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()

        let speechUtterance = AVSpeechUtterance(string: text)
        speechUtterance.voice = preferredVoice
        speechUtterance.rate = AVSpeechUtteranceDefaultSpeechRate

        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(speechUtterance)
        print("🔊 System voice TTS: speaking \(text.count) characters with \(preferredVoice?.name ?? "default voice")")
    }

    /// Whether speech is currently playing back.
    var isPlaying: Bool {
        speechSynthesizer.isSpeaking
    }

    /// Stops any in-progress speech immediately.
    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
    }
}
