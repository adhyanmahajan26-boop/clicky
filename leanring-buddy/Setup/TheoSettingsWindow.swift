//
//  TheoSettingsWindow.swift
//  leanring-buddy
//
//  Settings live inside Theo's one window: the sidebar swaps to a list of sections with icon tiles, and every page
//  is one click away. There's no second window that can open behind the first, and any "Add a key" or "Change" button
//  anywhere lands on the right page straight away.
//

import AppKit
import AVFoundation
import ClickyCore
import Combine
import Speech
import SwiftUI

@MainActor
enum TheoSettingsWindowController {
    /// Opens Settings on a page, in Theo's window.
    static func show(section: SettingsTab.Section = .look) {
        guard let manager = CompanionManager.current else { return }
        BotsSelection.shared.openSettings(section)
        TheoHomeWindowController.show(companionManager: manager)
    }
}

enum SettingsTab {
    enum Section: String, CaseIterable, Identifiable {
        case look, clicky, coding, keys, voice, screen, permissions, updates, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .look: return "Look"
            case .clicky: return "Clicky"
            case .coding: return "Harnesses"
            case .keys: return "Models & API keys"
            case .voice: return "Voice"
            case .screen: return "Screen"
            case .permissions: return "Permissions"
            case .updates: return "Updates"
            case .about: return "About"
            }
        }

        var subtitle: String {
            switch self {
            case .look: return "Cursor, theme and pill. Click one and it changes right away."
            case .clicky: return "Everything about your screen companion, in one place."
            case .coding: return "Your coding agents: install, sign in, and where builds go."
            case .keys: return "Bring your own key for any provider, and use it anywhere in Theo."
            case .voice: return "How Clicky and Theo speak, and how they hear you."
            case .screen: return "The monitor Theo works on, leaving your main screen alone."
            case .permissions: return "What Theo needs to hear, see and point."
            case .updates: return "Keep Theo current."
            case .about: return "Dock, setup guide and version."
            }
        }

        var symbol: String {
            switch self {
            case .look: return "paintbrush.pointed.fill"
            case .clicky: return "cursorarrow.rays"
            case .coding: return "terminal.fill"
            case .keys: return "key.fill"
            case .voice: return "waveform"
            case .screen: return "display"
            case .permissions: return "lock.shield.fill"
            case .updates: return "arrow.down.circle.fill"
            case .about: return "info.circle.fill"
            }
        }

        var colors: [Color] {
            switch self {
            case .look: return TileColors.violet
            case .clicky: return TileColors.ember
            case .coding: return TileColors.graphite
            case .keys: return TileColors.amber
            case .voice: return TileColors.rose
            case .screen: return TileColors.sky
            case .permissions: return TileColors.teal
            case .updates: return TileColors.lime
            case .about: return TileColors.slate
            }
        }
    }
}

/// The sidebar while Settings is open.
struct SettingsSidebar: View {
    @ObservedObject var selection: BotsSelection
    let current: SettingsTab.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Color.clear.frame(height: 40)
            Button { selection.closeSettings() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textSecondary).frame(width: 22)
                    Text("Back to Theo").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 8).frame(height: 34).contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle(isSelected: false))
            .keyboardShortcut(.cancelAction)
            Text("SETTINGS").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(DS.Colors.textTertiary)
                .padding(.leading, 10).padding(.top, 14).padding(.bottom, 4)
            ForEach(SettingsTab.Section.allCases) { section in
                Button { selection.openSettings(section) } label: {
                    HStack(spacing: 10) {
                        IconTile(symbol: section.symbol, colors: section.colors, size: 22)
                        Text(section.title).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 34).contentShape(Rectangle())
                }
                .buttonStyle(SidebarButtonStyle(isSelected: current == section))
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 248)
        .background(DS.Colors.sidebar)
    }
}

