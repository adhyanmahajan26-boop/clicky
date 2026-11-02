//
//  ElevenLabsClient.swift
//  leanring-buddy
//
//  ElevenLabs text-to-speech over HTTP with the owner's key: POST /v1/text-to-speech/{voice} (header xi-api-key) and
//  GET /v2/voices. Audio comes back as MP3, one file per caption segment.
//

import Foundation

enum ElevenLabsClient {
    static let voiceKey = "v2.voice.elevenlabs.voice"
    static let modelKey = "v2.voice.elevenlabs.model"
    static let defaultModel = "eleven_flash_v2_5"
    static let baseURL = "https://api.elevenlabs.io"

    struct Voice: Identifiable, Equatable {
        let id: String
        let name: String
    }

    enum ClientError: LocalizedError {
        case noKey, noVoice, failed(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "No ElevenLabs key saved."
            case .noVoice: return "Pick an ElevenLabs voice in Settings › Voice."
            case .failed(let message): return "ElevenLabs: \(message)"
            }
        }
    }

    static var isActive: Bool { UserDefaults.standard.string(forKey: SarvamVoiceSettings_Keys.engine) == "elevenlabs" && ProviderKeychain.get("elevenlabs") != nil }

    /// Pure, so it can be tested without the network.
    static func speechRequest(key: String, voice: String, model: String, text: String) -> URLRequest? {
        guard let url = URL(string: "\(baseURL)/v1/text-to-speech/\(voice)?output_format=mp3_44100_128") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": model])
        return request
    }

    /// `voice` nil uses the picked one.
    static func synthesize(_ text: String, voice pickedVoice: String? = nil) async throws -> Data {
        guard let key = ProviderKeychain.get("elevenlabs") else { throw ClientError.noKey }
        guard let voice = pickedVoice ?? UserDefaults.standard.string(forKey: voiceKey), !voice.isEmpty else { throw ClientError.noVoice }
        let model = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
        guard let request = speechRequest(key: key, voice: voice, model: model, text: text) else { throw ClientError.noVoice }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let failure = ProviderInfo.testFailure(statusCode: status, body: data) { throw ClientError.failed(failure) }
        return data
    }

    static func listVoices() async throws -> [Voice] {
        guard let key = ProviderKeychain.get("elevenlabs") else { throw ClientError.noKey }
        guard let url = URL(string: "\(baseURL)/v2/voices?page_size=100") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let failure = ProviderInfo.testFailure(statusCode: status, body: data) { throw ClientError.failed(failure) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["voices"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["voice_id"] as? String, let name = entry["name"] as? String else { return nil }
            return Voice(id: id, name: name)
        }
    }
}
