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
        // The same router that streams answers: tags become words, WORKER
        // lines and blocks disappear, malformed tags are dropped.
        var router = ResponseRouter()
        var rewrittenText = ""
        var tagsByIndex: [Int: ParsedTag] = [:]
        var placeholderIndex = 0
        for output in router.feed(responseText) + router.finish() {
            switch output {
            case .tag(let index, let tag):
                tagsByIndex[index] = tag
            case .narration(let text):
                for character in text {
                    if character == ResponseRouter.placeholder {
                        // A marker per tag, replaced by its words below.
                        rewrittenText += "\u{1}\(placeholderIndex)\u{1}"
                        placeholderIndex += 1
                    } else {
                        rewrittenText.append(character)
                    }
                }
            case .worker, .block, .unsupportedBlock, .dropped, .codeModeToggle, .agentsDashboard, .notesCommand:
                break
            }
        }
        for (index, tag) in tagsByIndex {
            rewrittenText = rewrittenText.replacingOccurrences(of: "\u{1}\(index)\u{1}", with: words(for: tag))
        }
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
}