/// One Settings page: its title and its content, scrolled.
struct SettingsPage: View {
    let section: SettingsTab.Section

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(TheoType.title).foregroundColor(DS.Colors.textPrimary)
                    Text(section.subtitle).font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
                }
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .id(section)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .look: LookSettingsContent()
        case .clicky: ClickySettingsContent()
        case .coding: CodingSettingsView()
        case .keys: ProviderKeysView()
        case .voice: VoiceSettingsContent()
        case .screen: ScreenSettingsContent()
        case .permissions: PermissionsSettingsContent()
        case .updates: UpdatesSettingsContent()
        case .about: AboutSettingsContent()
        }
    }
}

// MARK: - Look

struct LookSettingsContent: View {
    @ObservedObject private var look = LookSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "Cursor", hint: "The spark that follows you, everywhere at once.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                    ForEach(CompanionIconStyle.allCases, id: \.self) { style in
                        CursorTile(style: style, isSelected: look.sparkStyle == style) { look.sparkStyle = style }
                    }
                }
                .padding(12)
            }
            TheoSection(title: "Spark", hint: nil) {
                ChoiceChips(options: [(ClickySettings.SparkMode.cursor, "Follows my pointer", "cursorarrow.motionlines"),
                                      (.docked, "Lives in a corner of Theo's screen", "rectangle.bottomthird.inset.filled")], selection: $look.sparkMode)
                    .padding(12)
            }
            TheoSection(title: "Theme", hint: "Colours for Notes and T3 Code.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(ClaudiaTheme.allCases, id: \.self) { theme in
                        ThemeTile(theme: theme, isSelected: look.theme == theme) { look.theme = theme }
                    }
                }
                .padding(12)
            }
            TheoSection(title: "Pill", hint: "Where Theo's status pill lives.") {
                ChoiceChips(options: [(ClickySettings.IslandPlacement.notch, "Notch", "rectangle.topthird.inset.filled"),
                                      (.floating, "Floating", "rectangle.dashed"),
                                      (.corner, "Top-right corner", "rectangle.inset.topright.filled")], selection: $look.placement)
                    .padding(12)
            }
        }
        .onAppear { look.reload() }
    }
}

