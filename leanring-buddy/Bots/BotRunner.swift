//
//  BotRunner.swift
//  leanring-buddy
//
//  Runs one bot turn on its engine: Claude Code (`claude -p`, streamed) or
//  OpenCode (`opencode run --format json`). The engine keeps the
//  conversation in its own session, so a follow-up only sends the new
//  message. On Claude a bot may only use reading tools, its own memory
//  file and the connectors of its apps; anything else is refused, since
//  nobody is there to approve it.
//

import ClickyCore
import Foundation

enum BotRunnerError: LocalizedError {
    case notInstalled(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let engine): return "\(engine) isn't installed on this Mac."
        case .failed(let message): return message
        }
    }
}

enum BotRunner {
    /// Where bots run: the folder that holds their memory files (~/.t3/bots), so reading and keeping
    /// memory never needs a permission nobody is there to give.
    static var workspace: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/bots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The Claude tools a bot may use without asking: reading and the web, its memory file, and the
    /// connectors of its own apps.
    static func claudeAllowedTools(for bot: NativeBot) -> [String] {
        let memoryFolder = "~/.t3/bots/\(bot.id)/**"
        var tools = ["Read", "Glob", "Grep", "WebSearch", "WebFetch", "Edit(\(memoryFolder))", "Write(\(memoryFolder))"]
        tools += BotConnectors.known.filter { bot.apps.contains($0.id) }.compactMap(\.claudeToolPrefix)
        return tools
    }

    /// Runs the turn; `onText` gets the reply so far as it streams in.
    static func run(bot: NativeBot, prompt: String, session: String?, team: [NativeBot],
                    onText: @escaping @MainActor (String) -> Void) async throws -> (text: String, session: String?) {
        let isClaude = bot.provider == "claude"
        let provider: BrainProvider = isClaude ? .claude : .opencode
        guard let executable = BrainCLIRunner.locateExecutable(for: provider) else {
            throw BotRunnerError.notInstalled(provider.displayName)
        }
        var arguments: [String]
        var newSessionID: String?
        if isClaude {
            arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--model", bot.model,
                         "--append-system-prompt", BotPrompts.persona(bot: bot, team: team),
                         "--allowedTools"] + claudeAllowedTools(for: bot)
            if let session { arguments += ["--resume", session] } else {
                let id = UUID().uuidString.lowercased()
                newSessionID = id
                arguments += ["--session-id", id]
            }
            arguments += ["--", prompt]
        } else {
            arguments = ["run", "-m", bot.model, "--format", "json", "--dir", workspace.path]
            if let effort = bot.effort, !effort.isEmpty { arguments += ["--variant", effort] }
            if let session { arguments += ["-s", session] }
            arguments += [prompt]
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["PWD"] = workspace.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        let errorLog = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Clicky/bots-\(provider.rawValue).log")
        try? FileManager.default.createDirectory(at: errorLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: errorLog.path) {
            FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        }
        let errorHandle = try? FileHandle(forWritingTo: errorLog)
        errorHandle?.seekToEndOfFile()
        process.standardError = errorHandle ?? FileHandle.nullDevice
        try process.run()

        var parser = BotStreamParser(isClaude: isClaude)
        for await line in lines(of: output.fileHandleForReading) where parser.consume(line) {
            let text = parser.text
            await onText(text)
        }
        process.waitUntilExit()
        try? errorHandle?.close()
        if let error = parser.error, parser.text.isEmpty { throw BotRunnerError.failed(error) }
        if parser.text.isEmpty && process.terminationStatus != 0 {
            throw BotRunnerError.failed("\(provider.displayName) stopped (exit \(process.terminationStatus)). " +
                                        "Details are in ~/Library/Logs/Clicky/bots-\(provider.rawValue).log.")
        }
        return (parser.text, parser.sessionID ?? newSessionID ?? session)
    }
}

extension BotRunner {
    /// The output's lines as they arrive. A bot turn can wait minutes (Theo waiting on Clicky's research),
    /// so it reads on the file handle's own callbacks rather than `bytes`, whose blocking reads would
    /// hold up the research helpers' readers in the meantime.
    static func lines(of handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let pending = PendingLine()
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    if let last = pending.finish() { continuation.yield(last) }
                    continuation.finish()
                    return
                }
                for line in pending.append(chunk) { continuation.yield(line) }
            }
        }
    }

    private final class PendingLine: @unchecked Sendable {
        private var buffer = Data()

        func append(_ chunk: Data) -> [String] {
            buffer.append(chunk)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }

        func finish() -> String? {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
    }
}

/// Reads an engine's JSON lines into the reply text. Only what the bot says is kept: reasoning,
/// tool calls and command output are skipped.
struct BotStreamParser {
    let isClaude: Bool
    private(set) var text = ""
    private(set) var sessionID: String?
    private(set) var error: String?
    /// A Claude reply can span several assistant messages around tool calls.
    private var messageHasText = false

    init(isClaude: Bool) { self.isClaude = isClaude }

    /// Returns true when the reply text changed.
    mutating func consume(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return false }
        return isClaude ? consumeClaude(type, event) : consumeOpenCode(type, event)
    }

    private mutating func consumeClaude(_ type: String, _ event: [String: Any]) -> Bool {
        if let id = event["session_id"] as? String { sessionID = id }
        switch type {
        case "stream_event":
            guard let inner = event["event"] as? [String: Any], let innerType = inner["type"] as? String else { return false }
            if innerType == "message_start" {
                messageHasText = false
                return false
            }
            guard innerType == "content_block_delta",
                  let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let chunk = delta["text"] as? String, !chunk.isEmpty else { return false }
            if !messageHasText && !text.isEmpty { text += "\n\n" }
            messageHasText = true
            text += chunk
            return true
        case "result":
            if event["is_error"] as? Bool == true {
                error = event["result"] as? String ?? "Claude reported an error."
                return false
            }
            if text.isEmpty, let result = event["result"] as? String {
                text = result
                return true
            }
            return false
        default:
            return false
        }
    }

    private mutating func consumeOpenCode(_ type: String, _ event: [String: Any]) -> Bool {
        if let id = event["sessionID"] as? String { sessionID = id }
        switch type {
        case "text":
            guard let part = event["part"] as? [String: Any], let chunk = part["text"] as? String else { return false }
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            text += (text.isEmpty ? "" : "\n\n") + trimmed
            return true
        case "error":
            let detail = (event["error"] as? [String: Any]).flatMap {
                ($0["data"] as? [String: Any])?["message"] as? String ?? $0["message"] as? String
            }
            error = detail ?? "OpenCode reported an error."
            return false
        default:
            return false
        }
    }
}
