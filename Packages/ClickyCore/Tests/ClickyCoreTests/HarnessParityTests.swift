import XCTest
@testable import ClickyCore

final class HarnessParityTests: XCTestCase {
    // MARK: Failover

    func testClassifiesEngineErrors() {
        XCTAssertEqual(EngineFailure.classify("API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"), .transient)
        XCTAssertEqual(EngineFailure.classify("API Error: 429 rate_limit_error: This request would exceed the rate limit"), .transient)
        XCTAssertEqual(EngineFailure.classify("API Error: 500 Internal server error"), .transient)
        XCTAssertEqual(EngineFailure.classify("Claude reported an error: fetch failed"), .transient)
        XCTAssertEqual(EngineFailure.classify("Invalid API key · Please run /login"), .auth)
        XCTAssertEqual(EngineFailure.classify("API Error: 401 authentication_error"), .auth)
        XCTAssertEqual(EngineFailure.classify("Credit balance is too low"), .auth)
        XCTAssertEqual(EngineFailure.classify("There's an issue with the selected model (claude-foo). It may not exist or you may not have access to it."), .modelUnavailable)
        XCTAssertEqual(EngineFailure.classify("API Error: 404 not_found_error: model: claude-3-opus"), .modelUnavailable)
        XCTAssertEqual(EngineFailure.classify("No conversation found with session ID: abc"), .other)
        XCTAssertEqual(EngineFailure.classify("Claude Code stopped (exit 3)."), .other)
    }

