//
//  CodeAgentRunner.swift
//  ClickyCore
//
//  Runs the Code-mode `claude` agent as a ChildProcess in the worktree and
//  reads its stream-json. The first real event must be system/init, within
//  30 s, and must pass AgentInitValidator (acceptEdits, exactly our tools,
//  no MCP/plugins, same apiKeySource as the probe, cwd = the worktree);
//  otherwise the whole process group is SIGKILLed before it runs a tool.
//  tool_use / tool_result events pause the idle timeout while a tool runs.
//  The final result becomes an AgentResult (structured_output, or the last
//  JSON object in the result text).
//

import Foundation

public struct AgentRunConfiguration: Sendable {
    public var claudePath: String
    public var invocation: AgentInvocation
    /// From `claude --help` (+ probe-verified flags); unsupported optional flags are dropped.
    public var supportedFlags: Set<String>
    public var expectation: AgentInitExpectation
    public var workingDirectory: String
    /// The base environment; AgentInvocation.environment(base:) strips credentials from it.
    public var baseEnvironment: [String: String]
    public var timeouts: ChildProcessTimeouts
    public var initTimeoutSeconds: TimeInterval
    /// Every stdout line is appended here (0600), when set.
    public var transcriptURL: URL?

    public init(claudePath: String, invocation: AgentInvocation, supportedFlags: Set<String>, expectation: AgentInitExpectation, workingDirectory: String,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, timeouts: ChildProcessTimeouts = .agent,
                initTimeoutSeconds: TimeInterval = AgentInitValidator.initTimeout, transcriptURL: URL? = nil) {
        self.claudePath = claudePath
        self.invocation = invocation
        self.supportedFlags = supportedFlags
        self.expectation = expectation
        self.workingDirectory = workingDirectory
        self.baseEnvironment = baseEnvironment
        self.timeouts = timeouts
        self.initTimeoutSeconds = initTimeoutSeconds
        self.transcriptURL = transcriptURL
    }

    /// argv after `claude`, filtered by the supported flags.
    public var filteredArguments: (arguments: [String], droppedFlags: [String]) { invocation.arguments(supportedFlags: supportedFlags) }
}

public enum AgentRunOutcome: Equatable, Sendable {
    case completed(resultText: String, result: AgentResult?)
    case initRejected([AgentInitFailure])
    case initTimedOut
    case reportedError(String)
    case endedWithoutResult
    case timedOut(ChildProcessEndReason)
    case cancelled
    case refusedForbiddenFlags([String])
    case launchFailed(String)

    public var isSuccess: Bool {
        if case .completed = self { return true }
        return false
    }

    public var failureDescription: String? {
        switch self {
        case .completed: return nil
        case .initRejected(let failures): return "agent init rejected: " + failures.map(\.description).joined(separator: "; ")
        case .initTimedOut: return "the agent didn't start within \(Int(AgentInitValidator.initTimeout)) s"
        case .reportedError(let message): return "the agent reported an error: \(message.prefix(200))"
        case .endedWithoutResult: return "the agent stopped without a result"
        case .timedOut(let reason): return "the agent timed out (\(reason))"
        case .cancelled: return "cancelled"
        case .refusedForbiddenFlags(let tokens): return "refused forbidden flags: \(tokens.joined(separator: " "))"
        case .launchFailed(let message): return "couldn't start claude: \(message)"
        }
    }
}

public struct AgentRunReport: Sendable {
    public var outcome: AgentRunOutcome
    public var droppedFlags: [String]
    public var sessionIdentifier: String?
    public var processIdentifier: pid_t?
    /// The leader exited and its group was reaped (ChildProcess guarantees it on exit).
    public var isProcessGroupReaped: Bool
}

public final class CodeAgentRunner: @unchecked Sendable {
    public let configuration: AgentRunConfiguration

    private let lock = NSLock()
    private var childProcess: ChildProcess?
    private var killRequestedBeforeLaunch = false
    private var hasSeenInit = false
    private var initFailures: [AgentInitFailure]?
    private var didTimeOutWaitingForInit = false
    private var wasCancelledByUser = false
    private var resultEvent: [String: Any]?
    private var sessionIdentifier: String?
    private var transcriptHandle: FileHandle?

    public init(configuration: AgentRunConfiguration) {
        self.configuration = configuration
    }

    /// SIGINT → SIGTERM → SIGKILL on the agent's group.
    public func cancel() {
        lock.lock()
        wasCancelledByUser = true
        let process = childProcess
        lock.unlock()
        process?.cancel()
    }

    public var runningProcess: ChildProcess? { lock.withLock { childProcess } }

