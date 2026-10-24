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
//  - Answers are split into sentences: the first one is generated and starts
//    playing within about half a second while the next is generated in the
//    background, so long answers don't wait for the whole thing.
//  - Same text always gives the same voice (the model is deterministic), so
//    sentences stitched together sound like one speaker.
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

    /// Short enough that the first sentence arrives fast, long enough that
    /// the voice keeps a natural flow across a clause.
    nonisolated private static let maximumCharactersPerSpokenChunk = 220
    private static let serverStartupTimeoutSeconds: Double = 40

    /// True when MLX Core is installed, i.e. this voice can work at all.
    static var isAvailableOnThisMac: Bool {
        FileManager.default.isExecutableFile(atPath: mlxServeExecutableURL.path)
    }

    private var playbackTask: Task<Void, Never>?
    private var currentAudioPlayer: AVAudioPlayer?
    /// Only set when Clicky launched the server, so Clicky never kills a
    /// server the user started themselves.
    private var serverProcessStartedByClicky: Process?
    private var isPlaybackQueueActive = false

    var isPlaying: Bool {
        isPlaybackQueueActive || (currentAudioPlayer?.isPlaying ?? false)
    }

    // MARK: - Speaking

    /// Generates the first sentence, starts playing it, and returns, matching
    /// the other speech clients, which return once audio has begun. The rest
    /// of the answer keeps playing in the background.
    func speakText(_ text: String) async throws {
        stopPlayback()
        try Task.checkCancellation()

        let spokenChunks = Self.splitIntoSpokenChunks(text)
        guard let firstSpokenChunk = spokenChunks.first else { return }

        try await ensureServerIsRunning()
        let firstChunkAudioData = try await synthesizeSpeech(for: firstSpokenChunk)
        try Task.checkCancellation()

        isPlaybackQueueActive = true
        try startPlaying(audioData: firstChunkAudioData)
        print("🔊 Qwen voice: speaking \(text.count) characters in \(spokenChunks.count) chunk(s)")

        let remainingSpokenChunks = Array(spokenChunks.dropFirst())
        playbackTask = Task { [weak self] in
            await self?.playRemainingChunks(remainingSpokenChunks)
        }
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        currentAudioPlayer?.stop()
        currentAudioPlayer = nil
        isPlaybackQueueActive = false
    }

    /// Plays chunk after chunk, generating each next chunk while the current
    /// one is still playing so there's no gap between sentences.
    private func playRemainingChunks(_ remainingSpokenChunks: [String]) async {
        defer {
            if !Task.isCancelled {
                isPlaybackQueueActive = false
            }
        }

        var nextChunkAudioTask: Task<Data, Error>? = remainingSpokenChunks.first.map { firstRemainingChunk in
            Task { try await synthesizeSpeech(for: firstRemainingChunk) }
        }

        for chunkIndex in remainingSpokenChunks.indices {
            await waitForCurrentAudioToFinish()
            guard !Task.isCancelled, let currentChunkAudioTask = nextChunkAudioTask else { return }

            let currentChunkAudioData: Data
            do {
                currentChunkAudioData = try await currentChunkAudioTask.value
            } catch {
                print("⚠️ Qwen voice: chunk \(chunkIndex + 2) failed, stopping: \(error)")
                return
            }
            guard !Task.isCancelled else { return }

            let followingChunkIndex = chunkIndex + 1
            nextChunkAudioTask = followingChunkIndex < remainingSpokenChunks.count
                ? Task { try await synthesizeSpeech(for: remainingSpokenChunks[followingChunkIndex]) }
                : nil

            do {
                try startPlaying(audioData: currentChunkAudioData)
            } catch {
                print("⚠️ Qwen voice: couldn't play chunk: \(error)")
                return
            }
        }

        await waitForCurrentAudioToFinish()
    }

    private func startPlaying(audioData: Data) throws {
        let audioPlayer = try AVAudioPlayer(data: audioData)
        currentAudioPlayer = audioPlayer
        audioPlayer.play()
    }

    private func waitForCurrentAudioToFinish() async {
        while let currentAudioPlayer, currentAudioPlayer.isPlaying, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    // MARK: - Server

    private func synthesizeSpeech(for spokenChunk: String) async throws -> Data {
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

    // MARK: - Chunking

    /// Splits an answer into sentence-sized chunks, merging very short
    /// sentences and breaking very long ones at commas, then spaces.
    nonisolated static func splitIntoSpokenChunks(_ text: String) -> [String] {
        let normalizedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return [] }

        var sentences: [String] = []
        normalizedText.enumerateSubstrings(in: normalizedText.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence {
                let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedSentence.isEmpty { sentences.append(trimmedSentence) }
            }
        }
        if sentences.isEmpty { sentences = [normalizedText] }

        var spokenChunks: [String] = []
        for sentence in sentences {
            for sentencePiece in breakUpLongSentence(sentence) {
                // Fold tiny fragments ("Yes." "Okay.") into the previous chunk.
                if let previousChunk = spokenChunks.last,
                   sentencePiece.count < 25 || previousChunk.count < 25,
                   previousChunk.count + 1 + sentencePiece.count <= maximumCharactersPerSpokenChunk {
                    spokenChunks[spokenChunks.count - 1] = previousChunk + " " + sentencePiece
                } else {
                    spokenChunks.append(sentencePiece)
                }
            }
        }
        return spokenChunks
    }

    nonisolated private static func breakUpLongSentence(_ sentence: String) -> [String] {
        guard sentence.count > maximumCharactersPerSpokenChunk else { return [sentence] }

        var sentencePieces: [String] = []
        var currentPiece = ""
        for word in sentence.split(separator: " ") {
            let candidatePiece = currentPiece.isEmpty ? String(word) : currentPiece + " " + word
            let currentPieceEndsAtComma = currentPiece.hasSuffix(",") || currentPiece.hasSuffix(";")
            if candidatePiece.count > maximumCharactersPerSpokenChunk
                || (currentPieceEndsAtComma && currentPiece.count > maximumCharactersPerSpokenChunk / 2) {
                sentencePieces.append(currentPiece)
                currentPiece = String(word)
            } else {
                currentPiece = candidatePiece
            }
        }
        if !currentPiece.isEmpty { sentencePieces.append(currentPiece) }
        return sentencePieces
    }
}
