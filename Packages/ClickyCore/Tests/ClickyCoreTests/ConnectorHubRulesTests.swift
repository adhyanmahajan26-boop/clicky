import Foundation
import Testing
@testable import ClickyCore

struct ConnectorHubRulesTests {
    private func gmail() -> HubAppRecord {
        HubAppRecord(id: "gmail", name: "Gmail", kind: .claudeAccount, status: "connected", server: "claude.ai Gmail",
                     readTools: ["search_threads", "get_thread"],
                     writeTools: ["create_draft", "send_message", "reply", "trash_thread", "label_message", "mark_message_spam", "update_draft"])
    }

    private func files() -> HubAppRecord {
        HubAppRecord(id: "files", name: "My files", kind: .local, status: "connected", command: "npx")
    }

    // MARK: Reading the hub

    @Test func aListAnswerBecomesApps() throws {
        let text = #"{"ok":true,"apps":[{"id":"gmail","name":"Gmail","kind":"claude-account","server":"claude.ai Gmail","readTools":["search_threads"],"writeTools":["create_draft"],"catalogId":"gmail","status":"connected","lastWorked":"2026-11-13T21:40:33Z","lastChecked":"2026-11-13T21:41:00Z","toolCount":3,"signedIn":false},{"id":"linear","name":"Linear","kind":"remote","url":"https://mcp.linear.app/mcp","auth":"oauth","status":"needsSignIn","lastWorked":null,"lastChecked":null,"signedIn":false},{"id":"notes","name":"Notes","kind":"local","command":"npx","enabled":false,"status":"off","lastWorked":null,"lastChecked":null,"signedIn":false},{"id":"odd","name":"Odd","kind":"carrier-pigeon"}]}"#
        let answer = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let apps = try #require(HubAppRecord.list(fromHubAnswer: answer))
        #expect(apps.map(\.id) == ["gmail", "linear", "notes"])
        #expect(apps[0].isConnected && apps[0].isClaudeAccount)
        #expect(apps[0].server == "claude.ai Gmail" && apps[0].catalogID == "gmail" && apps[0].toolCount == 3)
        #expect(apps[0].lastWorked == HubDates.parse("2026-11-13T21:40:33Z"))
        #expect(apps[0].lastWorked != nil)
        #expect(apps[1].needsSignIn && apps[1].signsInWithBrowser && apps[1].lastWorked == nil)
        #expect(!apps[2].enabled && apps[2].status == "off" && !apps[2].isConnected)
        #expect(apps[0].connectorState == .connected)
        #expect(apps[1].connectorState == .needsSignIn)
        #expect(apps[2].connectorState == .missing)
        var failing = apps[1]
        failing.status = "failed"
        failing.reason = "HTTP 500"
        #expect(failing.connectorState == .failed("HTTP 500"))
    }

    @Test func aFailureAnswerIsNotAList() {
        #expect(HubAppRecord.list(fromHubAnswer: ["ok": false, "error": "Say where Theo's data folder is"]) == nil)
    }

    // MARK: Levels

    @Test func aTurnNotFromTheOwnerOnlyReads() {
        #expect(HubAccessLevel.full.effective(ownerAsked: false) == .read)
        #expect(HubAccessLevel.full.effective(ownerAsked: true) == .full)
        #expect(HubAccessLevel(saved: nil) == .readAndDraft)
        #expect(HubAccessLevel(saved: "nonsense") == .readAndDraft)
        #expect(HubAccessLevel(saved: "read") == .read)
    }

    @Test func toolEffectsMatchTheHubAndTheOldRules() {
        // The old rule (BotRunner.irreversibleTools): send, reply, forward, trash, delete, spam, share, cancel and clear never ran.
        for name in ["send_message", "reply", "forward", "trash_thread", "delete_draft", "mark_thread_spam", "share_file",
                     "notion-calendar-cancel-events", "batch_clear_values", "notion-delete-pages", "sendEmail"] {
            #expect(HubToolEffect.of(toolName: name, listedAsWriting: true) == .irreversible, "\(name)")
        }
        for name in ["create_draft", "update_draft", "label_message", "notion-create-pages", "update_values", "copy_file"] {
            #expect(HubToolEffect.of(toolName: name, listedAsWriting: true) == .change, "\(name)")
        }
        #expect(HubToolEffect.of(toolName: "search_threads", listedAsWriting: false) == .read)
        #expect(HubToolEffect.words(inToolName: "getFileMetadata") == ["get", "file", "metadata"])
        #expect(HubToolEffect.words(inToolName: "notion-calendar-list-events") == ["notion", "calendar", "list", "events"])
    }

    // MARK: One turn

