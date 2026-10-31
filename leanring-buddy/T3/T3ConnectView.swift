//
//  T3ConnectView.swift
//  leanring-buddy
//
//  One-button "Connect Theo to T3 Code": detects the agents and T3 apps on this Mac,
//  installs the Theo extension into all of them, then proves it works by starting the
//  MCP server (`Clicky --mcp`) as a real subprocess and talking JSON-RPC to it
//  (initialize, tools/list, tools/call claudia_status).
//

import AppKit
import Combine
import SwiftUI

// MARK: - Self-test

enum T3ConnectSelfTest {
    struct Result {
        var passed: Bool
        var summary: String
        var detail: String
    }

    /// Starts `<executable> --mcp`, sends initialize + tools/list + tools/call claudia_status,
    /// checks each reply, then kills the process. Blocking: call it off the main thread.
    static func run(executablePath: String, timeout: TimeInterval = 25) -> Result {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return Result(passed: false, summary: "Theo's program wasn't found",
                          detail: "Expected an executable at:\n\(executablePath)\nMove Theo to /Applications and press Fix.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--mcp"]
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do { try process.run() } catch {
            return Result(passed: false, summary: "Couldn't start Theo's MCP server",
                          detail: "Starting \(executablePath) --mcp failed:\n\(error.localizedDescription)")
        }
        defer { if process.isRunning { process.terminate() } }

        let lock = NSLock()
        var replies: [Int: [String: Any]] = [:]
        var rawOutput = ""
        let gotAll = DispatchSemaphore(value: 0)
        var signalled = false
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            rawOutput += String(data: data, encoding: .utf8) ?? ""
            for line in rawOutput.components(separatedBy: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let id = object["id"] as? Int else { continue }
                replies[id] = object
            }
            if replies[1] != nil, replies[2] != nil, replies[3] != nil, !signalled { signalled = true; gotAll.signal() }
        }
        var stderrText = ""
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); stderrText += String(data: data, encoding: .utf8) ?? ""; lock.unlock()
        }

        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "theo-self-test", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "claudia_status", "arguments": [:]]]
        ]
        for request in requests {
            guard let data = try? JSONSerialization.data(withJSONObject: request) else { continue }
            // A server that already quit makes a plain write raise (EPIPE) and take the app down.
            guard process.isRunning else { break }
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        }
        let waitResult = gotAll.wait(timeout: .now() + timeout)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminate()

        lock.lock()
        let snapshot = replies, raw = rawOutput, errText = stderrText
        lock.unlock()
        let tail = "\n\nstdout:\n\(raw.isEmpty ? "(nothing)" : String(raw.prefix(2000)))\nstderr:\n\(errText.isEmpty ? "(nothing)" : String(errText.prefix(2000)))"

        if waitResult == .timedOut {
            let missing = [1: "initialize", 2: "tools/list", 3: "claudia_status call"].filter { snapshot[$0.key] == nil }.map(\.value).sorted()
            return Result(passed: false, summary: "Theo's MCP server didn't answer in time",
                          detail: "No reply to: \(missing.joined(separator: ", ")) within \(Int(timeout))s." + tail)
        }
        guard let initResult = snapshot[1]?["result"] as? [String: Any], let serverInfo = initResult["serverInfo"] as? [String: Any],
              (serverInfo["name"] as? String) == "theo" else {
            return Result(passed: false, summary: "initialize returned something unexpected", detail: "Reply: \(String(describing: snapshot[1]))" + tail)
        }
        let toolNames = ((snapshot[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        guard toolNames.contains("claudia_status"), toolNames.contains("claudia_ask") else {
            return Result(passed: false, summary: "tools/list is missing Theo's tools", detail: "Tools seen: \(toolNames)" + tail)
        }
        guard let callResult = snapshot[3]?["result"] as? [String: Any] else {
            return Result(passed: false, summary: "claudia_status returned an error", detail: "Reply: \(String(describing: snapshot[3]))" + tail)
        }
        let text = ((callResult["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        if (callResult["isError"] as? Bool) == true {
            return Result(passed: false, summary: "claudia_status failed: \(text.prefix(120))", detail: "Theo answered with an error:\n\(text)" + tail)
        }
        return Result(passed: true, summary: "Theo answered (\(toolNames.count) tools)",
                      detail: "initialize OK (server \"theo\"), tools/list returned \(toolNames.count) tools, claudia_status replied:\n\(text.prefix(600))")
    }
}

// MARK: - Model

@MainActor
final class T3ConnectModel: ObservableObject {
    enum StepState { case pending, running, done, failed }
    struct Step: Identifiable {
        var id: String
        var title: String
        var state: StepState = .pending
        var detail: String = ""
    }
    struct AgentRow: Identifiable {
        var agent: ClaudiaT3Integration.Agent
        var onThisMac: Bool
        var configPresent: Bool
        var selfTestPassed: Bool?
        var errorText: String
        var id: String { agent.rawValue }
        var connected: Bool { onThisMac && configPresent && selfTestPassed == true }
    }

    @Published var steps: [Step] = T3ConnectModel.freshSteps()
    @Published var rows: [AgentRow] = []
    @Published var t3Apps: [URL] = []
    @Published var isRunning = false
    @Published var connected = false
    @Published var hasRun = false
    @Published var selfTest: T3ConnectSelfTest.Result?

    private var lastInstallErrors: [String: String] = [:]

    static func freshSteps() -> [Step] {
        [Step(id: "detect", title: "Detecting agents and T3 Code"),
         Step(id: "install", title: "Installing the Theo extension"),
         Step(id: "test", title: "Testing the connection"),
         Step(id: "done", title: "Connected")]
    }

    func refreshStatus() {
        t3Apps = ClaudiaT3Integration.t3Apps
        rows = buildRows()
    }

    private func buildRows() -> [AgentRow] {
        let status = ClaudiaT3Integration.status()
        let present: [ClaudiaT3Integration.Agent: Bool] = [.claude: status.claude ?? false, .codex: status.codex ?? false, .openCode: status.openCode ?? false]
        return ClaudiaT3Integration.Agent.allCases.map { agent in
            var configPresent = present[agent] ?? false
            // Codex/OpenCode store the program path: it must still point at a program that exists.
            if configPresent, agent == .codex {
                let text = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
                configPresent = text.contains(ClaudiaT3Integration.executablePath)
            }
            return AgentRow(agent: agent, onThisMac: agent.isOnThisMac, configPresent: configPresent,
                            selfTestPassed: selfTest?.passed, errorText: lastInstallErrors[agent.rawValue] ?? "")
        }
    }

    private func setStep(_ id: String, _ state: StepState, _ detail: String = "") {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].state = state
        steps[index].detail = detail
    }

    /// The full flow. `only` limits the install to one agent (the Fix button); the self-test always runs.
    func connect(only: ClaudiaT3Integration.Agent? = nil) {
        guard !isRunning else { return }
        isRunning = true; connected = false; hasRun = true; selfTest = nil
        steps = Self.freshSteps()
        lastInstallErrors = [:]
        Task {
            setStep("detect", .running)
            try? await Task.sleep(nanoseconds: 350_000_000)
            t3Apps = ClaudiaT3Integration.t3Apps
            let available = Set(ClaudiaT3Integration.Agent.allCases.filter { $0.isOnThisMac })
            let targets = only.map { Set([$0]) } ?? available
            let agentNames = available.map(\.title).sorted().joined(separator: ", ")
            let appNames = t3Apps.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", ")
            setStep("detect", .done, "Agents: \(agentNames.isEmpty ? "none found" : agentNames). T3 Code: \(appNames.isEmpty ? "not found in Applications" : appNames).")
            if targets.isEmpty {
                setStep("install", .failed, "No supported agent (Claude Code, Codex, OpenCode) was found on this Mac. Install one, then press the button again.")
                finish(); return
            }

            setStep("install", .running)
            let installResult: (ClaudiaT3Integration.Outcome, [String: String]) = await Task.detached(priority: .userInitiated) {
                let outcome = ClaudiaT3Integration.install(agents: targets)
                var errors: [String: String] = [:]
                for line in outcome.lines where line.hasPrefix("✗") {
                    // The integration cuts messages short, so re-run the failing step for the full text.
                    if line.contains("Claude Code") { errors["claude"] = Self.fullClaudeError(fallback: line) }
                    else if line.contains("Codex") { errors["codex"] = line }
                    else if line.contains("OpenCode") { errors["openCode"] = line }
                    else { for target in targets { errors[target.rawValue] = line } }
                }
                return (outcome, errors)
            }.value
            lastInstallErrors = installResult.1
            if installResult.0.succeeded {
                setStep("install", .done, installResult.0.lines.joined(separator: "\n"))
            } else {
                setStep("install", .failed, installResult.0.lines.joined(separator: "\n"))
            }

            setStep("test", .running)
            let path = ClaudiaT3Integration.executablePath
            let result = await Task.detached(priority: .userInitiated) { T3ConnectSelfTest.run(executablePath: path) }.value
            selfTest = result
            setStep("test", result.passed ? .done : .failed, result.passed ? result.detail : "\(result.summary)\n\(result.detail)")
            rows = buildRows()
            let allGood = installResult.0.succeeded && result.passed && rows.filter { $0.onThisMac }.allSatisfy { $0.configPresent }
            if allGood { setStep("done", .done, "Restart your T3 thread, then type $ to use Theo."); connected = true }
            else { setStep("done", .failed, "Not connected yet. Open the failing step above for the full error, or press Fix on an agent below.") }
            isRunning = false
        }
    }

    private func finish() {
        rows = buildRows()
        setStep("done", .failed, "Not connected yet.")
        isRunning = false
    }

    nonisolated private static func fullClaudeError(fallback: String) -> String {
        guard let claude = ClaudeCodeBridge.locateClaudeCodeExecutable() else { return fallback }
        let directory = ClaudiaT3Integration.extensionDirectory.path
        let add = runCapturing(claude.path, ["plugin", "marketplace", "add", directory])
        if add.0 != 0 { return "claude plugin marketplace add \(directory)\nexit \(add.0)\n\(add.1)" }
        let install = runCapturing(claude.path, ["plugin", "install", "theo@theo"])
        if install.0 != 0 { return "claude plugin install theo@theo\nexit \(install.0)\n\(install.1)" }
        return fallback
    }

    nonisolated private static func runCapturing(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "couldn't start \(executable)") }
        // A hung install (network, a prompt) is stopped after two minutes, so Connect never stays stuck.
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: deadline)
        defer { deadline.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - View

struct T3ConnectView: View {
    @StateObject private var model = T3ConnectModel()
    private let accent = LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 0.93, green: 0.27, blue: 0.45), Color(red: 0.75, green: 0.27, blue: 0.9)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
    /// The release that carries the T3 Code Cursor Assistant build (T3-Code-Cursor-Assistant-arm64.zip).
    static let builtInReleaseURL = URL(string: "https://github.com/adhyanmahajan26-boop/clicky/releases/latest")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            connectCard
            if model.hasRun { stepsCard }
            agentsCard
            downloadCard
        }
        .onAppear { model.refreshStatus() }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.connected ? "checkmark.seal.fill" : "link.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(model.connected ? AnyShapeStyle(Color.green) : AnyShapeStyle(accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.connected ? "Theo is connected to T3 Code" : "Connect Theo to T3 Code").font(.system(size: 16, weight: .semibold))
                    Text("One click installs Theo's tools and skills into Claude Code, Codex and OpenCode, then checks that they really work.")
                        .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: { model.connect() }) {
                HStack(spacing: 8) {
                    if model.isRunning { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: model.connected ? "arrow.clockwise" : "bolt.fill") }
                    Text(model.isRunning ? "Connecting…" : (model.connected ? "Run the test again" : "Connect Theo to T3 Code"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent))
                .opacity(model.isRunning ? 0.7 : 1)
            }
            .buttonStyle(.plain)
            .disabled(model.isRunning)
            if model.connected {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill").foregroundColor(.green)
                    Text("Next: restart your T3 thread, then type $ to use Theo.").font(.system(size: 13, weight: .medium))
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.green.opacity(0.12)))
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.steps) { step in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        stepIcon(step.state)
                        Text(stepTitle(step)).font(.system(size: 13, weight: .medium))
                            .foregroundColor(step.state == .pending ? .secondary : .primary)
                    }
                    if !step.detail.isEmpty && step.state != .pending {
                        Text(step.detail).font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(step.state == .failed ? .red : .secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 26)
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }

    private func stepTitle(_ step: T3ConnectModel.Step) -> String {
        switch (step.id, step.state) {
        case ("detect", .running): return "Detecting…"
        case ("install", .running): return "Installing…"
        case ("test", .running): return "Testing…"
        case ("done", .done): return "Connected ✓"
        case ("done", .failed): return "Not connected"
        default: return step.title
        }
    }

    @ViewBuilder private func stepIcon(_ state: T3ConnectModel.StepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundColor(.secondary).frame(width: 18)
        case .running: ProgressView().controlSize(.small).frame(width: 18)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green).frame(width: 18)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundColor(.red).frame(width: 18)
        }
    }

    private var agentsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agents").font(.system(size: 13, weight: .semibold))
            ForEach(model.rows) { row in AgentRowView(row: row, isRunning: model.isRunning, fix: { model.connect(only: row.agent) }) }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "macwindow").foregroundColor(.secondary)
                if model.t3Apps.isEmpty {
                    Text("No T3 Code app found in Applications. The extension still works once T3 Code is installed.").font(.system(size: 11.5)).foregroundColor(.secondary)
                } else {
                    Text("T3 Code on this Mac:").font(.system(size: 11.5)).foregroundColor(.secondary)
                    ForEach(model.t3Apps, id: \.self) { app in
                        Button(app.deletingPathExtension().lastPathComponent) { NSWorkspace.shared.open(app) }.controlSize(.small)
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }

    private var downloadCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.app.fill").font(.system(size: 22)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Get T3 Code with Theo built in").font(.system(size: 13, weight: .semibold))
                Text("Optional. A separate T3 Code build with a Theo page, Ask Theo and a notes button in every thread already included. You don't need it for the connection above. Download T3-Code-Cursor-Assistant-arm64.zip from the latest release.")
                    .font(.system(size: 11.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open download page") { NSWorkspace.shared.open(Self.builtInReleaseURL) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

private struct AgentRowView: View {
    let row: T3ConnectModel.AgentRow
    let isRunning: Bool
    let fix: () -> Void
    @State private var expanded = false

    private var statusText: String {
        if !row.onThisMac { return "Not installed on this Mac" }
        if !row.configPresent { return "Extension not installed" }
        switch row.selfTestPassed {
        case .some(true): return "Connected: config present, self-test passed"
        case .some(false): return "Config present, but the self-test failed"
        case .none: return "Config present, not tested yet"
        }
    }

    private var statusColor: Color {
        if !row.onThisMac { return .secondary }
        if row.connected { return .green }
        return row.configPresent && row.selfTestPassed == nil ? .orange : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: row.connected ? "checkmark.circle.fill" : (row.onThisMac ? "exclamationmark.circle.fill" : "minus.circle"))
                    .foregroundColor(statusColor).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.agent.title).font(.system(size: 13, weight: .medium))
                    Text(statusText).font(.system(size: 11.5)).foregroundColor(.secondary)
                }
                Spacer()
                if row.onThisMac {
                    Button(row.connected ? "Reinstall" : "Fix", action: fix).controlSize(.small).disabled(isRunning)
                }
                if row.onThisMac {
                    Button(action: { expanded.toggle() }) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.plain).foregroundColor(.secondary)
                }
            }
            if expanded {
                Text(detailText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .foregroundColor(row.errorText.isEmpty ? .secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))
            }
        }
    }

    private var detailText: String {
        var parts: [String] = []
        switch row.agent {
        case .claude: parts.append("Checks: ~/.claude/plugins/installed_plugins.json contains theo@theo")
        case .codex: parts.append("Checks: ~/.codex/config.toml has [mcp_servers.theo] pointing at \(ClaudiaT3Integration.executablePath)")
        case .openCode: parts.append("Checks: ~/.config/opencode/opencode.json has an mcp entry named theo")
        }
        parts.append("Config present: \(row.configPresent ? "yes" : "no")")
        parts.append("Self-test: \(row.selfTestPassed.map { $0 ? "passed" : "failed" } ?? "not run")")
        if !row.errorText.isEmpty { parts.append("\nError:\n\(row.errorText)") }
        return parts.joined(separator: "\n")
    }
}
