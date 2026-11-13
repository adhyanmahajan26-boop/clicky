//
//  APIChatToolsTests.swift
//  leanring-buddyTests
//
//  API-key bots with tools: the request carries the tools for both API styles, rounds go back in each API's shape, and the
//  toolbox only offers and runs what the bot was given. Pure: no network, no hub, a scratch memory folder.
//

import ClickyCore
import Foundation
import Testing
@testable import Clicky

/// A stand-in hub with one app, Notion, that has a reading, a changing and an irreversible tool. Records what it was asked to run.
private final class StandInConnectorSource: APIChatConnectorSource, @unchecked Sendable {
    let levels: [String: String]
    private let lock = NSLock()
    private var recordedCalls: [(appID: String, toolName: String, argumentsJSON: String, ticket: URL)] = []
    private var revoked: [URL] = []
    let ticketURL = URL(fileURLWithPath: "/tmp/theo-test-ticket.json")

    init(levels: [String: String]) { self.levels = levels }

    var calls: [(appID: String, toolName: String, argumentsJSON: String, ticket: URL)] { lock.withLock { recordedCalls } }
    var revokedTickets: [URL] { lock.withLock { revoked } }

    func appLevels(for bot: NativeBot) async -> [String: String] { levels }

    func tools(appID: String) async throws -> [APIChatHubTool] {
        guard appID == "notion" else { throw APIChatError.rejected("\(appID) isn't connected.") }
        let schema = #"{"type":"object","properties":{"query":{"type":"string"}}}"#
        return [
            APIChatHubTool(appID: "notion", appName: "Notion", toolName: "search", exposedName: "notion__search", description: "[Notion] Search", inputSchemaJSON: schema, effect: "read"),
            APIChatHubTool(appID: "notion", appName: "Notion", toolName: "create_page", exposedName: "notion__create_page", description: "[Notion] New page", inputSchemaJSON: schema, effect: "change"),
            APIChatHubTool(appID: "notion", appName: "Notion", toolName: "delete_page", exposedName: "notion__delete_page", description: "[Notion] Delete", inputSchemaJSON: schema, effect: "irreversible")
        ]
    }

    func issueTicket(botID: String, appLevels: [String: String], ownerAsked: Bool, expiresAt: Date) async throws -> URL { ticketURL }

    func revokeTicket(_ ticket: URL) async { lock.withLock { revoked.append(ticket) } }

    func call(appID: String, toolName: String, argumentsJSON: String, ticket: URL) async throws -> (text: String, isError: Bool) {
        lock.withLock { recordedCalls.append((appID, toolName, argumentsJSON, ticket)) }
        return ("Found: Launch plan", false)
    }
}

