//
//  StandbyCLI.swift
//  ClickyCore
//
//  P6.3 pre-spawn: start `claude -p` (stream-json in) at key-down and let it
//  wait on an open stdin until key-up, so the CLI's ~0.6 s start-up is spent
//  while the user is still talking. Measured with claude 2.1.301 (pipes, 30 s
//  idle, --debug-file): with stdin open and nothing written, the CLI stays alive,
//  prints nothing and makes no /v1/messages request; its system/init event
//  and the API request only start once the message line arrives.
//
//  StandbyCLIProcess is one such process (Foundation Process + pipes, the
//  same way ClaudeCodeBridge launches it). StandbyCLISlot holds at most one
//  waiting process: it is used only when the turn needs exactly the same
//  launch (argv, env, cwd and system prompt text), otherwise it is reaped and
//  the caller spawns fresh; one never used within 60 s is reaped too.
//  StandbyCLIDelivery writes the single message and closes stdin, and on a
//  broken pipe (the process died after the health check) spawns once more
//  and retries.
//

import Darwin
import Foundation

/// Everything a `claude` launch depends on. A standby process serves a turn
/// only when the turn's spec is equal to the one it was started with.
public struct CLILaunchSpec: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectoryURL: URL
    /// The prompt file's text at spawn: the path in `arguments` doesn't say
    /// what the file held (a MODE: whiteboard turn rewrites it).
    public var systemPromptText: String

    public init(executableURL: URL, arguments: [String], environment: [String: String], workingDirectoryURL: URL, systemPromptText: String) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.systemPromptText = systemPromptText
    }
}

public enum StandbyCLIError: Error, Equatable, Sendable {
    /// The reader end is gone: the process exited before reading the message.
    case brokenPipe
    case writeFailed(String)
}

/// One launched CLI process with its three pipes.
public final class StandbyCLIProcess: @unchecked Sendable {
    public let spec: CLILaunchSpec
    public let process: Process
    public let standardInputHandle: FileHandle
    public let standardOutputHandle: FileHandle
    public let standardErrorHandle: FileHandle
    public let spawnDate: Date

    private let stateLock = NSLock()
    private var isInputClosed = false
    private var hasBeenReaped = false

    /// A write to a dead pipe must fail with EPIPE, not kill the app.
    private static let ignoreBrokenPipeSignalOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private init(spec: CLILaunchSpec, process: Process, standardInputHandle: FileHandle, standardOutputHandle: FileHandle, standardErrorHandle: FileHandle) {
        self.spec = spec
        self.process = process
        self.standardInputHandle = standardInputHandle
        self.standardOutputHandle = standardOutputHandle
        self.standardErrorHandle = standardErrorHandle
        self.spawnDate = Date()
    }

    /// Launches the process; it waits on stdin until a message is written.
    public static func spawn(_ spec: CLILaunchSpec) throws -> StandbyCLIProcess {
        _ = ignoreBrokenPipeSignalOnce
        let launchedProcess = Process()
        launchedProcess.executableURL = spec.executableURL
        launchedProcess.arguments = spec.arguments
        // PWD must name the folder the CLI really runs in: Claude Code takes its project folder from
        // PWD, and an inherited one (Theo's is the home folder) makes it look through that instead.
        var environment = spec.environment
        environment["PWD"] = spec.workingDirectoryURL.path
        launchedProcess.environment = environment
        launchedProcess.currentDirectoryURL = spec.workingDirectoryURL
        // Someone is waiting on it, even when Theo itself is in the background and macOS would slow its children down.
        launchedProcess.qualityOfService = .userInitiated

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        launchedProcess.standardInput = standardInputPipe
        launchedProcess.standardOutput = standardOutputPipe
        launchedProcess.standardError = standardErrorPipe
        try launchedProcess.run()

        return StandbyCLIProcess(spec: spec, process: launchedProcess,
                                 standardInputHandle: standardInputPipe.fileHandleForWriting,
                                 standardOutputHandle: standardOutputPipe.fileHandleForReading,
                                 standardErrorHandle: standardErrorPipe.fileHandleForReading)
    }

    public var processIdentifier: pid_t { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Still waiting for its message: running, stdin open, not reaped.
    public var isHealthy: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !isInputClosed && !hasBeenReaped && process.isRunning
    }

    /// Writes the one message line and closes stdin (no more turns).
    /// Blocks until the CLI has read it all (payloads exceed the pipe buffer).
    public func writeMessageAndCloseInput(_ messageLine: Data) throws {
        stateLock.lock()
        let alreadyClosed = isInputClosed
        isInputClosed = true
        stateLock.unlock()
        guard !alreadyClosed else { throw StandbyCLIError.brokenPipe }
        defer { try? standardInputHandle.close() }
        do {
            try standardInputHandle.write(contentsOf: messageLine)
        } catch {
            if Self.isBrokenPipe(error) { throw StandbyCLIError.brokenPipe }
            throw StandbyCLIError.writeFailed(String(describing: error))
        }
    }

