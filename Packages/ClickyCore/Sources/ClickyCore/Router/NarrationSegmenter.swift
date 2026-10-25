//
//  NarrationSegmenter.swift
//  ClickyCore
//
//  Cuts the router's narration into speakable segments as it streams, so
//  speech can start on the first sentence while the rest is still arriving.
//   - Sentences come from NLTokenizer(.sentence); the last one is always
//     held back until more text (or the end) shows it's complete.
//   - Sentences under 24 characters merge into the next one, except the very
//     first (it starts the voice early).
//   - A first sentence over 80 characters is cut at its first ", " or "; "
//     at least 24 characters in, however it arrived. Options change both
//     numbers: the Qwen voice (no streaming audio) cuts any first sentence
//     at its first ", " 16 characters in, so the first WAV is short.
//   - Never cut inside a ``` fence. Tags arrive whole (the router holds
//     them) as U+E000 placeholders.
//   - A sentence that is only placeholders / spaces / punctuation joins the
//     previous segment; a lone fence joins the previous segment (else the
//     next) and is revealed at its end.
//  The output is the same whether text arrives char by char or all at once.
//

import Foundation
import NaturalLanguage

public struct NarrationSegmenter: Sendable {
    public static let minimumSentenceLength = 24
    public static let longFirstSentenceLength = 80

    /// When the first sentence is cut at a clause. The defaults are the
    /// behaviour every engine had before P3.
    public struct Options: Equatable, Sendable {
        /// The ", " / "; " must be at least this many characters in.
        public var firstCutMinChars: Int
        /// Only first sentences longer than this are cut.
        public var firstCutMinSentenceLen: Int
        /// If set, a first segment with no clause cut by this length is cut at
        /// the last space before it (a short first WAV starts the voice sooner).
        public var firstCutMaxChars: Int?

        public init(firstCutMinChars: Int = NarrationSegmenter.minimumSentenceLength,
                    firstCutMinSentenceLen: Int = NarrationSegmenter.longFirstSentenceLength,
                    firstCutMaxChars: Int? = nil) {
            self.firstCutMinChars = firstCutMinChars
            self.firstCutMinSentenceLen = firstCutMinSentenceLen
            self.firstCutMaxChars = firstCutMaxChars
        }

        /// For the Qwen voice: its first WAV arrives only when it's complete,
        /// and synthesis time grows with length (live, cloning one reference
        /// clip: ~1.1 s at 15 chars, ~1.4 s at 30, ~2.5 s at 63).
        public static let qwen = Options(firstCutMinChars: 12, firstCutMinSentenceLen: 0, firstCutMaxChars: 32)
    }

    public let options: Options
    private var pending = ""
    public private(set) var releasedCount = 0

    public init(options: Options = Options()) {
        self.options = options
    }

    public mutating func feed(_ narration: String) -> [String] {
        pending += narration
        return release(isFinal: false)
    }

    public mutating func finish() -> [String] {
        release(isFinal: true)
    }

    // MARK: - Units

    private struct Unit {
        var text: String
        var hasSpeech: Bool
        var isComplete: Bool
    }

    private mutating func release(isFinal: Bool) -> [String] {
        var released: [String] = []
        while true {
            let units = Self.units(of: pending, isFinal: isFinal)
            guard !units.isEmpty else { break }

            // A long first sentence: cut early at a comma, even mid-stream.
            if releasedCount == 0, let firstUnit = units.first, firstUnit.hasSpeech,
               firstUnit.text.count > options.firstCutMinSentenceLen,
               let cutOffset = Self.firstCut(in: firstUnit.text, options: options) {
                let head = String(firstUnit.text.prefix(cutOffset))
                released.append(head)
                releasedCount += 1
                pending = String(pending.dropFirst(head.count))
                continue
            }

            // Build the next segment from complete units.
            var segmentText = ""
            var consumedUnits = 0
            var segmentHasSpeech = false
            var isReady = false
            for unit in units {
                guard unit.isComplete || isFinal else { break }
                segmentText += unit.text
                consumedUnits += 1
                segmentHasSpeech = segmentHasSpeech || unit.hasSpeech
                let speechLength = Self.speechLength(of: segmentText)
                let isFirstSegment = releasedCount == 0
                if segmentHasSpeech && (isFirstSegment || speechLength >= Self.minimumSentenceLength) {
                    // Trailing speechless units (a lone tag or fence) belong to this segment:
                    // wait until the unit after them is known.
                    isReady = true
                    break
                }
            }
            guard isReady || (isFinal && consumedUnits > 0) else { break }

            // Absorb following speechless units (placeholders, punctuation, lone fences).
            var index = consumedUnits
            var trailingIsKnown = false
            while index < units.count {
                let unit = units[index]
                if unit.hasSpeech { trailingIsKnown = true; break }
                guard unit.isComplete || isFinal else { break }
                segmentText += unit.text
                consumedUnits += 1
                index += 1
            }
            if !isFinal && !trailingIsKnown { break }

            released.append(segmentText)
            releasedCount += 1
            pending = String(pending.dropFirst(segmentText.count))
        }
        return released
    }