    @Test func aClaudeBotKeepsItsDirectRouteAndOthersUseTheHub() {
        let hubApps = [gmail(), files()]
        let claude = ConnectorHubTurnPlan.make(botApps: ["gmail", "files", "theo", "chrome"], savedLevels: [:], hubApps: hubApps,
                                               engine: "claude", ownerAsked: true)
        #expect(claude.directClaudeApps.map(\.app.id) == ["gmail"])
        #expect(claude.ticketApps == ["files": .readAndDraft])

        for engine in ["codex", "cursor", "gemini", "opencode", "grok", "api:anthropic"] {
            let plan = ConnectorHubTurnPlan.make(botApps: ["gmail", "files", "theo"], savedLevels: ["files": "full"], hubApps: hubApps,
                                                 engine: engine, ownerAsked: true)
            #expect(plan.directClaudeApps.isEmpty, "\(engine)")
            #expect(plan.ticketApps == ["gmail": .readAndDraft, "files": .full], "\(engine)")
        }
    }

    @Test func onlyTheBotsOwnEnabledAppsAreInTheTicket() {
        var off = files()
        off.enabled = false
        let plan = ConnectorHubTurnPlan.make(botApps: ["files"], savedLevels: [:], hubApps: [gmail(), off], engine: "codex", ownerAsked: true)
        #expect(!plan.usesHub)
        let other = ConnectorHubTurnPlan.make(botApps: ["notion"], savedLevels: [:], hubApps: [gmail(), files()], engine: "codex", ownerAsked: true)
        #expect(!other.usesHub)
    }

    @Test func aRoutineTurnGetsReadOnlyTickets() {
        let plan = ConnectorHubTurnPlan.make(botApps: ["files", "gmail"], savedLevels: ["files": "full"], hubApps: [gmail(), files()],
                                             engine: "claude", ownerAsked: false)
        #expect(plan.ticketApps == ["files": .read])
        #expect(plan.directClaudeApps.first?.level == .read)
    }

