//
//  ClaudeCodeBridge.swift
//  leanring-buddy
//
//  Talks to Claude through the locally installed Claude Code CLI instead of
//  the Anthropic API, so requests run on the user's Claude subscription and
//  no API key is needed. Each request launches `claude -p` in headless
//  stream-json mode (arguments from ClickyCore's ClaudeArgs, shared with
//  workers and probes) — or, P6.3, takes the one pre-spawned at key-down
//  when it was launched with the same settings (StandbyCLISlot) — writes
//  ONE user message to its stdin and closes it,
//  and reads streamed events from stdout, split on 0x0A only (LineReader:
//  a U+2028 inside a delta must not break the JSON line). Every event is
//  passed to `onStreamEvent`; 25 s without a text delta ends the request.
//
//  The message is: a text block (history + what the user said), then for
//  each screen its SCREEN header text followed by its JPEG.
//

import ClickyCore
import Foundation

enum ClaudeCodeBridgeError: LocalizedError {
    case claudeCodeNotInstalled
    case claudeCodeReportedError(String)
    case claudeCodeExitedWithoutResult(exitCode: Int32, standardErrorOutput: String)
    case claudeCodeStalled

    var errorDescription: String? {
        switch self {
        case .claudeCodeNotInstalled:
            return "Claude Code isn't installed. Install it, then run `claude auth login` in Terminal."
        case .claudeCodeReportedError(let message):
            return "Claude Code error: \(message)"
        case .claudeCodeExitedWithoutResult(let exitCode, let standardErrorOutput):
            return "Claude Code exited (\(exitCode)) without an answer. \(standardErrorOutput)"
        case .claudeCodeStalled:
            return "Claude Code sent nothing for \(Int(CLIStreamFailure.stallSeconds)) seconds."
        }
    }
}

/// One piece of the user message.
enum ClaudeContentBlock {
    case text(String)
    case jpegImage(Data)
    /// P6.1 zoom check: one lossless crop.
    case pngImage(Data)

    var isImage: Bool {
        switch self {
        case .text: return false
        case .jpegImage, .pngImage: return true
        }
    }
}

/// How a request's CLI process came to be (turn.json `cli`, P6.3).
struct ClaudeProcessOrigin: Sendable {
    let spawnDate: Date
    /// The pre-spawned process was used (no CLI start-up after key-up).
    let usedStandbyProcess: Bool
    /// What the standby slot said; nil when the request didn't ask for it.
    let standbyOutcome: StandbyCLISlot.TakeOutcome?
    let retriedAfterBrokenPipe: Bool
}

struct ClaudeTurnResult {
    let text: String
    /// The model id the CLI resolved the alias to (from its system/init event).
    let resolvedModelIdentifier: String?
    /// The `usage` object from the final result event.
    let usage: [String: Any]
    /// Tokens and `total_cost_usd` from the final result event, for turn.json
    /// and the Agents dashboard (nil when the result had neither).
    let usageSummary: AgentUsage?
    let duration: TimeInterval
}

final class ClaudeCodeBridge {
    /// Claude Code model alias ("sonnet", "opus", "haiku") or a full model ID.
    /// Aliases always resolve to the newest model of that family.
    var model: String

    /// Whether image blocks carry `"transformations":{"oversized_image":"error"}`
    /// (fail loudly instead of being silently downscaled). Set from the
    /// transportProbe result (c); see docs/v2/PROBES.md.
    static var sendsOversizedImageErrorTransformation = false

    /// $TMPDIR/clicky-session is recreated empty once per launch; calls run
    /// concurrently (workers), so it is never deleted while one is running.
    private static let sessionWorkingDirectoryURL: URL = {
        (try? ClaudeArgs.prepareSessionWorkingDirectory()) ?? ClaudeArgs.sessionWorkingDirectoryURL
    }()

    /// The pre-spawned process waiting for this bridge's next request (P6.3).
    let standbySlot = StandbyCLISlot(idleLimitSeconds: ClaudeCodeBridge.standbyIdleLimitSeconds)
    /// A pre-spawned process not used within this long is reaped.
    static let standbyIdleLimitSeconds: TimeInterval = 60

    init(model: String = "sonnet") {
        self.model = model
    }

    // MARK: - Locating the CLI

