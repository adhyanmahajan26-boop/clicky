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

    /// Fuzzy search is skipped above this many characters (a console or a
    /// long chat transcript): exact matches only there.
    public static let maximumFuzzyTextLength = 20_000

    /// Where `query` occurs in `text`: exact (case/normalisation-insensitive)
    /// first, else the best approximate substring within the edit budget.
    /// Returns the matched range in the NORMALISED text's characters plus
    /// whether it was fuzzy, or nil. Linear in the text length.
    public static func findOccurrences(of query: String, in text: String) -> [(range: Range<Int>, isFuzzy: Bool)] {
        let normalizedQuery = Array(normalize(query))
        let normalizedText = Array(normalize(text))
        let queryLength = normalizedQuery.count
        guard queryLength > 0, normalizedText.count >= 1 else { return [] }

        var exactMatches: [(range: Range<Int>, isFuzzy: Bool)] = []
        var startIndex = 0
        while startIndex + queryLength <= normalizedText.count {
            var isMatch = true
            for offset in 0..<queryLength where normalizedText[startIndex + offset] != normalizedQuery[offset] {
                isMatch = false
                break
            }
            if isMatch {
                exactMatches.append((startIndex..<(startIndex + queryLength), false))
                startIndex += queryLength
            } else {
                startIndex += 1
            }
        }
        if !exactMatches.isEmpty { return exactMatches }

        let editBudget = allowedEdits(forQueryLength: queryLength)
        guard editBudget > 0, normalizedText.count <= maximumFuzzyTextLength else { return [] }
        // Approximate substring search (Sellers): one pass over the text
        // finds the best end position; its start is the best window ending there.
        var previousColumn = Array(0...queryLength)
        var currentColumn = Array(repeating: 0, count: queryLength + 1)
        var bestDistance = Int.max
        var bestEnd: Int?
        for textIndex in 0..<normalizedText.count {
            currentColumn[0] = 0
            for queryIndex in 1...queryLength {
                let substitutionCost = normalizedQuery[queryIndex - 1] == normalizedText[textIndex] ? 0 : 1
                currentColumn[queryIndex] = min(previousColumn[queryIndex] + 1, currentColumn[queryIndex - 1] + 1,
                                                previousColumn[queryIndex - 1] + substitutionCost)
            }
            if currentColumn[queryLength] <= editBudget && currentColumn[queryLength] < bestDistance {
                bestDistance = currentColumn[queryLength]
                bestEnd = textIndex + 1
            }
            swap(&previousColumn, &currentColumn)
        }
        guard let bestEnd, max(1, queryLength - editBudget) <= min(bestEnd, queryLength + editBudget) else { return [] }
        var bestRange: Range<Int>?
        var bestWindowDistance = Int.max
        for windowLength in max(1, queryLength - editBudget)...min(bestEnd, queryLength + editBudget) {
            let window = Array(normalizedText[(bestEnd - windowLength)..<bestEnd])
            let distance = levenshtein(normalizedQuery, window)
            if distance < bestWindowDistance {
                bestWindowDistance = distance
                bestRange = (bestEnd - windowLength)..<bestEnd
            }
        }
        return bestRange.map { [($0, true)] } ?? []
    }
}
