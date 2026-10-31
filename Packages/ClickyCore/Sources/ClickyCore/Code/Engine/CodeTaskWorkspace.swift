//
//  CodeTaskWorkspace.swift
//  ClickyCore
//
//  The folders of one code task under ~/.clicky/code/<task>/: ctx/ (what
//  the agent may read: PR text, threads, CI logs, rules.md), outbox/ (the
//  bodies Clicky will send — the agent can neither read nor write it), an
//  empty gh config dir for the agent, state.json (the ExecutionPlan) and
//  commands.log. Every folder is 0700 and every file 0600.
//

import Foundation

public struct CodeTaskWorkspace: Sendable {
    public let taskIdentifier: String
    public let taskDirectoryURL: URL

    public var contextDirectoryURL: URL { taskDirectoryURL.appendingPathComponent("ctx", isDirectory: true) }
    public var outboxDirectoryURL: URL { taskDirectoryURL.appendingPathComponent("outbox", isDirectory: true) }
    public var emptyGHConfigDirectoryURL: URL { taskDirectoryURL.appendingPathComponent("gh-empty", isDirectory: true) }
    public var stateFileURL: URL { taskDirectoryURL.appendingPathComponent(ExecutionPlan.stateFileName) }
    public var commandLogURL: URL { taskDirectoryURL.appendingPathComponent("commands.log") }
    public var agentTranscriptURL: URL { taskDirectoryURL.appendingPathComponent("agent.jsonl") }

    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/code", isDirectory: true)
    }

    /// "20261025-130512-a1b2".
    public static func makeTaskIdentifier(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date) + "-" + randomHex(count: 4)
    }

    public static func randomHex(count: Int) -> String {
        String((0..<count).map { _ in "0123456789abcdef".randomElement()! })
    }

    /// Creates the folders (0700).
    public static func create(rootURL: URL = defaultRootURL, taskIdentifier: String = makeTaskIdentifier()) throws -> CodeTaskWorkspace {
        let workspace = CodeTaskWorkspace(taskIdentifier: taskIdentifier, taskDirectoryURL: rootURL.appendingPathComponent(taskIdentifier, isDirectory: true))
        for directoryURL in [rootURL, workspace.taskDirectoryURL, workspace.contextDirectoryURL, workspace.outboxDirectoryURL, workspace.emptyGHConfigDirectoryURL] {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        }
        return workspace
    }

    public init(taskIdentifier: String, taskDirectoryURL: URL) {
        self.taskIdentifier = taskIdentifier
        self.taskDirectoryURL = taskDirectoryURL
    }

    // MARK: - Files

    @discardableResult
    public func writeContextFile(_ name: String, _ text: String) throws -> URL {
        try Self.writePrivateFile(contextDirectoryURL.appendingPathComponent(Self.safeFileName(name)), text)
    }

    @discardableResult
    public func writeOutboxFile(_ name: String, _ text: String) throws -> URL {
        try Self.writePrivateFile(outboxDirectoryURL.appendingPathComponent(Self.safeFileName(name)), text)
    }

    public func outboxFileURL(_ name: String) -> URL {
        outboxDirectoryURL.appendingPathComponent(Self.safeFileName(name))
    }

    public func readOutboxFile(_ name: String) -> String? {
        try? String(contentsOf: outboxFileURL(name), encoding: .utf8)
    }

    @discardableResult
    public static func writePrivateFile(_ fileURL: URL, _ text: String) throws -> URL {
        try Data(text.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return fileURL
    }

    /// Letters, digits, ".", "-", "_" only; never a path.
    public static func safeFileName(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.map { scalar -> Character in
            (CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII) || scalar == "." || scalar == "-" || scalar == "_" ? Character(scalar) : "_"
        })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "file" : trimmed
    }
}
