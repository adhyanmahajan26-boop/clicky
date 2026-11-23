import Foundation
import Testing
@testable import ClickyCore

/// A conversation holds as much as its model can, and what no longer fits is summed up, never just dropped.
struct ContextBudgetTests {
    typealias Message = ConversationCompaction.Message

    @Test func theWindowComesFromTheServerFirstThenTheModelsName() {
        #expect(ContextBudget.windowTokens(model: "qwen3-32b", isLocalServer: true, reportedTokens: 32_768) == 32_768)
        #expect(ContextBudget.windowTokens(model: "qwen3-32b", isLocalServer: true) == ContextBudget.unknownLocalWindowTokens)
        #expect(ContextBudget.windowTokens(model: "claude-sonnet-5-5", isLocalServer: false) == 200_000)
        #expect(ContextBudget.windowTokens(model: "gemini-3-pro", isLocalServer: false) == 1_000_000)
        #expect(ContextBudget.windowTokens(model: "some-new-model", isLocalServer: false) == 128_000)
    }

    @Test func theRoomLeavesSpaceForTheAnswerAndTheInstructions() {
        // A big cloud model: capped so every turn stays quick.
        let claude = ContextBudget.historyCharacters(windowTokens: 200_000, answerTokens: 8_192, instructionsCharacters: 20_000)
        #expect(claude == ContextBudget.longestLiveHistoryCharacters)
        // A local model with 32k loaded: answer, instructions and a spare tenth come off first.
        let answer = ContextBudget.answerTokens(windowTokens: 32_768, wantedAnswerTokens: 16_384)
        #expect(answer == 8_192)
        let local = ContextBudget.historyCharacters(windowTokens: 32_768, answerTokens: answer, instructionsCharacters: 9_000)
        #expect(local > 50_000 && local < 60_000)
        // A tiny window still sends something.
        #expect(ContextBudget.historyCharacters(windowTokens: 4_096, answerTokens: 1_024, instructionsCharacters: 30_000) == 2_000)
        // A call starts with a quarter of the room, at most about 13,000 words.
        #expect(ContextBudget.callCarryOverCharacters(historyCharacters: claude) == 40_000)
        #expect(ContextBudget.callCarryOverCharacters(historyCharacters: 20_000) == 5_000)
    }

    private func conversation(turns: Int, wordsEach: Int) -> [Message] {
        (1...turns).flatMap { turn in
            [Message(role: "user", text: "question \(turn) " + String(repeating: "word ", count: wordsEach)),
             Message(role: "assistant", text: "answer \(turn) " + String(repeating: "word ", count: wordsEach))]
        }
    }

    @Test func nothingIsSummedUpWhileItFits() {
        let short = conversation(turns: 5, wordsEach: 10)
        #expect(ConversationCompaction.partToSummarize(short, roomCharacters: 100_000) == nil)
        #expect(ConversationCompaction.fitting(short, roomCharacters: 100_000) == short)
    }

    @Test func theOldestPartIsSummedUpAndTheNewestStaysWordForWord() throws {
        let long = conversation(turns: 40, wordsEach: 100) // about 40,000 characters
        let count = try #require(ConversationCompaction.partToSummarize(long, roomCharacters: 20_000))
        #expect(long[count].role == "user")
        #expect(ConversationCompaction.totalCharacters(Array(long[count...])) <= 10_000 + 600)
        let request = ConversationCompaction.summaryRequest(for: Array(long.prefix(count)), owner: "Sam")
        #expect(request.contains("Sam: question 1 "))
        #expect(request.contains("Keep every fact"))
        let compacted = ConversationCompaction.replacing(long, firstCount: count, withSummary: "Sam asked forty questions about words.")
        #expect(ConversationCompaction.isSummary(compacted[0]))
        #expect(compacted[1].role == "assistant")
        #expect(compacted[2].role == "user")
        #expect(compacted.last == long.last)
        // The next summary takes the earlier one in, so nothing is ever simply dropped.
        let longer = compacted + conversation(turns: 40, wordsEach: 100)
        let next = try #require(ConversationCompaction.partToSummarize(longer, roomCharacters: 20_000))
        let nextRequest = ConversationCompaction.summaryRequest(for: Array(longer.prefix(next)), owner: "Sam")
        #expect(nextRequest.contains("Earlier summary:\n(Summary of the earlier part"))
        #expect(nextRequest.contains("Sam asked forty questions about words."))
    }

    @Test func untilTheSummaryIsReadyEachTurnStillFitsTheWindow() {
        let summary = ConversationCompaction.replacing(conversation(turns: 2, wordsEach: 5), firstCount: 2, withSummary: "Earlier: the rent is due on the 5th.")
        let long = Array(summary.prefix(2)) + conversation(turns: 60, wordsEach: 100)
        let fitted = ConversationCompaction.fitting(long, roomCharacters: 15_000)
        #expect(ConversationCompaction.totalCharacters(fitted) <= 15_000)
        #expect(ConversationCompaction.isSummary(fitted[0]))
        #expect(fitted[2].role == "user")
        #expect(fitted.last == long.last)
        // One message bigger than the whole room keeps its end.
        let huge = [Message(role: "user", text: "start " + String(repeating: "x", count: 50_000) + " the question")]
        let cut = ConversationCompaction.fitting(huge, roomCharacters: 5_000)
        #expect(cut.count == 1 && cut[0].text.hasSuffix("the question") && cut[0].text.count <= 5_000)
    }
}
