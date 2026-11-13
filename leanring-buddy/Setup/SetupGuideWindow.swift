//
//  SetupGuideWindow.swift
//  leanring-buddy
//
//  The first-run Setup guide: one step at a time, like an installer, with a step list on the left and Back / Continue
//  at the bottom. Welcome → Pick products (Theo, Clicky, Dictation, each with a demo) → Permissions → Harnesses →
//  API keys → Voice → Done. Harnesses and Voice only show for Theo or Clicky (ClickyCore `SetupStep.shown`). Everything
//  here is also in Settings.
//

import AVFoundation
import Combine
import ClickyCore
import Speech
import SwiftUI

@MainActor
final class SetupGuideModel: ObservableObject {
    typealias Step = SetupStep

    @Published var step: Step = Step(rawValue: ClickySettings.setupGuideStep) ?? .welcome {
        didSet { ClickySettings.setupGuideStep = step.rawValue }
    }
    let setup: SetupModel
    let companionManager: CompanionManager

    init(companionManager: CompanionManager, setup: SetupModel) {
        self.companionManager = companionManager
        self.setup = setup
    }

    var picked: Set<TheoProduct> { TheoProducts.shared.picked }

    /// Continue on the products step needs something picked.
    var canContinue: Bool { step != .products || TheoProductChoice.canFinish(picked) }

    func next() {
        if let following = Step.next(after: step, products: picked) { step = following }
    }

    func back() {
        if let previous = Step.previous(before: step, products: picked) { step = previous }
    }

    func finish() {
        // Nothing picked: back to the products, since a Theo with nothing on would do nothing.
        guard TheoProductChoice.canFinish(picked) else {
            step = .products
            return
        }
        TheoProducts.shared.saveChoices()
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
        // Dictation alone needs no brain, so a missing one only matters with Theo or Clicky on.
        let needsBrain = TheoProducts.isOn(.clicky) || TheoProducts.isOn(.theo)
        return !ClickySettings.isSetupCompleted || (needsBrain && provider != .api && BrainCLIRunner.locateExecutable(for: provider) == nil)
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

/// Theo's own face, for the guide's brand mark. `state` is the setup's own status: ready normally, needs while the step
/// still wants something, talking while a voice sample plays, done on the last step.
private struct TheoMark: View {
    let size: CGFloat
    var state: PixelState = .awake

    var body: some View {
        CrewAvatar(look: BotsStore.shared.primary?.crewLook ?? .theo, size: size, pose: state, name: "Theo")
    }
}

struct SetupGuideView: View {
    @ObservedObject var model: SetupGuideModel
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var products = TheoProducts.shared
    @ObservedObject private var voicePreview = VoicePreviewPlayer.shared

    /// The face in the sidebar follows the step.
    private var setupState: PixelState {
        if model.step == .done { return .done }
        if voicePreview.playing != nil { return .talking }
        if model.step == .products && !model.canContinue { return .needs }
        return .awake
    }

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
                TheoMark(size: 32, state: setupState)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Theo").font(TheoType.headline).foregroundColor(DS.Colors.textPrimary)
                    Text("Setup").font(TheoType.micro).foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(.bottom, 22)
            let steps = SetupStep.shown(for: products.picked)
            ForEach(Array(steps.enumerated()), id: \.element) { number, step in
                let isCurrent = step == model.step
                let isDone = step.rawValue < model.step.rawValue
                Button { model.step = step } label: {
                    HStack(spacing: 10) {
                        if isDone {
                            // A finished step wears the white tick.
                            PixelBadge(tone: .done, size: 20, animated: false).frame(width: 22, height: 22)
                        } else {
                            ZStack {
                                Circle().fill(isCurrent ? DS.Colors.accent : DS.Colors.hover)
                                Text("\(number + 1)").font(.system(size: 11, weight: .bold)).foregroundColor(isCurrent ? DS.Colors.textOnAccent : DS.Colors.textTertiary)
                            }
                            .frame(width: 22, height: 22)
                        }
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

    /// What the step still wants, or how it's going, on the left of the footer.
    @ViewBuilder private var footerHint: some View {
        switch model.step {
        case .products:
            if !model.canContinue {
                StatusPill(text: "Pick at least one", tone: .warn)
            }
        case .keys:
            Text("You can skip this").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            footerHint
            Spacer().frame(width: 12)
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
                    .disabled(!model.canContinue)
            }
        }
        .padding(.horizontal, 24).frame(height: 56)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .products:
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: "Pick what you want", subtitle: "Theo, Clicky and Dictation are separate products. Watch each demo and turn on only the ones you want; you can change this any time in Settings \u{203A} Products.")
                TheoProductsList(demoWidth: 250)
            }
        case .permissions:
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: "Let Theo hear and see", subtitle: "Allow what you want. Theo still runs without any of these and tells you what it can't do yet, so you can come back to this any time in Settings.")
                PermissionsSettingsContent()
            }
        case .harnesses:
            VStack(alignment: .leading, spacing: 18) {
                if products.isOn(.theo) {
                    StepHeader(title: "Your coding agents", subtitle: "Install and sign in right here. T3 Code is the default for builds; any other harness runs in a live terminal inside Theo.")
                    CodingSettingsView()
                } else {
                    StepHeader(title: "Clicky's brain", subtitle: "The model Clicky answers with. Your Claude subscription works, and so does any API key.")
                }
                if products.isOn(.clicky) {
                    TheoSection(title: "Clicky thinks with", hint: "Clicky is your screen companion. Claude Sonnet 5.5 is a good start, and any agent or API key works.") {
                        SetupBrainRow(companionManager: companionManager)
                    }
                }
            }
        case .keys:
            VStack(alignment: .leading, spacing: 18) {
                if products.isOn(.dictation) {
                    StepHeader(title: "API keys (optional)", subtitle: "Dictation works with Apple's dictation on this Mac; a Sarvam key makes it better. Every key here is optional and stays in your Keychain.")
                    TheoSection(title: "Dictation's Sarvam key", hint: products.dictationAccess == .ready ? "Saved. Dictation uses Sarvam." : "Optional: Sarvam adds Indian languages and Hinglish. Without it Apple's dictation does the listening. You can add it later in Settings \u{203A} Dictation.") {
                        if products.dictationAccess == .ready {
                            SettingRow(title: "Sarvam AI", detail: "Key saved") { StatusPill(text: "Ready", tone: .good) }
                        } else {
                            SarvamKeyField().padding(12)
                        }
                    }
                } else {
                    StepHeader(title: "API keys (optional)", subtitle: "Bring a key for any provider and use it for bots, Theo, Clicky and voices. You can skip this and add them later.")
                }
                ProviderKeysView()
            }
        case .voice:
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: "How should Theo sound?", subtitle: "Theo always listens for \u{201C}hey Theo\u{201D}. Answers can be spoken or shown as captions.")
                VoiceSettingsContent()
            }
        case .done: DoneStep(model: model, setup: model.setup, products: products)
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
    @AppStorage(TheoAppearance.settingKey) private var appearance = TheoAppearance.dark.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TheoMark(size: 72, state: .awake)
            Text("Hi, I'm Theo").font(.system(size: 30, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
            Text("Three products, one app. Next you'll see a short demo of each and turn on only the ones you want. Setup takes about two minutes.")
                .font(.system(size: 15)).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(TheoProduct.allCases.reversed()) { product in
                    feature(product.symbol, product.colors, "\(product.title): \(product.tagline)")
                }
            }
            .padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                Text("What should your bots call you?").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                OwnerNameField(suggestsComputerName: true).frame(width: 260)
            }
            .padding(.top, 8)
            VStack(alignment: .leading, spacing: 8) {
                Text("Pick your look").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                HairlineSegments(options: TheoAppearance.allCases.map { ($0.rawValue, $0.title) }, selection: $appearance).frame(width: 260)
            }
            .padding(.top, 8)
        }
    }

    private func feature(_ symbol: String, _ colors: [Color], _ text: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, colors: colors, size: 26)
            Text(text).font(.system(size: 14)).foregroundColor(DS.Colors.textPrimary)
        }
    }
}

