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
        // Each tag (any v2 or legacy form) becomes words; unknown ones vanish.
        for parsedTag in MarkTagParser.extractAll(responseText).tags {
            guard let tagRange = rewrittenText.range(of: parsedTag.raw) else { continue }
            rewrittenText.replaceSubrange(tagRange, with: words(for: parsedTag))
        }
        // Malformed POINT/MARK tags are dropped like in speech.
        rewrittenText = MarkTagParser.extractAll(rewrittenText).speechText
        rewrittenText = replace(#"\[WORKER:[^\]]*\]"#, in: rewrittenText) { _ in "" }

        return rewrittenText
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "(pointed at Share)", "(marked file menu)"; the name, else the quoted
    /// text the tag searched for, never an id or a coordinate.
    static func words(for parsedTag: ParsedTag) -> String {
        if parsedTag.kind == .clear { return "" }
        if case .none = parsedTag.target { return "" }
        var thingName = parsedTag.name
        if thingName == nil, case .text(let searchedText, _, _) = parsedTag.target {
            thingName = searchedText
        }
        let verb = parsedTag.kind == .point ? "pointed at" : "marked"
        if let thingName, !thingName.isEmpty {
            return "(\(verb) \(thingName))"
        }
        return parsedTag.kind == .point ? "(pointed)" : "(marked something)"
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
