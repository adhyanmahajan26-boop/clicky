//
//  ClaudeArgs.swift
//  ClickyCore
//
//  The one place the `claude` command line is built, shared by the main
//  brain, Haiku workers and probes, so every call runs isolated the same way:
//  no tools, no MCP, no skills, no hooks, user settings only, no saved
//  session, a system prompt from a 0600 file, from an empty working
//  directory outside $HOME (so no project CLAUDE.md is picked up).
//

import Foundation

public struct ClaudeArgs: Sendable {
    public var model: String
    public var systemPromptFileURL: URL
    public var effortLevel: String?
    /// Probes only: keep a transcript under a known session id.
    public var persistentSessionIdentifier: String?
    /// When the CLI rejects --system-prompt-file, pass the text inline instead.
    public var inlineSystemPrompt: String?
    /// One-shot checks (P6.1 zoom check): --max-turns (hidden from --help, accepted).
    public var maximumTurns: Int?

    public init(model: String, systemPromptFileURL: URL, effortLevel: String? = nil, persistentSessionIdentifier: String? = nil,
                inlineSystemPrompt: String? = nil, maximumTurns: Int? = nil) {
        self.model = model
        self.systemPromptFileURL = systemPromptFileURL
        self.effortLevel = effortLevel
        self.persistentSessionIdentifier = persistentSessionIdentifier
        self.inlineSystemPrompt = inlineSystemPrompt
        self.maximumTurns = maximumTurns
    }

    public var arguments: [String] {
        var commandArguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model
        ]
        if let inlineSystemPrompt {
            commandArguments += ["--system-prompt", inlineSystemPrompt]
        } else {
            commandArguments += ["--system-prompt-file", systemPromptFileURL.path]
        }
        commandArguments += [
            "--tools", "",
            "--strict-mcp-config",
            "--disable-slash-commands"
        ]
        if let persistentSessionIdentifier {
            commandArguments += ["--session-id", persistentSessionIdentifier]
        } else {
            commandArguments += ["--no-session-persistence"]
        }
        commandArguments += [
            "--setting-sources", "user",
            "--settings", #"{"disableAllHooks":true}"#
        ]
        if let effortLevel {
            commandArguments += ["--effort", effortLevel]
        }
        if let maximumTurns {
            commandArguments += ["--max-turns", String(maximumTurns)]
        }
        return commandArguments
    }

    /// Code-mode preflight: one cheap headless turn with no tools, so its
    /// system/init shows which tools can't be removed and which apiKeySource
    /// the agent will see. Run from the empty session working directory.
    /// --max-turns is hidden from `claude --help`; this run proves it works.
    /// Same plugin isolation as the agent: no settings files, every plugin
    /// it reports switched off, no skills. A plugin that still shows up here
    /// would make the agent's init fail.
    public static func preflightProbeArguments(disabling disabledPluginSources: [String] = AgentInvocation.builtinPluginSources, disablesSkills: Bool = true) -> [String] {
        let probeSettings: [String: Any] = ["disableAllHooks": true, "enabledPlugins": AgentInvocation.disabledPluginsObject(disabledPluginSources)]
        return [
            "-p", "Reply OK",
            "--tools", "",
            "--max-turns", "1",
            "--output-format", "stream-json",
            "--verbose",
            "--strict-mcp-config",
            "--no-session-persistence",
            // The helper can be another engine's model when the brain isn't Claude; this probe is Claude's.
            "--model", ClickyModels.helper.hasPrefix("claude") ? ClickyModels.helper : ClickyModels.haiku,
            "--setting-sources", ""
        ] + (disablesSkills ? ["--disable-slash-commands"] : []) + [
            "--settings", AgentInvocation.jsonString(probeSettings)
        ]
    }

    public static var preflightProbeArguments: [String] { preflightProbeArguments(disabling: AgentInvocation.builtinPluginSources) }

    /// The process environment for every call: the app's own, plus
    /// CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 so the user's ~/.claude/CLAUDE.md (and
    /// any project/auto memory) is not injected into Clicky's context.
    /// Documented: code.claude.com/docs/en/env-vars ("prevent loading any
    /// CLAUDE.md memory files into context"); unlike --bare it keeps OAuth.
    public static func environment(base baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var callEnvironment = baseEnvironment
        callEnvironment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
        if let apiKey = ClickySettings.anthropicAPIKeyForCalls { callEnvironment["ANTHROPIC_API_KEY"] = apiKey }
        return callEnvironment
    }

    /// `$TMPDIR/clicky-session`: the working directory for every call.
    public static var sessionWorkingDirectoryURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clicky-session", isDirectory: true)
    }

    /// `~/.clicky/session`, holding the prompt files (0700 directory).
    public static var promptDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/session", isDirectory: true)
    }

    /// Recreates the working directory empty, so nothing left behind by a
    /// previous call can be read as project context.
    public static func prepareSessionWorkingDirectory() throws -> URL {
        let workingDirectoryURL = sessionWorkingDirectoryURL
        try? FileManager.default.removeItem(at: workingDirectoryURL)
        try FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
        return workingDirectoryURL
    }

    /// Writes a prompt file (0600 in a 0700 directory), only when it changed.
    public static func writePromptFile(named fileName: String, contents promptText: String) throws -> URL {
        let promptDirectoryURL = promptDirectoryURL
        try FileManager.default.createDirectory(at: promptDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: promptDirectoryURL.path)
        let promptFileURL = promptDirectoryURL.appendingPathComponent(fileName)
        if (try? String(contentsOf: promptFileURL, encoding: .utf8)) != promptText {
            try Data(promptText.utf8).write(to: promptFileURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptFileURL.path)
        return promptFileURL
    }
}
