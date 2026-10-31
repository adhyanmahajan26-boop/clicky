//
//  ArticleSentenceMatcher.swift
//  ClickyCore
//
//  P8 highlights: a sentence the model copied from the article → where it
//  is in the page text (UTF-16 range), and → which OCR lines it covers
//  (one rect per line, so a sentence that wraps gets one highlighter
//  stroke per line, never one big box).
//
//  Matching works on a "skeleton" of both texts: letters and digits only,
//  case and diacritics folded, compatibility forms decomposed ("ﬁ" → "fi").
//  So whitespace, line breaks, curly vs straight quotes, dashes, hyphens
//  (including a word hyphenated across two lines: "impor-\ntant"), soft
//  hyphens and punctuation never stop a verbatim sentence from matching.
//  Every skeleton character remembers the UTF-16 span of the source
//  character it came from, so a skeleton match maps back to the exact
//  source range. When there is no exact match (OCR misreads, a word the
//  model changed) an approximate substring search (Sellers' edit distance)
//  accepts up to 15 % errors.
//

import CoreGraphics
import Foundation

public struct ArticleTextMatch: Equatable, Sendable {
    /// UTF-16 range in the searched text, first to last matched character.
    public var utf16Range: Range<Int>
    /// Edit distance of the skeletons (0 = exact).
    public var editDistance: Int
    public var isExact: Bool { editDistance == 0 }

    public init(utf16Range: Range<Int>, editDistance: Int) {
        self.utf16Range = utf16Range
        self.editDistance = editDistance
    }
}

public enum ArticleSentenceMatcher {
    /// Fraction of the sentence's skeleton that may differ in an approximate match.
    public static let maximumErrorFraction = 0.15
    /// Skeletons shorter than this are matched exactly only (too easy to find by accident).
    public static let minimumApproximateLength = 12
    static let closingPunctuation = CharacterSet(charactersIn: ".!?;:,\"\u{201D}\u{2019}')]\u{2026}")

    /// The folded letters/digits of a text and, per character, the UTF-16 span it came from.
    public struct Skeleton: Equatable, Sendable {
        public var characters: [UInt32]
        public var sourceStarts: [Int]
        public var sourceEnds: [Int]
        /// The source text's UTF-16 units (to extend a match over closing punctuation).
        public var sourceUTF16: [UInt16]

        public init(_ text: String) {
            var characters: [UInt32] = []
            var sourceStarts: [Int] = []
            var sourceEnds: [Int] = []
            characters.reserveCapacity(text.utf16.count)
            var utf16Offset = 0
            for scalar in text.unicodeScalars {
                let scalarLength = scalar.utf16.count
                defer { utf16Offset += scalarLength }
                // Fast path for ASCII (most article text).
                if scalar.isASCII {
                    let value = scalar.value
                    if (0x30...0x39).contains(value) || (0x61...0x7A).contains(value) {
                        characters.append(value)
                    } else if (0x41...0x5A).contains(value) {
                        characters.append(value + 0x20)
                    } else {
                        continue
                    }
                    sourceStarts.append(utf16Offset)
                    sourceEnds.append(utf16Offset + scalarLength)
                    continue
                }
                guard CharacterSet.alphanumerics.contains(scalar) else { continue }
                let folded = String(scalar).decomposedStringWithCompatibilityMapping
                    .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                for foldedScalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(foldedScalar)
                    && !CharacterSet.nonBaseCharacters.contains(foldedScalar) {
                    characters.append(foldedScalar.value)
                    sourceStarts.append(utf16Offset)
                    sourceEnds.append(utf16Offset + scalarLength)
                }
            }
            self.characters = characters
            self.sourceStarts = sourceStarts
            self.sourceEnds = sourceEnds
            self.sourceUTF16 = Array(text.utf16)
        }

        /// A match ends at its last letter or digit; a sentence that ends in
        /// "." / "?" / a closing quote gets those characters too (up to 3).
        func extendedOverClosingPunctuation(_ range: Range<Int>, sentence: String) -> Range<Int> {
            guard let last = sentence.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last,
                  ArticleSentenceMatcher.closingPunctuation.contains(last) else { return range }
            var end = range.upperBound
            var added = 0
            while end < sourceUTF16.count, added < 3, let scalar = Unicode.Scalar(sourceUTF16[end]), ArticleSentenceMatcher.closingPunctuation.contains(scalar) {
                end += 1
                added += 1
            }
            return range.lowerBound..<end
        }

        public var count: Int { characters.count }

        /// Skeleton positions start..<end → the source UTF-16 range.
        public func sourceRange(_ skeletonRange: Range<Int>) -> Range<Int> {
            sourceStarts[skeletonRange.lowerBound]..<sourceEnds[skeletonRange.upperBound - 1]
        }
    }

    /// The skeleton as a string (for comparisons and tests).
    public static func normalizedForComparison(_ text: String) -> String {
        String(String.UnicodeScalarView(Skeleton(text).characters.compactMap(Unicode.Scalar.init)))
    }

