//
//  SetupGuideWindow.swift
//  leanring-buddy
//
//  The first-run Setup guide: one step at a time, like an installer, with a step
//  list on the left and Back / Next at the bottom. Welcome → brain (the owner picks,
//  nothing is preselected) → voice → permissions → Theo's screen and look → T3 Code
//  (the T3 Code apps found, and which agents get the extension) → done. The full
//  Setup window stays available for every setting ("All settings…").
//

import AVFoundation
import Combine
import ClickyCore
import Speech
import SwiftUI

@MainActor
final class SetupGuideModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, brain, voice, permissions, look, t3Code, done
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .brain: return "Brain"
            case .voice: return "Voice"
            case .permissions: return "Permissions"
            case .look: return "Screen and look"
            case .t3Code: return "T3 Code"
            case .done: return "Done"
            }
        }
        var symbol: String {
            switch self {
            case .welcome: return "hand.wave"
            case .brain: return "brain"
            case .voice: return "waveform"
            case .permissions: return "lock.shield"
            case .look: return "sparkles"
            case .t3Code: return "puzzlepiece.extension"
            case .done: return "checkmark.seal"
            }
        }
    }

    @Published var step: Step = Step(rawValue: ClickySettings.setupGuideStep) ?? .welcome {
        didSet { ClickySettings.setupGuideStep = step.rawValue }
    }
    /// nil until the owner picks one: no brain is chosen for them.
    @Published var chosenBrain: BrainProvider? = ClickySettings.setupGuideBrainChosen ? BrainModel(setting: ClickyModels.main).provider : nil
    @Published private(set) var installedBrains: [BrainProvider: Bool] = [:]
    @Published var agentsPicked: Set<ClaudiaT3Integration.Agent> = []
    @Published private(set) var agentsOnThisMac: [ClaudiaT3Integration.Agent: Bool] = [:]
    @Published private(set) var t3Apps: [URL] = []
    @Published private(set) var extensionLines: [String] = []
    @Published private(set) var isInstallingExtension = false
    @Published var speaksAnswers = !ClickySettings.isSilentModeEnabled

    let setup: SetupModel
    let companionManager: CompanionManager

    init(companionManager: CompanionManager, setup: SetupModel) {
        self.companionManager = companionManager
        self.setup = setup
        refreshDetections()
    }

    func refreshDetections() {
        Task.detached {
            var brains: [BrainProvider: Bool] = [:]
            for provider in BrainProvider.allCases { brains[provider] = BrainCLIRunner.locateExecutable(for: provider) != nil }
            var agents: [ClaudiaT3Integration.Agent: Bool] = [:]
            for agent in ClaudiaT3Integration.Agent.allCases { agents[agent] = agent.isOnThisMac }
            let apps = ClaudiaT3Integration.t3Apps
            await MainActor.run {
                self.installedBrains = brains
                self.agentsOnThisMac = agents
                self.t3Apps = apps
            }
        }
    }

    func choose(_ provider: BrainProvider) {
        chosenBrain = provider
        ClickySettings.setupGuideBrainChosen = true
        setup.catalog.load()
        setup.brainProvider = provider
    }

    var canGoNext: Bool {
        switch step {
        case .brain: return chosenBrain != nil
        default: return true
        }
    }

    func next() {
        if step == .voice { ClickySettings.isSilentModeEnabled = !speaksAnswers; setup.saveVoiceChoice() }
        if step == .brain { setup.saveBrainChoice() }
        if let following = Step(rawValue: step.rawValue + 1) { step = following }
        if step == .t3Code || step == .brain { refreshDetections() }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    func installExtension() {
        let agents = agentsPicked
        isInstallingExtension = true
        extensionLines = []
        Task.detached {
            let outcome = ClaudiaT3Integration.install(agents: agents)
            await MainActor.run {
                self.extensionLines = outcome.lines + [outcome.succeeded ? "Restart T3 Code threads, then type $ to see Theo's skills." : "Some agents weren't updated."]
                self.isInstallingExtension = false
            }
        }
    }

    func finish() {
        ClickySettings.isSetupCompleted = true
        ClickySettings.setupGuideStep = 0
        SetupGuideWindowController.close()
        TheoHomeWindowController.show(companionManager: companionManager)
    }
}

@MainActor
enum SetupGuideWindowController {
    private static var window: NSWindow?
    private static var model: SetupGuideModel?

