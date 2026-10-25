//
//  QwenSupervisor.swift
//  ClickyCore
//
//  What to do about the mlx-serve server, decided from two facts: who is
//  listening on its port (lsof) and what the machine has (the binary, a
//  debug port override). Pure, so every branch is tested; the app runs
//  lsof, acts on the decision and reports the status line.
//   - listening on loopback only → adopt it (never kill it, even on quit);
//   - listening on * / 0.0.0.0 / :: / a LAN address → don't use it (the
//     Mac voice speaks), and never kill it;
//   - nobody listening → spawn mlx-serve on 127.0.0.1 (unless the binary is
//     missing, or a debug port override points somewhere else);
//   - lsof sees nobody but the port answers (another user's process, which
//     lsof can't show) → its binding is unknown, so treat it as exposed.
//

import Foundation

public enum QwenSupervisor {
    public enum Listener: Equatable, Sendable {
        case none
        case loopbackOnly(processIDs: [Int32])
        /// Reachable from other machines; the addresses as lsof printed them.
        case exposed(addresses: [String])
    }

    public struct Probe: Equatable, Sendable {
        /// GET /v1/models answered.
        public var isResponding: Bool
        public var isBinaryInstalled: Bool
        public var isPortOverridden: Bool
        public var port: Int

        public init(isResponding: Bool, isBinaryInstalled: Bool, isPortOverridden: Bool = false, port: Int = QwenTuning.serverPort) {
            self.isResponding = isResponding
            self.isBinaryInstalled = isBinaryInstalled
            self.isPortOverridden = isPortOverridden
            self.port = port
        }
    }

    public enum Decision: Equatable, Sendable {
        case adopt
        case spawn
        case unavailable(status: String)
    }

    public static let notLoopbackStatus = "Qwen unavailable: not loopback-only"
    public static let binaryMissingStatus = "Qwen unavailable: mlx-serve not found"

    public static func decide(probe: Probe, lsof listener: Listener) -> Decision {
        switch listener {
        case .loopbackOnly:
            return .adopt
        case .exposed:
            return .unavailable(status: notLoopbackStatus)
        case .none:
            if probe.isResponding { return .unavailable(status: notLoopbackStatus) }
            if probe.isPortOverridden { return .unavailable(status: "Qwen unavailable: nothing on port \(probe.port)") }
            if !probe.isBinaryInstalled { return .unavailable(status: binaryMissingStatus) }
            return .spawn
        }
    }

    /// Parses `lsof -nP -iTCP:<port> -sTCP:LISTEN` output.
    public static func listener(fromLsof output: String) -> Listener {
        var loopbackProcessIDs: [Int32] = []
        var exposedAddresses: [String] = []
        for line in output.split(separator: "\n") where line.contains("(LISTEN)") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 3, let listenIndex = columns.lastIndex(of: "(LISTEN)"), listenIndex >= 1 else { continue }
            let address = String(columns[listenIndex - 1])
            if isLoopback(address) {
                if let processID = Int32(columns[1]) { loopbackProcessIDs.append(processID) }
            } else {
                exposedAddresses.append(address)
            }
        }
        if !exposedAddresses.isEmpty { return .exposed(addresses: exposedAddresses) }
        if !loopbackProcessIDs.isEmpty { return .loopbackOnly(processIDs: loopbackProcessIDs) }
        return .none
    }

    /// "127.0.0.1:11234", "127.x.y.z:…", "[::1]:…", "localhost:…".
    static func isLoopback(_ address: String) -> Bool {
        guard let portSeparator = address.lastIndex(of: ":") else { return false }
        let host = address[..<portSeparator]
        return host.hasPrefix("127.") || host == "[::1]" || host == "localhost"
    }

    /// The TTS model to request: one the server has loaded, else the default.
    /// `models` is the `data` array of GET /v1/models.
    public static func ttsModelIdentifier(fromModels models: [[String: Any]]) -> String {
        let loadedTTSModels = models.filter { model in
            let identifier = model["id"] as? String ?? ""
            let isLoaded = model["loaded"] as? Bool ?? false
            return isLoaded && identifier.localizedCaseInsensitiveContains("TTS")
        }
        return loadedTTSModels.first?["id"] as? String ?? QwenTuning.defaultModelIdentifier
    }

    /// Whether a model id honours speakers (CustomVoice) or only clones (Base).
    public static func supportsSpeakers(modelIdentifier: String) -> Bool {
        modelIdentifier.localizedCaseInsensitiveContains("CustomVoice")
    }

    /// At most one respawn per minute.
    public static func mayRespawn(lastSpawnDate: Date?, now: Date) -> Bool {
        guard let lastSpawnDate else { return true }
        return now.timeIntervalSince(lastSpawnDate) >= QwenTuning.respawnMinimumIntervalSeconds
    }
}