/// A row of one-click options, the chosen one filled.
struct ChoiceChips<Value: Hashable>: View {
    let options: [(Value, String, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = selection == option.0
                Button { selection = option.0 } label: {
                    HStack(spacing: 8) {
                        Image(systemName: option.2).font(.system(size: 13))
                        Text(option.1).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                    }
                    .foregroundColor(selected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? DS.Colors.accent.opacity(0.16) : DS.Colors.hover))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? DS.Colors.accent.opacity(0.8) : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A cursor style: the spark on black, its name, and a check when it's the one in use.
struct CursorTile: View {
    let style: CompanionIconStyle
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                CompanionIconPreview(style: style).frame(width: 40, height: 40).padding(8)
                Text(style.displayName).font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.center).lineLimit(2).foregroundColor(DS.Colors.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? DS.Colors.accent : Color.white.opacity(isHovering ? 0.22 : 0.06), lineWidth: isSelected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if isSelected { Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundColor(DS.Colors.accent).padding(7) }
            }
            .animation(DS.Motion.hover, value: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A theme swatch: the theme's background and accent with its name.
struct ThemeTile: View {
    let theme: ClaudiaTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let palette = theme.palette
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.map { ClaudiaTheme.color($0.background) } ?? DS.Colors.surface)
                    if let palette {
                        Circle().fill(ClaudiaTheme.color(palette.accent)).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "circle.lefthalf.filled").font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .frame(width: 30, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                Text(theme.displayName).font(.system(size: 12, weight: isSelected ? .semibold : .regular)).foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? DS.Colors.accent.opacity(0.16) : DS.Colors.hover))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? DS.Colors.accent.opacity(0.8) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Clicky

/// Any model Clicky (or its helpers) can think with: the signed-in agents, and every provider with a saved key.
struct BrainModelPicker: View {
    let title: String
    @Binding var setting: String
    @ObservedObject private var catalog = BrainCatalog.shared
    @ObservedObject private var keys = ProviderKeys.shared
    private static let addKeyTag = "__add_key"

    var body: some View {
        Picker(title, selection: Binding(get: { setting }, set: { value in
            if value == Self.addKeyTag { TheoSettingsWindowController.show(section: .keys) } else { setting = value }
        })) {
            ForEach(BrainProvider.allCases, id: \.self) { provider in
                let identifiers = catalog.models[provider] ?? []
                if !identifiers.isEmpty {
                    Section(provider.displayName) {
                        ForEach(identifiers, id: \.self) { identifier in
                            let value = BrainModel(provider: provider, modelIdentifier: identifier).setting
                            Text(catalog.label(for: value)).tag(value)
                        }
                    }
                }
            }
            ForEach(keys.usableChatProviders) { provider in
                Section("\(provider.label) API") {
                    ForEach(keys.models(for: provider), id: \.self) { model in
                        Text(model).tag(BrainModel(provider: .api, modelIdentifier: "\(provider.id)/\(model)").setting)
                    }
                }
            }
            if !isListed { Text(catalog.label(for: setting)).tag(setting) }
            Divider()
            Text("Add an API key…").tag(Self.addKeyTag)
        }
        .labelsHidden()
        .onAppear { catalog.load() }
    }

    private var isListed: Bool {
        let model = BrainModel(setting: setting)
        if model.provider == .api {
            let parts = model.modelIdentifier.split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 && keys.usableChatProviders.contains { $0.id == parts[0] && keys.models(for: $0).contains(parts[1]) }
        }
        return (catalog.models[model.provider] ?? []).contains(model.modelIdentifier)
    }
}

struct ClickySettingsContent: View {
    @ObservedObject private var look = LookSettings.shared
    @State private var main = ClickyModels.main
    @State private var helper = ClickyModels.helper
    @State private var code = ClickyModels.code
    @State private var silent = ClickySettings.isSilentModeEnabled
    @State private var listens = ClickySettings.isWakeWordEnabled
    @State private var actions = ClickySettings.isActionsEnabled
    @State private var name = ClickySettings.assistantName
    private var manager: CompanionManager? { CompanionManager.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "", hint: nil) {
                HStack(spacing: 12) {
                    ClickyAvatar(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clicky").font(TheoType.headline).foregroundColor(DS.Colors.textPrimary)
                        Text("Sees your screens, points at things, draws boards, researches links with helpers, and acts on Theo's own screen.")
                            .font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("Clicky on", isOn: Binding(get: { listens }, set: setClicky)).toggleStyle(.switch).labelsHidden()
                }
                .padding(14)
            }
            TheoSection(title: "Brain", hint: BrainModel(setting: main).sendsScreenshotsToThirdParty ? "This model runs in someone else's cloud, so your screenshots go to that provider." : nil) {
                SettingRow(title: "Thinks with", detail: "Answers everything you ask Clicky.") {
                    BrainModelPicker(title: "Thinks with", setting: Binding(get: { main }, set: { value in
                        main = value
                        if let manager { manager.setSelectedModel(value) } else { ClickyModels.main = value }
                    })).frame(width: 260)
                }
                RowDivider()
                SettingRow(title: "Helpers", detail: "Research pages, helper workers, mark checks.") {
                    BrainModelPicker(title: "Helpers", setting: Binding(get: { helper }, set: { helper = $0; ClickyModels.helper = $0 })).frame(width: 260)
                }
                RowDivider()
                SettingRow(title: "Code tasks", detail: "When you ask Clicky to change code by voice.") {
                    BrainModelPicker(title: "Code tasks", setting: Binding(get: { code }, set: { code = $0; ClickyModels.code = $0 })).frame(width: 260)
                }
            }
            TheoSection(title: "Behaviour", hint: nil) {
                SettingRow(title: "Name", detail: "What you call it: \u{201C}hey \(name)\u{201D}.") {
                    TextField("Theo", text: Binding(get: { name }, set: { name = $0; if !$0.trimmingCharacters(in: .whitespaces).isEmpty { ClickySettings.assistantName = $0 } })).theoField().frame(width: 160)
                }
                RowDivider()
                SettingRow(title: "Listens for its name", detail: "On-device. Pauses when another app uses the mic.") {
                    Toggle("Listens", isOn: Binding(get: { listens }, set: { value in
                        listens = value
                        if let manager { manager.wakeWordController.setEnabled(value) } else { ClickySettings.isWakeWordEnabled = value }
                    })).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(title: "Speaks answers", detail: "Off: captions, marks and boards only.") {
                    Toggle("Speaks", isOn: Binding(get: { !silent }, set: { value in
                        silent = !value
                        ClickySettings.isSilentModeEnabled = !value
                    })).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(title: "Acts on screen", detail: "Opens, clicks and types on Theo's own monitor, with its own cursor.") {
                    Toggle("Acts", isOn: Binding(get: { actions }, set: { value in
                        actions = value
                        UserDefaults.standard.set(value, forKey: ClickySettings.Keys.actionsEnabled)
                    })).toggleStyle(.switch).labelsHidden()
                }
            }
            TheoSection(title: "Also", hint: nil) {
                linkRow("Cursor style", detail: look.sparkStyle.displayName, section: .look)
                RowDivider()
                linkRow("Voice", detail: "How it speaks and hears", section: .voice)
                RowDivider()
                linkRow("Theo's screen", detail: look.screenName.isEmpty ? "Follows your pointer" : look.screenName, section: .screen)
            }
        }
    }

    private func linkRow(_ title: String, detail: String, section: SettingsTab.Section) -> some View {
        Button { TheoSettingsWindowController.show(section: section) } label: {
            HStack {
                Text(title).font(TheoType.body).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text(detail).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 14).frame(height: 38).contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(isSelected: false))
    }

    private func setClicky(_ on: Bool) {
        listens = on
        if let manager {
            manager.wakeWordController.setEnabled(on)
            manager.setClickyCursorEnabled(on)
        } else {
            ClickySettings.isWakeWordEnabled = on
        }
    }
}

// MARK: - Voice

struct VoiceSettingsContent: View {
    @AppStorage(SarvamVoiceSettings_Keys.engine) private var engine = ""
    @AppStorage(CloudListening.settingKey) private var listening = ""
    @ObservedObject private var keys = ProviderKeys.shared
    @State private var usesQwen = CompanionManager.current?.speechOutputClient.usesQwenLocalVoice ?? false
    @State private var bestMacVoice = SystemVoiceTTSClient.automaticallyChosenVoice()
    private var manager: CompanionManager? { CompanionManager.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "Clicky and Theo speak with", hint: nil) {
                voiceRow(id: "qwen", logo: nil, symbol: "waveform.circle.fill", title: "Theo's voice", detail: "Qwen, running on this Mac", available: QwenLocalTTSClient.isAvailable, selected: engine.isEmpty && usesQwen) {
                    engine = ""
                    usesQwen = true
                    manager?.speechOutputClient.selectQwenLocalVoice()
                }
                RowDivider(inset: 54)
                voiceRow(id: "mac", logo: nil, symbol: "apple.logo", title: "Mac voice", detail: macVoiceDetail, available: true, selected: engine.isEmpty && !usesQwen) {
                    engine = ""
                    usesQwen = false
                    manager?.speechOutputClient.selectSystemVoice(identifier: nil)
                }
                RowDivider(inset: 54)
                voiceRow(id: "sarvam", logo: "sarvam", symbol: nil, title: "Sarvam Bulbul", detail: "Indian English, Hindi and Hinglish", available: keys.hasKey(for: "sarvam"), selected: engine == "sarvam") { engine = "sarvam" }
                RowDivider(inset: 54)
                voiceRow(id: "elevenlabs", logo: "elevenlabs", symbol: nil, title: "ElevenLabs", detail: "Natural voices, in many languages", available: keys.hasKey(for: "elevenlabs"), selected: engine == "elevenlabs") { engine = "elevenlabs" }
            }
            if bestMacVoice?.quality != .premium && engine.isEmpty && !usesQwen {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(DS.Colors.warning)
                    Text("Mac's compact voices sound robotic. A free Premium voice sounds far better: download one in System Settings › Accessibility › Spoken Content.")
                        .font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.theoSecondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.warning.opacity(0.1)))
            }
            HStack(spacing: 8) {
                Button { manager?.speechOutputClient.previewVoice() } label: { Label("Hear it", systemImage: "play.fill") }.buttonStyle(.theoPrimary).disabled(TheoProfile.isTest)
                Button("All voices…") { manager?.voiceGalleryController.showWindow(activatesClicky: true) }.buttonStyle(.theoSecondary)
                Spacer()
            }
            if engine == "sarvam" { SarvamVoiceSettings() }
            if engine == "elevenlabs" { ElevenLabsVoiceSettings() }
            TheoSection(title: "Hears you with", hint: "Push-to-talk goes through this when it's set. The wake word always stays on this Mac.") {
                listenRow(id: "", logo: nil, title: "On this Mac", detail: "Apple's speech recognition, private and instant", available: true)
                RowDivider(inset: 54)
                listenRow(id: "deepgram", logo: "deepgram", title: "Deepgram", detail: "Cloud, very accurate", available: keys.hasKey(for: "deepgram"))
                RowDivider(inset: 54)
                listenRow(id: "assemblyai", logo: "assemblyai", title: "AssemblyAI", detail: "Cloud, very accurate", available: keys.hasKey(for: "assemblyai"))
                RowDivider(inset: 54)
                listenRow(id: "sarvam", logo: "sarvam", title: "Sarvam Saaras", detail: "Best for Indian languages and code-mixing", available: keys.hasKey(for: "sarvam"))
            }
        }
    }

