//
//  CodeOutwardStepRunner.swift
//  ClickyCore
//
//  The ExecutionPlan's real steps, run only after the user's click. Before
//  every single command the ApprovalKey is rebuilt from disk (argv, body
//  files, acks, reviewed OID) and compared with the approved one; any
//  difference aborts. Push: the remote ref must still be the head we
//  reviewed on top of (or absent, for a new branch), then `push --porcelain
//  <url> <REVIEW_OID>:refs/heads/<ref>` with gh as the only credential
//  helper; a "!" line stops, a "+" (forced) or "-" (deleted) line is fatal.
//  Replies and resolves are GraphQL mutations with the body read by gh from
//  the outbox file. PR create runs only if no open PR has that head.
//

import Foundation

/// Everything one approval sends, in plan order.
public struct OutwardDelivery: Equatable, Sendable {
    public struct PushTarget: Equatable, Sendable {
        public var repositoryPath: String
        public var remoteURL: String
        /// Branch name on the remote (no refs/heads/).
        public var branch: String
        /// The remote ref must equal this before pushing; nil = it must not exist yet.
        public var expectedRemoteOID: String?
        public var reviewOID: String
        /// Fork this repo first (no push rights on the base).
        public var forkFrom: GitHubRemote?

        public init(repositoryPath: String, remoteURL: String, branch: String, expectedRemoteOID: String?, reviewOID: String, forkFrom: GitHubRemote? = nil) {
            self.repositoryPath = repositoryPath
            self.remoteURL = remoteURL
            self.branch = branch
            self.expectedRemoteOID = expectedRemoteOID
            self.reviewOID = reviewOID
            self.forkFrom = forkFrom
        }
    }

    public struct ThreadReply: Equatable, Sendable {
        public var threadIdentifier: String
        public var bodyFilePath: String

        public init(threadIdentifier: String, bodyFilePath: String) {
            self.threadIdentifier = threadIdentifier
            self.bodyFilePath = bodyFilePath
        }
    }

    public struct PullRequestCreation: Equatable, Sendable {
        public var base: String
        /// "branch" or "owner:branch" (from a fork).
        public var head: String
        public var headBranch: String
        public var title: String
        public var bodyFilePath: String

        public init(base: String, head: String, headBranch: String, title: String, bodyFilePath: String) {
            self.base = base
            self.head = head
            self.headBranch = headBranch
            self.title = title
            self.bodyFilePath = bodyFilePath
        }
    }

    public var repository: GitHubRemote
    public var pullRequestNumber: Int?
    public var reviewOID: String
    public var push: PushTarget?
    public var replies: [ThreadReply]
    public var resolveThreadIdentifiers: [String]
    public var commentBodyFilePath: String?
    public var pullRequestCreation: PullRequestCreation?

    public init(repository: GitHubRemote, pullRequestNumber: Int?, reviewOID: String, push: PushTarget? = nil, replies: [ThreadReply] = [],
                resolveThreadIdentifiers: [String] = [], commentBodyFilePath: String? = nil, pullRequestCreation: PullRequestCreation? = nil) {
        self.repository = repository
        self.pullRequestNumber = pullRequestNumber
        self.reviewOID = reviewOID
        self.push = push
        self.replies = replies
        self.resolveThreadIdentifiers = resolveThreadIdentifiers
        self.commentBodyFilePath = commentBodyFilePath
        self.pullRequestCreation = pullRequestCreation
    }

    public var stepKinds: [OutwardStepKind] {
        var kinds: [OutwardStepKind] = []
        if push != nil { kinds.append(.push) }
        if !replies.isEmpty { kinds.append(.replies) }
        if !resolveThreadIdentifiers.isEmpty { kinds.append(.resolves) }
        if commentBodyFilePath != nil, pullRequestNumber != nil { kinds.append(.comment) }
        if pullRequestCreation != nil { kinds.append(.prCreate) }
        return kinds
    }

    public var bodyFilePaths: [String] {
        replies.map(\.bodyFilePath) + [commentBodyFilePath, pullRequestCreation?.bodyFilePath].compactMap { $0 }
    }
}

/// One command an approval runs, for the panel (quoted) and the ApprovalKey.
public struct OutwardCommand: Equatable, Sendable {
    public var step: OutwardStepKind?
    public var gatedAction: GatedAction
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?

    public init(step: OutwardStepKind?, gatedAction: GatedAction, executable: String, arguments: [String], workingDirectory: String?) {
        self.step = step
        self.gatedAction = gatedAction
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    public var argv: [String] { [executable] + arguments }
    public var quoted: String { ShellQuoting.quote(argv) }
}

public enum OutwardStepError: Error, Equatable, Sendable, CustomStringConvertible {
    case approvalMismatch
    case remoteMoved(expected: String?, found: String?)
    case pushRejected(String)
    case pushFatal(String)
    case pushFailed(String)
    case pullRequestAlreadyOpen(String)
    case commandFailed(String)
    case invalidThreadIdentifier(String)