/// The owner's name, as the bots will call them (ClickySettings.ownerName). Saved as it's typed, and Theo's bot guide is
/// rewritten so a bot reading it sees the new name. In setup an empty field starts with the computer's first name, saved
/// straight away so what's shown is what the bots are told.
struct OwnerNameField: View {
    var suggestsComputerName = false
    @State private var draft = ClickySettings.savedOwnerName
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Your first name", text: $draft)
            .focused($focused).theoField(focused: focused)
            .onAppear {
                guard suggestsComputerName, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let suggestion = OwnerName.suggestion(fullUserName: NSFullUserName(), accountName: NSUserName())
                guard !suggestion.isEmpty else { return }
                draft = suggestion
                save(suggestion)
            }
            .onChange(of: draft) { _, newName in save(newName) }
    }

    private func save(_ newName: String) {
        ClickySettings.ownerName = String(newName.prefix(OwnerName.maximumLength))
        BotMemory.writeGuide(owner: BotPrompts.ownerName)
    }
}

private struct DoneStep: View {
    @ObservedObject var model: SetupGuideModel
    @ObservedObject var setup: SetupModel
    @ObservedObject var products: TheoProducts
    @ObservedObject private var look = LookSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Theo smiling: the done face.
            TheoMark(size: 84, state: .done)
            Text("You're all set").font(.system(size: 28, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
            if products.picked.isEmpty {
                Text("Nothing is on yet. Go back to Pick products and turn on at least one.").font(TheoType.body).foregroundColor(DS.Colors.warningText)
            }
            TheoSection(title: "Try one of these", hint: nil) {
                ForEach(Array(tips.enumerated()), id: \.offset) { index, line in
                    if index > 0 { RowDivider() }
                    tip(line)
                }
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
            if products.isOn(.clicky) {
                Button("Test the spark") { setup.testSpark() }.buttonStyle(.theoSecondary).disabled(TheoProfile.isTest)
            }
        }
    }

    /// Something to try with each product that's on.
    private var tips: [String] {
        var lines: [String] = []
        if products.isOn(.clicky) {
            lines.append("\u{201C}Hey Theo, what's on my screen?\u{201D} (Clicky answers)")
            lines.append("\u{201C}Hey Theo, draw me a flowchart of my signup flow.\u{201D}")
        }
        if products.isOn(.theo) { lines.append("Make a bot, then tell it \u{201C}fix the failing test in ~/Projects/foo\u{201D}.") }
        if products.isOn(.dictation) { lines.append("Hold Control + Fn in any app, say a sentence, and let go.") }
        return lines
    }

    private func tip(_ text: String) -> some View {
        Text(text).font(TheoType.body).foregroundColor(DS.Colors.textPrimary).padding(.horizontal, 14).padding(.vertical, 10)
    }
}