    func testChainSkipsOwnModelAndRepeats() {
        XCTAssertEqual(EngineFailoverPlan.chain(for: "claude-haiku-5-5", configured: nil), ["claude-sonnet-5-5", "claude-opus-5-5"])
        XCTAssertEqual(EngineFailoverPlan.chain(for: "claude-sonnet-5-5", configured: ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-haiku-5-5", " "]), ["claude-haiku-5-5"])
        XCTAssertEqual(EngineFailoverPlan.chain(for: "x", configured: []), EngineFailoverPlan.defaultClaudeChain)
    }

    func testSameModelRetriesThenChainThenStop() {
        let plan = EngineFailoverPlan(retryDelays: [3, 10], fallbacks: ["b", "c"])
        XCTAssertEqual(plan.next(after: .transient, model: "a", attempt: 0, fallbackIndex: nil), .init(model: "a", delay: 3, isFallback: false))
        XCTAssertEqual(plan.next(after: .transient, model: "a", attempt: 1, fallbackIndex: nil), .init(model: "a", delay: 10, isFallback: false))
        XCTAssertEqual(plan.next(after: .transient, model: "a", attempt: 2, fallbackIndex: nil), .init(model: "b", delay: 1, isFallback: true))
        XCTAssertEqual(plan.next(after: .transient, model: "b", attempt: 3, fallbackIndex: 0), .init(model: "c", delay: 1, isFallback: true))
        XCTAssertNil(plan.next(after: .transient, model: "c", attempt: 4, fallbackIndex: 1))
    }

    func testMissingModelGoesStraightToChainAndAuthNeverRetries() {
        let plan = EngineFailoverPlan(fallbacks: ["b"])
        XCTAssertEqual(plan.next(after: .modelUnavailable, model: "a", attempt: 0, fallbackIndex: nil), .init(model: "b", delay: 0, isFallback: true))
        XCTAssertNil(plan.next(after: .auth, model: "a", attempt: 0, fallbackIndex: nil))
        XCTAssertNil(plan.next(after: .other, model: "a", attempt: 0, fallbackIndex: nil))
        XCTAssertNil(EngineFailoverPlan(retryDelays: [], fallbacks: []).next(after: .transient, model: "a", attempt: 0, fallbackIndex: nil))
    }

    // MARK: Skills

    func testParsesSkillFrontMatter() {
        let text = "---\nname: theo-release\ndescription: \"How to cut a Theo release safely\"\n---\n# Steps\n1. Test\n"
        let skill = BotSkill.parse(text, path: "/x/SKILL.md", author: "Pip", folderName: "theo-release")
        XCTAssertEqual(skill, BotSkill(name: "theo-release", description: "How to cut a Theo release safely", path: "/x/SKILL.md", author: "Pip"))
        XCTAssertEqual(BotSkill.parse("---\ndescription: d\n---\n", path: "p", author: nil, folderName: "folder")?.name, "folder")
        XCTAssertNil(BotSkill.parse("# no front matter\n", path: "p", author: nil, folderName: "f"))
        XCTAssertNil(BotSkill.parse("---\nname: x\n---\n", path: "p", author: nil, folderName: "f"))
    }

    func testSkillsSectionListsAndCaps() {
        let skills = (0..<45).map { BotSkill(name: "s\($0)", description: "d\($0)", path: "/p\($0)", author: $0 == 0 ? nil : "Pip") }
        let text = BotSkillsPrompt.section(skills: skills, ownFolder: "/own/skills", sharedFolder: "/shared/skills", botName: "Pip", owner: "Addy")
        XCTAssertTrue(text.contains("- s0: d0 [/p0]"))
        XCTAssertTrue(text.contains("(yours)"))
        XCTAssertTrue(text.contains("and 5 more"))
        XCTAssertTrue(text.contains("/own/skills/<short-name>/SKILL.md"))
        XCTAssertTrue(BotSkillsPrompt.section(skills: [], ownFolder: "/o", sharedFolder: "/s", botName: "P", owner: "Addy").contains("none yet"))
    }

    // MARK: Memory

    func testMemoryGoesInWithItsSize() {
        let text = BotMemoryPrompt.section("- dog: Biscuit\n", path: "/m.md", limit: 100)
        XCTAssertTrue(text.contains("- dog: Biscuit"))
        XCTAssertTrue(text.contains("14/100 characters"))
        XCTAssertTrue(BotMemoryPrompt.section("  \n", path: "/m.md").contains("empty so far"))
    }

    func testOversizedMemoryKeepsStartAndNewestAndAsksForTidy() {
        let memory = "- first fact\n" + (0..<500).map { "- filler \($0)" }.joined(separator: "\n") + "\n- newest fact"
        let text = BotMemoryPrompt.section(memory, path: "/m.md", limit: 600)
        XCTAssertTrue(text.contains("- first fact"))
        XCTAssertTrue(text.contains("- newest fact"))
        XCTAssertTrue(text.contains("characters not shown"))
        XCTAssertTrue(text.contains("rewrite that file under 600"))
        XCTAssertLessThan(text.count, 1_100)
    }

    // MARK: Routines

    func testQuietMarker() {
        XCTAssertTrue(RoutineQuiet.isQuiet("[SILENT]"))
        XCTAssertTrue(RoutineQuiet.isQuiet("  `[SILENT]`\n"))
        XCTAssertTrue(RoutineQuiet.isQuiet("NO_REPLY"))
        XCTAssertFalse(RoutineQuiet.isQuiet("Nothing changed. [SILENT]"))
        XCTAssertFalse(RoutineQuiet.isQuiet(nil))
        XCTAssertFalse(RoutineQuiet.isQuiet("The build is red."))
    }

    func testCatchUpWindow() {
        XCTAssertEqual(RoutineCatchUp.window(periodSeconds: 86_400), 7_200)
        XCTAssertEqual(RoutineCatchUp.window(periodSeconds: 3_600), 1_800)
        XCTAssertEqual(RoutineCatchUp.window(periodSeconds: 60), 120)
        let due = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RoutineCatchUp.decide(due: due, now: due.addingTimeInterval(-1), periodSeconds: 86_400), .notYet)
        XCTAssertEqual(RoutineCatchUp.decide(due: due, now: due.addingTimeInterval(60), periodSeconds: 86_400), .fire)
        XCTAssertEqual(RoutineCatchUp.decide(due: due, now: due.addingTimeInterval(3 * 86_400), periodSeconds: 86_400), .missed)
        XCTAssertEqual(RoutineCatchUp.decide(due: due, now: due.addingTimeInterval(1_799), periodSeconds: 3_600), .fire)
        XCTAssertEqual(RoutineCatchUp.decide(due: due, now: due.addingTimeInterval(1_801), periodSeconds: 3_600), .missed)
    }
}
