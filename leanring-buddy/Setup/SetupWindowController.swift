//
//  SetupWindowController.swift
//  leanring-buddy
//
//  The Setup window: how Clicky signs in to Claude (the owner's Claude
//  subscription through Claude Code, or an Anthropic API key) and where its
//  voice runs (this Mac's MLX Core, a Qwen voice server on another Mac, or
//  the Mac voice). Each half has a Test button that does a real call.
//
//  It opens by itself until it has been finished once, and again whenever
//  Claude Code is missing or Clicky is opened while it's already running
//  (a menu-bar icon can hide behind a MacBook's notch).
//

import AppKit
import ClickyCore
import Combine
import Speech
import SwiftUI

enum VoiceSource: String, CaseIterable, Identifiable {
    case otherMac
    case thisMac
    case macVoice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .otherMac: return "Voice server on my other Mac"
        case .thisMac: return "Qwen on this Mac (needs MLX Core)"
        case .macVoice: return "Built-in Mac voice"
        }
    }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var authMode: ClickySettings.BrainAuthMode = ClickySettings.brainAuthMode
    @Published var apiKeyField = ""
    @Published private(set) var hasSavedAPIKey = ClickySecrets.read(.anthropicAPIKey) != nil
    @Published private(set) var claudeCodePath: String?
    @Published private(set) var brainTestStatus = ""
    @Published private(set) var isTestingBrain = false

    @Published var voiceSource: VoiceSource

    @Published var mainModel = ClickyModels.main { didSet { companionManager.setSelectedModel(mainModel) } }
    @Published var helperModel = ClickyModels.helper { didSet { ClickyModels.helper = helperModel } }
    @Published var codeModel = ClickyModels.code { didSet { ClickyModels.code = codeModel } }
    @Published var voiceServerURLField = ClickySettings.remoteVoiceServerURL?.absoluteString ?? ""
    @Published var voiceServerKeyField = ""
    @Published private(set) var hasSavedVoiceServerKey = ClickySecrets.read(.voiceServerKey) != nil
    @Published private(set) var voiceTestStatus = ""
    @Published private(set) var isTestingVoice = false

    /// "Check everything": one line per thing Clicky needs, ✓ or ✗ with the fix.
    @Published private(set) var checkLines: [String] = []
    @Published private(set) var isChecking = false

    private let companionManager: CompanionManager
    let showPanel: () -> Void

    init(companionManager: CompanionManager, showPanel: @escaping () -> Void) {
        self.companionManager = companionManager
        self.showPanel = showPanel
        if ClickySettings.remoteVoiceServerURL != nil {
            voiceSource = .otherMac
        } else if QwenLocalTTSClient.isAvailableOnThisMac {
            voiceSource = .thisMac
        } else {
            voiceSource = .macVoice
        }
        refreshClaudeCodePath()
    }

    var isMLXCoreInstalled: Bool { QwenLocalTTSClient.isAvailableOnThisMac }

    func refreshClaudeCodePath() {
        Task.detached {
            let path = ClaudeCodeBridge.locateClaudeCodeExecutable()?.path
            await MainActor.run { self.claudeCodePath = path }
        }
    }

    // MARK: - Brain

    func saveBrainChoice() {
        ClickySettings.brainAuthMode = authMode
        if !apiKeyField.isEmpty {
            ClickySecrets.write(.anthropicAPIKey, value: apiKeyField)
            apiKeyField = ""
        }
        hasSavedAPIKey = ClickySecrets.read(.anthropicAPIKey) != nil
        companionManager.refreshClaudeCodeSignInStatus()
    }

    func forgetAPIKey() {
        ClickySecrets.write(.anthropicAPIKey, value: "")
        hasSavedAPIKey = false
        companionManager.refreshClaudeCodeSignInStatus()
    }

    /// Opens Terminal running Anthropic's installer for Claude Code.
    func installClaudeCode() {
        Self.runInTerminal("curl -fsSL https://claude.ai/install.sh | bash && echo && echo 'Done. Go back to Clicky and press Check again.'")
    }

    /// Opens Terminal running `claude auth login`.
    func signInToClaudeCode() {
        let claudeCommand = claudeCodePath.map { "'\($0)'" } ?? "~/.local/bin/claude"
        Self.runInTerminal("\(claudeCommand) auth login && echo && echo 'Signed in. Go back to Clicky and press Test.'")
    }

    /// One real call through Claude Code with the chosen sign-in.
    func testBrain() {
        saveBrainChoice()
        guard let claudeCodeExecutablePath = claudeCodePath else {
            brainTestStatus = "Claude Code isn't installed yet. Press Install, then Check."
            return
        }
        if authMode == .apiKey, !hasSavedAPIKey {
            brainTestStatus = "Paste your API key first."
            return
        }
        isTestingBrain = true
        brainTestStatus = "Asking Claude…"
        Task {
            let (succeeded, output) = await Self.runClaudeTestCall(executablePath: claudeCodeExecutablePath)
            isTestingBrain = false
            brainTestStatus = succeeded ? "✓ Claude answered: \(output)" : "✗ \(output)"
            companionManager.refreshClaudeCodeSignInStatus()
        }
    }

    private nonisolated static func runClaudeTestCall(executablePath: String) async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = ["-p", "Reply with exactly one word: ready", "--model", ClickyModels.main, "--output-format", "json"]
                process.environment = ClaudeArgs.environment()
                if let workingDirectoryURL = try? ClaudeArgs.prepareSessionWorkingDirectory() {
                    process.currentDirectoryURL = workingDirectoryURL
                }
                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (false, "Couldn't start Claude Code: \(error.localizedDescription)"))
                    return
                }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                let output = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let shortOutput = String(output.suffix(240))
                // The JSON result names the model that really answered, so an old Claude Code shows up here.
                // stderr notes can come before the JSON, which is the last line.
                let jsonLine = output.split(separator: "\n").last.map(String.init) ?? output
                if process.terminationStatus == 0,
                   let resultObject = try? JSONSerialization.jsonObject(with: Data(jsonLine.utf8)) as? [String: Any],
                   resultObject["is_error"] as? Bool != true {
                    let answer = (resultObject["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let answeringModels = ((resultObject["modelUsage"] as? [String: Any])?.keys).map { $0.sorted().joined(separator: ", ") } ?? "unknown model"
                    continuation.resume(returning: (true, "\(answer) (\(answeringModels))"))
                } else if let resultObject = try? JSONSerialization.jsonObject(with: Data(jsonLine.utf8)) as? [String: Any] {
                    let message = resultObject["result"] as? String ?? shortOutput
                    continuation.resume(returning: (false, String(message.prefix(240)) + " If the model isn't found, update Claude Code: claude update"))
                } else {
                    let hint = output.isEmpty ? "Claude Code exited with status \(process.terminationStatus)." : shortOutput
                    continuation.resume(returning: (false, hint))
                }
            }
        }
    }

    // MARK: - Voice

    func saveVoiceChoice() {
        let speechOutput = companionManager.speechOutputClient
        switch voiceSource {
        case .otherMac:
            var urlText = voiceServerURLField.trimmingCharacters(in: .whitespacesAndNewlines)
            if !urlText.isEmpty, !urlText.contains("://") { urlText = "http://" + urlText }
            ClickySettings.remoteVoiceServerURL = URL(string: urlText)
            voiceServerURLField = ClickySettings.remoteVoiceServerURL?.absoluteString ?? urlText
            if !voiceServerKeyField.isEmpty {
                ClickySecrets.write(.voiceServerKey, value: voiceServerKeyField)
                voiceServerKeyField = ""
            }
            hasSavedVoiceServerKey = ClickySecrets.read(.voiceServerKey) != nil
            Self.installBundledReferenceClipIfMissing()
            speechOutput.selectQwenLocalVoice()
        case .thisMac:
            ClickySettings.remoteVoiceServerURL = nil
            Self.installBundledReferenceClipIfMissing()
            speechOutput.selectQwenLocalVoice()
        case .macVoice:
            ClickySettings.remoteVoiceServerURL = nil
            speechOutput.selectSystemVoice(identifier: nil)
        }
        speechOutput.qwenServerSupervisor.reconnect()
    }

    /// Saves the choice, connects, and speaks the preview sentence.
    func testVoice() {
        saveVoiceChoice()
        if voiceSource == .otherMac {
            guard ClickySettings.remoteVoiceServerURL != nil else {
                voiceTestStatus = "Type the voice server's address first."
                return
            }
            guard hasSavedVoiceServerKey else {
                voiceTestStatus = "Paste the voice server key first."
                return
            }
        }
        if voiceSource == .thisMac, !isMLXCoreInstalled {
            voiceTestStatus = "MLX Core isn't installed on this Mac. Pick another voice."
            return
        }
        let speechOutput = companionManager.speechOutputClient
        guard voiceSource != .macVoice else {
            voiceTestStatus = "Speaking with the Mac voice…"
            speechOutput.previewVoice()
            return
        }
        isTestingVoice = true
        voiceTestStatus = "Connecting…"
        Task {
            let supervisor = speechOutput.qwenServerSupervisor
            let isReady = await supervisor.waitUntilReady(timeoutSeconds: 60)
            isTestingVoice = false
            if isReady {
                voiceTestStatus = "✓ \(supervisor.status). Speaking…"
                speechOutput.previewVoice()
            } else {
                voiceTestStatus = "✗ \(supervisor.status)"
            }
        }
    }

    /// The bundled clip becomes ~/.clicky/voice/clicky-voice.wav when there's none, so every answer has the same voice.
    static func installBundledReferenceClipIfMissing() {
        let destinationPath = ClickySettings.qwenReferenceClipPath
        guard !FileManager.default.fileExists(atPath: destinationPath),
              let bundledClipURL = Bundle.main.url(forResource: "clicky-voice", withExtension: "wav") else { return }
        let destinationURL = URL(fileURLWithPath: destinationPath)
        try? FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: bundledClipURL, to: destinationURL)
        print("🔊 Setup: installed the bundled voice clip at \(destinationPath)")
    }

    // MARK: - Check everything

    func checkEverything() {
        isChecking = true
        companionManager.refreshAllPermissions()
        var lines: [String] = []
        lines.append(companionManager.hasMicrophonePermission ? "✓ Microphone" : "✗ Microphone: grant it in the permissions panel")
        lines.append(companionManager.hasAccessibilityPermission ? "✓ Accessibility"
                     : "✗ Accessibility: grant it, or marks are guesses from the screenshot and Clicky can't click or type")
        lines.append(companionManager.hasScreenRecordingPermission ? "✓ Screen Recording" : "✗ Screen Recording: grant it, then quit and reopen Clicky")
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        if speechStatus != .authorized {
            lines.append("✗ Speech Recognition: not allowed yet (it's asked the first time you talk)")
        } else if speechRecognizer?.isAvailable != true {
            lines.append("✗ Speech Recognition: unavailable. Turn on Dictation in System Settings › Keyboard")
        } else {
            lines.append("✓ Speech Recognition" + (speechRecognizer?.supportsOnDeviceRecognition == true ? " (on-device)" : ""))
        }
        checkLines = lines + ["… checking Claude Code"]
        let claudeCodeExecutablePath = claudeCodePath
        Task {
            var claudeLines: [String] = []
            if let claudeCodeExecutablePath {
                let version = await Self.runQuietly(executablePath: claudeCodeExecutablePath, arguments: ["--version"])
                claudeLines.append("✓ Claude Code \(version.isEmpty ? "(version unknown)" : version)")
                let (succeeded, output) = await Self.runClaudeTestCall(executablePath: claudeCodeExecutablePath)
                claudeLines.append(succeeded ? "✓ Claude answers: \(output)" : "✗ Claude: \(output)")
            } else {
                claudeLines.append("✗ Claude Code isn't installed: press Install above")
            }
            let speechOutput = companionManager.speechOutputClient
            if speechOutput.usesQwenLocalVoice {
                let isReady = await speechOutput.qwenServerSupervisor.waitUntilReady(timeoutSeconds: 30)
                claudeLines.append(isReady ? "✓ \(speechOutput.qwenServerSupervisor.status)" : "✗ \(speechOutput.qwenServerSupervisor.status) (the Mac voice speaks instead)")
            } else {
                claudeLines.append("✓ Voice: built-in Mac voice")
            }
            checkLines = lines + claudeLines
            isChecking = false
        }
    }

    private nonisolated static func runQuietly(executablePath: String, arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continuation.resume(returning: ""); return }
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }
        }
    }

    // MARK: - Finish

    func finish() {
        saveBrainChoice()
        ClickySettings.isSetupCompleted = true
        SetupWindowController.close()
        showPanel()
    }

    /// Writes a one-off .command file and opens it, so Terminal runs it
    /// (no AppleScript, so no Automation prompt).
    static func runInTerminal(_ shellCommand: String) {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-setup-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/zsh -l\n\(shellCommand)\n"
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            NSWorkspace.shared.open(scriptURL)
        } catch {
            print("⚠️ Setup: couldn't open Terminal: \(error)")
        }
    }
}

