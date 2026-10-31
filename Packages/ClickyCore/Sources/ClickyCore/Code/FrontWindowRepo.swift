//
//  FrontWindowRepo.swift
//  ClickyCore
//
//  "this repo" / "this project": the repo comes from the frontmost window.
//  The app reads, read-only, the front app's bundle id, its focused
//  window's title and AXDocument (Xcode's document, Terminal's working
//  directory), and for Terminal the cwd of the front tab's shell found
//  through the tty in the title; this file turns that into a git root:
//  paths first (walk up to the folder holding `.git`), then folder names
//  from the title (VS Code "file — folder — Visual Studio Code") matched to
//  the indexed clones, exact folder name first, then RepoMatcher.
//
//  CodeRepoDenylist is checked on every local root, whichever way it was
//  found: Clicky never works on its own source — ~/Projects/clicky, any
//  checkout whose root holds leanring-buddy.xcodeproj, or any worktree of
//  such a checkout (the clicky-* worktrees) — on top of RepoMatcher's
//  farzaa/clicky denylist.
//

import Foundation

/// Read-only file checks, injectable for tests.
public struct RepoFileSystem: Sendable {
    public var exists: @Sendable (String) -> Bool
    public var isDirectory: @Sendable (String) -> Bool
    public var readText: @Sendable (String) -> String?

    public init(exists: @escaping @Sendable (String) -> Bool, isDirectory: @escaping @Sendable (String) -> Bool, readText: @escaping @Sendable (String) -> String?) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.readText = readText
    }

    public static let live = RepoFileSystem(
        exists: { FileManager.default.fileExists(atPath: $0) },
        isDirectory: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        },
        readText: { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), (attributes[.size] as? NSNumber)?.intValue ?? 0 < 64_000 else { return nil }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
    )
}

public enum CodeRepoDenylist {
    /// A checkout of Clicky itself has this at its root.
    public static let clickyProjectMarker = "leanring-buddy.xcodeproj"

    /// ~/Projects/clicky, a root holding leanring-buddy.xcodeproj, or a
    /// worktree whose main checkout is one of those.
    public static func isDeniedLocalRoot(_ rootPath: String, homeDirectory: String = NSHomeDirectory(), fileSystem: RepoFileSystem = .live) -> Bool {
        let root = standardized(rootPath)
        if root == standardized((homeDirectory as NSString).appendingPathComponent("Projects/clicky")) { return true }
        if fileSystem.exists((root as NSString).appendingPathComponent(clickyProjectMarker)) { return true }
        // A linked worktree: `.git` is a file "gitdir: <main>/.git/worktrees/<name>".
        let dotGitPath = (root as NSString).appendingPathComponent(".git")
        if !fileSystem.isDirectory(dotGitPath), let pointer = fileSystem.readText(dotGitPath),
           let mainCheckout = mainCheckoutPath(fromGitFile: pointer, worktreeRoot: root) {
            if mainCheckout == standardized((homeDirectory as NSString).appendingPathComponent("Projects/clicky")) { return true }
            if fileSystem.exists((mainCheckout as NSString).appendingPathComponent(clickyProjectMarker)) { return true }
        }
        return false
    }

    /// "gitdir: /x/clicky/.git/worktrees/fix" → "/x/clicky".
    static func mainCheckoutPath(fromGitFile text: String, worktreeRoot: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitDirectory = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitDirectory.hasPrefix("/") { gitDirectory = (worktreeRoot as NSString).appendingPathComponent(gitDirectory) }
        gitDirectory = standardized(gitDirectory)
        guard let range = gitDirectory.range(of: "/.git/worktrees/") else { return nil }
        return String(gitDirectory[..<range.lowerBound])
    }

