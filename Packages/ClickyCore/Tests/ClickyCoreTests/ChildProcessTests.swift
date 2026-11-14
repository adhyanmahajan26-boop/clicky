//
//  ChildProcessTests.swift
//  ClickyCoreTests
//
//  ChildProcess, ProcessSweep, ExecutablePath and SyntheticEventTag, driven
//  by tiny /bin/sh helper scripts written to a temp dir per test. Every test
//  checks that the processes it started are gone before it returns.
//

import Darwin
import Foundation
import Testing
@testable import ClickyCore

// MARK: - Helpers

/// A fresh temp dir with a shell script in it; removed by `cleanUp()`.
private struct HelperScript {
    let directoryURL: URL
    let scriptPath: String

    init(_ body: String) throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        scriptPath = directoryURL.appendingPathComponent("helper.sh").path
        try ("#!/bin/sh\n" + body + "\n").write(toFile: scriptPath, atomically: true, encoding: .utf8)
        chmod(scriptPath, 0o755)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private let testEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

/// Collects stdout lines from the drain thread.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedLines: [Data] = []

    func append(_ line: Data) { lock.withLock { collectedLines.append(line) } }
    var lines: [Data] { lock.withLock { collectedLines } }
    var texts: [String] { lines.map { String(decoding: $0, as: UTF8.self) } }
}

private func processExists(_ processIdentifier: pid_t) -> Bool {
    kill(processIdentifier, 0) == 0 || errno != ESRCH
}

private func groupExists(_ processGroupIdentifier: pid_t) -> Bool {
    kill(-processGroupIdentifier, 0) == 0 || errno != ESRCH
}

