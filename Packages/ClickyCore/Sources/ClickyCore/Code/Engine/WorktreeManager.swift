//
//  WorktreeManager.swift
//  ClickyCore
//
//  The isolated checkout an editing agent works in, under
//  ~/.clicky/worktrees/<owner>__<name>/. A PR is fetched into
//  refs/clicky/pr/N and checked out locked on clicky/pr-N, and HEAD must be
//  the PR's head OID; a no-PR change gets clicky/<slug>-<4hex> off the base.
//  Conflict tasks start a `merge --no-commit` of refs/clicky/base/N so the
//  commit gets parents [HEAD, BASE]. Afterwards Clicky stages everything and
//  makes one commit from outbox/commit-msg.txt (follow-ups amend it).
//  Cleanup only ever touches `git worktree list` entries under the root.
//

import Foundation

public struct ClickyWorktree: Codable, Equatable, Sendable {
    public var clonePath: String
    public var path: String
    /// Short branch name, e.g. "clicky/pr-12".
    public var branch: String
    /// HEAD when the worktree was made (the PR head, or the base).
    public var startOID: String
    public var pullRequestNumber: Int?
    /// Set while resolving conflicts: the base commit being merged in.
    public var mergeBaseOID: String?

    public init(clonePath: String, path: String, branch: String, startOID: String, pullRequestNumber: Int? = nil, mergeBaseOID: String? = nil) {
        self.clonePath = clonePath
        self.path = path
        self.branch = branch
        self.startOID = startOID
        self.pullRequestNumber = pullRequestNumber
        self.mergeBaseOID = mergeBaseOID
    }
}

public enum WorktreeError: Error, Equatable, Sendable, CustomStringConvertible {
    case headMismatch(expected: String, found: String?)
    case existingWorktreeHasUnpushedWork(path: String)
    case integrityChanged([String])
    case nothingToCommit
    case mergeParentsWrong
    case notUnderWorktreeRoot(String)

    public var description: String {
        switch self {
        case .headMismatch(let expected, let found): return "worktree HEAD is \(found ?? "missing"), expected \(expected)"
        case .existingWorktreeHasUnpushedWork(let path): return "\(path) already exists with unpushed commits"
        case .integrityChanged(let paths): return "git config or hooks changed during the run: \(paths.joined(separator: ", "))"
        case .nothingToCommit: return "the agent made no changes"
        case .mergeParentsWrong: return "the conflict commit doesn't have parents [HEAD, BASE]"
        case .notUnderWorktreeRoot(let path): return "\(path) isn't one of Clicky's worktrees"
        }
    }
}

/// One `git worktree list --porcelain` entry.
public struct WorktreeListEntry: Equatable, Sendable {
    public var path: String
    public var headOID: String?
    /// Full ref, e.g. "refs/heads/clicky/pr-12".
    public var branchRef: String?
    public var isLocked = false
    public var isDetached = false
    public var isPrunable = false
    public var isBare = false

    public init(path: String) {
        self.path = path
    }

    public var shortBranch: String? {
        guard let branchRef, branchRef.hasPrefix("refs/heads/") else { return nil }
        return String(branchRef.dropFirst("refs/heads/".count))
    }

