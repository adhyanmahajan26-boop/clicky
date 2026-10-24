//
//  CompanionWorkers.swift
//  leanring-buddy
//
//  Helper workers for the main brain. For questions that split into
//  independent smaller sub-tasks, the main Claude request replies with a
//  short heads-up plus [WORKER:short title:task prompt] tags. Each tag runs
//  as its own parallel Claude request on Haiku (fast and cheap), at most four
//  at a time with the rest queued, and their results go back to the main
//  brain for the final spoken answer.
//
//  CompanionWorkerRunner is also the real CompanionActivitySource: each
//  running worker shows up as a mini spark orbiting the companion.
//

import Foundation

/// One sub-task the main brain asked for.
struct CompanionWorkerRequest: Equatable {
    let workerTitle: String
    let workerTaskPrompt: String
}

/// What a worker came back with. Failed workers still produce a result so
/// the main brain can answer with whatever the others found.
struct CompanionWorkerResult: Equatable {
    let workerTitle: String
    let workerResultText: String
    let didWorkerSucceed: Bool
}

enum CompanionWorkerTagParser {
    /// Four run at once and the rest queue; past this many the main brain is
    /// over-splitting, so extras are dropped.
    static let maximumWorkerRequestsPerResponse = 8

    private static let workerTagPattern = #"\[WORKER:\s*([^:\]]+?)\s*:\s*([^\]]+?)\s*\]"#

