//
//  LabelSimilarity.swift
//  ClickyCore
//
//  How well a name the model gave ("Share") matches an element's label.
//  labelSim = max(Dice over word tokens, 1 − levenshtein / longer length)
//  after normalising both (lowercase, NFKC, unified quotes and ellipses).
//

import Foundation

public enum LabelSimilarity {
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best similarity of `query` against any of `candidateTexts`.
    public static func labelSim(_ query: String, candidates candidateTexts: [String?]) -> Double {
        candidateTexts.compactMap { $0 }.map { similarity(query, $0) }.max() ?? 0
    }

    public static func similarity(_ first: String, _ second: String) -> Double {
        let normalizedFirst = normalize(first)
        let normalizedSecond = normalize(second)
        guard !normalizedFirst.isEmpty, !normalizedSecond.isEmpty else { return 0 }
        if normalizedFirst == normalizedSecond { return 1 }
        let editSimilarity = 1 - Double(levenshtein(Array(normalizedFirst), Array(normalizedSecond)))
            / Double(max(normalizedFirst.count, normalizedSecond.count))
        return max(diceCoefficient(tokens(normalizedFirst), tokens(normalizedSecond)), editSimilarity)
    }

    static func tokens(_ normalizedText: String) -> [String] {
        normalizedText.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func diceCoefficient(_ firstTokens: [String], _ secondTokens: [String]) -> Double {
        guard !firstTokens.isEmpty, !secondTokens.isEmpty else { return 0 }
        var remainingSecond = secondTokens
        var sharedCount = 0
        for token in firstTokens {
            if let matchIndex = remainingSecond.firstIndex(of: token) {
                sharedCount += 1
                remainingSecond.remove(at: matchIndex)
            }
        }
        return 2 * Double(sharedCount) / Double(firstTokens.count + secondTokens.count)
    }

    public static func levenshtein(_ first: [Character], _ second: [Character]) -> Int {
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }
        var previousRow = Array(0...second.count)
        var currentRow = Array(repeating: 0, count: second.count + 1)
        for firstIndex in 1...first.count {
            currentRow[0] = firstIndex
            for secondIndex in 1...second.count {
                let substitutionCost = first[firstIndex - 1] == second[secondIndex - 1] ? 0 : 1
                currentRow[secondIndex] = min(previousRow[secondIndex] + 1, currentRow[secondIndex - 1] + 1,
                                              previousRow[secondIndex - 1] + substitutionCost)
            }
            swap(&previousRow, &currentRow)
        }
        return previousRow[second.count]
    }

    /// Edits allowed for a fuzzy match: 1 per 6 characters of the query.
    public static func allowedEdits(forQueryLength queryLength: Int) -> Int {
        queryLength / 6
    }

    /// Where `query` occurs in `text`: exact (case/normalisation-insensitive)
    /// first, else the best approximate substring within the edit budget.
    /// Returns the matched range in the NORMALISED text's characters plus
    /// whether it was fuzzy, or nil.
    public static func findOccurrences(of query: String, in text: String) -> [(range: Range<Int>, isFuzzy: Bool)] {
        let normalizedQuery = Array(normalize(query))
        let normalizedText = Array(normalize(text))
        guard !normalizedQuery.isEmpty, normalizedText.count >= 1 else { return [] }

        var exactMatches: [(range: Range<Int>, isFuzzy: Bool)] = []
        if normalizedText.count >= normalizedQuery.count {
            var startIndex = 0
            while startIndex + normalizedQuery.count <= normalizedText.count {
                if Array(normalizedText[startIndex..<(startIndex + normalizedQuery.count)]) == normalizedQuery {
                    exactMatches.append((startIndex..<(startIndex + normalizedQuery.count), false))
                    startIndex += normalizedQuery.count
                } else {
                    startIndex += 1
                }
            }
        }
        if !exactMatches.isEmpty { return exactMatches }

        let editBudget = allowedEdits(forQueryLength: normalizedQuery.count)
        guard editBudget > 0 else { return [] }
        // Approximate substring search (Sellers): best end position, then
        // walk back to find its start.
        var bestDistance = Int.max
        var bestRange: Range<Int>?
        for startIndex in 0..<normalizedText.count {
            let maximumLength = min(normalizedQuery.count + editBudget, normalizedText.count - startIndex)
            let minimumLength = max(1, normalizedQuery.count - editBudget)
            guard maximumLength >= minimumLength else { continue }
            for windowLength in minimumLength...maximumLength {
                let window = Array(normalizedText[startIndex..<(startIndex + windowLength)])
                let distance = levenshtein(normalizedQuery, window)
                if distance <= editBudget && distance < bestDistance {
                    bestDistance = distance
                    bestRange = startIndex..<(startIndex + windowLength)
                }
            }
        }
        return bestRange.map { [($0, true)] } ?? []
    }
}
