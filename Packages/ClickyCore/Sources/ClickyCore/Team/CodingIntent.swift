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
        ("बन जाए", "build"), ("चाहिए", "want"), ("भेज", "send"), ("रोक", "stop"), ("बंद कर", "stop"), ("कोड", "code"), ("आइडिया", "idea"), ("प्लान", "plan"),
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
