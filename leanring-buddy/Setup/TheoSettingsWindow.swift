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
        case look, studio, clicky, coding, keys, voice, dictation, screen, link, permissions, updates, about
        var id: String { rawValue }

        /// The pages this Mac has: Studio is on a Mac Studio only.
        static var shown: [Section] { allCases.filter { $0 != .studio || StudioController.isAvailable } }

        /// Its Hairline icon.
        var icon: String {
            switch self {
            case .look: return "paint"
            case .studio: return "studio"
            case .clicky: return "clicky"
            case .coding: return "term"
            case .keys: return "key"
            case .voice: return "voice"
            case .dictation: return "mic"
            case .screen: return "screen"
            case .link: return "link"
            case .permissions: return "lock"
            case .updates: return "updates"
            case .about: return "info"
            }
        }

        var title: String {
            switch self {
            case .look: return "Look"
            case .studio: return "Studio"
            case .clicky: return "Clicky"
            case .coding: return "Harnesses"
            case .keys: return "Models & API keys"
            case .voice: return "Voice"
            case .dictation: return "Dictation"
            case .screen: return "Screen"
            case .link: return "Your other Mac"
            case .permissions: return "Permissions"
            case .updates: return "Updates"
            case .about: return "About"
            }
        }

        var subtitle: String {
            switch self {
            case .look: return "How Theo looks and moves. Click one and it changes right away."
            case .studio: return "Hidden screens your bots work on, with small live views inside Theo."
            case .clicky: return "Everything about your screen companion, in one place."
            case .coding: return "Your coding agents: install, sign in, and where builds go."
            case .keys: return "Bring your own key for any provider, and use it anywhere in Theo."
            case .voice: return "How Clicky and Theo speak, how they hear you, and calls."
            case .dictation: return "Hold a shortcut in any app, talk, and it's typed."
            case .screen: return "The monitor Theo works on, leaving your main screen alone."
            case .link: return "Both Macs run as one Theo: the same bots, group chats, chats and memory."
            case .permissions: return "What Theo needs to hear, see and point."
            case .updates: return "Keep Theo current."
            case .about: return "The Dock icon and the setup guide."
            }
        }

        var symbol: String {
            switch self {
            case .look: return "paintbrush.pointed.fill"
            case .studio: return "rectangle.split.2x1"
            case .clicky: return "cursorarrow.rays"
            case .coding: return "terminal.fill"
            case .keys: return "key.fill"
            case .voice: return "waveform"
            case .dictation: return "mic.fill"
            case .screen: return "display"
            case .link: return "link"
            case .permissions: return "lock.shield.fill"
            case .updates: return "arrow.down.circle.fill"
            case .about: return "info.circle.fill"
            }
        }

        var colors: [Color] {
            switch self {
            case .look: return TileColors.violet
            case .studio: return TileColors.graphite
            case .clicky: return TileColors.ember
            case .coding: return TileColors.graphite
            case .keys: return TileColors.amber
            case .voice: return TileColors.rose
            case .dictation: return TileColors.violet
            case .screen: return TileColors.sky
            case .link: return TileColors.teal
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
            ForEach(SettingsTab.Section.shown) { section in
                Button { selection.openSettings(section) } label: {
                    HStack(spacing: 10) {
                        HairlineIcon(name: section.icon, size: 20, color: current == section ? DS.Colors.textPrimary : DS.Colors.textSecondary, selected: current == section)
                        Text(section.title).font(.system(size: 13)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(SidebarButtonStyle(isSelected: current == section))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 264)
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
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .id(section)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .look: LookSettingsContent()
        case .studio: StudioSettingsContent()
        case .clicky: ClickySettingsContent()
        case .coding: CodingSettingsView()
        case .keys: ProviderKeysView()
        case .voice: VoiceSettingsContent()
        case .dictation: DictationSettingsContent()
        case .screen: ScreenSettingsContent()
        case .link: LinkSettingsContent()
        case .permissions: PermissionsSettingsContent()
        case .updates: UpdatesSettingsContent()
        case .about: AboutSettingsContent()
        }
    }
}

// MARK: - Look

struct LookSettingsContent: View {
    @ObservedObject private var look = LookSettings.shared
    @AppStorage(TheoAppearance.settingKey) private var appearance = TheoAppearance.dark.rawValue
    @AppStorage(TheoAccent.settingKey) private var accent = "ember"
    @AppStorage(TheoMotionLevel.settingKey) private var motion = TheoMotionLevel.lively.rawValue
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "Appearance", hint: nil) {
                HStack(spacing: 10) {
                    ForEach(TheoAppearance.allCases) { option in appearanceCard(option) }
                }
                .padding(12)
            }
            TheoSection(title: "Accent", hint: nil) {
                HStack(spacing: 10) {
                    ForEach(TheoPalette.accents, id: \.id) { swatch in
                        Button { accent = swatch.id } label: {
                            Circle().fill(Color(hex: scheme == .dark ? swatch.dark : swatch.light)).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().strokeBorder(accent == swatch.id ? DS.Colors.textPrimary : .clear, lineWidth: 2))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain).help(swatch.id.capitalized)
                    }
                    Spacer()
                }
                .padding(12)
            }
            TheoSection(title: "Motion", hint: DS.Motion.level == .off && motion != "off" ? "Reduce Motion is on in macOS, so everything holds still." : nil) {
                SettingRow(title: "Motion", detail: "Your crew, animated icons and live dots. Off stops all of it.") {
                    HairlineSegments(options: TheoMotionLevel.allCases.map { ($0.rawValue, $0.title) }, selection: $motion)
                }
            }
            TheoSection(title: "Cursor", hint: "The spark that follows you, and where it lives.") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(CompanionIconStyle.allCases, id: \.self) { style in
                        CursorTile(style: style, isSelected: look.sparkStyle == style) { look.sparkStyle = style }
                    }
                }
                .padding(12)
                RowDivider()
                ChoiceChips(options: [(ClickySettings.SparkMode.cursor, "Follows my pointer", "cursorarrow.motionlines"),
                                      (.docked, "Lives in a corner of Theo's screen", "rectangle.bottomthird.inset.filled")], selection: $look.sparkMode)
                    .padding(12)
            }
            TheoSection(title: "Whiteboard and notch colours", hint: "Also used on the T3 Code page. The window itself follows Appearance above.") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
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

    private func appearanceCard(_ option: TheoAppearance) -> some View {
        let on = appearance == option.rawValue
        return Button { appearance = option.rawValue } label: {
            VStack(spacing: 6) {
                AppearancePreview(option: option).frame(height: 52)
                Text(option.title).font(.system(size: 11.5)).foregroundColor(on ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A tiny Theo window in Black, Light or half of each.
private struct AppearancePreview: View {
    let option: TheoAppearance

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            switch option {
            case .dark: window(page: Color.black, side: Color(hex: 0x0B0B0B))
            case .light: window(page: Color.white, side: Color(hex: 0xF4F4F4))
            case .system:
                HStack(spacing: 0) { Color.black; Color.white }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(option == .light ? Color(hex: 0xE5E5E5) : Color(hex: 0x333333), lineWidth: 1))
    }

    private func window(page: Color, side: Color) -> some View {
        GeometryReader { box in
            HStack(spacing: 0) {
                side.frame(width: box.size.width * 0.28)
                ZStack(alignment: .topLeading) {
                    page
                    Capsule().fill(DS.Colors.accent).frame(width: box.size.width * 0.3, height: 6).padding(10)
                }
            }
        }
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
                    .multilineTextAlignment(.center).lineLimit(2).foregroundColor(Color.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .padding(6)
            // Always dark: the sparks are drawn for it, in either appearance.
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x111114)))
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
                    .multilineTextAlignment(.leading).lineLimit(1).minimumScaleFactor(0.85)
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
    var claudeOnly = false
    @ObservedObject private var catalog = BrainCatalog.shared
    @ObservedObject private var keys = ProviderKeys.shared
    private static let addKeyTag = "__add_key"

    var body: some View {
        Picker(title, selection: Binding(get: { setting }, set: { value in
            if value == Self.addKeyTag { TheoSettingsWindowController.show(section: .keys) } else { setting = value }
        })) {
            ForEach(claudeOnly ? [BrainProvider.claude] : BrainProvider.allCases, id: \.self) { provider in
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
            if !claudeOnly {
                ForEach(keys.usableChatProviders) { provider in
                    Section("\(provider.label) API") {
                        ForEach(keys.models(for: provider), id: \.self) { model in
                            Text(model).tag(BrainModel(provider: .api, modelIdentifier: "\(provider.id)/\(model)").setting)
                        }
                    }
                }
            }
            if !isListed { Text(catalog.label(for: setting)).tag(setting) }
            if !claudeOnly {
                Divider()
                Text("Add an API key…").tag(Self.addKeyTag)
            }
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
                    // Voice code tasks run through Claude Code, so only its models work here.
                    BrainModelPicker(title: "Code tasks", setting: Binding(get: { code }, set: { code = $0; ClickyModels.code = $0 }), claudeOnly: true).frame(width: 260)
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
            ClickyVoicePicker()
            TheoSection(title: "Also", hint: nil) {
                linkRow("Cursor style", detail: look.sparkStyle.displayName, section: .look)
                RowDivider()
                linkRow("Listening", detail: "How it hears you", section: .voice)
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
    @AppStorage(CloudListening.settingKey) private var listening = ""
    @AppStorage(CallSettings.languageKey) private var callLanguage = CallSettings.Language.auto.rawValue
    @AppStorage(CallSettings.modelKey) private var callModel = "claude-sonnet-5-5"
    @ObservedObject private var keys = ProviderKeys.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ClickyVoicePicker()
            TheoSection(title: "Hears you with", hint: "Push-to-talk goes through this when it's set. The wake word always stays on this Mac.") {
                listenRow(id: "", logo: nil, title: "On this Mac", detail: "Apple's speech recognition, private and instant", available: true)
                RowDivider(inset: 54)
                listenRow(id: "deepgram", logo: "deepgram", title: "Deepgram", detail: "Cloud, very accurate", available: keys.hasKey(for: "deepgram"))
                RowDivider(inset: 54)
                listenRow(id: "assemblyai", logo: "assemblyai", title: "AssemblyAI", detail: "Cloud, very accurate", available: keys.hasKey(for: "assemblyai"))
                RowDivider(inset: 54)
                listenRow(id: "sarvam", logo: "sarvam", title: "Sarvam Saaras", detail: "Best for Indian languages and code-mixing", available: keys.hasKey(for: "sarvam"))
            }
            TheoSection(title: "Calls with Theo", hint: keys.hasKey(for: "sarvam") ? "Calls listen and speak with Sarvam, in Hindi, English or Hinglish." : "Calls use Apple's listening and the Mac voice until a Sarvam key is saved. Hindi and Hinglish sound far better with Sarvam.") {
                SettingRow(title: "Language", detail: "Auto answers in whatever you just spoke.") {
                    Picker("Language", selection: $callLanguage) {
                        ForEach(CallSettings.Language.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                RowDivider()
                SettingRow(title: "Thinks with") {
                    Picker("Thinks with", selection: $callModel) {
                        Text("Claude Sonnet 5.5").tag("claude-sonnet-5-5")
                        Text("Claude Haiku 5.5 (fastest)").tag("claude-haiku-5-5")
                    }
                    .labelsHidden().frame(width: 220)
                }
                RowDivider()
                SettingRow(title: "Talk to Theo now") {
                    Button { TheoCallController.start() } label: { Label("Call Theo", systemImage: "phone.fill") }.buttonStyle(.theoPrimary)
                }
            }
        }
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