struct APIChatToolsTests {
    private let bot = NativeBot(id: "ledger", name: "Ledger", description: "", instructions: "", hue: 0, accentHue: 0, primary: false,
                                provider: "api:anthropic", model: "m", effort: nil, apps: ["notion"], category: nil)
    private let search = APIChatToolDefinition(name: "notion__search", description: "[Notion] Search", inputSchemaJSON: #"{"type":"object","properties":{}}"#)

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apichat-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Requests

    @Test func requestsCarryTheToolsForBothAPIs() throws {
        let messages = [APIChatMessage(role: "user", text: "find the plan")]
        let anthropic = try #require(ProviderInfo.builtIn.first { $0.id == "anthropic" })
        let anthropicBody = try body(APIChat.request(provider: anthropic, key: "K", model: "m", system: "S", messages: messages, tools: [search]))
        #expect((anthropicBody["tools"] as? [[String: Any]])?.first?["name"] as? String == "notion__search")
        #expect(anthropicBody["tool_choice"] == nil)
        #expect(anthropicBody["stream"] as? Bool == true)

        let groq = try #require(ProviderInfo.builtIn.first { $0.id == "groq" })
        let openAIBody = try body(APIChat.request(provider: groq, key: "K", model: "m", system: "S", messages: messages, tools: [search]))
        let function = (openAIBody["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "notion__search")
        #expect(openAIBody["stream"] as? Bool == true)
    }

    @Test func aRequestWithoutToolsIsAsBefore() throws {
        let anthropic = try #require(ProviderInfo.builtIn.first { $0.id == "anthropic" })
        let plain = try body(APIChat.request(provider: anthropic, key: "K", model: "m", system: "S", messages: [APIChatMessage(role: "user", text: "hi")]))
        #expect(plain["tools"] == nil)
        #expect(plain["tool_choice"] == nil)
    }

    @Test func roundsGoBackAfterTheConversationAndTheLastGoSwitchesToolsOff() throws {
        let round = APIChatToolRound(assistantText: "", calls: [APIChatToolCall(callID: "c1", toolName: "notion__search", argumentsJSON: "{}")],
                                     results: [APIChatToolResult(callID: "c1", text: "Found", isError: false)])
        let messages = [APIChatMessage(role: "user", text: "find the plan")]

        let anthropic = try #require(ProviderInfo.builtIn.first { $0.id == "anthropic" })
        let anthropicBody = try body(APIChat.request(provider: anthropic, key: "K", model: "m", system: "S", messages: messages,
                                                     tools: [search], toolRounds: [round], mayCallTools: false))
        let anthropicMessages = try #require(anthropicBody["messages"] as? [[String: Any]])
        #expect(anthropicMessages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect((anthropicMessages[2]["content"] as? [[String: Any]])?.first?["type"] as? String == "tool_result")
        #expect((anthropicBody["tool_choice"] as? [String: String]) == ["type": "none"])

        let openAI = try #require(ProviderInfo.builtIn.first { $0.id == "openai" })
        let openAIBody = try body(APIChat.request(provider: openAI, key: "K", model: "m", system: "S", messages: messages,
                                                  tools: [search], toolRounds: [round], mayCallTools: false))
        let openAIMessages = try #require(openAIBody["messages"] as? [[String: Any]])
        #expect(openAIMessages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(openAIBody["tool_choice"] as? String == "none")
    }

    // MARK: What the toolbox offers and runs

    @Test func onlyToolsTheLevelAllowsAreOffered() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let drafting = await APIChatToolbox.make(for: bot, ownerAsked: true, turnLimitSeconds: 60,
                                                 connectorSource: StandInConnectorSource(levels: ["notion": "readAndDraft"]), memoryFolder: folder)
        let draftingNames = drafting.definitions.map(\.name)
        #expect(draftingNames.contains("notion__search"))
        #expect(draftingNames.contains("notion__create_page"))
        #expect(!draftingNames.contains("notion__delete_page"))
        #expect(draftingNames.contains(APIChatToolbox.memoryWriteToolName))

        let notFromOwner = await APIChatToolbox.make(for: bot, ownerAsked: false, turnLimitSeconds: 60,
                                                     connectorSource: StandInConnectorSource(levels: ["notion": "full"]), memoryFolder: folder)
        let readingNames = notFromOwner.definitions.map(\.name)
        #expect(readingNames.contains("notion__search"))
        #expect(!readingNames.contains("notion__create_page"))
        #expect(!readingNames.contains("notion__delete_page"))
    }

    @Test func aGivenAppsToolRunsWithTheTurnsTicket() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = StandInConnectorSource(levels: ["notion": "readAndDraft"])
        let toolbox = await APIChatToolbox.make(for: bot, ownerAsked: true, turnLimitSeconds: 60, connectorSource: source, memoryFolder: folder)
        let result = await toolbox.run(APIChatToolCall(callID: "c1", toolName: "notion__search", argumentsJSON: #"{"query":"plan"}"#))
        #expect(!result.isError)
        #expect(result.text == "Found: Launch plan")
        #expect(source.calls.map { $0.toolName } == ["search"])
        #expect(source.calls.first?.ticket == source.ticketURL)
        await toolbox.finish()
        #expect(source.revokedTickets == [source.ticketURL])
    }

    @Test func aBotCannotReachAnAppItWasNotGiven() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = StandInConnectorSource(levels: ["notion": "read"])
        let toolbox = await APIChatToolbox.make(for: bot, ownerAsked: true, turnLimitSeconds: 60, connectorSource: source, memoryFolder: folder)
        for name in ["gmail__send_message", "notion__delete_page", "notion__create_page", "made_up"] {
            let result = await toolbox.run(APIChatToolCall(callID: "c", toolName: name, argumentsJSON: "{}"))
            #expect(result.isError)
        }
        #expect(source.calls.isEmpty)
    }

    @Test func anAppThatCantBeReachedIsNamedInThePrompt() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let toolbox = await APIChatToolbox.make(for: bot, ownerAsked: true, turnLimitSeconds: 60,
                                                connectorSource: StandInConnectorSource(levels: ["notion": "read", "gmail": "read"]), memoryFolder: folder)
        #expect(toolbox.promptSection.contains("gmail"))
        #expect(toolbox.promptSection.contains("Notion (look things up only)"))
        #expect(!toolbox.definitions.contains { $0.name.hasPrefix("gmail__") })
    }

    @Test func withoutTheHubThereAreStillMemoryTools() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let toolbox = await APIChatToolbox.make(for: bot, ownerAsked: true, turnLimitSeconds: 60, connectorSource: nil, memoryFolder: folder)
        #expect(toolbox.definitions.map(\.name) == [APIChatToolbox.memoryListToolName, APIChatToolbox.memoryReadToolName, APIChatToolbox.memoryWriteToolName])
    }

    @Test func memoryToolsStayInTheBotsOwnFolder() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let toolbox = await APIChatToolbox.make(for: bot, ownerAsked: false, turnLimitSeconds: 60, connectorSource: nil, memoryFolder: folder)

        let write = await toolbox.run(APIChatToolCall(callID: "w", toolName: APIChatToolbox.memoryWriteToolName, argumentsJSON: #"{"path":"memory.md","content":"Owner likes short answers."}"#))
        #expect(!write.isError)
        let append = await toolbox.run(APIChatToolCall(callID: "a", toolName: APIChatToolbox.memoryWriteToolName, argumentsJSON: #"{"path":"memory.md","content":"Launch is Friday.","append":true}"#))
        #expect(!append.isError)
        let read = await toolbox.run(APIChatToolCall(callID: "r", toolName: APIChatToolbox.memoryReadToolName, argumentsJSON: #"{"path":"memory.md"}"#))
        #expect(read.text == "Owner likes short answers.\nLaunch is Friday.")
        let list = await toolbox.run(APIChatToolCall(callID: "l", toolName: APIChatToolbox.memoryListToolName, argumentsJSON: ""))
        #expect(list.text.hasPrefix("memory.md"))

        let escape = await toolbox.run(APIChatToolCall(callID: "e", toolName: APIChatToolbox.memoryWriteToolName, argumentsJSON: #"{"path":"../other/memory.md","content":"x"}"#))
        #expect(escape.isError)
        let absolute = await toolbox.run(APIChatToolCall(callID: "e2", toolName: APIChatToolbox.memoryReadToolName, argumentsJSON: #"{"path":"/etc/hosts"}"#))
        #expect(absolute.isError)
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("other/memory.md").path))
    }
}
