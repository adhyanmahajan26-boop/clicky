//
//  ProjectDestination.swift
//  ClickyCore
//
//  Which local project a named destination ("Mahajan motor work",
//  "scratch helpers project") means. Candidates are the local git repos
//  code mode indexes (LocalRepoIndexer over v2.code.repoRoots) plus the
//  folders his Claude Code sessions ran in: the NAMES of the directories
//  under ~/.claude/projects, decoded back to a path (ClaudeProjectDirectory;
//  their contents are never opened).
//
//  Scoring (0...1, the best of):
//    - words: the names' content words (generic words like project, repo,
//      app, code, claude, work, clicky dropped; "motors" = "motor"), as the
//      mean of the Dice and overlap coefficients;
//    - the joined names' Damerau-Levenshtein similarity (RepoMatcher's);
//    - initials: "Mahajan Motor India Works" → "mmi" against a short word
//      such as "mmi" in mmi-website (1.0 alone, 0.9 with other words, 0.8
//      when one letter more or less, so "Mahajan motor" → "mm" still finds
//      "mmi"), and the other way round.
//  A folder that isn't a git repo scores ×0.9 (code mode can't run there).
//
//  Decision: a saved alias (v2.code.projectAliases, the owner's earlier
//  pick) wins outright; else the top ≥ 0.75 with nobody within 0.1 runs;
//  else up to four rows within 0.1 of the top (or ≥ 0.5 when the top is
//  below 0.75) go on a pick card, the likeliest preselected — a folder with
//  a GitHub remote first, and for a photo / screenshot / web / site
//  request one whose name says web or site; nothing ≥ 0.5 → no match.
//

import Foundation

public struct ProjectFolderCandidate: Equatable, Hashable, Sendable {
    public enum Source: String, Sendable {
        /// A clone found under the repo roots.
        case localRepository
        /// A folder a Claude Code session ran in (~/.claude/projects, name decoded).
        case claudeProject
    }

    public var path: String
    public var isGitRepository: Bool
    /// The origin (or upstream) URL, when the repo has one.
    public var remoteURL: String?
    public var source: Source

    public init(path: String, isGitRepository: Bool, remoteURL: String? = nil, source: Source) {
        self.path = path
        self.isGitRepository = isGitRepository
        self.remoteURL = remoteURL
        self.source = source
    }

    public var folderName: String { (path as NSString).lastPathComponent }
    public var hasRemote: Bool { remoteURL.map { !$0.isEmpty } ?? false }

    /// Repos and decoded session folders merged by path (a repo's entry wins).
    public static func merged(repositories: [ProjectFolderCandidate], claudeProjects: [ProjectFolderCandidate]) -> [ProjectFolderCandidate] {
        var seenPaths = Set<String>()
        var merged: [ProjectFolderCandidate] = []
        for candidate in repositories + claudeProjects {
            let key = (candidate.path as NSString).standardizingPath
            if seenPaths.insert(key).inserted { merged.append(candidate) }
        }
        return merged
    }
}

public struct ScoredProjectCandidate: Equatable, Sendable {
    public var candidate: ProjectFolderCandidate
    public var score: Double

    public init(candidate: ProjectFolderCandidate, score: Double) {
        self.candidate = candidate
        self.score = score
    }
}

public enum ProjectDestinationDecision: Equatable, Sendable {
    /// The owner picked this folder for that name before.
    case alias(ProjectFolderCandidate)
    /// One clear winner.
    case confident(ScoredProjectCandidate)
    /// Several close ones (or none confident): the pick card, best preselected.
    case pick(candidates: [ScoredProjectCandidate], preselectedIndex: Int)
    case noMatch
}

public enum ProjectDestinationMatcher {
    public static let confidentScore = 0.75
    /// A runner-up this close to the top makes it a pick.
    public static let closeMargin = 0.1
    public static let minimumPickScore = 0.5
    public static let maximumPickRows = 4
    public static let nonGitFactor = 0.9

    static let genericWords: Set<String> = [
        "project", "repo", "repository", "app", "code", "claude", "claud", "cloud", "the", "my", "a", "an", "our", "folder",
        "work", "clicky", "local", "main"
    ]
    /// Request words that point at a website repo.
    static let webHintWords: Set<String> = [
        "photo", "picture", "image", "screenshot", "product", "web", "website", "site", "page", "landing", "deploy", "banner", "logo", "css", "html"
    ]

    // MARK: Words

