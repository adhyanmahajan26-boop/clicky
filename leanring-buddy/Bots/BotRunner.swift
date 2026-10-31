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
    case freeLimit

    var errorDescription: String? {
        switch self {
        case .notInstalled(let engine): return "\(engine) isn't installed on this Mac."
        case .failed(let message): return message
        case .freeLimit: return "OpenCode's free models have hit their usage limit."
        }
    }
}

/// Claude sessions of the Haiku stand-in, by bot and OpenCode session (kept while Theo runs).
final class FallbackSessions: @unchecked Sendable {
    static let shared = FallbackSessions()
    private let lock = NSLock()
    private var sessions: [String: String] = [:]
    func get(_ key: String) -> String? { lock.withLock { sessions[key] } }
    func set(_ key: String, _ value: String) { lock.withLock { sessions[key] = value } }
}

/// The engine process behind each bot's reply in progress, so a reply can be stopped.
final class BotProcesses: @unchecked Sendable {
    static let shared = BotProcesses()
    private let lock = NSLock()
    private var running: [String: Process] = [:]

    func set(_ botID: String, _ process: Process) { lock.withLock { running[botID] = process } }
    func remove(_ botID: String, _ process: Process) {
        lock.withLock { if running[botID] === process { running[botID] = nil } }
    }
    /// Stops the bot's reply; false when nothing was running.
    @discardableResult func stop(_ botID: String) -> Bool {
        guard let process = lock.withLock({ running.removeValue(forKey: botID) }), process.isRunning else { return false }
        process.terminate()
        return true
    }
}

enum BotRunner {
    /// The longest one bot turn may take.
    static let turnLimitSeconds: Double = 420

    /// Where bots run: the folder that holds their memory files (~/.t3/bots), so reading and keeping
    /// memory never needs a permission nobody is there to give.
    static var workspace: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/bots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Theo's MCP tools a bot may use on its own.
    static let theoBotTools = ["claudia_research", "claudia_app", "claudia_attachments", "claudia_status"]

    /// The Claude tools a bot may use without asking: reading and the web, its memory file, and the
    /// connectors of its own apps.
    static func claudeAllowedTools(for bot: NativeBot) -> [String] {
        let memoryFolder = "~/.t3/bots/\(bot.id)/**"
        var tools = ["Read", "Glob", "Grep", "WebSearch", "WebFetch", "Edit(\(memoryFolder))", "Write(\(memoryFolder))"]
        for connector in BotConnectors.known where bot.apps.contains(connector.id) {
            if connector.id == "theo" {
                // Research, notes and the app bridge; never the screen or Theo's voice, with nobody watching.
                tools += theoBotTools.map { "mcp__plugin_theo_theo__\($0)" }
            } else if let prefix = connector.claudeToolPrefix {
                tools.append(prefix)
            }
        }
        return tools
    }

    /// Connector tools a bot never runs on its own, since nobody is there to say yes: sending, replying,
    /// forwarding, deleting, sharing, spam and cancelling. Drafts and new pages are fine.
    static let irreversibleTools = ConnectorBridge.writeTools.filter { name in
        ["send", "reply", "forward", "trash", "delete", "spam", "share", "cancel", "clear"].contains { name.contains($0) }
    } + ["CronCreate", "CronDelete", "CronList", "ScheduleWakeup", "RemoteTrigger", "Skill"]

    /// Runs the turn; `onText` gets the reply so far as it streams in.
    static func run(bot: NativeBot, prompt: String, session: String?, team: [NativeBot],
                    onText: @escaping @MainActor (String) -> Void) async throws -> (text: String, session: String?) {
        do {
            return try await runOnEngine(bot: bot, prompt: prompt, session: session, team: team, onText: onText)
        } catch BotRunnerError.freeLimit {
            // OpenCode's free models are used up for now: this turn runs on Claude Haiku instead, so the
            // bot still answers. Its OpenCode session stays for when the free models are back.
            var standIn = bot
            standIn.provider = "claude"
            standIn.model = fallbackModel
            standIn.effort = nil
            standIn.thinking = nil
            standIn.fast = nil
            // Claude gets the persona as its system prompt; drop the copy an OpenCode first message carries.
            var claudePrompt = prompt
            if let range = prompt.range(of: "\n\n---\n\n"), prompt.hasPrefix(bot.instructions) {
                claudePrompt = String(prompt[range.upperBound...])
            }
            // The stand-in keeps its own Claude session per OpenCode session, so follow-ups keep their context.
            let key = "\(bot.id)#\(session ?? "new")"
            let standInSession = FallbackSessions.shared.get(key)
            let result = try await runOnEngine(bot: standIn, prompt: claudePrompt, session: standInSession, team: team, onText: onText)
            if let claudeSession = result.session { FallbackSessions.shared.set(key, claudeSession) }
            return (result.text + "\n\n_(OpenCode's free models hit their usage limit, so this reply came from Claude Haiku.)_", session)
        }
    }

    static let fallbackModel = "claude-haiku-5-5"

    /// OpenCode logs "Free usage limit reached" and keeps retrying without printing anything, so a turn
    /// would sit there until the time limit. This checks its log for that error since `start`.
    static func openCodeHitFreeLimit(since start: Date) -> Bool {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/log/opencode.log")
        guard let handle = try? FileHandle(forReadingFrom: log) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let since = ISO8601DateFormatter().string(from: start)
        return tail.split(separator: "\n").contains { line in
            guard line.contains("Free usage limit reached"), let stamp = line.split(separator: " ").first?
                .replacingOccurrences(of: "timestamp=", with: "") else { return false }
            return String(stamp.prefix(19)) >= String(since.prefix(19))
        }
    }

