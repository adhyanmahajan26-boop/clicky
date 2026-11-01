//
//  UpdateFeed.swift
//  ClickyCore
//
//  One-click updates: Clicky reads the newest GitHub release of its updates
//  repo, and when its build number is higher than this app's, offers it.
//  A release is tagged "build-<number>", carries one .zip asset with the
//  app, and has a line "sha256: <hex>" in its notes. The app verifies the
//  zip's SHA-256 and, after unzipping, that the new app is signed by the
//  same team with the same bundle id, before it replaces itself.
//

import Foundation

public struct UpdateRelease: Equatable, Sendable {
    public var build: Int
    public var zipURL: URL
    /// The API URL of the same asset (needed for a private repo, with a token).
    public var apiAssetURL: URL?
    public var sha256: String
    public var notes: String

    public init(build: Int, zipURL: URL, apiAssetURL: URL? = nil, sha256: String, notes: String) {
        self.build = build
        self.zipURL = zipURL
        self.apiAssetURL = apiAssetURL
        self.sha256 = sha256
        self.notes = notes
    }
}

public enum UpdateFeed {
    /// The updates repo's newest release (GitHub API, no sign-in for a public repo).
    public static let defaultFeedURL = URL(string: "https://api.github.com/repos/adhyanmahajan26-boop/claudia-releases/releases/latest")!

    /// Parses a GitHub "release" object. Nil when it isn't a usable Clicky release.
    public static func parseRelease(_ data: Data) -> UpdateRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, let build = buildNumber(fromTag: tag) else { return nil }
        let body = object["body"] as? String ?? ""
        guard let sha256 = sha256(in: body) else { return nil }
        let assets = object["assets"] as? [[String: Any]] ?? []
        // A private repo needs the API asset URL (with Accept: application/octet-stream); a public one the download URL.
        guard let asset = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }),
              let urlText = (asset["browser_download_url"] as? String), let zipURL = URL(string: urlText) else { return nil }
        // GitHub bodies use \r\n line ends.
        let notes = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.lowercased().hasPrefix("sha256:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiAssetURL = (asset["url"] as? String).flatMap(URL.init(string:))
        return UpdateRelease(build: build, zipURL: zipURL, apiAssetURL: apiAssetURL, sha256: sha256, notes: notes)
    }

    /// "build-202610271200" → 202610271200.
    public static func buildNumber(fromTag tag: String) -> Int? {
        let digits = tag.lowercased().replacingOccurrences(of: "build-", with: "").replacingOccurrences(of: "v", with: "")
        return Int(digits)
    }

    static func sha256(in body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard text.hasPrefix("sha256:") else { continue }
            let hex = text.dropFirst("sha256:".count).trimmingCharacters(in: .whitespaces)
            if hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) { return hex }
        }
        return nil
    }

    public static func isNewer(_ release: UpdateRelease, thanBuild currentBuild: Int) -> Bool {
        release.build > currentBuild
    }

    /// The shell script that swaps the app once Clicky has quit, then opens the new one.
    /// The new app keeps its own file name (Clicky.app → Claudia.app), next to where the old one was.
    public static func installScript(processIdentifier: Int32, newAppPath: String, installedAppPath: String) -> String {
        func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let targetAppPath = (installedAppPath as NSString).deletingLastPathComponent + "/" + (newAppPath as NSString).lastPathComponent
        return """
        #!/bin/zsh
        # Waits for Clicky (pid \(processIdentifier)) to quit, swaps in the new app and opens it.
        for i in {1..100}; do kill -0 \(processIdentifier) 2>/dev/null || break; sleep 0.1; done
        backup=\(quoted(installedAppPath + ".previous"))
        rm -rf "$backup"
        mv \(quoted(installedAppPath)) "$backup" || exit 1
        \(targetAppPath == installedAppPath ? "" : "rm -rf " + quoted(targetAppPath))
        if ditto \(quoted(newAppPath)) \(quoted(targetAppPath)); then
          xattr -dr com.apple.quarantine \(quoted(targetAppPath)) 2>/dev/null
          rm -rf "$backup"
          open -g \(quoted(targetAppPath)) --args --background
        else
          rm -rf \(quoted(targetAppPath)); mv "$backup" \(quoted(installedAppPath))
          open -g \(quoted(installedAppPath)) --args --background
        fi
        """
    }
}
