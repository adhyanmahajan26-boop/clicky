import Foundation
import Testing
@testable import ClickyCore

struct APIChatToolCallingTests {
    private let notionSearch = APIChatToolDefinition(name: "notion__search", description: "[Notion] Search pages",
                                                     inputSchemaJSON: #"{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#)

    private func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    // MARK: Requests

    @Test func anthropicToolsCarryAnInputSchema() throws {
        let tools = APIChatToolWire.toolsField([notionSearch], style: .anthropic)
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "notion__search")
        let schema = try #require(tools[0]["input_schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["$schema"] == nil)
        #expect((schema["required"] as? [String]) == ["query"])
    }

    @Test func openAIToolsAreFunctions() throws {
        let tools = APIChatToolWire.toolsField([notionSearch], style: .openAI)
        #expect(tools[0]["type"] as? String == "function")
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "notion__search")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func anOddSchemaBecomesAnEmptyObjectSchema() throws {
        for oddSchema in ["", "not json", #"{"type":"string"}"#, "[1,2]"] {
            let tool = APIChatToolDefinition(name: "odd", description: "", inputSchemaJSON: oddSchema)
            let schema = try #require(APIChatToolWire.toolsField([tool], style: .anthropic)[0]["input_schema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["properties"] is [String: Any])
        }
        let noType = APIChatToolDefinition(name: "plain", description: "", inputSchemaJSON: #"{"properties":{"a":{"type":"number"}}}"#)
        let schema = try #require(APIChatToolWire.toolsField([noType], style: .openAI)[0]["function"] as? [String: Any])
        #expect((schema["parameters"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func toolChoiceNoneForEachAPI() {
        #expect((APIChatToolWire.toolChoiceNone(style: .anthropic) as? [String: String]) == ["type": "none"])
        #expect(APIChatToolWire.toolChoiceNone(style: .openAI) as? String == "none")
    }

    @Test func toolNamesBothAPIsTake() {
        #expect(APIChatToolWire.isUsableToolName("notion__search"))
        #expect(APIChatToolWire.isUsableToolName("memory_write"))
        #expect(!APIChatToolWire.isUsableToolName("notion.search"))
        #expect(!APIChatToolWire.isUsableToolName(""))
        #expect(!APIChatToolWire.isUsableToolName(String(repeating: "a", count: 65)))
    }

    // MARK: Rounds sent back

    private let round = APIChatToolRound(
        assistantText: "Let me look.",
        calls: [APIChatToolCall(callID: "toolu_1", toolName: "notion__search", argumentsJSON: #"{"query":"plan"}"#)],
        results: [APIChatToolResult(callID: "toolu_1", text: "Found: Launch plan", isError: false)])

    @Test func anthropicRoundIsToolUseThenToolResult() throws {
        let messages = APIChatToolWire.messages(for: round, style: .anthropic)
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "assistant")
        let assistantContent = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(assistantContent[0]["type"] as? String == "text")
        #expect(assistantContent[1]["type"] as? String == "tool_use")
        #expect(assistantContent[1]["id"] as? String == "toolu_1")
        #expect((assistantContent[1]["input"] as? [String: Any])?["query"] as? String == "plan")
        #expect(messages[1]["role"] as? String == "user")
        let resultContent = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(resultContent[0]["type"] as? String == "tool_result")
        #expect(resultContent[0]["tool_use_id"] as? String == "toolu_1")
        #expect(resultContent[0]["content"] as? String == "Found: Launch plan")
        #expect(resultContent[0]["is_error"] == nil)
    }

    @Test func openAIRoundIsToolCallsThenToolMessages() throws {
        var failedRound = round
        failedRound.assistantText = ""
        failedRound.calls[0].argumentsJSON = ""
        failedRound.results[0].isError = true
        let messages = APIChatToolWire.messages(for: failedRound, style: .openAI)
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "assistant")
        #expect(messages[0]["content"] is NSNull)
        let toolCalls = try #require(messages[0]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls[0]["id"] as? String == "toolu_1")
        #expect((toolCalls[0]["function"] as? [String: Any])?["arguments"] as? String == "{}")
        #expect(messages[1]["role"] as? String == "tool")
        #expect(messages[1]["tool_call_id"] as? String == "toolu_1")
    }

    @Test func anthropicErrorResultsAreMarked() throws {
        var failedRound = round
        failedRound.results[0].isError = true
        failedRound.calls[0].argumentsJSON = "{broken"
        let messages = APIChatToolWire.messages(for: failedRound, style: .anthropic)
        let toolUse = try #require((messages[0]["content"] as? [[String: Any]])?.last)
        #expect((toolUse["input"] as? [String: Any])?.isEmpty == true)
        #expect((messages[1]["content"] as? [[String: Any]])?.first?["is_error"] as? Bool == true)
    }

    // MARK: Streamed tool calls (recorded responses)

    @Test func anthropicStreamedToolCallIsPutBackTogether() {
        let recorded = [
            #"event: message_start"#,
            #"data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking."}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"notion__search","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"que"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"ry\": \"plan\"}"}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_02","name":"memory_list","input":{}}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"data: {"type":"message_stop"}"#
        ]
        var collector = APIChatToolCallCollector()
        for line in recorded { collector.take(line: line, style: .anthropic) }
        #expect(collector.calls == [
            APIChatToolCall(callID: "toolu_01", toolName: "notion__search", argumentsJSON: #"{"query": "plan"}"#),
            APIChatToolCall(callID: "toolu_02", toolName: "memory_list", argumentsJSON: "")
        ])
    }

