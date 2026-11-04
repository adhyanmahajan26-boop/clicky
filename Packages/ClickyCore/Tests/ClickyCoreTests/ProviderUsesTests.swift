import Foundation
import Testing
@testable import ClickyCore

struct ProviderUsesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "provider-uses-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func everythingIsOnByDefault() {
        let defaults = freshDefaults()
        for use in ProviderUse.allCases { #expect(ProviderUses.allows(use, providerID: "lmstudio", defaults: defaults)) }
    }

    @Test func turningOneOffLeavesTheOthersAndOtherProviders() {
        let defaults = freshDefaults()
        ProviderUses.set(false, use: .clicky, providerID: "lmstudio", defaults: defaults)
        #expect(!ProviderUses.allows(.clicky, providerID: "lmstudio", defaults: defaults))
        #expect(ProviderUses.allows(.bots, providerID: "lmstudio", defaults: defaults))
        #expect(ProviderUses.allows(.theo, providerID: "lmstudio", defaults: defaults))
        #expect(ProviderUses.allows(.clicky, providerID: "openai", defaults: defaults))
    }

    @Test func turningBackOnAndForgettingRestoreTheDefault() {
        let defaults = freshDefaults()
        ProviderUses.set(false, use: .bots, providerID: "groq", defaults: defaults)
        ProviderUses.set(true, use: .bots, providerID: "groq", defaults: defaults)
        #expect(ProviderUses.allows(.bots, providerID: "groq", defaults: defaults))
        ProviderUses.set(false, use: .theo, providerID: "groq", defaults: defaults)
        ProviderUses.forget(providerID: "groq", defaults: defaults)
        #expect(ProviderUses.allows(.theo, providerID: "groq", defaults: defaults))
    }

    @Test func aSentPromptNamesTheRunsOwnHarnessNotTheDefault() {
        // The bug: a run through Claude Code read "Sent to T3 Code" because the default target was T3 Code.
        #expect(SentEngine.resolve(hasMatchingRun: true, runHarness: "claude", chosen: "t3") == "claude")
        #expect(SentEngine.resolve(hasMatchingRun: true, runHarness: nil, chosen: "claude") == "t3")
        #expect(SentEngine.resolve(hasMatchingRun: false, runHarness: nil, chosen: "codex") == "codex")
    }
}
