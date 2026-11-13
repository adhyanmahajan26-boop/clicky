import Foundation

// Tool calling for bots that run straight on a model API with the owner's key (`api:<provider>` engines). The app's `APIChat`
// sends the requests and `APIChatToolbox` runs the tools; this file is the part that needs no network, so it can be tested here:
// how tools and tool rounds are written for each API, how a streamed answer's tool calls are put back together, the loop that
// keeps going until the model stops asking for tools, which tools a bot's level allows, and which paths are its own memory folder.

/// The two ways model APIs take tools: Anthropic's Messages API (`tool_use` and `tool_result` blocks) and the OpenAI-style chat
/// endpoint everyone else offers (`tools`, `tool_calls` and `role: tool` messages).
public enum APIChatWireStyle: Sendable {
    case anthropic
    case openAI
}

/// One tool offered to the model.
public struct APIChatToolDefinition: Equatable, Sendable {
    /// The name the model calls it by: letters, digits, `_` and `-`, up to 64 (both APIs refuse anything else).
    public var name: String
    public var description: String
    /// The JSON Schema of its arguments, as JSON text.
    public var inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

/// One tool the model asked for.
public struct APIChatToolCall: Equatable, Sendable {
    public var callID: String
    public var toolName: String
    /// The arguments as the model wrote them: JSON text, which can be empty or broken.
    public var argumentsJSON: String

    public init(callID: String, toolName: String, argumentsJSON: String) {
        self.callID = callID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }
}

/// What a tool answered, sent back to the model.
public struct APIChatToolResult: Equatable, Sendable {
    public var callID: String
    public var text: String
    public var isError: Bool

    public init(callID: String, text: String, isError: Bool) {
        self.callID = callID
        self.text = text
        self.isError = isError
    }
}

/// One round inside a turn: what the model said and the tools it asked for, then what those tools answered.
public struct APIChatToolRound: Equatable, Sendable {
    public var assistantText: String
    public var calls: [APIChatToolCall]
    public var results: [APIChatToolResult]

    public init(assistantText: String, calls: [APIChatToolCall], results: [APIChatToolResult]) {
        self.assistantText = assistantText
        self.calls = calls
        self.results = results
    }
}

/// Why a provider turned down a request that carried tools.
public enum APIChatToolRefusal: Equatable, Sendable {
    /// The model or provider has no tool calling at all: remember it and stop offering tools to it.
    case modelHasNoTools
    /// Something about these tools this time (a schema it didn't like): answer in words this turn, try tools again next time.
    case thisRequestOnly
}

public enum APIChatToolWire {
    /// Rounds of tool calls in one turn. After that the model is asked once more, with tools switched off, to answer with what it has.
    public static let maximumToolRounds = 8
    /// A tool's answer is cut to this many characters before it goes back to the model.
    public static let maximumResultCharacters = 20_000

    /// Both APIs only take tool names made of letters, digits, `_` and `-`, up to 64 characters.
    public static func isUsableToolName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
    }

    /// The request's `tools` field.
    public static func toolsField(_ definitions: [APIChatToolDefinition], style: APIChatWireStyle) -> [[String: Any]] {
        definitions.map { definition -> [String: Any] in
            let schema = inputSchemaObject(definition.inputSchemaJSON)
            switch style {
            case .anthropic:
                return ["name": definition.name, "description": definition.description, "input_schema": schema]
            case .openAI:
                return ["type": "function",
                        "function": ["name": definition.name, "description": definition.description, "parameters": schema] as [String: Any]]
            }
        }
    }

    /// The request's `tool_choice` for the last go after the round cap: the tools stay listed (Anthropic refuses a conversation with
    /// tool blocks and no tools), but the model may not call them.
    public static func toolChoiceNone(style: APIChatWireStyle) -> Any {
        switch style {
        case .anthropic: return ["type": "none"]
        case .openAI: return "none"
        }
    }

