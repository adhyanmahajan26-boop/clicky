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
    /// The release that carries the T3 Code Cursor Assistant build (T3-Code-Cursor-Assistant-arm64.zip): this build's
    /// releases repo (Config/Theo.xcconfig), the one place people who aren't the owner can download from.
    /// Nil only for a build made without a releases repo, which then has no download button.
    static let builtInReleaseURL: URL? = UpdateFeed.bundledReleasesRepository.flatMap(UpdateFeed.releasesPageURL(repository:))

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.connected ? "Theo is connected to T3 Code" : "One click adds Theo's tools to your agents")
                        .font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                    Text(model.connected ? "Restart your T3 thread, then type $ to use Theo." : "Installs them into Claude Code, Codex and OpenCode, then checks they really answer.")
                        .font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: { model.connect() }) {
                    HStack(spacing: 6) {
                        if model.isRunning { ProgressView().controlSize(.mini) }
                        Text(model.isRunning ? "Connecting…" : (model.connected ? "Test again" : "Connect"))
                    }
                }
                .buttonStyle(model.connected ? .theoSecondary : .theoPrimary)
                .disabled(model.isRunning)
            }
            if model.hasRun { steps }
            agents
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.hover))
        .onAppear { model.refreshStatus() }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.steps) { step in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        stepIcon(step.state)
                        Text(stepTitle(step)).font(TheoType.caption).foregroundColor(step.state == .pending ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    }
                    if !step.detail.isEmpty && step.state != .pending {
                        Text(step.detail).font(.system(size: 11, design: .monospaced))
                            .foregroundColor(step.state == .failed ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).lineLimit(8)
                            .padding(.leading, 24)
                    }
                }
            }
        }
    }

    private func stepTitle(_ step: T3ConnectModel.Step) -> String {
        switch (step.id, step.state) {
        case ("detect", .running): return "Detecting…"
        case ("install", .running): return "Installing…"
        case ("test", .running): return "Testing…"
        case ("done", .done): return "Connected"
        case ("done", .failed): return "Not connected"
        default: return step.title
        }
    }

    @ViewBuilder private func stepIcon(_ state: T3ConnectModel.StepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").font(.system(size: 12)).foregroundColor(DS.Colors.textDisabled).frame(width: 16)
        case .running: ProgressView().controlSize(.mini).frame(width: 16)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(DS.Colors.success).frame(width: 16)
        case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(DS.Colors.destructiveText).frame(width: 16)
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.rows) { row in AgentRowView(row: row, isRunning: model.isRunning, fix: { model.connect(only: row.agent) }) }
            if !model.t3Apps.isEmpty {
                HStack(spacing: 6) {
                    Text("T3 Code on this Mac").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                    ForEach(model.t3Apps, id: \.self) { app in
                        Button(app.deletingPathExtension().lastPathComponent) { NSWorkspace.shared.open(app) }.buttonStyle(.theo(.secondary, .small))
                    }
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 6) {
                    Text("No T3 Code app in Applications. Theo's tools still work once it's installed.").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                    if let builtInReleaseURL = Self.builtInReleaseURL {
                        Button("Get the build with Theo inside") { NSWorkspace.shared.open(builtInReleaseURL) }.buttonStyle(.theo(.ghost, .small))
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct AgentRowView: View {
    let row: T3ConnectModel.AgentRow
    let isRunning: Bool
    let fix: () -> Void
    @State private var expanded = false

    private var statusText: String {
        if !row.onThisMac { return "Not on this Mac" }
        if !row.configPresent { return "Tools not added" }
        switch row.selfTestPassed {
        case .some(true): return "Connected"
        case .some(false): return "Added, but the test failed"
        case .none: return "Added"
        }
    }

    private var tone: StatusPill.Tone {
        if !row.onThisMac { return .neutral }
        if row.connected { return .good }
        return row.configPresent && row.selfTestPassed == nil ? .good : .bad
    }

    private var logo: String { row.agent == .claude ? "claude" : row.agent == .codex ? "codex" : "opencode" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                BrandLogo(id: logo, name: row.agent.title, size: 22)
                Text(row.agent.title).font(TheoType.body).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                StatusPill(text: statusText, tone: tone)
                if row.onThisMac {
                    Button(row.connected ? "Reinstall" : "Fix", action: fix).buttonStyle(.theo(.ghost, .small)).disabled(isRunning)
                    Button { expanded.toggle() } label: {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 14)
                    }
                    .buttonStyle(.theo(.ghost, .small)).help("Details")
                }
            }
            if expanded {
                Text(detailText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .foregroundColor(row.errorText.isEmpty ? DS.Colors.textTertiary : DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.background))
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
