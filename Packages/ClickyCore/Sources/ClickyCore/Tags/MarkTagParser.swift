//
//  MarkTagParser.swift
//  ClickyCore
//
//  The one grammar for tags in Claude's answers (hand-written, so quoting
//  and escapes behave exactly as specified):
//
//    [POINT:target[:label][:screenN]]
//    [MARK:style:target[:label][:screenN]]
//    [CLEAR]
//    [SNAP:screen|window|marks[+marks]]   (SnapshotTag.swift says what each covers)
//    [SNAP:board]                          (save the open whiteboard, PDF + PNG)
//
//    style   circle | box | arrow | underline | spot | 1..9   (unknown → circle;
//            a target in the style slot also means circle: [MARK:#57:Share])
//    target  #n[@x,y] | #a-#b | "text"[~k][ in #n] | x,y | x,y,r (legacy → box)
//            | x,y,w,h | none
//    label   name[|note], up to the closing ] (a trailing :screenN is cut first)
//
//  Keywords are case-insensitive, a space is allowed after "[" and around
//  ":", "," and "|". A "]" inside quotes doesn't close a tag and \" escapes
//  a quote. Coordinates are model pixels of SCREEN N (default 1); decimals
//  are rounded.
//

import CoreGraphics
import Foundation

public enum MarkStyle: Equatable, Sendable {
    case circle
    case box
    case arrow
    case underline
    case spot
    /// Numbered step badge 1...9.
    case step(Int)
}

public enum MarkTarget: Equatable, Sendable {
    /// An element from the list, optionally with the model's guess of where it is.
    case element(id: Int, hint: CGPoint?)
    /// Elements #from through #to, as one box.
    case span(fromID: Int, toID: Int)
    /// Exact on-screen text; `occurrence` is ~k (1-based), `scopeID` is "in #n".
    case text(String, occurrence: Int?, scopeID: Int?)
    case point(CGPoint)
    case box(CGRect)
    case none
}

public struct ParsedTag: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case point
        case mark
        case clear
        case snap
    }

    public let kind: Kind
    public let style: MarkStyle?
    public let target: MarkTarget
    public let name: String?
    public let note: String?
    public let screenNumber: Int?
    /// What a [SNAP:…] asks for (nil for every other kind).
    public let snapshot: SnapshotRequest?
    public let raw: String
    /// The model wrote a style keyword (circle, box, arrow, underline, spot
    /// or a step number). False for [MARK:#57:Share] and unknown styles,
    /// which fall back to circle: only those (and steps) may be turned into
    /// an underline on a dense text row.
    public var hasExplicitStyle: Bool = false

    /// What to write on screen next to the mark: the note, else the name for
    /// arrows and numbered steps, else nothing.
    public var displayText: String? {
        if let note, !note.isEmpty { return note }
        switch style {
        case .arrow?, .step?:
            return name
        default:
            return nil
        }
    }

    /// SCREEN n the coordinates refer to (1 when not given).
    public var effectiveScreenNumber: Int { screenNumber ?? 1 }
}

public enum MarkTagParser {
    public static let maximumLabelLength = 80

    public struct Extraction: Equatable, Sendable {
        /// Valid tags in the order they appear.
        public let tags: [ParsedTag]
        /// The answer with every tag (valid or not) removed: what gets spoken.
        public let speechText: String
        /// Tag-looking spans that didn't parse (removed from speech anyway).
        public let malformedTagCount: Int
    }

    /// Finds every [POINT…], [MARK…] and [CLEAR] in order. Malformed ones are
    /// dropped but still removed from the spoken text. Anything else in
    /// brackets (e.g. [WORKER…], "items[0]") is left alone.
    public static func extractAll(_ responseText: String) -> Extraction {
        var tags: [ParsedTag] = []
        var malformedTagCount = 0
        var speechCharacters = ""
        let characters = Array(responseText)
        var index = 0

        while index < characters.count {
            if characters[index] == "[", let keyword = keywordAfterBracket(characters, from: index) {
                guard let closingIndex = closingBracketIndex(characters, openingIndex: index) else {
                    // An unclosed tag runs to the end of the text; never speak it.
                    malformedTagCount += 1
                    break
                }
                let rawTag = String(characters[index...closingIndex])
                if let parsedTag = parseTag(rawTag, keyword: keyword) {
                    tags.append(parsedTag)
                } else {
                    malformedTagCount += 1
                }
                index = closingIndex + 1
                continue
            }
            speechCharacters.append(characters[index])
            index += 1
        }

        return Extraction(tags: tags, speechText: tidySpeech(speechCharacters), malformedTagCount: malformedTagCount)
    }