@MainActor
enum SetupWindowController {
    private static var window: NSWindow?
    private static var model: SetupModel?

    /// True when the window should open at launch: never finished, or Claude Code is missing.
    static var isNeededAtLaunch: Bool {
        !ClickySettings.isSetupCompleted || ClaudeCodeBridge.locateClaudeCodeExecutable() == nil
    }

    static func show(companionManager: CompanionManager, showPanel: @escaping () -> Void) {
        if model == nil {
            model = SetupModel(companionManager: companionManager, showPanel: showPanel)
        }
        guard let model else { return }
        model.refreshClaudeCodePath()

        if window == nil {
            let createdWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                                         styleMask: [.titled, .closable, .resizable],
                                         backing: .buffered, defer: false)
            createdWindow.title = "Clicky Setup"
            createdWindow.isReleasedWhenClosed = false
            createdWindow.contentView = NSHostingView(rootView: SetupView(model: model))
            createdWindow.center()
            window = createdWindow
        }
        // An accessory app can't always take focus at launch (macOS stops
        // activation stealing), so the window floats and is ordered front regardless.
        window?.level = .floating
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.orderOut(nil)
    }
}

private struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Set up Clicky")
                    .font(.system(size: 20, weight: .semibold))
                Text("Clicky lives in the menu bar (the sparkle icon). If you can't see it, open Clicky again from Applications to bring this window back.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox(label: Text("1. Claude").font(.headline)) {
                    brainSection.padding(8)
                }
                GroupBox(label: Text("2. Voice").font(.headline)) {
                    voiceSection.padding(8)
                }
                GroupBox(label: Text("3. Models").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        modelPicker("Answers", selection: $model.mainModel)
                        modelPicker("Helpers, research, mark checks", selection: $model.helperModel)
                        modelPicker("Code tasks", selection: $model.codeModel)
                        Text("Clicky passes these exact model ids to Claude Code.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                GroupBox(label: Text("4. Permissions").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Clicky needs Microphone, Speech Recognition, Accessibility and Screen Recording. The menu-bar panel has a button for each.")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open the permissions panel") { model.showPanel() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox(label: Text("5. Check everything").font(.headline)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(model.isChecking ? "Checking…" : "Check everything") { model.checkEverything() }
                            .disabled(model.isChecking)
                        ForEach(model.checkLines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 12))
                                .foregroundColor(line.hasPrefix("✗") ? .orange : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                HStack {
                    Spacer()
                    Button("Done") { model.finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ClickyModels.options, id: \.identifier) { option in
                Text(option.label).tag(option.identifier)
            }
            if !ClickyModels.options.contains(where: { $0.identifier == selection.wrappedValue }) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
    }

    private var brainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: model.claudeCodePath == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(model.claudeCodePath == nil ? .orange : .green)
                Text(model.claudeCodePath == nil ? "Claude Code isn't installed" : "Claude Code found")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if model.claudeCodePath == nil {
                    Button("Install") { model.installClaudeCode() }
                }
                Button("Check") { model.refreshClaudeCodePath() }
            }
            Text("Clicky talks to Claude through Claude Code, whichever way you sign in.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Picker("Sign in with", selection: $model.authMode) {
                Text("My Claude subscription (Pro or Max)").tag(ClickySettings.BrainAuthMode.subscription)
                Text("An Anthropic API key").tag(ClickySettings.BrainAuthMode.apiKey)
            }
            .pickerStyle(.radioGroup)

            if model.authMode == .subscription {
                HStack {
                    Text("Sign in once in Terminal.")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Sign in…") { model.signInToClaudeCode() }
                        .disabled(model.claudeCodePath == nil)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField(model.hasSavedAPIKey ? "Saved in the Keychain (paste a new one to replace it)" : "sk-ant-…",
                                text: $model.apiKeyField)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Get one at console.anthropic.com. Usage is billed to that account.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        if model.hasSavedAPIKey {
                            Button("Forget key") { model.forgetAPIKey() }
                        }
                    }
                }
            }

            HStack {
                Button(model.isTestingBrain ? "Testing…" : "Save and test") { model.testBrain() }
                    .disabled(model.isTestingBrain)
                Text(model.brainTestStatus)
                    .font(.system(size: 11))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Voice", selection: $model.voiceSource) {
                ForEach(VoiceSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.radioGroup)

            if model.voiceSource == .otherMac {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Address, e.g. http://adhyans-mac-studio-6.local:11240", text: $model.voiceServerURLField)
                        .textFieldStyle(.roundedBorder)
                    SecureField(model.hasSavedVoiceServerKey ? "Key saved in the Keychain (paste a new one to replace it)" : "Voice server key",
                                text: $model.voiceServerKeyField)
                        .textFieldStyle(.roundedBorder)
                    Text("Both Macs need to be on the same Wi-Fi, and the other Mac needs to be awake.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else if model.voiceSource == .thisMac, !model.isMLXCoreInstalled {
                Text("MLX Core isn't installed on this Mac, so Clicky will use the Mac voice.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            HStack {
                Button(model.isTestingVoice ? "Testing…" : "Save and test voice") { model.testVoice() }
                    .disabled(model.isTestingVoice)
                Text(model.voiceTestStatus)
                    .font(.system(size: 11))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
