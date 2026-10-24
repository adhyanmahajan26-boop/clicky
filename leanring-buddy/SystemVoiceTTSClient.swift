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
import Combine
import Foundation

@MainActor
final class SystemVoiceTTSClient: ObservableObject {
    private let speechSynthesizer = AVSpeechSynthesizer()

    private static let selectedVoiceIdentifierUserDefaultsKey = "selectedSpeechVoiceIdentifier"

    /// The voice the user picked in the panel, or nil to pick automatically.
    @Published private(set) var selectedVoiceIdentifier: String? =
        UserDefaults.standard.string(forKey: SystemVoiceTTSClient.selectedVoiceIdentifierUserDefaultsKey)

    /// English voices worth offering: no novelty voices (Bells, Bubbles…),
    /// no Eloquence voices (Eddy, Grandma…) and no pre-2010 voices (Fred,
    /// Ralph…), which all sound robotic. Best quality first.
    static func selectableEnglishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                voice.language.hasPrefix("en")
                    && !voice.voiceTraits.contains(.isNoveltyVoice)
                    && !voice.identifier.contains(".eloquence.")
                    && !voice.identifier.hasPrefix("com.apple.speech.synthesis.voice.")
            }
            .sorted { firstVoice, secondVoice in
                if firstVoice.quality != secondVoice.quality {
                    return firstVoice.quality.rawValue > secondVoice.quality.rawValue
                }
                return firstVoice.name < secondVoice.name
            }
    }

    /// True when only compact voices are installed, so the panel can point
    /// the user to System Settings to download a Premium one.
    static var hasHighQualityVoiceInstalled: Bool {
        selectableEnglishVoices().contains { $0.quality == .premium || $0.quality == .enhanced }
    }

    /// The user's pick if it's still installed, otherwise the best voice:
    /// Premium, then Enhanced, then default quality, preferring the user's
    /// own English variant (en-US, en-GB, en-IN…).
    var voiceInUse: AVSpeechSynthesisVoice? {
        if let selectedVoiceIdentifier,
           let selectedVoice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
            return selectedVoice
        }
        return Self.automaticallyChosenVoice()
    }

    static func automaticallyChosenVoice() -> AVSpeechSynthesisVoice? {
        let selectableVoices = selectableEnglishVoices()
        let currentLanguageCode = AVSpeechSynthesisVoice.currentLanguageCode()

        for voiceQuality in [AVSpeechSynthesisVoiceQuality.premium, .enhanced, .default] {
            let voicesOfQuality = selectableVoices.filter { $0.quality == voiceQuality }
            if let voiceInUsersLanguage = voicesOfQuality.first(where: { $0.language == currentLanguageCode }) {
                return voiceInUsersLanguage
            }
            // Among compact voices, Samantha is the least robotic US voice.
            if voiceQuality == .default, let samanthaVoice = voicesOfQuality.first(where: { $0.name == "Samantha" }) {
                return samanthaVoice
            }
            if let anyVoiceOfQuality = voicesOfQuality.first {
                return anyVoiceOfQuality
            }
        }
        return AVSpeechSynthesisVoice(language: currentLanguageCode)
    }

    /// Remembers the user's pick; nil goes back to choosing automatically.
    func selectVoice(identifier voiceIdentifier: String?) {
        selectedVoiceIdentifier = voiceIdentifier
        UserDefaults.standard.set(voiceIdentifier, forKey: Self.selectedVoiceIdentifierUserDefaultsKey)
    }

    /// Starts speaking `text` and returns once speech has begun, matching
    /// ElevenLabsTTSClient which returns right after playback starts.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        try speakTextImmediately(text)
    }

    private func speakTextImmediately(_ text: String) throws {
        let speechUtterance = AVSpeechUtterance(string: text)
        let currentVoice = voiceInUse
        speechUtterance.voice = currentVoice
        // The default rate is a touch fast for long answers; this is closer
        // to a person explaining something.
        speechUtterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95

        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(speechUtterance)
        print("🔊 System voice TTS: speaking \(text.count) characters with \(currentVoice?.name ?? "default voice")")
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