    private var macVoiceDetail: String {
        guard let voice = bestMacVoice else { return "The best voice installed" }
        let quality = voice.quality == .premium ? "premium" : voice.quality == .enhanced ? "enhanced" : "compact"
        return "\(voice.name), \(quality)"
    }

    private func voiceRow(id: String, logo: String?, symbol: String?, title: String, detail: String, available: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        selectRow(logo: logo, symbol: symbol, title: title, detail: detail, available: available, selected: selected, action: action)
    }

    private func listenRow(id: String, logo: String?, title: String, detail: String, available: Bool) -> some View {
        selectRow(logo: logo, symbol: logo == nil ? "mic.fill" : nil, title: title, detail: detail, available: available, selected: listening == id) { listening = id }
    }

    private func selectRow(logo: String?, symbol: String?, title: String, detail: String, available: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if available { action() } else { TheoSettingsWindowController.show(section: .keys) }
        } label: {
            HStack(spacing: 12) {
                if let logo {
                    BrandLogo(id: logo, name: title, size: 30)
                } else {
                    IconTile(symbol: symbol ?? "circle", colors: TileColors.graphite, size: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                    Text(detail).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
                Spacer()
                if !available {
                    Text("Add a key").font(TheoType.caption).foregroundColor(DS.Colors.accentText)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 16))
                        .foregroundColor(selected ? DS.Colors.accent : DS.Colors.textDisabled)
                }
            }
            .padding(.horizontal, 12).frame(height: 50).contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(isSelected: false))
    }
}