    @Test func claudeDirectRouteDeniesWhatTheLevelDoesNot() {
        #expect(ClaudeDirectRoute.toolPrefix(forServer: "claude.ai Gmail") == "mcp__claude_ai_Gmail")
        #expect(ClaudeDirectRoute.toolPrefix(forServer: "claude.ai Google Drive") == "mcp__claude_ai_Google_Drive")
        #expect(ClaudeDirectRoute.toolPrefix(forServer: "content-studio") == "mcp__content-studio")
        #expect(ClaudeDirectRoute.toolPrefix(forServer: "claude.ai Hostinger Connector") == "mcp__claude_ai_Hostinger_Connector")

        let read = Set(ClaudeDirectRoute.deniedTools(for: gmail(), level: .read))
        #expect(read.contains("mcp__claude_ai_Gmail__create_draft") && read.contains("mcp__claude_ai_Gmail__send_message"))
        let draft = Set(ClaudeDirectRoute.deniedTools(for: gmail(), level: .readAndDraft))
        #expect(!draft.contains("mcp__claude_ai_Gmail__create_draft"))
        #expect(draft.isSuperset(of: ["mcp__claude_ai_Gmail__send_message", "mcp__claude_ai_Gmail__reply", "mcp__claude_ai_Gmail__trash_thread",
                                      "mcp__claude_ai_Gmail__mark_message_spam"]))
        #expect(ClaudeDirectRoute.deniedTools(for: gmail(), level: .full).isEmpty)
    }

    // MARK: Tickets

    @Test func aTicketHasTheHubsShape() throws {
        let expires = Date(timeIntervalSince1970: 1_794_000_000)
        let data = ConnectorHubTicket.json(botID: "ledger", apps: ["gmail": .readAndDraft, "files": .read], ownerAsked: true, expiresAt: expires)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["botId"] as? String == "ledger")
        #expect(object["apps"] as? [String: String] == ["gmail": "readAndDraft", "files": "read"])
        #expect(object["ownerAsked"] as? Bool == true)
        #expect(HubDates.parse(object["expiresAt"] as? String) == expires)
        #expect(ConnectorHubTicket.fileName(botID: "clicky/memory bot", unique: "ab12") == "clicky_memory_bot-ab12.json")
    }

    // MARK: Wiring

    private let launch = HubServerLaunch(command: "/Applications/Theo.app/Contents/Helpers/theo-connectors",
                                         arguments: ["--data", "/Users/a/Library/Application Support/Theo", "serve", "--ticket", "/t/x \"y\".json"],
                                         environment: ["THEO_CONNECTORS_CLAUDE": "/Users/a/.local/bin/claude"])

    @Test func claudeGetsAnMCPConfigOfItsOwn() throws {
        let config = ConnectorHubWiring.claudeMCPConfig(launch)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let server = try #require((object["mcpServers"] as? [String: Any])?["theo_apps"] as? [String: Any])
        #expect(server["command"] as? String == launch.command)
        #expect(server["args"] as? [String] == launch.arguments)
        #expect(ConnectorHubWiring.claudeAllowRule == "mcp__theo_apps")
    }

    @Test func codexOverridesAreValidTOML() {
        let arguments = ConnectorHubWiring.codexArguments(launch)
        #expect(arguments.count == 8)
        #expect(arguments.enumerated().allSatisfy { $0.offset % 2 == 1 || $0.element == "-c" })
        #expect(arguments[1] == "mcp_servers.theo_apps.command=\"/Applications/Theo.app/Contents/Helpers/theo-connectors\"")
        #expect(arguments[3] == #"mcp_servers.theo_apps.args=["--data","/Users/a/Library/Application Support/Theo","serve","--ticket","/t/x \"y\".json"]"#)
        #expect(arguments[5] == "mcp_servers.theo_apps.default_tools_approval_mode=\"approve\"")
        #expect(arguments[7] == #"mcp_servers.theo_apps.env={THEO_CONNECTORS_CLAUDE="/Users/a/.local/bin/claude"}"#)
        #expect(ConnectorHubWiring.tomlString("a\\b\n") == #""a\\b\n""#)
    }

    @Test func openCodeGetsALocalServerForTheRun() throws {
        let content = ConnectorHubWiring.openCodeConfigContent(launch)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let server = try #require((object["mcp"] as? [String: Any])?["theo_apps"] as? [String: Any])
        #expect(server["type"] as? String == "local")
        #expect(server["command"] as? [String] == [launch.command] + launch.arguments)
        #expect(server["environment"] as? [String: String] == launch.environment)
    }

    @Test func geminiAndCursorGetTheServerByName() throws {
        for text in [ConnectorHubWiring.geminiSettings(launch), ConnectorHubWiring.cursorMCPFile(launch)] {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let server = try #require((object["mcpServers"] as? [String: Any])?["theo_apps"] as? [String: Any])
            #expect(server["command"] as? String == launch.command)
        }
        #expect(ConnectorHubWiring.geminiSettings(launch).contains("\"trust\":true"))
    }

    @Test func groksBlockNamesTheServerOnce() {
        let block = ConnectorHubWiring.grokConfigBlock(launch)
        #expect(block.contains("[mcp_servers.theo_apps]\n"))
        #expect(block.contains("command = \"/Applications/Theo.app/Contents/Helpers/theo-connectors\""))
        #expect(block.contains("[mcp_servers.theo_apps.env]\nTHEO_CONNECTORS_CLAUDE = \"/Users/a/.local/bin/claude\""))
    }

    // MARK: Migration

    @Test func botsKeepTheirAppsAfterTheMove() {
        let plan = ConnectorHubMigration.plan(botApps: ["gmail", "notion", "theo", "hyperframes"], claudeServers: [], hubIDs: [])
        #expect(plan.catalogIDs == ["gmail", "notion"])
        #expect(plan.ownApps.isEmpty)
    }

    @Test func whatClaudeCodeHasMovesTooButCalendarOnlyWhenUsed() {
        let plan = ConnectorHubMigration.plan(botApps: ["hostinger"],
                                              claudeServers: ["claude.ai Gmail", "claude.ai Notion", "content-studio", "claude.ai Runway"],
                                              hubIDs: ["gmail"])
        #expect(plan.catalogIDs == ["notion"])
        #expect(plan.ownApps.map { $0["id"] } == ["hostinger", "studio"])
        #expect(plan.ownApps.first?["server"] == "claude.ai Hostinger Connector")
        #expect(plan.ownApps.allSatisfy { $0["kind"] == "claude-account" })
        #expect(ConnectorHubMigration.plan(botApps: ["calendar"], claudeServers: [], hubIDs: []).catalogIDs == ["calendar"])
    }

    @Test func aSecondRunMovesNothing() {
        let all = Set(ConnectorHubMigration.catalogIDs + ["hostinger", "studio"])
        #expect(ConnectorHubMigration.plan(botApps: all, claudeServers: ["claude.ai Gmail"], hubIDs: all).isEmpty)
    }

    // MARK: Add your own

    @Test func newAppIDsAreSafeAndUnique() {
        #expect(ConnectorHubNewApp.id(fromName: "My Notes (work)", taken: []) == "my-notes-work")
        #expect(ConnectorHubNewApp.id(fromName: "Linear", taken: ["linear"]) == "linear-2")
        #expect(ConnectorHubNewApp.id(fromName: "!!!", taken: []) == "app")
    }

    @Test func remoteAddressesMustBeHTTPSOrThisMac() {
        #expect(ConnectorHubNewApp.remote(id: "linear", name: "Linear", address: " https://mcp.linear.app/mcp ", signIn: "oauth")?["url"] as? String == "https://mcp.linear.app/mcp")
        #expect(ConnectorHubNewApp.remote(id: "x", name: "X", address: "http://example.com/mcp", signIn: "none") == nil)
        #expect(ConnectorHubNewApp.remote(id: "x", name: "X", address: "http://127.0.0.1:8080/mcp", signIn: "none") != nil)
        #expect(ConnectorHubNewApp.remote(id: "x", name: "X", address: "not a url", signIn: "none") == nil)
    }

    @Test func aCommandLineBecomesALocalApp() {
        let entry = ConnectorHubNewApp.local(id: "files", name: "Files", commandLine: "npx -y \"@scope/server files\" ~/Notes", home: "/Users/a")
        #expect(entry?["command"] as? String == "npx")
        #expect(entry?["args"] as? [String] == ["-y", "@scope/server files", "/Users/a/Notes"])
        #expect(ConnectorHubNewApp.local(id: "x", name: "X", commandLine: "   ", home: "/Users/a") == nil)
    }
}
