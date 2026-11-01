//
//  BrainCLIRunner.swift
//  leanring-buddy
//
//  Runs one turn on a non-Claude brain (Codex, Cursor Agent, OpenCode):
//  writes the screenshots to a private temp folder, starts the CLI with the
//  instructions and the user's words, reads its JSON lines and hands the
//  answer text back exactly like ClaudeCodeBridge.runTurn does, so the
//  rest of Clicky (captions, tags, marks, boards, workers) doesn't change.
//

import ClickyCore
import Foundation

enum BrainCLIRunnerError: LocalizedError {
    case notInstalled(BrainProvider)
    case reported(BrainProvider, String)
    case noAnswer(BrainProvider, Int32, String)
    case stalled(BrainProvider)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let provider):
            return "\(provider.displayName) isn't installed (no \(provider.executableName) command)."
        case .reported(let provider, let message):
            return "\(provider.displayName): \(message)"
        case .noAnswer(let provider, let exitCode, let standardError):
            let hint = standardError.lowercased().contains("login") || standardError.lowercased().contains("auth")
                ? " Sign in with `\(provider.signInCommand)` in Terminal." : ""
            return "\(provider.displayName) exited (\(exitCode)) without an answer.\(hint) \(standardError.suffix(200))"
        case .stalled(let provider):
            return "\(provider.displayName) sent nothing for \(Int(BrainCLIRunner.stallSeconds)) seconds."
        }
    }
}

enum BrainCLIRunner {
    /// One-shot CLIs think before printing anything, so they get longer than Claude's stream.
    static let stallSeconds: TimeInterval = 120

