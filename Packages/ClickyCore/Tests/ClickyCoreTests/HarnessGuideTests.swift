import Foundation
import Testing
@testable import ClickyCore

struct HarnessGuideTests {
    @Test func theGuideCoversEveryWayABotActs() {
        let guide = HarnessGuide.markdown()
        for needed in ["[TELL:", "@Name", "```prompt", "```routine", "[CHOOSE:", "[SCREEN:", "[RESEARCH:", "Continue:", "```followup", "Where you are", "ToolSearch"] {
            #expect(guide.contains(needed), "The guide doesn't mention \(needed)")
        }
        // The one contradiction that confused the bots before: @Name only works in groups.
        #expect(!guide.contains("@Name reaches"))
        #expect(!guide.contains("  "))
    }

    /// docs/BOT-HARNESS-GUIDE.md is the guide as the code makes it. UPDATE_HARNESS_GUIDE=1 rewrites it.
    @Test func theGuideInTheRepoMatchesTheCode() throws {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/BOT-HARNESS-GUIDE.md")
        let generated = HarnessGuide.markdown()
        if ProcessInfo.processInfo.environment["UPDATE_HARNESS_GUIDE"] == "1" {
            try generated.write(to: docs, atomically: true, encoding: .utf8)
        }
        let committed = try String(contentsOf: docs, encoding: .utf8)
        #expect(committed == generated, "docs/BOT-HARNESS-GUIDE.md is out of date: run UPDATE_HARNESS_GUIDE=1 swift test --filter HarnessGuide")
    }
}
