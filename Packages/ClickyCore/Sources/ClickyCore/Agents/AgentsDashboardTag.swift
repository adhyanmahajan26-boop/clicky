//
//  AgentsDashboardTag.swift
//  ClickyCore
//
//  [AGENTS:open]: the main brain asks the app to open the Agents dashboard
//  ("show agents", "open the agents dashboard"). The ResponseRouter emits it
//  as .agentsDashboard and strips it from speech, like [CODEMODE:on].
//  Opening a window is local and harmless, so the tag alone is enough.
//

import Foundation

public enum AgentsDashboardTag {
    public static let openTag = "[AGENTS:open]"

    /// One line for the main system prompt.
    public static let promptLine = "agents dashboard: when the user asks to see what you or your helpers are doing (\"show agents\", \"open the agents dashboard\"), say a short line like \"here are your agents.\" and add [AGENTS:open]. the tag is never spoken."

    public enum Command: String, Equatable, Sendable {
        case open
    }

    /// "[AGENTS:open]" (any case, "show" also means open) → .open; anything else nil.
    public static func parse(_ rawTag: String) -> Command? {
        var body = rawTag.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("["), body.hasSuffix("]") else { return nil }
        body = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard body.uppercased().hasPrefix("AGENTS:") else { return nil }
        let value = body.dropFirst("AGENTS:".count).trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "open", "show": return .open
        default: return nil
        }
    }
}