    /// Apps launched from Xcode or Finder don't inherit the user's shell PATH,
    /// so we check the usual install locations first and fall back to asking
    /// a login shell where `claude` lives.
    static func locateClaudeCodeExecutable() -> URL? {
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let commonInstallPaths = [
            "\(homeDirectoryPath)/.local/bin/claude",
            "\(homeDirectoryPath)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]

        for installPath in commonInstallPaths where FileManager.default.isExecutableFile(atPath: installPath) {
            return URL(fileURLWithPath: installPath)
        }

        let loginShellProcess = Process()
        loginShellProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        loginShellProcess.arguments = ["-lc", "command -v claude"]
        let loginShellOutputPipe = Pipe()
        loginShellProcess.standardOutput = loginShellOutputPipe
        loginShellProcess.standardError = FileHandle.nullDevice

        do {
            try loginShellProcess.run()
            loginShellProcess.waitUntilExit()
        } catch {
            return nil
        }

        let loginShellOutputData = loginShellOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let resolvedPath = String(data: loginShellOutputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !resolvedPath.isEmpty, FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            return nil
        }
        return URL(fileURLWithPath: resolvedPath)
    }

    /// The launch a request with these settings uses (writes the prompt file).
    func makeLaunchSpec(systemPromptFileName: String, systemPrompt: String, effortLevel: String?,
                        persistentSessionIdentifier: String? = nil, maximumTurns: Int? = nil) throws -> CLILaunchSpec {
        guard let claudeCodeExecutableURL = Self.locateClaudeCodeExecutable() else {
            throw ClaudeCodeBridgeError.claudeCodeNotInstalled
        }
        let systemPromptFileURL = try ClaudeArgs.writePromptFile(named: systemPromptFileName, contents: systemPrompt)
        let claudeArgs = ClaudeArgs(
            model: model,
            systemPromptFileURL: systemPromptFileURL,
            effortLevel: effortLevel,
            persistentSessionIdentifier: persistentSessionIdentifier,
            maximumTurns: maximumTurns
        )
        let workingDirectoryURL = Self.sessionWorkingDirectoryURL
        try? FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
        return CLILaunchSpec(executableURL: claudeCodeExecutableURL, arguments: claudeArgs.arguments, environment: ClaudeArgs.environment(),
                             workingDirectoryURL: workingDirectoryURL, systemPromptText: systemPrompt)
    }

    // MARK: - Pre-spawn (P6.3)

    /// Starts the CLI for the next request now (key-down) and leaves it
    /// waiting on stdin; a request with the same settings then skips the
    /// CLI's start-up. Already waiting with these settings: nothing to do.
    @discardableResult
    func prespawnStandbyProcess(systemPromptFileName: String, systemPrompt: String, effortLevel: String?, maximumTurns: Int? = nil) -> Bool {
        do {
            let launchSpec = try makeLaunchSpec(systemPromptFileName: systemPromptFileName, systemPrompt: systemPrompt,
                                                effortLevel: effortLevel, maximumTurns: maximumTurns)
            if standbySlot.hasHealthyProcess(matching: launchSpec) { return true }
            standbySlot.install(try StandbyCLIProcess.spawn(launchSpec))
            return true
        } catch {
            print("⚠️ Claude Code pre-spawn failed (\(model)): \(error)")
            return false
        }
    }

    /// Reaps the waiting process, if any (turn end, setting turned off).
    func reapStandbyProcess() {
        standbySlot.reapWaiting()
    }

    // MARK: - Requests

    /// Runs one request: writes the system prompt file, takes the waiting
    /// pre-spawned CLI when it matches (else launches one), builds the single
    /// stdin line off the main actor, writes it, and collects streamed
    /// deltas and the final result.
    func runTurn(
        systemPromptFileName: String,
        systemPrompt: String,
        contentBlocks: [ClaudeContentBlock],
        effortLevel: String? = nil,
        persistentSessionIdentifier: String? = nil,
        maximumTurns: Int? = nil,
        allowsStandbyProcess: Bool = false,
        oversizedImageErrorTransformationOverride: Bool? = nil,
        onTextChunk: @MainActor @Sendable (String) -> Void = { _ in },
        onStreamEvent: (@MainActor @Sendable (CLIStreamEvent) -> Void)? = nil,
        onPipelineStage: (@MainActor @Sendable (String) -> Void)? = nil,
        onProcessReady: (@MainActor @Sendable (ClaudeProcessOrigin) -> Void)? = nil
    ) async throws -> ClaudeTurnResult {
        let startTime = Date()

        let launchSpec = try makeLaunchSpec(systemPromptFileName: systemPromptFileName, systemPrompt: systemPrompt, effortLevel: effortLevel,
                                            persistentSessionIdentifier: persistentSessionIdentifier, maximumTurns: maximumTurns)

        // A waiting process launched with exactly this spec skips start-up;
        // a different model / effort / prompt is reaped and we spawn fresh.
        let taken = allowsStandbyProcess ? standbySlot.take(matching: launchSpec) : nil
        let standbyOutcome = taken?.outcome
        let maybeStandbyProcess = taken?.process
        let initialProcess = try maybeStandbyProcess ?? StandbyCLIProcess.spawn(launchSpec)
        let activeProcess = ActiveCLIProcess(initialProcess)

        // 25 s without a text delta: stop the CLI and report it as stalled.
        let stallWatch = StallWatch()
        let stallWatchTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if stallWatch.secondsSinceLastActivity() > CLIStreamFailure.stallSeconds {
                    stallWatch.markStalled()
                    activeProcess.current.reap()
                    return
                }
            }
        }
        defer { stallWatchTask.cancel() }