    static func standardized(_ path: String) -> String {
        var result = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// What the app read from the front window (all optional; nothing is required).
public struct FrontWindowContext: Equatable, Sendable {
    public enum Application: String, Sendable {
        case xcode, vsCode, terminal, other
    }

    public var bundleIdentifier: String?
    public var windowTitle: String?
    /// The window's AXDocument (a file:// URL or a path).
    public var documentURL: String?
    /// Terminal: the cwd of the shell on the front tab's tty, when found.
    public var terminalWorkingDirectory: String?

    public init(bundleIdentifier: String?, windowTitle: String? = nil, documentURL: String? = nil, terminalWorkingDirectory: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.documentURL = documentURL
        self.terminalWorkingDirectory = terminalWorkingDirectory
    }

    static let xcodeBundleIdentifiers: Set<String> = ["com.apple.dt.Xcode"]
    static let vsCodeBundleIdentifiers: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss",
                                                       "com.vscodium", "com.todesktop.230313mt9", "com.todesktop.230313mt9k", "com.exafunction.windsurf"]
    static let terminalBundleIdentifiers: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"]

    public var application: Application {
        guard let bundleIdentifier else { return .other }
        if Self.xcodeBundleIdentifiers.contains(bundleIdentifier) { return .xcode }
        if Self.vsCodeBundleIdentifiers.contains(bundleIdentifier) { return .vsCode }
        if Self.terminalBundleIdentifiers.contains(bundleIdentifier) { return .terminal }
        return .other
    }

    /// Only these apps are read for "this repo".
    public static func isSupported(bundleIdentifier: String?) -> Bool {
        FrontWindowContext(bundleIdentifier: bundleIdentifier).application != .other
    }
}

public enum FrontWindowRepoResolution: Equatable, Sendable {
    /// A git root and how it was found ("Xcode document", "VS Code title").
    case found(rootPath: String, source: String)
    /// The front window is a checkout Clicky must not work on.
    case denied(rootPath: String)
    case notFound
}

public enum FrontWindowRepoResolver {
    /// The `repo` values that mean "the one in front".
    public static func isDeicticRepoName(_ repoName: String) -> Bool {
        let key = RepoMatcher.normalize(repoName)
        return ["", "this", "thisrepo", "thisrepository", "thisproject", "thiscode", "thiscodebase", "here", "current", "currentrepo",
                "currentproject", "thisone", "frontwindow", "theoneonscreen"].contains(key)
    }