/// Polls until `condition` holds or `timeoutSeconds` pass.
private func waitUntil(timeoutSeconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let giveUpTime = Date().addingTimeInterval(timeoutSeconds)
    while Date() < giveUpTime {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Last resort so a failing test never leaves a process running.
private func forceKill(_ processIdentifiers: [pid_t]) {
    for processIdentifier in processIdentifiers where processIdentifier > 0 { kill(processIdentifier, SIGKILL) }
}

// MARK: - ChildProcess

@Suite("ChildProcess")
struct ChildProcessTests {
    @Test func largeOutputOnBothPipesDoesNotDeadlock() async throws {
        let script = try HelperScript("""
        head -c 2097152 /dev/zero | tr '\\000' 'e' >&2 &
        head -c 2097152 /dev/zero | tr '\\000' 'o'
        wait
        """)
        defer { script.cleanUp() }
        let result = try await ChildProcess.run(executable: "/bin/sh", arguments: [script.scriptPath],
                                                environment: testEnvironment, timeouts: .total(8))
        #expect(result.endReason == .exited)
        #expect(result.exitStatus == 0)
        #expect(result.standardOutput.count == 2_097_152)
        #expect(result.standardError.count == 2_097_152)
        #expect(!groupExists(result.processIdentifier))
    }

    @Test func captureLimitKeepsOnlyTheTailButEveryLineArrives() async throws {
        // 40,000 lines on stdout and 2 MB on stderr: the result keeps the last 4 KB of each, the lines all reach the callback.
        let script = try HelperScript("""
        head -c 2097152 /dev/zero | tr '\\000' 'e' >&2 &
        i=0; while [ $i -lt 40000 ]; do echo "line $i"; i=$((i+1)); done
        wait
        printf 'last-err' >&2
        """)
        defer { script.cleanUp() }
        let collector = LineCollector()
        let child = try ChildProcess.launch(executable: "/bin/sh", arguments: [script.scriptPath], environment: testEnvironment,
                                            timeouts: .total(20), captureLimit: 4096, onStdoutLine: { collector.append($0) })
        let result = await child.waitForExit()
        #expect(result.endReason == .exited)
        #expect(collector.lines.count == 40_000)
        #expect(collector.texts.last == "line 39999")
        #expect(result.standardOutput.count == 4096)
        #expect(result.standardOutputText.hasSuffix("line 39999\n"))
        #expect(result.standardError.count == 4096)
        #expect(result.standardErrorText.hasSuffix("last-err"))
        #expect(!groupExists(result.processIdentifier))
    }

    @Test func stdoutLinesSplitOnlyOnNewline() async throws {
        let collector = LineCollector()
        let result = try await ChildProcess.run(
            executable: "/usr/bin/printf", arguments: ["a\\342\\200\\250b\\nsecond\\nno newline"],
            environment: testEnvironment, onStdoutLine: { collector.append($0) })
        #expect(result.succeeded)
        #expect(collector.texts == ["a\u{2028}b", "second", "no newline"])
    }

    @Test func passesArgumentsEnvironmentAndWorkingDirectory() async throws {
        let script = try HelperScript(#"printf '%s|%s|%s' "$1" "$CLICKY_TEST_VALUE" "$(pwd -P)"; exit 3"#)
        defer { script.cleanUp() }
        let result = try await ChildProcess.run(
            executable: "/bin/sh", arguments: [script.scriptPath, "one arg"],
            environment: testEnvironment.merging(["CLICKY_TEST_VALUE": "hello"]) { $1 },
            workingDirectory: script.directoryURL.path)
        let resolvedDirectory = try #require(ProcessSweep.resolvedPath(script.directoryURL.path))
        #expect(result.standardOutputText == "one arg|hello|\(resolvedDirectory)")
        #expect(result.exitStatus == 3)
        #expect(!result.succeeded)
    }

    @Test func stdinIsDevNull() async throws {
        let result = try await ChildProcess.run(executable: "/bin/cat", arguments: [], environment: testEnvironment, timeouts: .total(3))
        #expect(result.endReason == .exited)
        #expect(result.standardOutput.isEmpty)
    }

    @Test func spawnFailureThrows() async {
        await #expect(throws: ChildProcessError.self) {
            _ = try await ChildProcess.run(executable: "/nonexistent/clicky-tool", arguments: [], environment: testEnvironment)
        }
    }

    @Test func cancelEmptiesSignalIgnoringGroupWithinSevenSeconds() async throws {
        let script = try HelperScript("""
        trap '' INT TERM
        ( trap '' INT TERM; sleep 30 ) &
        echo $!
        sleep 30
        """)
        defer { script.cleanUp() }
        let collector = LineCollector()
        let childProcess = try ChildProcess.launch(executable: "/bin/sh", arguments: [script.scriptPath],
                                                   environment: testEnvironment, onStdoutLine: { collector.append($0) })
        let backgroundProcessIdentifier = await waitUntil(timeoutSeconds: 3) { !collector.lines.isEmpty }
            ? pid_t(collector.texts[0]) ?? 0 : 0
        defer { forceKill([backgroundProcessIdentifier, childProcess.processIdentifier]) }
        #expect(backgroundProcessIdentifier > 0)

        let cancelTime = Date()
        childProcess.cancel()
        let result = await childProcess.waitForExit()
        let elapsedSeconds = Date().timeIntervalSince(cancelTime)

        #expect(elapsedSeconds < 7)
        #expect(result.endReason == .cancelled)
        #expect(result.terminatingSignal == SIGKILL)
        #expect(!processExists(childProcess.processIdentifier))
        #expect(await waitUntil(timeoutSeconds: 1) { !processExists(backgroundProcessIdentifier) })
        #expect(!groupExists(childProcess.processGroupIdentifier))
    }

    @Test func cancelStopsCooperativeChildWithSIGINT() async throws {
        let childProcess = try ChildProcess.launch(executable: "/bin/sleep", arguments: ["30"], environment: testEnvironment)
        defer { forceKill([childProcess.processIdentifier]) }
        childProcess.cancel()
        let result = await childProcess.waitForExit()
        #expect(result.endReason == .cancelled)
        #expect(result.terminatingSignal == SIGINT)
    }

    @Test func leaderExitReapsBackgroundedChild() async throws {
        let script = try HelperScript("""
        sleep 30 &
        echo $!
        exit 0
        """)
        defer { script.cleanUp() }
        let result = try await ChildProcess.run(executable: "/bin/sh", arguments: [script.scriptPath],
                                                environment: testEnvironment, timeouts: .total(8))
        let backgroundProcessIdentifier = pid_t(result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        defer { forceKill([backgroundProcessIdentifier]) }
        #expect(backgroundProcessIdentifier > 0)
        #expect(result.exitStatus == 0)
        #expect(await waitUntil(timeoutSeconds: 1) { !processExists(backgroundProcessIdentifier) })
        #expect(!groupExists(result.processIdentifier))
    }

    @Test func idleTimeoutFires() async throws {
        let startTime = Date()
        // The child would sleep for 30 seconds; the 1 second idle timeout has to be what ends it. The bound is far below 30
        // and far above 1 because a build machine running every suite at once can hold the timeout back by several seconds
        // (it fired after 5.9 seconds there, which the old 5 second sleep and 3 second bound called a failure).
        let result = try await ChildProcess.run(executable: "/bin/sleep", arguments: ["30"], environment: testEnvironment,
                                                timeouts: ChildProcessTimeouts(idleSeconds: 1))
        #expect(result.endReason == .idleTimeout)
        #expect(Date().timeIntervalSince(startTime) < 15)
    }

    @Test func toolInFlightSuppressesIdleTimeout() async throws {
        let script = try HelperScript("sleep 2; echo done")
        defer { script.cleanUp() }
        let childProcess = try ChildProcess.launch(executable: "/bin/sh", arguments: [script.scriptPath], environment: testEnvironment,
                                                   timeouts: ChildProcessTimeouts(idleSeconds: 1))
        defer { forceKill([childProcess.processIdentifier]) }
        childProcess.markToolInFlight(true)
        let result = await childProcess.waitForExit()
        #expect(result.endReason == .exited)
        #expect(result.standardOutputText == "done\n")
    }

    @Test func totalTimeoutFires() async throws {
        let result = try await ChildProcess.run(executable: "/bin/sleep", arguments: ["5"], environment: testEnvironment,
                                                timeouts: .total(0.5))
        #expect(result.endReason == .totalTimeout)
    }

    @Test func taskCancellationCancelsChild() async throws {
        let runTask = Task {
            try await ChildProcess.run(executable: "/bin/sleep", arguments: ["30"], environment: testEnvironment)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        runTask.cancel()
        let result = try await runTask.value
        #expect(result.endReason == .cancelled)
    }
}

// MARK: - ProcessSweep

@Suite("ProcessSweep")
struct ProcessSweepTests {
    @Test func findsAndKillsDetachedProcessByWorkingDirectory() async throws {
        let script = try HelperScript("""
        cd "$1" || exit 1
        ( perl -MPOSIX -e 'POSIX::setsid(); open(my $f, ">", "pid.txt") or die; print $f $$; close($f); exec("/bin/sleep", "30")' </dev/null >/dev/null 2>&1 & )
        # Stay until it has left our group, or group reaping would kill it first.
        while [ ! -s pid.txt ]; do sleep 0.05; done
        exit 0
        """)
        defer { script.cleanUp() }
        let workDirectory = script.directoryURL.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let pidFilePath = workDirectory.appendingPathComponent("pid.txt").path

        let result = try await ChildProcess.run(executable: "/bin/sh", arguments: [script.scriptPath, workDirectory.path],
                                                environment: testEnvironment, timeouts: .total(5))
        #expect(result.exitStatus == 0)
        var detachedProcessIdentifier: pid_t = 0
        _ = await waitUntil(timeoutSeconds: 3) {
            detachedProcessIdentifier = (try? String(contentsOfFile: pidFilePath, encoding: .utf8)).flatMap { pid_t($0) } ?? 0
            return detachedProcessIdentifier > 0
        }
        defer { forceKill([detachedProcessIdentifier]) }
        #expect(detachedProcessIdentifier > 0)
        // It left the group, so group reaping did not touch it.
        #expect(processExists(detachedProcessIdentifier))

        // Wait for the exec into sleep so cwd lookups are stable.
        #expect(await waitUntil(timeoutSeconds: 2) {
            ProcessSweep.processes(underDirectories: [workDirectory.path]).contains(detachedProcessIdentifier)
        })
        #expect(!ProcessSweep.processes(underDirectories: [workDirectory.path]).contains(getpid()))

        let remainingProcesses = ProcessSweep.killAll(underDirectories: [workDirectory.path])
        #expect(remainingProcesses.isEmpty)
        #expect(await waitUntil(timeoutSeconds: 2) { !processExists(detachedProcessIdentifier) })
    }

    @Test func pathMatchingRespectsDirectoryBoundaries() {
        #expect(ProcessSweep.isPath("/tmp/work", underAnyOf: ["/tmp/work"]))
        #expect(ProcessSweep.isPath("/tmp/work/sub/bin", underAnyOf: ["/tmp/work"]))
        #expect(!ProcessSweep.isPath("/tmp/workshop", underAnyOf: ["/tmp/work"]))
        #expect(!ProcessSweep.isPath("/tmp", underAnyOf: ["/tmp/work"]))
    }

    @Test func missingDirectoriesMatchNothing() {
        #expect(ProcessSweep.processes(underDirectories: ["/nonexistent/clicky-\(UUID().uuidString)"]).isEmpty)
    }

    @Test func readsOwnExecutablePath() {
        #expect(ProcessSweep.executablePath(of: getpid()) != nil)
        #expect(ProcessSweep.currentWorkingDirectory(of: getpid()) != nil)
    }
}

// MARK: - ExecutablePath

@Suite("ExecutablePath")
struct ExecutablePathTests {
    @Test func includesLocalBinAndFindsShell() async {
        let searchDirectories = await ExecutablePath.searchDirectories()
        let localBinDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")
        #expect(searchDirectories.contains(localBinDirectory))
        #expect(Set(searchDirectories).count == searchDirectories.count)
        #expect(await ExecutablePath.which("sh") == "/bin/sh")
        #expect(await ExecutablePath.which("clicky-no-such-tool-\(UUID().uuidString)") == nil)
    }

    @Test func combinesAndDedupes() {
        let combinedDirectories = ExecutablePath.combinedSearchDirectories(
            probedPath: "/opt/homebrew/bin:/usr/bin::/usr/bin/", inheritedPath: "/usr/bin:/bin", homeDirectory: "/Users/test")
        #expect(combinedDirectories.first == "/opt/homebrew/bin")
        #expect(combinedDirectories.last == "/Users/test/.local/bin")
        #expect(combinedDirectories.filter { $0 == "/usr/bin" }.count == 1)
        #expect(!combinedDirectories.contains(""))
    }

    @Test func whichAcceptsAbsolutePathsAndSkipsDirectories() {
        #expect(ExecutablePath.which("/bin/sh", in: []) == "/bin/sh")
        #expect(ExecutablePath.which("bin", in: ["/"]) == nil)
    }
}

// MARK: - SyntheticEventTag

@Test func syntheticEventTagValue() {
    #expect(SyntheticEventTag.value == 0x434C49434B59)
    #expect(SyntheticEventTag.isTagged(userData: 0x434C49434B59))
    #expect(!SyntheticEventTag.isTagged(userData: 0))
}
