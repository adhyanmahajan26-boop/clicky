//
//  QwenLocalTTSClient.swift
//  leanring-buddy
//
//  Speaks with Qwen3-TTS running locally through MLX Core's `mlx-serve`
//  (http://127.0.0.1:11234/v1/audio/speech). Free, offline, and far more
//  natural than the built-in Mac voices.
//
//  - This client only turns one caption segment into WAV audio. Running
//    the server (adopt / spawn / never kill) is QwenServerSupervisor's job;
//    Clicky leaves a server it started running when it quits.
//  - The request carries the loaded model, the lexicon-respelled text, a
//    fixed speaker + instruct, English, WAV, and a token cap (the probe in
//    docs/v2/EVAL.md showed the server accepts every key).
//  - Every request has a watchdog (1.0 + 0.6 x chars/15 s): a slow answer
//    throws QwenSlowSynthesisError, so only that segment falls back.
//  - Same text always gives the same voice (the model is deterministic), so
//    segments stitched together sound like one speaker.
//

import AVFoundation
import ClickyCore
import Foundation

/// The server is gone or refused: the rest of the answer goes to the Mac voice.
struct QwenLocalTTSError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One request took longer than its watchdog: only that segment falls back.
struct QwenSlowSynthesisError: LocalizedError {
    let watchdogSeconds: TimeInterval
    var errorDescription: String? { String(format: "Qwen took over %.1f s for one segment", watchdogSeconds) }
}

@MainActor
final class QwenLocalTTSClient {
    static let mlxServeExecutableURL = URL(fileURLWithPath: QwenTuning.mlxServeExecutablePath)

    /// True when MLX Core is installed, i.e. this voice can work at all.
    static var isAvailableOnThisMac: Bool {
        FileManager.default.isExecutableFile(atPath: mlxServeExecutableURL.path)
    }

    /// 11234, or the debug override (v2.debug.ttsPortOverride).
    static var serverPort: Int { ClickySettings.ttsPortOverride ?? QwenTuning.serverPort }
    static var serverBaseURL: URL { URL(string: "http://\(QwenTuning.serverHost):\(serverPort)")! }

    private let urlSession: URLSession
    /// The TTS model the server has loaded (set by the supervisor).
    var loadedModelIdentifier = QwenTuning.defaultModelIdentifier

    /// The one voice every segment clones (v2.voice.qwen.referenceClip), read
    /// once and kept as base64; nil when the clip is missing.
    private(set) lazy var referenceClipBase64: String? = {
        let path = (ClickySettings.qwenReferenceClipPath as NSString).expandingTildeInPath
        guard let clipData = FileManager.default.contents(atPath: path), PCMAudio(wavData: clipData) != nil else {
            print("⚠️ Qwen voice: no reference clip at \(path); each answer may sound different")
            return nil
        }
        return clipData.base64EncodedString()
    }()

    /// Base (cloning the reference clip) whenever a clip exists.
    var modelIdentifier: String {
        QwenTuning.modelIdentifier(hasReferenceClip: referenceClipBase64 != nil, loadedModelIdentifier: loadedModelIdentifier)
    }

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// The exact request for one segment (also checked by the hosted tests).
    func makeSpeechRequest(for speech: String) throws -> URLRequest {
        var speechRequest = URLRequest(url: Self.serverBaseURL.appendingPathComponent("v1/audio/speech"))
        speechRequest.httpMethod = "POST"
        speechRequest.timeoutInterval = 60
        speechRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        speechRequest.httpBody = try JSONSerialization.data(withJSONObject: QwenTuning.requestBody(
            model: modelIdentifier,
            speech: speech,
            referenceClipBase64: referenceClipBase64
        ), options: [.sortedKeys])
        return speechRequest
    }

    /// WAV audio for one caption segment, or QwenSlowSynthesisError after the watchdog.
    func synthesizeSpeech(for speech: String, watchdogSeconds: TimeInterval? = nil) async throws -> Data {
        let speechRequest = try makeSpeechRequest(for: speech)
        let watchdog = watchdogSeconds ?? QwenTuning.watchdogSeconds(characters: speech.count)
        let urlSession = urlSession
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (responseData, response) = try await urlSession.data(for: speechRequest)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, !responseData.isEmpty else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw QwenLocalTTSError(message: "Qwen voice server answered with status \(statusCode)")
                }
                return responseData
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(watchdog * 1_000_000_000))
                throw QwenSlowSynthesisError(watchdogSeconds: watchdog)
            }
            defer { group.cancelAll() }
            guard let audioData = try await group.next() else { throw CancellationError() }
            return audioData
        }
    }

    /// GET /v1/models: the `data` array, or nil if nothing answers.
    func fetchModels(timeoutSeconds: TimeInterval = 1.5) async -> [[String: Any]]? {
        var modelsRequest = URLRequest(url: Self.serverBaseURL.appendingPathComponent("v1/models"))
        modelsRequest.timeoutInterval = timeoutSeconds
        guard let (modelsData, response) = try? await urlSession.data(for: modelsRequest),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let modelsObject = try? JSONSerialization.jsonObject(with: modelsData) as? [String: Any]
        return modelsObject?["data"] as? [[String: Any]] ?? []
    }
}
