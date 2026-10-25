//
//  WorktreeIntegrity.swift
//  ClickyCore
//
//  Hashes what an agent must never change — the clone's .git/config, the
//  worktree's `.git` pointer file, config.worktree and the hooks/ folder —
//  before and after it runs. Any difference (a byte, a new hook, a removed
//  file) aborts the task before Clicky runs a single git command in that
//  worktree again. Symlinks are hashed by their target, never followed.
//

import CryptoKit
import Foundation

public struct IntegritySnapshot: Equatable, Sendable {
    /// Path → SHA-256 hex, "absent", "dir" or "link:<target>".
    public var entries: [String: String]

    public init(entries: [String: String]) {
        self.entries = entries
    }

    /// Hashes each path; folders are walked recursively.
    public static func capture(paths: [String]) -> IntegritySnapshot {
        var entries: [String: String] = [:]
        for path in paths { addEntries(for: path, into: &entries) }
        return IntegritySnapshot(entries: entries)
    }

    /// Paths whose state differs (added, removed or changed), sorted.
    public func changedPaths(comparedTo later: IntegritySnapshot) -> [String] {
        Set(entries.keys).union(later.entries.keys).filter { entries[$0] != later.entries[$0] }.sorted()
    }

    private static func addEntries(for path: String, into entries: inout [String: String]) {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            entries[path] = "absent"
            return
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink?:
            entries[path] = "link:" + ((try? fileManager.destinationOfSymbolicLink(atPath: path)) ?? "?")
        case .typeDirectory?:
            entries[path] = "dir"
            let childNames = ((try? fileManager.contentsOfDirectory(atPath: path)) ?? []).sorted()
            for childName in childNames { addEntries(for: (path as NSString).appendingPathComponent(childName), into: &entries) }
        default:
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let contents = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            entries[path] = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined() + String(format: ":%o", permissions)
        }
    }
}

public enum WorktreeIntegrity {
    /// The paths to watch for a linked worktree (or a plain clone when the
    /// worktree is the clone itself).
    public static func protectedPaths(worktreePath: String, gitDirectory: String, commonGitDirectory: String) -> [String] {
        var paths = [
            (commonGitDirectory as NSString).appendingPathComponent("config"),
            (commonGitDirectory as NSString).appendingPathComponent("hooks")
        ]
        if gitDirectory != commonGitDirectory {
            // A linked worktree: its `.git` is a one-line pointer file.
            paths.append((worktreePath as NSString).appendingPathComponent(".git"))
            paths.append((gitDirectory as NSString).appendingPathComponent("config.worktree"))
        }
        paths.append((commonGitDirectory as NSString).appendingPathComponent("config.worktree"))
        return paths
    }
}