    public var description: String {
        switch self {
        case .approvalMismatch: return "what's on disk no longer matches what you approved"
        case .remoteMoved(let expected, let found): return "the remote branch moved (expected \(expected?.prefix(7) ?? "none"), found \(found?.prefix(7) ?? "none"))"
        case .pushRejected(let message): return "push rejected: \(message)"
        case .pushFatal(let message): return "push did something it must never do: \(message)"
        case .pushFailed(let message): return "push failed: \(message)"
        case .pullRequestAlreadyOpen(let url): return "a PR for this branch is already open: \(url)"
        case .commandFailed(let message): return message
        case .invalidThreadIdentifier(let identifier): return "bad thread id \(identifier)"
        }
    }
}

public final class CodeOutwardStepRunner: OutwardStepRunner, @unchecked Sendable {
    public let delivery: OutwardDelivery
    public let git: HardenedGit
    public let ghPath: String
    public let runner: CodeCommandRunning
    public let environment: [String: String]
    public let approvedKey: ApprovalKey
    public let acks: [String]
    public private(set) var createdPullRequestURL: String?
    public private(set) var pushedOID: String?

    public init(delivery: OutwardDelivery, git: HardenedGit, ghPath: String, runner: CodeCommandRunning, environment: [String: String],
                approvedKey: ApprovalKey, acks: [String]) {
        self.delivery = delivery
        self.git = git
        self.ghPath = ghPath
        self.runner = runner
        self.environment = environment
        self.approvedKey = approvedKey
        self.acks = acks
    }

    // MARK: - Commands as data

    /// Every command this delivery may run, in order (shown in the panel, hashed into the key).
    public static func commands(for delivery: OutwardDelivery, git: HardenedGit, ghPath: String) -> [OutwardCommand] {
        var commands: [OutwardCommand] = []
        if let push = delivery.push {
            if let forkFrom = push.forkFrom {
                commands.append(OutwardCommand(step: .push, gatedAction: .fork, executable: ghPath, arguments: GitHubCommands.fork(forkFrom), workingDirectory: nil))
            }
            commands.append(OutwardCommand(step: .push, gatedAction: .push, executable: git.gitPath,
                                           arguments: git.arguments(["ls-remote", "--", push.remoteURL, "refs/heads/\(push.branch)"], in: push.repositoryPath, usesGitHubCredentials: true),
                                           workingDirectory: push.repositoryPath))
            commands.append(OutwardCommand(step: .push, gatedAction: .push, executable: git.gitPath,
                                           arguments: git.arguments(pushArguments(push), in: push.repositoryPath, usesGitHubCredentials: true),
                                           workingDirectory: push.repositoryPath))
        }
        for reply in delivery.replies {
            commands.append(OutwardCommand(step: .replies, gatedAction: .reply, executable: ghPath,
                                           arguments: GitHubCommands.replyToThread(threadIdentifier: reply.threadIdentifier, bodyFilePath: reply.bodyFilePath), workingDirectory: nil))
        }
        for threadIdentifier in delivery.resolveThreadIdentifiers {
            commands.append(OutwardCommand(step: .resolves, gatedAction: .resolve, executable: ghPath,
                                           arguments: GitHubCommands.resolveThread(threadIdentifier: threadIdentifier), workingDirectory: nil))
        }
        if let commentBodyFilePath = delivery.commentBodyFilePath, let number = delivery.pullRequestNumber {
            commands.append(OutwardCommand(step: .comment, gatedAction: .comment, executable: ghPath,
                                           arguments: GitHubCommands.comment(delivery.repository, number: number, bodyFilePath: commentBodyFilePath), workingDirectory: nil))
        }
        if let creation = delivery.pullRequestCreation {
            commands.append(OutwardCommand(step: .prCreate, gatedAction: .prCreate, executable: ghPath,
                                           arguments: GitHubCommands.openPullRequests(delivery.repository, headBranch: creation.headBranch), workingDirectory: nil))
            commands.append(OutwardCommand(step: .prCreate, gatedAction: .prCreate, executable: ghPath,
                                           arguments: GitHubCommands.createPullRequest(delivery.repository, base: creation.base, head: creation.head,
                                                                                       title: creation.title, bodyFilePath: creation.bodyFilePath), workingDirectory: nil))
        }
        return commands
    }

    static func pushArguments(_ push: OutwardDelivery.PushTarget) -> [String] {
        ["push", "--porcelain", "--no-verify", "--", push.remoteURL, "\(push.reviewOID):refs/heads/\(push.branch)"]
    }

