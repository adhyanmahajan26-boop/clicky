//
//  LocalRepoIndexer.swift
//  ClickyCore
//
//  Finds local clones for RepoMatcher: walks each repo root (~/Projects,
//  ~/Developer by default) up to depth 3, stops descending at a folder with
//  a `.git`, skips hidden folders, node_modules and Clicky's own worktrees,
//  and reads origin/upstream with read-only `git config --get`.
//

import Foundation

public struct LocalRepoIndexer: Sendable {
    public static let maximumDepth = 3
    static let skippedFolderNames: Set<String> = ["node_modules", "Pods", "DerivedData", "build", ".build", "vendor"]

    public var git: HardenedGit
    public var roots: [String]

    public init(git: HardenedGit, roots: [String]) {
        self.git = git
        self.roots = roots.map { ($0 as NSString).expandingTildeInPath }
    }

    /// Clone folders under the roots (no git calls).
    public func cloneFolders() -> [String] {
        var folders: [String] = []
        var seen = Set<String>()
        for root in roots {
            walk(root, depth: 0, into: &folders, seen: &seen)
        }
        return folders
    }

    private func walk(_ folder: String, depth: Int, into folders: inout [String], seen: inout Set<String>) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) {
            let resolvedFolder = ProcessSweep.resolvedPath(folder) ?? folder
            if seen.insert(resolvedFolder).inserted { folders.append(folder) }
            return
        }
        guard depth < Self.maximumDepth, let childNames = try? fileManager.contentsOfDirectory(atPath: folder) else { return }
        for childName in childNames.sorted() where !childName.hasPrefix(".") && !Self.skippedFolderNames.contains(childName) {
            let childPath = (folder as NSString).appendingPathComponent(childName)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: childPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let attributes = try? fileManager.attributesOfItem(atPath: childPath), attributes[.type] as? FileAttributeType == .typeSymbolicLink { continue }
            walk(childPath, depth: depth + 1, into: &folders, seen: &seen)
        }
    }

    /// Each clone with its origin/upstream URLs.
    public func index() async -> [LocalRepoEntry] {
        var entries: [LocalRepoEntry] = []
        for folder in cloneFolders() {
            let originURL = await git.remoteURL(named: "origin", in: folder)
            let upstreamURL = await git.remoteURL(named: "upstream", in: folder)
            guard originURL != nil || upstreamURL != nil else { continue }
            entries.append(LocalRepoEntry(folderPath: folder, originURL: originURL, upstreamURL: upstreamURL))
        }
        return entries
    }
}
