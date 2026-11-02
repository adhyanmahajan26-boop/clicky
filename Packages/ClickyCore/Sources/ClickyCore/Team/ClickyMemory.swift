//
//  ClickyMemory.swift
//  ClickyCore
//
//  What Memory keeps: what the owner said to Clicky in one file; what was asked to be remembered, Memory's summaries and
//  the finished work of Clicky's team in another. Two small JSON-lines files in the app's own folder, so it stays local and survives the Memory bot being
//  removed. Anything that looks like a secret is taken out before it's written.
//

import Foundation

public struct ClickyMemoryEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case said, remembered, summary, teamWork }
    public var at: Date
    public var kind: Kind
    public var text: String

    public init(at: Date = Date(), kind: Kind, text: String) {
        self.at = at
        self.kind = kind
        self.text = text
    }
}

public struct ClickyMemoryHit: Equatable, Sendable {
    public let at: Date
    public let kind: ClickyMemoryEntry.Kind
    public let text: String
}

/// What a job for Memory is asking for, from its words.
public enum ClickyMemoryTask: Equatable, Sendable {
    case remember(String)
    case find(String)
    case summarise

    public static func classify(_ task: String) -> ClickyMemoryTask {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.range(of: #"^(do you remember|remember (what|when|where|who|how|if)\b|what did|when did|did i\b|find\b|search\b|look up\b|list\b|collect\b|gather\b|pull\b|fetch\b|get\b|give\b|show\b)"#, options: .regularExpression) != nil { return .find(trimmed) }
        if lower.range(of: #"^summari[sz]e\b"#, options: .regularExpression) != nil { return .summarise }
        if let range = lower.range(of: #"^(please )?(remember|save|note|store|keep|don'?t forget)( down)?( this| that)?[:,]?\s*"#, options: .regularExpression) {
            let rest = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))...])
            return .remember(rest.isEmpty ? trimmed : rest)
        }
        // A plain statement ("Priya's birthday is in March") is something to keep; a question is something to look up.
        if lower.hasSuffix("?") || lower.range(of: #"^(what|when|where|who|why|how|which|is|are|was|were|does|do|did|has|have|can)\b"#, options: .regularExpression) != nil { return .find(trimmed) }
        return .remember(trimmed)
    }
}

public struct ClickyMemoryStore: Sendable {
    public let directory: URL
    /// After this many new things said, Memory writes a summary.
    public static let summaryEvery = 8
    public static let maximumEntries = 5000

    public init(directory: URL) {
        self.directory = directory
    }

    private var entriesFile: URL { directory.appendingPathComponent("said.jsonl") }
    private var summariesFile: URL { directory.appendingPathComponent("summaries.jsonl") }

    /// Commands and one-word answers aren't worth keeping.
    public static func isWorthKeeping(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 3
    }

