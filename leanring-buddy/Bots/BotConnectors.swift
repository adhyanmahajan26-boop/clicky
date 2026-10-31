//
//  BotConnectors.swift
//  leanring-buddy
//
//  The apps bots can use and whether each engine can reach them. Claude
//  Code gets claude.ai connectors (Gmail, Notion, Drive…) from the signed-in
//  account plus local MCP servers; OpenCode only has the MCP servers in its
//  own config, so a cloud connector has to be added and signed in there
//  separately. Statuses come from `claude mcp list` and `opencode mcp list`.
//

import AppKit
import ClickyCore
import Foundation

struct BotConnector: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    /// The server's name in `claude mcp list`.
    let claudeServer: String?
    /// The tool-name prefix Claude Code gives the server's tools.
    let claudeToolPrefix: String?
    /// The server's name in OpenCode's config.
    let openCodeServer: String?
    /// A hosted MCP endpoint OpenCode can add and sign in to, when there is one.
    let openCodeURL: String?
    /// A skill set rather than a connector (always there when the plugin is).
    var isSkill = false
}

enum BotConnectors {
    static let known: [BotConnector] = [
        BotConnector(id: "gmail", name: "Gmail", symbol: "envelope.fill", claudeServer: "claude.ai Gmail",
                     claudeToolPrefix: "mcp__claude_ai_Gmail", openCodeServer: "gmail",
                     openCodeURL: "https://gmailmcp.googleapis.com/mcp/v1"),
        BotConnector(id: "notion", name: "Notion", symbol: "doc.richtext.fill", claudeServer: "claude.ai Notion",
                     claudeToolPrefix: "mcp__claude_ai_Notion", openCodeServer: "notion",
                     openCodeURL: "https://mcp.notion.com/mcp"),
        BotConnector(id: "calendar", name: "Notion Calendar", symbol: "calendar", claudeServer: "claude.ai Notion",
                     claudeToolPrefix: "mcp__claude_ai_Notion", openCodeServer: "notion",
                     openCodeURL: "https://mcp.notion.com/mcp"),
        BotConnector(id: "drive", name: "Google Drive", symbol: "externaldrive.fill", claudeServer: "claude.ai Google Drive",
                     claudeToolPrefix: "mcp__claude_ai_Google_Drive", openCodeServer: "google-drive",
                     openCodeURL: "https://drivemcp.googleapis.com/mcp/v1"),
        BotConnector(id: "docs", name: "Google Docs", symbol: "doc.text.fill", claudeServer: "claude.ai Google Docs",
                     claudeToolPrefix: "mcp__claude_ai_Google_Docs", openCodeServer: "google-docs",
                     openCodeURL: "https://docsmcp.googleapis.com/mcp/v1"),
        BotConnector(id: "sheets", name: "Google Sheets", symbol: "tablecells.fill", claudeServer: "claude.ai Google Sheets",
                     claudeToolPrefix: "mcp__claude_ai_Google_Sheets", openCodeServer: "google-sheets",
                     openCodeURL: "https://sheetsmcp.googleapis.com/mcp/v1"),
        BotConnector(id: "hostinger", name: "Hostinger", symbol: "server.rack", claudeServer: "claude.ai Hostinger Connector",
                     claudeToolPrefix: "mcp__claude_ai_Hostinger_Connector", openCodeServer: "hostinger",
                     openCodeURL: "https://mcp.hostinger.com"),
        BotConnector(id: "studio", name: "Content Studio", symbol: "film.stack.fill", claudeServer: "content-studio",
                     claudeToolPrefix: "mcp__content-studio", openCodeServer: "content-studio", openCodeURL: nil),
        BotConnector(id: "theo", name: "Theo (screen, voice, notes)", symbol: "sparkles", claudeServer: "plugin:theo:theo",
                     claudeToolPrefix: "mcp__plugin_theo_theo", openCodeServer: "theo", openCodeURL: nil),
        BotConnector(id: "hyperframes", name: "HyperFrames", symbol: "wand.and.stars", claudeServer: nil,
                     claudeToolPrefix: nil, openCodeServer: nil, openCodeURL: nil, isSkill: true),
        BotConnector(id: "chrome", name: "Chrome", symbol: "globe", claudeServer: "claude-in-chrome",
                     claudeToolPrefix: "mcp__claude-in-chrome", openCodeServer: "claude-in-chrome", openCodeURL: nil),
    ]

