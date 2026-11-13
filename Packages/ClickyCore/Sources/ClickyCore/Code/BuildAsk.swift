//
//  BuildAsk.swift
//  ClickyCore
//
//  Did the owner's own words ask for code? A coding run's agent works with full access to the Mac, so a final prompt only starts a run
//  by itself when they did. A bot's answer can always carry a ```prompt block (a page told it to, or its model misbehaves), so this is
//  the check that stops a bot getting a shell out of "what's the fix for a squeaky door?" or "ship me a summary".
//
//  The rule: a word for making or changing something, followed in the same sentence (within a few words) by a thing that is code, or a
//  path; or a plain go-ahead ("build it", "ship that"); or a pull request or a refactor. A question about something else that happens to
//  use "build", "fix", "ship" or "make" doesn't count.
//

import Foundation

public enum BuildAsk {
    static let verbs = "build|ship|fix|make|create|write|add|change|update|implement|develop|scaffold|set up|deploy|debug|code|rewrite|port|want|need"
    static let things = "apps?|application|site|website|webpage|web page|landing page|page|game|tool|cli|api|dashboard|feature|function|method|class|" +
        "tests?|test suite|code|codebase|repo|repository|folder|project|script|bugs?|crash|error|parser|component|endpoint|server|backend|frontend|" +
        "database|schema|extension|plugin|bot|library|package|module|ui|button|form|screen|branch|commit|migration|workflow|pipeline|" +
        "ci|program|prototype|mvp|widget|chrome extension|mac app|ios app|cli tool|command|binary|build"

    public static func matches(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        // A pull request or a refactor is only ever about code.
        if lower.range(of: #"\b(refactor(ing)?|pull request)\b"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"\b(open|make|create|raise|draft|send)\s+(me\s+)?(a\s+|the\s+)?(draft\s+)?pr\b"#, options: .regularExpression) != nil { return true }
        // A plain go-ahead for what's on the table.
        if lower.range(of: #"\b(build|ship|code|implement|start)\s+(it|this|that|them)\b"#, options: .regularExpression) != nil { return true }
        // "update me on …", "make me laugh": about the owner, not a thing.
        let verb = #"\b(\#(verbs))\b(?!\s+me\s+(on|about|with|laugh|smile|feel)\b)"#
        // Up to five words between, none ending a sentence or a clause.
        let gap = #"(\s+[^\s.?!:;,]+){0,5}?"#
        if lower.range(of: verb + gap + #"\s+(\#(things))\b"#, options: .regularExpression) != nil { return true }
        // A path in the same sentence: "fix the parser in ~/Projects/foo".
        if lower.range(of: verb + #"[^.?!\n]*?(~/|/users/|\bprojects/|\.(swift|py|js|ts|tsx|jsx|go|rs|rb|java|kt|c|cpp|h|m|html|css|json|yml|yaml|sh)\b)"#, options: .regularExpression) != nil { return true }
        return false
    }
}
