//
//  RoutineIntent.swift
//  ClickyCore
//
//  A routine runs a bot again and again with nobody watching, so Theo only adds one from a bot's ```routine block when the owner's own
//  words asked for something on a schedule. A bot that writes the block anyway (a page or memory file it read told it to, or its model
//  misbehaves) gets nothing: the block alone proves nothing about what the owner wanted.
//

import Foundation

public enum RoutineIntent {
    /// How a routine's run is posted in a chat, so it's never taken for the owner's own words.
    public static let runPrefix = "\u{23F0} Routine"

    /// True when these words are a routine's run rather than something the owner typed.
    public static func isRoutineRun(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(runPrefix)
    }

    /// The owner asked for something to happen on a schedule, or to change one.
    public static func ownerAsked(_ text: String) -> Bool {
        guard !isRoutineRun(text) else { return false }
        let lower = text.lowercased()
        let units = "minutes?|mins?|hours?|days?|nights?|mornings?|evenings?|afternoons?|weeks?|weekdays?|weekends?|months?|year|" +
            "mondays?|tuesdays?|wednesdays?|thursdays?|fridays?|saturdays?|sundays?|mon|tue|wed|thu|fri|sat|sun"
        let patterns = [
            #"\broutines?\b"#,
            #"\bremind(er|ers)?\b"#,
            #"\bschedul(e|ed|ing)\b"#,
            #"\b(daily|nightly|weekly|hourly|monthly|fortnightly)\b"#,
            #"\b(every|each)\s+(\d+\s+|other\s+|single\s+|few\s+|couple of\s+)?(\#(units))\b"#,
            #"\bon\s+(mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays|weekdays|weekends)\b"#,
            #"\b(once|twice)\s+a\s+(day|week|month)\b"#,
            #"\b(recurring|repeat(ing)?|cron)\b"#,
            #"\bevery\s+\d{1,2}(:\d{2})?\s*(am|pm)?\b"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}
