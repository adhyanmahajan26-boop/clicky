//
//  LocalRepoIndexer.swift
//  ClickyCore
//
//  Finds local clones for RepoMatcher: walks each repo root (~/Projects and
//  ~/Developer up to depth 3; the home folder itself only one level, so
//  ~/mmi-website is found; ~/Documents, ~/Downloads and ~/jstest two
//  levels; any other root three; at the home level the system folders Library,
//  Desktop, Movies, Music, Pictures, Public and Applications are skipped),
//  stops descending at a folder with
//  a `.git`, skips hidden folders, node_modules and Clicky's own worktrees,
//  and reads origin/upstream with read-only `git config --get`. A repo with
//  neither remote is kept too (RepoMatcher makes it local-only).
//

import Foundation

public struct LocalRepoIndexer: Sendable {
    public static let maximumDepth = 3
    /// ~/Documents, ~/Downloads and ~/jstest (big folders, mostly not code).
    public static let shallowRootDepth = 2
    static let shallowRootNames = ["Documents", "Downloads", "jstest"]
    static let skippedFolderNames: Set<String> = ["node_modules", "Pods", "DerivedData", "build", ".build", "vendor"]
    /// Skipped directly under the home folder (system folders; Desktop and the media folders would also ask for privacy access).
    static let skippedHomeFolderNames: Set<String> = ["Library", "Desktop", "Movies", "Music", "Pictures", "Public", "Applications",
                                                      "Documents", "Downloads"]
    /// Privacy-protected folders: listing them makes macOS ask the owner for access (a live test left
    /// that prompt on screen and blocked a code task). Only walked when the owner turned on
    /// v2.code.searchProtectedFolders himself; the home folder's top level and ~/Projects never ask.
    public static let protectedFolderNames: Set<String> = ["Desktop", "Documents", "Downloads"]

    /// Whether `root` is (inside) a protected folder of `homeDirectory`.
    public static func isProtected(_ root: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let standardizedRoot = (root as NSString).standardizingPath
        let standardizedHome = (homeDirectory as NSString).standardizingPath
        return protectedFolderNames.contains { name in
            let protectedPath = (standardizedHome as NSString).appendingPathComponent(name)
            return standardizedRoot == protectedPath || standardizedRoot.hasPrefix(protectedPath + "/")
        }
    }

    /// How deep a root is walked.
    public static func maximumDepth(forRoot root: String, homeDirectory: String = NSHomeDirectory()) -> Int {
        let standardizedRoot = (root as NSString).standardizingPath
        let standardizedHome = (homeDirectory as NSString).standardizingPath
        if standardizedRoot == standardizedHome { return 1 }
        let shallowRoots = shallowRootNames.map { (standardizedHome as NSString).appendingPathComponent($0) }
        return shallowRoots.contains(standardizedRoot) ? shallowRootDepth : maximumDepth
    }

    public var git: HardenedGit
    public var roots: [String]
    /// The owner allowed searching Desktop/Documents/Downloads (v2.code.searchProtectedFolders).
    public var searchesProtectedFolders: Bool
    var homeDirectory: String
    /// Lists a folder (injectable so tests can prove protected folders are never touched).
    var listDirectory: @Sendable (String) -> [String]?

    public init(git: HardenedGit, roots: [String], searchesProtectedFolders: Bool = ClickySettings.searchesProtectedFolders,
                homeDirectory: String = NSHomeDirectory()) {
        self.git = git
        self.roots = roots.map { ($0 as NSString).expandingTildeInPath }
        self.searchesProtectedFolders = searchesProtectedFolders
        self.homeDirectory = homeDirectory
        self.listDirectory = { try? FileManager.default.contentsOfDirectory(atPath: $0) }
    }

    /// Clone folders under the roots (no git calls).
    public func cloneFolders() -> [String] {
        var folders: [String] = []
        var seen = Set<String>()
        for root in roots where searchesProtectedFolders || !Self.isProtected(root, homeDirectory: homeDirectory) {
            walk(root, depth: 0, maximumDepth: Self.maximumDepth(forRoot: root, homeDirectory: homeDirectory),
                 isHomeRoot: Self.maximumDepth(forRoot: root, homeDirectory: homeDirectory) == 1,
                 into: &folders, seen: &seen)
        }
        return folders
    }

    private func walk(_ folder: String, depth: Int, maximumDepth: Int, isHomeRoot: Bool, into folders: inout [String], seen: inout Set<String>) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) {
            let resolvedFolder = ProcessSweep.resolvedPath(folder) ?? folder
            if seen.insert(resolvedFolder).inserted { folders.append(folder) }
            return
        }
        guard depth < maximumDepth, let childNames = listDirectory(folder) else { return }
        for childName in childNames.sorted() where !childName.hasPrefix(".") && !Self.skippedFolderNames.contains(childName) {
            if isHomeRoot, depth == 0, Self.skippedHomeFolderNames.contains(childName) { continue }
            let childPath = (folder as NSString).appendingPathComponent(childName)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: childPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let attributes = try? fileManager.attributesOfItem(atPath: childPath), attributes[.type] as? FileAttributeType == .typeSymbolicLink { continue }
            walk(childPath, depth: depth + 1, maximumDepth: maximumDepth, isHomeRoot: isHomeRoot, into: &folders, seen: &seen)
        }
    }

    /// Each clone with its origin/upstream URLs.
    public func index() async -> [LocalRepoEntry] {
        var entries: [LocalRepoEntry] = []
        for folder in cloneFolders() {
            let originURL = await git.remoteURL(named: "origin", in: folder)
            let upstreamURL = await git.remoteURL(named: "upstream", in: folder)
            entries.append(LocalRepoEntry(folderPath: folder, originURL: originURL, upstreamURL: upstreamURL))
        }
        return entries
    }
}
