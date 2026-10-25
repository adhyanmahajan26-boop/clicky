//
//  RepoMatcher.swift
//  ClickyCore
//
//  Turns a spoken repo name ("altron engine") into a GitHub owner/name.
//  The app scans the repo roots (~/Projects, ~/Developer, depth 3) and
//  passes each clone's folder plus its origin/upstream URLs; optionally the
//  `gh api user/repos` full names too. Names are compared on [a-z0-9] only:
//  exact first, then Damerau-Levenshtein similarity. A clone's identity is
//  its origin (upstream only when there is no origin), and anything on the
//  hard denylist (farzaa/clicky, the upstream Clicky was forked from) is
//  never returned, so Clicky can't be pointed at someone else's repo.
//

import Foundation

/// owner/name parsed from a GitHub remote URL.
public struct GitHubRemote: Equatable, Hashable, Sendable {
    public var owner: String
    public var name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var fullName: String { "\(owner)/\(name)" }

    /// Parses https://github.com/o/n(.git), git@github.com:o/n.git,
    /// ssh://git@github.com(:22)/o/n.git and git://github.com/o/n.
    /// Returns nil for other hosts or malformed URLs.
    public static func parse(_ remoteURLString: String) -> GitHubRemote? {
        var remainder = remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        let lowercasedRemainder = remainder.lowercased()
        var pathPart: String
        if let schemeRange = lowercasedRemainder.range(of: "://") {
            let scheme = lowercasedRemainder[..<schemeRange.lowerBound]
            guard ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(String(scheme)) else { return nil }
            remainder = String(remainder[schemeRange.upperBound...])
            guard let firstSlash = remainder.firstIndex(of: "/") else { return nil }
            var authority = String(remainder[..<firstSlash])
            pathPart = String(remainder[remainder.index(after: firstSlash)...])
            if let atSign = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: atSign)...]) }
            if let colon = authority.firstIndex(of: ":") { authority = String(authority[..<colon]) }
            guard isGitHubHost(authority) else { return nil }
        } else if let colon = remainder.firstIndex(of: ":") {
            // scp-like: [user@]github.com:owner/name.git
            var hostPart = String(remainder[..<colon])
            if let atSign = hostPart.lastIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: atSign)...]) }
            guard isGitHubHost(hostPart) else { return nil }
            pathPart = String(remainder[remainder.index(after: colon)...])
        } else {
            return nil
        }
        if pathPart.hasPrefix("/") { pathPart.removeFirst() }
        while pathPart.hasSuffix("/") { pathPart.removeLast() }
        if pathPart.lowercased().hasSuffix(".git") { pathPart.removeLast(4) }
        let pathComponents = pathPart.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pathComponents.count == 2, let owner = pathComponents.first, let name = pathComponents.last,
              isValidGitHubPathComponent(owner), isValidGitHubPathComponent(name) else { return nil }
        return GitHubRemote(owner: owner, name: name)
    }

    private static func isGitHubHost(_ host: String) -> Bool {
        let lowercasedHost = host.lowercased()
        return lowercasedHost == "github.com" || lowercasedHost == "www.github.com" || lowercasedHost == "ssh.github.com"
    }

    private static func isValidGitHubPathComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        return component.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "-" || scalar == "_" || scalar == "."
        }
    }
}

/// One local clone found under the repo roots.
public struct LocalRepoEntry: Equatable, Sendable {
    public var folderPath: String
    public var originURL: String?
    public var upstreamURL: String?

    public init(folderPath: String, originURL: String? = nil, upstreamURL: String? = nil) {
        self.folderPath = folderPath
        self.originURL = originURL
        self.upstreamURL = upstreamURL
    }
}

