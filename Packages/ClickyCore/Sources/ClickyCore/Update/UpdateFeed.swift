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
    /// The Info.plist key holding the releases repo (owner/name). The build fills it from THEO_RELEASES_REPO in
    /// Config/Theo.xcconfig, the one place the Mac side keeps it, so a fork changes it there and nowhere in Swift.
    public static let releasesRepositoryInfoKey = "TheoReleasesRepository"

    /// The releases repo this build of the app was made for, from its Info.plist. Nil when the build didn't set one.
    public static var bundledReleasesRepository: String? {
        releasesRepository(fromInfoValue: Bundle.main.object(forInfoDictionaryKey: releasesRepositoryInfoKey) as? String)
    }

    /// The updates feed of this build: its releases repo's newest release (GitHub API, no sign-in for a public repo).
    public static var bundledFeedURL: URL? {
        bundledReleasesRepository.flatMap(latestReleaseFeedURL(repository:))
    }

    /// "owner/name" when the Info.plist value looks like a GitHub repo. Nil for an empty value or one the build left
    /// unexpanded ("$(THEO_RELEASES_REPO)"), so a build without the setting says so instead of asking a wrong URL.
    public static func releasesRepository(fromInfoValue infoValue: String?) -> String? {
        let repository = (infoValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
        }) else { return nil }
        return repository
    }

    /// GitHub's "latest release" API URL for a repo (owner/name).
    public static func latestReleaseFeedURL(repository: String) -> URL? {
        guard let checkedRepository = releasesRepository(fromInfoValue: repository) else { return nil }
        return URL(string: "https://api.github.com/repos/\(checkedRepository)/releases/latest")
    }

    /// The repo's releases page, for a person to open in a browser.
    public static func releasesPageURL(repository: String) -> URL? {
        guard let checkedRepository = releasesRepository(fromInfoValue: repository) else { return nil }
        return URL(string: "https://github.com/\(checkedRepository)/releases/latest")
    }

    /// What a failed update check tells the person, from GitHub's answer. GitHub answers 404 both for a repo
    /// that doesn't exist and for a private repo the request can't see, so without a token the honest answer is
    /// that this build's updates are private (not a sign-in instruction most people can't follow).
    public static func checkFailureMessage(statusCode: Int, sentToken: Bool, repository: String?) -> String {
        let repositoryName = repository ?? "the updates repo"
        switch statusCode {
        case 404 where !sentToken:
            return "This build's updates are private, so this Mac can't see them. If you were given access to \(repositoryName), "
                + "paste a GitHub token that can read it below. Otherwise, new builds come from whoever gave you Theo."
        case 404:
            return "No updates found: \(repositoryName) has no published build yet, or the saved GitHub token can't read it."
        case 401:
            return "GitHub refused the saved token. Paste a new one below, or remove it if the updates are public."
        case 403, 429:
            return "GitHub is limiting how often this Mac can check for updates. Theo tries again later by itself."
        default:
            return "The update check answered \(statusCode)."
        }
    }

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
