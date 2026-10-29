//
//  ExecutablePath.swift
//  ClickyCore
//
//  Finds `git`, `gh` and `claude` the way the user's Terminal would. A menu-bar
//  app launched by launchd only gets a bare PATH, so we ask a login shell for
//  its PATH once (5 s limit), add ~/.local/bin (where the claude installer
//  puts its binary), drop duplicates and cache the result.
//

import Foundation

public enum ExecutablePath {
    public static let probeTimeoutSeconds: TimeInterval = 5
    static let fallbackSearchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    private static let probeMarker = "__CLICKY_PATH__"

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedProbeTask: Task<[String], Never>?

    /// The search directories, probed once per launch.
    public static func searchDirectories() async -> [String] {
        await sharedProbeTask().value
    }

    private static func sharedProbeTask() -> Task<[String], Never> {
        cacheLock.withLock {
            if let cachedProbeTask { return cachedProbeTask }
            let probeTask = Task { await probeSearchDirectories() }
            cachedProbeTask = probeTask
            return probeTask
        }
    }

    /// Absolute path of an executable named `name`, or nil.
    public static func which(_ name: String) async -> String? {
        which(name, in: await searchDirectories())
    }

    public static func which(_ name: String, in directories: [String]) -> String? {
        guard !name.isEmpty else { return nil }
        if name.contains("/") { return isExecutableFile(atPath: name) ? name : nil }
        for directory in directories {
            let candidatePath = (directory as NSString).appendingPathComponent(name)
            if isExecutableFile(atPath: candidatePath) { return candidatePath }
        }
        return nil
    }

    /// Forget the cached PATH (tests, or after the user installs a tool).
    public static func resetCache() {
        cacheLock.lock()
        cachedProbeTask = nil
        cacheLock.unlock()
    }

    /// Login-shell PATH first, then the inherited PATH, then common
    /// fallbacks, then ~/.local/bin; empty entries and duplicates removed.
    static func combinedSearchDirectories(probedPath: String?, inheritedPath: String?, homeDirectory: String) -> [String] {
        var combinedDirectories: [String] = []
        var seenDirectories = Set<String>()
        let localBinDirectory = (homeDirectory as NSString).appendingPathComponent(".local/bin")
        let candidateDirectories = (probedPath ?? "").split(separator: ":").map(String.init)
            + (inheritedPath ?? "").split(separator: ":").map(String.init)
            + fallbackSearchDirectories
            + [localBinDirectory]
        for directory in candidateDirectories where !directory.isEmpty {
            let normalizedDirectory = directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            if seenDirectories.insert(normalizedDirectory).inserted {
                combinedDirectories.append(normalizedDirectory)
            }
        }
        return combinedDirectories
    }

    private static func probeSearchDirectories() async -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let homeDirectory = environment["HOME"] ?? NSHomeDirectory()
        let probedPath = await probeLoginShellPath(environment: environment, homeDirectory: homeDirectory)
        return combinedSearchDirectories(probedPath: probedPath, inheritedPath: environment["PATH"], homeDirectory: homeDirectory)
    }

    /// Markers around the PATH keep it apart from anything a profile prints.
    private static func probeLoginShellPath(environment: [String: String], homeDirectory: String) async -> String? {
        let probeCommand = "printf '\(probeMarker)%s\(probeMarker)' \"$PATH\""
        guard let probeResult = try? await ChildProcess.run(
            executable: "/bin/zsh", arguments: ["-lc", probeCommand], environment: environment,
            workingDirectory: homeDirectory, timeouts: .total(probeTimeoutSeconds)
        ), probeResult.endReason == .exited else { return nil }
        let probeOutput = probeResult.standardOutputText
        guard let openingMarker = probeOutput.range(of: probeMarker),
              let closingMarker = probeOutput.range(of: probeMarker, range: openingMarker.upperBound..<probeOutput.endIndex) else { return nil }
        return String(probeOutput[openingMarker.upperBound..<closingMarker.lowerBound])
    }

    private static func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