    public func run() async -> AgentRunReport {
        let (arguments, droppedFlags) = configuration.filteredArguments
        let forbiddenTokens = AgentInvocation.forbiddenTokens(in: arguments)
        guard forbiddenTokens.isEmpty else {
            return AgentRunReport(outcome: .refusedForbiddenFlags(forbiddenTokens), droppedFlags: droppedFlags, sessionIdentifier: nil, processIdentifier: nil, isProcessGroupReaped: true)
        }
        openTranscript()
        defer { closeTranscript() }

        let launchedProcess: ChildProcess
        do {
            launchedProcess = try ChildProcess.launch(
                executable: configuration.claudePath, arguments: arguments,
                environment: configuration.invocation.environment(base: configuration.baseEnvironment),
                workingDirectory: configuration.workingDirectory, timeouts: configuration.timeouts,
                onStdoutLine: { [self] line in handleLine(line) }
            )
        } catch {
            return AgentRunReport(outcome: .launchFailed(String(describing: error)), droppedFlags: droppedFlags, sessionIdentifier: nil, processIdentifier: nil, isProcessGroupReaped: true)
        }
        let mustKillNow: Bool = lock.withLock {
            childProcess = launchedProcess
            return killRequestedBeforeLaunch
        }
        if mustKillNow { launchedProcess.killImmediately() }

        let initWatchdog = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(configuration.initTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let shouldKill: Bool = lock.withLock {
                guard !hasSeenInit, initFailures == nil else { return false }
                didTimeOutWaitingForInit = true
                return true
            }
            if shouldKill { launchedProcess.killImmediately() }
        }

        let processResult = await withTaskCancellationHandler {
            await launchedProcess.waitForExit()
        } onCancel: {
            launchedProcess.cancel()
        }
        initWatchdog.cancel()

        let outcome: AgentRunOutcome = lock.withLock {
            if let initFailures { return .initRejected(initFailures) }
            if didTimeOutWaitingForInit { return .initTimedOut }
            if wasCancelledByUser || Task.isCancelled { return .cancelled }
            if let resultEvent {
                let resultText = resultEvent["result"] as? String ?? ""
                if resultEvent["is_error"] as? Bool == true || (resultEvent["subtype"] as? String).map({ $0 != "success" }) == true {
                    return .reportedError(resultText.isEmpty ? (resultEvent["subtype"] as? String ?? "error") : resultText)
                }
                return .completed(resultText: resultText, result: AgentResultExtractor.extract(fromResultEvent: resultEvent))
            }
            switch processResult.endReason {
            case .idleTimeout, .totalTimeout: return .timedOut(processResult.endReason)
            case .cancelled: return .cancelled
            case .exited: return .endedWithoutResult
            }
        }
        return AgentRunReport(outcome: outcome, droppedFlags: droppedFlags, sessionIdentifier: lock.withLock { sessionIdentifier },
                              processIdentifier: launchedProcess.processIdentifier, isProcessGroupReaped: launchedProcess.isFinished)
    }

    // MARK: - Stream

    private func handleLine(_ line: Data) {
        appendToTranscript(line)
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let eventType = event["type"] as? String else { return }

        lock.lock()
        let isBeforeInit = !hasSeenInit && initFailures == nil
        lock.unlock()

        if isBeforeInit {
            if eventType == "system" && event["subtype"] as? String != "init" { return }
            let failures = AgentInitValidator.validate(initEvent: event, expectation: configuration.expectation)
            lock.lock()
            if failures.isEmpty {
                hasSeenInit = true
                sessionIdentifier = event["session_id"] as? String
                lock.unlock()
            } else {
                initFailures = failures
                lock.unlock()
                killNow()
            }
            return
        }

        lock.lock()
        let rejected = initFailures != nil
        lock.unlock()
        guard !rejected else { return }

        switch eventType {
        case "assistant":
            if Self.contentBlockTypes(in: event).contains("tool_use") { runningProcess?.markToolInFlight(true) }
        case "user":
            if Self.contentBlockTypes(in: event).contains("tool_result") { runningProcess?.markToolInFlight(false) }
        case "result":
            lock.withLock { resultEvent = event }
        default:
            break
        }
    }

    private func killNow() {
        lock.lock()
        let process = childProcess
        if process == nil { killRequestedBeforeLaunch = true }
        lock.unlock()
        process?.killImmediately()
    }

    static func contentBlockTypes(in event: [String: Any]) -> Set<String> {
        guard let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return [] }
        return Set(content.compactMap { $0["type"] as? String })
    }

    // MARK: - Transcript

    private func openTranscript() {
        guard let transcriptURL = configuration.transcriptURL else { return }
        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        transcriptHandle = try? FileHandle(forWritingTo: transcriptURL)
        transcriptHandle?.seekToEndOfFile()
    }

    private func appendToTranscript(_ line: Data) {
        lock.withLock {
            transcriptHandle?.write(line)
            transcriptHandle?.write(Data([0x0A]))
        }
    }

    private func closeTranscript() {
        lock.withLock {
            try? transcriptHandle?.close()
            transcriptHandle = nil
        }
    }
}

public enum AgentResultExtractor {
    /// structured_output first (from --json-schema), else the last JSON object in the result text.
    public static func extract(fromResultEvent resultEvent: [String: Any]) -> AgentResult? {
        if let structuredOutput = resultEvent["structured_output"], !(structuredOutput is NSNull),
           JSONSerialization.isValidJSONObject(structuredOutput),
           let data = try? JSONSerialization.data(withJSONObject: structuredOutput),
           let result = try? JSONDecoder().decode(AgentResult.self, from: data) {
            return result
        }
        return extract(fromText: resultEvent["result"] as? String ?? "")
    }

    public static func extract(fromText text: String) -> AgentResult? {
        guard let lastClose = text.lastIndex(of: "}") else { return nil }
        var searchEnd = lastClose
        while let openIndex = text[..<searchEnd].lastIndex(of: "{") {
            let candidate = text[openIndex...lastClose]
            if let result = try? JSONDecoder().decode(AgentResult.self, from: Data(candidate.utf8)) { return result }
            searchEnd = openIndex
        }
        return nil
    }
}
