//
//  BotReadScope.swift
//  ClickyCore
//
//  What a bot may read, kept as narrow as what it may write. A bot reads its own memory folder, the shared guide beside it, the
//  project folders coding runs use, and any file or folder the owner's own words name in that turn (a path they typed, or a file
//  they attached). Nothing a page or another bot says opens anything: only the owner's words are searched for paths.
//

import Foundation

public enum BotReadScope {
    /// Paths named in the owner's words: absolute (`/Users/…`) or home-relative (`~/…`), written plainly, in quotes or backticks, or on
    /// an attachment line ("- /path/to/file", which may hold spaces). Too-broad ones (the whole disk, the whole home) are left out.
    public static func paths(in ownerWords: String, home: String) -> [String] {
        var found: [String] = []
        let text = ownerWords.replacingOccurrences(of: "\u{2019}", with: "'")
        // A whole attachment line, spaces and all.
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- /") || trimmed.hasPrefix("- ~/") { found.append(String(trimmed.dropFirst(2))) }
        }
        // Quoted or backticked paths, which may hold spaces.
        let quoted = try! NSRegularExpression(pattern: #"["'`]((?:~|/)[^"'`\n]+)["'`]"#)
        for match in quoted.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text) { found.append(String(text[range])) }
        }
        // Plain ones, up to the first space.
        let plain = try! NSRegularExpression(pattern: #"(?:^|[\s(\[])((?:~/|/)[^\s"'`)\],;]+)"#)
        for match in plain.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text) { found.append(String(text[range])) }
        }
        var seen: Set<String> = []
        return found.compactMap { raw -> String? in
            var path = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?"))
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard isNarrowEnough(path, home: home), seen.insert(path).inserted else { return nil }
            return path
        }
    }

    /// The whole disk, the whole home, or a top-level system folder would open everything: those are never taken from words.
    static func isNarrowEnough(_ path: String, home: String) -> Bool {
        guard !path.contains("..") else { return false }
        let absolute = path.hasPrefix("~") ? home + path.dropFirst() : path
        let parts = absolute.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return false }
        let homeParts = home.split(separator: "/").count
        if absolute.hasPrefix(home) { return parts.count > homeParts }
        // Outside home: at least two levels down (/Volumes/Drive, /opt/thing), and never the system's own folders.
        return !["System", "Library", "private", "etc", "var", "usr", "bin", "sbin", "dev", "cores"].contains(parts[0])
    }

    /// The permission rules for those paths: the file itself and, if it's a folder, everything in it.
    /// `~/x` stays as it is (the engine reads it from its own home); an absolute path gets the double slash Claude Code's rules want.
    public static func readRules(for paths: [String]) -> [String] {
        paths.flatMap { path -> [String] in
            let rule = path.hasPrefix("~") ? path : "/" + path
            return ["Read(\(rule))", "Read(\(rule)/**)", "Grep(\(rule))", "Grep(\(rule)/**)", "Glob(\(rule)/**)"]
        }
    }
}
