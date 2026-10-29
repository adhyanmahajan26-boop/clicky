//
//  CaptionParser.swift
//  ClickyCore
//
//  Turns one narration segment (markdown-ish text with U+E000 tag
//  placeholders) into what the bubble shows and what the voice says:
//   - display-only (shown, never spoken): ``` fences (monospaced), list
//     markers (as bullets), "|" table lines, URLs, inline code over 24 chars;
//   - inline markdown is rendered with .inlineOnlyPreservingWhitespace and
//     links lose their styling (their text stays);
//   - emoji (Extended_Pictographic, ZWJ, VS16) are removed first;
//   - every placeholder becomes an anchor at its spoken-character offset,
//     with the start of the word before it (where a POINT fires).
//  Offsets are in Characters of `speech`; `pieces` map each spoken run to
//  the identical characters of `display`.
//

import Foundation

public struct CaptionAnchor: Equatable, Sendable {
    public let tagIndex: Int
    /// Spoken characters before the tag (it fires once speech passes this).
    public let speechOffset: Int
    /// Start of the word before the tag (a POINT fires here).
    public let prevWordStart: Int
}

public struct CaptionPiece: Equatable, Sendable {
    public let speechRange: Range<Int>
    public let displayStart: Int
}

public struct CaptionSegment: Identifiable, Equatable, Sendable {
    public let id: Int
    public let display: String
    public let speech: String
    public let pieces: [CaptionPiece]
    public let anchors: [CaptionAnchor]
    /// Words of `speech`, as Character ranges.
    public let wordRanges: [Range<Int>]
    /// Display ranges drawn monospaced (fence contents).
    public let monospacedRanges: [Range<Int>]
    /// Whiteboard step this segment narrates (P4).
    public var boardStep: Int?

    public var speechLength: Int { speech.count }
    public var hasSpeech: Bool { !speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func wordStart(_ wordIndex: Int) -> Int {
        guard !wordRanges.isEmpty else { return 0 }
        return wordRanges[min(max(0, wordIndex), wordRanges.count - 1)].lowerBound
    }

    /// Characters of `speech` spoken once the synthesizer has reached
    /// `utf16Offset` (Apple reports NSRanges in UTF-16). Never splits a
    /// Character: a position inside one counts the whole Character.
    public func spokenCharacters(throughUTF16 utf16Offset: Int) -> Int {
        let utf16View = speech.utf16
        let clampedOffset = min(max(0, utf16Offset), utf16View.count)
        let utf16Index = utf16View.index(utf16View.startIndex, offsetBy: clampedOffset)
        var characterIndex = speech.startIndex
        var characterCount = 0
        while characterIndex < speech.endIndex && characterIndex < utf16Index {
            characterIndex = speech.index(after: characterIndex)
            characterCount += 1
        }
        return characterCount
    }

    /// How much of `display` to show once `spokenCharacters` are spoken.
    /// Display-only text is revealed when the speech after it starts (or at
    /// the end of the segment).
    public func displayRevealCount(spokenCharacters: Int) -> Int {
        let displayLength = display.count
        guard spokenCharacters < speechLength else { return displayLength }
        var revealed = 0
        for piece in pieces {
            if spokenCharacters >= piece.speechRange.upperBound {
                revealed = piece.displayStart + piece.speechRange.count
            } else if spokenCharacters >= piece.speechRange.lowerBound {
                revealed = piece.displayStart + (spokenCharacters - piece.speechRange.lowerBound)
                break
            } else {
                break
            }
        }
        return min(revealed, displayLength)
    }
}

public enum CaptionParser {
    public static let maximumSpokenInlineCodeLength = 24

    private static let listMarkerPattern = try! NSRegularExpression(pattern: #"^\s*(?:[-*•+]|\d{1,3}[.)])\s+"#)
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s)\]>"']+"#, options: [.caseInsensitive])