    /// Paths to start the `.git` walk from, best first.
    public static func candidatePaths(_ context: FrontWindowContext, homeDirectory: String = NSHomeDirectory()) -> [String] {
        var paths: [String] = []
        if let terminalWorkingDirectory = context.terminalWorkingDirectory, !terminalWorkingDirectory.isEmpty { paths.append(terminalWorkingDirectory) }
        if let documentURL = context.documentURL, let path = filePath(fromDocument: documentURL) { paths.append(path) }
        for component in titleComponents(context.windowTitle) where component.hasPrefix("/") || component.hasPrefix("~/") {
            paths.append(component.hasPrefix("~/") ? (homeDirectory as NSString).appendingPathComponent(String(component.dropFirst(2))) : component)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Folder names in the title that may be the project, best first.
    public static func folderNameHints(_ context: FrontWindowContext) -> [String] {
        var components = titleComponents(context.windowTitle).filter { !$0.hasPrefix("/") && !$0.hasPrefix("~") }
        switch context.application {
        case .vsCode:
            // "utils.py — scratch — Visual Studio Code": the app name last, the folder before it.
            components = components.filter { !isEditorName($0) }
            return components.reversed().filter { !looksLikeFileName($0) }
        case .xcode:
            // "clicky — utils.swift": the project first.
            return components.map { stripping($0, suffixes: [".xcodeproj", ".xcworkspace"]) }.filter { !looksLikeFileName($0) }
        case .terminal:
            // "scratch — -zsh — 80×24", "user@host: ~/x" (paths are handled above).
            return components.filter { component in
                !component.hasPrefix("-") && !isTerminalNoise(component)
            }.map { component in
                if let colon = component.lastIndex(of: ":"), component.contains("@") { return String(component[component.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
                return component
            }.filter { !$0.isEmpty }
        case .other:
            return []
        }
    }

    /// "ttys003" from a Terminal title that shows the tty.
    public static func ttyName(fromTitle title: String?) -> String? {
        guard let title, let range = title.range(of: #"ttys[0-9]{3,4}"#, options: .regularExpression) else { return nil }
        return String(title[range])
    }

    /// Walks up from `path` (a file or folder) to the folder holding `.git`.
    public static func gitRoot(startingAt path: String, homeDirectory: String = NSHomeDirectory(), fileSystem: RepoFileSystem = .live) -> String? {
        var current = CodeRepoDenylist.standardized(path)
        if !fileSystem.isDirectory(current) { current = (current as NSString).deletingLastPathComponent }
        let home = CodeRepoDenylist.standardized(homeDirectory)
        var steps = 0
        while current != "/", !current.isEmpty, steps < 40 {
            // The home folder itself is never a project (and nothing above it is).
            if current == home { return nil }
            if fileSystem.exists((current as NSString).appendingPathComponent(".git")) { return current }
            current = (current as NSString).deletingLastPathComponent
            steps += 1
        }
        return nil
    }

    /// The front window's repo: paths first, then title folder names
    /// matched to `localRepos` (exact folder name, then a confident RepoMatcher match).
    public static func resolve(_ context: FrontWindowContext, localRepos: [LocalRepoEntry], homeDirectory: String = NSHomeDirectory(),
                               fileSystem: RepoFileSystem = .live) -> FrontWindowRepoResolution {
        guard context.application != .other else { return .notFound }
        let sourceName: String
        switch context.application {
        case .xcode: sourceName = "Xcode"
        case .vsCode: sourceName = "VS Code"
        case .terminal: sourceName = "Terminal"
        case .other: sourceName = "window"
        }
        for path in candidatePaths(context, homeDirectory: homeDirectory) {
            guard let root = gitRoot(startingAt: path, homeDirectory: homeDirectory, fileSystem: fileSystem) else { continue }
            if CodeRepoDenylist.isDeniedLocalRoot(root, homeDirectory: homeDirectory, fileSystem: fileSystem) { return .denied(rootPath: root) }
            return .found(rootPath: root, source: "\(sourceName) path")
        }
        let allowedRepos = localRepos.filter { !CodeRepoDenylist.isDeniedLocalRoot($0.folderPath, homeDirectory: homeDirectory, fileSystem: fileSystem) }
        let deniedFolderKeys = Set(localRepos.filter { CodeRepoDenylist.isDeniedLocalRoot($0.folderPath, homeDirectory: homeDirectory, fileSystem: fileSystem) }
            .map { RepoMatcher.normalize(($0.folderPath as NSString).lastPathComponent) })
        for hint in folderNameHints(context) {
            let hintKey = RepoMatcher.normalize(hint)
            guard !hintKey.isEmpty else { continue }
            let exactMatches = allowedRepos.filter { RepoMatcher.normalize(($0.folderPath as NSString).lastPathComponent) == hintKey }
            if exactMatches.count == 1 { return .found(rootPath: exactMatches[0].folderPath, source: "\(sourceName) title") }
            if exactMatches.count > 1 { continue }
            if deniedFolderKeys.contains(hintKey) { return .denied(rootPath: hint) }
            let matchResult = RepoMatcher(localRepos: allowedRepos).match(spokenName: hint)
            if matchResult.isConfident, let folderPath = matchResult.top?.folderPath { return .found(rootPath: folderPath, source: "\(sourceName) title") }
        }
        return .notFound
    }

    // MARK: - Pieces

    static func filePath(fromDocument document: String) -> String? {
        let trimmed = document.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { return trimmed }
        guard let url = URL(string: trimmed), url.isFileURL else { return nil }
        return url.path
    }

    /// Title split on " — ", " – ", " - " with dirty markers and brackets removed.
    static func titleComponents(_ title: String?) -> [String] {
        guard var text = title?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        for marker in ["●", "•", "✎"] { text = text.replacingOccurrences(of: marker, with: "") }
        if let bracketRange = text.range(of: #"\s*\[[^\]]*\]"#, options: .regularExpression) { text.removeSubrange(bracketRange) }
        let separators = [" — ", " – ", " - "]
        var parts = [text]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isEditorName(_ component: String) -> Bool {
        let lowered = component.lowercased()
        return ["visual studio code", "code", "code - insiders", "vscodium", "cursor", "windsurf", "visual studio code - insiders"].contains(lowered)
            || lowered.hasPrefix("visual studio code")
    }

    static func looksLikeFileName(_ component: String) -> Bool {
        let fileExtension = (component as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty, !component.contains(" ") else { return false }
        return !["xcodeproj", "xcworkspace"].contains(fileExtension) && fileExtension.count <= 6
    }

    static func isTerminalNoise(_ component: String) -> Bool {
        let lowered = component.lowercased()
        if lowered.range(of: #"^[0-9]+[×x][0-9]+$"#, options: .regularExpression) != nil { return true }
        if lowered.range(of: #"^ttys[0-9]+$"#, options: .regularExpression) != nil { return true }
        return ["zsh", "bash", "fish", "sh", "login", "terminal"].contains(lowered)
    }

    static func stripping(_ text: String, suffixes: [String]) -> String {
        for suffix in suffixes where text.lowercased().hasSuffix(suffix) { return String(text.dropLast(suffix.count)) }
        return text
    }
}