    /// Lowercased [a-z0-9] runs, a plural "s" dropped ("motors" → "motor").
    public static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }.map { word in
            let wordText = String(word)
            if wordText.count > 3, wordText.hasSuffix("s"), !wordText.hasSuffix("ss") { return String(wordText.dropLast()) }
            return wordText
        }
    }

    /// The words without generic ones (all of them when only generic ones are left).
    public static func contentWords(_ text: String) -> [String] {
        let allWords = words(text)
        let content = allWords.filter { !genericWords.contains($0) }
        return content.isEmpty ? allWords : content
    }

    static func wordsMatch(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        guard min(first.count, second.count) >= 4 else { return false }
        return RepoMatcher.damerauLevenshteinSimilarity(first, second) >= 0.8
    }

    // MARK: Scoring

    public static func score(spokenName: String, candidateName: String) -> Double {
        let spokenWords = contentWords(spokenName)
        let candidateWords = contentWords(candidateName)
        guard !spokenWords.isEmpty, !candidateWords.isEmpty else { return 0 }

        let matchedCount = spokenWords.filter { spokenWord in candidateWords.contains { wordsMatch(spokenWord, $0) } }.count
        let dice = 2 * Double(matchedCount) / Double(spokenWords.count + candidateWords.count)
        let overlap = Double(matchedCount) / Double(min(spokenWords.count, candidateWords.count))
        let wordScore = (dice + overlap) / 2

        let joinedScore: Double = {
            let spokenKey = spokenWords.joined()
            let candidateKey = candidateWords.joined()
            if spokenKey == candidateKey { return 1 }
            return RepoMatcher.damerauLevenshteinSimilarity(spokenKey, candidateKey)
        }()

        let initialsScore = max(initialsMatch(longWords: spokenWords, shortWords: candidateWords),
                                initialsMatch(longWords: candidateWords, shortWords: spokenWords))
        return min(1, max(wordScore, joinedScore, initialsScore))
    }

    /// "mahajan motor india" (initials "mmi") against a short word "mmi" in the other name.
    static func initialsMatch(longWords: [String], shortWords: [String]) -> Double {
        guard longWords.count >= 2 else { return 0 }
        let initials = String(longWords.compactMap(\.first))
        var best = 0.0
        for shortWord in shortWords where (2...5).contains(shortWord.count) && shortWord.allSatisfy(\.isLetter) {
            let hasOtherWords = shortWords.count > 1
            if shortWord == initials {
                best = max(best, hasOtherWords ? 0.9 : 1)
            } else if abs(shortWord.count - initials.count) == 1, min(shortWord.count, initials.count) >= 2,
                      shortWord.hasPrefix(initials) || initials.hasPrefix(shortWord) {
                best = max(best, 0.8)
            }
        }
        return best
    }

    public static func score(spokenName: String, candidate: ProjectFolderCandidate) -> Double {
        let baseScore = score(spokenName: spokenName, candidateName: candidate.folderName)
        return candidate.isGitRepository ? baseScore : baseScore * nonGitFactor
    }

    /// Every candidate's score, best first (ties: git with a remote, then git, then path).
    public static func ranked(spokenName: String, candidates: [ProjectFolderCandidate]) -> [ScoredProjectCandidate] {
        candidates.map { ScoredProjectCandidate(candidate: $0, score: score(spokenName: spokenName, candidate: $0)) }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                if preferenceRank(left.candidate, isWebRequest: false) != preferenceRank(right.candidate, isWebRequest: false) {
                    return preferenceRank(left.candidate, isWebRequest: false) > preferenceRank(right.candidate, isWebRequest: false)
                }
                return left.candidate.path < right.candidate.path
            }
    }

    static func isWebRequest(_ requestText: String) -> Bool {
        words(requestText).contains(where: webHintWords.contains)
    }

    /// Higher is likelier: a remote, a git repo, and for web requests a name saying web/site.
    static func preferenceRank(_ candidate: ProjectFolderCandidate, isWebRequest: Bool) -> Int {
        var rank = 0
        if candidate.isGitRepository { rank += 1 }
        if candidate.hasRemote { rank += 2 }
        if isWebRequest, words(candidate.folderName).contains(where: { ["web", "website", "site", "landing", "www"].contains($0) }) { rank += 4 }
        return rank
    }

    public static func decide(spokenName: String, requestText: String, candidates: [ProjectFolderCandidate],
                              aliases: [String: String]) -> ProjectDestinationDecision {
        if let aliasPath = ProjectAliasBook.lookup(spokenName: spokenName, in: aliases) {
            let standardizedAliasPath = (aliasPath as NSString).standardizingPath
            if let aliasCandidate = candidates.first(where: { ($0.path as NSString).standardizingPath == standardizedAliasPath }) {
                return .alias(aliasCandidate)
            }
        }
        let rankedCandidates = ranked(spokenName: spokenName, candidates: candidates)
        guard let top = rankedCandidates.first, top.score >= minimumPickScore else { return .noMatch }
        let closeCandidates = rankedCandidates.filter { top.score - $0.score <= closeMargin + 1e-9 }
        if top.score >= confidentScore, closeCandidates.count == 1 { return .confident(top) }
        let rows: [ScoredProjectCandidate]
        if top.score >= confidentScore {
            rows = Array(closeCandidates.prefix(maximumPickRows))
        } else {
            rows = Array(rankedCandidates.filter { $0.score >= minimumPickScore }.prefix(maximumPickRows))
        }
        let webRequest = isWebRequest(requestText)
        // The likeliest among the closest ones, by preference, then score.
        let preselectedIndex = rows.indices.filter { top.score - rows[$0].score <= closeMargin + 1e-9 }.max { left, right in
            let leftRank = preferenceRank(rows[left].candidate, isWebRequest: webRequest)
            let rightRank = preferenceRank(rows[right].candidate, isWebRequest: webRequest)
            if leftRank != rightRank { return leftRank < rightRank }
            if rows[left].score != rows[right].score { return rows[left].score < rows[right].score }
            return left > right
        } ?? 0
        return .pick(candidates: rows, preselectedIndex: preselectedIndex)
    }
}

