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

    public init(model: String, systemPromptFileURL: URL, effortLevel: String? = nil, persistentSessionIdentifier: String? = nil, inlineSystemPrompt: String? = nil) {
        self.model = model
        self.systemPromptFileURL = systemPromptFileURL
        self.effortLevel = effortLevel
        self.persistentSessionIdentifier = persistentSessionIdentifier
        self.inlineSystemPrompt = inlineSystemPrompt
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
        return commandArguments
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