struct SarvamVoiceSettings: View {
    @AppStorage(SarvamVoiceSettings_Keys.model) private var model = "bulbul:v4-flash"
    @AppStorage(SarvamVoiceSettings_Keys.speaker) private var speaker = "shubh"
    @AppStorage(SarvamVoiceSettings_Keys.language) private var language = "hi-IN"
    @AppStorage(SarvamVoiceSettings_Keys.pace) private var pace = 1.0

    private var speakerOptions: [String] { model.hasPrefix("bulbul:v4") ? SarvamClient.v4SpeakerCatalog.flatMap(\.speakers) : SarvamClient.v3Speakers }

    var body: some View {
        TheoSection(title: "Sarvam voice", hint: nil) {
            SettingRow(title: "Model") {
                Picker("Model", selection: $model) {
                    Text("Bulbul v4 flash").tag("bulbul:v4-flash")
                    Text("Bulbul v3").tag("bulbul:v3")
                }.labelsHidden().frame(width: 200)
            }
            RowDivider()
            SettingRow(title: "Language") {
                Picker("Language", selection: $language) {
                    Text("Hindi").tag("hi-IN")
                    Text("Indian English").tag("en-IN")
                    Text("Hinglish").tag("hinglish")
                }.labelsHidden().frame(width: 200)
            }
            RowDivider()
            SettingRow(title: "Speaker") {
                Picker("Speaker", selection: $speaker) {
                    if !speakerOptions.contains(speaker) { Text(speaker).tag(speaker) }
                    ForEach(speakerOptions, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 200)
            }
            RowDivider()
            SettingRow(title: "Pace", detail: String(format: "%.2fx", pace)) {
                Slider(value: $pace, in: 0.5...2.0, step: 0.05).frame(width: 200)
            }
        }
    }
}

struct ElevenLabsVoiceSettings: View {
    @AppStorage(ElevenLabsClient.voiceKey) private var voice = ""
    @AppStorage(ElevenLabsClient.modelKey) private var model = ElevenLabsClient.defaultModel
    @State private var voices: [ElevenLabsClient.Voice] = []
    @State private var problem: String?

