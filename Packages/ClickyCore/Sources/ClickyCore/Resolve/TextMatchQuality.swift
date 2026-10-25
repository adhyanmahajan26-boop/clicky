//
//  TextMatchQuality.swift
//  ClickyCore
//
//  How good a text hit is, so a "text" target picks the label the model
//  meant rather than the same letters somewhere else on screen:
//
//   whole    the whole OCR line / AX text is the query (case-insensitive,
//            leading/trailing punctuation trimmed): a "Submit" button.
//   token    the query sits on word boundaries inside longer text:
//            "Click Submit to send".
//   inToken  the query is part of a longer token. `_ / . :` join tokens
//            here, so "submit" in "127.0.0.1:8793/submit_form.html" is
//            inToken: a URL, path or identifier, never what was named.
//
//  Case-exact hits ("Submit" for "Submit") beat case-folded ones, and text
//  in a browser's chrome (tab strip, address bar) loses to the page.
//

import CoreGraphics
import Foundation

public enum TextMatchQuality: Int, Comparable, Sendable {
    case whole = 0
    case token = 1
    case inToken = 2

    public static func < (lhs: TextMatchQuality, rhs: TextMatchQuality) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One AX text range hit (AXBoundsForRange) with its quality.
public struct TextRangeMatch: Sendable, Equatable {
    public var frameCG: CGRect
    public var isFuzzy: Bool
    public var quality: TextMatchQuality
    public var isCaseExact: Bool

    public init(frameCG: CGRect, isFuzzy: Bool, quality: TextMatchQuality, isCaseExact: Bool) {
        self.frameCG = frameCG
        self.isFuzzy = isFuzzy
        self.quality = quality
        self.isCaseExact = isCaseExact
    }
}

public enum TextMatchClassifier {
    public struct Occurrence: Sendable, Equatable {
        /// Range in the normalised text's characters (as findOccurrences).
        public let range: Range<Int>
        public let isFuzzy: Bool
        public let quality: TextMatchQuality
        public let isCaseExact: Bool
    }

