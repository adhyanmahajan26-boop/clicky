//
//  HarnessBotEngines.swift
//  leanring-buddy
//
//  Headless bot engines for Codex (ChatGPT subscription), Cursor Agent and Gemini CLI, next to the Claude,
//  OpenCode and Grok ones in BotRunner. Bots are read-only here (Codex's read-only sandbox, Cursor's ask
//  mode): nobody is there to approve anything.
//

import Foundation

extension BotRunner {
    /// Removes the variables that would make an engine think it runs inside another Claude session.
    static func scrubClaudeEnvironment(_ environment: inout [String: String]) {
        for key in environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK") {
            environment[key] = nil
        }
    }

    /// The engines in this file, by `bot.provider`; nil for the others.
    static func runHarnessEngine(bot: NativeBot, prompt: String, session: String?, team: [NativeBot],
                                 onText: @escaping @MainActor (String) -> Void) async throws -> (text: String, session: String?)? {
        switch bot.provider {
        case "codex": return try await runCodex(bot: bot, prompt: prompt, session: session, team: team, onText: onText)
        case "cursor": return try await runCursor(bot: bot, prompt: prompt, session: session, team: team, onText: onText)
        case "gemini": return try await runGemini(bot: bot, prompt: prompt, team: team)
        default: return nil
        }
    }

    // MARK: Usage limits

    /// "Codex's ChatGPT usage limit is reached; it resets …", or nil when the output shows no limit.
    static func usageLimitMessage(engine: String, output: String) -> String? {
        let pattern: String
        let plan: String
        switch engine {
        case "codex":
            pattern = #"(hit|reached) your usage limit|usage limit (reached|exceeded)|quota exceeded"#
            plan = "Codex's ChatGPT"
        case "cursor":
            pattern = #"out of usage|increase your limit"#
            plan = "Cursor's"
        default: return nil
        }
        guard output.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        var reset = ""
        if let range = output.range(of: #"(try again|resets?|available again)[^.\n"]*"#, options: [.regularExpression, .caseInsensitive]) {
            let phrase = String(output[range]).trimmingCharacters(in: .whitespaces)
            reset = "; " + (phrase.lowercased().hasPrefix("try again") ? "try again" + phrase.dropFirst(9) : phrase.prefix(1).lowercased() + phrase.dropFirst())
        } else {
            reset = "; it resets later"
        }
        return "\(plan) usage limit is reached\(reset)."
    }

    // MARK: Process plumbing

    struct EngineExit {
        var status: Int32
        /// What the engine wrote to its log (stderr) during this turn.
        var logTail: String
    }

    /// Starts an engine, feeds each stdout line to `onLine`, and waits for it. Registered with BotProcesses
    /// (the stop button) and stopped at the turn limit.
    static func spawnEngine(botID: String, executable: URL, arguments: [String], logName: String,
                            extraEnvironment: [String: String] = [:],
                            onLine: (String) async -> Void) async throws -> EngineExit {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        var environment = HarnessCatalog.childEnvironment(extra: extraEnvironment)
        environment["PWD"] = workspace.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/bots-\(logName).log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let errorHandle = try? FileHandle(forWritingTo: log)
        let startOffset = errorHandle?.seekToEndOfFile() ?? 0
        process.standardError = errorHandle ?? FileHandle.nullDevice
        try process.run()
        BotProcesses.shared.set(botID, process)
        defer { BotProcesses.shared.remove(botID, process) }
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(turnLimitSeconds * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }
        for await line in lines(of: output.fileHandleForReading) { await onLine(line) }
        process.waitUntilExit()
        try? errorHandle?.close()
        var tail = ""
        if let reader = try? FileHandle(forReadingFrom: log) {
            defer { try? reader.close() }
            try? reader.seek(toOffset: startOffset)
            tail = String(decoding: reader.readDataToEndOfFile().suffix(8000), as: UTF8.self)
        }
        return EngineExit(status: process.terminationStatus, logTail: tail)
    }

    private static func json(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    // MARK: Codex

    static func runCodex(bot: NativeBot, prompt: String, session: String?, team: [NativeBot],
                         onText: @escaping @MainActor (String) -> Void) async throws -> (text: String, session: String?) {
        guard let executable = HarnessCatalog.executable(for: "codex") else { throw BotRunnerError.notInstalled("Codex") }
        let reply = FileManager.default.temporaryDirectory.appendingPathComponent("theo-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: reply) }
        let effort = bot.effort.flatMap { $0.isEmpty ? nil : $0 }
        var common = ["--json", "--skip-git-repo-check", "-m", bot.model]
        if let effort { common += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        common += ["-c", "check_for_update_on_startup=false"]
        var arguments: [String]
        if let session {
            // `exec resume` has no -C / -s: the folder is the process's, the sandbox a config override.
            arguments = ["exec", "resume"] + common + ["-c", "sandbox_mode=\"read-only\"", "-o", reply.path, "--", session, prompt]
        } else {
            let first = BotPrompts.persona(bot: bot, team: team) + "\n\n" + prompt
            arguments = ["exec"] + common + ["-C", workspace.path, "-s", "read-only", "-o", reply.path, "--", first]
        }
        var newSession = session
        var text = ""
        var failure: String?
        var seen = ""
        let exit = try await spawnEngine(botID: bot.id, executable: executable, arguments: arguments, logName: "codex") { line in
            seen += line + "\n"
            guard let event = json(line), let type = event["type"] as? String else { return }
            switch type {
            case "thread.started":
                if let id = event["thread_id"] as? String { newSession = id }
            case "item.completed":
                // Only the agent's messages are the reply; "error" items are warnings (e.g. a model mismatch on resume).
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let message = item["text"] as? String, !message.isEmpty {
                    text = message
                    await onText(text)
                }
            case "turn.failed":
                failure = ((event["error"] as? [String: Any])?["message"] as? String) ?? "Codex reported an error."
            case "error":
                failure = event["message"] as? String ?? failure
            default: break
            }
        }
        if text.isEmpty, let saved = try? String(contentsOf: reply, encoding: .utf8) {
            text = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.isEmpty {
            if let limit = usageLimitMessage(engine: "codex", output: seen + (failure ?? "") + exit.logTail) { throw BotRunnerError.usageLimit(limit) }
            if let failure { throw BotRunnerError.failed(failure) }
            throw BotRunnerError.failed("Codex stopped (exit \(exit.status)). Details are in ~/Library/Logs/Clicky/bots-codex.log.")
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), newSession)
    }

    // MARK: Cursor

    static func runCursor(bot: NativeBot, prompt: String, session: String?, team: [NativeBot],
                          onText: @escaping @MainActor (String) -> Void) async throws -> (text: String, session: String?) {
        guard let executable = HarnessCatalog.executable(for: "cursor") else { throw BotRunnerError.notInstalled("Cursor Agent") }
        let fullPrompt = session == nil ? BotPrompts.persona(bot: bot, team: team) + "\n\n" + prompt : prompt
        // ask mode is read-only; the effort is part of the model id (e.g. "gpt-5.2-high"), so there is no flag for it.
        var arguments = ["-p", "--output-format", "stream-json", "--stream-partial-output", "--model", bot.model,
                         "--trust", "--mode", "ask", "--workspace", workspace.path]
        if let session { arguments += ["--resume", session] }
        arguments += [fullPrompt]
        var newSession = session
        var streamed = ""
        var final: String?
        var failure: String?
        var sawDelta = false
        var toolSinceText = false
        var seen = ""
        let exit = try await spawnEngine(botID: bot.id, executable: executable, arguments: arguments, logName: "cursor") { line in
            seen += line + "\n"
            guard let event = json(line), let type = event["type"] as? String else { return }
            if let id = event["session_id"] as? String, !id.isEmpty { newSession = id }
            switch type {
            case "assistant":
                guard let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return }
                let chunk = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                guard !chunk.isEmpty else { return }
                // With --stream-partial-output, deltas carry timestamp_ms; the whole message repeats at the end without one.
                if event["timestamp_ms"] != nil {
                    sawDelta = true
                } else if sawDelta {
                    return
                }
                if toolSinceText && !streamed.isEmpty { streamed += "\n\n" }
                toolSinceText = false
                streamed += chunk
                await onText(streamed)
            case "tool_call":
                if !streamed.isEmpty { toolSinceText = true }
            case "result":
                if event["is_error"] as? Bool == true || (event["subtype"] as? String).map({ $0 != "success" }) == true {
                    failure = event["result"] as? String ?? "Cursor reported an error."
                } else if let result = event["result"] as? String, !result.isEmpty {
                    final = result
                }
            default: break
            }
        }
        let text = (final ?? streamed).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || failure != nil {
            if let limit = usageLimitMessage(engine: "cursor", output: seen + (failure ?? "") + exit.logTail) { throw BotRunnerError.usageLimit(limit) }
            if text.isEmpty {
                let detail = failure ?? (exit.logTail.isEmpty ? seen : exit.logTail)
                throw BotRunnerError.failed("Cursor Agent didn't answer (exit \(exit.status)): \(detail.suffix(200))")
            }
        }
        return (text, newSession)
    }

    // MARK: Gemini

    static func runGemini(bot: NativeBot, prompt: String, team: [NativeBot]) async throws -> (text: String, session: String?) {
        guard let executable = HarnessCatalog.executable(for: "gemini") else { throw BotRunnerError.notInstalled("Gemini CLI") }
        // No session id to resume with, so every turn carries the persona.
        let fullPrompt = BotPrompts.persona(bot: bot, team: team) + "\n\n" + prompt
        var arguments = ["-p", fullPrompt, "--output-format", "json"]
        if !bot.model.isEmpty { arguments += ["-m", bot.model] }
        var raw = ""
        let exit = try await spawnEngine(botID: bot.id, executable: executable, arguments: arguments, logName: "gemini") { line in
            raw += line + "\n"
        }
        var text: String?
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
           let object = json(String(raw[start...end])) {
            text = object["response"] as? String
        }
        guard let text, !text.isEmpty else {
            throw BotRunnerError.failed("Gemini CLI didn't answer (exit \(exit.status)): \((exit.logTail.isEmpty ? raw : exit.logTail).suffix(200))")
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
}