    private static let secretPatterns: [NSRegularExpression] = [
        #"\b(?:sk|pk|rk|xai|gsk|ghp|gho)[-_][A-Za-z0-9_-]{12,}"#,
        #"(?i)\b(?:api[ _-]?key|token|password|passcode|secret|pin)\b\s*(?:is|was|:|=)\s*\S+"#,
        #"\b\d(?:[ -]?\d){12,18}\b"#,
        #"\b[A-Za-z0-9+/_-]{36,}={0,2}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func redacted(_ text: String) -> String {
        var cleaned = text
        for pattern in secretPatterns {
            cleaned = pattern.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "[hidden]")
        }
        return cleaned
    }

    @discardableResult
    public func append(_ text: String, kind: ClickyMemoryEntry.Kind, at: Date = Date()) -> ClickyMemoryEntry? {
        let trimmed = Self.redacted(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty, kind != .said || Self.isWorthKeeping(trimmed) else { return nil }
        let entry = ClickyMemoryEntry(at: at, kind: kind, text: trimmed)
        write(entry, to: kind == .said ? entriesFile : summariesFile)
        return entry
    }

    private func write(_ entry: ClickyMemoryEntry, to file: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file, options: .atomic)
        }
    }

    /// Writes a whole log at once.
    func replace(_ entries: [ClickyMemoryEntry], inSaidLog: Bool) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: inSaidLog ? entriesFile : summariesFile, options: .atomic)
    }

    private func read(_ file: URL) -> [ClickyMemoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(ClickyMemoryEntry.self, from: Data($0)) }
    }

    /// What was said, oldest first.
    public func entries() -> [ClickyMemoryEntry] { Array(read(entriesFile).suffix(Self.maximumEntries)) }
    /// What was saved on purpose, the summaries and the team's work, oldest first.
    public func summaries() -> [ClickyMemoryEntry] { read(summariesFile) }
    /// What Clicky's team finished, oldest first.
    public func teamWork() -> [ClickyMemoryEntry] { summaries().filter { $0.kind == .teamWork } }

    /// Things said since the last summary.
    public func unsummarised() -> [ClickyMemoryEntry] {
        let since = summaries().last { $0.kind == .summary }?.at ?? .distantPast
        return entries().filter { $0.at > since }
    }

    private static let stopWords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "is", "was", "were", "are", "it", "that", "this",
                                                 "i", "my", "me", "you", "did", "do", "does", "what", "when", "where", "who", "how", "about", "say", "said", "tell", "told",
                                                 "find", "search", "look", "up", "remember", "clicky", "asks", "ask"]

    /// Best matches first: more of the query's words, then the whole phrase, then newer.
    public func search(_ query: String, limit: Int = 12) -> [ClickyMemoryHit] {
        let words = Set(query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 && !Self.stopWords.contains($0) })
        let phrase = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let all = entries() + summaries()
        guard !words.isEmpty else { return all.suffix(limit).reversed().map { ClickyMemoryHit(at: $0.at, kind: $0.kind, text: $0.text) } }
        let scored = all.compactMap { entry -> (entry: ClickyMemoryEntry, score: Int)? in
            let lower = entry.text.lowercased()
            let tokens = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted))
            var score = words.reduce(0) { $0 + (tokens.contains($1) ? 2 : lower.contains($1) ? 1 : 0) }
            guard score > 0 else { return nil }
            if phrase.count > 3, lower.contains(phrase) { score += 3 }
            return (entry, score)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.at > $1.entry.at }
            .prefix(limit).map { ClickyMemoryHit(at: $0.entry.at, kind: $0.entry.kind, text: $0.entry.text) }
    }

    public static let nothingToKeep = "Nothing to keep."

    /// One finished job of the team, as it goes in the log.
    public static func teamWorkText(worker: String, task: String, result: String, savedPath: String? = nil) -> String {
        let cappedResult = result.count > maximumTeamWorkCharacters ? String(result.prefix(maximumTeamWorkCharacters)) + "…" : result
        let saved = savedPath.map { "\nSaved at: \($0)" } ?? ""
        return "\(worker) finished \"\(task.prefix(160))\":\n\(cappedResult)\(saved)"
    }

    public static let maximumTeamWorkCharacters = 6000

    /// The team's latest finished work, shortened, so Clicky and Theo know it came back.
    public func teamWorkContext(limit: Int = 4, charactersEach: Int = 500) -> String {
        let work = teamWork().suffix(limit).map { entry -> String in
            let text = entry.text.count > charactersEach ? String(entry.text.prefix(charactersEach)) + "…" : entry.text
            return "- \(ClickyTeamPrompts.day(entry.at)): \(text)"
        }
        guard !work.isEmpty else { return "" }
        return "what your team has finished lately (it's all saved, so ask memory for the rest):\n" + work.joined(separator: "\n")
    }

    /// The last few summaries and saved things, for the top of Clicky's turn. Empty when there's nothing yet.
    public func context(maximumCharacters: Int = 600) -> String {
        let recent = summaries().filter { $0.text != Self.nothingToKeep && $0.kind != .teamWork }.suffix(6).map(\.text)
        let work = teamWorkContext()
        guard !recent.isEmpty else { return work }
        let body = String(recent.joined(separator: "\n").suffix(maximumCharacters))
        let remembered = "the latest from your memory helper (use it only if it matters, don't recite it). it isn't the whole log, so if the user asks what they said before, hand that to memory:\n\(body)"
        return work.isEmpty ? remembered : remembered + "\n\n" + work
    }
}