public struct RepoCandidate: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// Matched a clone's origin repo name or its folder name.
        case localOrigin
        /// Matched only via a clone's upstream (identity is still origin when present).
        case localUpstream
        /// From the `gh api user/repos` list; no local clone.
        case githubAccount
    }

    /// owner/name.
    public var fullName: String
    /// The local clone, when there is one.
    public var folderPath: String?
    /// 0...1, 1 = exact normalized match.
    public var score: Double
    public var source: Source

    public init(fullName: String, folderPath: String?, score: Double, source: Source) {
        self.fullName = fullName
        self.folderPath = folderPath
        self.score = score
        self.source = source
    }
}

public struct RepoMatchResult: Equatable, Sendable {
    /// Best first, every score ≥ RepoMatcher.minimumCandidateScore.
    public var rankedCandidates: [RepoCandidate]

    public var top: RepoCandidate? { rankedCandidates.first }

    /// True when the top candidate scores ≥ 0.9 and beats the runner-up by
    /// at least RepoMatcher.uniquenessMargin (0.05): two equally good repos
    /// (say two exact "api" repos) always go to the chooser.
    public var isConfident: Bool {
        guard let top, top.score >= RepoMatcher.confidentScore else { return false }
        guard rankedCandidates.count > 1 else { return true }
        return top.score - rankedCandidates[1].score >= RepoMatcher.uniquenessMargin
    }

    /// What the chooser shows when not confident: the top 4.
    public var chooserCandidates: [RepoCandidate] { Array(rankedCandidates.prefix(RepoMatcher.chooserSize)) }
}

public struct RepoMatcher: Sendable {
    public static let confidentScore = 0.9
    /// The runner-up must score at least this much below the top for a match to be unique.
    public static let uniquenessMargin = 0.05
    public static let chooserSize = 4
    public static let minimumCandidateScore = 0.4
    /// A name matched only through `upstream` counts slightly less than the same name on origin.
    public static let upstreamScoreFactor = 0.95
    /// Never returned, whatever the remotes say (lowercased owner/name).
    public static let hardDenylist: Set<String> = ["farzaa/clicky"]

    public var localRepos: [LocalRepoEntry]
    /// Full names from `gh api user/repos` (`full_name`), passed in as data.
    public var accountRepoFullNames: [String]

    public init(localRepos: [LocalRepoEntry], accountRepoFullNames: [String] = []) {
        self.localRepos = localRepos
        self.accountRepoFullNames = accountRepoFullNames
    }

