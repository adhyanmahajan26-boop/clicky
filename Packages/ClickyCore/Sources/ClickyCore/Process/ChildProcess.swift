//
//  ChildProcess.swift
//  ClickyCore
//
//  Runs `git`, `gh` and the `claude` agent as child processes. Spawned with
//  posix_spawn (not Foundation.Process) so the child leads its own process
//  group, inherits only stdin (/dev/null), stdout and stderr, and starts with
//  default signal handling. Both pipes are drained on one poll loop so large
//  output on either never deadlocks; stdout is also split into lines with
//  LineReader as it arrives. Cancelling escalates SIGINT → SIGTERM (3 s) →
//  SIGKILL (6 s) on the whole group, and whenever the leader exits the group
//  is reaped so nothing it started is left running.
//

import Darwin
import Foundation

/// Limits on how long a child may run. `nil` means no limit.
public struct ChildProcessTimeouts: Sendable, Equatable {
    /// No stdout line for this long → cancel (paused while a tool is in flight).
    public var idleSeconds: TimeInterval?
    /// Total wall-clock time → cancel.
    public var totalSeconds: TimeInterval?

    public init(idleSeconds: TimeInterval? = nil, totalSeconds: TimeInterval? = nil) {
        self.idleSeconds = idleSeconds
        self.totalSeconds = totalSeconds
    }

    public static let none = ChildProcessTimeouts()
    /// The `claude` agent: 180 s without output, 20 minutes in total.
    public static let agent = ChildProcessTimeouts(idleSeconds: 180, totalSeconds: 20 * 60)

    public static func total(_ seconds: TimeInterval) -> ChildProcessTimeouts {
        ChildProcessTimeouts(totalSeconds: seconds)
    }
}

/// Why the child stopped.
public enum ChildProcessEndReason: Sendable, Equatable {
    case exited
    case cancelled
    case idleTimeout
    case totalTimeout
}

public struct ChildProcessResult: Sendable {
    public let processIdentifier: pid_t
    /// Exit code when the leader exited normally.
    public let exitStatus: Int32?
    /// Signal number when the leader was killed by a signal.
    public let terminatingSignal: Int32?
    public let endReason: ChildProcessEndReason
    public let standardOutput: Data
    public let standardError: Data
    /// Stdout lines over LineReader's 5 MB limit that were dropped.
    public let droppedOversizedLineCount: Int

    public var succeeded: Bool { endReason == .exited && exitStatus == 0 }
    public var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}

public enum ChildProcessError: Error, Equatable, Sendable {
    case pipeCreationFailed(errno: Int32)
    case spawnFailed(executable: String, errno: Int32)
}

/// A running child process and its process group. Create with `launch` (or
/// use `run` for one-shot commands), then `waitForExit()`.
public final class ChildProcess: @unchecked Sendable {
    /// Seconds after cancel() before SIGTERM, and before SIGKILL.
    public static let interruptToTerminateSeconds: TimeInterval = 3
    public static let interruptToKillSeconds: TimeInterval = 6

    public let processIdentifier: pid_t
    /// The child leads a new group, so its pgid is its pid.
    public var processGroupIdentifier: pid_t { processIdentifier }

    private let timeouts: ChildProcessTimeouts
    private let onStdoutLine: (@Sendable (Data) -> Void)?
    private let standardOutputDescriptor: Int32
    private let standardErrorDescriptor: Int32
    private let controlQueue = DispatchQueue(label: "clicky.child-process.control")
    private let startTime = Date()

    // Everything below is guarded by stateLock.
    private let stateLock = NSLock()
    private var endReason: ChildProcessEndReason?
    private var hasLeaderExited = false
    private var isGroupReaped = false
    private var isToolInFlight = false
    private var lastStdoutLineTime = Date()
    private var drainDeadline: Date?
    private var finishedResult: ChildProcessResult?
    private var exitWaiters: [CheckedContinuation<ChildProcessResult, Never>] = []
    private var monitorTimer: DispatchSourceTimer?

    // Owned by the drain thread until it signals drainFinished.
    private var capturedStandardOutput = Data()
    private var capturedStandardError = Data()
    private var stdoutLineReader = LineReader()
    private let drainFinished = DispatchSemaphore(value: 0)

    private static let ignoreBrokenPipeSignalOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    // MARK: - Launching

    /// Runs to completion. Cancelling the calling Task cancels the child.
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        timeouts: ChildProcessTimeouts = .none,
        onStdoutLine: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ChildProcessResult {
        let childProcess = try launch(executable: executable, arguments: arguments, environment: environment,
                                      workingDirectory: workingDirectory, timeouts: timeouts, onStdoutLine: onStdoutLine)
        return await withTaskCancellationHandler {
            await childProcess.waitForExit()
        } onCancel: {
            childProcess.cancel()
        }
    }

    /// Starts the child and returns at once. `executable` must be an absolute
    /// path (see ExecutablePath.which); `arguments` excludes argv[0].
    /// `onStdoutLine` is called on a background thread, one call per line.
    public static func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        timeouts: ChildProcessTimeouts = .none,
        onStdoutLine: (@Sendable (Data) -> Void)? = nil
    ) throws -> ChildProcess {
        _ = ignoreBrokenPipeSignalOnce

        let standardOutputPipe = try makePipe()
        let standardErrorPipe: (read: Int32, write: Int32)
        do {
            standardErrorPipe = try makePipe()
        } catch {
            close(standardOutputPipe.read); close(standardOutputPipe.write)
            throw error
        }

        let spawnResult = spawn(executable: executable, arguments: arguments, environment: environment,
                                workingDirectory: workingDirectory,
                                standardOutputWriteDescriptor: standardOutputPipe.write,
                                standardErrorWriteDescriptor: standardErrorPipe.write)
        // The child has its own copies; ours must close so EOF can arrive.
        close(standardOutputPipe.write)
        close(standardErrorPipe.write)

        switch spawnResult {
        case .failure(let spawnErrno):
            close(standardOutputPipe.read); close(standardErrorPipe.read)
            throw ChildProcessError.spawnFailed(executable: executable, errno: spawnErrno)
        case .success(let processIdentifier):
            let childProcess = ChildProcess(processIdentifier: processIdentifier, timeouts: timeouts, onStdoutLine: onStdoutLine,
                                            standardOutputDescriptor: standardOutputPipe.read,
                                            standardErrorDescriptor: standardErrorPipe.read)
            childProcess.start()
            return childProcess
        }
    }

    private init(processIdentifier: pid_t, timeouts: ChildProcessTimeouts, onStdoutLine: (@Sendable (Data) -> Void)?,
                 standardOutputDescriptor: Int32, standardErrorDescriptor: Int32) {
        self.processIdentifier = processIdentifier
        self.timeouts = timeouts
        self.onStdoutLine = onStdoutLine
        self.standardOutputDescriptor = standardOutputDescriptor
        self.standardErrorDescriptor = standardErrorDescriptor
    }

    private func start() {
        let drainThread = Thread { [self] in drainPipes() }
        drainThread.name = "clicky.child-process.drain.\(processIdentifier)"
        drainThread.start()

        let waitThread = Thread { [self] in waitForLeaderThenReap() }
        waitThread.name = "clicky.child-process.wait.\(processIdentifier)"
        waitThread.start()

        startMonitorTimerIfNeeded()
    }

    // MARK: - Public control

    /// Waits for the leader to exit, the group to be reaped and the pipes to drain.
    public func waitForExit() async -> ChildProcessResult {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if let finishedResult {
                stateLock.unlock()
                continuation.resume(returning: finishedResult)
            } else {
                exitWaiters.append(continuation)
                stateLock.unlock()
            }
        }
    }

    /// SIGINT the group, SIGTERM at 3 s, SIGKILL at 6 s while anything is alive.
    public func cancel() {
        cancel(reason: .cancelled)
    }

    /// While a tool runs the agent may print nothing for minutes; pause the
    /// idle timeout until it finishes. Turning it off restarts the idle clock.
    public func markToolInFlight(_ inFlight: Bool) {
        stateLock.lock()
        isToolInFlight = inFlight
        lastStdoutLineTime = Date()
        stateLock.unlock()
    }

    public var isFinished: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return finishedResult != nil
    }

    // MARK: - Cancellation and timeouts

    private func cancel(reason: ChildProcessEndReason) {
        stateLock.lock()
        guard endReason == nil, !hasLeaderExited else {
            stateLock.unlock()
            return
        }
        endReason = reason
        signalGroupLocked(SIGINT)
        stateLock.unlock()

        controlQueue.asyncAfter(deadline: .now() + Self.interruptToTerminateSeconds) { [self] in
            escalate(to: SIGTERM)
        }
        controlQueue.asyncAfter(deadline: .now() + Self.interruptToKillSeconds) { [self] in
            escalate(to: SIGKILL)
        }
    }

    private func escalate(to signalNumber: Int32) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !isGroupReaped, kill(-processGroupIdentifier, 0) == 0 else { return }
        signalGroupLocked(signalNumber)
    }

    /// Never signals a group id that might already belong to someone else.
    private func signalGroupLocked(_ signalNumber: Int32) {
        guard !isGroupReaped else { return }
        kill(-processGroupIdentifier, signalNumber)
    }

    private func startMonitorTimerIfNeeded() {
        guard timeouts.idleSeconds != nil || timeouts.totalSeconds != nil else { return }
        let shortestLimit = [timeouts.idleSeconds, timeouts.totalSeconds].compactMap { $0 }.min() ?? 1
        let checkInterval = max(0.05, min(1, shortestLimit / 4))
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
        timer.setEventHandler { [self] in checkTimeouts() }
        stateLock.lock()
        monitorTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    private func checkTimeouts() {
        let now = Date()
        stateLock.lock()
        let isRunning = endReason == nil && !hasLeaderExited
        let idleSeconds = now.timeIntervalSince(lastStdoutLineTime)
        let toolInFlight = isToolInFlight
        stateLock.unlock()
        guard isRunning else { return }

        if let totalSeconds = timeouts.totalSeconds, now.timeIntervalSince(startTime) >= totalSeconds {
            cancel(reason: .totalTimeout)
        } else if let idleLimit = timeouts.idleSeconds, !toolInFlight, idleSeconds >= idleLimit {
            cancel(reason: .idleTimeout)
        }
    }

    // MARK: - Exit and group reaping

    private func waitForLeaderThenReap() {
        // Wait without reaping: the zombie leader keeps its pid (and so the
        // group id) reserved while we kill whatever is left in the group.
        var exitInformation = siginfo_t()
        while waitid(P_PID, id_t(processIdentifier), &exitInformation, WEXITED | WNOWAIT) == -1, errno == EINTR {}

        stateLock.lock()
        hasLeaderExited = true
        stateLock.unlock()

        kill(-processGroupIdentifier, SIGKILL)
        var waitStatus: Int32 = 0
        while waitpid(processIdentifier, &waitStatus, 0) == -1, errno == EINTR {}
        reapRemainingGroupMembers()

        // Something outside the group may still hold the pipes; stop draining soon.
        stateLock.lock()
        drainDeadline = Date().addingTimeInterval(1)
        stateLock.unlock()
        drainFinished.wait()

        finish(waitStatus: waitStatus)
    }

    /// SIGKILL the group until no member is left (bounded at ~3 s).
    private func reapRemainingGroupMembers() {
        let giveUpTime = Date().addingTimeInterval(3)
        while Date() < giveUpTime {
            if kill(-processGroupIdentifier, 0) == -1, errno == ESRCH { break }
            kill(-processGroupIdentifier, SIGKILL)
            usleep(10_000)
        }
        stateLock.lock()
        isGroupReaped = true
        stateLock.unlock()
    }

    private func finish(waitStatus: Int32) {
        let terminationBits = waitStatus & 0x7f
        let exitStatus: Int32? = terminationBits == 0 ? (waitStatus >> 8) & 0xff : nil
        let terminatingSignal: Int32? = (terminationBits != 0 && terminationBits != 0x7f) ? terminationBits : nil

        stateLock.lock()
        let result = ChildProcessResult(
            processIdentifier: processIdentifier,
            exitStatus: exitStatus,
            terminatingSignal: terminatingSignal,
            endReason: endReason ?? .exited,
            standardOutput: capturedStandardOutput,
            standardError: capturedStandardError,
            droppedOversizedLineCount: stdoutLineReader.droppedOversizedLineCount
        )
        finishedResult = result
        let waiters = exitWaiters
        exitWaiters = []
        monitorTimer?.cancel()
        monitorTimer = nil
        stateLock.unlock()

        for waiter in waiters { waiter.resume(returning: result) }
    }

    // MARK: - Draining

    private func drainPipes() {
        var isStandardOutputOpen = true
        var isStandardErrorOpen = true
        var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

        while isStandardOutputOpen || isStandardErrorOpen {
            stateLock.lock()
            let deadline = drainDeadline
            stateLock.unlock()
            if let deadline, Date() >= deadline { break }

            var pollDescriptors: [pollfd] = []
            if isStandardOutputOpen { pollDescriptors.append(pollfd(fd: standardOutputDescriptor, events: Int16(POLLIN), revents: 0)) }
            if isStandardErrorOpen { pollDescriptors.append(pollfd(fd: standardErrorDescriptor, events: Int16(POLLIN), revents: 0)) }
            let readyCount = poll(&pollDescriptors, nfds_t(pollDescriptors.count), 100)
            if readyCount < 0 {
                if errno == EINTR { continue }
                break
            }
            for pollDescriptor in pollDescriptors where pollDescriptor.revents != 0 {
                let byteCount = read(pollDescriptor.fd, &readBuffer, readBuffer.count)
                if byteCount > 0 {
                    let chunk = Data(readBuffer[0..<byteCount])
                    if pollDescriptor.fd == standardOutputDescriptor {
                        handleStandardOutput(chunk)
                    } else {
                        capturedStandardError.append(chunk)
                    }
                } else if byteCount == 0 || (errno != EINTR && errno != EAGAIN) {
                    if pollDescriptor.fd == standardOutputDescriptor { isStandardOutputOpen = false } else { isStandardErrorOpen = false }
                }
            }
        }
        close(standardOutputDescriptor)
        close(standardErrorDescriptor)

        if let lastLine = stdoutLineReader.finish() {
            onStdoutLine?(lastLine)
        }
        drainFinished.signal()
    }

    private func handleStandardOutput(_ chunk: Data) {
        capturedStandardOutput.append(chunk)
        let completedLines = stdoutLineReader.append(chunk)
        guard !completedLines.isEmpty else { return }
        stateLock.lock()
        lastStdoutLineTime = Date()
        stateLock.unlock()
        for line in completedLines { onStdoutLine?(line) }
    }

    // MARK: - posix_spawn

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw ChildProcessError.pipeCreationFailed(errno: errno) }
        // Close-on-exec so other spawners in this process don't inherit them.
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(descriptors[0], F_SETFL, fcntl(descriptors[0], F_GETFL) | O_NONBLOCK)
        return (descriptors[0], descriptors[1])
    }

    private enum SpawnOutcome {
        case success(pid_t)
        case failure(Int32)
    }

    private static func spawn(executable: String, arguments: [String], environment: [String: String], workingDirectory: String?,
                              standardOutputWriteDescriptor: Int32, standardErrorWriteDescriptor: Int32) -> SpawnOutcome {
        var spawnAttributes: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttributes)
        defer { posix_spawnattr_destroy(&spawnAttributes) }
        // New group (pgid = child pid), only file-action fds inherited, and
        // default signal handling (our SIG_IGN for SIGPIPE must not leak in).
        let spawnFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&spawnAttributes, Int16(spawnFlags))
        posix_spawnattr_setpgroup(&spawnAttributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&spawnAttributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&spawnAttributes, &noSignals)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, standardOutputWriteDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, standardErrorWriteDescriptor, STDERR_FILENO)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
        }

        let argumentPointers = ([executable] + arguments).map { strdup($0) } + [nil]
        let environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }

        var processIdentifier: pid_t = 0
        let spawnErrno = posix_spawn(&processIdentifier, executable, &fileActions, &spawnAttributes,
                                     argumentPointers, environmentPointers)
        return spawnErrno == 0 ? .success(processIdentifier) : .failure(spawnErrno)
    }
}
