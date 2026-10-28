//
//  DiagnosticsPanelView.swift
//  leanring-buddy
//
//  The Diagnostics window body: status sections, self-test buttons, and the
//  v2 settings list (one row per ClickySettingsCatalog entry). It only shows
//  the snapshot it is given and calls the closures in `actions`, so the
//  offscreen render (fake snapshot, inert actions) and the live window use
//  the same view. The window wraps it in a ScrollView.
//

import ClickyCore
import SwiftUI

/// What the buttons do. The window controller supplies the real ones.
struct DiagnosticsActions {
    let checkClaude: () -> Void
    let checkGitHub: () -> Void
    let runSelfTest: (String) -> Void

    static let inert = DiagnosticsActions(checkClaude: {}, checkGitHub: {}, runSelfTest: { _ in })
}

struct DiagnosticsPanelView: View {
    let snapshot: DiagnosticsSnapshot
    let actions: DiagnosticsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Diagnostics")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Status is read only. Nothing is requested or run until you press a button.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            statusSection(title: "Permissions", lines: snapshot.permissionLines)
            statusSection(title: "Claude", lines: snapshot.claudeAuthLines, buttonTitle: "Check Claude", buttonAction: actions.checkClaude)
            statusSection(title: "Code mode", lines: snapshot.codeLines)
            statusSection(title: "GitHub", lines: snapshot.githubLines, buttonTitle: "Check GitHub", buttonAction: actions.checkGitHub)
            statusSection(title: "Voice (TTS)", lines: snapshot.voiceLines)
            statusSection(title: "Wake word", lines: snapshot.wakeLines)
            statusSection(title: "LaunchAgent", lines: snapshot.launchAgentLines)
            selfTestSection
            settingsSection
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
        .background(DS.Colors.background)
    }

    // MARK: - Status sections

    private func statusSection(title: String, lines: [DiagnosticsStatusLine], buttonTitle: String? = nil, buttonAction: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle(title)
                Spacer()
                if let buttonTitle, let buttonAction {
                    textButton(buttonTitle, action: buttonAction)
                }
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(color(for: line.level))
                        .frame(width: 7, height: 7)
                    Text(line.label)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 170, alignment: .leading)
                    Text(line.value)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func color(for level: DiagnosticsStatusLine.Level) -> Color {
        switch level {
        case .good: return DS.Colors.success
        case .problem: return DS.Colors.warning
        case .unknown: return DS.Colors.textTertiary
        }
    }

    // MARK: - Self-tests

    private var selfTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Self-tests")
            Text("Each Run calls the same function as the debug inbox's selftest command.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            ForEach(DiagnosticsSelfTestCatalog.names, id: \.self) { selfTestName in
                HStack(spacing: 8) {
                    Text(selfTestName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 170, alignment: .leading)
                    Text(selfTestResultText(for: selfTestName))
                        .font(.system(size: 11))
                        .foregroundColor(selfTestResultColor(for: selfTestName))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    textButton("Run") { actions.runSelfTest(selfTestName) }
                }
            }
        }
    }

    private func selfTestResultText(for selfTestName: String) -> String {
        guard let result = snapshot.selfTestResults[selfTestName] else { return "Not run" }
        return result.isPassing ? "Passed. \(result.summary)" : "Failed. \(result.summary)"
    }

    private func selfTestResultColor(for selfTestName: String) -> Color {
        guard let result = snapshot.selfTestResults[selfTestName] else { return DS.Colors.textTertiary }
        return result.isPassing ? DS.Colors.success : DS.Colors.destructiveText
    }

    // MARK: - Settings

    /// One group per `v2.<section>` word, then the reused pre-v2 keys.
    private var settingsSection: some View {
        let sectionNames = Array(Set(ClickySettingsCatalog.entries.map(\.sectionName))).sorted()
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Settings (v2)")
            ForEach(sectionNames, id: \.self) { sectionName in
                VStack(alignment: .leading, spacing: 10) {
                    Text(sectionName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    ForEach(ClickySettingsCatalog.entries.filter { $0.sectionName == sectionName }, id: \.key) { entry in
                        settingRow(for: entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settingRow(for entry: ClickySettingsEntry) -> some View {
        switch entry.kind {
        case .toggle(let defaultValue):
            ToggleSettingRow(entry: entry, defaultValue: defaultValue)
        case .choice(let options, let defaultValue):
            ChoiceSettingRow(entry: entry, options: options, defaultValue: defaultValue)
        case .integer(let defaultValue, let range, let step):
            IntegerSettingRow(entry: entry, defaultValue: defaultValue, range: range, step: step)
        case .number(let defaultValue, let range, let step):
            NumberSettingRow(entry: entry, defaultValue: defaultValue, range: range, step: step)
        case .text(let defaultValue):
            TextSettingRow(entry: entry, defaultValue: defaultValue)
        case .textList(let defaultValue):
            TextListSettingRow(entry: entry, defaultValue: defaultValue)
        case .internalData:
            SettingRowChrome(entry: entry) {
                Text("Written by Claudia")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    // MARK: - Small helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.surface3)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Setting rows

/// The key, the control on the right, and the explanation under them.
private struct SettingRowChrome<Control: View>: View {
    let entry: ClickySettingsEntry
    let control: Control

    init(entry: ClickySettingsEntry, @ViewBuilder control: () -> Control) {
        self.entry = entry
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(entry.key)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                control
            }
            Text(entry.explanation)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Each row reads and writes its key through @AppStorage, the same UserDefaults entry ClickySettings reads.
private struct ToggleSettingRow: View {
    let entry: ClickySettingsEntry
    @AppStorage private var isOn: Bool

    init(entry: ClickySettingsEntry, defaultValue: Bool) {
        self.entry = entry
        _isOn = AppStorage(wrappedValue: defaultValue, entry.key)
    }

    var body: some View {
        SettingRowChrome(entry: entry) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .pointerCursor()
        }
    }
}

private struct ChoiceSettingRow: View {
    let entry: ClickySettingsEntry
    let options: [String]
    @AppStorage private var choice: String

    init(entry: ClickySettingsEntry, options: [String], defaultValue: String) {
        self.entry = entry
        self.options = options
        _choice = AppStorage(wrappedValue: defaultValue, entry.key)
    }

    var body: some View {
        SettingRowChrome(entry: entry) {
            Picker("", selection: $choice) {
                ForEach(options, id: \.self) { option in
                    Text(option.isEmpty ? "None" : option).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }
}

private struct IntegerSettingRow: View {
    let entry: ClickySettingsEntry
    let range: ClosedRange<Int>
    let step: Int
    @AppStorage private var value: Int

    init(entry: ClickySettingsEntry, defaultValue: Int, range: ClosedRange<Int>, step: Int) {
        self.entry = entry
        self.range = range
        self.step = step
        _value = AppStorage(wrappedValue: defaultValue, entry.key)
    }

    var body: some View {
        SettingRowChrome(entry: entry) {
            Stepper(value: $value, in: range, step: step) {
                Text("\(value)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .fixedSize()
        }
    }
}

private struct NumberSettingRow: View {
    let entry: ClickySettingsEntry
    let range: ClosedRange<Double>
    let step: Double
    @AppStorage private var value: Double

    init(entry: ClickySettingsEntry, defaultValue: Double, range: ClosedRange<Double>, step: Double) {
        self.entry = entry
        self.range = range
        self.step = step
        _value = AppStorage(wrappedValue: defaultValue, entry.key)
    }

    var body: some View {
        SettingRowChrome(entry: entry) {
            Stepper(value: $value, in: range, step: step) {
                Text(String(format: "%g", value))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .fixedSize()
        }
    }
}

private struct TextSettingRow: View {
    let entry: ClickySettingsEntry
    @AppStorage private var text: String

    init(entry: ClickySettingsEntry, defaultValue: String) {
        self.entry = entry
        _text = AppStorage(wrappedValue: defaultValue, entry.key)
    }

    var body: some View {
        SettingRowChrome(entry: entry) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
    }
}

/// Arrays are not an @AppStorage type, so this row reads and writes the UserDefaults array itself.
/// Comma separated; an empty list removes the key so ClickySettings uses its default again.
private struct TextListSettingRow: View {
    let entry: ClickySettingsEntry
    @State private var draftText: String

    init(entry: ClickySettingsEntry, defaultValue: [String]) {
        self.entry = entry
        let storedValues = UserDefaults.standard.stringArray(forKey: entry.key) ?? defaultValue
        _draftText = State(initialValue: storedValues.joined(separator: ", "))
    }

    var body: some View {
        SettingRowChrome(entry: entry) {
            TextField("", text: Binding(
                get: { draftText },
                set: { newText in
                    draftText = newText
                    saveDraft(newText)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
        }
    }

    private func saveDraft(_ text: String) {
        let values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: entry.key)
        } else {
            UserDefaults.standard.set(values, forKey: entry.key)
        }
    }
}