    /// A schema both APIs take: an object at the top level. Anything else (missing, unreadable, not an object) becomes an empty
    /// object schema, so one odd tool can't make the whole request fail.
    static func inputSchemaObject(_ json: String) -> [String: Any] {
        let emptyObjectSchema: [String: Any] = ["type": "object", "properties": [String: Any]()]
        guard let parsedSchema = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return emptyObjectSchema }
        var schema = parsedSchema
        // "$schema" is only a label, and some OpenAI-style endpoints refuse keys they don't know at the top.
        schema.removeValue(forKey: "$schema")
        if schema["type"] == nil { schema["type"] = "object" }
        guard schema["type"] as? String == "object" else { return emptyObjectSchema }
        if schema["properties"] == nil { schema["properties"] = [String: Any]() }
        return schema
    }

    /// The messages one finished round adds to the conversation: the model's own message with its tool calls, then the answers.
    public static func messages(for round: APIChatToolRound, style: APIChatWireStyle) -> [[String: Any]] {
        switch style {
        case .anthropic:
            var assistantContent: [[String: Any]] = []
            if !round.assistantText.isEmpty { assistantContent.append(["type": "text", "text": round.assistantText]) }
            for call in round.calls {
                assistantContent.append(["type": "tool_use", "id": call.callID, "name": call.toolName, "input": argumentsObject(call.argumentsJSON)])
            }
            let resultContent: [[String: Any]] = round.results.map { result -> [String: Any] in
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": result.callID, "content": result.text]
                if result.isError { block["is_error"] = true }
                return block
            }
            return [["role": "assistant", "content": assistantContent], ["role": "user", "content": resultContent]]
        case .openAI:
            let toolCalls: [[String: Any]] = round.calls.map { call -> [String: Any] in
                ["id": call.callID, "type": "function",
                 "function": ["name": call.toolName, "arguments": argumentsText(call.argumentsJSON)] as [String: Any]]
            }
            var assistantMessage: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
            assistantMessage["content"] = round.assistantText.isEmpty ? NSNull() : round.assistantText
            let toolMessages: [[String: Any]] = round.results.map { result -> [String: Any] in
                ["role": "tool", "tool_call_id": result.callID, "content": result.text]
            }
            return [assistantMessage] + toolMessages
        }
    }

    /// The arguments as an object, for Anthropic's `input` (it must be an object, even when the model wrote nothing).
    public static func argumentsObject(_ argumentsJSON: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
    }

    /// The arguments as text, for OpenAI's `arguments` (a JSON string; "{}" when the model wrote nothing).
    static func argumentsText(_ argumentsJSON: String) -> String {
        argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : argumentsJSON
    }

    /// Whether a refused request (`statusCode`, `body`) was refused because of its tools. Only asked when the request carried tools.
    public static func toolRefusal(statusCode: Int, body: String) -> APIChatToolRefusal? {
        // Sign-in, rate limits and server trouble are never about the tools.
        guard (400..<500).contains(statusCode), ![401, 403, 408, 429].contains(statusCode) else { return nil }
        let lowercasedBody = body.lowercased()
        let mentionsTools = ["tool", "function"].contains { lowercasedBody.contains($0) }
        guard mentionsTools else { return nil }
        // "does not support tools" (Ollama), "No endpoints found that support tool use" (OpenRouter), "tool calling is not
        // supported for this model" (Groq and others), "function calling is not enabled".
        let saysNoToolsAtAll = ["not support", "unsupported", "doesn't support", "no endpoints found that support",
                                "not supported", "not enabled", "not available"].contains { lowercasedBody.contains($0) }
        return saysNoToolsAtAll ? .modelHasNoTools : .thisRequestOnly
    }

    /// Cuts a tool's answer to `maximumResultCharacters`, saying so.
    public static func trimmedResultText(_ text: String) -> String {
        guard text.count > maximumResultCharacters else { return text }
        return String(text.prefix(maximumResultCharacters)) + "\n…(cut: the tool's answer was \(text.count) characters long)"
    }

    /// Two pieces of an answer, a blank line between them when both have words.
    public static func joinedAnswer(_ earlierText: String, _ laterText: String) -> String {
        if earlierText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return laterText }
        if laterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return earlierText }
        return earlierText + "\n\n" + laterText
    }
}

