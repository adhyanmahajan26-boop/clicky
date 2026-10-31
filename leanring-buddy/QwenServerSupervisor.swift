//
//  QwenServerSupervisor.swift
//  leanring-buddy
//
//  Keeps the mlx-serve server for the Qwen voice usable, and says so in one
//  status line for the panel. The decision itself is the pure
//  QwenSupervisor.decide(probe:lsof:) in ClickyCore; this runs lsof, acts
//  on it, and warms the model:
//   - a loopback-only listener is adopted and never killed;
//   - a listener on * / :: (reachable from the network) is left alone and
//     the Mac voice speaks ("Qwen unavailable: not loopback-only");
//   - a port that answers while lsof shows nobody (another user's process)
//     is treated like an exposed one;
//   - nobody listening → spawn `mlx-serve serve --host 127.0.0.1 --port
//     11234`, write ~/.clicky/mlx-serve.pid, and leave it running on quit
//     (the next launch adopts it);
//   - "Hi." warms the loaded model before "Qwen ready (…)";
//   - a server that dies mid-answer is respawned at most once per 60 s
//     (the Mac voice speaks the rest of that answer).
//  Nothing runs under XCTest, so hosted tests never touch the server.
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class QwenServerSupervisor: ObservableObject {
    @Published private(set) var status = "Qwen not started"
    @Published private(set) var isReady = false
    /// Decided against this server (exposed listener, no binary, or it didn't start).
    @Published private(set) var isUnavailable = false

    let client: QwenLocalTTSClient
    private var superviseTask: Task<Void, Never>?
    private var lastSpawnDate: Date?
    private static let pidFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".clicky/mlx-serve.pid")

    static var isRunningUnderXCTest: Bool {
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(client: QwenLocalTTSClient) {
        self.client = client
    }

    /// Adopts or starts the server and warms the model (once; no-op while running).
    func start() {
        guard superviseTask == nil, !isReady else { return }
        guard !Self.isRunningUnderXCTest else {
            status = "Qwen off under tests"
            isUnavailable = true
            return
        }
        isUnavailable = false
        superviseTask = Task { @MainActor [weak self] in
            await self?.supervise()
            self?.superviseTask = nil
        }
    }

    /// Setup changed where the voice runs: forget the old server and connect again.
    func reconnect() {
        superviseTask?.cancel()
        superviseTask = nil
        isReady = false
        isUnavailable = false
        status = "Qwen not started"
        start()
    }

    /// A request failed hard (connection refused, bad status): check again,
    /// respawning at most once per minute.
    func serverMayHaveDied() {
        guard isReady, superviseTask == nil else { return }
        isReady = false
        status = "Qwen restarting…"
        start()
    }

    /// Waits (up to `timeoutSeconds`) for "ready"; false if unavailable or still starting.
    func waitUntilReady(timeoutSeconds: TimeInterval) async -> Bool {
        if isReady { return true }
        if isUnavailable { return false }
        start()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline, !isReady, !isUnavailable, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return isReady
    }

    // MARK: - Supervision

    private func supervise() async {
        // Another Mac's server: nothing to adopt or spawn, just reach it.
        if let remoteServerURL = QwenLocalTTSClient.remoteServerURL {
            status = "Qwen connecting to \(remoteServerURL.host ?? "voice server")…"
            await connectAndWarm(modelsTimeoutSeconds: 10)
            return
        }
        let port = QwenLocalTTSClient.serverPort
        let lsofOutput = await Self.runLsof(port: port)
        let isResponding = await client.fetchModels() != nil
        let decision = QwenSupervisor.decide(
            probe: QwenSupervisor.Probe(
                isResponding: isResponding,
                isBinaryInstalled: QwenLocalTTSClient.isAvailableOnThisMac,
                isPortOverridden: ClickySettings.ttsPortOverride != nil,
                port: port
            ),
            lsof: QwenSupervisor.listener(fromLsof: lsofOutput)
        )
        print("🔊 Qwen supervisor: \(decision) (port \(port))")

        switch decision {
        case .unavailable(let unavailableStatus):
            markUnavailable(unavailableStatus)
            return
        case .spawn:
            guard QwenSupervisor.mayRespawn(lastSpawnDate: lastSpawnDate, now: Date()) else {
                markUnavailable("Qwen unavailable: server died (retrying in a minute)")
                scheduleRespawnRetry()
                return
            }
            status = "Qwen starting…"
            do {
                try spawnServer(port: port)
            } catch {
                markUnavailable("Qwen unavailable: couldn't start mlx-serve")
                return
            }
        case .adopt:
            status = "Qwen connecting…"
        }

        await connectAndWarm(modelsTimeoutSeconds: QwenTuning.serverStartupTimeoutSeconds)
    }

    /// Waits for the server's model list, then warms the model with "Hi.".
    private func connectAndWarm(modelsTimeoutSeconds: TimeInterval) async {
        guard let models = await waitForModels(timeoutSeconds: modelsTimeoutSeconds) else {
            markUnavailable(QwenLocalTTSClient.remoteServerURL != nil
                            ? "Qwen unavailable: voice server didn't answer (same Wi-Fi? right key?)"
                            : "Qwen unavailable: server didn't answer")
            return
        }
        client.loadedModelIdentifier = QwenSupervisor.ttsModelIdentifier(fromModels: models)

        status = "Qwen warming up…"
        do {
            // The first request loads the model, so it gets the startup timeout.
            _ = try await client.synthesizeSpeech(for: QwenTuning.warmUpText, watchdogSeconds: QwenTuning.serverStartupTimeoutSeconds)
        } catch {
            markUnavailable("Qwen unavailable: warm-up failed")
            return
        }
        isReady = true
        isUnavailable = false
        status = "Qwen ready (\(voiceLabel))"
    }

    /// The speaker, or "Base voice" when the loaded model ignores speakers.
    var voiceLabel: String {
        client.referenceClipBase64 != nil ? "fixed voice" : "no reference clip — voice varies"
    }

    /// Refreshes "ready (speaker)" after the picker changes.
    func refreshReadyStatus() {
        if isReady { status = "Qwen ready (\(voiceLabel))" }
    }

    /// Tries again once the one-per-minute respawn window has passed.
    private func scheduleRespawnRetry() {
        let waitSeconds = max(1, QwenTuning.respawnMinimumIntervalSeconds - Date().timeIntervalSince(lastSpawnDate ?? .distantPast))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            guard let self, self.isUnavailable, !self.isReady else { return }
            self.start()
        }
    }

    private func markUnavailable(_ unavailableStatus: String) {
        isReady = false
        isUnavailable = true
        status = unavailableStatus
        print("⚠️ \(unavailableStatus)")
    }

    private func waitForModels(timeoutSeconds: TimeInterval) async -> [[String: Any]]? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline, !Task.isCancelled {
            if let models = await client.fetchModels() { return models }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }

    /// Bound to 127.0.0.1 explicitly (mlx-serve's own default is 0.0.0.0).
    /// The model loads on the warm-up request: `--model` wants a directory.
    private func spawnServer(port: Int) throws {
        let serverProcess = Process()
        serverProcess.executableURL = QwenLocalTTSClient.mlxServeExecutableURL
        serverProcess.arguments = ["serve", "--host", QwenTuning.serverHost, "--port", String(port)]
        serverProcess.standardOutput = FileHandle.nullDevice
        serverProcess.standardError = FileHandle.nullDevice
        try serverProcess.run()
        lastSpawnDate = Date()
        try? FileManager.default.createDirectory(at: Self.pidFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(serverProcess.processIdentifier)\n".write(to: Self.pidFileURL, atomically: true, encoding: .utf8)
        print("🔊 Qwen voice: started mlx-serve (pid \(serverProcess.processIdentifier)) on \(QwenTuning.serverHost):\(port)")
    }

    /// `lsof -nP -iTCP:<port> -sTCP:LISTEN` (empty output = nobody listening).
    private nonisolated static func runLsof(port: Int) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let lsofProcess = Process()
                lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                lsofProcess.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
                let outputPipe = Pipe()
                lsofProcess.standardOutput = outputPipe
                lsofProcess.standardError = FileHandle.nullDevice
                do {
                    try lsofProcess.run()
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    lsofProcess.waitUntilExit()
                    continuation.resume(returning: String(decoding: outputData, as: UTF8.self))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
