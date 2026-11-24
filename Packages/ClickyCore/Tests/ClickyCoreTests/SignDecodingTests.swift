import Foundation
import Testing
@testable import ClickyCore

/// Sign to text decoding (Tools/signs/SPEC.md section 4): word scores to the likeliest words, and the
/// finger-spelling model's CTC rows to letters.
struct SignDecodingTests {
    // MARK: Words

    @Test func topGuessesAreTheLikeliestWordsWithSoftmaxProbabilities() {
        let guesses = SignWordScores.topGuesses(scores: [1, 3, 2], labels: ["apple", "book", "cat"], count: 2)
        #expect(guesses.map(\.label) == ["book", "cat"])
        let exponentialTotal = exp(1.0) + exp(3.0) + exp(2.0)
        #expect(abs(Double(guesses[0].probability) - exp(3.0) / exponentialTotal) < 1e-6)
        #expect(abs(Double(guesses[1].probability) - exp(2.0) / exponentialTotal) < 1e-6)
    }

    @Test func equalScoresKeepTheLowerIndexFirst() {
        let guesses = SignWordScores.topGuesses(scores: [1, 2, 2, 0], labels: ["a", "b", "c", "d"], count: 4)
        #expect(guesses.map(\.label) == ["b", "c", "a", "d"])
        #expect(guesses[0].probability == guesses[1].probability)
    }

    @Test func hugeScoresDoNotOverflow() {
        let guesses = SignWordScores.topGuesses(scores: [1000, 1001], labels: ["low", "high"], count: 2)
        #expect(guesses.map(\.label) == ["high", "low"])
        #expect(guesses.allSatisfy { $0.probability.isFinite })
        #expect(abs(Double(guesses[0].probability) - 1 / (1 + exp(-1.0))) < 1e-6)
        let total = SignWordScores.probabilities(scores: [-500, 800, 799.5]).reduce(Float(0), +)
        #expect(abs(total - 1) < 1e-6)
    }

    @Test func labelsThatDoNotMatchTheScoresGiveNothing() {
        #expect(SignWordScores.topGuesses(scores: [1, 2], labels: ["a"], count: 1).isEmpty)
        #expect(SignWordScores.topGuesses(scores: [], labels: [], count: 3).isEmpty)
        #expect(SignWordScores.topGuesses(scores: [1, 2], labels: ["a", "b"], count: 0).isEmpty)
        // Asking for more than there are gives them all.
        #expect(SignWordScores.topGuesses(scores: [1, 2], labels: ["a", "b"], count: 5).count == 2)
    }

    // MARK: Finger-spelling

    /// Characters "a", "b", "l": column 0 is the blank, 1 is "a", 2 is "b", 3 is "l".
    private static let characters = ["a", "b", "l"]
    private static let columnCount = 4

    /// One row per entry, scoring 5 for the given column and 0 for the rest.
    private static func rows(bestColumns: [Int]) -> [Float] {
        var scores: [Float] = []
        for bestColumn in bestColumns {
            for column in 0..<columnCount {
                scores.append(column == bestColumn ? 5 : 0)
            }
        }
        return scores
    }

    /// One row of log-probabilities: `probability` for the best column, the rest shared by the other columns.
    private static func logProbabilityRow(bestColumn: Int, probability: Double) -> [Float] {
        let otherProbability = (1 - probability) / Double(columnCount - 1)
        return (0..<columnCount).map { column in
            Float(log(column == bestColumn ? probability : otherProbability))
        }
    }

    private static func greedy(_ scores: [Float], usedRowCount: Int? = nil) -> SignSpelledGuess {
        let rowCount = scores.count / columnCount
        return SignSpellingDecoder.greedy(scores: scores, rowCount: rowCount, usedRowCount: usedRowCount ?? rowCount, characters: characters)
    }

    @Test func aRepeatSeparatedByABlankIsTwoLetters() {
        // "l", blank, "l" is "ll" (as in "hello").
        #expect(Self.greedy(Self.rows(bestColumns: [3, 0, 3])).text == "ll")
        #expect(Self.greedy(Self.rows(bestColumns: [0, 1, 1, 0, 2, 0, 3, 0, 3, 0])).text == "abll")
    }

