//
//  SetupGuideWindow.swift
//  leanring-buddy
//
//  The first-run Setup guide: one step at a time, like an installer, with a step list on the left and Back / Continue
//  at the bottom. Welcome → Permissions → Harnesses (install, sign in, connect T3 Code) → API keys (optional) → Voice →
//  Done. Everything here is also in Settings.
//

import AVFoundation
import Combine
import ClickyCore
import Speech
import SwiftUI

@MainActor
final class SetupGuideModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, permissions, harnesses, keys, voice, done
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Permissions"
            case .harnesses: return "Harnesses"
            case .keys: return "API keys"
            case .voice: return "Voice"
            case .done: return "Done"
            }
        }
    }

    @Published var step: Step = Step(rawValue: ClickySettings.setupGuideStep) ?? .welcome {
        didSet { ClickySettings.setupGuideStep = step.rawValue }
    }
    let setup: SetupModel
    let companionManager: CompanionManager

    init(companionManager: CompanionManager, setup: SetupModel) {
        self.companionManager = companionManager
        self.setup = setup
    }

    func next() {
        if let following = Step(rawValue: step.rawValue + 1) { step = following }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
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
        let provider = BrainModel(setting: ClickyModels.main).provider
        // An API model has no command-line tool to look for.
        return !ClickySettings.isSetupCompleted || (provider != .api && BrainCLIRunner.locateExecutable(for: provider) == nil)
    }

    /// `activates` false opens it without taking focus (a launch in the background).
    static func show(companionManager: CompanionManager, step: SetupGuideModel.Step? = nil, activates: Bool = true) {
        if model == nil {
            model = SetupGuideModel(companionManager: companionManager, setup: SetupModel(companionManager: companionManager, showPanel: {}))
        }
        guard let model else { return }
        if let step { model.step = step }
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
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
        if activates {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        window?.orderFrontRegardless()
    }

    static func close() { window?.orderOut(nil) }
}

// MARK: - Views

struct SetupGuideView: View {
    @ObservedObject var model: SetupGuideModel
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    content
                        .id(model.step)
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 24)
                        .frame(maxWidth: .infinity)
                }
                Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
                footer
            }
            .background(DS.Colors.background)
        }
        .frame(width: 980, height: 680)
        .modifier(TheoAppearanceRoot())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ClickyAvatar(size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Theo").font(TheoType.headline).foregroundColor(DS.Colors.textPrimary)
                    Text("Setup").font(TheoType.micro).foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(.bottom, 22)
            ForEach(SetupGuideModel.Step.allCases, id: \.self) { step in
                let isCurrent = step == model.step
                let isDone = step.rawValue < model.step.rawValue
                Button { model.step = step } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(isCurrent ? DS.Colors.accent : DS.Colors.hover)
                            if isDone {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
                            } else {
                                Text("\(step.rawValue + 1)").font(.system(size: 11, weight: .bold)).foregroundColor(isCurrent ? .white : DS.Colors.textTertiary)
                            }
                        }
                        .frame(width: 22, height: 22)
                        Text(step.title).font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(isCurrent ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 6).frame(height: 34).contentShape(Rectangle())
                }
                .buttonStyle(SidebarButtonStyle(isSelected: isCurrent))
            }
            Spacer()
            Button("All settings") {
                SetupGuideWindowController.close()
                TheoSettingsWindowController.show()
            }
            .buttonStyle(.theo(.ghost, .small))
        }
        .padding(.horizontal, 14).padding(.top, 44).padding(.bottom, 16)
        .frame(width: 220, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.sidebar)
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { model.back() }.buttonStyle(.theoGhost).keyboardShortcut(.cancelAction)
            }
            Spacer()
            if model.step == .keys || model.step == .harnesses {
                Button("Skip") { model.next() }.buttonStyle(.theoGhost)
            }
            if model.step == .done {
                Button("Open Theo") { model.finish() }.buttonStyle(.theoPrimary).keyboardShortcut(.defaultAction)
            } else {
                Button(model.step == .welcome ? "Get started" : "Continue") { model.next() }.buttonStyle(.theoPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24).frame(height: 56)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .permissions:
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: "Let Theo hear and see", subtitle: "Allow what you want. Theo still runs without any of these and tells you what it can't do yet, so you can come back to this any time in Settings.")
                PermissionsSettingsContent()
            }
        case .harnesses:
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: "Your coding agents", subtitle: "Install and sign in right here. T3 Code is the default for builds; any other harness runs in a live terminal inside Theo.")
                CodingSettingsView()
                TheoSection(title: "Clicky thinks with", hint: "Clicky is your screen companion. Claude Sonnet 5.5 is a good start, and any agent or API key works.") {
                    SetupBrainRow(companionManager: companionManager)
                }
            }
        case .keys:
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: "API keys (optional)", subtitle: "Bring a key for any provider and use it for bots, Theo, Clicky and voices. You can skip this and add them later.")
                ProviderKeysView()
            }
        case .voice:
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: "How should Theo sound?", subtitle: "Theo always listens for \u{201C}hey Theo\u{201D}. Answers can be spoken or shown as captions.")
                VoiceSettingsContent()
            }
        case .done: DoneStep(setup: model.setup)
        }
    }
}

