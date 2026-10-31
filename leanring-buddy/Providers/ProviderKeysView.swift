//
//  ProviderKeysView.swift
//  leanring-buddy
//
//  Settings sections: API keys (Keychain) and the Sarvam voice options.
//  Place `ProviderKeysView()` and `SarvamVoiceSettings()` in Settings.
//

import SwiftUI

struct ProviderKeysView: View {
    @ObservedObject private var keys = ProviderKeys.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API keys")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Stored in your Mac's Keychain. Never logged or synced.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            VStack(spacing: 0) {
                ForEach(Array(keys.providers.enumerated()), id: \.element.id) { index, provider in
                    ProviderKeyRow(provider: provider)
                    if index < keys.providers.count - 1 {
                        Divider().overlay(DS.Colors.borderSubtle)
                    }
                }
            }
            .background(DS.Colors.surface1)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
            .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        }
    }
}

private struct ProviderKeyRow: View {
    let provider: ProviderInfo
    @ObservedObject private var keys = ProviderKeys.shared
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(provider.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                if let masked = keys.maskedPreview(for: provider.id) {
                    Text(masked)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                statusLabel
                Link("Get a key", destination: provider.consoleURL)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accentText)
            }
            HStack(spacing: 6) {
                SecureField(keys.hasKey(for: provider.id) ? "Replace key" : provider.keyHint, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(DS.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small))
                Button("Save") {
                    keys.save(draft, for: provider.id)
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Test") { Task { await keys.test(provider.id) } }
                    .disabled(!keys.hasKey(for: provider.id) || keys.testingIDs.contains(provider.id))
                Button("Remove") { keys.remove(provider.id) }
                    .disabled(!keys.hasKey(for: provider.id))
            }
            .font(.system(size: 11))
        }
        .padding(10)
    }

    @ViewBuilder private var statusLabel: some View {
        if keys.testingIDs.contains(provider.id) {
            Text("Testing…").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
        } else if let result = keys.testResults[provider.id] {
            Text(result.isOK ? "✓ Works" : result.message)
                .font(.system(size: 11))
                .foregroundColor(result.isOK ? DS.Colors.success : DS.Colors.destructiveText)
                .lineLimit(1)
        } else if keys.hasKey(for: provider.id) {
            Text("Saved").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
        }
    }
}

struct SarvamVoiceSettings: View {
    @AppStorage(SarvamVoiceSettings_Keys.engine) private var engine = ""
    @AppStorage(SarvamVoiceSettings_Keys.model) private var model = "bulbul:v4-flash"
    @AppStorage(SarvamVoiceSettings_Keys.speaker) private var speaker = "shubh"
    @AppStorage(SarvamVoiceSettings_Keys.language) private var language = "hi-IN"
    @AppStorage(SarvamVoiceSettings_Keys.pace) private var pace = 1.0
    @ObservedObject private var keys = ProviderKeys.shared

    private var isV4: Bool { model.hasPrefix("bulbul:v4") }
    private var speakerOptions: [String] {
        isV4 ? SarvamClient.v4SpeakerCatalog.flatMap(\.speakers) : SarvamClient.v3Speakers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sarvam voice")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Toggle("Speak with Sarvam Bulbul", isOn: Binding(
                get: { engine == "sarvam" },
                set: { engine = $0 ? "sarvam" : "" }
            ))
            if engine == "sarvam" && !keys.hasKey(for: "sarvam") {
                Text("Add a Sarvam key above; until then Theo uses her current voice.")
                    .font(.system(size: 11)).foregroundColor(DS.Colors.warning)
            }
            Picker("Model", selection: $model) {
                Text("Bulbul v4 flash").tag("bulbul:v4-flash")
                Text("Bulbul v3").tag("bulbul:v3")
            }
            Picker("Language", selection: $language) {
                Text("Hindi (hi-IN)").tag("hi-IN")
                Text("English (en-IN)").tag("en-IN")
                Text("Hinglish").tag("hinglish")
            }
            Picker("Speaker", selection: $speaker) {
                if !speakerOptions.contains(speaker) { Text(speaker).tag(speaker) }
                ForEach(speakerOptions, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Text("Pace").font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                Slider(value: $pace, in: 0.5...2.0, step: 0.05)
                Text(String(format: "%.2fx", pace))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            if isV4 && !speaker.contains("_") {
                Text("v4 uses persona voices; \"\(speaker)\" is mapped to a matching persona for the chosen language.")
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).stroke(DS.Colors.borderSubtle, lineWidth: 1))
    }
}
