//
//  KeepWarmLaunchAgent.swift
//  ClickyCore
//
//  The optional keep-warm LaunchAgent for the Qwen server: the plist that
//  would start mlx-serve at login and keep it running, plus the pure
//  decisions around it. Nothing here writes a file or runs launchctl. The
//  generated plist is returned as data, and the commands are argv arrays.
//
//  Install only when `v2.voice.keepWarmAgent` is on AND the user approved
//  the install (`v2.voice.keepWarmAgentApproved`). Turning the setting off
//  boots the agent out. An already-running server on the port is adopted
//  when its /v1/models health is 200 and it serves the same model.
//

import Foundation

public enum KeepWarmLaunchAgent {
    public static let label = "local.clicky.tts"
    public static let serverBinaryPath = "/Applications/MLX Core.app/Contents/MacOS/mlx-serve"
    public static let launchctlPath = "/bin/launchctl"
    public static let throttleIntervalSeconds = 30

    /// `~/Library/LaunchAgents/local.clicky.tts.plist` for the given home directory.
    public static func plistFilePath(homeDirectoryPath: String) -> String {
        "\(homeDirectoryPath)/Library/LaunchAgents/\(label).plist"
    }

    /// The agent's dictionary. Every path is absolute (launchd does not expand `~`).
    public static func plistDictionary(homeDirectoryPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [serverBinaryPath, "serve", "--host", QwenTuning.serverHost, "--port", String(QwenTuning.serverPort)],
            "EnvironmentVariables": [
                "HF_HUB_OFFLINE": "1",
                "HF_HUB_CACHE": "\(homeDirectoryPath)/.cache/huggingface/hub"
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": throttleIntervalSeconds,
            "ProcessType": "Interactive",
            "StandardErrorPath": "\(homeDirectoryPath)/Library/Logs/Clicky/mlx-serve.log"
        ]
    }

    /// The plist as XML property-list data.
    public static func plistData(homeDirectoryPath: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plistDictionary(homeDirectoryPath: homeDirectoryPath), format: .xml, options: 0)
    }

    /// `launchctl bootstrap gui/<uid> <plist>`: data only, never run by the app yet.
    public static func bootstrapArguments(userIdentifier: uid_t, plistFilePath: String) -> [String] {
        [launchctlPath, "bootstrap", "gui/\(userIdentifier)", plistFilePath]
    }

    /// `launchctl bootout gui/<uid>/local.clicky.tts`: data only, never run by the app yet.
    public static func bootoutArguments(userIdentifier: uid_t) -> [String] {
        [launchctlPath, "bootout", "gui/\(userIdentifier)/\(label)"]
    }

    // MARK: - Decisions

    public enum InstallDecision: Equatable {
        /// Setting on and the user said yes: write the plist and bootstrap it.
        case install
        /// Setting off while the agent is installed: bootout it.
        case bootOut
        /// Anything else: touch nothing.
        case leaveAlone
    }

    public static func installDecision(isKeepWarmSettingOn: Bool, isInstallApprovedByUser: Bool, isAgentInstalled: Bool) -> InstallDecision {
        if isKeepWarmSettingOn && isInstallApprovedByUser { return .install }
        if !isKeepWarmSettingOn && isAgentInstalled { return .bootOut }
        return .leaveAlone
    }

    public enum AdoptDecision: Equatable {
        /// A server on the port answers /v1/models with 200 and serves the expected model: use it, never kill it.
        case adoptRunningServer
        /// Nothing usable is listening: start the server (or the agent) as usual.
        case startOwnServer
    }

    /// `healthStatusCode` is nil when nothing answered. `servedModelIdentifiers` are the ids from /v1/models.
    public static func adoptDecision(healthStatusCode: Int?, servedModelIdentifiers: [String], expectedModelIdentifier: String) -> AdoptDecision {
        guard healthStatusCode == 200, servedModelIdentifiers.contains(expectedModelIdentifier) else { return .startOwnServer }
        return .adoptRunningServer
    }

    // MARK: - Install plan (unused for now)

    public struct InstallPlan: Equatable {
        public let plistFilePath: String
        public let plistData: Data
        public let bootstrapArguments: [String]
    }

    /// What installing the agent would write and run. Nothing in the app calls this yet: the app
    /// may only call it, and then write the plist and run `bootstrapArguments`, after the user says
    /// yes (the `v2.voice.keepWarmAgentApproved` flag). Until that exists this stays unused.
    public static func installPlanRequiringUserApproval(homeDirectoryPath: String, userIdentifier: uid_t) throws -> InstallPlan {
        let filePath = plistFilePath(homeDirectoryPath: homeDirectoryPath)
        return InstallPlan(plistFilePath: filePath,
                           plistData: try plistData(homeDirectoryPath: homeDirectoryPath),
                           bootstrapArguments: bootstrapArguments(userIdentifier: userIdentifier, plistFilePath: filePath))
    }
}