private struct SetupBrainRow: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var main = ClickyModels.main

    var body: some View {
        SettingRow(title: "Answers") {
            BrainModelPicker(title: "Answers", setting: Binding(get: { main }, set: { main = $0; companionManager.setSelectedModel($0) })).frame(width: 280)
        }
    }
}

private struct StepHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(TheoType.title).foregroundColor(DS.Colors.textPrimary)
            Text(subtitle).font(TheoType.body).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ClickyAvatar(size: 72)
            Text("Hi, I'm Theo").font(.system(size: 30, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
            Text("Your Mac's team: Clicky on your screen, bots you make yourself, and any coding agent you already use. Setup takes about two minutes.")
                .font(.system(size: 15)).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                feature("cursorarrow.rays", TileColors.ember, "Clicky sees your screen, points at things, draws boards and researches links")
                feature("person.2.fill", TileColors.indigo, "Bots you make from stencils, with teams, schedules and their own settings")
                feature("terminal.fill", TileColors.graphite, "Hand any fix to T3 Code, Claude Code, Codex, Cursor, OpenCode, Grok or Gemini")
                feature("arrow.triangle.pull", TileColors.lime, "Runs come back with a branch, a draft PR and a report")
            }
            .padding(.top, 6)
        }
    }

    private func feature(_ symbol: String, _ colors: [Color], _ text: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, colors: colors, size: 26)
            Text(text).font(.system(size: 14)).foregroundColor(DS.Colors.textPrimary)
        }
    }
}

private struct DoneStep: View {
    @ObservedObject var setup: SetupModel
    @ObservedObject private var look = LookSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            IconTile(symbol: "checkmark", colors: TileColors.lime, size: 56)
            Text("You're all set").font(.system(size: 28, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
            TheoSection(title: "Try one of these", hint: nil) {
                tip("\u{201C}Hey Theo, what's on my screen?\u{201D}")
                RowDivider()
                tip("\u{201C}Hey Theo, draw me a flowchart of my signup flow.\u{201D}")
                RowDivider()
                tip("Make a bot, then tell it \u{201C}fix the failing test in ~/Projects/foo\u{201D}.")
            }
            TheoSection(title: "Theo's screen", hint: "Theo opens its windows here and leaves your main screen alone.") {
                SettingRow(title: "Monitor") {
                    Picker("Monitor", selection: $look.screenName) {
                        Text("Follow my pointer").tag("")
                        ForEach(look.screenNames, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 260)
                }
            }
            Button("Test the spark") { setup.testSpark() }.buttonStyle(.theoSecondary).disabled(TheoProfile.isTest)
        }
    }

    private func tip(_ text: String) -> some View {
        Text(text).font(TheoType.body).foregroundColor(DS.Colors.textPrimary).padding(.horizontal, 14).padding(.vertical, 10)
    }
}