// MARK: - Aliases (v2.code.projectAliases)

/// The owner's picks: a spoken name ("mahajan motor work") → a folder path.
public enum ProjectAliasBook {
    /// Lowercased words, leading the/my and trailing "project(s)" dropped: "The Mahajan Motor Work project" → "mahajan motor work".
    public static func key(forSpokenName spokenName: String) -> String {
        var spokenWords = spokenName.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        while let first = spokenWords.first, ["the", "my", "a", "an", "our"].contains(first) { spokenWords.removeFirst() }
        while let last = spokenWords.last, ["project", "projects"].contains(last) { spokenWords.removeLast() }
        return spokenWords.joined(separator: " ")
    }

    public static func lookup(spokenName: String, in aliases: [String: String]) -> String? {
        let aliasKey = key(forSpokenName: spokenName)
        guard !aliasKey.isEmpty else { return nil }
        return aliases[aliasKey]
    }

    public static func adding(spokenName: String, path: String, to aliases: [String: String]) -> [String: String] {
        let aliasKey = key(forSpokenName: spokenName)
        guard !aliasKey.isEmpty, !path.isEmpty else { return aliases }
        var updated = aliases
        updated[aliasKey] = path
        return updated
    }

    public static func removing(key aliasKey: String, from aliases: [String: String]) -> [String: String] {
        var updated = aliases
        updated[aliasKey] = nil
        return updated
    }

    /// Sorted rows for the Agents dashboard.
    public static func rows(_ aliases: [String: String]) -> [(key: String, path: String)] {
        aliases.map { (key: $0.key, path: $0.value) }.sorted { $0.key < $1.key }
    }
}

// MARK: - The spoken answer to the pick card

public enum ProjectPickReply: Equatable, Sendable {
    case choose(Int)
    case cancel
    /// Not about the card: it goes away and the turn is handled normally.
    case notAReply

    private static let ordinalWords: [String: Int] = [
        "first": 0, "1st": 0, "one": 0, "top": 0, "second": 1, "2nd": 1, "two": 1, "third": 2, "3rd": 2, "three": 2, "fourth": 3, "4th": 3, "four": 3
    ]
    private static let pointerWords: Set<String> = ["that", "this", "highlighted", "selected", "it"]

