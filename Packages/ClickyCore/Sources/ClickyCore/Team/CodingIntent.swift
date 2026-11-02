//
//  CodingIntent.swift
//  ClickyCore
//
//  What the owner's words ask of a coding run: the model, the effort, stopping it, or talking an idea through first. Calls
//  come back in Devanagari ("टी थ्री कोड में, ओपस फाइव पॉइंट फाइव हाई पे"), so those words are put in English first.
//

import Foundation

public enum CodingIntent {
    private static let hindi: [(String, String)] = [
        ("फाइव पॉइंट फाइव", "5.5"), ("फोर पॉइंट एट", "4.8"), ("टी थ्री कोड", "t3 code"), ("टी थ्री", "t3 code"), ("कोडेक्स", "codex"),
        ("क्लॉड कोड", "claude code"), ("क्लाउड कोड", "claude code"), ("कर्सर", "cursor"), ("ओपन कोड", "opencode"), ("ग्रोक", "grok"), ("जेमिनी", "gemini"),
        ("ओपस", "opus"), ("सॉनेट", "sonnet"), ("हाइकू", "haiku"), ("हाई", "high"), ("मीडियम", "medium"),
        ("वेबसाइट", "website"), ("ऐप", "app"), ("गेम", "game"), ("प्रोजेक्ट", "project"), ("थ्रेड", "thread"), ("कैंसल", "cancel"), ("प्रॉम्प्ट", "prompt"),
        ("बनाएगा", "build"), ("बनाएंगे", "build"), ("बनाओ", "build"), ("बना दे", "build"), ("बनानी", "build"), ("बनाना", "build"),
        ("बन जाए", "build"), ("फोल्डर", "folder"), ("नया", "new"), ("नई", "new"), ("चाहिए", "want"), ("भेज", "send"), ("रोक", "stop"), ("बंद कर", "stop"), ("कोड", "code"), ("आइडिया", "idea"), ("प्लान", "plan"),
        ("में", " in "), ("पे", " on "), ("पर", " on "),
    ]

