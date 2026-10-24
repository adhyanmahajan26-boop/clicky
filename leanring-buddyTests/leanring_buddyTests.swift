//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

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

    @Test func handsFreeQuestionsThatContainCommandWordsGoToClaude() async throws {
        #expect(HandsFreeVoiceCommand.parse("how do I stop the music from playing") == nil)
        #expect(HandsFreeVoiceCommand.parse("what does this capture button do") == nil)
    }

}