    @Test func unseparatedRepeatsCollapseIntoOneLetter() {
        #expect(Self.greedy(Self.rows(bestColumns: [3, 3, 3])).text == "l")
        #expect(Self.greedy(Self.rows(bestColumns: [1, 1, 2, 2, 1])).text == "aba")
    }

    @Test func onlyBlanksReadAsNothingWithNoConfidence() {
        let guess = Self.greedy(Self.rows(bestColumns: [0, 0, 0]))
        #expect(guess.text == "")
        #expect(guess.confidence == 0)
    }

    @Test func rowsAfterTheUsedOnesAreIgnored() {
        let scores = Self.rows(bestColumns: [1, 0, 2, 3])
        #expect(Self.greedy(scores, usedRowCount: 1).text == "a")
        #expect(Self.greedy(scores, usedRowCount: 3).text == "ab")
        #expect(Self.greedy(scores, usedRowCount: 0).text == "")
        // More than there are reads them all.
        #expect(Self.greedy(scores, usedRowCount: 99).text == "abl")
    }

    @Test func confidenceIsTheMeanOfEachLettersBestProbability() {
        // "a" over two rows (0.6 then 0.9: its best is 0.9), a blank, then "b" at 0.7: (0.9 + 0.7) / 2 = 0.8.
        let scores: [Float] = [
            Self.logProbabilityRow(bestColumn: 1, probability: 0.6),
            Self.logProbabilityRow(bestColumn: 1, probability: 0.9),
            Self.logProbabilityRow(bestColumn: 0, probability: 0.95),
            Self.logProbabilityRow(bestColumn: 2, probability: 0.7)
        ].flatMap { $0 }
        let guess = Self.greedy(scores)
        #expect(guess.text == "ab")
        #expect(abs(guess.confidence - 0.8) < 1e-5)
    }

    @Test func rawScoresAndLogProbabilitiesReadTheSame() {
        // Raw scores are log-probabilities plus a constant per row: the softmax, and so the reading, is the same.
        let logProbabilities: [Float] = [
            Self.logProbabilityRow(bestColumn: 3, probability: 0.8),
            Self.logProbabilityRow(bestColumn: 0, probability: 0.6),
            Self.logProbabilityRow(bestColumn: 1, probability: 0.75)
        ].flatMap { $0 }
        let rawScores = logProbabilities.map { $0 + 7 }
        let fromLogProbabilities = Self.greedy(logProbabilities)
        let fromRawScores = Self.greedy(rawScores)
        #expect(fromLogProbabilities.text == "la")
        #expect(fromRawScores.text == "la")
        #expect(abs(fromLogProbabilities.confidence - fromRawScores.confidence) < 1e-5)
        #expect(abs(fromRawScores.confidence - 0.775) < 1e-5)
    }

    @Test func wrongSizedScoresReadAsNothing() {
        let scores = Self.rows(bestColumns: [1, 2])
        let tooFewCharacters = SignSpellingDecoder.greedy(scores: scores, rowCount: 2, usedRowCount: 2, characters: ["a", "b"])
        #expect(tooFewCharacters == .nothing)
        let wrongRowCount = SignSpellingDecoder.greedy(scores: scores, rowCount: 3, usedRowCount: 3, characters: Self.characters)
        #expect(wrongRowCount == .nothing)
        #expect(SignSpellingDecoder.greedy(scores: [], rowCount: 0, usedRowCount: 0, characters: Self.characters) == .nothing)
    }

    @Test func usedRowsAreHalfTheRealFramesRoundedUp() {
        #expect(SignSpellingDecoder.usedRowCount(forRealFrameCount: 0) == 0)
        #expect(SignSpellingDecoder.usedRowCount(forRealFrameCount: 1) == 1)
        #expect(SignSpellingDecoder.usedRowCount(forRealFrameCount: 2) == 1)
        #expect(SignSpellingDecoder.usedRowCount(forRealFrameCount: 3) == 2)
        #expect(SignSpellingDecoder.usedRowCount(forRealFrameCount: 256) == 128)
        #expect(SignSpellingDecoder.usedRowCount(forRealFrameCount: -3) == 0)
    }
}