    /// "the website one", "billing", "the first one", "yes" (the preselected row), "cancel".
    public static func parse(_ transcript: String, rows: [ProjectFolderCandidate], preselectedIndex: Int) -> ProjectPickReply {
        guard !rows.isEmpty else { return .notAReply }
        let spokenWords = NamedProjectTrigger.words(ProjectSendTrigger.withoutBracketedText(transcript).replacingOccurrences(of: "\u{2019}", with: "'"))
        guard !spokenWords.isEmpty, spokenWords.count <= 10 else { return .notAReply }
        switch SpokenConfirmation.parse(transcript) {
        case .yes: return .choose(min(max(0, preselectedIndex), rows.count - 1))
        case .no: return .cancel
        case .other: break
        }
        let plainWords = spokenWords.map { $0.replacingOccurrences(of: "'", with: "") }
        // A row's own words, without the ones every row shares ("mmi").
        let rowWords = rows.map { Set(ProjectDestinationMatcher.words($0.folderName)) }
        let sharedWords = rowWords.dropFirst().reduce(rowWords.first ?? []) { $0.intersection($1) }
        let stemmedSpoken = ProjectDestinationMatcher.words(plainWords.joined(separator: " "))
        let namedRows = rows.indices.filter { rowIndex in
            let distinctiveWords = rowWords[rowIndex].subtracting(sharedWords).subtracting(ProjectDestinationMatcher.genericWords)
            return stemmedSpoken.contains { spokenWord in distinctiveWords.contains { ProjectDestinationMatcher.wordsMatch(spokenWord, $0) } }
        }
        if namedRows.count == 1 { return .choose(namedRows[0]) }
        if plainWords.contains("last") { return .choose(rows.count - 1) }
        if plainWords.count <= 3, plainWords.contains(where: pointerWords.contains), plainWords.contains("one") {
            return .choose(min(max(0, preselectedIndex), rows.count - 1))
        }
        if let ordinalIndex = plainWords.compactMap({ ordinalWords[$0] }).first, ordinalIndex < rows.count, spokenWords.count <= 5 {
            return .choose(ordinalIndex)
        }
        return .notAReply
    }
}

// MARK: - ~/.claude/projects directory names

/// Claude Code keeps each folder's sessions in ~/.claude/projects/<the
/// folder's path with every non-alphanumeric character turned into "-">/
/// <session id>.jsonl. Only directory and file NAMES are read here (and
/// file modification dates); no file there is ever opened or written.
public enum ClaudeProjectDirectory {
    /// "/Users/a/mmi-website" → "-Users-a-mmi-website".
    public static func encodedName(forPath path: String) -> String {
        String(path.unicodeScalars.map { scalar in
            (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "-"
        })
    }

    /// The directory names worth decoding: under the home folder, not under
    /// ~/Library, no hidden path component ("--").
    public static func isCandidateName(_ directoryName: String, homeDirectory: String) -> Bool {
        let homePrefix = encodedName(forPath: homeDirectory) + "-"
        guard directoryName.hasPrefix(homePrefix), !directoryName.contains("--"), !directoryName.hasSuffix("-") else { return false }
        let rest = directoryName.dropFirst(homePrefix.count)
        return !rest.hasPrefix("Library-") && rest != "Library"
    }

    /// "-" in the name is "/", "-", "_", "." or " " in the path: the first
    /// spelling that exists as a folder wins ("/" tried first, so a wrong
    /// guess is pruned at once). Nil when none exists.
    public static func decodedPath(fromDirectoryName directoryName: String, isDirectory: (String) -> Bool, maximumChecks: Int = 3000) -> String? {
        guard directoryName.hasPrefix("-") else { return nil }
        let tokens = directoryName.dropFirst().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !tokens.isEmpty, !tokens.contains(where: \.isEmpty) else { return nil }
        var checksLeft = maximumChecks
        var cache: [String: Bool] = [:]
        func exists(_ path: String) -> Bool {
            if let cached = cache[path] { return cached }
            guard checksLeft > 0 else { return false }
            checksLeft -= 1
            let result = isDirectory(path)
            cache[path] = result
            return result
        }
        func search(_ tokenIndex: Int, parent: String, component: String, componentTokens: Int) -> String? {
            if tokenIndex == tokens.count {
                let fullPath = parent + "/" + component
                return exists(fullPath) ? fullPath : nil
            }
            let closedPath = parent + "/" + component
            if exists(closedPath), let found = search(tokenIndex + 1, parent: closedPath, component: tokens[tokenIndex], componentTokens: 1) {
                return found
            }
            guard componentTokens < 6 else { return nil }
            for separator in ["-", "_", ".", " "] {
                if let found = search(tokenIndex + 1, parent: parent, component: component + separator + tokens[tokenIndex], componentTokens: componentTokens + 1) {
                    return found
                }
            }
            return nil
        }
        return search(1, parent: "", component: tokens[0], componentTokens: 1)
    }

    /// The newest "<uuid>.jsonl" by modification date: its name is the session id.
    public static func newestSessionIdentifier(in entries: [(name: String, modificationDate: Date)]) -> String? {
        entries.filter { entry in
            guard entry.name.hasSuffix(".jsonl") else { return false }
            return UUID(uuidString: String(entry.name.dropLast(".jsonl".count))) != nil
        }
        .max { $0.modificationDate < $1.modificationDate }
        .map { String($0.name.dropLast(".jsonl".count)).lowercased() }
    }
}