    var body: some View {
        TheoSection(title: "ElevenLabs voice", hint: problem) {
            SettingRow(title: "Voice") {
                Picker("Voice", selection: $voice) {
                    if voices.isEmpty { Text(voice.isEmpty ? "Loading…" : voice).tag(voice) }
                    ForEach(voices) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(width: 240)
            }
            RowDivider()
            SettingRow(title: "Model") {
                Picker("Model", selection: $model) {
                    Text("Multilingual v2").tag("eleven_multilingual_v2")
                    Text("Flash v2.5 (fastest)").tag("eleven_flash_v2_5")
                    Text("Turbo v2.5").tag("eleven_turbo_v2_5")
                }.labelsHidden().frame(width: 240)
            }
        }
        .task {
            do {
                voices = try await ElevenLabsClient.listVoices()
                if voice.isEmpty, let first = voices.first { voice = first.id }
            } catch { problem = error.localizedDescription }
        }
    }
}

// MARK: - Screen

struct ScreenSettingsContent: View {
    @ObservedObject private var look = LookSettings.shared

    var body: some View {
        TheoSection(title: "Theo's screen", hint: "With a screen picked, Theo opens its windows, browser, boards and notes there, with its own cursor, and leaves your main screen alone.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                tile(name: "", title: "Follow my pointer", symbol: "cursorarrow.rays")
                ForEach(look.screenNames, id: \.self) { name in tile(name: name, title: name, symbol: "display") }
            }
            .padding(12)
        }
    }

    private func tile(name: String, title: String, symbol: String) -> some View {
        let selected = look.screenName == name
        return Button { look.screenName = name } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundColor(selected ? DS.Colors.accent : DS.Colors.textSecondary)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).foregroundColor(DS.Colors.textPrimary).multilineTextAlignment(.center).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? DS.Colors.accent.opacity(0.14) : DS.Colors.hover))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? DS.Colors.accent.opacity(0.8) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Permissions

