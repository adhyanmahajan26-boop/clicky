import Foundation
import Testing
@testable import ClickyCore

struct ModelEffortTests {
    @Test func claudeOffersEveryLevelExceptOnHaiku() {
        #expect(ModelEffort.levels(engine: "claude", model: "claude-sonnet-5-5", engineListed: []) == ModelEffort.claudeLevels)
        #expect(ModelEffort.levels(engine: "claude", model: "claude-opus-5-5", engineListed: []).contains("max"))
        #expect(ModelEffort.levels(engine: "claude", model: "claude-haiku-5-5", engineListed: ["low"]).isEmpty)
    }

    @Test func codexUsesItsOwnListAndKeysAndSomeAgentsHaveNone() {
        #expect(ModelEffort.levels(engine: "codex", model: "gpt-5.5", engineListed: ["low", "high"]) == ["low", "high"])
        #expect(ModelEffort.levels(engine: "api:openai", model: "gpt-5.5", engineListed: ["low"]).isEmpty)
        #expect(ModelEffort.levels(engine: "cursor", model: "auto", engineListed: ["low"]).isEmpty)
        #expect(ModelEffort.levels(engine: "gemini", model: "", engineListed: []).isEmpty)
        #expect(ModelEffort.levels(engine: "grok", model: "grok-4.7", engineListed: []) == ["low", "medium", "high"])
    }

    @Test func anEffortTheNewModelLacksFallsBackToAuto() {
        #expect(ModelEffort.carriedOver(effort: "high", toLevels: ModelEffort.claudeLevels) == "high")
        #expect(ModelEffort.carriedOver(effort: "max", toLevels: ["low", "medium", "high"]) == nil)
        #expect(ModelEffort.carriedOver(effort: "high", toLevels: []) == nil)
        #expect(ModelEffort.carriedOver(effort: "", toLevels: ["high"]) == nil)
    }

    @Test func theChipNamesTheModelAndItsEffort() {
        #expect(ModelEffort.chipLabel(modelLabel: "Claude Sonnet 5.5", effort: "high", levels: ModelEffort.claudeLevels) == "Sonnet 5.5 · High")
        #expect(ModelEffort.chipLabel(modelLabel: "Claude Opus 5.5", effort: "xhigh", levels: ModelEffort.claudeLevels) == "Opus 5.5 · X-high")
        #expect(ModelEffort.chipLabel(modelLabel: "Claude Haiku 5.5", effort: "high", levels: []) == "Haiku 5.5")
        #expect(ModelEffort.chipLabel(modelLabel: "Claude Sonnet 5.5", effort: nil, levels: ModelEffort.claudeLevels) == "Sonnet 5.5")
        #expect(ModelEffort.chipLabel(modelLabel: "", effort: nil, levels: []) == "Default model")
    }

    @Test func everyLevelHasWordsAndAHint() {
        for level in ModelEffort.claudeLevels + ModelEffort.openCodeLevels {
            #expect(!ModelEffort.title(for: level).isEmpty)
            #expect(ModelEffort.hint(for: level) != ModelEffort.hint(for: "unknown-level"))
        }
        #expect(ModelEffort.title(for: "") == "Auto")
        #expect(ModelEffort.title(for: "xhigh") == "Extra high")
    }

    @Test func modelHintsDescribeTheClaudeFamily() {
        #expect(ModelEffort.modelHint(engine: "claude", model: "claude-opus-5-5") == "Most capable, slower")
        #expect(ModelEffort.modelHint(engine: "claude", model: "claude-haiku-5-5")?.contains("Fastest") == true)
        #expect(ModelEffort.modelHint(engine: "opencode", model: "opencode/deepseek-v4.1-flash-free") == "Free")
        #expect(ModelEffort.modelHint(engine: "codex", model: "gpt-5.5") == nil)
    }

    @Test func sourceStatesReadLikeTheHarnessesPage() {
        #expect(BrainSourceState.of(checked: false, installed: true, loggedIn: true, account: nil, usesAPIKey: false) == .checking)
        #expect(BrainSourceState.of(checked: true, installed: false, loggedIn: nil, account: nil, usesAPIKey: false) == .notInstalled)
        #expect(BrainSourceState.of(checked: true, installed: true, loggedIn: false, account: nil, usesAPIKey: true) == .onAPIKey)
        #expect(BrainSourceState.of(checked: true, installed: true, loggedIn: false, account: nil, usesAPIKey: false) == .signedOut)
        #expect(BrainSourceState.of(checked: true, installed: true, loggedIn: true, account: "me · max plan", usesAPIKey: false) == .signedIn(account: "me · max plan"))
        #expect(BrainSourceState.of(checked: true, installed: true, loggedIn: nil, account: nil, usesAPIKey: false) == .ready)
        #expect(BrainSourceState.signedOut.isUsable == false)
        #expect(BrainSourceState.signedIn(account: nil).caption == "Signed in")
    }
}
