//
//  ClaudiaT3Integration.swift
//  leanring-buddy
//
//  The T3 Code extension: installs the "theo" Claude plugin (skills + MCP tools)
//  and registers this app's MCP server (`--mcp`) with
//  the agents T3 Code drives, at user scope, so every T3 Code thread (and
//  plain Claude Code / Codex / OpenCode sessions) gets Claudia's tools:
//    Claude Code → `claude mcp add --scope user claudia -- <this app> --mcp`
//    Codex       → [mcp_servers.claudia] in ~/.codex/config.toml
//    OpenCode    → "mcp": {"theo": …} in ~/.config/opencode/opencode.json
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

    /// Where the extension (plugin marketplace) is written.
    static var extensionDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Theo/t3-extension")
    }

    static let extensionVersion = "1.0.0"
    static let skillNames = ["theo-notes", "ask-theo", "theo-screen", "theo-whiteboard"]

    /// Which agents have the extension, read from their config files (no processes run).
    struct Status: Equatable {
        var claude: Bool?   // nil = the agent isn't installed
        var codex: Bool?
        var openCode: Bool?
        var anyInstalled: Bool { claude == true || codex == true || openCode == true }
    }

    static func status() -> Status {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var status = Status()
        if ClaudeCodeBridge.locateClaudeCodeExecutable() != nil {
            let installed = (try? String(contentsOf: home.appendingPathComponent(".claude/plugins/installed_plugins.json"), encoding: .utf8)) ?? ""
            status.claude = installed.contains("\"theo@theo\"")
        }
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        if FileManager.default.fileExists(atPath: codexConfig.deletingLastPathComponent().path) {
            status.codex = ((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "").contains("[mcp_servers.theo]")
        }
        if BrainCLIRunner.locateExecutable(for: .opencode) != nil {
            let config = (try? String(contentsOf: home.appendingPathComponent(".config/opencode/opencode.json"), encoding: .utf8)) ?? ""
            status.openCode = config.contains("\"theo\"")
        }
        return status
    }

    /// The agents the extension can go into.
    enum Agent: String, CaseIterable, Identifiable {
        case claude, codex, openCode
        var id: String { rawValue }
        var title: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex (ChatGPT)"
            case .openCode: return "OpenCode"
            }
        }
        var isOnThisMac: Bool {
            switch self {
            case .claude: return ClaudeCodeBridge.locateClaudeCodeExecutable() != nil
            case .codex: return FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
                || BrainCLIRunner.locateExecutable(for: .codex) != nil
            case .openCode: return BrainCLIRunner.locateExecutable(for: .opencode) != nil
            }
        }
    }

    /// The T3 Code apps on this Mac (the official ones and the Cursor Assistant build).
    static var t3Apps: [URL] {
        let names = ["T3 Code (Nightly).app", "T3 Code.app", "T3 Code Cursor Assistant.app"]
        let folders = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        return folders.flatMap { folder in names.map { URL(fileURLWithPath: folder).appendingPathComponent($0) } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Writes the extension and installs it in every agent that's installed. Safe to run again (updates it).
    static func install() -> Outcome { install(agents: Set(Agent.allCases)) }

    /// Writes the extension and installs it in the agents picked (that are on this Mac).
    static func install(agents: Set<Agent>) -> Outcome {
        var outcome = Outcome()
        let executable = executablePath
        let home = FileManager.default.homeDirectoryForCurrentUser

        // The extension files: a plugin marketplace with the "theo" plugin (skills + MCP launcher).
        let directory = extensionDirectory
        do {
            try? FileManager.default.removeItem(at: directory)
            for (relativePath, contents) in T3ExtensionFiles.files {
                let url = directory.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
                if relativePath.contains("/bin/") { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            }
        } catch {
            outcome.lines.append("✗ Couldn't write the extension: \(error.localizedDescription)")
            outcome.succeeded = false
            return outcome
        }

        if agents.contains(.claude), let claude = ClaudeCodeBridge.locateClaudeCodeExecutable() {
            // The plugin brings the tools, so the older user-scope servers go (no duplicate tools).
            for name in ["claudia", "theo"] { _ = run(claude.path, ["mcp", "remove", "--scope", "user", name]) }
            _ = run(claude.path, ["plugin", "marketplace", "remove", "theo"])
            let (addStatus, addOutput) = run(claude.path, ["plugin", "marketplace", "add", directory.path])
            let (installStatus, installOutput) = addStatus == 0 ? run(claude.path, ["plugin", "install", "theo@theo"]) : (addStatus, addOutput)
            outcome.lines.append(installStatus == 0 ? "✓ Claude Code" : "✗ Claude Code: \(installOutput.prefix(160))")
            if installStatus != 0 { outcome.succeeded = false }
        }

        let codexConfigURL = home.appendingPathComponent(".codex/config.toml")
        if agents.contains(.codex) {
            do {
                try FileManager.default.createDirectory(at: codexConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let existing = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
                try codexConfig(existing: existing, executable: executable).write(to: codexConfigURL, atomically: true, encoding: .utf8)
                let skills = home.appendingPathComponent(".codex/skills")
                for skill in skillNames {
                    let target = skills.appendingPathComponent(skill)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    let source = directory.appendingPathComponent("plugins/theo/skills/\(skill)/SKILL.md")
                    try? FileManager.default.removeItem(at: target.appendingPathComponent("SKILL.md"))
                    try FileManager.default.copyItem(at: source, to: target.appendingPathComponent("SKILL.md"))
                }
                outcome.lines.append("✓ Codex (ChatGPT)")
            } catch {
                outcome.lines.append("✗ Codex: \(error.localizedDescription)")
                outcome.succeeded = false
            }
        }

        if agents.contains(.openCode), BrainCLIRunner.locateExecutable(for: .opencode) != nil {
            let openCodeConfigURL = home.appendingPathComponent(".config/opencode/opencode.json")
            do {
                try FileManager.default.createDirectory(at: openCodeConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: openCodeConfigURL)) as? [String: Any]) ?? [:]
                if object["$schema"] == nil { object["$schema"] = "https://opencode.ai/config.json" }
                var servers = object["mcp"] as? [String: Any] ?? [:]
                servers.removeValue(forKey: "claudia")
                servers["theo"] = ["type": "local", "command": [executable, "--mcp"], "enabled": true]
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

    /// Takes the extension out of every agent.
    static func uninstall() -> Outcome {
        var outcome = Outcome()
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let claude = ClaudeCodeBridge.locateClaudeCodeExecutable() {
            _ = run(claude.path, ["plugin", "uninstall", "theo@theo"])
            _ = run(claude.path, ["plugin", "marketplace", "remove", "theo"])
            outcome.lines.append("✓ Removed from Claude Code")
        }
        let codexConfigURL = home.appendingPathComponent(".codex/config.toml")
        if let existing = try? String(contentsOf: codexConfigURL, encoding: .utf8) {
            try? removingTables(["[mcp_servers.theo]", "[mcp_servers.claudia]"], from: existing).write(to: codexConfigURL, atomically: true, encoding: .utf8)
            for skill in skillNames { try? FileManager.default.removeItem(at: home.appendingPathComponent(".codex/skills/\(skill)")) }
            outcome.lines.append("✓ Removed from Codex")
        }
        let openCodeConfigURL = home.appendingPathComponent(".config/opencode/opencode.json")
        if var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: openCodeConfigURL))) as? [String: Any],
           var servers = object["mcp"] as? [String: Any], servers["theo"] != nil {
            servers.removeValue(forKey: "theo")
            object["mcp"] = servers
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: openCodeConfigURL, options: .atomic) }
            outcome.lines.append("✓ Removed from OpenCode")
        }
        return outcome
    }

    static func removingTables(_ headers: [String], from existing: String) -> String {
        var lines = existing.components(separatedBy: "\n")
        for header in headers {
            if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) {
                var end = start + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
                lines.removeSubrange(start..<end)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// ~/.codex/config.toml with one [mcp_servers.claudia] table (replacing an older one).
    static func codexConfig(existing: String, executable: String) -> String {
        var text = removingTables(["[mcp_servers.theo]", "[mcp_servers.claudia]"], from: existing).trimmingCharacters(in: .whitespacesAndNewlines)
        let quotedExecutable = executable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        text += "\n\n[mcp_servers.theo]\ncommand = \"\(quotedExecutable)\"\nargs = [\"--mcp\"]\nstartup_timeout_sec = 30\ntool_timeout_sec = 330\n"
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
