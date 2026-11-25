//
//  APIChat.swift
//  leanring-buddy
//
//  Talks to a model straight over HTTP with the owner's key, streaming the answer: Anthropic's Messages API, and the
//  OpenAI-style chat endpoint everyone else offers. Bots, Theo and Clicky all run on it when their engine is
//  "api:<provider>". A bot's turn may call tools (`APIChatToolbox`): its own memory folder and the connector hub apps it was
//  given, with the loop and wire format in ClickyCore `Team/APIChatToolCalling.swift`. Theo's helpers get no tools. Changing
//  code is still a run on a harness.
//

import ClickyCore
import Foundation

enum APIChatError: LocalizedError {
    case noKey(String)
    case rejected(String)
    case noAnswer(String)
    /// The provider turned the request down because of its tools (`message` is its own words, trimmed). Caught in `APIChat.stream`,
    /// which asks again without tools.
    case toolsRefused(APIChatToolRefusal, message: String)

    var errorDescription: String? {
        switch self {
        case .noKey(let provider): return "\(provider) needs an API key. Add it in Settings › Models & API keys."
        case .rejected(let message): return message
        case .noAnswer(let provider): return "\(provider) returned no answer."
        case .toolsRefused(_, let message): return message
        }
    }
}

struct APIChatMessage: Codable, Equatable {
    var role: String
    var text: String
    /// Images for this message only; earlier screenshots aren't sent again.
    var imagesJPEGBase64: [String] = []
    /// Their media types, where they aren't all JPEG.
    var imageTypes: [String]?

    func imageType(at index: Int) -> String { imageTypes.flatMap { index < $0.count ? $0[index] : nil } ?? "image/jpeg" }
}

enum APIChat {
    static let maxOutputTokens = 8192
    /// What a call or a one-turn conversation asks an OpenAI-style server for: a thinking model (Qwen 3.x and the like)
    /// spends thousands of tokens thinking before the answer, and a server's own default can stop it before it answers.
    static let roomForThinkingTokens = 16_384

    /// The field an OpenAI-style request carries its output limit in: OpenAI itself wants `max_completion_tokens` for its
    /// newer models, every compatible server takes `max_tokens`.
    static func outputLimitField(providerID: String) -> String { providerID == "openai" ? "max_completion_tokens" : "max_tokens" }

    /// How a provider takes tools, or nil when it can't chat here at all.
    static func wireStyle(for kind: ProviderInfo.Protocol_) -> APIChatWireStyle? {
        switch kind {
        case .anthropic: return .anthropic
        case .openAICompatible: return .openAI
        case .other: return nil
        }
    }

