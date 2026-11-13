//
//  SarvamClient.swift
//  leanring-buddy
//
//  Sarvam AI REST client (https://api.sarvam.ai, header api-subscription-key):
//  text-to-speech (Bulbul), speech-to-text (Saaras), translate, chat.
//  Written against the docs as of 2026-11 (docs.sarvam.ai). Not exercised
//  against the live API yet (no key): request building and response parsing
//  are pure static functions covered by SarvamClientTests.
//
//  Doc notes:
//   - TTS body uses "language_code" per the current reference (older SDKs
//     said "target_language_code"); on a 400/422 naming the field the call
//     is retried once with the other spelling.
//   - bulbul:v4-flash speakers are persona ids like shubh_hi_devotional; the
//     v3 short names ("shubh") are only valid for bulbul:v3. resolveSpeaker
//     maps a short name to a v4 persona for the chosen language.
//   - REST speech-to-text is meant for audio under 30 s (use Batch beyond).
//   - TTS text limit: 2500 characters (v3, v4-flash).
//

import Foundation

enum SarvamError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidRequest(String)
    case unauthorized(String)
    case rateLimited(String)
    case server(Int, String)
    case badResponse(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No Sarvam API key saved"
        case .invalidRequest(let m): return "Sarvam rejected the request: \(m)"
        case .unauthorized(let m): return "Sarvam key rejected: \(m)"
        case .rateLimited(let m): return "Sarvam rate limit or quota: \(m)"
        case .server(let c, let m): return "Sarvam server error \(c): \(m)"
        case .badResponse(let m): return "Unexpected Sarvam response: \(m)"
        case .transport(let m): return "Network error: \(m)"
        }
    }
}

struct SarvamClient {
    /// The test profile can point at a local stand-in server (Tools/mock-sarvam.py). Real runs always go to Sarvam.
    static var baseURL: URL {
        if TheoProfile.isTest, let local = UserDefaults.standard.string(forKey: "test.sarvam.base"), let url = URL(string: local) { return url }
        return URL(string: "https://api.sarvam.ai")!
    }

    /// Sockets and REST share an address at Sarvam; the stand-in server keeps REST one port up.
    static var restBaseURL: URL {
        if TheoProfile.isTest, let local = UserDefaults.standard.string(forKey: "test.sarvam.base"), var parts = URLComponents(string: local), let port = parts.port {
            parts.port = port + 1
            return parts.url ?? baseURL
        }
        return baseURL
    }
    static let maxTTSCharacters = 2500
    static let restSTTMaxSeconds = 30

    enum STTMode: String { case transcribe, translate, verbatim, translit, codemix }

    var apiKey: String
    var session: URLSession = .shared

    /// A client using the Keychain key, or nil.
    static func fromKeychain() -> SarvamClient? {
        ProviderKeychain.get("sarvam").map { SarvamClient(apiKey: $0) }
    }

    // MARK: - Pure helpers

    /// Display language setting -> (language_code, preferred speaker tag).
    /// "hinglish" speaks code-mixed text with an enhi voice under hi-IN.
    static func languageParameters(forSetting setting: String) -> (code: String, tag: String) {
        switch setting.lowercased() {
        case "en-in", "en": return ("en-IN", "en")
        case "hinglish", "enhi", "hi-en": return ("hi-IN", "enhi")
        case "hi-in", "hi": return ("hi-IN", "hi")
        default:
            let tag = String(setting.prefix(2)).lowercased()
            return (setting, tag)
        }
    }

    /// bulbul:v3 short names are invalid on v4; map "shubh" to e.g. shubh_hi_conversational-like personas.
    static func resolveSpeaker(_ speaker: String, model: String, languageSetting: String) -> String {
        guard model.hasPrefix("bulbul:v4") else { return speaker }
        if speaker.contains("_") { return speaker }
        let tag = languageParameters(forSetting: languageSetting).tag
        let defaults: [String: String] = [
            "hi": "\(speaker)_hi_customer", "en": "\(speaker)_en_narration", "enhi": "\(speaker)_enhi_companion"
        ]
        let candidate = defaults[tag] ?? "shubh_enhi_ads"
        return knownV4Speakers.contains(candidate) ? candidate : "shubh_enhi_ads"
    }

    static let knownV4Speakers: Set<String> = Set(v4VoiceGroups.flatMap(\.speakers))

    static let v3Speakers = ["shubh", "aditya", "ritu", "priya", "neha", "rahul", "pooja", "rohan", "simran", "kavya", "amit", "dev", "ishita", "shreya", "ratan", "varun", "manan", "sumit", "roopa", "kabir", "aayan", "ashutosh", "advait", "anand", "tanya", "tarun", "sunny", "mani", "gokul", "vijay", "shruti", "suhani", "mohit", "kavitha", "rehan", "soham", "rupali"]

