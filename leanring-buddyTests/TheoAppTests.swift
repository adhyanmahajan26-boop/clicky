//
//  TheoAppTests.swift
//  leanring-buddyTests
//

import ClickyCore
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

@MainActor
struct TheoAppTests {

    @Test func permissionAsksPromptOnceThenOpenSettings() {
        #expect(PermissionAskOutcome.next(isGranted: false, promptedThisLaunch: false) == .systemPrompt)
        #expect(PermissionAskOutcome.next(isGranted: false, promptedThisLaunch: true) == .systemSettings)
        #expect(PermissionAskOutcome.next(isGranted: true, promptedThisLaunch: true) == .alreadyGranted)
    }

    @Test func handsFreeCommandsIgnoreFillerWordsAndPunctuation() async throws {
        #expect(HandsFreeVoiceCommand.parse("Okay Clicky, wait.") == .pause)
        #expect(HandsFreeVoiceCommand.parse("Keep going!") == .resume)
        #expect(HandsFreeVoiceCommand.parse("Stop listening") == .endSession)
        #expect(HandsFreeVoiceCommand.parse("That's it") == .endSession)
        #expect(HandsFreeVoiceCommand.parse("Slow down") == .slower)
    }

    @Test func handsFreeCaptureCommandsParseTheRequestedCount() async throws {
        #expect(HandsFreeVoiceCommand.parse("Take a screenshot") == .capture(requestedCaptureCount: 1))
        #expect(HandsFreeVoiceCommand.parse("capture these two") == .capture(requestedCaptureCount: 2))
        #expect(HandsFreeVoiceCommand.parse("take 3 screenshots") == .capture(requestedCaptureCount: 3))
    }

    @Test func handsFreeClearCommandsRemoveLiveMarks() async throws {
        #expect(HandsFreeVoiceCommand.parse("Clear.") == .clearMarks)
        #expect(HandsFreeVoiceCommand.parse("okay clear the marks") == .clearMarks)
        #expect(HandsFreeVoiceCommand.parse("erase that") == .clearMarks)
        #expect(HandsFreeVoiceCommand.parse("how do I clear my browser cache") == nil)
    }

    // The legacy [MARK]/[POINT] regex parsers were replaced by ClickyCore's
    // MarkTagParser in v2 P1b; its tests live in MarkTagParserTests.

    @Test func handsFreeQuestionsThatContainCommandWordsGoToClaude() async throws {
        #expect(HandsFreeVoiceCommand.parse("how do I stop the music from playing") == nil)
        #expect(HandsFreeVoiceCommand.parse("what does this capture button do") == nil)
    }


    @Test func companionShowsOnlyRunningWorkersAndAtMostFour() async throws {
        let sixWorkersWithOneFinished = (1...6).map { workerNumber in
            CompanionWorkerActivity(id: "worker-\(workerNumber)", workerTitle: "Thread \(workerNumber)", isWorking: workerNumber != 2)
        }

        let visibleWorkers = CompanionActivityLimits.visibleWorkers(from: sixWorkersWithOneFinished)

        #expect(visibleWorkers.map(\.id) == ["worker-1", "worker-3", "worker-4", "worker-5"])
    }

    @MainActor
    @Test func simulatedActivitySourceClampsToFourAndKeepsExistingWorkers() async throws {
        let simulatedCompanionActivitySource = SimulatedCompanionActivitySource()
        var activityChangeCount = 0
        simulatedCompanionActivitySource.onActivityChanged = { activityChangeCount += 1 }

        simulatedCompanionActivitySource.setSimulatedWorkingWorkerCount(3)
        let firstThreeWorkerIDs = simulatedCompanionActivitySource.workers.map(\.id)
        simulatedCompanionActivitySource.setSimulatedWorkingWorkerCount(9)
        #expect(simulatedCompanionActivitySource.workers.count == 4)
        #expect(Array(simulatedCompanionActivitySource.workers.map(\.id).prefix(3)) == firstThreeWorkerIDs)

        simulatedCompanionActivitySource.setSimulatedWorkingWorkerCount(1)
        #expect(simulatedCompanionActivitySource.workers.map(\.id) == [firstThreeWorkerIDs[0]])

        simulatedCompanionActivitySource.setSimulatedCoordinatorThinking(true)
        #expect(simulatedCompanionActivitySource.coordinatorIsThinking)
        #expect(activityChangeCount == 4)
    }

