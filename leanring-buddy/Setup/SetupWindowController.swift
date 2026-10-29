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
    /// The brain switch: which agent the answers run on (the model list below follows it).
    @Published var brainProvider = BrainModel(setting: ClickyModels.main).provider {
        didSet {
            guard brainProvider != BrainModel(setting: mainModel).provider else { return }
            if let firstModel = catalog.defaultModel(for: brainProvider) { mainModel = firstModel }
            // Helpers follow the brain unless they already use it.
            if BrainModel(setting: helperModel).provider != brainProvider {
                helperModel = brainProvider == .claude ? ClickyModels.haiku : mainModel
            }
        }
    }
    let catalog = BrainCatalog.shared
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
    /// Demo recordings / "show me the voice settings": the section to scroll to.
    @Published var scrollTarget: Int?
    var updateController: UpdateController { companionManager.updateController }
    @Published var updateTokenField = ""
    @Published private(set) var hasSavedUpdateToken = ClickySecrets.read(.updateToken) != nil

    func saveUpdateToken() {
        ClickySecrets.write(.updateToken, value: updateTokenField)
        updateTokenField = ""
        hasSavedUpdateToken = ClickySecrets.read(.updateToken) != nil
        Task { await updateController.check() }
    }

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
        Self.runInTerminal("curl -fsSL https://claude.ai/install.sh | bash && echo && echo 'Done. Go back to Claudia and press Check again.'")
    }

    /// Opens Terminal running `claude auth login`.
    func signInToClaudeCode() {
        let claudeCommand = claudeCodePath.map { "'\($0)'" } ?? "~/.local/bin/claude"
        Self.runInTerminal("\(claudeCommand) auth login && echo && echo 'Signed in. Go back to Claudia and press Test.'")
    }

    /// One real call through Claude Code with the chosen sign-in.
    func testBrain() {
        saveBrainChoice()
        let brainModel = BrainModel(setting: ClickyModels.main)
        if !brainModel.isClaude {
            isTestingBrain = true
            brainTestStatus = "Asking \(brainModel.provider.displayName)…"
            Task {
                let (succeeded, output) = await Self.runOtherBrainTestCall(brainModel)
                isTestingBrain = false
                brainTestStatus = succeeded ? "✓ \(output)" : "✗ \(output)"
                companionManager.refreshClaudeCodeSignInStatus()
            }
            return
        }
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

    /// One real turn on a Codex / Cursor / OpenCode model.
    static func runOtherBrainTestCall(_ brainModel: BrainModel) async -> (Bool, String) {
        do {
            let turn = try await BrainCLIRunner.runTurn(model: brainModel, systemPrompt: "Reply with exactly one word.",
                                                        contentBlocks: [.text("Reply with exactly one word: ready")], onTextChunk: { _ in })
            return (true, "\(brainModel.provider.displayName) answered: \(turn.text.prefix(60)) (\(brainModel.modelIdentifier))")
        } catch {
            return (false, error.localizedDescription)
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
                     : "✗ Accessibility: grant it, or marks are guesses from the screenshot and Claudia can't click or type")
        lines.append(companionManager.hasScreenRecordingPermission ? "✓ Screen Recording" : "✗ Screen Recording: grant it, then quit and reopen Claudia")
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
                let brainModel = BrainModel(setting: ClickyModels.main)
                let (succeeded, output) = brainModel.isClaude
                    ? await Self.runClaudeTestCall(executablePath: claudeCodeExecutablePath)
                    : await Self.runOtherBrainTestCall(brainModel)
                claudeLines.append(succeeded ? "✓ Brain answers: \(output)" : "✗ Brain: \(output)")
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

    /// Shows the spark spinning with three helpers orbiting for 6 seconds,
    /// so you can see the animation works on this Mac without asking anything.
    func testSpark() {
        let simulatedSource = companionManager.simulatedCompanionActivitySource
        companionManager.showOverlayForSparkTest()
        simulatedSource.setSimulatedCoordinatorThinking(true)
        simulatedSource.setSimulatedWorkingWorkerCount(3)
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            simulatedSource.setSimulatedWorkingWorkerCount(0)
            simulatedSource.setSimulatedCoordinatorThinking(false)
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
            // As tall as the screen allows (up to 960 pt), so most sections show at once.
            let windowHeight = min(960, max(600, ((ClaudiaScreen.picked ?? NSScreen.main)?.visibleFrame.height ?? 800) - 60))
            let createdWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: windowHeight),
                                         styleMask: [.titled, .closable, .resizable],
                                         backing: .buffered, defer: false)
            createdWindow.title = "Claudia Setup"
            createdWindow.isReleasedWhenClosed = false
            createdWindow.contentView = NSHostingView(rootView: SetupView(model: model))
            createdWindow.center()
            // On Claudia's own screen when one is picked.
            if let screen = ClaudiaScreen.picked {
                let frame = screen.visibleFrame
                createdWindow.setFrameOrigin(NSPoint(x: frame.midX - createdWindow.frame.width / 2, y: frame.midY - createdWindow.frame.height / 2))
            }
            window = createdWindow
        }
        // An accessory app can't always take focus at launch (macOS stops
        // activation stealing), so the window floats and is ordered front regardless.
        window?.level = .floating
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Scrolls Setup to a numbered section (1 Claude … 8 Updates).
    static func hide() { window?.orderOut(nil) }

    static func scroll(toSection section: Int) {
        model?.scrollTarget = nil
        model?.scrollTarget = section
    }

    static func close() {
        window?.orderOut(nil)
    }
}

private struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Set up Claudia")
                    .font(.system(size: 20, weight: .semibold))
                Text("Claudia lives in the menu bar (the spark icon). If you can't see it, open Claudia again from Applications to bring this window back.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Color.clear.frame(height: 0).id(1)

                GroupBox(label: Text("1. Claude").font(.headline)) {
                    brainSection.padding(8)
                }
                Color.clear.frame(height: 0).id(2)
                GroupBox(label: Text("2. Voice").font(.headline)) {
                    voiceSection.padding(8)
                }
                Color.clear.frame(height: 0).id(3)
                GroupBox(label: Text("3. Models").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        BrainSwitchSection(model: model, catalog: model.catalog)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                Color.clear.frame(height: 0).id(4)
                GroupBox(label: Text("4. Permissions").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Claudia needs Microphone, Speech Recognition, Accessibility and Screen Recording. The menu-bar panel has a button for each.")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open the permissions panel") { model.showPanel() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                Color.clear.frame(height: 0).id(5)

                GroupBox(label: Text("5. Check everything").font(.headline)) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button(model.isChecking ? "Checking…" : "Check everything") { model.checkEverything() }
                                .disabled(model.isChecking)
                            Button("Test the spark") { model.testSpark() }
                        }
                        Text("Test the spark: the spark by your pointer should spin with three small sparks orbiting it for 6 seconds.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
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

                Color.clear.frame(height: 0).id(6)

                GroupBox(label: Text("6. Claudia's screen and spark").font(.headline)) {
                    ClaudiaScreenSection()
                        .padding(8)
                }

                Color.clear.frame(height: 0).id(7)

                GroupBox(label: Text("7. Claudia in T3 Code").font(.headline)) {
                    T3IntegrationSection()
                        .padding(8)
                }

                Color.clear.frame(height: 0).id(8)

                GroupBox(label: Text("8. Updates").font(.headline)) {
                    UpdateSection(updateController: model.updateController, tokenField: $model.updateTokenField,
                                  hasSavedToken: model.hasSavedUpdateToken, saveToken: { model.saveUpdateToken() })
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
        .onChange(of: model.scrollTarget) { _, target in
            guard let target else { return }
            withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo(target, anchor: .top) }
        }
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    func modelPicker(_ title: String, selection: Binding<String>) -> some View {
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
            Text("Claudia thinks with the brain you pick below: Claude Code, ChatGPT (Codex), Cursor or OpenCode.")
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
                Text("MLX Core isn't installed on this Mac, so Claudia will use the Mac voice.")
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


/// Version, Check for updates / Update now, and the optional token for a private updates repo.
private struct UpdateSection: View {
    @ObservedObject var updateController: UpdateController
    @Binding var tokenField: String
    let hasSavedToken: Bool
    let saveToken: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This is Claudia \(updateController.currentVersionLabel)")
                    .font(.system(size: 12))
                Spacer()
                if let release = updateController.availableRelease {
                    Button("Update now to build \(release.build)") { updateController.installAvailableUpdate() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Check for updates") { Task { await updateController.check() } }
                        .disabled(updateController.state == .checking)
                }
            }
            Text(statusLine)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let release = updateController.availableRelease, !release.notes.isEmpty {
                Text(release.notes)
                    .font(.system(size: 11))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                SecureField(hasSavedToken ? "Updates token saved (only for a private updates repo)" : "Updates token (only for a private updates repo)",
                            text: $tokenField)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveToken() }
                    .disabled(tokenField.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: String {
        switch updateController.state {
        case .idle: return "Claudia checks for updates when it starts and every 6 hours. Updating keeps your settings and permissions."
        case .checking: return "Checking…"
        case .upToDate: return "✓ You have the newest build."
        case .available: return "A newer build is ready. Claudia quits, updates itself and reopens."
        case .installing(let message): return message
        case .failed(let message): return "✗ \(message)"
        }
    }
}


/// The brain switch (Claude / ChatGPT / Cursor / OpenCode, the agents T3 Code drives) and its models.
private struct BrainSwitchSection: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var catalog: BrainCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Brain", selection: $model.brainProvider) {
                ForEach(BrainProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            if let note = catalog.notes[model.brainProvider] {
                Text(note).font(.system(size: 11)).foregroundColor(.orange)
            }
            modelMenu("Answers", selection: $model.mainModel, providers: [model.brainProvider])
            modelMenu("Helpers, research, mark checks", selection: $model.helperModel, providers: BrainProvider.allCases)
            modelMenu("Code tasks (Claude Code)", selection: $model.codeModel, providers: [.claude])
            if BrainModel(setting: model.mainModel).sendsScreenshotsToThirdParty || BrainModel(setting: model.helperModel).sendsScreenshotsToThirdParty {
                Text("This OpenCode model runs in someone else's cloud: your screenshots go to that provider. Local models (lmstudio/…) stay on your Mac.")
                    .font(.system(size: 11)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(catalog.isLoading ? "Loading models…" : "Models come from your subscriptions: Claude Code, Codex (ChatGPT), Cursor Agent and OpenCode, the same agents T3 Code uses.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Refresh") { catalog.load(force: true) }
            }
        }
        .onAppear { catalog.load() }
    }

    private func modelMenu(_ title: String, selection: Binding<String>, providers: [BrainProvider]) -> some View {
        Picker(title, selection: selection) {
            ForEach(providers, id: \.self) { provider in
                let identifiers = catalog.models[provider] ?? []
                if !identifiers.isEmpty {
                    Section(provider.displayName) {
                        ForEach(identifiers, id: \.self) { identifier in
                            let setting = BrainModel(provider: provider, modelIdentifier: identifier).setting
                            Text(catalog.label(for: setting)).tag(setting)
                        }
                    }
                }
            }
            let known = providers.flatMap { provider in (catalog.models[provider] ?? []).map { BrainModel(provider: provider, modelIdentifier: $0).setting } }
            if !known.contains(selection.wrappedValue) {
                Text(catalog.label(for: selection.wrappedValue)).tag(selection.wrappedValue)
            }
        }
    }
}


/// Which display Claudia uses for itself, and whether the spark follows the pointer.
private struct ClaudiaScreenSection: View {
    @State private var screenName = ClickySettings.claudiaScreenName
    @State private var sparkMode = ClickySettings.sparkMode
    @State private var sparkStyle = ClickySettings.sparkStyle
    @State private var theme = ClickySettings.uiTheme
    private let screenNames = NSScreen.screens.map(\.localizedName)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Claudia's screen", selection: $screenName) {
                Text("None: wherever my pointer is").tag("")
                ForEach(screenNames, id: \.self) { name in
                    Text(name).tag(name)
                }
                if !screenName.isEmpty && !screenNames.contains(screenName) {
                    Text("\(screenName) (not connected)").tag(screenName)
                }
            }
            .onChange(of: screenName) { _, newValue in ClickySettings.claudiaScreenName = newValue }
            Text("With a screen picked, Claudia opens its browser windows, apps, boards and notes there and leaves your main screen alone.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Spark", selection: $sparkMode) {
                Text("Follows my pointer").tag(ClickySettings.SparkMode.cursor)
                Text("Lives on its own (corner of Claudia's screen)").tag(ClickySettings.SparkMode.docked)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: sparkMode) { _, newValue in ClickySettings.sparkMode = newValue }
            Picker("Notes and T3 theme", selection: $theme) {
                ForEach(ClaudiaTheme.allCases, id: \.self) { theme in Text(theme.displayName).tag(theme) }
            }
            .onChange(of: theme) { _, newValue in ClickySettings.uiTheme = newValue }
            Text("Spark style").font(.system(size: 12, weight: .medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(CompanionIconStyle.allCases, id: \.self) { style in
                    Button(action: { sparkStyle = style; ClickySettings.sparkStyle = style }) {
                        VStack(spacing: 6) {
                            CompanionIconPreview(style: style)
                                .frame(width: 30, height: 30)
                                .padding(6)
                            Text(style.displayName).font(.system(size: 10)).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 66)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.75)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(sparkStyle == style ? Color.accentColor : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// "Add Claudia to T3 Code": every agent T3 Code runs gets Claudia's tools.
private struct T3IntegrationSection: View {
    @State private var resultLines: [String] = []
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gives every T3 Code thread (Claude, ChatGPT, Cursor, OpenCode) Claudia's tools: see your screen, point and mark, whiteboards, research with Haiku agents, search, click and type, and her voice.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(isWorking ? "Adding…" : "Add Claudia to T3 Code") {
                    isWorking = true
                    Task.detached {
                        let outcome = ClaudiaT3Integration.install()
                        await MainActor.run {
                            resultLines = outcome.lines + [outcome.succeeded ? "Restart T3 Code threads to pick it up." : "Some agents weren't updated."]
                            isWorking = false
                        }
                    }
                }
                .disabled(isWorking)
                Spacer()
            }
            ForEach(resultLines, id: \.self) { line in
                Text(line).font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