/// Puts a streamed answer's tool calls back together, one server-sent line at a time. Anthropic sends a `content_block_start` with
/// the tool's id and name, then the arguments in `input_json_delta` pieces; OpenAI-style endpoints send `delta.tool_calls` pieces
/// keyed by `index`, the id and name in the first and the arguments spread over the rest.
public struct APIChatToolCallCollector {
    private var callsByStreamIndex: [Int: APIChatToolCall] = [:]
    /// Arguments Anthropic gave whole in `content_block_start`, used when no pieces follow.
    private var startingArgumentsByStreamIndex: [Int: String] = [:]
    private var streamIndexesInOrder: [Int] = []

    public init() {}

    /// The calls so far, in the order the model made them. A call with no name is dropped; one with no id gets one.
    public var calls: [APIChatToolCall] {
        streamIndexesInOrder.compactMap { streamIndex -> APIChatToolCall? in
            guard var call = callsByStreamIndex[streamIndex], !call.toolName.isEmpty else { return nil }
            if call.callID.isEmpty { call.callID = "call_\(streamIndex)" }
            if call.argumentsJSON.isEmpty, let startingArguments = startingArgumentsByStreamIndex[streamIndex] { call.argumentsJSON = startingArguments }
            return call
        }
    }

    public mutating func take(line: String, style: APIChatWireStyle) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return }
        switch style {
        case .anthropic: takeAnthropic(event)
        case .openAI: takeOpenAI(event)
        }
    }

    private mutating func takeAnthropic(_ event: [String: Any]) {
        let streamIndex = event["index"] as? Int ?? 0
        switch event["type"] as? String {
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use" else { return }
            begin(streamIndex: streamIndex)
            callsByStreamIndex[streamIndex]?.callID = block["id"] as? String ?? ""
            callsByStreamIndex[streamIndex]?.toolName = block["name"] as? String ?? ""
            if let input = block["input"] as? [String: Any], !input.isEmpty,
               let inputData = try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys) {
                startingArgumentsByStreamIndex[streamIndex] = String(decoding: inputData, as: UTF8.self)
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "input_json_delta",
                  let partialJSON = delta["partial_json"] as? String, callsByStreamIndex[streamIndex] != nil else { return }
            callsByStreamIndex[streamIndex]?.argumentsJSON += partialJSON
        default:
            return
        }
    }

    private mutating func takeOpenAI(_ event: [String: Any]) {
        guard let choice = (event["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any],
              let toolCallPieces = delta["tool_calls"] as? [[String: Any]] else { return }
        for (position, piece) in toolCallPieces.enumerated() {
            let streamIndex = piece["index"] as? Int ?? position
            begin(streamIndex: streamIndex)
            if let callID = piece["id"] as? String, !callID.isEmpty { callsByStreamIndex[streamIndex]?.callID = callID }
            let function = piece["function"] as? [String: Any]
            // The name comes once; a provider that repeats it in later pieces mustn't double it.
            if let name = function?["name"] as? String, !name.isEmpty, callsByStreamIndex[streamIndex]?.toolName.isEmpty == true {
                callsByStreamIndex[streamIndex]?.toolName = name
            }
            if let argumentsPiece = function?["arguments"] as? String {
                callsByStreamIndex[streamIndex]?.argumentsJSON += argumentsPiece
            } else if let argumentsObject = function?["arguments"] as? [String: Any],
                      let argumentsData = try? JSONSerialization.data(withJSONObject: argumentsObject, options: .sortedKeys) {
                // A few OpenAI-style servers send the arguments as an object rather than a string.
                callsByStreamIndex[streamIndex]?.argumentsJSON += String(decoding: argumentsData, as: UTF8.self)
            }
        }
    }

    private mutating func begin(streamIndex: Int) {
        guard callsByStreamIndex[streamIndex] == nil else { return }
        callsByStreamIndex[streamIndex] = APIChatToolCall(callID: "", toolName: "", argumentsJSON: "")
        streamIndexesInOrder.append(streamIndex)
    }
}

/// What one request in the loop brought back.
public struct APIChatRoundReply: Equatable, Sendable {
    public var text: String
    public var toolCalls: [APIChatToolCall]
    /// "max_tokens" or "length" means the answer hit the length limit.
    public var stopReason: String?
    /// Whether the stream said it had ended, rather than the connection just closing.
    public var endedCleanly: Bool

    public init(text: String, toolCalls: [APIChatToolCall], stopReason: String?, endedCleanly: Bool) {
        self.text = text
        self.toolCalls = toolCalls
        self.stopReason = stopReason
        self.endedCleanly = endedCleanly
    }
}

public struct APIChatToolLoopOutcome: Equatable, Sendable {
    /// Everything the model said across the rounds.
    public var answer: String
    public var rounds: [APIChatToolRound]
    public var lastStopReason: String?
    public var lastEndedCleanly: Bool
    /// The model was still asking for tools when the round cap was reached.
    public var stoppedAtRoundCap: Bool
}

/// Ask, run the tools the model asked for, send their answers back, and ask again, until the model stops asking for tools.
public enum APIChatToolLoop {
    /// `sendRound(rounds, mayCallTools, textBeforeThisRound)` makes one request with the rounds so far; with `mayCallTools` false it
    /// must switch tools off for that request. `runTool` runs one call and never throws: a failure is an `isError` result.
    public static func run(
        maximumRounds: Int = APIChatToolWire.maximumToolRounds,
        sendRound: (_ rounds: [APIChatToolRound], _ mayCallTools: Bool, _ textBeforeThisRound: String) async throws -> APIChatRoundReply,
        runTool: (_ call: APIChatToolCall) async -> APIChatToolResult
    ) async throws -> APIChatToolLoopOutcome {
        var rounds: [APIChatToolRound] = []
        var textBeforeThisRound = ""
        while true {
            try Task.checkCancellation()
            let mayCallTools = rounds.count < maximumRounds
            let reply = try await sendRound(rounds, mayCallTools, textBeforeThisRound)
            guard mayCallTools, !reply.toolCalls.isEmpty else {
                return APIChatToolLoopOutcome(answer: APIChatToolWire.joinedAnswer(textBeforeThisRound, reply.text), rounds: rounds,
                                              lastStopReason: reply.stopReason, lastEndedCleanly: reply.endedCleanly,
                                              stoppedAtRoundCap: !mayCallTools)
            }
            var results: [APIChatToolResult] = []
            for call in reply.toolCalls {
                try Task.checkCancellation()
                var result = await runTool(call)
                // Every call gets its own answer under its own id: both APIs refuse a round with an unanswered call.
                result.callID = call.callID
                result.text = APIChatToolWire.trimmedResultText(result.text)
                results.append(result)
            }
            rounds.append(APIChatToolRound(assistantText: reply.text, calls: reply.toolCalls, results: results))
            textBeforeThisRound = APIChatToolWire.joinedAnswer(textBeforeThisRound, reply.text)
        }
    }
}

/// What a bot's level on an app lets it run, matching the connector hub's rule (`crossplatform/docs/CONNECTORS.md`).
public enum APIChatToolAccess {
    /// `effect` is the hub's `read`, `change` or `irreversible`; `level` is `read`, `readAndDraft` or `full`. A turn that didn't
    /// come from the owner's own words never gets more than `read`, and a level this build doesn't know counts as `read`.
    public static func allows(effect: String, level: String, ownerAsked: Bool) -> Bool {
        let effectiveLevel = ownerAsked ? level : "read"
        switch effectiveLevel {
        case "full": return true
        case "readAndDraft": return effect == "read" || effect == "change"
        default: return effect == "read"
        }
    }
}

/// A bot's own memory folder, the only place its file tools reach.
public enum BotMemoryFolderPath {
    /// The file `relativePath` names inside `folder`, or nil when it would leave the folder: an absolute path, `~`, `..`, or a
    /// symbolic link anywhere along the way (a bot has no reason to keep links in its memory folder, and one could point anywhere).
    public static func resolve(_ relativePath: String, inside folder: URL) -> URL? {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.hasPrefix("/"), !trimmedPath.hasPrefix("~") else { return nil }
        let rootFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
        let components = trimmedPath.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        var currentURL = rootFolder
        for component in components {
            currentURL = currentURL.appendingPathComponent(component)
            if isSymbolicLink(currentURL) { return nil }
        }
        return currentURL
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