    /// Stops the process: SIGTERM now, SIGKILL after `graceSeconds` if it's
    /// still running. Foundation reaps the exited child itself.
    public func reap(graceSeconds: TimeInterval = 2) {
        stateLock.lock()
        let wasReaped = hasBeenReaped
        hasBeenReaped = true
        let shouldCloseInput = !isInputClosed
        isInputClosed = true
        stateLock.unlock()
        guard !wasReaped else { return }
        if shouldCloseInput { try? standardInputHandle.close() }
        guard process.isRunning else { return }
        process.terminate()
        let leaderIdentifier = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + graceSeconds) { [process] in
            if process.isRunning { kill(leaderIdentifier, SIGKILL) }
        }
    }

    /// Waits (off the caller's thread) until the process has exited.
    public func waitForExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async { [process] in
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    /// EPIPE, directly or as the underlying error of a Cocoa write error.
    static func isBrokenPipe(_ error: Error) -> Bool {
        var currentError: NSError? = error as NSError
        while let nsError = currentError {
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPIPE) { return true }
            currentError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

/// Holds at most one waiting process.
public final class StandbyCLISlot: @unchecked Sendable {
    /// Why a turn did or didn't get the waiting process.
    public enum TakeOutcome: String, Sendable, Equatable {
        /// Same launch: used as is.
        case matched
        /// Model, effort or prompt differ: reaped, spawn fresh.
        case mismatched
        /// Exited or stdin closed: reaped, spawn fresh.
        case unhealthy
        /// Nothing was waiting.
        case empty
    }

    public enum ReapReason: String, Sendable, Equatable {
        case replaced, mismatched, unhealthy, idle, explicit
    }

    /// A process waiting longer than this is reaped (60 s in the app).
    public let idleLimitSeconds: TimeInterval
    /// Called (on any thread) whenever the slot reaps a process.
    public var onReap: (@Sendable (StandbyCLIProcess, ReapReason) -> Void)?

    private let stateLock = NSLock()
    private var waitingProcess: StandbyCLIProcess?
    private var installGeneration = 0

    public init(idleLimitSeconds: TimeInterval = 60) {
        self.idleLimitSeconds = idleLimitSeconds
    }

    /// The process waiting now, if any (not removed).
    public var currentProcess: StandbyCLIProcess? {
        stateLock.lock(); defer { stateLock.unlock() }
        return waitingProcess
    }

    /// True when a healthy process is waiting with exactly this spec.
    public func hasHealthyProcess(matching spec: CLILaunchSpec) -> Bool {
        guard let currentProcess else { return false }
        return currentProcess.spec == spec && currentProcess.isHealthy
    }

    /// Makes `newProcess` the waiting one (a previous one is reaped) and
    /// starts its idle clock.
    public func install(_ newProcess: StandbyCLIProcess) {
        stateLock.lock()
        let replacedProcess = waitingProcess
        waitingProcess = newProcess
        installGeneration += 1
        let generation = installGeneration
        stateLock.unlock()
        if let replacedProcess, replacedProcess !== newProcess { reap(replacedProcess, reason: .replaced) }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleLimitSeconds) { [weak self] in
            self?.reapIfStillWaiting(generation: generation)
        }
    }

    /// Removes the waiting process. Returned only when it matches `spec`
    /// and is still healthy; anything else is reaped (the caller spawns).
    public func take(matching spec: CLILaunchSpec) -> (process: StandbyCLIProcess?, outcome: TakeOutcome) {
        stateLock.lock()
        let candidate = waitingProcess
        waitingProcess = nil
        installGeneration += 1
        stateLock.unlock()
        guard let candidate else { return (nil, .empty) }
        guard candidate.isHealthy else {
            reap(candidate, reason: .unhealthy)
            return (nil, .unhealthy)
        }
        guard candidate.spec == spec else {
            reap(candidate, reason: .mismatched)
            return (nil, .mismatched)
        }
        return (candidate, .matched)
    }

    /// Reaps whatever is waiting (cancel, turn end, setting turned off).
    public func reapWaiting() {
        stateLock.lock()
        let candidate = waitingProcess
        waitingProcess = nil
        installGeneration += 1
        stateLock.unlock()
        if let candidate { reap(candidate, reason: .explicit) }
    }

    private func reapIfStillWaiting(generation: Int) {
        stateLock.lock()
        guard generation == installGeneration, let candidate = waitingProcess else {
            stateLock.unlock()
            return
        }
        waitingProcess = nil
        installGeneration += 1
        stateLock.unlock()
        reap(candidate, reason: .idle)
    }

    private func reap(_ process: StandbyCLIProcess, reason: ReapReason) {
        process.reap()
        onReap?(process, reason)
    }
}

public enum StandbyCLIDelivery {
    public struct Delivered: Sendable {
        /// The process that got the message (a respawn after a broken pipe).
        public let process: StandbyCLIProcess
        public let didRetryAfterBrokenPipe: Bool
    }

    /// Writes the message to `process` and closes its stdin. On EPIPE the
    /// dead process is reaped, `respawn` starts a new one and the write is
    /// retried once; a second broken pipe is thrown.
    public static func deliver(_ messageLine: Data, to process: StandbyCLIProcess, respawn: () throws -> StandbyCLIProcess) throws -> Delivered {
        do {
            try process.writeMessageAndCloseInput(messageLine)
            return Delivered(process: process, didRetryAfterBrokenPipe: false)
        } catch StandbyCLIError.brokenPipe {
            process.reap()
            let respawnedProcess = try respawn()
            do {
                try respawnedProcess.writeMessageAndCloseInput(messageLine)
            } catch {
                respawnedProcess.reap()
                throw error
            }
            return Delivered(process: respawnedProcess, didRetryAfterBrokenPipe: true)
        }
    }
}
