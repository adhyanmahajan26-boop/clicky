//
//  HardenedGit.swift
//  ClickyCore
//
//  Every git command Clicky itself runs on a repo the agent may have
//  touched. Each call carries `-c core.fsmonitor=false -c
//  core.hooksPath=/dev/null -c protocol.ext.allow=never`, so a planted
//  fsmonitor, hook or ext:: remote can't run code as Clicky; subcommands that
//  accept them also get --no-verify / --no-ext-diff --no-textconv. Commands
//  that talk to GitHub use gh as the only credential helper (the user's own
//  helpers are cleared first).
//

import Foundation

public struct HardenedGit: Sendable {
    public static let safetyConfiguration = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never"]
    public static let defaultTimeoutSeconds: TimeInterval = 120
    public static let networkTimeoutSeconds: TimeInterval = 300

    public var gitPath: String
    public var ghPath: String
    public var runner: CodeCommandRunning
    public var environment: [String: String]

    public init(gitPath: String, ghPath: String, runner: CodeCommandRunning, environment: [String: String] = CodeCommandEnvironment.forClickyCommands()) {
        self.gitPath = gitPath
        self.ghPath = ghPath
        self.runner = runner
        self.environment = environment
    }

    /// `-c credential.helper= -c credential.helper=!<gh> auth git-credential`.
    public var githubCredentialConfiguration: [String] {
        ["-c", "credential.helper=", "-c", "credential.helper=!\(ghPath) auth git-credential"]
    }

    /// The argv after `git`, for display (panel, ApprovalKey) and running.
    public func arguments(_ subcommandArguments: [String], in repositoryPath: String, usesGitHubCredentials: Bool = false) -> [String] {
        ["-C", repositoryPath] + Self.safetyConfiguration + (usesGitHubCredentials ? githubCredentialConfiguration : []) + subcommandArguments
    }

    public func run(_ subcommandArguments: [String], in repositoryPath: String, usesGitHubCredentials: Bool = false,
                    timeoutSeconds: TimeInterval = defaultTimeoutSeconds) async throws -> CodeCommandOutput {
        try await runner.run(executable: gitPath, arguments: arguments(subcommandArguments, in: repositoryPath, usesGitHubCredentials: usesGitHubCredentials),
                             workingDirectory: repositoryPath, environment: environment, timeoutSeconds: timeoutSeconds)
    }

    /// Runs and throws unless it exited 0.
    @discardableResult
    public func runChecked(_ subcommandArguments: [String], in repositoryPath: String, usesGitHubCredentials: Bool = false,
                           timeoutSeconds: TimeInterval = defaultTimeoutSeconds) async throws -> CodeCommandOutput {
        let output = try await run(subcommandArguments, in: repositoryPath, usesGitHubCredentials: usesGitHubCredentials, timeoutSeconds: timeoutSeconds)
        guard output.succeeded else {
            throw CodeCommandError.failed(command: "git " + (subcommandArguments.first ?? ""), exitStatus: output.exitStatus, message: output.shortError)
        }
        return output
    }

    /// Trimmed stdout of a successful command, nil otherwise.
    public func value(_ subcommandArguments: [String], in repositoryPath: String) async -> String? {
        guard let output = try? await run(subcommandArguments, in: repositoryPath), output.succeeded else { return nil }
        let value = output.trimmedOutput
        return value.isEmpty ? nil : value
    }

    // MARK: - Common reads

    public func headOID(in repositoryPath: String) async -> String? {
        await value(["rev-parse", "--verify", "HEAD^{commit}"], in: repositoryPath)
    }

    public func remoteURL(named remoteName: String, in repositoryPath: String) async -> String? {
        await value(["config", "--get", "remote.\(remoteName).url"], in: repositoryPath)
    }

    /// The shared .git directory (the main clone's, also from a worktree), absolute.
    public func commonGitDirectory(in repositoryPath: String) async -> String? {
        guard let commonDirectory = await value(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repositoryPath) else { return nil }
        return commonDirectory
    }

    /// The worktree's own git dir (…/.git/worktrees/<name> for a linked worktree), absolute.
    public func gitDirectory(in repositoryPath: String) async -> String? {
        await value(["rev-parse", "--path-format=absolute", "--git-dir"], in: repositoryPath)
    }

    public func currentBranch(in repositoryPath: String) async -> String? {
        await value(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repositoryPath)
    }

    /// True when `status --porcelain` is empty (untracked files count as dirty).
    public func isClean(_ repositoryPath: String) async -> Bool {
        guard let output = try? await run(["status", "--porcelain", "--untracked-files=normal"], in: repositoryPath), output.succeeded else { return false }
        return output.trimmedOutput.isEmpty
    }

    /// `git diff` with external diff drivers and textconv off.
    public func diff(_ revisionArguments: [String], in repositoryPath: String) async throws -> String {
        try await runChecked(["diff", "--no-ext-diff", "--no-textconv", "--no-color"] + revisionArguments, in: repositoryPath).standardOutput
    }

    /// The OID a remote ref points at right now (nil when the ref doesn't exist).
    public func lsRemote(url remoteURL: String, ref: String, in repositoryPath: String) async throws -> String? {
        let output = try await runChecked(["ls-remote", "--", remoteURL, ref], in: repositoryPath, usesGitHubCredentials: true, timeoutSeconds: Self.networkTimeoutSeconds)
        for line in output.standardOutput.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            if fields.count == 2, fields[1] == ref { return String(fields[0]) }
        }
        return nil
    }
}

/// `git push --porcelain` output, line by line.
public struct GitPushPorcelain: Equatable, Sendable {
    public enum Flag: Character, Sendable {
        case fastForward = " "
        case forced = "+"
        case deleted = "-"
        case new = "*"
        case rejected = "!"
        case upToDate = "="
    }

    public struct RefLine: Equatable, Sendable {
        public var flag: Flag
        public var from: String
        public var to: String
        public var summary: String
    }

    public var refLines: [RefLine]

    public static func parse(_ porcelainOutput: String) -> GitPushPorcelain {
        var refLines: [RefLine] = []
        for line in porcelainOutput.components(separatedBy: "\n") {
            guard let firstCharacter = line.first, let flag = Flag(rawValue: firstCharacter), line.dropFirst().first == "\t" else { continue }
            let fields = line.dropFirst(2).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let refPair = fields.first else { continue }
            let refParts = refPair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            refLines.append(RefLine(flag: flag, from: refParts.first ?? "", to: refParts.count > 1 ? refParts[1] : "", summary: fields.count > 1 ? fields[1] : ""))
        }
        return GitPushPorcelain(refLines: refLines)
    }

    public enum Verdict: Equatable, Sendable {
        case ok
        /// A "!" line: rejected; stop.
        case rejected(String)
        /// A "+" (forced) or "-" (deleted) line: must never happen.
        case fatal(String)
        case noRefLine
    }

    public var verdict: Verdict {
        if let fatalLine = refLines.first(where: { $0.flag == .forced || $0.flag == .deleted }) {
            return .fatal("\(fatalLine.flag == .forced ? "forced update" : "deletion") of \(fatalLine.to)")
        }
        if let rejectedLine = refLines.first(where: { $0.flag == .rejected }) { return .rejected("\(rejectedLine.to): \(rejectedLine.summary)") }
        return refLines.isEmpty ? .noRefLine : .ok
    }
}