    /// Parses exactly one tag, e.g. "[MARK:circle:#57:Share]". nil if invalid.
    public static func parse(_ rawTag: String) -> ParsedTag? {
        let characters = Array(rawTag.trimmingCharacters(in: .whitespacesAndNewlines))
        guard characters.first == "[", let keyword = keywordAfterBracket(characters, from: 0),
              let closingIndex = closingBracketIndex(characters, openingIndex: 0),
              closingIndex == characters.count - 1 else { return nil }
        return parseTag(String(characters), keyword: keyword)
    }

    // MARK: - Scanning

    private enum Keyword {
        case point, mark, clear, snap
    }

    private static func keywordAfterBracket(_ characters: [Character], from openingIndex: Int) -> Keyword? {
        var index = openingIndex + 1
        while index < characters.count, characters[index] == " " { index += 1 }
        func matches(_ word: String) -> Bool {
            let wordCharacters = Array(word)
            guard index + wordCharacters.count <= characters.count else { return false }
            for (offset, wordCharacter) in wordCharacters.enumerated() where characters[index + offset].lowercased() != String(wordCharacter) {
                return false
            }
            // The keyword must be followed by ":" or "]" (after optional spaces).
            var afterIndex = index + wordCharacters.count
            while afterIndex < characters.count, characters[afterIndex] == " " { afterIndex += 1 }
            return afterIndex < characters.count && (characters[afterIndex] == ":" || characters[afterIndex] == "]")
        }
        if matches("point") { return .point }
        if matches("mark") { return .mark }
        if matches("clear") { return .clear }
        if matches("snap") { return .snap }
        return nil
    }