    /// Finds `sentence` in `text`: exact skeleton match first, else the best approximate one.
    public static func match(_ sentence: String, in text: String, maximumErrorFraction: Double = maximumErrorFraction) -> ArticleTextMatch? {
        match(sentence, in: Skeleton(text), maximumErrorFraction: maximumErrorFraction)
    }

    /// The same, against a skeleton built once for many sentences.
    public static func match(_ sentence: String, in haystack: Skeleton, maximumErrorFraction: Double = maximumErrorFraction) -> ArticleTextMatch? {
        let needle = Skeleton(sentence).characters
        guard !needle.isEmpty, haystack.count > 0 else { return nil }
        if let start = exactSearch(needle, in: haystack.characters) {
            return ArticleTextMatch(utf16Range: haystack.extendedOverClosingPunctuation(haystack.sourceRange(start..<(start + needle.count)), sentence: sentence), editDistance: 0)
        }
        guard needle.count >= minimumApproximateLength else { return nil }
        let allowedErrors = Int((Double(needle.count) * maximumErrorFraction).rounded(.down))
        guard allowedErrors > 0, let approximate = approximateSearch(needle, in: haystack.characters, maximumErrors: allowedErrors) else { return nil }
        return ArticleTextMatch(utf16Range: haystack.extendedOverClosingPunctuation(haystack.sourceRange(approximate.range), sentence: sentence),
                                editDistance: approximate.errors)
    }

    /// First occurrence of `needle` (Knuth–Morris–Pratt).
    static func exactSearch(_ needle: [UInt32], in haystack: [UInt32]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var failure = [Int](repeating: 0, count: needle.count)
        var matched = 0
        for index in 1..<max(1, needle.count) {
            while matched > 0 && needle[index] != needle[matched] { matched = failure[matched - 1] }
            if needle[index] == needle[matched] { matched += 1 }
            failure[index] = matched
        }
        matched = 0
        for (index, character) in haystack.enumerated() {
            while matched > 0 && character != needle[matched] { matched = failure[matched - 1] }
            if character == needle[matched] { matched += 1 }
            if matched == needle.count { return index - needle.count + 1 }
        }
        return nil
    }

    /// Best substring of `haystack` within `maximumErrors` edits of `needle` (Sellers):
    /// the lowest error count wins, then the earliest end.
    static func approximateSearch(_ needle: [UInt32], in haystack: [UInt32], maximumErrors: Int) -> (range: Range<Int>, errors: Int)? {
        let needleLength = needle.count
        // cost[i] = edits to match needle[0..<i] ending at the current haystack position; start[i] = where that match began.
        var previousCost = Array(0...needleLength)
        var previousStart = [Int](repeating: 0, count: needleLength + 1)
        var currentCost = [Int](repeating: 0, count: needleLength + 1)
        var currentStart = [Int](repeating: 0, count: needleLength + 1)
        var best: (range: Range<Int>, errors: Int)?
        for (haystackIndex, character) in haystack.enumerated() {
            currentCost[0] = 0
            currentStart[0] = haystackIndex + 1
            for needleIndex in 1...needleLength {
                let substitution = previousCost[needleIndex - 1] + (needle[needleIndex - 1] == character ? 0 : 1)
                let deletionInHaystack = previousCost[needleIndex] + 1
                let insertionInHaystack = currentCost[needleIndex - 1] + 1
                if substitution <= deletionInHaystack && substitution <= insertionInHaystack {
                    currentCost[needleIndex] = substitution
                    currentStart[needleIndex] = needleIndex == 1 ? haystackIndex : previousStart[needleIndex - 1]
                } else if deletionInHaystack <= insertionInHaystack {
                    currentCost[needleIndex] = deletionInHaystack
                    currentStart[needleIndex] = previousStart[needleIndex]
                } else {
                    currentCost[needleIndex] = insertionInHaystack
                    currentStart[needleIndex] = currentStart[needleIndex - 1]
                }
            }
            let errors = currentCost[needleLength]
            if errors <= maximumErrors, best == nil || errors < best!.errors {
                let start = min(currentStart[needleLength], haystackIndex)
                best = (start..<(haystackIndex + 1), errors)
            }
            swap(&previousCost, &currentCost)
            swap(&previousStart, &currentStart)
        }
        return best
    }
}

// MARK: - OCR lines

/// One recognised line (CG global points).
public struct ArticleOCRLine: Equatable, Sendable {
    public var text: String
    public var frameCG: CGRect

    public init(text: String, frameCG: CGRect) {
        self.text = text
        self.frameCG = frameCG
    }
}

