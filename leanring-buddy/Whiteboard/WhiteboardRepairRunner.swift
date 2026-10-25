//
//  WhiteboardRepairRunner.swift
//  leanring-buddy
//
//  Runs ClickyCore's WBRepairRequest: the one-shot, tool-less CLI call that
//  rewrites a board the local repair ladder couldn't save into
//  schema-constrained JSON. Same isolation as every other call (ClaudeArgs
//  argv, $TMPDIR/clicky-session, the app's environment), with the main
//  brain's model. A plain Foundation Process, off the main actor, at most
//  60 s. Returns nil on any failure (the answer then goes on without a board).
//

import ClickyCore
import Foundation

enum WhiteboardRepairRunner {
    nonisolated static let timeoutSeconds: TimeInterval = 60

    /// The repaired board (nil: none usable) and the call's tokens and cost
    /// (from the `--output-format json` result) for the Agents dashboard.
    struct RepairResult {
        let outcome: WBParseOutcome?
        let usage: AgentUsage?
    }

    static func repair(brokenBoardText: String, model: String) async -> RepairResult {
        guard let systemPromptFileURL = try? ClaudeArgs.writePromptFile(named: WBRepairRequest.systemPromptFileName,
                                                                        contents: WBRepairRequest.systemPromptText) else { return RepairResult(outcome: nil, usage: nil) }
        let request = WBRepairRequest(brokenBoardText: brokenBoardText, model: model, systemPromptFileURL: systemPromptFileURL)
        guard let executableURL = ClaudeCodeBridge.locateClaudeCodeExecutable() else { return RepairResult(outcome: nil, usage: nil) }
        let resultText: String? = await Task.detached(priority: .userInitiated) {
            runCLI(request, executableURL: executableURL)
        }.value
        guard let resultText else { return RepairResult(outcome: nil, usage: nil) }
        let usage = AgentUsage.fromResultLine(Data(resultText.utf8), model: model)
        let outcome = WBRepairRequest.board(fromCLIResult: resultText)
        return RepairResult(outcome: outcome?.isUsable == true ? outcome : nil, usage: usage)
    }

    nonisolated private static func runCLI(_ request: WBRepairRequest, executableURL: URL) -> String? {
        try? FileManager.default.createDirectory(at: request.workingDirectoryURL, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectoryURL
        process.environment = request.environment
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            print("⚠️ Board repair: couldn't start claude: \(error)")
            return nil
        }
        standardInput.fileHandleForWriting.write(Data(request.standardInputText.utf8))
        try? standardInput.fileHandleForWriting.close()

        let timeoutWorkItem = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWorkItem.cancel()
        guard process.terminationStatus == 0 else {
            print("⚠️ Board repair: claude exited with \(process.terminationStatus)")
            return nil
        }
        return String(data: outputData, encoding: .utf8)
    }
}
