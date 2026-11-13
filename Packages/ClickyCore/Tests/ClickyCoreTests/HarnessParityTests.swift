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

    func testRecallNamesOtherConversations() {
        let plain = BotRecallPrompt.section(chatFile: "/c/pip.json", owner: "Addy")
        XCTAssertTrue(plain.contains("/c/pip.json"))
        let more = BotRecallPrompt.section(chatFile: "/c/pip.json", owner: "Addy", others: (0..<14).map { ("thread \($0)", "/c/dm-\($0).json") })
        XCTAssertTrue(more.contains("thread 0 in /c/dm-0.json"))
        XCTAssertFalse(more.contains("/c/dm-12.json"))
        XCTAssertTrue(more.contains("2 more"))
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

final class HarnessParityRoundTwoTests: XCTestCase {
    func testUsageFromClaudeAndOpenCode() {
        let claude: [String: Any] = ["type": "result", "total_cost_usd": 0.0123,
                                     "usage": ["input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 300, "cache_creation_input_tokens": 40]]
        XCTAssertEqual(BotTurnUsage.fromClaudeResult(claude), BotTurnUsage(inputTokens: 10, outputTokens: 20, cacheReadTokens: 300, cacheWriteTokens: 40, costUSD: 0.0123))
        XCTAssertNil(BotTurnUsage.fromClaudeResult(["type": "result"]))
        let step: [String: Any] = ["type": "step_finish", "part": ["cost": 0.5, "tokens": ["input": 1, "output": 2, "reasoning": 3, "cache": ["read": 4, "write": 5]]]]
        XCTAssertEqual(BotTurnUsage.fromOpenCodeStep(step), BotTurnUsage(inputTokens: 1, outputTokens: 5, cacheReadTokens: 4, cacheWriteTokens: 5, costUSD: 0.5))
        XCTAssertEqual((BotTurnUsage(outputTokens: 1) + BotTurnUsage(outputTokens: 2, costUSD: 1)).costUSD, 1)
        XCTAssertNil((BotTurnUsage(outputTokens: 1) + BotTurnUsage(outputTokens: 2)).costUSD)
    }

    func testLedgerTotalsByDayAndWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = BotUsageLedger()
        ledger.record(botID: "pip", usage: BotTurnUsage(outputTokens: 100, costUSD: 0.10), at: now, calendar: calendar)
        ledger.record(botID: "pip", usage: BotTurnUsage(outputTokens: 50), at: now, calendar: calendar)
        ledger.record(botID: "pip", usage: BotTurnUsage(outputTokens: 1000, costUSD: 1), at: now.addingTimeInterval(-10 * 86_400), calendar: calendar)
        let week = ledger.total(botID: "pip", days: 7, now: now, calendar: calendar)
        XCTAssertEqual(week.turns, 2)
        XCTAssertEqual(week.usage.outputTokens, 150)
        XCTAssertEqual(week.usage.costUSD, 0.10)
        XCTAssertEqual(week.turnsWithoutCost, 1)
        XCTAssertEqual(ledger.total(botID: "pip", days: 30, now: now, calendar: calendar).turns, 3)
        XCTAssertEqual(BotUsageLedger.line(week, period: "this week"), "2 turns, 150 tokens, $0.10 this week (1 without a cost from the engine).")
        XCTAssertEqual(BotUsageLedger.line(.init(), period: "this week"), "No turns this week.")
        ledger.record(botID: "pip", usage: BotTurnUsage(), at: now.addingTimeInterval(500 * 86_400), calendar: calendar)
        XCTAssertEqual(ledger.days["pip"]?.count, 1)
    }

    func testHookFilesMustBeOwnedExecutableAndNotWritableByOthers() {
        XCTAssertTrue(TheoHookFiles.runs(name: "notify.sh", isRegularFile: true, permissions: 0o700, ownerID: 501, userID: 501))
        XCTAssertTrue(TheoHookFiles.runs(name: "notify", isRegularFile: true, permissions: 0o755, ownerID: 501, userID: 501))
        XCTAssertFalse(TheoHookFiles.runs(name: "notify.sh", isRegularFile: true, permissions: 0o600, ownerID: 501, userID: 501))
        XCTAssertFalse(TheoHookFiles.runs(name: "notify.sh", isRegularFile: true, permissions: 0o777, ownerID: 501, userID: 501))
        XCTAssertFalse(TheoHookFiles.runs(name: "notify.sh", isRegularFile: true, permissions: 0o720, ownerID: 501, userID: 501))
        XCTAssertFalse(TheoHookFiles.runs(name: "notify.sh", isRegularFile: true, permissions: 0o700, ownerID: 0, userID: 501))
        XCTAssertFalse(TheoHookFiles.runs(name: ".hidden", isRegularFile: true, permissions: 0o700, ownerID: 501, userID: 501))
        XCTAssertFalse(TheoHookFiles.runs(name: "link", isRegularFile: false, permissions: 0o700, ownerID: 501, userID: 501))
        let payload = TheoHookFiles.payload(event: .turnFinished, at: Date(timeIntervalSince1970: 0), fields: ["reply": String(repeating: "x", count: 5000), "ok": true])
        let object = try! JSONSerialization.jsonObject(with: payload) as! [String: Any]
        XCTAssertEqual(object["event"] as? String, "turn-finished")
        XCTAssertEqual((object["reply"] as? String)?.count, 4000)
        XCTAssertEqual(object["ok"] as? Bool, true)
    }

    func testDoctorMarkdownPutsProblemsFirst() {
        let text = TheoDoctor.markdown([.init(.ok, "Disk", "500 GB free."), .init(.fail, "Claude Code", "Not signed in."), .init(.warn, "Skills", "One has no description.")])
        XCTAssertTrue(text.hasPrefix("Theo's health check: 1 problem and 1 warning out of 3 checks."))
        XCTAssertLessThan(text.range(of: "Claude Code")!.lowerBound, text.range(of: "Skills")!.lowerBound)
        XCTAssertLessThan(text.range(of: "Skills")!.lowerBound, text.range(of: "Disk")!.lowerBound)
        XCTAssertEqual(TheoDoctor.markdown([.init(.ok, "Disk", "fine")]).components(separatedBy: "\n").first, "Theo's health check: all 1 checks pass.")
        XCTAssertTrue(TheoDoctor.asksForDoctor(" /doctor "))
        XCTAssertFalse(TheoDoctor.asksForDoctor("doctor who?"))
    }

    func testGatewayHasUsageAndDoctorRoutes() {
        XCTAssertEqual(TheoGatewayHTTP.route(method: "GET", path: "/v1/usage"), .usage)
        XCTAssertEqual(TheoGatewayHTTP.route(method: "GET", path: "/v1/doctor"), .doctor)
        XCTAssertEqual(TheoGatewayHTTP.route(method: "POST", path: "/v1/doctor"), .methodNotAllowed)
    }
}