    static func clampPace(_ pace: Double) -> Double { min(2.0, max(0.5, pace)) }

    static func authedRequest(_ path: String, apiKey: String, contentType: String? = "application/json") -> URLRequest {
        var request = URLRequest(url: restBaseURL.appendingPathComponent(path), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }

    static func makeTTSRequest(apiKey: String, text: String, languageSetting: String, speaker: String,
                               model: String, pace: Double, languageFieldName: String = "language_code") throws -> URLRequest {
        let trimmed = String(text.prefix(maxTTSCharacters))
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SarvamError.invalidRequest("empty text")
        }
        let language = languageParameters(forSetting: languageSetting)
        let body: [String: Any] = [
            "text": trimmed,
            languageFieldName: language.code,
            "speaker": resolveSpeaker(speaker, model: model, languageSetting: languageSetting),
            "model": model,
            "pace": clampPace(pace),
            "output_audio_codec": "wav"
        ]
        var request = authedRequest("text-to-speech", apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func makeTranslateRequest(apiKey: String, input: String, source: String, target: String,
                                     model: String = "mayura:v1", mode: String = "formal") -> URLRequest? {
        let body: [String: Any] = ["input": input, "source_language_code": source, "target_language_code": target, "model": model, "mode": mode]
        var request = authedRequest("translate", apiKey: apiKey)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func makeChatRequest(apiKey: String, messages: [[String: String]], model: String = "sarvam-105b",
                                temperature: Double = 0.2, maxTokens: Int = 2048) -> URLRequest? {
        let body: [String: Any] = ["model": model, "messages": messages, "temperature": temperature, "max_tokens": maxTokens, "stream": false]
        var request = authedRequest("v1/chat/completions", apiKey: apiKey)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Multipart body for POST /speech-to-text.
    static func makeSTTRequest(apiKey: String, audio: Data, fileName: String = "audio.wav", mimeType: String = "audio/wav",
                               model: String = "saaras:v4", mode: STTMode? = .transcribe, languageCode: String = "unknown", keyterms: [String] = [],
                               boundary: String = "TheoBoundary-\(UUID().uuidString)") -> URLRequest {
        var request = authedRequest("speech-to-text", apiKey: apiKey, contentType: "multipart/form-data; boundary=\(boundary)")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n".utf8))
        field("model", model)
        // The model page says v3 and v4 take `mode`, the REST field says v3 only; `transcribe` calls fall back without it on a 400.
        if let mode { field("mode", mode.rawValue) }
        field("language_code", languageCode)
        // saaras:v4 only: words to expect, up to 50 of up to 64 characters.
        if model == "saaras:v4", !keyterms.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: Array(keyterms.map { String($0.prefix(64)) }.prefix(50))), let json = String(data: data, encoding: .utf8) {
            field("keyterms", json)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        request.timeoutInterval = 60
        return request
    }

    // MARK: - Response parsing

    /// Decodes audios[] (base64 WAV) into Data blobs.
    static func parseTTSResponse(_ data: Data) throws -> [Data] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audios = object["audios"] as? [String], !audios.isEmpty else {
            throw SarvamError.badResponse("no audios in response")
        }
        return try audios.map { encoded in
            guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !decoded.isEmpty else {
                throw SarvamError.badResponse("audio was not valid base64")
            }
            return decoded
        }
    }

    static func parseSTTResponse(_ data: Data) throws -> (transcript: String, languageCode: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcript = object["transcript"] as? String else {
            throw SarvamError.badResponse("no transcript in response")
        }
        return (transcript, object["language_code"] as? String)
    }

    static func parseTranslateResponse(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["translated_text"] as? String else {
            throw SarvamError.badResponse("no translated_text in response")
        }
        return text
    }

    static func parseChatResponse(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SarvamError.badResponse("no choices[0].message.content")
        }
        return content
    }

    /// {"error": {"message": ..., "code": ...}} or {"detail": ...}.
    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        if let detail = object["detail"] as? String { return detail }
        if let message = object["message"] as? String { return message }
        return nil
    }

    static func error(statusCode: Int, body: Data) -> SarvamError {
        let message = errorMessage(from: body) ?? String(data: body.prefix(160), encoding: .utf8) ?? ""
        switch statusCode {
        case 400, 422: return .invalidRequest(message)
        case 401, 403: return .unauthorized(message)
        case 429: return .rateLimited(message)
        default: return .server(statusCode, message)
        }
    }

    // MARK: - Network

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw Self.error(statusCode: status, body: data) }
            return data
        } catch let error as SarvamError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw SarvamError.transport(error.localizedDescription)
        }
    }

    /// One WAV for `text`.
    func synthesize(text: String, languageSetting: String, speaker: String, model: String, pace: Double) async throws -> Data {
        let request = try Self.makeTTSRequest(apiKey: apiKey, text: text, languageSetting: languageSetting, speaker: speaker, model: model, pace: pace)
        do {
            return try Self.parseTTSResponse(try await send(request)).first!
        } catch SarvamError.invalidRequest(let message) where message.contains("language_code") {
            let alternate = try Self.makeTTSRequest(apiKey: apiKey, text: text, languageSetting: languageSetting, speaker: speaker, model: model, pace: pace, languageFieldName: "target_language_code")
            return try Self.parseTTSResponse(try await send(alternate)).first!
        }
    }

    /// One WAV for `text`, over Sarvam's socket. REST took 2.8 to 21 s for a line here, and the socket about half a second.
    func synthesizeOverSocket(text: String, languageSetting: String, speaker: String, model: String, pace: Double, timeout: TimeInterval = 8) async throws -> Data {
        guard let url = SarvamWire.ttsURL(model: model) else { throw SarvamError.badResponse("Bad address") }
        let parameters = Self.languageParameters(forSetting: languageSetting)
        let task = session.webSocketTask(with: SarvamWire.socketRequest(url, apiKey: apiKey))
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let rate = 24000
        try await task.send(.string(SarvamWire.ttsConfig(speaker: Self.resolveSpeaker(speaker, model: model, languageSetting: languageSetting),
                                                         languageCode: parameters.code, pace: pace, codec: "linear16", sampleRate: rate)))
        try await task.send(.string(SarvamWire.ttsText(text)))
        try await task.send(.string(SarvamWire.ttsFlush))
        let deadline = Task { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); task.cancel(with: .goingAway, reason: nil) }
        defer { deadline.cancel() }
        var samples = Data()
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch { throw SarvamError.transport(error.localizedDescription) }
            guard case .string(let body) = message else { continue }
            switch SarvamWire.parseTTS(body) {
            case .audio(let audio, _): samples.append(audio)
            case .final:
                guard !samples.isEmpty else { throw SarvamError.badResponse("No audio") }
                return Self.wav(pcm16: samples, sampleRate: rate)
            case .error(let problem): throw SarvamError.badResponse(problem)
            case .other: continue
            }
        }
    }

    /// A WAV header around mono 16-bit samples.
    static func wav(pcm16 samples: Data, sampleRate: Int) -> Data {
        func little<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var file = Data("RIFF".utf8) + little(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8) + little(UInt32(16)) + little(UInt16(1)) + little(UInt16(1))
        file += little(UInt32(sampleRate)) + little(UInt32(sampleRate * 2)) + little(UInt16(2)) + little(UInt16(16)) + Data("data".utf8) + little(UInt32(samples.count))
        return file + samples
    }

    /// Audio should be under 30 s on the REST endpoint.
    func transcribe(audio: Data, fileName: String = "audio.wav", mimeType: String = "audio/wav",
                    model: String = "saaras:v4", mode: STTMode = .transcribe, languageCode: String = "unknown", keyterms: [String] = []) async throws -> (transcript: String, languageCode: String?) {
        let request = Self.makeSTTRequest(apiKey: apiKey, audio: audio, fileName: fileName, mimeType: mimeType, model: model, mode: mode, languageCode: languageCode, keyterms: keyterms)
        do {
            return try Self.parseSTTResponse(try await send(request))
        } catch SarvamError.invalidRequest(let message) where message.lowercased().contains("mode") {
            // The docs disagree on whether this model takes `mode`: once more without it.
            let plain = Self.makeSTTRequest(apiKey: apiKey, audio: audio, fileName: fileName, mimeType: mimeType, model: model, mode: nil, languageCode: languageCode, keyterms: keyterms)
            return try Self.parseSTTResponse(try await send(plain))
        }
    }

    func translate(_ input: String, from source: String = "auto", to target: String, model: String = "mayura:v1", mode: String = "formal") async throws -> String {
        guard let request = Self.makeTranslateRequest(apiKey: apiKey, input: input, source: source, target: target, model: model, mode: mode) else {
            throw SarvamError.invalidRequest("could not build request")
        }
        return try Self.parseTranslateResponse(try await send(request))
    }

    func chat(messages: [[String: String]], model: String = "sarvam-105b") async throws -> String {
        guard let request = Self.makeChatRequest(apiKey: apiKey, messages: messages, model: model) else {
            throw SarvamError.invalidRequest("could not build request")
        }
        return try Self.parseChatResponse(try await send(request))
    }
}