    @MainActor
    @Test func orbitingWorkersAreEvenlySpacedStartingAtTheTop() async throws {
        let threeWorkerSlotDegrees = (0..<3).map {
            ClaudeCompanionView.evenlySpacedOrbitSlotDegrees(workerIndex: $0, activeWorkerCount: 3)
        }
        #expect(threeWorkerSlotDegrees == [-90, 30, 150])
        #expect(ClaudeCompanionView.evenlySpacedOrbitSlotDegrees(workerIndex: 1, activeWorkerCount: 4) == 0)
    }


    @Test func workerTagsAreRoutedOutOfSpeech() async throws {
        var router = ResponseRouter()
        let outputs = router.feed("on it, checking both.\n[WORKER:Swift pricing:What does Swift cost? Answer briefly.]\n[worker: Rust pricing : What does Rust cost: free or paid?]\n") + router.finish()
        let workers = outputs.compactMap { output -> CompanionWorkerRequest? in
            if case .worker(let title, let task) = output { return CompanionWorkerRequest(workerTitle: title, workerTaskPrompt: task) }
            return nil
        }
        let narration = outputs.compactMap { output -> String? in
            if case .narration(let text) = output { return text }
            return nil
        }.joined()
        #expect(narration.trimmingCharacters(in: .whitespacesAndNewlines) == "on it, checking both.")
        #expect(workers == [
            CompanionWorkerRequest(workerTitle: "Swift pricing", workerTaskPrompt: "What does Swift cost? Answer briefly."),
            CompanionWorkerRequest(workerTitle: "Rust pricing", workerTaskPrompt: "What does Rust cost: free or paid?")
        ])
    }

    @Test func workersRunOnHaiku() async throws {
        #expect(CompanionWorkerRunner.workerClaudeModel == ClickyModels.haiku)
        #expect(CompanionWorkerRunner.makeWorkerClaudeCodeBridge().model == ClickyModels.haiku)
    }

    @MainActor
    @Test func workerRunnerRunsAtMostFourAtOnceAndQueuesTheRest() async throws {
        let companionWorkerRunner = CompanionWorkerRunner()
        let sixWorkerRequests = (1...6).map {
            CompanionWorkerRequest(workerTitle: "task \($0)", workerTaskPrompt: "do task \($0)")
        }
        var currentlyRunningWorkerCount = 0
        var peakRunningWorkerCount = 0
        var peakVisibleWorkerCount = 0
        companionWorkerRunner.onActivityChanged = {
            peakVisibleWorkerCount = max(peakVisibleWorkerCount, companionWorkerRunner.workers.filter(\.isWorking).count)
        }

        let workerResults = try await companionWorkerRunner.runWorkers(sixWorkerRequests) { workerRequest in
            currentlyRunningWorkerCount += 1
            peakRunningWorkerCount = max(peakRunningWorkerCount, currentlyRunningWorkerCount)
            try await Task.sleep(nanoseconds: 20_000_000)
            currentlyRunningWorkerCount -= 1
            return "done: \(workerRequest.workerTitle)"
        }

        #expect(peakRunningWorkerCount == 4)
        #expect(peakVisibleWorkerCount == 4)
        #expect(workerResults.map(\.workerResultText) == sixWorkerRequests.map { "done: \($0.workerTitle)" })
        #expect(companionWorkerRunner.workers.isEmpty)
    }

    @MainActor
    @Test func oneFailedWorkerDoesNotSinkTheOthers() async throws {
        struct SimulatedWorkerFailure: Error {}
        let companionWorkerRunner = CompanionWorkerRunner()
        let twoWorkerRequests = [
            CompanionWorkerRequest(workerTitle: "works", workerTaskPrompt: "ok"),
            CompanionWorkerRequest(workerTitle: "fails", workerTaskPrompt: "boom")
        ]

        let workerResults = try await companionWorkerRunner.runWorkers(twoWorkerRequests) { workerRequest in
            if workerRequest.workerTitle == "fails" { throw SimulatedWorkerFailure() }
            return "fine"
        }

        #expect(workerResults.map(\.didWorkerSucceed) == [true, false])
    }


    @Test func copyThatIsALocalVoiceCommand() async throws {
        #expect(HandsFreeVoiceCommand.parse("copy that") == .copyLastAnswer)
        #expect(HandsFreeVoiceCommand.parse("okay clicky, copy the answer") == .copyLastAnswer)
        #expect(HandsFreeVoiceCommand.parse("copy that file to the desktop") == nil)
    }
}