public enum ArticleOCRMatcher {
    /// Lines in reading order: grouped into columns (lines whose horizontal
    /// extents overlap), columns left to right, lines top to bottom.
    public static func readingOrder(_ lines: [ArticleOCRLine]) -> [ArticleOCRLine] {
        var columns: [(extent: ClosedRange<CGFloat>, lines: [ArticleOCRLine])] = []
        for line in lines.sorted(by: { $0.frameCG.minY < $1.frameCG.minY }) where line.frameCG.width > 0 {
            let lineExtent = line.frameCG.minX...line.frameCG.maxX
            if let columnIndex = columns.firstIndex(where: { overlapFraction($0.extent, lineExtent) >= 0.5 }) {
                let extent = columns[columnIndex].extent
                columns[columnIndex].extent = min(extent.lowerBound, lineExtent.lowerBound)...max(extent.upperBound, lineExtent.upperBound)
                columns[columnIndex].lines.append(line)
            } else {
                columns.append((lineExtent, [line]))
            }
        }
        return columns.sorted { $0.extent.lowerBound < $1.extent.lowerBound }.flatMap { column in
            column.lines.sorted { first, second in
                if abs(first.frameCG.midY - second.frameCG.midY) > min(first.frameCG.height, second.frameCG.height) / 2 {
                    return first.frameCG.midY < second.frameCG.midY
                }
                return first.frameCG.minX < second.frameCG.minX
            }
        }
    }

    static func overlapFraction(_ first: ClosedRange<CGFloat>, _ second: ClosedRange<CGFloat>) -> CGFloat {
        let overlap = min(first.upperBound, second.upperBound) - max(first.lowerBound, second.lowerBound)
        let narrower = min(first.upperBound - first.lowerBound, second.upperBound - second.lowerBound)
        guard narrower > 0 else { return 0 }
        return max(0, overlap) / narrower
    }

    /// The sentence over consecutive OCR lines → one rect per line it covers
    /// (the first and last trimmed to where the sentence starts / ends, by
    /// character position). nil when it isn't there.
    public static func lineRects(for sentence: String, lines: [ArticleOCRLine]) -> [CGRect]? {
        let ordered = readingOrder(lines)
        guard !ordered.isEmpty else { return nil }
        var joined = ""
        var lineRanges: [Range<Int>] = []
        for line in ordered {
            if !joined.isEmpty { joined += "\n" }
            let start = joined.utf16.count
            joined += line.text
            lineRanges.append(start..<joined.utf16.count)
        }
        guard let match = ArticleSentenceMatcher.match(sentence, in: joined) else { return nil }
        var rects: [CGRect] = []
        for (lineIndex, lineRange) in lineRanges.enumerated() {
            let lower = max(lineRange.lowerBound, match.utf16Range.lowerBound)
            let upper = min(lineRange.upperBound, match.utf16Range.upperBound)
            guard lower < upper else { continue }
            let lineLength = lineRange.count
            let frame = ordered[lineIndex].frameCG
            let startFraction = CGFloat(lower - lineRange.lowerBound) / CGFloat(max(1, lineLength))
            let endFraction = CGFloat(upper - lineRange.lowerBound) / CGFloat(max(1, lineLength))
            rects.append(CGRect(x: frame.minX + startFraction * frame.width, y: frame.minY,
                                width: max(2, (endFraction - startFraction) * frame.width), height: frame.height))
        }
        return rects.isEmpty ? nil : rects
    }
}

// MARK: - Line fragments

public enum ArticleLineFragments {
    /// Word (or character) rects from AXBoundsForRange → one rect per text
    /// line, top to bottom: rects that overlap vertically by at least half
    /// the shorter one's height are on the same line and are unioned.
    public static func lineRects(fromWordRects wordRects: [CGRect]) -> [CGRect] {
        var lines: [CGRect] = []
        for rect in wordRects where rect.width > 0 && rect.height > 0 && rect.minX.isFinite && rect.minY.isFinite {
            if let lineIndex = lines.lastIndex(where: { verticalOverlapFraction($0, rect) >= 0.5 }) {
                lines[lineIndex] = lines[lineIndex].union(rect)
            } else {
                lines.append(rect)
            }
        }
        return lines.sorted { $0.minY < $1.minY }
    }

    static func verticalOverlapFraction(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let overlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
        let shorter = min(first.height, second.height)
        guard shorter > 0 else { return 0 }
        return max(0, overlap) / shorter
    }

    /// Does one bounds rect for a range look like a single line? (Taller than
    /// 1.6 × one line means the range wrapped and must be split per word.)
    public static func isSingleLine(rangeBounds: CGRect, lineHeight: CGFloat) -> Bool {
        guard lineHeight > 0 else { return false }
        return rangeBounds.height <= lineHeight * 1.6
    }

    /// UTF-16 ranges of the words in `text` (runs of non-whitespace), offset by `base`.
    public static func wordRanges(in text: String, base: Int = 0) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var wordStart: Int?
        var offset = 0
        for unit in text.utf16 {
            let isSpace = unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0xA0
            if isSpace {
                if let start = wordStart { ranges.append((base + start)..<(base + offset)) }
                wordStart = nil
            } else if wordStart == nil {
                wordStart = offset
            }
            offset += 1
        }
        if let start = wordStart { ranges.append((base + start)..<(base + offset)) }
        return ranges
    }
}
