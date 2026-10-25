//
//  StandbyCLITests.swift
//  ClickyCoreTests
//
//  P6.3 pre-spawn, driven by Tools/fakecli/fakecli.sh: a standby waits
//  (prints nothing) until its stdin closes; a turn with another spec reaps
//  it; a broken pipe respawns and retries exactly once; cancel and the idle
//  limit reap it. Every test checks its processes are gone before returning.
//

import Darwin
import Foundation
import Testing
@testable import ClickyCore

private let fakeCLIURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../Tools/fakecli/fakecli.sh").standardizedFileURL

private func fakeSpec(mode: String, effortLevel: String? = nil) -> CLILaunchSpec {
    var arguments = [mode]
    if let effortLevel { arguments += ["--effort", effortLevel] }
    return CLILaunchSpec(executableURL: fakeCLIURL, arguments: arguments, environment: ["PATH": "/usr/bin:/bin"],
                         workingDirectoryURL: FileManager.default.temporaryDirectory, systemPromptText: "prompt")
}

private let messageLine = Data(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#.utf8) + Data([0x0A])

/// Polls until `condition` holds or `timeoutSeconds` pass.
private func waitUntil(timeoutSeconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let giveUpTime = Date().addingTimeInterval(timeoutSeconds)
    while Date() < giveUpTime {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Bytes readable right now without blocking (nil = nothing yet).
private func nonBlockingRead(_ fileHandle: FileHandle) -> Data? {
    let descriptor = fileHandle.fileDescriptor
    let originalFlags = fcntl(descriptor, F_GETFL)
    _ = fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK)
    defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let byteCount = read(descriptor, &buffer, buffer.count)
    return byteCount > 0 ? Data(buffer[0..<byteCount]) : nil
}

/// Collects onReap calls.
private final class ReapLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [StandbyCLISlot.ReapReason] = []
    func append(_ reason: StandbyCLISlot.ReapReason) { lock.withLock { reasons.append(reason) } }
    var all: [StandbyCLISlot.ReapReason] { lock.withLock { reasons } }
}

@Suite("Standby CLI (P6.3)")
struct StandbyCLITests {
    @Test func prespawnedProcessWaitsUntilStdinCloses() async throws {
        let standby = try StandbyCLIProcess.spawn(fakeSpec(mode: "stream-json-stdin"))
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(standby.isRunning)
        #expect(standby.isHealthy)
        #expect(nonBlockingRead(standby.standardOutputHandle) == nil)

        try standby.writeMessageAndCloseInput(messageLine)
        let output = String(decoding: standby.standardOutputHandle.readDataToEndOfFile(), as: UTF8.self)
        await standby.waitForExit()
        #expect(output.contains(#""result":"got \#(messageLine.count)""#))
        let resultLine = output.split(separator: "\n").last.map { Data($0.utf8) } ?? Data()
        #expect(CLIStreamEvent.parse(resultLine) == .result(text: "got \(messageLine.count)", isError: false, subtype: "success"))
        #expect(!standby.isRunning)
        #expect(!standby.isHealthy)
    }

    @Test func matchingSpecIsTakenAsIs() async throws {
        let slot = StandbyCLISlot(idleLimitSeconds: 30)
        let spec = fakeSpec(mode: "stream-json-stdin", effortLevel: nil)
        let standby = try StandbyCLIProcess.spawn(spec)
        slot.install(standby)
        #expect(slot.hasHealthyProcess(matching: spec))

        let taken = slot.take(matching: spec)
        #expect(taken.outcome == .matched)
        #expect(taken.process === standby)
        #expect(slot.currentProcess == nil)
        standby.reap()
        #expect(await waitUntil(timeoutSeconds: 5) { !standby.isRunning })
    }

    @Test func effortChangeReapsAndAsksForRespawn() async throws {
        let slot = StandbyCLISlot(idleLimitSeconds: 30)
        let reapLog = ReapLog()
        slot.onReap = { _, reason in reapLog.append(reason) }
        let standby = try StandbyCLIProcess.spawn(fakeSpec(mode: "stream-json-stdin"))
        slot.install(standby)

        let turnSpec = fakeSpec(mode: "stream-json-stdin", effortLevel: "medium")
        #expect(!slot.hasHealthyProcess(matching: turnSpec))
        let taken = slot.take(matching: turnSpec)
        #expect(taken.outcome == .mismatched)
        #expect(taken.process == nil)
        #expect(reapLog.all == [.mismatched])
        #expect(await waitUntil(timeoutSeconds: 5) { !standby.isRunning })

        // The caller spawns fresh for the turn's spec.
        let respawned = try StandbyCLIProcess.spawn(turnSpec)
        try respawned.writeMessageAndCloseInput(messageLine)
        let output = String(decoding: respawned.standardOutputHandle.readDataToEndOfFile(), as: UTF8.self)
        await respawned.waitForExit()
        #expect(output.contains("got \(messageLine.count)"))
    }

    @Test func promptTextChangeIsAMismatch() async throws {
        let slot = StandbyCLISlot(idleLimitSeconds: 30)
        let standby = try StandbyCLIProcess.spawn(fakeSpec(mode: "stream-json-stdin"))
        slot.install(standby)
        var whiteboardSpec = fakeSpec(mode: "stream-json-stdin")
        whiteboardSpec.systemPromptText = "prompt with whiteboard"
        #expect(slot.take(matching: whiteboardSpec).outcome == .mismatched)
        #expect(await waitUntil(timeoutSeconds: 5) { !standby.isRunning })
    }

    @Test func exitedStandbyIsUnhealthy() async throws {
        let slot = StandbyCLISlot(idleLimitSeconds: 30)
        let spec = fakeSpec(mode: "exit-now")
        let standby = try StandbyCLIProcess.spawn(spec)
        slot.install(standby)
        await standby.waitForExit()
        let taken = slot.take(matching: spec)
        #expect(taken.outcome == .unhealthy)
        #expect(taken.process == nil)
        #expect(slot.take(matching: spec).outcome == .empty)
    }

    @Test func brokenPipeRespawnsAndRetriesOnce() async throws {
        let deadStandby = try StandbyCLIProcess.spawn(fakeSpec(mode: "exit-now"))
        await deadStandby.waitForExit()
        var respawnCount = 0
        let delivered = try StandbyCLIDelivery.deliver(messageLine, to: deadStandby) {
            respawnCount += 1
            return try StandbyCLIProcess.spawn(fakeSpec(mode: "stream-json-stdin"))
        }
        #expect(respawnCount == 1)
        #expect(delivered.didRetryAfterBrokenPipe)
        #expect(delivered.process !== deadStandby)
        let output = String(decoding: delivered.process.standardOutputHandle.readDataToEndOfFile(), as: UTF8.self)
        await delivered.process.waitForExit()
        #expect(output.contains("got \(messageLine.count)"))
    }

    @Test func secondBrokenPipeIsThrown() async throws {
        let deadStandby = try StandbyCLIProcess.spawn(fakeSpec(mode: "exit-now"))
        await deadStandby.waitForExit()
        var respawnCount = 0
        var respawnedProcesses: [StandbyCLIProcess] = []
        #expect(throws: StandbyCLIError.brokenPipe) {
            _ = try StandbyCLIDelivery.deliver(messageLine, to: deadStandby) {
                respawnCount += 1
                let respawned = try StandbyCLIProcess.spawn(fakeSpec(mode: "exit-now"))
                respawned.process.waitUntilExit()
                respawnedProcesses.append(respawned)
                return respawned
            }
        }
        #expect(respawnCount == 1)
        #expect(respawnedProcesses.allSatisfy { !$0.isRunning })
    }

    @Test func healthyWriteDoesNotRespawn() async throws {
        let standby = try StandbyCLIProcess.spawn(fakeSpec(mode: "stream-json-stdin"))
        let delivered = try StandbyCLIDelivery.deliver(messageLine, to: standby) {
            Issue.record("respawned a healthy process")
            return standby
        }
        #expect(!delivered.didRetryAfterBrokenPipe)
        #expect(delivered.process === standby)
        _ = standby.standardOutputHandle.readDataToEndOfFile()
        await standby.waitForExit()
    }

    @Test func cancelReapsAWaitingProcess() async throws {
        let standby = try StandbyCLIProcess.spawn(fakeSpec(mode: "stream-json-stdin"))
        #expect(standby.isRunning)
        standby.reap()
        #expect(!standby.isHealthy)
        #expect(await waitUntil(timeoutSeconds: 5) { !standby.isRunning })
        // A reaped process takes no message.
        #expect(throws: StandbyCLIError.brokenPipe) { try standby.writeMessageAndCloseInput(messageLine) }
    }

    @Test func idleStandbyIsReaped() async throws {
        let slot = StandbyCLISlot(idleLimitSeconds: 0.3)
        let reapLog = ReapLog()
        slot.onReap = { _, reason in reapLog.append(reason) }
        let standby = try StandbyCLIProcess.spawn(fakeSpec(mode: "stream-json-stdin"))
        slot.install(standby)
        #expect(await waitUntil(timeoutSeconds: 5) { !reapLog.all.isEmpty })
        #expect(slot.currentProcess == nil)
        #expect(reapLog.all == [.idle])
        #expect(await waitUntil(timeoutSeconds: 5) { !standby.isRunning })
    }

    @Test func takenStandbyIsNotIdleReaped() async throws {
        let slot = StandbyCLISlot(idleLimitSeconds: 0.2)
        let reapLog = ReapLog()
        slot.onReap = { _, reason in reapLog.append(reason) }
        let spec = fakeSpec(mode: "stream-json-stdin")
        let standby = try StandbyCLIProcess.spawn(spec)
        slot.install(standby)
        #expect(slot.take(matching: spec).outcome == .matched)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(reapLog.all.isEmpty)
        #expect(standby.isHealthy)
        standby.reap()
        #expect(await waitUntil(timeoutSeconds: 5) { !standby.isRunning })
    }

    @Test func installReplacesAndReapsThePrevious() async throws {
        let slot = StandbyCLISlot(idleLimitSeconds: 30)
        let first = try StandbyCLIProcess.spawn(fakeSpec(mode: "stream-json-stdin"))
        let second = try StandbyCLIProcess.spawn(fakeSpec(mode: "stream-json-stdin", effortLevel: "low"))
        slot.install(first)
        slot.install(second)
        #expect(slot.currentProcess === second)
        #expect(await waitUntil(timeoutSeconds: 5) { !first.isRunning })
        slot.reapWaiting()
        #expect(slot.currentProcess == nil)
        #expect(await waitUntil(timeoutSeconds: 5) { !second.isRunning })
    }

    @Test func zoomCheckArgumentsIncludeMaxTurns() {
        let arguments = ClaudeArgs(model: "haiku", systemPromptFileURL: URL(fileURLWithPath: "/tmp/p.md"), maximumTurns: 1).arguments
        #expect(arguments.contains("--max-turns"))
        #expect(arguments[arguments.firstIndex(of: "--max-turns")! + 1] == "1")
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "")
        #expect(!ClaudeArgs(model: "sonnet", systemPromptFileURL: URL(fileURLWithPath: "/tmp/p.md")).arguments.contains("--max-turns"))
    }
}