    /// Apps bots on OpenCode and Grok reach through Theo's claudia_app tool (ConnectorBridge).
    static let bridgedApps: Set<String> = ["gmail", "notion", "calendar", "drive", "docs", "sheets"]

    static func bridged(_ connector: BotConnector) -> Bool { bridgedApps.contains(connector.id) }

    enum Status: Equatable {
        case connected, needsSignIn, missing, unknown

        var label: String {
            switch self {
            case .connected: return "Connected"
            case .needsSignIn: return "Needs sign-in"
            case .missing: return "Not connected"
            case .unknown: return "Checking…"
            }
        }
    }

    /// `claude mcp list`: "claude.ai Gmail: https://… - ✔ Connected".
    static func parseClaude(_ listing: String) -> [String: Status] {
        var statuses: [String: Status] = [:]
        for line in stripANSI(listing).split(separator: "\n") {
            guard let colon = line.range(of: ": ") else { continue }
            let name = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            if line.contains("✔") || line.localizedCaseInsensitiveContains("connected") && !line.contains("!") && !line.contains("✘") {
                statuses[name] = .connected
            } else if line.localizedCaseInsensitiveContains("needs authentication") {
                statuses[name] = .needsSignIn
            } else {
                statuses[name] = .missing
            }
        }
        return statuses
    }

    /// `opencode mcp list`: "●  ✓ theo connected" / "●  ✗ notion needs authentication".
    static func parseOpenCode(_ listing: String) -> [String: Status] {
        var statuses: [String: Status] = [:]
        for raw in stripANSI(listing).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("●") else { continue }
            let words = line.dropFirst().split(separator: " ").map(String.init)
            guard words.count >= 2 else { continue }
            let name = words[1]
            let rest = words.dropFirst(2).joined(separator: " ").lowercased()
            if words[0] == "✓" { statuses[name] = .connected }
            else if rest.contains("auth") { statuses[name] = .needsSignIn }
            else { statuses[name] = .missing }
        }
        return statuses
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// Runs an engine's listing command and returns its output (empty if the engine isn't installed).
    static func listing(_ provider: BrainProvider) async -> String {
        guard let executable = BrainCLIRunner.locateExecutable(for: provider) else { return "" }
        return await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["mcp", "list"]
            process.currentDirectoryURL = BotRunner.workspace
            var environment = ProcessInfo.processInfo.environment
            environment["NO_COLOR"] = "1"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    /// claude.ai connectors are added on the web; Claude Code picks them up from the account.
    static func openClaudeConnectors() {
        if let url = URL(string: "https://claude.ai/settings/connectors") { NSWorkspace.shared.open(url) }
    }

    /// Adds a hosted connector to OpenCode's config, then starts its sign-in (it opens the browser).
    static func addToOpenCode(_ connector: BotConnector) async -> String {
        guard let name = connector.openCodeServer, let url = connector.openCodeURL else {
            return "\(connector.name) can't be added to OpenCode from here."
        }
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode/opencode.json")
        var root = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? ["$schema": "https://opencode.ai/config.json"]
        var servers = root["mcp"] as? [String: Any] ?? [:]
        if servers[name] == nil {
            servers[name] = ["type": "remote", "url": url, "enabled": true]
            root["mcp"] = servers
            try? FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
                  (try? data.write(to: config, options: .atomic)) != nil else {
                return "Couldn't update OpenCode's config."
            }
        }
        guard let executable = BrainCLIRunner.locateExecutable(for: .opencode) else { return "OpenCode isn't installed." }
        return await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["mcp", "auth", name]
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "Couldn't start OpenCode's sign-in." }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = stripANSI(String(data: data, encoding: .utf8) ?? "")
            return process.terminationStatus == 0
                ? "\(connector.name) is added to OpenCode. Finish signing in in your browser if it asked."
                : "OpenCode sign-in for \(connector.name) didn't finish: \(output.suffix(160))"
        }.value
    }
}