    /// Removes every [WORKER:...] tag (even malformed ones, so they're never
    /// spoken) and returns the remaining text plus the requests in order.
    static func extractWorkerTags(from responseText: String) -> (textWithoutWorkerTags: String, workerRequests: [CompanionWorkerRequest]) {
        guard let workerTagRegex = try? NSRegularExpression(pattern: workerTagPattern, options: [.caseInsensitive]) else {
            return (responseText, [])
        }

        let fullResponseRange = NSRange(responseText.startIndex..., in: responseText)
        var workerRequests: [CompanionWorkerRequest] = []

        for workerTagMatch in workerTagRegex.matches(in: responseText, range: fullResponseRange) {
            guard workerRequests.count < maximumWorkerRequestsPerResponse,
                  let titleRange = Range(workerTagMatch.range(at: 1), in: responseText),
                  let taskPromptRange = Range(workerTagMatch.range(at: 2), in: responseText) else { continue }

            let workerTitle = responseText[titleRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let workerTaskPrompt = responseText[taskPromptRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workerTitle.isEmpty, !workerTaskPrompt.isEmpty else { continue }

            workerRequests.append(CompanionWorkerRequest(workerTitle: workerTitle, workerTaskPrompt: workerTaskPrompt))
        }

        var textWithoutWorkerTags = workerTagRegex.stringByReplacingMatches(in: responseText, range: fullResponseRange, withTemplate: "")
        if let looseWorkerTagRegex = try? NSRegularExpression(pattern: #"\[WORKER:[^\]]*\]"#, options: [.caseInsensitive]) {
            textWithoutWorkerTags = looseWorkerTagRegex.stringByReplacingMatches(
                in: textWithoutWorkerTags,
                range: NSRange(textWithoutWorkerTags.startIndex..., in: textWithoutWorkerTags),
                withTemplate: ""
            )
        }

        let collapsedText = textWithoutWorkerTags
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (collapsedText, workerRequests)
    }
}

@MainActor
final class CompanionWorkerRunner: CompanionActivitySource {
    /// The orbit shows four minis (CompanionActivityLimits.maximumVisibleWorkers),
    /// and four parallel CLI processes is plenty. Nonisolated because it's used
    /// as a default argument, which Swift evaluates outside the main actor.
    nonisolated static let maximumConcurrentWorkers = 4

    /// Workers run on Haiku: their sub-tasks are small, and speed matters
    /// more than depth since the user is waiting on the spoken answer. The
    /// main brain keeps whatever model the user picked.
    static let workerClaudeModel = "haiku"

    /// A fresh bridge per worker so parallel requests never share state.
    static func makeWorkerClaudeCodeBridge() -> ClaudeCodeBridge {
        ClaudeCodeBridge(model: workerClaudeModel)
    }

    /// The main brain's own thinking already spins the spark via voiceState.
    let coordinatorIsThinking = false
    private(set) var workers: [CompanionWorkerActivity] = []
    var onActivityChanged: (() -> Void)?

    private var workerRunNumber = 0

    /// Runs every request with at most `maximumConcurrentWorkers` in flight;
    /// as each finishes the next queued one starts. Results come back in
    /// request order. Cancelling the calling task cancels every worker.
    func runWorkers(
        _ workerRequests: [CompanionWorkerRequest],
        maximumConcurrentWorkers: Int = CompanionWorkerRunner.maximumConcurrentWorkers,
        performWorkerRequest: @escaping @MainActor (CompanionWorkerRequest) async throws -> String
    ) async throws -> [CompanionWorkerResult] {
        guard !workerRequests.isEmpty else { return [] }

        workerRunNumber += 1
        let currentWorkerRunNumber = workerRunNumber
        defer {
            workers = []
            onActivityChanged?()
        }

        var workerResultsByIndex: [Int: CompanionWorkerResult] = [:]

        try await withThrowingTaskGroup(of: (Int, CompanionWorkerResult).self) { workerTaskGroup in
            var nextWorkerIndexToStart = 0

            while nextWorkerIndexToStart < min(maximumConcurrentWorkers, workerRequests.count) {
                startWorker(
                    workerIndex: nextWorkerIndexToStart,
                    workerRequest: workerRequests[nextWorkerIndexToStart],
                    workerRunNumber: currentWorkerRunNumber,
                    workerTaskGroup: &workerTaskGroup,
                    performWorkerRequest: performWorkerRequest
                )
                nextWorkerIndexToStart += 1
            }

            while let (finishedWorkerIndex, workerResult) = try await workerTaskGroup.next() {
                workerResultsByIndex[finishedWorkerIndex] = workerResult
                markWorkerFinished(workerID: Self.workerID(workerRunNumber: currentWorkerRunNumber, workerIndex: finishedWorkerIndex))

                if nextWorkerIndexToStart < workerRequests.count {
                    startWorker(
                        workerIndex: nextWorkerIndexToStart,
                        workerRequest: workerRequests[nextWorkerIndexToStart],
                        workerRunNumber: currentWorkerRunNumber,
                        workerTaskGroup: &workerTaskGroup,
                        performWorkerRequest: performWorkerRequest
                    )
                    nextWorkerIndexToStart += 1
                }
            }
        }

        return workerRequests.indices.compactMap { workerResultsByIndex[$0] }
    }

    private func startWorker(
        workerIndex: Int,
        workerRequest: CompanionWorkerRequest,
        workerRunNumber: Int,
        workerTaskGroup: inout ThrowingTaskGroup<(Int, CompanionWorkerResult), Error>,
        performWorkerRequest: @escaping @MainActor (CompanionWorkerRequest) async throws -> String
    ) {
        workers.append(CompanionWorkerActivity(
            id: Self.workerID(workerRunNumber: workerRunNumber, workerIndex: workerIndex),
            workerTitle: workerRequest.workerTitle,
            isWorking: true
        ))
        onActivityChanged?()
        print("🛠️ Worker started (\(Self.workerClaudeModel)): \(workerRequest.workerTitle)")

        workerTaskGroup.addTask { @MainActor in
            do {
                let workerResultText = try await performWorkerRequest(workerRequest)
                return (workerIndex, CompanionWorkerResult(
                    workerTitle: workerRequest.workerTitle,
                    workerResultText: workerResultText,
                    didWorkerSucceed: true
                ))
            } catch {
                // Cancellation (Escape, "stop", a new question) ends the whole
                // run. Any other failure only loses this one worker's answer.
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                print("⚠️ Worker failed: \(workerRequest.workerTitle): \(error)")
                return (workerIndex, CompanionWorkerResult(
                    workerTitle: workerRequest.workerTitle,
                    workerResultText: "This helper failed: \(error.localizedDescription)",
                    didWorkerSucceed: false
                ))
            }
        }
    }

    /// Finished workers stay in the list as not-working until the run ends,
    /// which is what makes their mini fade off the orbit.
    private func markWorkerFinished(workerID: String) {
        guard let finishedWorkerPosition = workers.firstIndex(where: { $0.id == workerID }) else { return }
        let finishedWorker = workers[finishedWorkerPosition]
        workers[finishedWorkerPosition] = CompanionWorkerActivity(
            id: finishedWorker.id,
            workerTitle: finishedWorker.workerTitle,
            isWorking: false
        )
        onActivityChanged?()
        print("🛠️ Worker finished: \(finishedWorker.workerTitle)")
    }

    private static func workerID(workerRunNumber: Int, workerIndex: Int) -> String {
        "worker-run\(workerRunNumber)-\(workerIndex)"
    }
}
