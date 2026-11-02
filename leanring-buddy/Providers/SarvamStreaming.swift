//
//  SarvamStreaming.swift
//  leanring-buddy
//
//  Sarvam's live sockets for voice calls, written against docs.sarvam.ai as read on 2026-11-02:
//   - Text to speech: wss://api.sarvam.ai/text-to-speech/ws. A config message, then text and flush messages; audio comes
//     back in base64 chunks. There's no cancel: to cut it off, close the socket and open a new one.
//   - Speech to text, realtime (beta, has partial words): wss://api.sarvam.ai/speech-to-text-realtime/ws.
//   - Speech to text, standard (finals only): wss://api.sarvam.ai/speech-to-text/ws. Used when realtime is refused.
//
//  The messages are built and read by SarvamWire, which has no network in it and is covered by SarvamClientTests. The key
//  goes in the Api-Subscription-Key header, only to Sarvam.
//

import Foundation

enum SarvamWire {
    // MARK: Addresses

    /// wss://… for the REST base address.
    private static func socketBase() -> String {
        SarvamClient.baseURL.absoluteString.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func ttsURL(model: String = "bulbul:v4-flash") -> URL? {
        var parts = URLComponents(string: socketBase() + "/text-to-speech/ws")
        parts?.queryItems = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "send_completion_event", value: "true")]
        return parts?.url
    }

    static func realtimeSTTURL(languageCode: String = "auto", mode: String = "codemix", model: String = "saaras:v3-realtime") -> URL? {
        var parts = URLComponents(string: socketBase() + "/speech-to-text-realtime/ws")
        parts?.queryItems = [URLQueryItem(name: "language_code", value: languageCode), URLQueryItem(name: "model", value: model),
                             URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "stream_type", value: "fast"),
                             URLQueryItem(name: "endpointing", value: "vad"), URLQueryItem(name: "encoding", value: "linear16"),
                             URLQueryItem(name: "sample_rate", value: "16000")]
        return parts?.url
    }

    static func standardSTTURL(languageCode: String = "unknown", mode: String = "codemix", model: String = "saaras:v4") -> URL? {
        var parts = URLComponents(string: socketBase() + "/speech-to-text/ws")
        parts?.queryItems = [URLQueryItem(name: "language-code", value: languageCode), URLQueryItem(name: "model", value: model),
                             URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "sample_rate", value: "16000"),
                             URLQueryItem(name: "input_audio_codec", value: "pcm_s16le"), URLQueryItem(name: "vad_signals", value: "true"),
                             URLQueryItem(name: "flush_signal", value: "true")]
        return parts?.url
    }

    static func socketRequest(_ url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Subscription-Key")
        return request
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Text to speech

    /// `codec`: linear16 for raw samples, or mp3, which the socket's description says is its only format today.
    static func ttsConfig(speaker: String, languageCode: String, pace: Double, codec: String, sampleRate: Int = 24000) -> String {
        json(["type": "config", "data": [
            "speaker": speaker, "language_code": languageCode, "pace": SarvamClient.clampPace(pace),
            "min_buffer_size": 30, "max_chunk_length": 200, "output_audio_codec": codec, "speech_sample_rate": sampleRate,
        ] as [String: Any]])
    }

    static func ttsText(_ text: String) -> String { json(["type": "text", "data": ["text": text]]) }
    static let ttsFlush = #"{"type":"flush"}"#
    static let ttsPing = #"{"type":"ping"}"#

    enum TTSEvent: Equatable {
        case audio(Data, contentType: String)
        case final
        case error(String)
        case other
    }

    static func parseTTS(_ text: String) -> TTSEvent {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return .other }
        let body = object["data"] as? [String: Any]
        switch object["type"] as? String {
        case "audio":
            guard let encoded = body?["audio"] as? String, let audio = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { return .other }
            return .audio(audio, contentType: body?["content_type"] as? String ?? "")
        case "event":
            return body?["event_type"] as? String == "final" ? .final : .other
        case "error":
            return .error(body?["message"] as? String ?? "Sarvam's voice reported an error.")
        default:
            return .other
        }
    }

    // MARK: Speech to text

    static func realtimeAudio(_ pcm: Data) -> String { json(["event": "audio_input", "audio": pcm.base64EncodedString()]) }
    static let realtimeEnd = #"{"event":"end"}"#

    static func standardAudio(_ pcm: Data) -> String {
        json(["audio": ["data": pcm.base64EncodedString(), "sample_rate": 16000, "encoding": "audio/wav"] as [String: Any]])
    }
    static let standardFlush = #"{"type":"flush"}"#

    enum STTEvent: Equatable {
        case began
        case partial(String)
        case final(String, language: String?)
        case speechStarted
        case speechEnded
        case error(String, fatal: Bool)
        case other
    }

    static func parseRealtimeSTT(_ text: String) -> STTEvent {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return .other }
        switch object["event"] as? String {
        case "session.begin": return .began
        case "transcript.partial": return .partial(object["text"] as? String ?? "")
        case "transcript.final": return .final(object["text"] as? String ?? "", language: object["language"] as? String)
        case "vad.speech_start": return .speechStarted
        case "vad.speech_end": return .speechEnded
        case "error": return .error(object["message"] as? String ?? "Sarvam's listening reported an error.", fatal: object["is_fatal"] as? Bool ?? true)
        default: return .other
        }
    }

    static func parseStandardSTT(_ text: String) -> STTEvent {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return .other }
        let body = object["data"] as? [String: Any]
        switch object["type"] as? String {
        case "data": return .final(body?["transcript"] as? String ?? "", language: body?["language_code"] as? String)
        case "events":
            switch body?["signal_type"] as? String {
            case "START_SPEECH": return .speechStarted
            case "END_SPEECH": return .speechEnded
            default: return .other
            }
        case "error": return .error(body?["error"] as? String ?? "Sarvam's listening reported an error.", fatal: true)
        default: return .other
        }
    }
}

/// One live socket, with its text messages delivered on the main actor.
@MainActor
final class SarvamSocket {
    private let task: URLSessionWebSocketTask
    private var isOpen = true
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    var onText: ((String) -> Void)?
    var onClose: ((String?) -> Void)?

    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
    }

    func open(pingMessage: String? = nil) {
        task.resume()
        receiveLoop = Task { @MainActor [weak self, task] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text): self?.onText?(text)
                    case .data(let data): self?.onText?(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                } catch {
                    self?.closedByPeer(error.localizedDescription)
                    return
                }
            }
        }
        if let pingMessage {
            // An idle socket closes after about a minute.
            pingLoop = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.send(pingMessage)
                }
            }
        }
    }

    func send(_ text: String) {
        guard isOpen else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            let reason = error.localizedDescription
            Task { @MainActor in self?.closedByPeer(reason) }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        receiveLoop?.cancel()
        pingLoop?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func closedByPeer(_ reason: String?) {
        guard isOpen else { return }
        isOpen = false
        pingLoop?.cancel()
        onClose?(reason)
    }
}