    static func locateExecutable(for provider: BrainProvider) -> URL? {
        if provider == .claude { return ClaudeCodeBridge.locateClaudeCodeExecutable() }
        if provider == .api { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.opencode/bin", "\(home)/.cursor/bin"]
            .map { "\($0)/\(provider.executableName)" }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v \(provider.executableName)"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// `onStreamEvent` gets the same events Claude Code's stream-json gives (init, message start, text deltas,
    /// the result), so an AnswerSession reads this brain exactly like Claude.
    /// Claude Code resumes a session for an action task's follow-up turns; the one-shot CLIs get the
    /// earlier turns of the same session as text instead (screenshots aren't repeated).
    @MainActor private static var sessionHistories: [String: [(user: String, assistant: String)]] = [:]

    static func runTurn(model: BrainModel, systemPrompt: String, contentBlocks: [ClaudeContentBlock],
                        persistentSessionIdentifier: String? = nil,
                        onTextChunk: @MainActor @Sendable (String) -> Void,
                        onStreamEvent: (@MainActor @Sendable (CLIStreamEvent) -> Void)? = nil,
                        onProcessReady: (@MainActor @Sendable (ClaudeProcessOrigin) -> Void)? = nil) async throws -> ClaudeTurnResult {
        let startTime = Date()
        if model.provider == .api {
            return try await runAPITurn(model: model, systemPrompt: systemPrompt, contentBlocks: contentBlocks, persistentSessionIdentifier: persistentSessionIdentifier,
                                        startTime: startTime, onTextChunk: onTextChunk, onStreamEvent: onStreamEvent, onProcessReady: onProcessReady)
        }
        guard let executableURL = locateExecutable(for: model.provider) else { throw BrainCLIRunnerError.notInstalled(model.provider) }

        // Screenshots as files in a private folder, removed after the turn.
        let turnDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-brain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: turnDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: turnDirectory) }
        var imagePaths: [String] = []
        var textPieces: [String] = []
        for block in contentBlocks {
            switch block {
            case .text(let text):
                textPieces.append(text)
            case .jpegImage(let data), .pngImage(let data):
                let isPNG: Bool
                if case .pngImage = block { isPNG = true } else { isPNG = false }
                let imageURL = turnDirectory.appendingPathComponent("screen\(imagePaths.count + 1).\(isPNG ? "png" : "jpg")")
                try data.write(to: imageURL)
                imagePaths.append(imageURL.path)
            }
        }
        let workingDirectory = (try? ClaudeArgs.prepareSessionWorkingDirectory())?.path ?? turnDirectory.path
        let userText = textPieces.joined(separator: "\n\n")
        var promptUserText = userText
        if let persistentSessionIdentifier, let history = await sessionHistories[persistentSessionIdentifier], !history.isEmpty {
            let earlier = history.map { "USER:\n\($0.user)\n\nYOU REPLIED:\n\($0.assistant)" }.joined(separator: "\n\n")
            promptUserText = "<earlier_turns_of_this_task>\n\(earlier)\n</earlier_turns_of_this_task>\n\n\(userText)"
        }
        let prompt = BrainCLI.combinedPrompt(systemPrompt: systemPrompt, userText: promptUserText)
        let (arguments, stdinPrompt) = BrainCLI.arguments(for: model, imagePaths: imagePaths, workingDirectory: workingDirectory, prompt: prompt)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let outputPipe = Pipe()
        // stderr goes to a log file: an unread pipe would fill up and stall a chatty CLI.
        let errorLogURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/brain-\(model.provider.rawValue).log")
        try? FileManager.default.createDirectory(at: errorLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: errorLogURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorLogURL)
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorHandle
        process.standardInput = stdinPrompt == nil ? FileHandle.nullDevice : inputPipe
        print("🧠 \(model.provider.displayName) request: model \(model.modelIdentifier.isEmpty ? "default" : model.modelIdentifier), \(imagePaths.count) image(s)")
        try process.run()
        await onProcessReady?(ClaudeProcessOrigin(spawnDate: Date(), usedStandbyProcess: false, standbyOutcome: nil, retriedAfterBrokenPipe: false))
        await onStreamEvent?(.systemInit(model: model.setting))
        if let stdinPrompt {
            let promptData = Data(stdinPrompt.utf8)
            Task.detached {
                try? inputPipe.fileHandleForWriting.write(contentsOf: promptData)
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        let lastActivity = ActivityClock()
        let watchdog = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if lastActivity.secondsSince() > stallSeconds {
                    lastActivity.markStalled()
                    if process.isRunning { process.terminate() }
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            var answer = ""
            var finalText: String?
            var reportedError: String?
            var inputTokens = 0
            var outputTokens = 0
            var lineBuffer = Data()

            func handle(_ line: Data) async {
                for event in BrainCLI.parseLine(line, provider: model.provider) {
                    lastActivity.note()
                    switch event {
                    case .text(let text):
                        // Codex sends whole messages: keep them apart like paragraphs.
                        let delta = (model.provider == .codex && !answer.isEmpty ? "\n\n" : "") + text
                        if answer.isEmpty { await onStreamEvent?(.messageStart(id: UUID().uuidString)) }
                        answer += delta
                        await onStreamEvent?(.textDelta(delta))
                        let snapshot = answer
                        await onTextChunk(snapshot)
                    case .finalText(let text):
                        finalText = text
                    case .error(let message):
                        reportedError = message
                    case .tokens(let input, let output):
                        inputTokens += input
                        outputTokens += output
                    }
                }
            }

            for try await byte in outputPipe.fileHandleForReading.bytes {
                lastActivity.note()
                if byte == 0x0A {
                    await handle(lineBuffer)
                    lineBuffer.removeAll(keepingCapacity: true)
                } else {
                    lineBuffer.append(byte)
                }
            }
            if !lineBuffer.isEmpty { await handle(lineBuffer) }
            process.waitUntilExit()
            print("🧠 \(model.provider.displayName) finished: exit \(process.terminationStatus), \(answer.count) chars, \(String(format: "%.1f", Date().timeIntervalSince(startTime))) s")
            try Task.checkCancellation()
            if lastActivity.isStalled { throw BrainCLIRunnerError.stalled(model.provider) }

            let responseText = (finalText?.isEmpty == false ? finalText! : answer).trimmingCharacters(in: .whitespacesAndNewlines)
            if responseText.isEmpty {
                try? errorHandle.close()
                let standardError = (try? String(contentsOf: errorLogURL, encoding: .utf8)) ?? ""
                let failure: BrainCLIRunnerError = reportedError.map { .reported(model.provider, $0) }
                    ?? .noAnswer(model.provider, process.terminationStatus, standardError)
                // The session speaks the error like any failed answer.
                await onStreamEvent?(.result(text: failure.localizedDescription, isError: true, subtype: "error"))
                if onStreamEvent != nil { throw ClaudeCodeBridgeError.claudeCodeReportedError(failure.localizedDescription) }
                throw failure
            }
            if let finalText, finalText != answer {
                // A final result longer than what streamed: send the rest as one more delta.
                if finalText.hasPrefix(answer) {
                    let rest = String(finalText.dropFirst(answer.count))
                    if answer.isEmpty { await onStreamEvent?(.messageStart(id: UUID().uuidString)) }
                    if !rest.isEmpty { await onStreamEvent?(.textDelta(rest)) }
                }
                await onTextChunk(responseText)
            }
            if let persistentSessionIdentifier {
                await MainActor.run {
                    var history = sessionHistories[persistentSessionIdentifier] ?? []
                    history.append((userText, responseText))
                    sessionHistories[persistentSessionIdentifier] = Array(history.suffix(8))
                    if sessionHistories.count > 20 { sessionHistories.removeValue(forKey: sessionHistories.keys.first!) }
                }
            }
            await onStreamEvent?(.result(text: responseText, isError: false, subtype: "success"))
            let usage: [String: Any] = ["input_tokens": inputTokens, "output_tokens": outputTokens]
            return ClaudeTurnResult(text: responseText, resolvedModelIdentifier: model.setting, usage: usage,
                                    usageSummary: nil, duration: Date().timeIntervalSince(startTime))
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

extension BrainCLIRunner {
    /// One turn on the owner's API key: same events as a CLI, so the rest of Clicky doesn't change. The screenshots go
    /// with the user's words, and the model answers with the same tags.
    fileprivate static func runAPITurn(model: BrainModel, systemPrompt: String, contentBlocks: [ClaudeContentBlock], persistentSessionIdentifier: String?,
                                       startTime: Date, onTextChunk: @MainActor @Sendable (String) -> Void,
                                       onStreamEvent: (@MainActor @Sendable (CLIStreamEvent) -> Void)?,
                                       onProcessReady: (@MainActor @Sendable (ClaudeProcessOrigin) -> Void)?) async throws -> ClaudeTurnResult {
        let parts = model.modelIdentifier.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = await MainActor.run(body: { ProviderInfo.info(for: parts[0]) }) else {
            throw APIChatError.rejected("The model \(model.modelIdentifier) isn't set up. Pick another in Settings › Clicky.")
        }
        var words: [String] = []
        var images: [String] = []
        var imageTypes: [String] = []
        for block in contentBlocks {
            switch block {
            case .text(let text): words.append(text)
            case .jpegImage(let data):
                images.append(data.base64EncodedString())
                imageTypes.append("image/jpeg")
            case .pngImage(let data):
                images.append(data.base64EncodedString())
                imageTypes.append("image/png")
            }
        }
        var messages = persistentSessionIdentifier.map(APIChat.History.load) ?? []
        messages.append(APIChatMessage(role: "user", text: words.joined(separator: "\n\n"), imagesJPEGBase64: images, imageTypes: imageTypes))
        await onProcessReady?(ClaudeProcessOrigin(spawnDate: Date(), usedStandbyProcess: false, standbyOutcome: nil, retriedAfterBrokenPipe: false))
        await onStreamEvent?(.systemInit(model: model.setting))
        let answerBox = StreamedAnswer()
        let answer = try await APIChat.stream(provider: provider, key: ProviderKeychain.get(parts[0]), model: parts[1], system: systemPrompt, messages: messages) { soFar in
            if answerBox.text.isEmpty { onStreamEvent?(.messageStart(id: UUID().uuidString)) }
            // By scalars, not characters: a Hindi vowel sign arriving on its own chunk joins the character before it.
            let delta = String(String.UnicodeScalarView(soFar.unicodeScalars.dropFirst(answerBox.text.unicodeScalars.count)))
            answerBox.text = soFar
            if !delta.isEmpty { onStreamEvent?(.textDelta(delta)) }
            onTextChunk(soFar)
        }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw APIChatError.noAnswer(provider.label) }
        if let persistentSessionIdentifier {
            messages.append(APIChatMessage(role: "assistant", text: text))
            APIChat.History.save(messages, session: persistentSessionIdentifier)
        }
        await onStreamEvent?(.result(text: text, isError: false, subtype: "success"))
        return ClaudeTurnResult(text: text, resolvedModelIdentifier: model.setting, usage: [:], usageSummary: nil, duration: Date().timeIntervalSince(startTime))
    }

    /// The answer so far, for working out each delta inside a main-actor callback.
    @MainActor private final class StreamedAnswer {
        var text = ""
    }
}

/// When the CLI last printed anything (the stall watchdog reads it from another task).
private final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var stalled = false

    func note() { lock.lock(); last = Date(); lock.unlock() }
    func secondsSince() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    func markStalled() { lock.lock(); stalled = true; lock.unlock() }
    var isStalled: Bool { lock.lock(); defer { lock.unlock() }; return stalled }
}