    /// The request for one turn. Pure, so it can be tested without the network.
    /// `tools`: what the model may call. `toolRounds`: the tool calls made so far in this turn and their answers, sent after
    /// `messages`. `mayCallTools` false lists the tools but tells the model not to call them (the last go after the round cap).
    /// `fast`: Anthropic's fast mode, sent only for a model that takes it (ClickyCore `ClaudeFastMode`).
    static func request(provider: ProviderInfo, key: String?, model: String, system: String, messages: [APIChatMessage],
                        tools: [APIChatToolDefinition] = [], toolRounds: [APIChatToolRound] = [], mayCallTools: Bool = true,
                        fast: Bool = false, maxOutputTokens openAIOutputLimit: Int? = nil) -> URLRequest? {
        guard let style = wireStyle(for: provider.kind) else { return nil }
        let roundMessages = toolRounds.flatMap { APIChatToolWire.messages(for: $0, style: style) }
        switch style {
        case .anthropic:
            guard let url = URL(string: provider.baseURL + "/messages") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 300)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ProviderInfo.authorize(&request, provider: provider, key: key)
            var body: [String: Any] = ["model": model, "max_tokens": maxOutputTokens, "stream": true, "system": system,
                                       "messages": messages.map(anthropicMessage) + roundMessages]
            if fast, ClaudeFastMode.supports(model: model) { body["speed"] = "fast" }
            addTools(tools, mayCallTools: mayCallTools, style: style, to: &body)
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
        case .openAI:
            guard let url = URL(string: provider.baseURL + "/chat/completions") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 300)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ProviderInfo.authorize(&request, provider: provider, key: key)
            var all: [[String: Any]] = system.isEmpty ? [] : [["role": "system", "content": system]]
            all += messages.map(openAIMessage)
            all += roundMessages
            var body: [String: Any] = ["model": model, "stream": true, "messages": all]
            // So a bot's turn on this key counts in its usage (`APIStreamUsage`).
            if APIStreamUsage.asksForUsage(providerID: provider.id) { body["stream_options"] = ["include_usage": true] }
            if let openAIOutputLimit { body[outputLimitField(providerID: provider.id)] = openAIOutputLimit }
            addTools(tools, mayCallTools: mayCallTools, style: style, to: &body)
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
        }
    }

    private static func addTools(_ tools: [APIChatToolDefinition], mayCallTools: Bool, style: APIChatWireStyle, to body: inout [String: Any]) {
        guard !tools.isEmpty else { return }
        body["tools"] = APIChatToolWire.toolsField(tools, style: style)
        if !mayCallTools { body["tool_choice"] = APIChatToolWire.toolChoiceNone(style: style) }
    }

    private static func anthropicMessage(_ message: APIChatMessage) -> [String: Any] {
        guard !message.imagesJPEGBase64.isEmpty else { return ["role": message.role, "content": message.text] }
        var content: [[String: Any]] = message.imagesJPEGBase64.enumerated().map { index, image in
            ["type": "image", "source": ["type": "base64", "media_type": message.imageType(at: index), "data": image]]
        }
        content.append(["type": "text", "text": message.text])
        return ["role": message.role, "content": content]
    }

    private static func openAIMessage(_ message: APIChatMessage) -> [String: Any] {
        guard !message.imagesJPEGBase64.isEmpty else { return ["role": message.role, "content": message.text] }
        var content: [[String: Any]] = [["type": "text", "text": message.text]]
        content += message.imagesJPEGBase64.enumerated().map { index, image in
            ["type": "image_url", "image_url": ["url": "data:\(message.imageType(at: index));base64,\(image)"]]
        }
        return ["role": message.role, "content": content]
    }

    /// The text in one server-sent line ("data: {…}"), if any; `done` when the stream says it has ended.
    static func parse(line: String, kind: ProviderInfo.Protocol_) -> (text: String?, done: Bool, error: String?) {
        guard line.hasPrefix("data:") else { return (nil, false, nil) }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return (nil, true, nil) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return (nil, false, nil) }
        if let error = errorMessage(in: object) { return (nil, true, error) }
        switch kind {
        case .anthropic:
            switch object["type"] as? String {
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any]
                return (delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil, false, nil)
            case "message_stop": return (nil, true, nil)
            default: return (nil, false, nil)
            }
        default:
            let choice = (object["choices"] as? [[String: Any]])?.first
            let text = (choice?["delta"] as? [String: Any])?["content"] as? String
            return (text, false, nil)
        }
    }

    /// A provider's error, whichever way it writes it ({"error": {"message": …}} or {"error": "…"}).
    private static func errorMessage(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] { return error["message"] as? String ?? "The provider reported an error." }
        return object["error"] as? String
    }

    /// Why the model stopped, from one server-sent line: "max_tokens" or "length" means the answer hit the limit.
    static func stopReason(line: String) -> String? {
        guard line.hasPrefix("data:"), let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) as? [String: Any] else { return nil }
        if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String { return reason }
        return (object["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
    }

    /// Runs one turn and returns the whole answer; `onText` gets the answer so far as it grows. With a `toolbox`, the model may
    /// call its tools: each round's calls are run and sent back, until it answers without asking for more (or the round cap).
    static func stream(provider: ProviderInfo, key: String?, model: String, system: String, messages: [APIChatMessage],
                       toolbox: APIChatToolbox? = nil, fast: Bool = false, maxOutputTokens: Int? = nil, usageMeter: APIUsageMeter? = nil,
                       onText: @MainActor (String) -> Void) async throws -> String {
        guard key != nil || provider.keyless || provider.group == .custom else { throw APIChatError.noKey(provider.label) }
        guard request(provider: provider, key: key, model: model, system: system, messages: messages) != nil else {
            throw APIChatError.rejected("\(provider.label) can't be used for chat.")
        }
        var offeredTools = toolbox?.definitions ?? []
        if !offeredTools.isEmpty, ModelsWithoutTools.contains(providerID: provider.id, model: model) { offeredTools = [] }
        var wordsOnlyNote: String?
        let outcome: APIChatToolLoopOutcome
        do {
            outcome = try await runToolLoop(provider: provider, key: key, model: model, system: system, messages: messages,
                                            tools: offeredTools, toolbox: toolbox, fast: fast, maxOutputTokens: maxOutputTokens,
                                            usageMeter: usageMeter, onText: onText)
        } catch APIChatError.toolsRefused(let refusal, let message) {
            // Today's words-only turn, and the chat says why: once for a model that has no tools at all, every time for a one-off.
            switch refusal {
            case .modelHasNoTools:
                if ModelsWithoutTools.remember(providerID: provider.id, model: model) {
                    wordsOnlyNote = "_(\(model) on \(provider.label) can't use apps or tools, so on it this bot answers in words only.)_"
                }
            case .thisRequestOnly:
                wordsOnlyNote = "_(\(provider.label) turned down this bot's tools this time (\(message)), so it answered in words only.)_"
            }
            outcome = try await runToolLoop(provider: provider, key: key, model: model, system: system, messages: messages,
                                            tools: [], toolbox: nil, fast: fast, maxOutputTokens: maxOutputTokens,
                                            usageMeter: usageMeter, onText: onText)
        }
        var answer = outcome.answer
        guard !answer.isEmpty else { return answer }
        // The words so far are still worth having, but the owner should know they stop short.
        if outcome.lastStopReason == "max_tokens" || outcome.lastStopReason == "length" {
            answer += "\n\n_(That hit the length limit, so it stops there.)_"
        } else if !outcome.lastEndedCleanly && outcome.lastStopReason == nil {
            answer += "\n\n_(The connection ended early, so this may be cut off.)_"
        }
        if outcome.stoppedAtRoundCap {
            answer += "\n\n_(Vello stopped the tools after \(APIChatToolWire.maximumToolRounds) rounds, so this answer works from what they found so far.)_"
        }
        if let wordsOnlyNote { answer += "\n\n" + wordsOnlyNote }
        let finalAnswer = answer
        await onText(finalAnswer)
        return answer
    }

    /// The tool loop over real requests. A refusal because of the tools only counts on the first request: after that the provider
    /// has already taken them.
    private static func runToolLoop(provider: ProviderInfo, key: String?, model: String, system: String, messages: [APIChatMessage],
                                    tools: [APIChatToolDefinition], toolbox: APIChatToolbox?, fast: Bool = false, maxOutputTokens: Int? = nil,
                                    usageMeter: APIUsageMeter? = nil, onText: @MainActor (String) -> Void) async throws -> APIChatToolLoopOutcome {
        try await APIChatToolLoop.run(
            sendRound: { rounds, mayCallTools, textBeforeThisRound in
                try await streamRound(provider: provider, key: key, model: model, system: system, messages: messages, tools: tools,
                                      toolRounds: rounds, mayCallTools: mayCallTools, fast: fast, maxOutputTokens: maxOutputTokens,
                                      usageMeter: usageMeter) { roundText in
                    onText(APIChatToolWire.joinedAnswer(textBeforeThisRound, roundText))
                }
            },
            runTool: { call in
                guard let toolbox else { return APIChatToolResult(callID: call.callID, text: "No tools are available in this turn.", isError: true) }
                return await toolbox.run(call)
            })
    }

    /// One request: streams its words to `onRoundText` and collects the tool calls it asks for.
    private static func streamRound(provider: ProviderInfo, key: String?, model: String, system: String, messages: [APIChatMessage],
                                    tools: [APIChatToolDefinition], toolRounds: [APIChatToolRound], mayCallTools: Bool, fast: Bool = false,
                                    maxOutputTokens: Int? = nil, usageMeter: APIUsageMeter? = nil,
                                    onRoundText: @MainActor (String) -> Void) async throws -> APIChatRoundReply {
        let sendsFast = fast && provider.kind == .anthropic && ClaudeFastMode.supports(model: model)
        guard let style = wireStyle(for: provider.kind),
              let request = request(provider: provider, key: key, model: model, system: system, messages: messages,
                                    tools: tools, toolRounds: toolRounds, mayCallTools: mayCallTools, fast: sendsFast,
                                    maxOutputTokens: maxOutputTokens) else {
            throw APIChatError.rejected("\(provider.label) can't be used for chat.")
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Fast mode has its own rate limit and isn't on every account: when it's turned down, the same round goes again at standard speed.
        if sendsFast, [400, 403, 429, 529].contains(status) {
            return try await streamRound(provider: provider, key: key, model: model, system: system, messages: messages, tools: tools,
                                         toolRounds: toolRounds, mayCallTools: mayCallTools, fast: false, maxOutputTokens: maxOutputTokens,
                                         usageMeter: usageMeter, onRoundText: onRoundText)
        }
        if !(200..<300).contains(status) {
            var body = Data()
            for try await byte in bytes where body.count < 4000 { body.append(byte) }
            let failure = ProviderInfo.testFailure(statusCode: status, body: body) ?? "HTTP \(status)"
            if !tools.isEmpty, toolRounds.isEmpty,
               let refusal = APIChatToolWire.toolRefusal(statusCode: status, body: String(decoding: body, as: UTF8.self)) {
                throw APIChatError.toolsRefused(refusal, message: String(failure.prefix(160)))
            }
            throw APIChatError.rejected("\(provider.label): " + failure)
        }
        var text = ""
        var ended = false
        var stop: String?
        var notStreamed = ""
        var toolCallCollector = APIChatToolCallCollector()
        // A thinking model's reasoning is never the answer (ClickyCore `ThinkingText`): a server that separates it sends it
        // as reasoning_content, which isn't read as text, and a <think> block in the text itself is taken out. A model that
        // may start mid-think is held until it's sure, unless the server is seen separating its reasoning.
        var serverSeparatesReasoning = false
        let mayStartMidThink = ThinkingText.mayThinkWithoutOpeningTag(model: model)
        var shownSoFar = ""
        // What this request used, counted even when it fails or is stopped part way: it was paid for.
        var roundUsage = APIStreamUsage()
        defer { usageMeter?.add(roundUsage.usage) }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            roundUsage.take(line: line)
            if !line.hasPrefix("data:"), !line.hasPrefix("event:"), notStreamed.count < 4000 { notStreamed += line }
            let parsed = parse(line: line, kind: provider.kind)
            if let error = parsed.error { throw APIChatError.rejected("\(provider.label): \(error)") }
            stop = stopReason(line: line) ?? stop
            if !tools.isEmpty { toolCallCollector.take(line: line, style: style) }
            if !serverSeparatesReasoning, ThinkingText.lineCarriesReasoning(line) { serverSeparatesReasoning = true }
            if let piece = parsed.text, !piece.isEmpty {
                text += piece
                let shown = ThinkingText.visible(text, isComplete: false, holdsUntilSure: mayStartMidThink && !serverSeparatesReasoning)
                if shown != shownSoFar {
                    shownSoFar = shown
                    await onRoundText(shown)
                }
            }
            if parsed.done {
                ended = true
                break
            }
        }
        let toolCalls = toolCallCollector.calls
        // A 200 with a plain JSON error instead of a stream.
        if text.isEmpty, toolCalls.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(notStreamed.utf8)) as? [String: Any],
           let error = errorMessage(in: object) {
            throw APIChatError.rejected("\(provider.label): \(error)")
        }
        let answer = ThinkingText.visible(text, isComplete: true, holdsUntilSure: mayStartMidThink && !serverSeparatesReasoning)
        // A held reply shows at the end. Only ever more words: what was already passed on is never taken back mid-turn.
        if answer.count > shownSoFar.count, answer.hasPrefix(shownSoFar) { await onRoundText(answer) }
        return APIChatRoundReply(text: answer, toolCalls: toolCalls, stopReason: stop, endedCleanly: ended)
    }

    /// Models that said they can't take tools, so they're asked in words only from then on (`v4.apiChat.modelsWithoutTools`,
    /// "<provider>/<model>"). A new model id, or removing the entry, tries tools again.
    enum ModelsWithoutTools {
        static let defaultsKey = "v4.apiChat.modelsWithoutTools"

        static func contains(providerID: String, model: String) -> Bool {
            (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).contains("\(providerID)/\(model)")
        }

        /// Adds it; true when it wasn't there yet, which is when the chat should say so.
        @discardableResult
        static func remember(providerID: String, model: String) -> Bool {
            var models = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
            let entry = "\(providerID)/\(model)"
            guard !models.contains(entry) else { return false }
            models.append(entry)
            UserDefaults.standard.set(models, forKey: defaultsKey)
            return true
        }
    }

    // MARK: Conversations

    /// What one bot turn on an API key used, over all its requests. Requests run one after another, the lock is for the type checker's sake.
    nonisolated final class APIUsageMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = BotTurnUsage()

        func add(_ usage: BotTurnUsage) {
            guard !usage.isEmpty else { return }
            lock.lock()
            total = total + usage
            lock.unlock()
        }

        var used: BotTurnUsage? {
            lock.lock()
            defer { lock.unlock() }
            return total.isEmpty ? nil : total
        }
    }

    /// A stateless API has no session of its own, so the conversation is kept here, under an id that works like an
    /// engine's session id (Theo's own folder, never sent anywhere but the provider).
    enum History {
        private static var folder: URL {
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Theo/api-sessions", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        static func forget(_ session: String) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(session).json"))
        }

        static func load(_ session: String) -> [APIChatMessage] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(session).json")) else { return [] }
            return (try? JSONDecoder().decode([APIChatMessage].self, from: data)) ?? []
        }

        static func save(_ messages: [APIChatMessage], session: String) {
            // Screenshots aren't kept; the words are, all of them. What outgrows the model's room is summed up
            // (`compactLater`), never just dropped.
            let words = messages.map { APIChatMessage(role: $0.role, text: $0.text) }
            try? JSONEncoder().encode(words).write(to: folder.appendingPathComponent("\(session).json"), options: .atomic)
        }

        /// The room for earlier conversation on this model, with these instructions and this much answer.
        @MainActor
        static func roomCharacters(provider: ProviderInfo, model: String, systemCharacters: Int, wantedAnswerTokens: Int) async -> Int {
            let window = await ContextWindows.tokens(provider: provider, model: model)
            let answer = ContextBudget.answerTokens(windowTokens: window, wantedAnswerTokens: wantedAnswerTokens)
            return ContextBudget.historyCharacters(windowTokens: window, answerTokens: answer, instructionsCharacters: systemCharacters)
        }

        /// What goes with this turn: everything that fits, with the summary first if there is one (ClickyCore `ConversationCompaction.fitting`).
        static func fitting(_ messages: [APIChatMessage], roomCharacters: Int) -> [APIChatMessage] {
            let plain = messages.map { ConversationCompaction.Message(role: $0.role, text: $0.text) }
            let fitted = ConversationCompaction.fitting(plain, roomCharacters: roomCharacters)
            guard fitted != plain else { return messages }
            // The newest message keeps its screenshots.
            var result = fitted.map { APIChatMessage(role: $0.role, text: $0.text) }
            if let last = messages.last, let lastIndex = result.indices.last, result[lastIndex].text == last.text { result[lastIndex] = last }
            return result
        }

        @MainActor private static var compacting: Set<String> = []

        /// After a turn: when the conversation has outgrown its room, the same model sums up the oldest part, earlier
        /// summary included, and that summary replaces it. Runs after the answer, so it never holds a reply back.
        /// Until it's done (or if it fails), `fitting` keeps each turn inside the window.
        @MainActor
        static func compactLater(session: String, provider: ProviderInfo, key: String?, model: String, roomCharacters: Int) {
            guard !compacting.contains(session) else { return }
            let before = load(session)
            let plain = before.map { ConversationCompaction.Message(role: $0.role, text: $0.text) }
            guard let count = ConversationCompaction.partToSummarize(plain, roomCharacters: roomCharacters) else { return }
            compacting.insert(session)
            let request = ConversationCompaction.summaryRequest(for: Array(plain.prefix(count)), owner: BotPrompts.ownerName)
            Task { @MainActor in
                defer { compacting.remove(session) }
                do {
                    let summary = try await APIChat.stream(provider: provider, key: key, model: model,
                                                           system: "You write faithful, compact summaries of conversations, keeping every fact that matters.",
                                                           messages: [APIChatMessage(role: "user", text: request)],
                                                           maxOutputTokens: APIChat.roomForThinkingTokens) { _ in }
                    guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    // Turns may have come in meanwhile: only replace if the summed-up part is still the start.
                    let now = load(session)
                    guard now.count >= count, now.prefix(count).map(\.text) == before.prefix(count).map(\.text) else { return }
                    let nowPlain = now.map { ConversationCompaction.Message(role: $0.role, text: $0.text) }
                    let compacted = ConversationCompaction.replacing(nowPlain, firstCount: count, withSummary: summary)
                    save(compacted.map { APIChatMessage(role: $0.role, text: $0.text) }, session: session)
                    print("🧠 Summed up the first \(count) messages of a conversation on \(provider.label) (\(ConversationCompaction.totalCharacters(plain)) characters, room \(roomCharacters))")
                } catch {
                    print("🧠 Couldn't sum up a long conversation on \(provider.label): \(error.localizedDescription). Its newest part still goes with each turn.")
                }
            }
        }
    }

    /// A bot's turn: its persona as the system message, its memory file read in, the conversation so far, and its tools (its own
    /// memory folder and the hub apps it was given). `ownerAsked`: the turn came from the owner's own words; otherwise its apps read and draft at most.
    static func runBot(bot: NativeBot, prompt: String, session: String?, team: [NativeBot], ownerAsked: Bool,
                       onText: @escaping @MainActor (String) -> Void) async throws -> (text: String, session: String?) {
        let providerID = String(bot.provider.dropFirst("api:".count))
        guard let provider = await MainActor.run(body: { ProviderInfo.info(for: providerID) }) else {
            throw APIChatError.rejected("The provider \(providerID) is gone. Pick another engine in \(bot.name)'s settings.")
        }
        let key = ProviderKeychain.get(providerID)
        let id = session ?? UUID().uuidString.lowercased()
        var messages = History.load(id)
        messages.append(APIChatMessage(role: "user", text: prompt))
        var system = await MainActor.run { BotPrompts.persona(bot: bot, team: team) }
        let memory = (bot.memoryPath as NSString).expandingTildeInPath
        if let saved = try? String(contentsOfFile: memory, encoding: .utf8), !saved.isEmpty { system += "\n\nWhat you remember:\n\(saved.prefix(4000))" }
        let toolbox = await APIChatToolbox.make(for: bot, ownerAsked: ownerAsked, turnLimitSeconds: BotRunner.turnLimitSeconds)
        system += "\n\n" + toolbox.promptSection
        // As much of the chat as the model holds; the rest is in its summary.
        let room = await History.roomCharacters(provider: provider, model: bot.model, systemCharacters: system.count, wantedAnswerTokens: maxOutputTokens)
        let answer: String
        // Every request of the turn, tool rounds too, counts in the bot's usage like a Claude Code turn does. API prices aren't known here,
        // so these turns count tokens only.
        let usageMeter = APIUsageMeter()
        let botID = bot.id
        defer {
            let used = usageMeter.used
            Task { @MainActor in BotUsage.shared.record(botID: botID, usage: used) }
        }
        do {
            answer = try await stream(provider: provider, key: key, model: bot.model, system: system, messages: History.fitting(messages, roomCharacters: room),
                                      toolbox: toolbox, fast: bot.fast ?? false, usageMeter: usageMeter, onText: onText)
        } catch {
            await toolbox.finish()
            throw error
        }
        await toolbox.finish()
        guard !answer.isEmpty else { throw APIChatError.noAnswer(provider.label) }
        messages.append(APIChatMessage(role: "assistant", text: answer))
        History.save(messages, session: id)
        await History.compactLater(session: id, provider: provider, key: key, model: bot.model, roomCharacters: room)
        return (answer, id)
    }
}