struct PermissionsSettingsContent: View {
    @State private var speech = SFSpeechRecognizer.authorizationStatus()
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibility = CompanionManager.current?.hasAccessibilityPermission ?? false
    @State private var screen = CompanionManager.current?.hasScreenRecordingPermission ?? false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TheoSection(title: "", hint: "Theo checks every second, so this page updates by itself. Without a permission Theo still runs: it just can't do that one thing, and tells you so.") {
            row("Microphone", "Hears \u{201C}hey Theo\u{201D} and push-to-talk", "mic.fill", microphone == .authorized) { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
            RowDivider(inset: 50)
            row("Speech recognition", "Turns what you say into words, on this Mac", "waveform", speech == .authorized) { SFSpeechRecognizer.requestAuthorization { _ in } }
            RowDivider(inset: 50)
            row("Accessibility", "Points at and clicks the right things", "accessibility", accessibility) { _ = TheoPermissions.askForAccessibility() }
            RowDivider(inset: 50)
            row("Screen recording", "Sees your screens when you ask", "rectangle.dashed.badge.record", screen) { _ = TheoPermissions.askForScreenRecording() }
        }
        .onReceive(ticker) { _ in
            speech = SFSpeechRecognizer.authorizationStatus()
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            CompanionManager.current?.refreshAllPermissions()
            accessibility = CompanionManager.current?.hasAccessibilityPermission ?? false
            screen = CompanionManager.current?.hasScreenRecordingPermission ?? false
        }
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, _ granted: Bool, ask: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, colors: TileColors.graphite, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                Text(detail).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            if granted {
                StatusPill(text: "Allowed", tone: .good)
            } else {
                Button("Allow…", action: ask).buttonStyle(.theoSecondary)
            }
        }
        .padding(.horizontal, 12).frame(height: 54)
    }
}

// MARK: - Updates and About

struct UpdatesSettingsContent: View {
    var body: some View {
        if let manager = CompanionManager.current {
            UpdatesRows(updateController: manager.updateController)
        }
    }
}

private struct UpdatesRows: View {
    @ObservedObject var updateController: UpdateController

    var body: some View {
        TheoSection(title: "", hint: statusLine) {
            SettingRow(title: "This is Theo \(updateController.currentVersionLabel)") {
                if let release = updateController.availableRelease {
                    Button("Update to build \(release.build)") { updateController.installAvailableUpdate() }.buttonStyle(.theoPrimary)
                } else {
                    Button(updateController.state == .checking ? "Checking…" : "Check for updates") { Task { await updateController.check() } }
                        .buttonStyle(.theoSecondary).disabled(updateController.state == .checking)
                }
            }
        }
    }

    private var statusLine: String {
        switch updateController.state {
        case .idle: return "Theo checks when it starts and every 6 hours. Updating keeps your settings and permissions."
        case .checking: return "Checking…"
        case .upToDate: return "You have the newest build."
        case .available: return "A newer build is ready. Theo quits, updates itself and reopens."
        case .installing(let message): return message
        case .failed(let message): return message
        }
    }
}

struct AboutSettingsContent: View {
    @State private var showsInDock = ClickySettings.showsInDock

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "", hint: nil) {
                SettingRow(title: "Show Theo in the Dock", detail: "Off: Theo lives only in the menu bar.") {
                    Toggle("Dock", isOn: $showsInDock).toggleStyle(.switch).labelsHidden()
                        .onChange(of: showsInDock) { _, value in
                            ClickySettings.showsInDock = value
                            if !TheoProfile.isTest { NSApp.setActivationPolicy(value ? .regular : .accessory) }
                        }
                }
                RowDivider()
                SettingRow(title: "Setup guide", detail: "Permissions, harnesses, keys and voice, one step at a time.") {
                    Button("Run it again") {
                        if let manager = CompanionManager.current { SetupGuideWindowController.show(companionManager: manager, step: .welcome) }
                    }
                    .buttonStyle(.theoSecondary)
                }
            }
            TheoSection(title: "Keyboard", hint: nil) {
                shortcut("New bot", "⌘N")
                RowDivider()
                shortcut("Search", "⌘K")
                RowDivider()
                shortcut("Settings", "⌘,")
                RowDivider()
                shortcut("Talk to Clicky", "⌃⌥ hold")
            }
        }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        SettingRow(title: title) {
            Text(keys).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 7).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(DS.Colors.hover))
        }
    }
}
