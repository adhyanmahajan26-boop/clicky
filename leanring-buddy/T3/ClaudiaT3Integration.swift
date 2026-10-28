//
//  ClaudiaT3Integration.swift
//  leanring-buddy
//
//  "Add Claudia to T3 Code": registers this app's MCP server (`--mcp`) with
//  the agents T3 Code drives, at user scope, so every T3 Code thread (and
//  plain Claude Code / Codex / OpenCode sessions) gets Claudia's tools:
//    Claude Code → `claude mcp add --scope user claudia -- <this app> --mcp`
//    Codex       → [mcp_servers.claudia] in ~/.codex/config.toml
//    OpenCode    → "mcp": {"claudia": …} in ~/.config/opencode/opencode.json
//  Running it again points them at this copy of the app (after a move or an update).
//  Claudia's own brain never loads it: Claude runs with --strict-mcp-config and
//  Codex with --ignore-user-config.
//

import ClickyCore
import Foundation

enum ClaudiaT3Integration {
    static var executablePath: String { Bundle.main.executablePath ?? "/Applications/Claudia.app/Contents/MacOS/Clicky" }

    struct Outcome {
        var lines: [String] = []
        var succeeded = true
    }

    /// Registers Claudia with every agent that's installed. Safe to run again.
    static func install() -> Outcome {
        var outcome = Outcome()
        let executable = executablePath

        if let claude = ClaudeCodeBridge.locateClaudeCodeExecutable() {
            _ = run(claude.path, ["mcp", "remove", "--scope", "user", "claudia"])
            let (status, output) = run(claude.path, ["mcp", "add", "--scope", "user", "claudia", "--", executable, "--mcp"])
            outcome.lines.append(status == 0 ? "✓ Claude Code" : "✗ Claude Code: \(output.prefix(160))")
            if status != 0 { outcome.succeeded = false }
        } else {
            outcome.lines.append("– Claude Code isn't installed")
        }

        let codexConfigURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        if FileManager.default.fileExists(atPath: codexConfigURL.deletingLastPathComponent().path) {
            do {
                let existing = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
                try codexConfig(existing: existing, executable: executable).write(to: codexConfigURL, atomically: true, encoding: .utf8)
                outcome.lines.append("✓ Codex (ChatGPT)")
            } catch {
                outcome.lines.append("✗ Codex: \(error.localizedDescription)")
                outcome.succeeded = false
            }
        } else {
            outcome.lines.append("– Codex isn't set up")
        }

        if BrainCLIRunner.locateExecutable(for: .opencode) != nil {
            let openCodeConfigURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode/opencode.json")
            do {
                try FileManager.default.createDirectory(at: openCodeConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: openCodeConfigURL)) as? [String: Any]) ?? [:]
                if object["$schema"] == nil { object["$schema"] = "https://opencode.ai/config.json" }
                var servers = object["mcp"] as? [String: Any] ?? [:]
                servers["claudia"] = ["type": "local", "command": [executable, "--mcp"], "enabled": true]
                object["mcp"] = servers
                let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: openCodeConfigURL, options: .atomic)
                outcome.lines.append("✓ OpenCode")
            } catch {
                outcome.lines.append("✗ OpenCode: \(error.localizedDescription)")
                outcome.succeeded = false
            }
        }
        return outcome
    }

    /// ~/.codex/config.toml with one [mcp_servers.claudia] table (replacing an older one).
    static func codexConfig(existing: String, executable: String) -> String {
        var lines = existing.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.claudia]" }) {
            var end = start + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            lines.removeSubrange(start..<end)
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quotedExecutable = executable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        text += "\n\n[mcp_servers.claudia]\ncommand = \"\(quotedExecutable)\"\nargs = [\"--mcp\"]\nstartup_timeout_sec = 30\ntool_timeout_sec = 330\n"
        return text
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "couldn't start") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