    /// `firstTagIndex`: the router index of this segment's first placeholder
    /// (placeholders are numbered in order across the answer).
    public static func parse(_ rawSegment: String, id: Int, firstTagIndex: Int) -> CaptionSegment {
        var builder = Builder(nextTagIndex: firstTagIndex)
        let cleanedText = stripEmoji(rawSegment)
        var isInsideFence = false
        let lines = cleanedText.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            let isLastLine = lineIndex == lines.count - 1
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                // The ``` line itself isn't shown, nor its line break.
                isInsideFence.toggle()
                builder.appendDisplayOnly(placeholdersOnly(line))
                continue
            } else if isInsideFence {
                builder.appendDisplayOnly(line, isMonospaced: true)
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                builder.appendDisplayOnly(line)
            } else if let markerMatch = listMarkerPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let markerRange = Range(markerMatch.range, in: line) {
                builder.appendDisplayOnly("• ")
                builder.separateSpeech()
                appendInline(String(line[markerRange.upperBound...]), to: &builder)
            } else {
                appendInline(line, to: &builder)
            }
            if !isLastLine {
                builder.appendDisplayOnly("\n")
                builder.separateSpeech()
            }
        }
        return builder.makeSegment(id: id)
    }

    /// Inline markdown → spoken runs (URLs and long inline code display-only).
    private static func appendInline(_ text: String, to builder: inout Builder) {
        guard !text.isEmpty else { return }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            appendSplittingURLs(text, to: &builder)
            return
        }
        for run in attributed.runs {
            // Emphasis markers the parser couldn't pair ("**a****b**") are never spoken.
            let runText = String(attributed[run.range].characters)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
            let isCode = run.inlinePresentationIntent?.contains(.code) ?? false
            if isCode && runText.count > maximumSpokenInlineCodeLength {
                builder.appendDisplayOnly(runText, isMonospaced: true)
            } else {
                appendSplittingURLs(runText, to: &builder)
            }
        }
    }

    private static func appendSplittingURLs(_ text: String, to builder: inout Builder) {
        var cursor = text.startIndex
        for match in urlPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let urlRange = Range(match.range, in: text) else { continue }
            builder.appendSpoken(String(text[cursor..<urlRange.lowerBound]))
            builder.appendDisplayOnly(String(text[urlRange]))
            cursor = urlRange.upperBound
        }
        builder.appendSpoken(String(text[cursor...]))
    }

    /// Keeps only the placeholders of a fence marker line (``` itself isn't shown).
    private static func placeholdersOnly(_ line: String) -> String {
        String(line.filter { $0 == ResponseRouter.placeholder })
    }

    /// Extended_Pictographic outside Latin-1 (©, ® stay), ZWJ, VS16.
    private static let emojiPattern = try! NSRegularExpression(pattern: #"[[\p{Extended_Pictographic}]&&[^\u0000-\u00FF]]|\u200D|\uFE0F"#)

    /// Removes emoji: Extended_Pictographic scalars, ZWJ and VS16.
    public static func stripEmoji(_ text: String) -> String {
        emojiPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    // MARK: - Builder

    private struct Builder {
        var nextTagIndex: Int
        var display = ""
        var displayCount = 0
        var speech = ""
        var speechCount = 0
        var pieces: [CaptionPiece] = []
        var anchorOffsets: [(tagIndex: Int, speechOffset: Int)] = []
        var monospacedRanges: [Range<Int>] = []
        var needsSpeechSeparator = false

        mutating func recordPlaceholder() {
            anchorOffsets.append((nextTagIndex, speechCount))
            nextTagIndex += 1
        }

        mutating func separateSpeech() {
            needsSpeechSeparator = true
        }

        mutating func appendDisplayOnly(_ text: String, isMonospaced: Bool = false) {
            for character in text {
                if character == ResponseRouter.placeholder { recordPlaceholder(); continue }
                if isMonospaced { monospacedRanges.append(displayCount..<(displayCount + 1)) }
                display.append(character)
                displayCount += 1
            }
        }

        mutating func appendSpoken(_ text: String) {
            var runCharacters: [Character] = []
            func flushRun() {
                guard !runCharacters.isEmpty else { return }
                if needsSpeechSeparator, speechCount > 0, let lastSpoken = speech.last, !lastSpoken.isWhitespace,
                   let firstCharacter = runCharacters.first, !firstCharacter.isWhitespace {
                    speech.append(" ")
                    speechCount += 1
                }
                needsSpeechSeparator = false
                let runText = String(runCharacters)
                pieces.append(CaptionPiece(speechRange: speechCount..<(speechCount + runCharacters.count), displayStart: displayCount))
                speech += runText
                display += runText
                speechCount += runCharacters.count
                displayCount += runCharacters.count
                runCharacters = []
            }
            for character in text {
                if character == ResponseRouter.placeholder {
                    flushRun()
                    recordPlaceholder()
                    continue
                }
                runCharacters.append(character)
            }
            flushRun()
        }

        func makeSegment(id: Int) -> CaptionSegment {
            // Trailing line breaks (after a fence or list) would show as blank lines.
            var display = display
            let lastPieceEnd = pieces.last.map { $0.displayStart + $0.speechRange.count } ?? 0
            while display.last == "\n" && display.count > lastPieceEnd { display.removeLast() }
            let displayLength = display.count
            let monospacedRanges = Self.merged(monospacedRanges).compactMap { range -> Range<Int>? in
                let clamped = range.clamped(to: 0..<displayLength)
                return clamped.isEmpty ? nil : clamped
            }
            let wordRanges = Self.wordRanges(of: speech)
            let anchors = anchorOffsets.map { anchorOffset -> CaptionAnchor in
                let previousWordStart = wordRanges.last(where: { $0.lowerBound < anchorOffset.speechOffset })?.lowerBound ?? 0
                return CaptionAnchor(tagIndex: anchorOffset.tagIndex, speechOffset: anchorOffset.speechOffset, prevWordStart: previousWordStart)
            }
            return CaptionSegment(id: id, display: display, speech: speech, pieces: pieces, anchors: anchors,
                                  wordRanges: wordRanges, monospacedRanges: monospacedRanges, boardStep: nil)
        }

        static func wordRanges(of text: String) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, wordRange, _, _ in
                let start = text.distance(from: text.startIndex, to: wordRange.lowerBound)
                ranges.append(start..<(start + text.distance(from: wordRange.lowerBound, to: wordRange.upperBound)))
            }
            return ranges
        }

        static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
            var mergedRanges: [Range<Int>] = []
            for range in ranges {
                if let last = mergedRanges.last, last.upperBound == range.lowerBound {
                    mergedRanges[mergedRanges.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    mergedRanges.append(range)
                }
            }
            return mergedRanges
        }
    }
}