    public static func normalized(_ text: String) -> String {
        hindi.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// The model named, like "opus 5.5" or "gpt 6 luna". Nil when none was.
    public static func modelHint(in text: String) -> String? {
        let words = normalized(text).lowercased()
        for pattern in [#"\b(?:opus|sonnet|haiku|fable)\b(?:\s*\d+(?:[.\s]\d+)?)?"#, #"\bgpt[- ]?\d+(?:\.\d+)?(?:[- ][a-z]+)?"#] {
            if let range = words.range(of: pattern, options: .regularExpression) { return String(words[range]).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// "opus 5.5" → "claude-opus-5-5". Nil when it isn't a Claude model.
    public static func claudeModelID(forHint hint: String) -> String? {
        let parts = hint.split(separator: " ", maxSplits: 1).map(String.init)
        guard let family = parts.first, ["opus", "sonnet", "haiku", "fable"].contains(family) else { return nil }
        let version = parts.count > 1 ? parts[1] : (family == "fable" ? "5.1" : "5.5")
        return "claude-\(family)-\(version.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: " ", with: "-"))"
    }

    public static func effort(in text: String) -> String? {
        let words = normalized(text).lowercased()
        guard modelHint(in: text) != nil || words.contains("effort"),
              let range = words.range(of: #"\b(xhigh|high|medium|low|max)\b"#, options: .regularExpression) else { return nil }
        return String(words[range])
    }

    /// "Cancel the run", "stop that thread", "purana thread cancel karo".
    public static func asksToCancelRun(_ text: String) -> Bool {
        let words = normalized(text)
        let things = #"(run|thread|coding|agent|t3|codex|build)"#
        return words.range(of: #"(?i)\b(cancel|stop|kill|abort)\b.{0,40}\b"# + things + #"\b"#, options: .regularExpression) != nil
            || words.range(of: #"(?i)\b"# + things + #"\b.{0,30}\b(cancel|stop|kill|abort)\b"#, options: .regularExpression) != nil
    }

    /// An idea or a build, which the group talks through before anyone acts on it.
    public static func wantsDiscussion(_ text: String) -> Bool {
        normalized(text).range(of: #"(?i)\b(idea|plan|critique|discuss|what do you think|build|make|create|website|app|game|feature|design|prompt)\b"#, options: .regularExpression) != nil
    }

    /// The work worth passing on with a message: only what's about the same thing, best first.
    public static func relevantWork(for message: String, in work: [String], limit: Int = 2) -> [String] {
        let skipped: Set<String> = ["research", "researcher", "data", "clicky", "team", "brief", "photos", "photo", "notes", "send", "group", "with", "from", "that",
                                    "this", "what", "have", "they", "them", "into", "want", "fully", "make", "build", "website", "page", "file", "collected", "gather"]
        let words = Set(normalized(message).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 && !skipped.contains($0) })
        let scored = work.enumerated().compactMap { index, text -> (index: Int, score: Int, text: String)? in
            let lower = text.lowercased()
            let score = words.filter { lower.contains($0) }.count
            return score >= 2 ? (index, score, text) : nil
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index > $1.index }.prefix(limit).map(\.text)
    }
}

/// Which folder the owner's words are about: a new one they named, or a project they already have.
public enum ProjectWords {
    private static let notNames: Set<String> = ["for", "and", "in", "to", "on", "with", "the", "a", "an", "it", "this", "that", "please", "then", "or", "folder", "project"]

    /// "New folder called moon-site", "make a new project named Moon Site". Nil without a name.
    public static func newFolderName(in text: String) -> String? {
        let words = CodingIntent.normalized(text)
        let tail = #"[\"'`]?([\w][\w .-]{0,40}?)[\"'`]?(?=\s+(?:and|then|in|on|with|for)\b|\s*[.,!?\n]|\s*$)"#
        for pattern in [#"(?i)\bnew\s+(?:folder|project)\s+(?:called|named|name|as)\s+"# + tail, #"(?i)\b(?:folder|project)\s+(?:called|named)\s+"# + tail, #"(?i)\bnew\s+(?:folder|project)\s+"# + tail] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)),
                  let range = Range(match.range(at: 1), in: words) else { continue }
            let name = words[range].trimmingCharacters(in: .whitespaces)
            if !notNames.contains(name.lowercased()) { return name }
        }
        return nil
    }

    /// Only a folder asked for, with nothing to build in it yet.
    public static func asksOnlyForFolder(_ text: String) -> Bool {
        guard let name = newFolderName(in: text) else { return false }
        return CodingIntent.normalized(text).replacingOccurrences(of: name, with: "").range(of: #"(?i)\b(website|site|app|page|game|tool|script|dashboard|build|code|fix|write|add)\b"#, options: .regularExpression) == nil
    }

    /// The project these words talk about, out of the ones there are: "changes in the planets quiz", "moon-phases-page project".
    public static func namedProject(in text: String, among names: [String]) -> String? {
        let words = CodingIntent.normalized(text)
        for name in names.sorted(by: { $0.count > $1.count }) {
            let parts = name.split(whereSeparator: { "-_ ".contains($0) }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !parts.isEmpty else { continue }
            let flexible = parts.joined(separator: "[-_ ]?")
            let pattern = "(?i)\\b(?:in|on|to|into|inside|at|for|of)\\s+(?:the\\s+|my\\s+|that\\s+)?\(flexible)\\b|\\b\(flexible)\\s+(?:project|folder|repo|in|on)\\b"
            if words.range(of: pattern, options: .regularExpression) != nil { return name }
        }
        return nil
    }

    public static func asksToWork(_ text: String) -> Bool {
        CodingIntent.normalized(text).range(of: #"(?i)\b(change|changes|fix|update|edit|add|improve|continue|work|modify|redo|build|make)\b|बदल|ठीक"#, options: .regularExpression) != nil
    }

    /// What a bot wrote, inline or on its own line: "Repo: ~/Projects/foo", "New folder: foo".
    public static func labeled(_ label: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?im)\\*{0,2}\\b\(label):\\*{0,2}\\s*[`\"']?([~/\\w][\\w ./-]*?)[`\"']?\\s*(?:$|[,;\\]]|\\.\\s)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// "Clicky, work on the Air", "switch to the Studio": which Mac Clicky should work on. "air" or "studio", nil for anything else.
public enum ClickyMachineWords {
    public static func choice(in text: String) -> String? {
        let words = CodingIntent.normalized(text).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\b(work|use|switch|move|go|run|stay)\b.{0,25}\b(?:on|to)\s+(?:the\s+|my\s+)?(mac\s?book\s?air|mac\s?book|air|mac\s?studio|studio)\b\s*(?:for now|please|now)?[.!?]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)),
              let range = Range(match.range(at: 2), in: words) else { return nil }
        return words[range].contains("studio") ? "studio" : "air"
    }
}
