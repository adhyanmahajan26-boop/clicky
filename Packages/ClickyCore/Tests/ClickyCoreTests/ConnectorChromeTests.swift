import Foundation
import Testing
@testable import ClickyCore

struct ConnectorChromeTests {
    @Test func chromeIsThereWhenClaudeCodeHasIt() {
        #expect(ConnectorListing.claudeHasChrome(claudeJSON: nil, nativeHostInstalled: true))
        #expect(ConnectorListing.claudeHasChrome(claudeJSON: Data(#"{"claudeInChromeDefaultEnabled": true}"#.utf8), nativeHostInstalled: false))
        #expect(!ConnectorListing.claudeHasChrome(claudeJSON: Data(#"{"claudeInChromeDefaultEnabled": false}"#.utf8), nativeHostInstalled: false))
        #expect(!ConnectorListing.claudeHasChrome(claudeJSON: Data("not json".utf8), nativeHostInstalled: false))
        #expect(!ConnectorListing.claudeHasChrome(claudeJSON: nil, nativeHostInstalled: false))
    }

    @Test func theRealListingNeverNamesChromeSoItIsAdded() {
        let listing = """
        Checking MCP server health…

        claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ✔ Connected
        plugin:hostinger:hostinger: https://mcp.hostinger.com (HTTP) - ! Needs authentication
        """
        let parsed = ConnectorListing.parseClaude(listing)
        #expect(parsed["claude-in-chrome"] == nil)
        #expect(ConnectorListing.addingBuiltInChrome(parsed, claudeHasChrome: true)["claude-in-chrome"] == .connected)
        #expect(ConnectorListing.addingBuiltInChrome(parsed, claudeHasChrome: false)["claude-in-chrome"] == nil)
        // A listing that does name it (an older Claude Code) is kept as it said.
        let failed = ConnectorListing.addingBuiltInChrome(["claude-in-chrome": .needsSignIn], claudeHasChrome: true)
        #expect(failed["claude-in-chrome"] == .needsSignIn)
    }

    @Test func serverNamesReadLikeNames() {
        #expect(ConnectorListing.displayName("claude.ai Runway (runway.team)") == "Runway (runway.team)")
        #expect(ConnectorListing.displayName("plugin:hostinger:hostinger") == "Hostinger (plugin)")
        #expect(ConnectorListing.displayName("plugin:theo:notes") == "Notes (theo plugin)")
        #expect(ConnectorListing.displayName("ultron-director") == "ultron-director")
        #expect(ConnectorListing.displayName("plugin::x") == "plugin::x")
    }
}
