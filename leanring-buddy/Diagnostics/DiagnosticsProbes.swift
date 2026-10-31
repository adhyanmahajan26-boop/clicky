//
//  DiagnosticsProbes.swift
//  leanring-buddy
//
//  Read-only checks behind the Diagnostics window. Permissions are read and
//  never requested. `claude auth status` runs only when the user presses
//  Check Claude, and `gh` only when the user presses Check GitHub. Nothing
//  here prints a token: only exit codes, the logged-in login, and the
//  "Token scopes" line from `gh auth status` are kept.
//

import ApplicationServices
import AVFoundation
import ClickyCore
import CoreGraphics
import Foundation
import Speech

enum DiagnosticsProbes {
    static var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.clicky.tts.plist")
    }

    // MARK: - Permissions (read-only)

    static func permissionLines() -> [DiagnosticsStatusLine] {
        let isAccessibilityGranted = AXIsProcessTrusted()
        let isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
        return [
            DiagnosticsStatusLine(label: "Accessibility", value: isAccessibilityGranted ? "Granted" : "Not granted",
                                  level: isAccessibilityGranted ? .good : .problem),
            DiagnosticsStatusLine(label: "Screen Recording", value: isScreenRecordingGranted ? "Granted" : "Not granted (a relaunch may be needed after granting)",
                                  level: isScreenRecordingGranted ? .good : .problem),
            microphoneLine(AVCaptureDevice.authorizationStatus(for: .audio)),
            speechLine(SFSpeechRecognizer.authorizationStatus())
        ]
    }

    static func microphoneLine(_ status: AVAuthorizationStatus) -> DiagnosticsStatusLine {
        switch status {
        case .authorized: return DiagnosticsStatusLine(label: "Microphone", value: "Granted", level: .good)
        case .notDetermined: return DiagnosticsStatusLine(label: "Microphone", value: "Not asked yet", level: .unknown)
        case .denied: return DiagnosticsStatusLine(label: "Microphone", value: "Denied", level: .problem)
        case .restricted: return DiagnosticsStatusLine(label: "Microphone", value: "Restricted", level: .problem)
        @unknown default: return DiagnosticsStatusLine(label: "Microphone", value: "Unknown", level: .unknown)
        }
    }

    static func speechLine(_ status: SFSpeechRecognizerAuthorizationStatus) -> DiagnosticsStatusLine {
        switch status {
        case .authorized: return DiagnosticsStatusLine(label: "Speech Recognition", value: "Granted", level: .good)
        case .notDetermined: return DiagnosticsStatusLine(label: "Speech Recognition", value: "Not asked yet", level: .unknown)
        case .denied: return DiagnosticsStatusLine(label: "Speech Recognition", value: "Denied", level: .problem)
        case .restricted: return DiagnosticsStatusLine(label: "Speech Recognition", value: "Restricted", level: .problem)
        @unknown default: return DiagnosticsStatusLine(label: "Speech Recognition", value: "Unknown", level: .unknown)
        }
    }

    // MARK: - Claude and GitHub (run only on button press)

    /// Exit code of `claude auth status`, and the loggedIn field it prints.
    static func claudeAuthLines() async -> [DiagnosticsStatusLine] {
        guard let claudeExecutableURL = ClaudeCodeBridge.locateClaudeCodeExecutable() else {
            return [DiagnosticsStatusLine(label: "Claude sign-in", value: "claude CLI not found", level: .problem)]
        }
        let commandResult = await runProcess(executableURL: claudeExecutableURL, arguments: ["auth", "status"])
        // Only the loggedIn flag is read; the rest of the JSON is not shown.
        let isLoggedIn = (try? JSONSerialization.jsonObject(with: Data(commandResult.standardOutput.utf8)) as? [String: Any])?["loggedIn"] as? Bool ?? false
        return [
            DiagnosticsStatusLine(label: "claude auth status", value: "exit \(commandResult.exitCode)", level: commandResult.exitCode == 0 ? .good : .problem),
            DiagnosticsStatusLine(label: "Signed in", value: isLoggedIn ? "Yes" : "No. Run `claude auth login` in Terminal.", level: isLoggedIn ? .good : .problem)
        ]
    }

    /// `gh auth status` exit code, scopes line and `gh api user -q .login`. Token lines are dropped.
    static func githubLines() async -> [DiagnosticsStatusLine] {
        guard let githubExecutableURL = locateGitHubExecutable() else {
            return [DiagnosticsStatusLine(label: "GitHub", value: "gh CLI not found", level: .problem)]
        }
        let statusResult = await runProcess(executableURL: githubExecutableURL, arguments: ["auth", "status"])
        let statusText = statusResult.standardOutput + "\n" + statusResult.standardError
        // The scopes line is safe to show; any line that carries a token value is not.
        let scopeLines = statusText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.localizedCaseInsensitiveContains("Token scopes") && !$0.localizedCaseInsensitiveContains("token:") }

        var lines = [DiagnosticsStatusLine(label: "gh auth status", value: "exit \(statusResult.exitCode)", level: statusResult.exitCode == 0 ? .good : .problem)]
        if let scopeLine = scopeLines.first {
            lines.append(DiagnosticsStatusLine(label: "Scopes", value: scopeLine.replacingOccurrences(of: "- ", with: "", options: .anchored), level: .unknown))
        }
        let loginResult = await runProcess(executableURL: githubExecutableURL, arguments: ["api", "user", "-q", ".login"])
        let login = loginResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if loginResult.exitCode == 0, !login.isEmpty {
            lines.append(DiagnosticsStatusLine(label: "Logged in as", value: login, level: .good))
        } else {
            lines.append(DiagnosticsStatusLine(label: "Logged in as", value: "Not logged in", level: .problem))
        }
        return lines
    }

    static func locateGitHubExecutable() -> URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Code mode

    /// The last preflight report (code mode runs it once per launch).
    static func codeLines(preflightReport: CodePreflightReport?, isCodeEnabled: Bool) -> [DiagnosticsStatusLine] {
        guard let preflightReport else {
            let value = isCodeEnabled ? "Not run this launch" : "Code mode is off"
            return [DiagnosticsStatusLine(label: "Code preflight", value: value, level: .unknown)]
        }
        return [
            DiagnosticsStatusLine(label: "Code preflight", value: preflightReport.statusLine, level: preflightReport.isReady ? .good : .problem),
            DiagnosticsStatusLine(label: "apiKeySource", value: preflightReport.apiKeySource ?? "not recorded", level: .unknown)
        ]
    }

    // MARK: - Voice (Qwen supervisor and the newest turn)

    static func voiceLines(supervisorStatus: String, isSupervisorReady: Bool, modelIdentifier: String,
                           newestTimeToFirstAudioMilliseconds: Double?) -> [DiagnosticsStatusLine] {
        var lines = [
            DiagnosticsStatusLine(label: "Qwen supervisor", value: supervisorStatus, level: isSupervisorReady ? .good : .unknown),
            DiagnosticsStatusLine(label: "TTS model", value: modelIdentifier, level: .unknown)
        ]
        if let newestTimeToFirstAudioMilliseconds {
            lines.append(DiagnosticsStatusLine(label: "Last time to first audio", value: "\(Int(newestTimeToFirstAudioMilliseconds.rounded())) ms", level: .unknown))
        } else {
            lines.append(DiagnosticsStatusLine(label: "Last time to first audio", value: "No turn with audio yet", level: .unknown))
        }
        return lines
    }

    /// keyUp → firstAudio of the newest turn in ~/Library/Logs/Clicky/turns (turn.json timings, Unix seconds).
    static func newestTimeToFirstAudioMilliseconds() -> Double? {
        let turnsDirectoryURL = TurnLogger.turnsDirectoryURL
        guard let turnDirectoryURLs = try? FileManager.default.contentsOfDirectory(at: turnsDirectoryURL, includingPropertiesForKeys: nil) else { return nil }
        // Directory names start with yyyyMMdd-HHmmss, so name order is age order.
        for turnDirectoryURL in turnDirectoryURLs.filter({ $0.hasDirectoryPath }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let turnData = try? Data(contentsOf: turnDirectoryURL.appendingPathComponent("turn.json")),
                  let turnObject = try? JSONSerialization.jsonObject(with: turnData) as? [String: Any],
                  let timings = turnObject["timings"] as? [String: Double],
                  let keyUpSeconds = timings["keyUp"], let firstAudioSeconds = timings["firstAudio"] else { continue }
            return (firstAudioSeconds - keyUpSeconds) * 1000
        }
        return nil
    }

    // MARK: - LaunchAgent (read-only)

    static func launchAgentLines() -> [DiagnosticsStatusLine] {
        let isInstalled = FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
        return [DiagnosticsStatusLine(label: "Keep-warm LaunchAgent",
                                      value: isInstalled ? "Plist present at ~/Library/LaunchAgents/local.clicky.tts.plist" : "Not installed",
                                      level: isInstalled ? .good : .unknown)]
    }

    // MARK: - Processes

    /// Runs a command and collects its output. Only used for the two CLIs above.
    static func runProcess(executableURL: URL, arguments: [String]) async -> (exitCode: Int32, standardOutput: String, standardError: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            let standardOutputPipe = Pipe()
            let standardErrorPipe = Pipe()
            process.standardOutput = standardOutputPipe
            process.standardError = standardErrorPipe
            do {
                try process.run()
            } catch {
                return (-1, "", "\(error)")
            }
            let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
            let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: standardOutputData, as: UTF8.self), String(decoding: standardErrorData, as: UTF8.self))
        }.value
    }
}
