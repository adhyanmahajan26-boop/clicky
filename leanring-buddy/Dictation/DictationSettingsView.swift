//
//  DictationSettingsView.swift
//  leanring-buddy
//
//  Settings › Dictation: on or off, the shortcut, who listens, the clean-up, the language and the owner's own words.
//

import ClickyCore
import SwiftUI

struct DictationSettingsContent: View {
    @AppStorage(DictationSettings.enabledKey) private var enabled = true
    @AppStorage(DictationSettings.shortcutKey) private var shortcut = DictationShortcut.controlFn.rawValue
    @AppStorage(DictationSettings.engineKey) private var engine = DictationSettings.Engine.automatic.rawValue
    @AppStorage(DictationSettings.cleanupKey) private var cleanup = true
    @AppStorage(DictationSettings.languageKey) private var language = "auto"
    @AppStorage(DictationSettings.dictionaryKey) private var dictionary = ""
    @ObservedObject private var keys = ProviderKeys.shared
    @State private var newWord = ""
    @State private var tryItText = ""

    private var picked: DictationShortcut { DictationShortcut(rawValue: shortcut) ?? .controlFn }
    private var manager: CompanionManager? { CompanionManager.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "Dictate anywhere", hint: nil) {
                HStack(spacing: 12) {
                    IconTile(symbol: "mic.fill", colors: TileColors.rose, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("Hold").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                            ForEach(picked.keyCaps, id: \.self) { KeyCapView(label: $0) }
                            Text("in any app, talk, then let go.").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                        }
                        Text("Your words are tidied up and typed wherever the cursor is.").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer()
                    Toggle("Dictation", isOn: Binding(get: { enabled }, set: { enabled = $0; apply() })).toggleStyle(.switch).labelsHidden()
                }
                .padding(12)
                RowDivider()
                TextField("Try it here: click, hold the keys and talk", text: $tryItText, axis: .vertical)
                    .lineLimit(2...3).theoField().padding(12)
            }
            TheoSection(title: "Shortcut", hint: globeHint) {
                ChoiceChips(options: DictationShortcut.allCases.map { ($0.rawValue, $0.title, $0.usesFn ? "globe" : "keyboard") },
                            selection: Binding(get: { shortcut }, set: { shortcut = $0; apply() }))
                    .padding(12)
                if DictationController.globeKeyAction != .nothing && picked.usesFn {
                    RowDivider()
                    HStack {
                        Text("Setting “Press 🌐 key to” to Do Nothing avoids any overlap.").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                        Spacer()
                        Button("Open Keyboard Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                        .buttonStyle(.theoSecondary).disabled(TheoProfile.isTest)
                    }
                    .padding(12)
                }
            }
            TheoSection(title: "Hears you with", hint: "Theo always listens on this Mac too, so if Sarvam can't be reached your words still go in.") {
                engineRow(.automatic, logo: "sarvam", symbol: nil, title: "Sarvam, when its key is saved", detail: keys.hasKey(for: "sarvam") ? "Indian languages and Hinglish, key saved" : "Using Apple on this Mac until a key is saved", available: true)
                RowDivider(inset: 54)
                engineRow(.apple, logo: nil, symbol: "apple.logo", title: "Apple, on this Mac", detail: "Private and free, works offline", available: true)
                RowDivider()
                SettingRow(title: "Language", detail: language == "auto" ? "Sarvam works out the language by itself." : nil) {
                    Picker("Language", selection: $language) {
                        ForEach(DictationSettings.languages, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 200)
                }
            }
            TheoSection(title: "Clean-up", hint: "It removes filler words and fixes punctuation and casing, keeping the language as you spoke it. If it's slow, your own words go in first.") {
                SettingRow(title: "Tidy up with Haiku", detail: "Small filler words like “um” always go, even with this off.") {
                    Toggle("Tidy up with Haiku", isOn: $cleanup).toggleStyle(.switch).labelsHidden()
                }
            }
            TheoSection(title: "Your words", hint: "Names and terms it should always get right. To fix something it keeps mishearing, write it as heard = written.") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Sarvam, or theo klicky = Theo Clicky", text: $newWord, onCommit: addWord).theoField()
                        Button("Add", action: addWord).buttonStyle(.theoSecondary).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !lines.isEmpty {
                        FlowChipsPlain(items: lines) { removed in
                            dictionary = lines.filter { $0 != removed }.joined(separator: "\n")
                        }
                    }
                }
                .padding(12)
            }
        }
        .onAppear { apply() }
    }

    private var lines: [String] {
        dictionary.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !lines.contains(word) else { return }
        dictionary = (lines + [word]).joined(separator: "\n")
        newWord = ""
    }

    private func apply() {
        guard let manager else { return }
        manager.dictationController.keys.useCurrentShortcut()
        manager.dictationController.refresh(accessibilityGranted: TheoPermissions.isAccessibilityGranted)
    }

    private var globeHint: String {
        var hint = "Clicky's push-to-talk stays on Control + Option; the two never overlap."
        if picked.usesFn, let sentence = DictationController.globeKeyAction.sentence {
            hint += " " + sentence + " If that pops up when you let go of the keys, turn it off in Keyboard Settings or pick a shortcut without Fn."
        }
        if picked.usesFn { hint += " External keyboards without an Fn key need a shortcut without it." }
        return hint
    }

    private func engineRow(_ value: DictationSettings.Engine, logo: String?, symbol: String?, title: String, detail: String, available: Bool) -> some View {
        Button { engine = value.rawValue } label: {
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
                Image(systemName: engine == value.rawValue ? "checkmark.circle.fill" : "circle").font(.system(size: 16))
                    .foregroundColor(engine == value.rawValue ? DS.Colors.accent : DS.Colors.textDisabled)
            }
            .padding(.horizontal, 12).frame(height: 50).contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(isSelected: false))
    }
}

private struct KeyCapView: View {
    let label: String
    var body: some View {
        Text(label).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(DS.Colors.hover))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
    }
}

/// Removable chips, wrapped onto rows.
private struct FlowChipsPlain: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 5) {
                    Text(item).font(TheoType.caption).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    Button { onRemove(item) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain).help("Remove")
                }
                .padding(.horizontal, 9).frame(height: 24)
                .background(Capsule().fill(DS.Colors.hover))
            }
        }
    }
}
