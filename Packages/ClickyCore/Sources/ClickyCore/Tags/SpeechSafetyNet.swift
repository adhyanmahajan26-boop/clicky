//
//  SpeechSafetyNet.swift
//  ClickyCore
//
//  The prompt tells the model never to say element ids aloud. This catches
//  the ones that slip through: "#57" is stripped only when 57 is an id in
//  this turn's registry and it isn't part of something real like "PR #12",
//  "issue #3", "number #4" or "No. #5". Every strip is counted as a leak.
//

import Foundation

public enum SpeechSafetyNet {
    public struct Result: Equatable, Sendable {
        public let speechText: String
        public let leakCount: Int
    }

    private static let protectedPrefixPattern = #"(?i)(?:\bpr|\bpull request|\bissue|\bnumber|\bno\.?|\bticket|\bbug)\s*$"#

    public static func clean(_ speechText: String, liveElementIDs: Set<Int>) -> Result {
        guard !liveElementIDs.isEmpty,
              let idRegex = try? NSRegularExpression(pattern: #"#\s?(\d+)\b"#) else {
            return Result(speechText: speechText, leakCount: 0)
        }
        var cleanedText = speechText
        var leakCount = 0
        let matches = idRegex.matches(in: speechText, range: NSRange(speechText.startIndex..., in: speechText))
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: cleanedText),
                  let numberRange = Range(match.range(at: 1), in: cleanedText),
                  let elementID = Int(cleanedText[numberRange]),
                  liveElementIDs.contains(elementID) else { continue }
            let textBefore = String(cleanedText[..<matchRange.lowerBound])
            if textBefore.range(of: protectedPrefixPattern, options: .regularExpression) != nil { continue }
            cleanedText.removeSubrange(matchRange)
            leakCount += 1
        }
        let tidiedText = cleanedText
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([.,!?;:])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(speechText: tidiedText, leakCount: leakCount)
    }

    /// The acceptance check on raw narration (before cleaning): live-id
    /// mentions that would be stripped, plus words that only make sense for
    /// Clicky's own overlay ("badge(s)", "element list", "list of elements").
    /// A plain "the list" is NOT counted: it is usually an on-screen list.
    public static func countBadgeMentions(in narration: String, liveElementIDs: Set<Int>) -> Int {
        let idMentions = clean(narration, liveElementIDs: liveElementIDs).leakCount
        let wordMentions = ["badge", "element list", "elements list", "list of elements"].reduce(0) { mentionCount, phrase in
            mentionCount + narration.lowercased().components(separatedBy: phrase).count - 1
        }
        return idMentions + wordMentions
    }
}