    public static func parsePorcelain(_ porcelainOutput: String) -> [WorktreeListEntry] {
        var entries: [WorktreeListEntry] = []
        var current: WorktreeListEntry?
        for line in porcelainOutput.components(separatedBy: "\n") {
            if line.isEmpty {
                if let current { entries.append(current) }
                current = nil
                continue
            }
            let (key, value) = Self.split(line)
            if key == "worktree" {
                if let current { entries.append(current) }
                current = WorktreeListEntry(path: value)
                continue
            }
            switch key {
            case "HEAD": current?.headOID = value
            case "branch": current?.branchRef = value
            case "locked": current?.isLocked = true
            case "detached": current?.isDetached = true
            case "prunable": current?.isPrunable = true
            case "bare": current?.isBare = true
            default: break
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}

public struct WorktreeManager: Sendable {
    public var git: HardenedGit
    public var worktreesRootURL: URL

    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/worktrees", isDirectory: true)
    }

    public init(git: HardenedGit, worktreesRootURL: URL = defaultRootURL) {
        self.git = git
        self.worktreesRootURL = worktreesRootURL
    }

    public func repositoryFolderURL(owner: String, name: String) -> URL {
        worktreesRootURL.appendingPathComponent(CodeTaskWorkspace.safeFileName("\(owner)__\(name)"), isDirectory: true)
    }

    /// Fetch flags shared by every Clicky fetch: no tags, no submodules, no auto-gc.
    static let fetchPrefix = ["-c", "gc.auto=0", "-c", "maintenance.auto=false", "fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head", "--quiet"]

    // MARK: - Creating

    /// Fetches the PR head and checks it out on clicky/pr-N, locked.
    public func prepareForPullRequest(clonePath: String, fetchURL: String, owner: String, name: String, pullRequestNumber: Int, expectedHeadOID: String) async throws -> ClickyWorktree {
        let pullRequestRef = "refs/clicky/pr/\(pullRequestNumber)"
        try await git.runChecked(Self.fetchPrefix + ["--", fetchURL, "+refs/pull/\(pullRequestNumber)/head:\(pullRequestRef)"], in: clonePath,
                                 usesGitHubCredentials: true, timeoutSeconds: HardenedGit.networkTimeoutSeconds)
        let worktreeURL = repositoryFolderURL(owner: owner, name: name).appendingPathComponent("pr-\(pullRequestNumber)", isDirectory: true)
        let branch = "clicky/pr-\(pullRequestNumber)"
        try await clearStaleWorktree(at: worktreeURL.path, clonePath: clonePath, alsoExcluding: [pullRequestRef])
        try FileManager.default.createDirectory(at: worktreeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git.runChecked(["worktree", "add", "--lock", "--quiet", "-B", branch, worktreeURL.path, pullRequestRef], in: clonePath)
        let headOID = await git.headOID(in: worktreeURL.path)
        guard headOID == expectedHeadOID else {
            // The PR moved (or the fetch was wrong): don't leave a worktree on the wrong commit.
            if let createdEntry = try? await clickyWorktrees(clonePath: clonePath).first(where: { Self.resolved($0.path) == Self.resolved(worktreeURL.path) }) {
                try? await remove(createdEntry, clonePath: clonePath)
            }
            throw WorktreeError.headMismatch(expected: expectedHeadOID, found: headOID)
        }
        return ClickyWorktree(clonePath: clonePath, path: worktreeURL.path, branch: branch, startOID: expectedHeadOID, pullRequestNumber: pullRequestNumber)
    }

    /// A new branch clicky/<slug>-<4hex> off `baseRevision` (a branch or OID).
    public func prepareForBranch(clonePath: String, owner: String, name: String, slug: String, baseRevision: String) async throws -> ClickyWorktree {
        let leafName = "\(Self.slug(from: slug))-\(CodeTaskWorkspace.randomHex(count: 4))"
        let branch = "clicky/\(leafName)"
        let worktreeURL = repositoryFolderURL(owner: owner, name: name).appendingPathComponent(leafName, isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let baseOID = await git.value(["rev-parse", "--verify", "--end-of-options", baseRevision + "^{commit}"], in: clonePath) else {
            throw CodeCommandError.failed(command: "git rev-parse", exitStatus: nil, message: "no base \(baseRevision)")
        }
        try await git.runChecked(["worktree", "add", "--lock", "--quiet", "-b", branch, worktreeURL.path, baseOID], in: clonePath)
        return ClickyWorktree(clonePath: clonePath, path: worktreeURL.path, branch: branch, startOID: baseOID)
    }

    /// Fetches the base into refs/clicky/base/N and starts `merge --no-commit`.
    /// Returns the worktree with mergeBaseOID set and whether there are conflicts.
    public func startConflictMerge(_ worktree: ClickyWorktree, fetchURL: String, baseBranch: String) async throws -> (ClickyWorktree, hasConflicts: Bool) {
        let number = worktree.pullRequestNumber.map(String.init) ?? Self.slug(from: worktree.branch)
        let baseRef = "refs/clicky/base/\(number)"
        try await git.runChecked(Self.fetchPrefix + ["--", fetchURL, "+refs/heads/\(baseBranch):\(baseRef)"], in: worktree.clonePath,
                                 usesGitHubCredentials: true, timeoutSeconds: HardenedGit.networkTimeoutSeconds)
        guard let baseOID = await git.value(["rev-parse", "--verify", baseRef], in: worktree.clonePath) else {
            throw CodeCommandError.failed(command: "git rev-parse", exitStatus: nil, message: "no \(baseRef)")
        }
        let mergeOutput = try await git.run(["merge", "--no-commit", "--no-ff", "--no-verify", "--no-edit", baseOID], in: worktree.path)
        var updatedWorktree = worktree
        updatedWorktree.mergeBaseOID = baseOID
        // 0 = merged cleanly (still uncommitted), 1 = conflicts left for the agent.
        guard mergeOutput.exitStatus == 0 || mergeOutput.exitStatus == 1 else {
            throw CodeCommandError.failed(command: "git merge", exitStatus: mergeOutput.exitStatus, message: mergeOutput.shortError)
        }
        return (updatedWorktree, mergeOutput.exitStatus == 1)
    }

    // MARK: - Integrity

    public func integrityPaths(for worktree: ClickyWorktree) async throws -> [String] {
        guard let gitDirectory = await git.gitDirectory(in: worktree.path), let commonDirectory = await git.commonGitDirectory(in: worktree.path) else {
            throw CodeCommandError.failed(command: "git rev-parse", exitStatus: nil, message: "not a worktree: \(worktree.path)")
        }
        return WorktreeIntegrity.protectedPaths(worktreePath: worktree.path, gitDirectory: gitDirectory, commonGitDirectory: commonDirectory)
    }

    // MARK: - Committing

    /// `add -A` and one commit (or amend) from the message file. Returns the new HEAD.
    public func commitAgentChanges(_ worktree: ClickyWorktree, commitMessageFileURL: URL, amend: Bool) async throws -> String {
        try await git.runChecked(["add", "-A"], in: worktree.path)
        let stagedCheck = try await git.run(["diff", "--cached", "--quiet", "--no-ext-diff"], in: worktree.path)
        let isMerging = worktree.mergeBaseOID != nil && !amend
        if stagedCheck.exitStatus == 0 && !isMerging && !amend { throw WorktreeError.nothingToCommit }
        var commitArguments = ["commit", "--no-verify", "--quiet", "--cleanup=strip", "-F", commitMessageFileURL.path]
        if amend { commitArguments.insert("--amend", at: 1) }
        if stagedCheck.exitStatus == 0 && (amend || isMerging) { commitArguments.insert("--allow-empty", at: 1) }
        try await git.runChecked(commitArguments, in: worktree.path)
        guard let newHeadOID = await git.headOID(in: worktree.path) else { throw WorktreeError.nothingToCommit }
        if let mergeBaseOID = worktree.mergeBaseOID {
            let parentsLine = await git.value(["rev-list", "--parents", "-n", "1", newHeadOID], in: worktree.path) ?? ""
            let parents = parentsLine.split(separator: " ").dropFirst().map(String.init)
            guard parents == [worktree.startOID, mergeBaseOID] else { throw WorktreeError.mergeParentsWrong }
        }
        return newHeadOID
    }

    /// The change under review: start → HEAD.
    public func reviewDiff(_ worktree: ClickyWorktree) async throws -> String {
        // For a conflict merge this is what the merge changes relative to the PR head (first parent).
        return try await git.diff(["--find-renames", worktree.startOID, "HEAD"], in: worktree.path)
    }

    // MARK: - Cleanup

    /// Entries of the clone's worktree list that live under the root (never the clone itself).
    public func clickyWorktrees(clonePath: String) async throws -> [WorktreeListEntry] {
        let output = try await git.runChecked(["worktree", "list", "--porcelain"], in: clonePath)
        let rootPath = Self.resolved(worktreesRootURL.path)
        return WorktreeListEntry.parsePorcelain(output.standardOutput).filter { entry in
            ProcessSweep.isPath(Self.resolved(entry.path), underAnyOf: [rootPath]) && Self.resolved(entry.path) != rootPath
        }
    }

    /// Commits on the entry's HEAD that no remote-tracking ref contains.
    public func unpushedCommitCount(_ entry: WorktreeListEntry, clonePath: String, alsoExcluding excludedRefs: [String] = []) async -> Int {
        guard let headOID = entry.headOID else { return 0 }
        return Int(await git.value(["rev-list", "--count", headOID, "--not", "--remotes"] + excludedRefs, in: clonePath) ?? "0") ?? 0
    }

    /// worktree remove --force, branch -D (clicky/ branches only), refs/clicky/{pr,base}/N.
    public func remove(_ entry: WorktreeListEntry, clonePath: String) async throws {
        let rootPath = Self.resolved(worktreesRootURL.path)
        guard ProcessSweep.isPath(Self.resolved(entry.path), underAnyOf: [rootPath]) else { throw WorktreeError.notUnderWorktreeRoot(entry.path) }
        _ = try? await git.run(["worktree", "unlock", entry.path], in: clonePath)
        try await git.runChecked(["worktree", "remove", "--force", entry.path], in: clonePath)
        if let branch = entry.shortBranch, branch.hasPrefix("clicky/") {
            _ = try? await git.run(["branch", "-D", "--", branch], in: clonePath)
            if branch.hasPrefix("clicky/pr-"), let number = Int(branch.dropFirst("clicky/pr-".count)) {
                for ref in ["refs/clicky/pr/\(number)", "refs/clicky/base/\(number)"] {
                    _ = try? await git.run(["update-ref", "-d", ref], in: clonePath)
                }
            }
        }
    }

    /// Every refs/clicky/* ref (after all of Clicky's worktrees are gone).
    public func removeAllClickyRefs(clonePath: String) async {
        guard let refList = await git.value(["for-each-ref", "--format=%(refname)", "refs/clicky/"], in: clonePath) else { return }
        for ref in refList.split(separator: "\n") where ref.hasPrefix("refs/clicky/") {
            _ = try? await git.run(["update-ref", "-d", String(ref)], in: clonePath)
        }
    }

    /// A previous run's worktree at the same path: removed when nothing on
    /// it is unpushed (commits the fetched PR head already has don't count).
    private func clearStaleWorktree(at path: String, clonePath: String, alsoExcluding excludedRefs: [String]) async throws {
        let existing = try await clickyWorktrees(clonePath: clonePath).first { Self.resolved($0.path) == Self.resolved(path) }
        if let existing {
            if await unpushedCommitCount(existing, clonePath: clonePath, alsoExcluding: excludedRefs) > 0 {
                throw WorktreeError.existingWorktreeHasUnpushedWork(path: path)
            }
            try await remove(existing, clonePath: clonePath)
        } else if FileManager.default.fileExists(atPath: path) {
            _ = try? await git.run(["worktree", "prune"], in: clonePath)
            if FileManager.default.fileExists(atPath: path) { throw WorktreeError.existingWorktreeHasUnpushedWork(path: path) }
        }
    }

    // MARK: - Helpers

    /// "Fix the login button!" → "fix-the-login-button" (≤ 30 chars, [a-z0-9-]).
    public static func slug(from text: String) -> String {
        let words = text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.prefix(5)
        var slug = words.joined(separator: "-")
        if slug.count > 30 { slug = String(slug.prefix(30)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        return slug.isEmpty ? "change" : slug
    }

    static func resolved(_ path: String) -> String {
        ProcessSweep.resolvedPath(path) ?? path
    }
}