    /// Sentences of `text`, merged so no unit ends inside a fence. The last
    /// unit is incomplete unless `isFinal`.
    private static func units(of text: String, isFinal: Bool) -> [Unit] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentenceEnds: [String.Index] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            sentenceEnds.append(tokenRange.upperBound)
            return true
        }
        if sentenceEnds.last != text.endIndex { sentenceEnds.append(text.endIndex) }

        // Fence spans (an unclosed fence runs to the end).
        var fenceSpans: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let openRange = text.range(of: "```", range: searchStart..<text.endIndex) {
            if let closeRange = text.range(of: "```", range: openRange.upperBound..<text.endIndex) {
                fenceSpans.append(openRange.lowerBound..<closeRange.upperBound)
                searchStart = closeRange.upperBound
            } else {
                fenceSpans.append(openRange.lowerBound..<text.endIndex)
                break
            }
        }
        // A fence that starts a sentence after other text gets its own unit.
        for fenceSpan in fenceSpans where fenceSpan.lowerBound != text.startIndex {
            sentenceEnds.append(fenceSpan.lowerBound)
        }
        for fenceSpan in fenceSpans where fenceSpan.upperBound != text.endIndex {
            sentenceEnds.append(fenceSpan.upperBound)
        }
        // NLTokenizer won't split ". next" when the next sentence starts in
        // lowercase (Clicky's prompt asks for all lowercase): split there too,
        // unless the word before the stop is an abbreviation or an initial.
        let lowercaseBoundaryPattern = try! NSRegularExpression(pattern: #"([A-Za-z0-9.]+)[.!?…]+["')\]]?(\s+)(?=[a-z0-9"'(\[])"#)
        for match in lowercaseBoundaryPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let wordRange = Range(match.range(at: 1), in: text), let spaceRange = Range(match.range(at: 2), in: text) else { continue }
            let word = text[wordRange].lowercased()
            if abbreviations.contains(word) || (word.count == 1 && word.first?.isLetter == true) || word.contains(".") { continue }
            sentenceEnds.append(spaceRange.upperBound)
        }
        sentenceEnds = Array(Set(sentenceEnds)).sorted()
        let validEnds = sentenceEnds.filter { end in
            !fenceSpans.contains { $0.lowerBound < end && end < $0.upperBound }
        }

        var units: [Unit] = []
        var unitStart = text.startIndex
        for end in validEnds where end > unitStart {
            let unitText = String(text[unitStart..<end])
            units.append(Unit(text: unitText, hasSpeech: hasSpeech(unitText), isComplete: true))
            unitStart = end
        }
        if !units.isEmpty, !isFinal { units[units.count - 1].isComplete = false }

        // Placeholders that open a sentence with nothing spoken before them
        // belong to the previous sentence ("Click Share. [POINT:#57]").
        var unitIndex = 1
        while unitIndex < units.count {
            let unitCharacters = Array(units[unitIndex].text)
            var lastLeadingPlaceholder: Int?
            for (offset, character) in unitCharacters.enumerated() {
                if character == ResponseRouter.placeholder { lastLeadingPlaceholder = offset; continue }
                if character.isLetter || character.isNumber || character == "`" { break }
            }
            if let lastLeadingPlaceholder {
                units[unitIndex - 1].text += String(unitCharacters[...lastLeadingPlaceholder])
                units[unitIndex].text = String(unitCharacters[(lastLeadingPlaceholder + 1)...])
                units[unitIndex].hasSpeech = hasSpeech(units[unitIndex].text)
                if units[unitIndex].text.isEmpty {
                    units.remove(at: unitIndex)
                    continue
                }
            }
            unitIndex += 1
        }
        return units
    }

    /// Letters or digits outside fences, placeholders and markup.
    /// Words a "." doesn't end a sentence after (the stop itself excluded).
    static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "st", "jr", "sr", "no", "fig", "approx", "inc", "ltd", "co"]

    static func hasSpeech(_ text: String) -> Bool {
        speechLength(of: text) > 0
    }

    static func speechLength(of text: String) -> Int {
        var length = 0
        var isInsideFence = false
        var characters = Array(text)[...]
        while let character = characters.first {
            if characters.starts(with: ["`", "`", "`"]) {
                isInsideFence.toggle()
                characters = characters.dropFirst(3)
                continue
            }
            characters = characters.dropFirst()
            if !isInsideFence && (character.isLetter || character.isNumber) { length += 1 }
        }
        return length
    }

    /// The first segment's cut: a clause boundary, else (with a max length)
    /// the last space before the max, once the text is longer than that.
    static func firstCut(in sentence: String, options: Options) -> Int? {
        let clauseCut = firstClauseCut(in: sentence, minimumOffset: options.firstCutMinChars)
        guard let maximumLength = options.firstCutMaxChars else { return clauseCut }
        if let clauseCut, clauseCut <= maximumLength { return clauseCut }
        guard sentence.count > maximumLength, !sentence.prefix(maximumLength).contains("```") else { return clauseCut }
        let characters = Array(sentence.prefix(maximumLength))
        guard let lastSpace = characters.lastIndex(of: " "), lastSpace >= options.firstCutMinChars else { return clauseCut }
        return lastSpace + 1
    }

    /// Offset just after the first ", " or "; " at least `minimumOffset`
    /// characters in, outside fences and before any placeholder-only tail.
    static func firstClauseCut(in sentence: String, minimumOffset: Int = minimumSentenceLength) -> Int? {
        let characters = Array(sentence)
        var isInsideFence = false
        var index = 0
        while index + 1 < characters.count {
            if index + 2 < characters.count, characters[index] == "`", characters[index + 1] == "`", characters[index + 2] == "`" {
                isInsideFence.toggle()
                index += 3
                continue
            }
            if !isInsideFence, index >= minimumOffset, (characters[index] == "," || characters[index] == ";"), characters[index + 1] == " " {
                return index + 2
            }
            index += 1
        }
        return nil
    }
}
