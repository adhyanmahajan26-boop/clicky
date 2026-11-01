//
//  APIChat.swift
//  leanring-buddy
//
//  Talks to a model straight over HTTP with the owner's key, streaming the answer: Anthropic's Messages API, and the
//  OpenAI-style chat endpoint everyone else offers. Bots, Theo and Clicky all run on it when their engine is
//  "api:<provider>". There are no tools on this path: the model answers in words (and Theo's tags), which is why a run
//  on a harness is still the way to change code.
//

import Foundation

enum APIChatError: LocalizedError {
    case noKey(String)
    case rejected(String)
    case noAnswer(String)

    var errorDescription: String? {
        switch self {
        case .noKey(let provider): return "\(provider) needs an API key. Add it in Settings › Models & API keys."
        case .rejected(let message): return message
        case .noAnswer(let provider): return "\(provider) returned no answer."
        }
    }
}

struct APIChatMessage: Codable, Equatable {
    var role: String
    var text: String
    /// Images for this message only; earlier screenshots aren't sent again.
    var imagesJPEGBase64: [String] = []
}

enum APIChat {
    static let maxOutputTokens = 8192

    /// The request for one turn. Pure, so it can be tested without the network.
    static func request(provider: ProviderInfo, key: String?, model: String, system: String, messages: [APIChatMessage]) -> URLRequest? {
        switch provider.kind {
        case .anthropic:
            guard let url = URL(string: provider.baseURL + "/messages") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 300)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ProviderInfo.authorize(&request, provider: provider, key: key)
            let body: [String: Any] = ["model": model, "max_tokens": maxOutputTokens, "stream": true, "system": system,
                                       "messages": messages.map(anthropicMessage)]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
        case .openAICompatible:
            guard let url = URL(string: provider.baseURL + "/chat/completions") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 300)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ProviderInfo.authorize(&request, provider: provider, key: key)
            var all: [[String: Any]] = system.isEmpty ? [] : [["role": "system", "content": system]]
            all += messages.map(openAIMessage)
            let body: [String: Any] = ["model": model, "stream": true, "messages": all]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
        case .other:
            return nil
        }
    }

    private static func anthropicMessage(_ message: APIChatMessage) -> [String: Any] {
        guard !message.imagesJPEGBase64.isEmpty else { return ["role": message.role, "content": message.text] }
        var content: [[String: Any]] = message.imagesJPEGBase64.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0]]
        }
        content.append(["type": "text", "text": message.text])
        return ["role": message.role, "content": content]
    }

    private static func openAIMessage(_ message: APIChatMessage) -> [String: Any] {
        guard !message.imagesJPEGBase64.isEmpty else { return ["role": message.role, "content": message.text] }
        var content: [[String: Any]] = [["type": "text", "text": message.text]]
        content += message.imagesJPEGBase64.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0)"]] }
        return ["role": message.role, "content": content]
    }

    /// The text in one server-sent line ("data: {…}"), if any; `done` when the stream says it has ended.
    static func parse(line: String, kind: ProviderInfo.Protocol_) -> (text: String?, done: Bool, error: String?) {
        guard line.hasPrefix("data:") else { return (nil, false, nil) }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return (nil, true, nil) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return (nil, false, nil) }
        if let error = object["error"] as? [String: Any] { return (nil, true, error["message"] as? String ?? "The provider reported an error.") }
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

    /// Runs one turn and returns the whole answer; `onText` gets the answer so far as it grows.
    static func stream(provider: ProviderInfo, key: String?, model: String, system: String, messages: [APIChatMessage],
                       onText: @MainActor (String) -> Void) async throws -> String {
        guard key != nil || provider.keyless || provider.group == .custom else { throw APIChatError.noKey(provider.label) }
        guard let request = request(provider: provider, key: key, model: model, system: system, messages: messages) else {
            throw APIChatError.rejected("\(provider.label) can't be used for chat.")
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            var body = Data()
            for try await byte in bytes where body.count < 4000 { body.append(byte) }
            throw APIChatError.rejected("\(provider.label): " + (ProviderInfo.testFailure(statusCode: status, body: body) ?? "HTTP \(status)"))
        }
        var answer = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let parsed = parse(line: line, kind: provider.kind)
            if let error = parsed.error { throw APIChatError.rejected("\(provider.label): \(error)") }
            if let text = parsed.text, !text.isEmpty {
                answer += text
                let soFar = answer
                await onText(soFar)
            }
            if parsed.done { break }
        }
        return answer
    }

    // MARK: Conversations

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
            // Screenshots aren't kept; the words are, within reason.
            let trimmed = messages.suffix(60).map { APIChatMessage(role: $0.role, text: $0.text) }
            try? JSONEncoder().encode(Array(trimmed)).write(to: folder.appendingPathComponent("\(session).json"), options: .atomic)
        }
    }

    /// A bot's turn: its persona as the system message, its memory file read in, the conversation so far.
    static func runBot(bot: NativeBot, prompt: String, session: String?, team: [NativeBot],
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
        let answer = try await stream(provider: provider, key: key, model: bot.model, system: system, messages: messages, onText: onText)
        guard !answer.isEmpty else { throw APIChatError.noAnswer(provider.label) }
        messages.append(APIChatMessage(role: "assistant", text: answer))
        History.save(messages, session: id)
        return (answer, id)
    }
}