    /// Lowercased [a-z0-9] only: "Altron-Engine" and "altron engine" → "altronengine".
    public static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
    }

    public static func isDenied(_ fullName: String) -> Bool {
        hardDenylist.contains(fullName.lowercased())
    }

    public func match(spokenName: String) -> RepoMatchResult {
        let spokenKey = Self.normalize(spokenName)
        guard !spokenKey.isEmpty else { return RepoMatchResult(rankedCandidates: []) }
        var bestByFullName: [String: RepoCandidate] = [:]

        func offer(_ candidate: RepoCandidate) {
            guard !Self.isDenied(candidate.fullName), candidate.score >= Self.minimumCandidateScore else { return }
            let dedupeKey = candidate.fullName.lowercased()
            if let existing = bestByFullName[dedupeKey] {
                let candidateIsBetter = candidate.score > existing.score
                    || (candidate.score == existing.score && existing.folderPath == nil && candidate.folderPath != nil)
                if candidateIsBetter { bestByFullName[dedupeKey] = candidate }
            } else {
                bestByFullName[dedupeKey] = candidate
            }
        }

        for localRepo in localRepos {
            let originRemote = localRepo.originURL.flatMap(GitHubRemote.parse)
            let upstreamRemote = localRepo.upstreamURL.flatMap(GitHubRemote.parse)
            // Identity prefers origin; a clone with neither remote can't be acted on outward.
            guard let identityRemote = originRemote ?? upstreamRemote else { continue }
            let folderName = (localRepo.folderPath as NSString).lastPathComponent

            var originSideNames = [folderName]
            if let originRemote { originSideNames += [originRemote.name, originRemote.owner + originRemote.name] }
            let originSideScore = originSideNames.map { Self.score(spokenKey: spokenKey, against: $0) }.max() ?? 0

            var upstreamSideScore = 0.0
            if let upstreamRemote {
                let upstreamNames = [upstreamRemote.name, upstreamRemote.owner + upstreamRemote.name]
                upstreamSideScore = (upstreamNames.map { Self.score(spokenKey: spokenKey, against: $0) }.max() ?? 0) * Self.upstreamScoreFactor
            }

            if originRemote == nil, let upstreamRemote, Self.isDenied(upstreamRemote.fullName) { continue }
            if originSideScore >= upstreamSideScore {
                offer(RepoCandidate(fullName: identityRemote.fullName, folderPath: localRepo.folderPath, score: originSideScore, source: .localOrigin))
            } else {
                offer(RepoCandidate(fullName: identityRemote.fullName, folderPath: localRepo.folderPath, score: upstreamSideScore, source: .localUpstream))
            }
        }

        for accountFullName in accountRepoFullNames {
            let nameParts = accountFullName.split(separator: "/").map(String.init)
            guard nameParts.count == 2 else { continue }
            let accountScore = max(Self.score(spokenKey: spokenKey, against: nameParts[1]), Self.score(spokenKey: spokenKey, against: nameParts[0] + nameParts[1]))
            offer(RepoCandidate(fullName: accountFullName, folderPath: nil, score: accountScore, source: .githubAccount))
        }

        let ranked = bestByFullName.values.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if (left.folderPath != nil) != (right.folderPath != nil) { return left.folderPath != nil }
            return left.fullName.lowercased() < right.fullName.lowercased()
        }
        return RepoMatchResult(rankedCandidates: ranked)
    }

    /// 1 for an exact normalized match, else Damerau-Levenshtein similarity.
    static func score(spokenKey: String, against name: String) -> Double {
        let nameKey = normalize(name)
        guard !nameKey.isEmpty else { return 0 }
        if nameKey == spokenKey { return 1 }
        return damerauLevenshteinSimilarity(spokenKey, nameKey)
    }

    /// 1 − distance / longer length, in 0...1.
    public static func damerauLevenshteinSimilarity(_ first: String, _ second: String) -> Double {
        let longerLength = max(first.count, second.count)
        guard longerLength > 0 else { return 1 }
        return max(0, 1 - Double(damerauLevenshteinDistance(first, second)) / Double(longerLength))
    }

    /// Optimal-string-alignment distance: insert, delete, substitute, and
    /// swap two adjacent characters each cost 1.
    public static func damerauLevenshteinDistance(_ first: String, _ second: String) -> Int {
        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        let firstCount = firstCharacters.count
        let secondCount = secondCharacters.count
        if firstCount == 0 { return secondCount }
        if secondCount == 0 { return firstCount }
        var distances = Array(repeating: Array(repeating: 0, count: secondCount + 1), count: firstCount + 1)
        for rowIndex in 0...firstCount { distances[rowIndex][0] = rowIndex }
        for columnIndex in 0...secondCount { distances[0][columnIndex] = columnIndex }
        for rowIndex in 1...firstCount {
            for columnIndex in 1...secondCount {
                let substitutionCost = firstCharacters[rowIndex - 1] == secondCharacters[columnIndex - 1] ? 0 : 1
                var best = min(distances[rowIndex - 1][columnIndex] + 1,
                               distances[rowIndex][columnIndex - 1] + 1,
                               distances[rowIndex - 1][columnIndex - 1] + substitutionCost)
                if rowIndex > 1, columnIndex > 1,
                   firstCharacters[rowIndex - 1] == secondCharacters[columnIndex - 2],
                   firstCharacters[rowIndex - 2] == secondCharacters[columnIndex - 1] {
                    best = min(best, distances[rowIndex - 2][columnIndex - 2] + 1)
                }
                distances[rowIndex][columnIndex] = best
            }
        }
        return distances[firstCount][secondCount]
    }
}
