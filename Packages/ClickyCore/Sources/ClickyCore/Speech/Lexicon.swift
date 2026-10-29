//
//  Lexicon.swift
//  ClickyCore
//
//  Respellings for the Qwen voice only: it reads "PR" as a word, "#12" as
//  "hash twelve" and "JSON" letter by letter. Applied to the text sent to
//  TTS, never to the caption; WordTiming spreads the ORIGINAL caption words
//  over the audio, so captions and tags stay on the words the user reads.
//

import Foundation

public enum Lexicon {
    /// (pattern, replacement), applied in order. Case-sensitive on purpose:
    /// "PR" is an acronym, "pr" is not.
    static let rules: [(pattern: String, replacement: String)] = [
        (#"\bCtrl\s*\+\s*Option\b"#, "Control Option"),
        (#"\bControl\s*\+\s*Option\b"#, "Control Option"),
        (#"#\s?(\d+)\b"#, "number $1"),
        (#"\bPRs\b"#, "P Rs"),
        (#"\bPR\b"#, "P R"),
        (#"\bGitHub\b"#, "Git Hub"),
        (#"\bXcode\b"#, "X code"),
        (#"\bSwiftUI\b"#, "Swift U I"),
        (#"\bJSON\b"#, "Jason"),
        (#"\bv(\d+(?:\.\d+)+)\b"#, "version $1")
    ]

    private static let compiledRules: [(NSRegularExpression, String)] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern)).map { ($0, rule.replacement) }
    }

    public static func apply(_ speech: String) -> String {
        compiledRules.reduce(speech) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }
}
