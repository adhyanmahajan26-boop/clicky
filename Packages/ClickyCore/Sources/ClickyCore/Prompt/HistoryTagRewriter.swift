//
//  HistoryTagRewriter.swift
//  ClickyCore
//
//  Conversation history is sent as plain text only. Old answers keep what
//  they pointed at in words ("(pointed at Share)") but never coordinates,
//  screen numbers or ids, which would be stale on the next screenshot.
//

import Foundation

public enum HistoryTagRewriter {
    public static func wordsForHistory(_ responseText: String) -> String {
        var rewrittenText = responseText

        rewrittenText = replace(#"\[POINT:none\]"#, in: rewrittenText) { _ in "" }
        rewrittenText = replace(#"\[POINT:[^\]]*\]"#, in: rewrittenText) { tag in
            label(fromTag: tag, fieldIndex: 2).map { "(pointed at \($0))" } ?? "(pointed)"
        }
        rewrittenText = replace(#"\[MARK:[^\]]*\]"#, in: rewrittenText) { tag in
            label(fromTag: tag, fieldIndex: 3).map { "(marked \($0))" } ?? "(marked something)"
        }
        rewrittenText = replace(#"\[WORKER:[^\]]*\]"#, in: rewrittenText) { _ in "" }

        return rewrittenText
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The label field of a tag, skipping coordinates and screenN fields.
    /// POINT: [POINT:x,y:label:screenN]  MARK: [MARK:kind:x,y:label:screenN]
    private static func label(fromTag tag: String, fieldIndex: Int) -> String? {
        let innerText = tag.dropFirst().dropLast()
        let fields = innerText.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count > fieldIndex - 1 else { return nil }
        let candidates = fields.dropFirst(fieldIndex - 1).filter { field in
            !field.isEmpty
                && field.range(of: #"^screen\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) == nil
                && field.range(of: #"^-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?$"#, options: .regularExpression) == nil
        }
        return candidates.first
    }

    private static func replace(_ pattern: String, in text: String, with makeReplacement: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        var resultText = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let matchRange = Range(match.range, in: resultText) else { continue }
            resultText.replaceSubrange(matchRange, with: makeReplacement(String(resultText[matchRange])))
        }
        return resultText
    }
}