    public static func approvalMaterial(for delivery: OutwardDelivery, git: HardenedGit, ghPath: String, acks: [String]) throws -> ApprovalMaterial {
        try ApprovalMaterial.reading(reviewOID: delivery.reviewOID, actionArguments: commands(for: delivery, git: git, ghPath: ghPath).map(\.argv),
                                     bodyFilePaths: delivery.bodyFilePaths, acks: acks)
    }

    // MARK: - OutwardStepRunner

    public func verifyApproval() throws {
        let isStillApproved = approvedKey.verifyBeforeAction(reviewOID: delivery.reviewOID,
                                                             actionArguments: Self.commands(for: delivery, git: git, ghPath: ghPath).map(\.argv),
                                                             bodyFilePaths: delivery.bodyFilePaths, acks: acks)
        guard isStillApproved else { throw OutwardStepError.approvalMismatch }
    }

    public func run(_ step: OutwardStepKind) async throws {
        let stepCommands = Self.commands(for: delivery, git: git, ghPath: ghPath).filter { $0.step == step }
        switch step {
        case .push:
            guard let push = delivery.push else { return }
            try await runPush(push, commands: stepCommands)
        case .replies:
            for reply in delivery.replies where !GitHubCommands.isValidNodeIdentifier(reply.threadIdentifier) {
                throw OutwardStepError.invalidThreadIdentifier(reply.threadIdentifier)
            }
            for command in stepCommands { try await runChecked(command) }
        case .resolves:
            for threadIdentifier in delivery.resolveThreadIdentifiers where !GitHubCommands.isValidNodeIdentifier(threadIdentifier) {
                throw OutwardStepError.invalidThreadIdentifier(threadIdentifier)
            }
            for command in stepCommands { try await runChecked(command) }
        case .comment:
            for command in stepCommands { try await runChecked(command) }
        case .prCreate:
            guard stepCommands.count == 2 else { return }
            let listOutput = try await runChecked(stepCommands[0])
            if let existingURL = Self.firstPullRequestURL(inListJSON: listOutput.standardOutput) { throw OutwardStepError.pullRequestAlreadyOpen(existingURL) }
            let createOutput = try await runChecked(stepCommands[1])
            createdPullRequestURL = createOutput.trimmedOutput.split(separator: "\n").last.map(String.init)
        }
    }

    private func runPush(_ push: OutwardDelivery.PushTarget, commands pushCommands: [OutwardCommand]) async throws {
        for command in pushCommands where command.gatedAction == .fork { try await runChecked(command) }
        let gitCommands = pushCommands.filter { $0.gatedAction == .push }
        guard gitCommands.count == 2 else { throw OutwardStepError.pushFailed("push commands missing") }

        try verifyApproval()
        let lsRemoteOutput = try await execute(gitCommands[0])
        guard lsRemoteOutput.succeeded else { throw OutwardStepError.pushFailed("ls-remote: \(lsRemoteOutput.shortError)") }
        let remoteRef = "refs/heads/\(push.branch)"
        let currentRemoteOID = lsRemoteOutput.standardOutput.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t")
            return fields.count == 2 && fields[1] == remoteRef ? String(fields[0]) : nil
        }.first
        guard currentRemoteOID == push.expectedRemoteOID else { throw OutwardStepError.remoteMoved(expected: push.expectedRemoteOID, found: currentRemoteOID) }

        try verifyApproval()
        let pushOutput = try await execute(gitCommands[1])
        switch GitPushPorcelain.parse(pushOutput.standardOutput).verdict {
        case .fatal(let message): throw OutwardStepError.pushFatal(message)
        case .rejected(let message): throw OutwardStepError.pushRejected(message)
        case .noRefLine where !pushOutput.succeeded, .ok where !pushOutput.succeeded:
            throw OutwardStepError.pushFailed(pushOutput.shortError)
        case .noRefLine:
            throw OutwardStepError.pushFailed("no ref line in push output")
        case .ok:
            pushedOID = push.reviewOID
        }
    }

    // MARK: - Running

    /// Verifies the approval, runs, and throws unless it exited 0.
    @discardableResult
    public func runChecked(_ command: OutwardCommand) async throws -> CodeCommandOutput {
        try verifyApproval()
        let output = try await execute(command)
        guard output.succeeded else { throw OutwardStepError.commandFailed("\(command.arguments.prefix(2).joined(separator: " ")) failed: \(output.shortError)") }
        return output
    }

    private func execute(_ command: OutwardCommand) async throws -> CodeCommandOutput {
        try await runner.run(executable: command.executable, arguments: command.arguments, workingDirectory: command.workingDirectory,
                             environment: environment, timeoutSeconds: HardenedGit.networkTimeoutSeconds)
    }

    static func firstPullRequestURL(inListJSON json: String) -> String? {
        guard let pullRequests = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]], let first = pullRequests.first else { return nil }
        return first["url"] as? String ?? "#\(first["number"] ?? "?")"
    }
}
