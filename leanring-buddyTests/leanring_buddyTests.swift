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

}
