//
//  ClaudeCodeBridge.swift
//  leanring-buddy
//
//  Talks to Claude through the locally installed Claude Code CLI instead of
//  the Anthropic API, so requests run on the user's Claude subscription and
//  no API key is needed. Each request launches `claude -p` in headless
//  stream-json mode, writes one user message (screenshots + prompt) to its
//  stdin, and reads streamed text deltas back from its stdout.
//
//  Exposes the same `analyzeImageStreaming` surface the old ClaudeAPI had so
//  CompanionManager's pipeline didn't need to change shape.
//

import Foundation

enum ClaudeCodeBridgeError: LocalizedError {
    case claudeCodeNotInstalled
    case claudeCodeReportedError(String)
    case claudeCodeExitedWithoutResult(exitCode: Int32, standardErrorOutput: String)

    var errorDescription: String? {
        switch self {
        case .claudeCodeNotInstalled:
            return "Claude Code isn't installed. Install it, then run `claude auth login` in Terminal."
        case .claudeCodeReportedError(let message):
            return "Claude Code error: \(message)"
        case .claudeCodeExitedWithoutResult(let exitCode, let standardErrorOutput):
            return "Claude Code exited (\(exitCode)) without an answer. \(standardErrorOutput)"
        }
    }
}

final class ClaudeCodeBridge {
    /// Claude Code model alias ("sonnet", "opus") or a full model ID.
    /// Aliases always resolve to the newest model of that family.
    var model: String

    /// An empty folder the CLI runs in, so it never picks up a project's
    /// CLAUDE.md or settings from wherever the app happened to launch.
    private let isolatedWorkingDirectoryURL: URL = {
        let workingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-claude-code-workdir", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
        return workingDirectoryURL
    }()

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

    // MARK: - Requests

    /// Sends screenshots + a prompt to Claude via Claude Code and streams the reply.
    /// Calls `onTextChunk` with the full text accumulated so far each time new text arrives.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        guard let claudeCodeExecutableURL = Self.locateClaudeCodeExecutable() else {
            throw ClaudeCodeBridgeError.claudeCodeNotInstalled
        }

        let userMessageLine = try makeStreamJSONUserMessageLine(
            images: images,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let claudeCodeProcess = Process()
        claudeCodeProcess.executableURL = claudeCodeExecutableURL
        claudeCodeProcess.currentDirectoryURL = isolatedWorkingDirectoryURL
        claudeCodeProcess.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            "--system-prompt", systemPrompt,
            // Clicky only needs Claude to look and answer — no file, shell, or
            // web tools, no MCP servers, no skills. This also keeps startup fast.
            "--tools", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence"
        ]

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        claudeCodeProcess.standardInput = standardInputPipe
        claudeCodeProcess.standardOutput = standardOutputPipe
        claudeCodeProcess.standardError = standardErrorPipe

        try claudeCodeProcess.run()
        let payloadMB = Double(userMessageLine.count) / 1_048_576.0
        print("🌐 Claude Code request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model \(model)")

        // Write the message off the main actor: the payload is larger than the
        // pipe buffer, so a blocking write here would stall the UI until the
        // CLI drains it. Closing stdin tells the CLI there are no more turns.
        let standardInputFileHandle = standardInputPipe.fileHandleForWriting
        Task.detached {
            try? standardInputFileHandle.write(contentsOf: userMessageLine)
            try? standardInputFileHandle.close()
        }

        return try await withTaskCancellationHandler {
            var accumulatedResponseText = ""
            var finalResultText: String?

            for try await outputLine in standardOutputPipe.fileHandleForReading.bytes.lines {
                guard let outputLineData = outputLine.data(using: .utf8),
                      let outputEvent = try? JSONSerialization.jsonObject(with: outputLineData) as? [String: Any],
                      let outputEventType = outputEvent["type"] as? String else {
                    continue
                }

                if outputEventType == "stream_event",
                   let streamEvent = outputEvent["event"] as? [String: Any],
                   (streamEvent["type"] as? String) == "content_block_delta",
                   let delta = streamEvent["delta"] as? [String: Any],
                   (delta["type"] as? String) == "text_delta",
                   let textChunk = delta["text"] as? String {
                    accumulatedResponseText += textChunk
                    let currentAccumulatedText = accumulatedResponseText
                    onTextChunk(currentAccumulatedText)
                }

                if outputEventType == "result" {
                    let resultText = outputEvent["result"] as? String ?? ""
                    let isErrorResult = outputEvent["is_error"] as? Bool ?? false
                    if isErrorResult {
                        throw ClaudeCodeBridgeError.claudeCodeReportedError(resultText)
                    }
                    finalResultText = resultText
                }
            }

            claudeCodeProcess.waitUntilExit()

            // A cancelled request was killed mid-stream; report it as a
            // cancellation so the caller doesn't treat it as a failure.
            try Task.checkCancellation()

            guard let finalResultText else {
                let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
                let standardErrorOutput = String(data: standardErrorData, encoding: .utf8) ?? ""
                throw ClaudeCodeBridgeError.claudeCodeExitedWithoutResult(
                    exitCode: claudeCodeProcess.terminationStatus,
                    standardErrorOutput: standardErrorOutput
                )
            }

            // Prefer the CLI's final result; fall back to the streamed text if
            // the result came back empty for any reason.
            let responseText = finalResultText.isEmpty ? accumulatedResponseText : finalResultText
            return (text: responseText, duration: Date().timeIntervalSince(startTime))
        } onCancel: {
            // The user spoke again — kill the in-flight request immediately.
            claudeCodeProcess.terminate()
        }
    }

    /// Builds one newline-terminated stream-json user message. The CLI can't
    /// accept prior assistant turns as input, so earlier exchanges are folded
    /// into the text as a transcript ahead of the new question.
    private func makeStreamJSONUserMessageLine(
        images: [(data: Data, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) throws -> Data {
        var contentBlocks: [[String: Any]] = []

        if !conversationHistory.isEmpty {
            let earlierConversationTranscript = conversationHistory.map { exchange in
                "user: \(exchange.userPlaceholder)\nyou: \(exchange.assistantResponse)"
            }.joined(separator: "\n\n")
            contentBlocks.append([
                "type": "text",
                "text": "earlier in this conversation:\n\n\(earlierConversationTranscript)"
            ])
        }

        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }

        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])

        let streamJSONUserMessage: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": contentBlocks
            ]
        ]

        var userMessageLine = try JSONSerialization.data(withJSONObject: streamJSONUserMessage)
        userMessageLine.append(contentsOf: [UInt8(ascii: "\n")])
        return userMessageLine
    }

    /// Screen captures are JPEG but pasted images can be PNG, and Claude
    /// rejects images whose declared media type doesn't match the bytes.
    private func detectImageMediaType(for imageData: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if imageData.count >= 4 && [UInt8](imageData.prefix(4)) == pngSignature {
            return "image/png"
        }
        return "image/jpeg"
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