    /// At launch: never finished, or the chosen brain's command-line tool is missing.
    static var isNeededAtLaunch: Bool {
        !ClickySettings.isSetupCompleted || BrainCLIRunner.locateExecutable(for: BrainModel(setting: ClickyModels.main).provider) == nil
    }

    static func show(companionManager: CompanionManager, step: SetupGuideModel.Step? = nil) {
        if model == nil {
            model = SetupGuideModel(companionManager: companionManager, setup: SetupModel(companionManager: companionManager, showPanel: {}))
        }
        guard let model else { return }
        if let step { model.step = step }
        model.refreshDetections()
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            created.title = "Set up Theo"
            created.titlebarAppearsTransparent = true
            created.isReleasedWhenClosed = false
            created.contentView = FirstMouseHostingView(rootView: SetupGuideView(model: model, companionManager: companionManager))
            created.center()
            if let screen = ClaudiaScreen.picked {
                let frame = screen.visibleFrame
                created.setFrameOrigin(NSPoint(x: frame.midX - created.frame.width / 2, y: frame.midY - created.frame.height / 2))
            }
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    static func close() { window?.orderOut(nil) }
}

// MARK: - Views

private let accentGradient = LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 0.93, green: 0.27, blue: 0.45), Color(red: 0.75, green: 0.27, blue: 0.9)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)

struct SetupGuideView: View {
    @ObservedObject var model: SetupGuideModel
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    content
                        .padding(.horizontal, 36)
                        .padding(.top, 44)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
        }
        .frame(width: 860, height: 600)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accentGradient)
                    Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Theo").font(.system(size: 15, weight: .bold))
                    Text("Setup guide").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 22)
            ForEach(SetupGuideModel.Step.allCases, id: \.self) { step in
                let isCurrent = step == model.step
                let isDone = step.rawValue < model.step.rawValue
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(isCurrent ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.secondary.opacity(isDone ? 0.25 : 0.12)))
                        if isDone {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.primary)
                        } else {
                            Text("\(step.rawValue + 1)").font(.system(size: 11, weight: .bold)).foregroundColor(isCurrent ? .white : .secondary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(step.title).font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? .primary : .secondary)
                }
                .padding(.vertical, 6)
            }
            Spacer()
            Button("All settings…") { SetupWindowController.show(companionManager: companionManager) {} }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 20)
        .padding(.top, 44)
        .padding(.bottom, 20)
        .frame(width: 220, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.06))
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { model.back() }.keyboardShortcut(.cancelAction)
            }
            Spacer()
            if model.step == .t3Code {
                Button("Skip") { model.next() }
            }
            if model.step == .done {
                Button("Finish") { model.finish() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            } else {
                Button(model.step == .welcome ? "Get started" : "Continue") { model.next() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!model.canGoNext)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .brain: BrainStep(model: model, setup: model.setup)
        case .voice: VoiceStep(model: model, setup: model.setup)
        case .permissions: PermissionsStep(companionManager: companionManager)
        case .look: LookStep()
        case .t3Code: T3CodeStep(model: model)
        case .done: DoneStep(setup: model.setup)
        }
    }
}

private struct StepHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(accentGradient)
                Image(systemName: "sparkles").font(.system(size: 40, weight: .semibold)).foregroundColor(.white)
            }
            .frame(width: 84, height: 84)
            .shadow(color: Color(red: 0.93, green: 0.27, blue: 0.45).opacity(0.35), radius: 18, y: 8)
            Text("Hi, I'm Theo").font(.system(size: 30, weight: .bold))
            Text("The cursor assistant for T3 Code. Let's get me set up. It takes about two minutes.")
                .font(.system(size: 15)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                feature("mic", "Say “hey Theo” and ask about anything on your screen")
                feature("hand.point.up.left", "I mark the steps, or click them for you")
                feature("rectangle.on.rectangle", "Whiteboards, flowcharts and research with helper agents")
                feature("chevron.left.forwardslash.chevron.right", "Your notes and screenshots go straight to your T3 Code agents")
            }
            .padding(.top, 6)
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundColor(Color(red: 0.93, green: 0.4, blue: 0.4))
            Text(text).font(.system(size: 14))
        }
    }
}

private struct BrainStep: View {
    @ObservedObject var model: SetupGuideModel
    @ObservedObject var setup: SetupModel