    /// The "]" closing the tag at `openingIndex`, skipping quoted text.
    private static func closingBracketIndex(_ characters: [Character], openingIndex: Int) -> Int? {
        var isInsideQuotes = false
        var index = openingIndex + 1
        while index < characters.count {
            let character = characters[index]
            if isInsideQuotes {
                if character == "\\" { index += 2; continue }
                if character == "\"" { isInsideQuotes = false }
            } else {
                if character == "\"" { isInsideQuotes = true }
                if character == "]" { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Parsing

    private static func parseTag(_ rawTag: String, keyword: Keyword) -> ParsedTag? {
        var body = rawTag.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        // Drop the keyword itself.
        let keywordLength: Int
        switch keyword {
        case .point: keywordLength = 5
        case .mark: keywordLength = 4
        case .clear: keywordLength = 5
        case .snap: keywordLength = 4
        }
        body = String(body.dropFirst(keywordLength)).trimmingCharacters(in: .whitespaces)

        if keyword == .clear {
            return body.isEmpty ? ParsedTag(kind: .clear, style: nil, target: .none, name: nil, note: nil, screenNumber: nil, snapshot: nil, raw: rawTag) : nil
        }
        if keyword == .snap {
            guard body.hasPrefix(":"), let snapshotRequest = parseSnapshotRequest(String(body.dropFirst())) else { return nil }
            return ParsedTag(kind: .snap, style: nil, target: .none, name: nil, note: nil, screenNumber: nil, snapshot: snapshotRequest, raw: rawTag)
        }
        guard body.hasPrefix(":") else { return nil }
        body = String(body.dropFirst())

        guard var fields = splitFieldsOutsideQuotes(body) else { return nil }

        // A trailing ":screenN" is cut before the label is read.
        var screenNumber: Int?
        if fields.count >= 2, let lastField = fields.last, let parsedScreenNumber = screenNumberField(lastField) {
            screenNumber = parsedScreenNumber
            fields.removeLast()
        }

        var style: MarkStyle?
        var hasExplicitStyle = false
        if keyword == .mark {
            guard let styleField = fields.first else { return nil }
            if parseTarget(styleField) != nil {
                // [MARK:#57:Share] — no style given, a target in its slot.
                style = .circle
            } else {
                (style, hasExplicitStyle) = parseStyle(styleField)
                fields.removeFirst()
            }
        }

        guard let targetField = fields.first, let target = parseTarget(targetField) else { return nil }
        fields.removeFirst()

        // The label is everything left (it may contain ":").
        let labelText = String(fields.joined(separator: ":").trimmingCharacters(in: .whitespaces).prefix(maximumLabelLength))
        var name: String?
        var note: String?
        if !labelText.isEmpty {
            if let separatorIndex = labelText.firstIndex(of: "|") {
                name = labelText[..<separatorIndex].trimmingCharacters(in: .whitespaces)
                note = labelText[labelText.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
                if name?.isEmpty == true { name = nil }
                if note?.isEmpty == true { note = nil }
            } else {
                name = labelText
            }
        }

        return ParsedTag(kind: keyword == .point ? .point : .mark, style: style, target: target,
                         name: name, note: note, screenNumber: screenNumber, snapshot: nil, raw: rawTag, hasExplicitStyle: hasExplicitStyle)
    }

    /// The field after "SNAP:": "screen", "window+marks", "marks" (spaces
    /// allowed around "+"). Anything else, including a second "+", is invalid.
    static func parseSnapshotRequest(_ field: String) -> SnapshotRequest? {
        let compactField = field.lowercased().filter { !$0.isWhitespace }
        let parts = compactField.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let target = parts.first.flatMap({ SnapshotTarget(rawValue: $0) }) else { return nil }
        switch parts.count {
        case 1:
            return SnapshotRequest(target: target)
        case 2 where parts[1] == "marks" && target != .board:
            return SnapshotRequest(target: target, includesClickyOverlay: true)
        default:
            return nil
        }
    }

    /// Splits on ":" outside quotes; nil if a quote is left open.
    private static func splitFieldsOutsideQuotes(_ body: String) -> [String]? {
        var fields: [String] = []
        var currentField = ""
        var isInsideQuotes = false
        var characters = Array(body)[...]
        while let character = characters.popFirst() {
            if isInsideQuotes {
                currentField.append(character)
                if character == "\\", let escapedCharacter = characters.popFirst() {
                    currentField.append(escapedCharacter)
                    continue
                }
                if character == "\"" { isInsideQuotes = false }
            } else if character == "\"" {
                isInsideQuotes = true
                currentField.append(character)
            } else if character == ":" {
                // Untrimmed: the label is rejoined from these fields and must
                // keep its own spacing ("Time: 10:30").
                fields.append(currentField)
                currentField = ""
            } else {
                currentField.append(character)
            }
        }
        guard !isInsideQuotes else { return nil }
        fields.append(currentField)
        return fields
    }

    private static func screenNumberField(_ field: String) -> Int? {
        let lowercasedField = field.lowercased().replacingOccurrences(of: " ", with: "")
        guard lowercasedField.hasPrefix("screen") else { return nil }
        return Int(lowercasedField.dropFirst("screen".count))
    }

    /// The style and whether it was a known keyword (unknown → circle, not explicit).
    private static func parseStyle(_ field: String) -> (MarkStyle, Bool) {
        let lowercasedField = field.lowercased().trimmingCharacters(in: .whitespaces)
        switch lowercasedField {
        case "circle": return (.circle, true)
        case "box": return (.box, true)
        case "arrow": return (.arrow, true)
        case "underline": return (.underline, true)
        case "spot": return (.spot, true)
        default:
            let stepText = lowercasedField.hasPrefix("step") ? String(lowercasedField.dropFirst(4)) : lowercasedField
            if let stepNumber = Int(stepText.trimmingCharacters(in: .whitespaces)), (1...9).contains(stepNumber) {
                return (.step(stepNumber), true)
            }
            return (.circle, false)
        }
    }

    /// Parses one target field; nil when it isn't a valid target.
    static func parseTarget(_ rawField: String) -> MarkTarget? {
        let field = rawField.trimmingCharacters(in: .whitespaces)
        guard !field.isEmpty else { return nil }
        if field.lowercased() == "none" { return MarkTarget.none }

        if field.hasPrefix("#") {
            return parseElementTarget(field)
        }
        if field.hasPrefix("\"") {
            return parseTextTarget(field)
        }
        return parseCoordinateTarget(field)
    }

    private static func parseElementTarget(_ field: String) -> MarkTarget? {
        let compactField = field.replacingOccurrences(of: " ", with: "")
        // #a-#b
        if let spanGroups = fullMatch(#"#(\d+)-#(\d+)"#, compactField),
           let fromID = spanGroups[0].flatMap({ Int($0) }), let toID = spanGroups[1].flatMap({ Int($0) }) {
            return .span(fromID: fromID, toID: toID)
        }
        // #n or #n@x,y
        if let elementGroups = fullMatch(#"#(\d+)(?:@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?))?"#, compactField),
           let elementID = elementGroups[0].flatMap({ Int($0) }) {
            var hint: CGPoint?
            if let hintX = elementGroups[1].flatMap({ Double($0) }), let hintY = elementGroups[2].flatMap({ Double($0) }) {
                hint = CGPoint(x: hintX.rounded(), y: hintY.rounded())
            }
            return .element(id: elementID, hint: hint)
        }
        return nil
    }

    private static func parseTextTarget(_ field: String) -> MarkTarget? {
        var characters = Array(field)[...]
        guard characters.popFirst() == "\"" else { return nil }
        var text = ""
        var isClosed = false
        while let character = characters.popFirst() {
            if character == "\\", let escapedCharacter = characters.popFirst() {
                text.append(escapedCharacter)
                continue
            }
            if character == "\"" { isClosed = true; break }
            text.append(character)
        }
        guard isClosed, !text.isEmpty else { return nil }

        let remainder = String(characters).trimmingCharacters(in: .whitespaces).lowercased()
        var occurrence: Int?
        var scopeID: Int?
        if !remainder.isEmpty {
            guard let remainderGroups = fullMatch(#"(?:~\s*(\d+))?\s*(?:in\s+#\s*(\d+))?"#, remainder) else { return nil }
            occurrence = remainderGroups[0].flatMap { Int($0) }
            scopeID = remainderGroups[1].flatMap { Int($0) }
            if occurrence == nil && scopeID == nil { return nil }
        }
        return .text(text, occurrence: occurrence, scopeID: scopeID)
    }

    private static func parseCoordinateTarget(_ field: String) -> MarkTarget? {
        let numberStrings = field.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let numbers = numberStrings.compactMap { numberString -> Double? in
            guard fullMatch(#"-?\d+(?:\.\d+)?"#, numberString) != nil else { return nil }
            return Double(numberString)?.rounded()
        }
        guard numbers.count == numberStrings.count else { return nil }
        switch numbers.count {
        case 2:
            return .point(CGPoint(x: numbers[0], y: numbers[1]))
        case 3:
            // Legacy x,y,r: a circle's bounding box.
            let radius = numbers[2]
            guard radius >= 0 else { return nil }
            return .box(CGRect(x: numbers[0] - radius, y: numbers[1] - radius, width: 2 * radius, height: 2 * radius))
        case 4:
            guard numbers[2] >= 0, numbers[3] >= 0 else { return nil }
            return .box(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
        default:
            return nil
        }
    }

    /// Matches `pattern` against the WHOLE string; returns the capture groups
    /// (nil for groups that didn't participate), or nil if it doesn't match.
    private static func fullMatch(_ pattern: String, _ text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { groupIndex in
            Range(match.range(at: groupIndex), in: text).map { String(text[$0]) }
        }
    }

    /// Collapses the double spaces left where tags were removed.
    private static func tidySpeech(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([.,!?;:])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