        return try await withTaskCancellationHandler {
            // Build the (large) message while a fresh CLI starts up.
            let sendsTransformation = oversizedImageErrorTransformationOverride ?? Self.sendsOversizedImageErrorTransformation
            let userMessageLine = try await Task.detached(priority: .userInitiated) {
                try Self.makeStreamJSONUserMessageLine(contentBlocks: contentBlocks, sendsOversizedImageErrorTransformation: sendsTransformation)
            }.value
            let imageCount = contentBlocks.filter(\.isImage).count
            print("🌐 Claude Code request: \(String(format: "%.1f", Double(userMessageLine.count) / 1_048_576.0))MB, \(imageCount) image(s), model \(model), standby \(standbyOutcome?.rawValue ?? "off")")

            // Write off the main actor: the payload is larger than the pipe
            // buffer, so a blocking write would stall the UI until the CLI
            // drains it. Closing stdin tells the CLI there are no more turns.
            // EPIPE (the process died): spawn once more and retry.
            onPipelineStage?("handedToWriter")
            let delivered = try await Task.detached(priority: .userInitiated) {
                try StandbyCLIDelivery.deliver(userMessageLine, to: initialProcess) {
                    guard !activeProcess.isCancelled else { throw CancellationError() }
                    let respawnedProcess = try StandbyCLIProcess.spawn(launchSpec)
                    activeProcess.replace(with: respawnedProcess)
                    return respawnedProcess
                }
            }.value
            let claudeCodeProcess = delivered.process
            onPipelineStage?("requestWritten")
            onProcessReady?(ClaudeProcessOrigin(
                spawnDate: claudeCodeProcess.spawnDate,
                usedStandbyProcess: claudeCodeProcess === maybeStandbyProcess,
                standbyOutcome: standbyOutcome,
                retriedAfterBrokenPipe: delivered.didRetryAfterBrokenPipe
            ))

            var accumulatedResponseText = ""
            var finalResultText: String?
            var resolvedModelIdentifier: String?
            var finalUsage: [String: Any] = [:]
            var finalResultEvent: [String: Any]?
            var lineReader = LineReader()
            var pendingBytes = Data()

            func handle(_ lineData: Data) async throws {
                if let event = CLIStreamEvent.parse(lineData) {
                    await onStreamEvent?(event)
                    switch event {
                    case .systemInit(let model):
                        resolvedModelIdentifier = model
                    case .textDelta(let textChunk):
                        stallWatch.noteActivity()
                        accumulatedResponseText += textChunk
                        let currentAccumulatedText = accumulatedResponseText
                        await onTextChunk(currentAccumulatedText)
                    case .result(let resultText, let isErrorResult, _):
                        if isErrorResult {
                            throw ClaudeCodeBridgeError.claudeCodeReportedError(resultText)
                        }
                        finalResultText = resultText
                    case .messageStart, .other:
                        break
                    }
                }
                if let outputEvent = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   (outputEvent["type"] as? String) == "result" {
                    finalUsage = outputEvent["usage"] as? [String: Any] ?? [:]
                    finalResultEvent = outputEvent
                }
            }

            for try await outputByte in claudeCodeProcess.standardOutputHandle.bytes {
                pendingBytes.append(outputByte)
                guard outputByte == 0x0A || pendingBytes.count >= 65_536 else { continue }
                let completedLines = lineReader.append(pendingBytes)
                pendingBytes.removeAll(keepingCapacity: true)
                for lineData in completedLines { try await handle(lineData) }
            }
            for lineData in lineReader.append(pendingBytes) { try await handle(lineData) }
            if let lastLine = lineReader.finish() { try await handle(lastLine) }

            await claudeCodeProcess.waitForExit()

            // A cancelled request was killed mid-stream; report it as a
            // cancellation so the caller doesn't treat it as a failure.
            try Task.checkCancellation()
            if stallWatch.isStalled { throw ClaudeCodeBridgeError.claudeCodeStalled }

            guard let finalResultText else {
                let standardErrorData = claudeCodeProcess.standardErrorHandle.readDataToEndOfFile()
                let standardErrorOutput = String(data: standardErrorData, encoding: .utf8) ?? ""
                throw ClaudeCodeBridgeError.claudeCodeExitedWithoutResult(
                    exitCode: claudeCodeProcess.process.terminationStatus,
                    standardErrorOutput: standardErrorOutput
                )
            }

            // Prefer the CLI's final result; fall back to the streamed text if
            // the result came back empty for any reason.
            let responseText = finalResultText.isEmpty ? accumulatedResponseText : finalResultText
            return ClaudeTurnResult(
                text: responseText,
                resolvedModelIdentifier: resolvedModelIdentifier,
                usage: finalUsage,
                usageSummary: finalResultEvent.flatMap { AgentUsage.fromResultEvent($0, model: resolvedModelIdentifier ?? model) },
                duration: Date().timeIntervalSince(startTime)
            )
        } onCancel: {
            // The user spoke again — kill the in-flight request immediately.
            activeProcess.cancel()
        }
    }

    /// Builds one newline-terminated stream-json user message.
    nonisolated static func makeStreamJSONUserMessageLine(contentBlocks: [ClaudeContentBlock], sendsOversizedImageErrorTransformation: Bool) throws -> Data {
        let messageContent: [[String: Any]] = contentBlocks.map { contentBlock in
            switch contentBlock {
            case .text(let blockText):
                return ["type": "text", "text": blockText]
            case .jpegImage(let imageData), .pngImage(let imageData):
                let mediaType: String
                if case .pngImage = contentBlock { mediaType = "image/png" } else { mediaType = "image/jpeg" }
                var imageBlock: [String: Any] = [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType,
                        "data": imageData.base64EncodedString()
                    ]
                ]
                if sendsOversizedImageErrorTransformation {
                    imageBlock["transformations"] = ["oversized_image": "error"]
                }
                return imageBlock
            }
        }

        let streamJSONUserMessage: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": messageContent
            ],
            "parent_tool_use_id": NSNull()
        ]

        var userMessageLine = try JSONSerialization.data(withJSONObject: streamJSONUserMessage)
        userMessageLine.append(contentsOf: [UInt8(ascii: "\n")])
        return userMessageLine
    }

    // MARK: - Sign-in Status

    /// Asks Claude Code whether it's signed in, so the panel can tell the
    /// user to run `claude auth login` instead of failing silently.
    static func checkIsSignedIn() async -> Bool {
        guard let claudeCodeExecutableURL = locateClaudeCodeExecutable() else { return false }

        return await Task.detached {
            let authStatusProcess = Process()
            authStatusProcess.executableURL = claudeCodeExecutableURL
            authStatusProcess.arguments = ["auth", "status"]
            let authStatusOutputPipe = Pipe()
            authStatusProcess.standardOutput = authStatusOutputPipe
            authStatusProcess.standardError = FileHandle.nullDevice

            do {
                try authStatusProcess.run()
            } catch {
                return false
            }

            let authStatusOutputData = authStatusOutputPipe.fileHandleForReading.readDataToEndOfFile()
            authStatusProcess.waitUntilExit()

            guard let authStatus = try? JSONSerialization.jsonObject(with: authStatusOutputData) as? [String: Any] else {
                return false
            }
            return authStatus["loggedIn"] as? Bool ?? false
        }.value
    }
}

/// The process a request is talking to: the standby, or its respawn after
/// a broken pipe. Cancel and the stall watchdog stop whichever it is now.
private nonisolated final class ActiveCLIProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: StandbyCLIProcess
    private var cancelled = false

    init(_ process: StandbyCLIProcess) {
        self.process = process
    }

    var current: StandbyCLIProcess {
        lock.lock(); defer { lock.unlock() }
        return process
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func replace(with newProcess: StandbyCLIProcess) {
        lock.lock()
        process = newProcess
        let shouldReap = cancelled
        lock.unlock()
        if shouldReap { newProcess.reap() }
    }

    /// Stops (and reaps) the process now and any respawn after.
    func cancel() {
        lock.lock()
        cancelled = true
        let processToReap = process
        lock.unlock()
        processToReap.reap()
    }
}

/// Last text-delta time for the stall watchdog (read from a detached task).
private nonisolated final class StallWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity = Date()
    private var stalled = false

    func noteActivity() {
        lock.lock(); lastActivity = Date(); lock.unlock()
    }

    func secondsSinceLastActivity() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastActivity)
    }

    func markStalled() {
        lock.lock(); stalled = true; lock.unlock()
    }

    var isStalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return stalled
    }
}