    /// `normalize` without lowercasing (same character positions as
    /// `LabelSimilarity.normalize` for everything but exotic case mappings).
    static func normalizePreservingCase(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Joins two word characters into one token (URL, path, host:port, file.ext).
    static func isJoiner(_ character: Character) -> Bool {
        character == "/" || character == "." || character == ":" || character == "_"
    }

    /// Case-insensitive, punctuation-trimmed text used for "whole" equality.
    static func trimmedForEquality(_ text: String) -> String {
        LabelSimilarity.normalize(text).trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
    }

    /// The whole of `text` is `query` (case-insensitive, punctuation trimmed).
    public static func isWholeMatch(query: String, text: String?) -> Bool {
        guard let text else { return false }
        let trimmedQuery = trimmedForEquality(query)
        return !trimmedQuery.isEmpty && trimmedQuery == trimmedForEquality(text)
    }

    /// Like `isWholeMatch`, and the letters' case agrees too.
    public static func isCaseExactWholeMatch(query: String, text: String?) -> Bool {
        guard let text, isWholeMatch(query: query, text: text) else { return false }
        let trimSet = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        return normalizePreservingCase(query).trimmingCharacters(in: trimSet) == normalizePreservingCase(text).trimmingCharacters(in: trimSet)
    }

    /// Every occurrence of `query` in `text` (findOccurrences), classified.
    public static func occurrences(of query: String, in text: String) -> [Occurrence] {
        let matches = LabelSimilarity.findOccurrences(of: query, in: text)
        guard !matches.isEmpty else { return [] }
        let casedText = Array(normalizePreservingCase(text))
        let foldedText = Array(LabelSimilarity.normalize(text))
        let casedQuery = Array(normalizePreservingCase(query))
        let isWhole = isWholeMatch(query: query, text: text)
        return matches.map { match in
            let quality: TextMatchQuality
            if isWhole && !match.isFuzzy {
                quality = .whole
            } else {
                quality = boundaryQuality(of: match.range, in: foldedText, queryFirst: casedQuery.first, queryLast: casedQuery.last)
            }
            var isCaseExact = false
            if !match.isFuzzy, casedText.count == foldedText.count, match.range.upperBound <= casedText.count {
                isCaseExact = Array(casedText[match.range]) == casedQuery
            }
            return Occurrence(range: match.range, isFuzzy: match.isFuzzy, quality: quality, isCaseExact: isCaseExact)
        }
    }

    /// token vs inToken for a match at `range` of `text` (characters).
    static func boundaryQuality(of range: Range<Int>, in text: [Character], queryFirst: Character?, queryLast: Character?) -> TextMatchQuality {
        // A query that starts (ends) with punctuation has no word edge to check there.
        if let queryFirst, isWordCharacter(queryFirst), range.lowerBound > 0 {
            let before = text[range.lowerBound - 1]
            if isWordCharacter(before) { return .inToken }
            if isJoiner(before), range.lowerBound >= 2, isWordCharacter(text[range.lowerBound - 2]) { return .inToken }
        }
        if let queryLast, isWordCharacter(queryLast), range.upperBound < text.count {
            let after = text[range.upperBound]
            if isWordCharacter(after) { return .inToken }
            if isJoiner(after), range.upperBound + 1 < text.count, isWordCharacter(text[range.upperBound + 1]) { return .inToken }
        }
        return .token
    }

    /// Classifies AX text range hits found in `text` in order (exact hits are
    /// non-overlapping left to right, like findOccurrences). Hits beyond the
    /// classified ones get the worst quality seen.
    public static func classify(rangeHits: [(frameCG: CGRect, isFuzzy: Bool)], query: String, text: String?) -> [TextRangeMatch] {
        let classified = text.map { occurrences(of: query, in: $0) } ?? []
        let worst = classified.map(\.quality).max() ?? .token
        return rangeHits.enumerated().map { hitIndex, hit in
            let occurrence = hitIndex < classified.count ? classified[hitIndex] : nil
            return TextRangeMatch(frameCG: hit.frameCG, isFuzzy: hit.isFuzzy, quality: occurrence?.quality ?? worst,
                                  isCaseExact: occurrence?.isCaseExact ?? false)
        }
    }

    // MARK: - Browser chrome

    static let browserApplicationNames = ["google chrome", "chrome", "chromium", "safari", "arc", "microsoft edge", "brave browser",
                                          "firefox", "opera", "vivaldi", "orion", "zen"]

    static func isBrowserApplication(_ applicationName: String?) -> Bool {
        let name = LabelSimilarity.normalize(applicationName ?? "")
        return browserApplicationNames.contains { name == $0 || name.hasPrefix($0 + " ") }
    }

    /// Tab strip / address bar elements of a browser window.
    public static func isBrowserChrome(_ element: GroundingElement) -> Bool {
        guard element.source == .accessibility else { return false }
        let label = LabelSimilarity.normalize(element.label ?? "")
        // Chrome/Edge/Brave/Arc and Safari name their address bars these.
        if element.role == .textField, label.contains("address and search bar") || label.contains("smart search field") { return true }
        guard isBrowserApplication(element.applicationName) else { return false }
        if element.role == .tab { return true }
        return element.role == .textField && (label.contains("address") || label.contains("search bar") || label.contains("url"))
    }

    /// The browser-chrome bands on screen: per window, the union of its
    /// tab-strip/address-bar elements, widened to the window's width when
    /// the window is known.
    public static func browserChromeBands(registry: ElementRegistry, windowStack: WindowStack?) -> [CGRect] {
        var unionByWindow: [CGWindowID: CGRect] = [:]
        var bandsWithoutWindow: [CGRect] = []
        for elementID in registry.orderedIDs {
            guard let element = registry[elementID], isBrowserChrome(element) else { continue }
            let frame = element.visibleFrameCG
            if let windowID = element.windowID {
                unionByWindow[windowID] = unionByWindow[windowID].map { $0.union(frame) } ?? frame
            } else {
                bandsWithoutWindow.append(frame)
            }
        }
        let windowBands = unionByWindow.map { windowID, union -> CGRect in
            guard let window = windowStack?.windows.first(where: { $0.windowID == windowID }) else { return union.insetBy(dx: -4, dy: -4) }
            // From the window's top edge down to just under the address bar.
            let top = min(union.minY, window.boundsCG.minY)
            return CGRect(x: window.boundsCG.minX, y: top, width: window.boundsCG.width, height: union.maxY + 4 - top)
        }
        return windowBands + bandsWithoutWindow.map { $0.insetBy(dx: -4, dy: -4) }
    }
}