    private static func runOnEngine(bot: NativeBot, prompt: String, session: String?, team: [NativeBot],
                                    onText: @escaping @MainActor (String) -> Void) async throws -> (text: String, session: String?) {
        if bot.provider == "grok" { return try await runGrok(bot: bot, prompt: prompt, session: session, team: team) }
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
                         // Only the allowed tools run: the user's own permission mode (auto) mustn't widen it.
                         "--permission-mode", "dontAsk",
                         "--append-system-prompt", BotPrompts.persona(bot: bot, team: team),
                         "--allowedTools"] + claudeAllowedTools(for: bot) + ["--disallowedTools"] + irreversibleTools
            if let effort = bot.effort, !effort.isEmpty { arguments += ["--effort", effort] }
            var settings: [String: Bool] = [:]
            if let thinking = bot.thinking { settings["alwaysThinkingEnabled"] = thinking }
            if let fast = bot.fast { settings["fastMode"] = fast }
            if !settings.isEmpty, let data = try? JSONSerialization.data(withJSONObject: settings, options: .sortedKeys),
               let json = String(data: data, encoding: .utf8) {
                arguments += ["--settings", json]
            }
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
        BotProcesses.shared.set(bot.id, process)
        defer { BotProcesses.shared.remove(bot.id, process) }
        // A turn that runs past the limit is stopped, so one stuck bot can't hold up the Project room.
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(turnLimitSeconds * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }
        let started = Date()
        let limitCheck = Task.detached {
            guard !isClaude else { return false }
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !process.isRunning { return false }
                if openCodeHitFreeLimit(since: started) {
                    process.terminate()
                    return true
                }
            }
            return false
        }

        var parser = BotStreamParser(isClaude: isClaude)
        for await line in lines(of: output.fileHandleForReading) where parser.consume(line) {
            let text = parser.text
            await onText(text)
        }
        process.waitUntilExit()
        try? errorHandle?.close()
        if parser.text.isEmpty, await limitCheck.value { throw BotRunnerError.freeLimit }
        limitCheck.cancel()
        if let error = parser.error, parser.text.isEmpty { throw BotRunnerError.failed(error) }
        if parser.text.isEmpty && process.terminationStatus != 0 {
            throw BotRunnerError.failed("\(provider.displayName) stopped (exit \(process.terminationStatus)). " +
                                        "Details are in ~/Library/Logs/Clicky/bots-\(provider.rawValue).log.")
        }
        return (parser.text, parser.sessionID ?? newSessionID ?? session)
    }
}

extension BotRunner {
    /// Grok's CLI (grok.com sign-in), headless: one JSON reply per turn, continued with --resume.
    static var grokExecutable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".grok/bin/grok", ".local/bin/grok"].map { home.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Adds Theo's MCP server to Grok's own config (~/.grok/config.toml), once. A project config isn't
    /// enough: Grok only loads a folder's servers once that folder is trusted, which needs a person.
    static func ensureGrokTheoServer() {
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/config.toml")
        let current = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        guard !current.contains("[mcp_servers.theo]"), let executable = Bundle.main.executableURL?.path else { return }
        let entry = "\n[mcp_servers.theo]\ncommand = \"\(executable)\"\nargs = [\"--mcp\"]\nenabled = true\n"
        try? (current + entry).write(to: config, atomically: true, encoding: .utf8)
    }

    /// Grok may read and search the web, nothing else, since nobody is there to approve more.
    static let grokTools = "web_search,web_fetch,read_file,grep,list_dir"

    static func runGrok(bot: NativeBot, prompt: String, session: String?, team: [NativeBot]) async throws -> (text: String, session: String?) {
        guard let executable = grokExecutable else { throw BotRunnerError.notInstalled("Grok") }
        let fullPrompt = session == nil ? BotPrompts.persona(bot: bot, team: team) + "\n\n" + prompt : prompt
        var arguments = ["-p", fullPrompt, "-m", bot.model, "--output-format", "streaming-messages-json",
                         "--permission-mode", "dontAsk", "--tools", grokTools, "--no-subagents"]
        if let effort = bot.effort, !effort.isEmpty { arguments += ["--reasoning-effort", effort] }
        if !bot.apps.isEmpty {
            // Theo's MCP server (apps through claudia_app, research, screen) in the bots folder's Grok config.
            ensureGrokTheoServer()
            arguments += theoBotTools.flatMap { ["--allow", "mcp__theo__\($0)"] }
        }
        if let session { arguments += ["--resume", session] }
        let data: Data = try await Task.detached {
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
            let errorLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/bots-grok.log")
            if !FileManager.default.fileExists(atPath: errorLog.path) { FileManager.default.createFile(atPath: errorLog.path, contents: nil) }
            let errorHandle = try? FileHandle(forWritingTo: errorLog)
            errorHandle?.seekToEndOfFile()
            process.standardError = errorHandle ?? FileHandle.nullDevice
            defer { try? errorHandle?.close() }
            process.standardInput = FileHandle.nullDevice
            try process.run()
            BotProcesses.shared.set(bot.id, process)
            defer { BotProcesses.shared.remove(bot.id, process) }
            let watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(turnLimitSeconds * 1_000_000_000))
                if process.isRunning { process.terminate() }
            }
            defer { watchdog.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
        // Only the final message is the reply; the notes Grok writes between tool calls are left out.
        var text: String?
        var newSession = session
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let id = event["session_id"] as? String { newSession = id }
            if event["type"] as? String == "result", event["is_error"] as? Bool != true { text = event["result"] as? String }
        }
        guard let text, !text.isEmpty else {
            throw BotRunnerError.failed("Grok didn't answer: \(String(decoding: data.suffix(200), as: UTF8.self))")
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), newSession)
    }

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
