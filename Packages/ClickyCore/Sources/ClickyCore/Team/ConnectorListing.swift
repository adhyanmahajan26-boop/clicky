//
//  ConnectorListing.swift
//  ClickyCore
//
//  Reads `claude mcp list` and `opencode mcp list` into one status per server. The wording was checked against real
//  output on 13 Nov 2026 (Tests/ClickyCoreTests/Fixtures/mcp): a server that is listed but not answering is `failed`
//  with its reason, which is different from one that was never set up (`missing`) or one that wants a sign-in.
//
//  claude:   "claude.ai Gmail: https://… - ✔ Connected"
//            "claude.ai Runway (runway.team): https://… - ! Needs authentication"
//            "broken-http: http://127.0.0.1:9/mcp (HTTP) - ✘ Failed to connect — ECONNREFUSED: Unable to connect. …"
//            "broken-stdio: /usr/bin/false  - ⏸ Pending approval (run `claude` to approve)"
//  opencode: "●  ✓ theo connected" / "●  ✗ broken-stdio failed" + "│      MCP error -32000: Connection closed"
//            "●  ⚠ notion needs authentication" / "●  ○ off-server disabled"
//

import Foundation

public enum ConnectorState: Equatable, Sendable {
    case connected, needsSignIn, failed(String), missing, unknown

    public var label: String {
        switch self {
        case .connected: return "Connected"
        case .needsSignIn: return "Needs sign-in"
        case .failed: return "Can't connect"
        case .missing: return "Not connected"
        case .unknown: return "Checking"
        }
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The raw reason a failed server gave, for See details.
    public var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

public enum ConnectorListing {
    public static func parseClaude(_ listing: String) -> [String: ConnectorState] {
        var statuses: [String: ConnectorState] = [:]
        for raw in stripANSI(listing).split(separator: "\n") {
            let line = String(raw)
            // The status starts at " - " followed by its mark; a failure reason after it can contain " - " of its own.
            let marked = line.range(of: #" - [✔✘!⏸]"#, options: .regularExpression)
            guard let colon = line.range(of: ": "), let dash = marked ?? line.range(of: " - ", options: .backwards), dash.lowerBound > colon.lowerBound else { continue }
            let name = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let status = line[line.index(dash.lowerBound, offsetBy: 3)...].trimmingCharacters(in: .whitespaces)
            if status.hasPrefix("✔") || status.lowercased().hasPrefix("connected") {
                statuses[name] = .connected
            } else if status.localizedCaseInsensitiveContains("needs authentication") {
                statuses[name] = .needsSignIn
            } else if status.hasPrefix("✘") || status.localizedCaseInsensitiveContains("failed") {
                statuses[name] = .failed(reason(after: status, marker: "Failed to connect"))
            } else {
                // Pending approval, disabled, or anything new: set up but not usable, and nothing a retry fixes.
                statuses[name] = .missing
            }
        }
        return statuses
    }

    public static func parseOpenCode(_ listing: String) -> [String: ConnectorState] {
        var statuses: [String: ConnectorState] = [:]
        let lines = stripANSI(listing).split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix("●") {
            let words = line.dropFirst().split(separator: " ").map(String.init)
            guard words.count >= 2 else { continue }
            let mark = words[0]
            let name = words[1]
            let rest = words.dropFirst(2).joined(separator: " ").lowercased()
            if mark == "✓" || rest == "connected" {
                statuses[name] = .connected
            } else if rest.contains("auth") {
                statuses[name] = .needsSignIn
            } else if mark == "✗" || rest.contains("failed") {
                // The reason is the first detail line under the server, before its command.
                let detail = index + 1 < lines.count ? lines[index + 1] : ""
                let reason = detail.hasPrefix("│") ? detail.dropFirst().trimmingCharacters(in: .whitespaces) : ""
                statuses[name] = .failed(reason.isEmpty ? "It didn't answer." : reason)
            } else {
                statuses[name] = .missing
            }
        }
        return statuses
    }

    private static func reason(after status: String, marker: String) -> String {
        var text = status
        if let range = text.range(of: marker) { text = String(text[range.upperBound...]) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " —-:✘"))
        return text.isEmpty ? "It didn't answer." : text
    }

    /// A raw failure as one plain sentence: what the owner would say, not the error code.
    public static func plainReason(_ raw: String, app: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("econnrefused") || lower.contains("unable to connect") || lower.contains("timed out") || lower.contains("timeout") {
            return "\(app) didn't answer."
        }
        if lower.contains("enoent") || lower.contains("no such file") { return "\(app)'s program isn't on this Mac any more." }
        if lower.contains("connection closed") || lower.contains("connection_closed") { return "\(app) closed the connection as soon as it started." }
        if lower.contains("401") || lower.contains("403") || lower.contains("unauthorized") { return "\(app) turned the sign-in down." }
        return "\(app) isn't answering."
    }

    public static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// "worked 2 h ago", for a failed row that used to work.
    public static func workedAgo(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return "worked a minute ago" }
        if seconds < 3600 { return "worked \(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "worked \(Int(seconds / 3600)) h ago" }
        return "worked \(Int(seconds / 86400)) d ago"
    }
}
