//
//  SignDecoding.swift
//  ClickyCore
//
//  Sign to text, step three: what the models' scores say. A word model gives one score per word it knows; the
//  finger-spelling model gives rows of scores (CTC), one row per two frames, that are read into letters here.
//  `Tools/signs/SPEC.md` section 4 says what each model gives. Pure Foundation: Core ML runs in the app.
//

import Foundation

// MARK: - Shared math

enum SignScoreMath {
    /// Softmax in Double, with the largest score taken off first so large scores never overflow. A NaN score
    /// counts as minus infinity. All minus infinity gives every entry the same share; any plus infinity shares
    /// everything among the plus infinities.
    static func softmax(_ scores: [Float]) -> [Double] {
        guard !scores.isEmpty else { return [] }
        let usableScores: [Double] = scores.map { score in
            score.isNaN ? -Double.infinity : Double(score)
        }
        var largestScore = -Double.infinity
        for score in usableScores where score > largestScore {
            largestScore = score
        }
        if largestScore == -Double.infinity {
            let evenShare = 1.0 / Double(usableScores.count)
            return [Double](repeating: evenShare, count: usableScores.count)
        }
        if largestScore == Double.infinity {
            let infiniteScoreCount = usableScores.filter { $0 == Double.infinity }.count
            return usableScores.map { score in
                score == Double.infinity ? 1.0 / Double(infiniteScoreCount) : 0.0
            }
        }
        let shiftedExponentials = usableScores.map { score in exp(score - largestScore) }
        let exponentialTotal = shiftedExponentials.reduce(0.0, +)
        return shiftedExponentials.map { exponential in exponential / exponentialTotal }
    }

    /// The index of the largest score; the lower index wins a tie. A NaN score never wins. Nil for no scores.
    static func indexOfLargestScore(_ scores: ArraySlice<Float>) -> Int? {
        var bestIndex: Int? = nil
        var bestScore = -Float.infinity
        for (index, score) in zip(scores.indices, scores) {
            if score.isNaN { continue }
            if bestIndex == nil || score > bestScore {
                bestIndex = index
                bestScore = score
            }
        }
        // Every score was NaN: the first one stands in.
        if bestIndex == nil && !scores.isEmpty {
            bestIndex = scores.startIndex
        }
        return bestIndex
    }
}

// MARK: - Words

/// One word the word model thinks the sign may be, with how likely it says it is (0–1).
public struct SignWordGuess: Equatable, Sendable {
    /// The dataset's label (lower case, no spaces); `SignWordNames.displayText(for:)` makes it readable.
    public var label: String
    public var probability: Float

    public init(label: String, probability: Float) {
        self.label = label
        self.probability = probability
    }
}

public enum SignWordScores {
    /// Softmax of the model's scores (stable for large scores).
    public static func probabilities(scores: [Float]) -> [Float] {
        SignScoreMath.softmax(scores).map { Float($0) }
    }

    /// The `count` most likely words, most likely first; equal scores keep the lower index first. Empty when the
    /// labels don't match the scores one for one (a model and a labels file from different trainings).
    public static func topGuesses(scores: [Float], labels: [String], count: Int) -> [SignWordGuess] {
        guard scores.count == labels.count, !scores.isEmpty, count > 0 else { return [] }
        let probabilities = SignScoreMath.softmax(scores)
        // Sorted by probability (the softmax keeps the scores' order), then by index so a tie is decided the same
        // way every time.
        let orderedIndices = probabilities.indices.sorted { firstIndex, secondIndex in
            if probabilities[firstIndex] != probabilities[secondIndex] {
                return probabilities[firstIndex] > probabilities[secondIndex]
            }
            return firstIndex < secondIndex
        }
        return orderedIndices.prefix(count).map { index in
            SignWordGuess(label: labels[index], probability: Float(probabilities[index]))
        }
    }
}

// MARK: - Finger-spelling

/// What the finger-spelling model read: the letters, and how sure it was (0–1, 0 when nothing was read).
public struct SignSpelledGuess: Equatable, Sendable {
    public var text: String
    public var confidence: Float

    public init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }

    public static let nothing = SignSpelledGuess(text: "", confidence: 0)
}

/// Reads CTC rows greedily: the best column of each row, repeats joined, blanks dropped.
public enum SignSpellingDecoder {
    /// Column 0 of every row is the CTC blank ("no new letter here").
    public static let blankColumn = 0

    /// The model gives one row per two frames, so a stretch of `realFrameCount` real frames (before padding) fills
    /// this many rows; the rows after it only saw padding.
    public static func usedRowCount(forRealFrameCount realFrameCount: Int) -> Int {
        max(0, (realFrameCount + 1) / 2)
    }

    /// - Parameters:
    ///   - scores: `rowCount × (characters.count + 1)` numbers, row-major. Column 0 is the blank, column i + 1 is
    ///     `characters[i]`. Raw scores or log-probabilities both work: each row's softmax gives its probabilities.
    ///   - usedRowCount: only the first this many rows are read (see `usedRowCount(forRealFrameCount:)`).
    /// - Returns: the text, and as confidence the mean over the kept characters of the highest probability each
    ///   one's run of rows reached (0 for no text). Wrong-sized scores read as nothing.
    public static func greedy(scores: [Float], rowCount: Int, usedRowCount: Int, characters: [String]) -> SignSpelledGuess {
        let columnCount = characters.count + 1
        guard rowCount > 0, scores.count == rowCount * columnCount else { return .nothing }
        let rowsToRead = min(max(usedRowCount, 0), rowCount)

        var keptCharacters: [String] = []
        var highestProbabilityOfEachKeptCharacter: [Double] = []
        // The previous row's best column, blank included: a repeat only joins its run when no blank came between.
        var previousBestColumn: Int? = nil
        for rowIndex in 0..<rowsToRead {
            let rowStart = rowIndex * columnCount
            let rowScores = scores[rowStart..<(rowStart + columnCount)]
            guard let bestIndexInScores = SignScoreMath.indexOfLargestScore(rowScores) else { continue }
            let bestColumn = bestIndexInScores - rowStart
            let rowProbabilities = SignScoreMath.softmax(Array(rowScores))
            let bestProbability = rowProbabilities[bestColumn]

            if bestColumn == blankColumn {
                previousBestColumn = blankColumn
                continue
            }
            if bestColumn == previousBestColumn, let lastCharacterIndex = highestProbabilityOfEachKeptCharacter.indices.last {
                // The same character as the row before: still the same letter, so its run's best is kept.
                highestProbabilityOfEachKeptCharacter[lastCharacterIndex] = max(
                    highestProbabilityOfEachKeptCharacter[lastCharacterIndex],
                    bestProbability
                )
            } else {
                keptCharacters.append(characters[bestColumn - 1])
                highestProbabilityOfEachKeptCharacter.append(bestProbability)
            }
            previousBestColumn = bestColumn
        }

        guard !keptCharacters.isEmpty else { return .nothing }
        let probabilityTotal = highestProbabilityOfEachKeptCharacter.reduce(0.0, +)
        let meanProbability = probabilityTotal / Double(highestProbabilityOfEachKeptCharacter.count)
        return SignSpelledGuess(text: keptCharacters.joined(), confidence: Float(meanProbability))
    }
}
