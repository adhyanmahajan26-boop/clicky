//
//  SpaceLocalBrain.swift
//  ClickyCore
//
//  For the X Space bot on a local model: the owner's ideology file, added to each turn, and the few lines that keep the
//  bot's X account from being banned, applied quietly to what the local model says.
//

import Foundation

public enum SpaceIdeology {
    /// What a new ideology file starts with. Lines in <!-- --> are notes for the owner and never reach the bot.
    public static let template = """
    <!-- Chotta Tirri's ideology. Edit freely; it's read again on the bot's next turn, no restart needed.
         Write in plain words. Empty sections are left out. -->

    ## Worldview
    -

    ## Opinions on topics
    -

    ## Style
    -

    ## Catchphrases
    -

    ## People he likes
    -

    ## People he roasts
    -
    """

    /// The file's words for the bot: notes and empty sections left out. Empty when there's nothing to say.
    public static func cleaned(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        var sections: [String] = []
        var heading = ""
        var body: [String] = []
        func close() {
            let lines = body.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "-" && $0 != "*" }
            if !lines.isEmpty { sections.append((heading.isEmpty ? "" : heading + "\n") + lines.joined(separator: "\n")) }
            body = []
        }
        for line in cleaned.components(separatedBy: .newlines) {
            if line.hasPrefix("#") { close(); heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } else { body.append(line) }
        }
        close()
        cleaned = sections.joined(separator: "\n")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The line for the brain, or nil when the file says nothing.
    public static func note(_ text: String, owner: String) -> String? {
        let words = cleaned(text)
        guard !words.isEmpty else { return nil }
        return "(Your ideology, written by \(owner); speak from it, never mention it:\n\(String(words.prefix(4000))))"
    }
}

/// The local model says what it likes, except what gets an X account banned: slurs, threats or calls for violence against
/// people or groups, someone's private details, and explicit sexual content. A sentence with any of it isn't said; a
/// short line of the bot's own goes instead, with no lecture.
public enum SpaceSafetyFilter {
    public enum Reason: String, Sendable { case slur, threat, privateDetails, sexual }

    static let slurs: [String] = [
        // English
        "nigger", "nigga", "faggot", "fagot", "tranny", "chink", "kike", "spic", "retard", "paki",
        // Hindi / Urdu, Roman
        "chamar", "bhangi", "chuhra", "katua", "katwa", "suar ki aulad", "randi", "kanjar",
        // Devanagari
        "चमार", "भंगी", "चूहड़ा", "कटुआ", "कटवा", "रंडी",
    ]
    static let threats: [String] = [
        "kill you", "kill them", "kill all", "i will kill", "shoot them", "bomb maar", "bomb se uda", "behead", "burn them", "lynch",
        "maar dunga", "maar denge", "maar daalo", "maar dalo", "jaan se maar", "kaat dunga", "kaat do", "jala do", "jala denge", "khatam kar do",
        "मार दूंगा", "मार दूँगा", "मार डालो", "जान से मार", "काट दो", "जला दो", "ख़त्म कर दो", "खत्म कर दो",
    ]
    static let sexual: [String] = [
        "sex karo", "sex karna", "chudai", "chodna", "chodne", "lund", "boobs", "nude", "nudes", "porn", "blowjob", "dick pic", "horny",
        "चोद", "चुद", "लंड", "चूत",
    ]

    /// Why a sentence can't be said, or nil.
    public static func reason(_ sentence: String) -> Reason? {
        let lower = " " + sentence.lowercased().replacingOccurrences(of: #"[^\p{L}\p{M}\p{N}@.+ ]"#, with: " ", options: .regularExpression) + " "
        func hasWord(_ list: [String]) -> Bool {
            list.contains { term in
                let pattern = "(?<![\\p{L}\\p{M}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{M}])"
                return lower.range(of: pattern, options: .regularExpression) != nil
            }
        }
        if hasWord(slurs) { return .slur }
        if hasWord(threats) { return .threat }
        if hasWord(sexual) { return .sexual }
        // A phone number, an email or a street address read out.
        if sentence.range(of: #"(?<!\d)(?:\+?91[\s-]?)?[6-9]\d{4}[\s-]?\d{5}(?!\d)"#, options: .regularExpression) != nil
            || sentence.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil
            || lower.range(of: #"(ghar ka address|home address|rehta hai .{0,20}(gali|sector|flat|house no)|पता है .{0,20}(गली|सेक्टर|फ्लैट))"#, options: .regularExpression) != nil {
            return .privateDetails
        }
        return nil
    }

    /// What's said in its place: short, in the bot's voice, no lecture.
    public static func deflection(turn: Int) -> String {
        let lines = ["Chhodo yaar, ye wala line rehne do.", "Ispe main chup hi theek hun, bhai.", "Arre, isse aage main nahi jaunga, next topic."]
        return lines[abs(turn) % lines.count]
    }
}
