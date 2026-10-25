//
//  QwenLocalTTSClient.swift
//  leanring-buddy
//
//  Speaks with Qwen3-TTS running locally through MLX Core's `mlx-serve`
//  (http://127.0.0.1:11234/v1/audio/speech). Free, offline, and far more
//  natural than the built-in Mac voices.
//
//  - If the server isn't running, Clicky starts it itself (bound to
//    127.0.0.1 only) and stops it again when Clicky quits.
//  - QwenSpeechEngine plays answers segment by segment (it synthesizes the
//    next segment while the current one plays); this client only runs the
//    server and turns text into WAV audio.
//  - Same text always gives the same voice (the model is deterministic), so
//    segments stitched together sound like one speaker.
//

import AVFoundation
import Foundation

struct QwenLocalTTSError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class QwenLocalTTSClient {
    static let serverBaseURL = URL(string: "http://127.0.0.1:11234")!
    static let speechModelIdentifier = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
    static let mlxServeExecutableURL = URL(fileURLWithPath: "/Applications/MLX Core.app/Contents/MacOS/mlx-serve")

    private static let serverStartupTimeoutSeconds: Double = 40

    /// True when MLX Core is installed, i.e. this voice can work at all.
    static var isAvailableOnThisMac: Bool {
        FileManager.default.isExecutableFile(atPath: mlxServeExecutableURL.path)
    }

    /// Only set when Clicky launched the server, so Clicky never kills a
    /// server the user started themselves.
    private var serverProcessStartedByClicky: Process?

    // MARK: - Server

    /// WAV audio for `spokenChunk` (one caption segment).
    func synthesizeSpeech(for spokenChunk: String) async throws -> Data {
        var speechRequest = URLRequest(url: Self.serverBaseURL.appendingPathComponent("v1/audio/speech"))
        speechRequest.httpMethod = "POST"
        speechRequest.timeoutInterval = 60
        speechRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        speechRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.speechModelIdentifier,
            "input": spokenChunk
        ])

        let (responseData, response) = try await URLSession.shared.data(for: speechRequest)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, !responseData.isEmpty else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw QwenLocalTTSError(message: "Qwen voice server answered with status \(statusCode)")
        }
        return responseData
    }

    private func isServerResponding() async -> Bool {
        var modelsRequest = URLRequest(url: Self.serverBaseURL.appendingPathComponent("v1/models"))
        modelsRequest.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: modelsRequest) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Starts `mlx-serve` (localhost only) if nothing is answering on its port.
    func ensureServerIsRunning() async throws {
        if await isServerResponding() { return }

        guard Self.isAvailableOnThisMac else {
            throw QwenLocalTTSError(message: "MLX Core isn't installed, so the Qwen voice can't run.")
        }

        if serverProcessStartedByClicky?.isRunning != true {
            let serverProcess = Process()
            serverProcess.executableURL = Self.mlxServeExecutableURL
            serverProcess.arguments = ["serve", "--host", "127.0.0.1", "--port", "11234"]
            serverProcess.standardOutput = FileHandle.nullDevice
            serverProcess.standardError = FileHandle.nullDevice
            try serverProcess.run()
            serverProcessStartedByClicky = serverProcess
            print("🔊 Qwen voice: started mlx-serve on 127.0.0.1:11234")
        }

        let startupDeadline = Date().addingTimeInterval(Self.serverStartupTimeoutSeconds)
        while Date() < startupDeadline {
            try Task.checkCancellation()
            if await isServerResponding() { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw QwenLocalTTSError(message: "The Qwen voice server didn't start in time.")
    }

    /// Starts the server and loads the model ahead of the first answer, so the
    /// first reply doesn't pay the few-second model load.
    func warmUp() async {
        do {
            try await ensureServerIsRunning()
            _ = try await synthesizeSpeech(for: "Ready.")
            print("🔊 Qwen voice: warmed up")
        } catch {
            print("⚠️ Qwen voice warm-up failed: \(error)")
        }
    }

    func stopServerIfStartedByClicky() {
        guard let serverProcessStartedByClicky, serverProcessStartedByClicky.isRunning else { return }
        serverProcessStartedByClicky.terminate()
        self.serverProcessStartedByClicky = nil
    }
}
