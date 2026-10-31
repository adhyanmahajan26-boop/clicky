//
//  WBRepair.swift
//  ClickyCore
//
//  Turns one scanned value's text into JSON, climbing a ladder of fixes for
//  the slips models actually make and stopping at the first rung that
//  parses: (a) strict, (b) trailing commas removed, (c) balanced (open
//  string and brackets closed), (d) "}{" split into separate values,
//  (e) smart quotes made ASCII, (f) single quotes made double (only when the
//  text has no '"'). Rungs build on each other, so (e) is tried together with
//  (b)–(d). The rung that worked is recorded for stats; a value no rung
//  parses is dropped by the caller and logged.
//
//  Parsed JSON comes back as WBJSONValue, a Sendable, Equatable copy of what
//  JSONSerialization returns (its numbers and booleans are told apart here).
//

import Foundation

public indirect enum WBJSONValue: Equatable, Sendable {
    case object([String: WBJSONValue])
    case array([WBJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(foundationObject: Any) {
        switch foundationObject {
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(WBJSONValue.init(foundationObject:)))
        case let array as [Any]:
            self = .array(array.map(WBJSONValue.init(foundationObject:)))
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        default:
            self = .null
        }
    }

    public subscript(key: String) -> WBJSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var objectMembers: [String: WBJSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }
}

public enum WBRepairRung: String, CaseIterable, Codable, Sendable {
    case strict
    case trailingCommas
    case balanced
    case splitObjects
    case smartQuotes
    case singleQuotes
    /// No rung parsed the value.
    case failed
}

public struct WBRepairResult: Equatable, Sendable {
    /// Usually one; several when "}{" was split.
    public var values: [WBJSONValue]
    public var rung: WBRepairRung
}

public enum WBRepair {
    public static func repair(_ valueText: String) -> WBRepairResult {
        // JSONSerialization tolerates trailing commas; rung (a) must not, so
        // the stats say how often the model wrote them.
        let withoutTrailingCommas = removeTrailingCommas(valueText)
        if withoutTrailingCommas == valueText, let parsedValue = strictParse(valueText) {
            return WBRepairResult(values: [parsedValue], rung: .strict)
        }
        if let parsedValue = strictParse(withoutTrailingCommas) {
            return WBRepairResult(values: [parsedValue], rung: .trailingCommas)
        }
        let balancedText = removeTrailingCommas(balance(withoutTrailingCommas))
        if let parsedValue = strictParse(balancedText) {
            return WBRepairResult(values: [parsedValue], rung: .balanced)
        }
        if let splitValues = parseSplitObjects(balancedText) {
            return WBRepairResult(values: splitValues, rung: .splitObjects)
        }
        let smartQuotesText = replaceSmartQuotes(valueText)
        if smartQuotesText != valueText, let values = parseWithStructuralFixes(smartQuotesText) {
            return WBRepairResult(values: values, rung: .smartQuotes)
        }
        if !smartQuotesText.contains("\"") && smartQuotesText.contains("'") {
            let doubleQuotedText = smartQuotesText.replacingOccurrences(of: "'", with: "\"")
            if let values = parseWithStructuralFixes(doubleQuotedText) {
                return WBRepairResult(values: values, rung: .singleQuotes)
            }
        }
        return WBRepairResult(values: [], rung: .failed)
    }

    /// Rungs (a)–(d) on an already quote-fixed text.
    private static func parseWithStructuralFixes(_ text: String) -> [WBJSONValue]? {
        if let parsedValue = strictParse(text) { return [parsedValue] }
        let withoutTrailingCommas = removeTrailingCommas(text)
        if let parsedValue = strictParse(withoutTrailingCommas) { return [parsedValue] }
        let balancedText = removeTrailingCommas(balance(withoutTrailingCommas))
        if let parsedValue = strictParse(balancedText) { return [parsedValue] }
        return parseSplitObjects(balancedText)
    }

    static func strictParse(_ text: String) -> WBJSONValue? {
        guard let data = text.data(using: .utf8),
              let foundationObject = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        guard foundationObject is [String: Any] || foundationObject is [Any] else { return nil }
        return WBJSONValue(foundationObject: foundationObject)
    }

    // MARK: - (b) trailing commas

    /// Removes `,` followed by optional whitespace and `}` or `]`, outside strings.
    static func removeTrailingCommas(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var isInsideString = false
        var isAfterBackslash = false
        var scalarIndex = 0
        while scalarIndex < scalars.count {
            let scalar = scalars[scalarIndex]
            if isInsideString {
                output.append(scalar)
                if isAfterBackslash { isAfterBackslash = false }
                else if scalar == "\\" { isAfterBackslash = true }
                else if scalar == "\"" { isInsideString = false }
                scalarIndex += 1
                continue
            }
            if scalar == "\"" { isInsideString = true }
            if scalar == "," {
                var lookaheadIndex = scalarIndex + 1
                while lookaheadIndex < scalars.count, scalars[lookaheadIndex].properties.isWhitespace { lookaheadIndex += 1 }
                if lookaheadIndex < scalars.count, scalars[lookaheadIndex] == "}" || scalars[lookaheadIndex] == "]" {
                    scalarIndex += 1
                    continue
                }
            }
            output.append(scalar)
            scalarIndex += 1
        }
        return String(output)
    }

    // MARK: - (c) balance

    private enum ObjectExpectation {
        case keyOrEnd, colon, value, commaOrEnd
    }

    /// Closes an open string, then the open brackets in stack order. Raw
    /// newlines and tabs inside strings become escapes; a stray closer that
    /// matches nothing is dropped; a key left without a value gets null.
    public static func balance(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var bracketStack: [Unicode.Scalar] = []
        var objectExpectations: [ObjectExpectation] = []
        var isInsideString = false
        var isAfterBackslash = false

        func noteValueFinished() {
            if bracketStack.last == "{", !objectExpectations.isEmpty {
                switch objectExpectations[objectExpectations.count - 1] {
                case .keyOrEnd: objectExpectations[objectExpectations.count - 1] = .colon
                case .value: objectExpectations[objectExpectations.count - 1] = .commaOrEnd
                default: break
                }
            }
        }

        for scalar in text.unicodeScalars {
            if isInsideString {
                if isAfterBackslash {
                    isAfterBackslash = false
                    output.append(scalar)
                } else if scalar == "\\" {
                    isAfterBackslash = true
                    output.append(scalar)
                } else if scalar == "\"" {
                    isInsideString = false
                    output.append(scalar)
                    noteValueFinished()
                } else if scalar == "\n" {
                    output.append(contentsOf: "\\n".unicodeScalars)
                } else if scalar == "\t" {
                    output.append(contentsOf: "\\t".unicodeScalars)
                } else if scalar == "\r" {
                    continue
                } else {
                    output.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"":
                isInsideString = true
                output.append(scalar)
            case "{", "[":
                bracketStack.append(scalar)
                if scalar == "{" { objectExpectations.append(.keyOrEnd) }
                output.append(scalar)
            case "}", "]":
                let expectedOpener: Unicode.Scalar = scalar == "}" ? "{" : "["
                guard bracketStack.last == expectedOpener else { continue }
                if scalar == "}" {
                    appendMissingObjectValue(&output, expectation: objectExpectations.last)
                    objectExpectations.removeLast()
                }
                bracketStack.removeLast()
                output.append(scalar)
                noteValueFinished()
            case ":":
                if bracketStack.last == "{", objectExpectations.last == .colon {
                    objectExpectations[objectExpectations.count - 1] = .value
                }
                output.append(scalar)
            case ",":
                if bracketStack.last == "{", !objectExpectations.isEmpty {
                    objectExpectations[objectExpectations.count - 1] = .keyOrEnd
                }
                output.append(scalar)
            default:
                output.append(scalar)
                // A bare literal or number fills a value slot.
                if !scalar.properties.isWhitespace, bracketStack.last == "{", objectExpectations.last == .value {
                    objectExpectations[objectExpectations.count - 1] = .commaOrEnd
                }
            }
        }

        if isInsideString {
            if isAfterBackslash { output.removeLast() }
            output.append("\"")
            noteValueFinished()
        }
        while let openBracket = bracketStack.popLast() {
            if openBracket == "{" {
                appendMissingObjectValue(&output, expectation: objectExpectations.last)
                objectExpectations.removeLast()
                output.append("}")
            } else {
                output.append("]")
            }
            noteValueFinished()
        }
        return String(output)
    }

    private static func appendMissingObjectValue(_ output: inout String.UnicodeScalarView, expectation: ObjectExpectation?) {
        switch expectation {
        case .colon: output.append(contentsOf: ":null".unicodeScalars)
        case .value: output.append(contentsOf: "null".unicodeScalars)
        default: break
        }
    }

    // MARK: - (d) split "}{"

    /// `{…}{…}` (or `[{…}{…}]`) → separate values; nil when that doesn't parse.
    static func parseSplitObjects(_ text: String) -> [WBJSONValue]? {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var isInsideString = false
        var isAfterBackslash = false
        var didSplit = false
        var scalarIndex = 0
        while scalarIndex < scalars.count {
            let scalar = scalars[scalarIndex]
            output.append(scalar)
            if isInsideString {
                if isAfterBackslash { isAfterBackslash = false }
                else if scalar == "\\" { isAfterBackslash = true }
                else if scalar == "\"" { isInsideString = false }
            } else if scalar == "\"" {
                isInsideString = true
            } else if scalar == "}" {
                var lookaheadIndex = scalarIndex + 1
                while lookaheadIndex < scalars.count, scalars[lookaheadIndex].properties.isWhitespace { lookaheadIndex += 1 }
                if lookaheadIndex < scalars.count, scalars[lookaheadIndex] == "{" {
                    output.append(",")
                    didSplit = true
                }
            }
            scalarIndex += 1
        }
        guard didSplit else { return nil }
        let joinedText = String(output)
        if let parsedArray = strictParse("[" + joinedText + "]"), case .array(let values) = parsedArray {
            // A top-level `[…]` that held the objects comes back nested once.
            if values.count == 1, case .array = values[0] { return [values[0]] }
            return values
        }
        return nil
    }

    // MARK: - (e) smart quotes

    static func replaceSmartQuotes(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}": output.append("\"")
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}": output.append("'")
            default: output.append(scalar)
            }
        }
        return String(output)
    }
}
