//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import CoreGraphics
import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
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

    @Test func liveMarkTagsAreParsedInOrderAndRemovedFromSpokenText() async throws {
        let (textWithoutMarkTags, parsedMarkTags) = LiveScreenMarkTagParser.extractLiveScreenMarkTags(
            from: "click file, then save. [MARK:1:100,20:file menu] [MARK:step2:300,40:save] [MARK:circle:500,600:screen2] [MARK:arrow:7,8] [POINT:100,20:file menu]"
        )

        #expect(textWithoutMarkTags == "click file, then save. [POINT:100,20:file menu]")
        #expect(parsedMarkTags.map(\.markKind) == [.numberedStep(stepNumber: 1), .numberedStep(stepNumber: 2), .circle, .arrow])
        #expect(parsedMarkTags[0].markLabel == "file menu")
        #expect(parsedMarkTags[0].screenshotPixelCoordinate == CGPoint(x: 100, y: 20))
        #expect(parsedMarkTags[2].screenNumber == 2)
        #expect(parsedMarkTags[2].markLabel == nil)
        #expect(parsedMarkTags[3].markLabel == nil)
    }

    @Test func liveMarkTagsLeaveThePointTagParseable() async throws {
        let (textWithoutMarkTags, _) = LiveScreenMarkTagParser.extractLiveScreenMarkTags(
            from: "see that button? [MARK:circle:40,50:run] [POINT:40,50:run]"
        )
        let pointingParseResult = CompanionManager.parsePointingCoordinates(from: textWithoutMarkTags)

        #expect(pointingParseResult.spokenText == "see that button?")
        #expect(pointingParseResult.coordinate == CGPoint(x: 40, y: 50))
    }

    @Test func malformedAndExtraLiveMarkTagsAreDroppedButNeverSpoken() async throws {
        let sevenCircleTags = (1...7).map { "[MARK:circle:\($0),\($0)]" }.joined(separator: " ")
        let (textWithoutMarkTags, parsedMarkTags) = LiveScreenMarkTagParser.extractLiveScreenMarkTags(
            from: "look here [MARK:squiggle:1,2] \(sevenCircleTags)"
        )

        #expect(textWithoutMarkTags == "look here")
        #expect(parsedMarkTags.count == LiveScreenMarkTagParser.maximumMarksPerResponse)
    }

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


    @Test func workerTagsAreParsedInOrderAndRemovedFromSpeech() async throws {
        let (textWithoutWorkerTags, workerRequests) = CompanionWorkerTagParser.extractWorkerTags(
            from: "on it, checking both. [WORKER:Swift pricing:What does Swift cost? Answer briefly.] [worker: Rust pricing : What does Rust cost: free or paid?] [WORKER:broken]"
        )

        #expect(textWithoutWorkerTags == "on it, checking both.")
        #expect(workerRequests == [
            CompanionWorkerRequest(workerTitle: "Swift pricing", workerTaskPrompt: "What does Swift cost? Answer briefly."),
            CompanionWorkerRequest(workerTitle: "Rust pricing", workerTaskPrompt: "What does Rust cost: free or paid?")
        ])
    }

    @Test func responsesWithoutWorkerTagsAreLeftAlone() async throws {
        let (textWithoutWorkerTags, workerRequests) = CompanionWorkerTagParser.extractWorkerTags(
            from: "click the save button. [POINT:10,20:save]"
        )

        #expect(textWithoutWorkerTags == "click the save button. [POINT:10,20:save]")
        #expect(workerRequests.isEmpty)
    }

    @Test func workersRunOnHaiku() async throws {
        #expect(CompanionWorkerRunner.workerClaudeModel == "haiku")
        #expect(CompanionWorkerRunner.makeWorkerClaudeCodeBridge().model == "haiku")
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

}