    @Test func openAIStreamedToolCallsArePutBackTogether() {
        let recorded = [
            #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"notion__search","arguments":""}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\""}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"plan\"}"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"memory_read","arguments":"{\"path\":\"memory.md\"}"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]"
        ]
        var collector = APIChatToolCallCollector()
        for line in recorded { collector.take(line: line, style: .openAI) }
        #expect(collector.calls == [
            APIChatToolCall(callID: "call_a", toolName: "notion__search", argumentsJSON: #"{"query":"plan"}"#),
            APIChatToolCall(callID: "call_b", toolName: "memory_read", argumentsJSON: #"{"path":"memory.md"}"#)
        ])
    }

    @Test func aCallWithNoIDGetsOneAndOneWithNoNameIsDropped() {
        var collector = APIChatToolCallCollector()
        collector.take(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"memory_list","arguments":{}}}]}}]}"#, style: .openAI)
        collector.take(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{}"}}]}}]}"#, style: .openAI)
        #expect(collector.calls == [APIChatToolCall(callID: "call_0", toolName: "memory_list", argumentsJSON: "{}")])
    }

    @Test func plainTextStreamsHaveNoToolCalls() {
        var collector = APIChatToolCallCollector()
        collector.take(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#, style: .anthropic)
        collector.take(line: #"data: {"choices":[{"delta":{"content":"Yo"}}]}"#, style: .openAI)
        collector.take(line: "event: ping", style: .anthropic)
        #expect(collector.calls.isEmpty)
    }

    // MARK: The loop

    /// A stand-in model that asks for one tool per round, `roundsWanted` times, then answers.
    private actor RecordedModel {
        var requests: [(roundCount: Int, mayCallTools: Bool)] = []
        let roundsWanted: Int
        init(roundsWanted: Int) { self.roundsWanted = roundsWanted }

        func reply(rounds: [APIChatToolRound], mayCallTools: Bool) -> APIChatRoundReply {
            requests.append((rounds.count, mayCallTools))
            if mayCallTools, rounds.count < roundsWanted {
                return APIChatRoundReply(text: "Looking (\(rounds.count + 1)).",
                                         toolCalls: [APIChatToolCall(callID: "c\(rounds.count)", toolName: "notion__search", argumentsJSON: #"{"query":"x"}"#)],
                                         stopReason: "tool_use", endedCleanly: true)
            }
            return APIChatRoundReply(text: "Done.", toolCalls: [], stopReason: "end_turn", endedCleanly: true)
        }
    }

    @Test func aToolCallIsRunAndItsResultSentBack() async throws {
        let model = RecordedModel(roundsWanted: 1)
        var toolsRun: [APIChatToolCall] = []
        let outcome = try await APIChatToolLoop.run(
            sendRound: { rounds, mayCallTools, _ in await model.reply(rounds: rounds, mayCallTools: mayCallTools) },
            runTool: { call in
                toolsRun.append(call)
                return APIChatToolResult(callID: "ignored", text: "Found: Launch plan", isError: false)
            })
        #expect(toolsRun.map(\.toolName) == ["notion__search"])
        #expect(outcome.rounds.count == 1)
        // The result goes back under the call's own id, whatever the runner wrote.
        #expect(outcome.rounds[0].results == [APIChatToolResult(callID: "c0", text: "Found: Launch plan", isError: false)])
        #expect(outcome.answer == "Looking (1).\n\nDone.")
        #expect(!outcome.stoppedAtRoundCap)
        let requests = await model.requests
        #expect(requests.map(\.roundCount) == [0, 1])
    }

    @Test func theLoopStopsAtTheCap() async throws {
        let model = RecordedModel(roundsWanted: 100)
        var toolRuns = 0
        let outcome = try await APIChatToolLoop.run(
            maximumRounds: 3,
            sendRound: { rounds, mayCallTools, _ in await model.reply(rounds: rounds, mayCallTools: mayCallTools) },
            runTool: { call in
                toolRuns += 1
                return APIChatToolResult(callID: call.callID, text: "ok", isError: false)
            })
        #expect(toolRuns == 3)
        #expect(outcome.rounds.count == 3)
        #expect(outcome.stoppedAtRoundCap)
        #expect(outcome.answer.hasSuffix("Done."))
        let requests = await model.requests
        // Three rounds with tools, then one last go with tools switched off.
        #expect(requests.map(\.mayCallTools) == [true, true, true, false])
    }

    @Test func toolsTheModelAsksForAfterTheCapAreNotRun() async throws {
        var toolRuns = 0
        let outcome = try await APIChatToolLoop.run(
            maximumRounds: 0,
            sendRound: { _, _, _ in
                APIChatRoundReply(text: "Still want a tool.", toolCalls: [APIChatToolCall(callID: "x", toolName: "notion__search", argumentsJSON: "{}")],
                                  stopReason: "tool_use", endedCleanly: true)
            },
            runTool: { call in
                toolRuns += 1
                return APIChatToolResult(callID: call.callID, text: "", isError: false)
            })
        #expect(toolRuns == 0)
        #expect(outcome.answer == "Still want a tool.")
    }

    @Test func longToolAnswersAreCut() {
        let long = String(repeating: "a", count: APIChatToolWire.maximumResultCharacters + 10)
        let trimmed = APIChatToolWire.trimmedResultText(long)
        #expect(trimmed.hasPrefix(String(repeating: "a", count: 100)))
        #expect(trimmed.contains("cut"))
        #expect(trimmed.count < long.count + 80)
        #expect(APIChatToolWire.trimmedResultText("short") == "short")
    }

    // MARK: Refusals

    @Test func providersThatHaveNoToolsAreRecognised() {
        #expect(APIChatToolWire.toolRefusal(statusCode: 400, body: #"{"error":"registry.ollama.ai/library/gemma:2b does not support tools"}"#) == .modelHasNoTools)
        #expect(APIChatToolWire.toolRefusal(statusCode: 404, body: #"{"error":{"message":"No endpoints found that support tool use."}}"#) == .modelHasNoTools)
        #expect(APIChatToolWire.toolRefusal(statusCode: 400, body: #"{"error":{"message":"tool calling is not supported for this model"}}"#) == .modelHasNoTools)
        #expect(APIChatToolWire.toolRefusal(statusCode: 400, body: #"{"error":{"message":"tools.0.input_schema: JSON schema is invalid"}}"#) == .thisRequestOnly)
    }

    @Test func otherFailuresAreNotAboutTools() {
        #expect(APIChatToolWire.toolRefusal(statusCode: 401, body: "invalid x-api-key, tools") == nil)
        #expect(APIChatToolWire.toolRefusal(statusCode: 429, body: "rate limited on tool use") == nil)
        #expect(APIChatToolWire.toolRefusal(statusCode: 500, body: "tool server error") == nil)
        #expect(APIChatToolWire.toolRefusal(statusCode: 400, body: "max_tokens: too large") == nil)
    }

    // MARK: Who may run what

    @Test func levelsMatchTheHubRule() {
        #expect(APIChatToolAccess.allows(effect: "read", level: "read", ownerAsked: true))
        #expect(!APIChatToolAccess.allows(effect: "change", level: "read", ownerAsked: true))
        #expect(APIChatToolAccess.allows(effect: "change", level: "readAndDraft", ownerAsked: true))
        #expect(!APIChatToolAccess.allows(effect: "irreversible", level: "readAndDraft", ownerAsked: true))
        #expect(APIChatToolAccess.allows(effect: "irreversible", level: "full", ownerAsked: true))
    }

    @Test func aTurnNotFromTheOwnerOnlyReads() {
        #expect(APIChatToolAccess.allows(effect: "read", level: "full", ownerAsked: false))
        #expect(!APIChatToolAccess.allows(effect: "change", level: "full", ownerAsked: false))
        #expect(!APIChatToolAccess.allows(effect: "irreversible", level: "full", ownerAsked: false))
    }

    @Test func anUnknownLevelOnlyReads() {
        #expect(APIChatToolAccess.allows(effect: "read", level: "everything", ownerAsked: true))
        #expect(!APIChatToolAccess.allows(effect: "change", level: "everything", ownerAsked: true))
    }

    // MARK: Its own memory folder

    @Test func memoryPathsStayInTheBotsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path

        #expect(BotMemoryFolderPath.resolve("memory.md", inside: folder)?.path == root + "/memory.md")
        #expect(BotMemoryFolderPath.resolve("./skills/plan/SKILL.md", inside: folder)?.path == root + "/skills/plan/SKILL.md")
        #expect(BotMemoryFolderPath.resolve("../other-bot/memory.md", inside: folder) == nil)
        #expect(BotMemoryFolderPath.resolve("skills/../../x", inside: folder) == nil)
        #expect(BotMemoryFolderPath.resolve("/etc/passwd", inside: folder) == nil)
        #expect(BotMemoryFolderPath.resolve("~/.ssh/id_rsa", inside: folder) == nil)
        #expect(BotMemoryFolderPath.resolve("", inside: folder) == nil)
        #expect(BotMemoryFolderPath.resolve(".", inside: folder) == nil)

        // A link inside the folder that points out is never followed, nor anything under it.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(BotMemoryFolderPath.resolve("escape", inside: folder) == nil)
        #expect(BotMemoryFolderPath.resolve("escape/notes.md", inside: folder) == nil)
    }
}