    private let blurbs: [BrainProvider: String] = [
        .claude: "Your Claude subscription or an API key",
        .codex: "Your ChatGPT subscription, through Codex",
        .cursor: "Your Cursor subscription, through Cursor Agent",
        .opencode: "Any model OpenCode can reach, local ones too",
    ]
    private let symbols: [BrainProvider: String] = [.claude: "asterisk", .codex: "hexagon", .cursor: "cursorarrow.rays", .opencode: "chevron.left.forwardslash.chevron.right"]
    private let installPages: [BrainProvider: String] = [
        .claude: "https://docs.anthropic.com/en/docs/claude-code/setup", .codex: "https://github.com/openai/codex",
        .cursor: "https://cursor.com/cli", .opencode: "https://opencode.ai",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Which AI should power Theo?",
                       subtitle: "Pick the one you're signed in to. You can switch any time in All settings.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(BrainProvider.allCases, id: \.self) { provider in
                    brainCard(provider)
                }
            }
            if let chosen = model.chosenBrain {
                VStack(alignment: .leading, spacing: 10) {
                    if chosen == .claude {
                        Picker("Sign in with", selection: $setup.authMode) {
                            Text("My Claude subscription").tag(ClickySettings.BrainAuthMode.subscription)
                            Text("An Anthropic API key").tag(ClickySettings.BrainAuthMode.apiKey)
                        }
                        .pickerStyle(.radioGroup)
                        if setup.authMode == .apiKey {
                            SecureField(setup.hasSavedAPIKey ? "Saved in the Keychain" : "Paste your API key", text: $setup.apiKeyField)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    HStack(spacing: 8) {
                        if model.installedBrains[chosen] == true {
                            Button("Sign in…") { SetupModel.runInTerminal(chosen.signInCommand) }
                            Button(setup.isTestingBrain ? "Testing…" : "Test it") { setup.testBrain() }.disabled(setup.isTestingBrain)
                        } else {
                            Button("Get \(chosen.displayName)…") { if let url = URL(string: installPages[chosen] ?? "") { NSWorkspace.shared.open(url) } }
                            Button("Check again") { model.refreshDetections() }
                        }
                    }
                    if !setup.brainTestStatus.isEmpty {
                        Text(setup.brainTestStatus).font(.system(size: 12))
                            .foregroundColor(setup.brainTestStatus.hasPrefix("✓") ? .green : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
            }
        }
    }

    private func brainCard(_ provider: BrainProvider) -> some View {
        let isChosen = model.chosenBrain == provider
        let installed = model.installedBrains[provider]
        return Button(action: { model.choose(provider) }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbols[provider] ?? "circle").font(.system(size: 18)).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName).font(.system(size: 14, weight: .semibold))
                    Text(blurbs[provider] ?? "").font(.system(size: 11.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Circle().fill(installed == true ? Color.green : (installed == false ? Color.orange : Color.secondary)).frame(width: 6, height: 6)
                        Text(installed == true ? "On this Mac" : (installed == false ? "Not installed" : "Checking…")).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle").foregroundColor(isChosen ? .accentColor : .secondary.opacity(0.5))
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(isChosen ? 0.12 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isChosen ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct VoiceStep: View {
    @ObservedObject var model: SetupGuideModel
    @ObservedObject var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "How should Theo sound?", subtitle: "Theo always listens for “hey Theo”. Answers can be spoken or shown as captions.")
            Toggle("Speak answers out loud", isOn: $model.speaksAnswers).toggleStyle(.switch)
            Text("Off means silent: captions, marks and boards only.").font(.system(size: 11.5)).foregroundColor(.secondary)
            Divider().padding(.vertical, 6)
            Text("Voice").font(.system(size: 13, weight: .semibold))
            ForEach(VoiceSource.allCases) { source in
                Button(action: { setup.voiceSource = source }) {
                    HStack(spacing: 10) {
                        Image(systemName: setup.voiceSource == source ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(setup.voiceSource == source ? .accentColor : .secondary)
                        Text(source.title).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(setup.voiceSource == source ? 0.1 : 0.04)))
                }
                .buttonStyle(.plain)
            }
            if setup.voiceSource == .otherMac {
                TextField("Voice server address (http://your-mac.local:11240)", text: $setup.voiceServerURLField).textFieldStyle(.roundedBorder)
                SecureField(setup.hasSavedVoiceServerKey ? "Key saved in the Keychain" : "Voice server key", text: $setup.voiceServerKeyField).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button(setup.isTestingVoice ? "Testing…" : "Test the voice") { setup.testVoice() }.disabled(setup.isTestingVoice)
                Text(setup.voiceTestStatus).font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(title: "Let Theo hear and see", subtitle: "Each one opens a macOS prompt or the right page of System Settings. Theo checks every second.")
            row("Microphone", "So Theo hears “hey Theo”", microphoneStatus == .authorized) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            row("Speech recognition", "Turns what you say into words, on this Mac", speechStatus == .authorized) {
                SFSpeechRecognizer.requestAuthorization { _ in }
            }
            row("Accessibility", "So Theo can point at and click the right things", companionManager.hasAccessibilityPermission) {
                _ = TheoPermissions.askForAccessibility()
            }
            row("Screen recording", "So Theo can see your screens", companionManager.hasScreenRecordingPermission) {
                _ = TheoPermissions.askForScreenRecording()
            }
        }
        .onReceive(ticker) { _ in
            speechStatus = SFSpeechRecognizer.authorizationStatus()
            microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private func row(_ title: String, _ detail: String, _ granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle").font(.system(size: 18))
                .foregroundColor(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed").font(.system(size: 12)).foregroundColor(.green)
            } else {
                Button("Allow…", action: request)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }
}

private struct LookStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Where Theo works, and how it looks", subtitle: "Give Theo a screen of its own if you have more than one. Then pick a spark.")
            ClaudiaScreenSection()
        }
    }
}

private struct T3CodeStep: View {
    @ObservedObject var model: SetupGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Connect Theo to T3 Code",
                       subtitle: "The extension gives every T3 Code thread Theo's skills: $theo-notes, $ask-theo, $theo-screen and $theo-whiteboard. Pick the agents you use.")
            VStack(alignment: .leading, spacing: 6) {
                Text("T3 Code on this Mac").font(.system(size: 13, weight: .semibold))
                if model.t3Apps.isEmpty {
                    Text("No T3 Code app found in Applications. You can still add Theo to the agents; T3 Code picks it up when you install it.")
                        .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !model.t3Apps.contains(where: { $0.lastPathComponent == "T3 Code Cursor Assistant.app" }) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack").foregroundStyle(accentGradient)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("T3 Code Cursor Assistant: T3 Code with Theo built in").font(.system(size: 12.5, weight: .medium))
                            Text("A Theo page and a notes button in every thread. Runs beside T3 Code Nightly.").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Download") { NSWorkspace.shared.open(TheoHomeWindowController.t3BuiltInDownloadURL) }
                    }
                }
                ForEach(model.t3Apps, id: \.self) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 22, height: 22)
                        Text(app.deletingPathExtension().lastPathComponent).font(.system(size: 13))
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 12))
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(app) }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))

            Text("Add Theo to").font(.system(size: 13, weight: .semibold)).padding(.top, 4)
            ForEach(ClaudiaT3Integration.Agent.allCases) { agent in
                let onMac = model.agentsOnThisMac[agent] == true
                Toggle(isOn: Binding(get: { model.agentsPicked.contains(agent) },
                                     set: { if $0 { model.agentsPicked.insert(agent) } else { model.agentsPicked.remove(agent) } })) {
                    HStack {
                        Text(agent.title).font(.system(size: 13))
                        Text(onMac ? "on this Mac" : "not installed").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!onMac)
            }
            HStack {
                Button(action: { model.installExtension() }) {
                    Label(model.isInstallingExtension ? "Adding…" : "Add Theo to T3 Code", systemImage: "puzzlepiece.extension.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.agentsPicked.isEmpty || model.isInstallingExtension)
                if model.agentsPicked.isEmpty { Text("Tick at least one agent.").font(.system(size: 11.5)).foregroundColor(.secondary) }
            }
            ForEach(model.extensionLines, id: \.self) { line in
                Text(line).font(.system(size: 12)).foregroundColor(line.hasPrefix("✗") ? .red : .secondary)
            }
        }
    }
}

private struct DoneStep: View {
    @ObservedObject var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 46)).foregroundStyle(accentGradient)
            Text("You're all set").font(.system(size: 28, weight: .bold))
            Text("Try one of these:").font(.system(size: 14)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                tip("“Hey Theo, what's on my screen?”")
                tip("“Hey Theo, draw me a flowchart of my signup flow.”")
                tip("“Hey Theo, research these links.”")
                tip("In T3 Code: the notes button next to the paperclip.")
            }
            Button("Test the spark") { setup.testSpark() }.padding(.top, 6)
            Text("Theo lives in the menu bar. Open it again from Applications to come back here.")
                .font(.system(size: 11.5)).foregroundColor(.secondary)
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill").foregroundColor(Color(red: 0.93, green: 0.4, blue: 0.4))
            Text(text).font(.system(size: 14))
        }
    }
}
