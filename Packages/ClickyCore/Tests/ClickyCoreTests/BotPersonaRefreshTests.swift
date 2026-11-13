//
//  BotPersonaRefreshTests.swift
//  ClickyCoreTests
//

import Testing
@testable import ClickyCore

struct BotPersonaRefreshTests {
    @Test func theFingerprintChangesWithAnyPartAndOnlyThen() {
        let base = BotPersonaRefresh.fingerprint(["rev-1", "You are Accountant.", "Reports to CEO.", "gmail,drive"])
        #expect(base == BotPersonaRefresh.fingerprint(["rev-1", "You are Accountant.", "Reports to CEO.", "gmail,drive"]))
        #expect(base != BotPersonaRefresh.fingerprint(["rev-2", "You are Accountant.", "Reports to CEO.", "gmail,drive"]))
        #expect(base != BotPersonaRefresh.fingerprint(["rev-1", "You are Accountant. Use Drive only.", "Reports to CEO.", "gmail,drive"]))
        #expect(base != BotPersonaRefresh.fingerprint(["rev-1", "You are Accountant.", "Reports to CEO.", "gmail"]))
        // Parts are kept apart: moving text from one part to the next is a change.
        #expect(BotPersonaRefresh.fingerprint(["ab", "c"]) != BotPersonaRefresh.fingerprint(["a", "bc"]))
    }

    @Test func aSessionWithNoRecordOrOtherInstructionsIsRefreshed() {
        #expect(BotPersonaRefresh.needsRefresh(storedFingerprint: nil, currentFingerprint: "abc"))
        #expect(BotPersonaRefresh.needsRefresh(storedFingerprint: "old", currentFingerprint: "abc"))
        #expect(!BotPersonaRefresh.needsRefresh(storedFingerprint: "abc", currentFingerprint: "abc"))
    }

    @Test func theRefreshedPromptCarriesTheInstructionsThenTheMessage() {
        let text = BotPersonaRefresh.refreshedPrompt("What's due today?", persona: "You are Accountant. Use the Drive connector.")
        #expect(text.hasPrefix("(Theo: your instructions have changed"))
        #expect(text.contains("You are Accountant. Use the Drive connector."))
        #expect(text.hasSuffix("What's due today?"))
    }
}
