//
//  AgentInitValidator.swift
//  ClickyCore
//
//  Checks the agent's first stream-json event (type "system", subtype
//  "init") against what we asked for: acceptEdits, exactly the expected
//  tools (plus whatever the preflight probe showed can't be removed), no
//  MCP servers, no plugins, the same apiKeySource as the probe and the
//  worktree as cwd. Any plugin at all fails it: AgentInvocation switches
//  them off, and one that still loads could add tools, hooks or MCP
//  servers. Any failure — or no init within 30 s — and the app
//  SIGKILLs the agent before it does anything.
//

import Foundation

public struct AgentInitExpectation: Equatable, Sendable {
    public var permissionMode: String
    public var expectedTools: Set<String>
    /// Tools the probe saw even with --tools restricted (empty on current CLIs).
    public var unremovableTools: Set<String>
    /// The probe's apiKeySource (e.g. "none" for OAuth).
    public var apiKeySource: String
    public var worktreePath: String

    public init(permissionMode: String = AgentInvocation.permissionMode, expectedTools: Set<String>, unremovableTools: Set<String> = [], apiKeySource: String, worktreePath: String) {
        self.permissionMode = permissionMode
        self.expectedTools = expectedTools
        self.unremovableTools = unremovableTools
        self.apiKeySource = apiKeySource
        self.worktreePath = worktreePath
    }
}

public enum AgentInitFailure: Equatable, Sendable, CustomStringConvertible {
    case notAnInitEvent
    case permissionMode(found: String?)
    case tools(unexpected: [String], missing: [String])
    case mcpServers([String])
    case plugins([String])
    case apiKeySource(found: String?)
    case workingDirectory(found: String?)

    public var description: String {
        switch self {
        case .notAnInitEvent: return "first event is not system/init"
        case .permissionMode(let found): return "permissionMode is \(found ?? "missing")"
        case .tools(let unexpected, let missing): return "tools differ (unexpected: \(unexpected.joined(separator: ", ")); missing: \(missing.joined(separator: ", ")))"
        case .mcpServers(let names): return "MCP servers loaded: \(names.joined(separator: ", "))"
        case .plugins(let names): return "plugins loaded: \(names.joined(separator: ", ")) (Clicky's coding agent only runs with no plugins; if this repo's .claude/settings.json turns plugins on, remove them there)"
        case .apiKeySource(let found): return "apiKeySource is \(found ?? "missing")"
        case .workingDirectory(let found): return "cwd is \(found ?? "missing")"
        }
    }
}

public enum AgentInitValidator {
    /// No init event within this many seconds → SIGKILL.
    public static let initTimeout: TimeInterval = 30

    /// Empty means OK.
    public static func validate(initEvent: [String: Any], expectation: AgentInitExpectation) -> [AgentInitFailure] {
        guard initEvent["type"] as? String == "system", initEvent["subtype"] as? String == "init" else { return [.notAnInitEvent] }
        var failures: [AgentInitFailure] = []

        let permissionMode = initEvent["permissionMode"] as? String
        if permissionMode != expectation.permissionMode { failures.append(.permissionMode(found: permissionMode)) }

        let reportedTools = Set(initEvent["tools"] as? [String] ?? [])
        let allowedTools = expectation.expectedTools.union(expectation.unremovableTools)
        if reportedTools != allowedTools || initEvent["tools"] as? [String] == nil {
            failures.append(.tools(unexpected: reportedTools.subtracting(allowedTools).sorted(), missing: allowedTools.subtracting(reportedTools).sorted()))
        }

        let mcpServerNames = namedEntries(initEvent["mcp_servers"])
        if !mcpServerNames.isEmpty { failures.append(.mcpServers(mcpServerNames)) }

        let pluginNames = namedEntries(initEvent["plugins"])
        if !pluginNames.isEmpty { failures.append(.plugins(pluginNames)) }

        let apiKeySource = initEvent["apiKeySource"] as? String
        if apiKeySource != expectation.apiKeySource { failures.append(.apiKeySource(found: apiKeySource)) }

        let workingDirectory = initEvent["cwd"] as? String
        if workingDirectory.map(resolvedPath) != resolvedPath(expectation.worktreePath) { failures.append(.workingDirectory(found: workingDirectory)) }

        return failures
    }

    /// Names from an array of {"name": …} objects or strings; a non-array non-nil value counts as one unknown entry.
    static func namedEntries(_ value: Any?) -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        guard let entries = value as? [Any] else { return ["<unreadable>"] }
        return entries.map { entry in
            if let name = entry as? String { return name }
            if let object = entry as? [String: Any], let name = object["name"] as? String { return name }
            return "<unnamed>"
        }
    }

    /// "name@marketplace" per plugin entry (its "source"; the name when there is none).
    public static func pluginSources(_ value: Any?) -> [String] {
        guard let entries = value as? [Any] else { return namedEntries(value) }
        return entries.map { entry in
            if let object = entry as? [String: Any] { return (object["source"] as? String) ?? (object["name"] as? String) ?? "<unnamed>" }
            return (entry as? String) ?? "<unnamed>"
        }
    }

    static func resolvedPath(_ path: String) -> String {
        var resolved = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        if resolved.hasPrefix("/private/") { resolved.removeFirst("/private".count) }
        while resolved.count > 1 && resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }
}
