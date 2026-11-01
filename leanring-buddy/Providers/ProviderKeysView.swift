//
//  ProviderKeysView.swift
//  leanring-buddy
//
//  Settings › Models & API keys: every provider as a row with its logo. A row opens to a paste field (⌘V or the
//  Paste button), Test (a real call, with the model count or the provider's own error), Save to the Keychain, Remove
//  and "Get a key". Used by Settings and the first-run setup.
//

import AppKit
import SwiftUI

struct ProviderKeysView: View {
    @ObservedObject private var keys = ProviderKeys.shared
    @State private var openID: String?
    @State private var addingCustom = false

    var body: some View {
        // `revision` is read so the custom list redraws when one is added or removed.
        let providers = keys.revision >= 0 ? keys.providers : []
        VStack(alignment: .leading, spacing: 22) {
            summary
            group("AI models", hint: "A saved key adds that provider's models to every engine picker: bots, Theo and Clicky.", providers.filter { $0.group == .models })
            group("Voice and listening", hint: "Pick which one speaks and listens in Settings › Voice.", providers.filter { $0.group == .voice })
            group("On this Mac", hint: "Local servers need no key. Test finds out whether they're running.", providers.filter { $0.group == .local })
            VStack(alignment: .leading, spacing: 8) {
                let custom = providers.filter { $0.group == .custom }
                if !custom.isEmpty { group("Custom", hint: nil, custom) }
                Button { addingCustom = true } label: { Label("Add a custom OpenAI-compatible provider", systemImage: "plus") }
                    .buttonStyle(.theoSecondary)
            }
        }
        .sheet(isPresented: $addingCustom) { CustomProviderSheet { added in
            addingCustom = false
            if let added { openID = added.id }
        } }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
            Text("Keys stay in your Mac's Keychain. They're never logged, synced or sent anywhere but that provider.")
                .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
        }
    }

    private func group(_ title: String, hint: String?, _ providers: [ProviderInfo]) -> some View {
        TheoSection(title: title, hint: hint) {
            ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                if index > 0 { RowDivider(inset: 54) }
                ProviderKeyRow(provider: provider, isOpen: openID == provider.id) {
                    withAnimation(DS.Motion.hover) { openID = openID == provider.id ? nil : provider.id }
                }
            }
        }
    }
}

private struct ProviderKeyRow: View {
    let provider: ProviderInfo
    let isOpen: Bool
    let toggle: () -> Void
    @ObservedObject private var keys = ProviderKeys.shared
    @State private var draft = ""
    @State private var reveals = false
    @State private var baseURL = ""
    @State private var confirmsRemove = false
    @FocusState private var fieldFocused: Bool

    private var hasKey: Bool { keys.hasKey(for: provider.id) }
    private var result: ProviderKeys.TestResult? { keys.testResults[provider.id] }
    private var isTesting: Bool { keys.testingIDs.contains(provider.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    BrandLogo(id: provider.id, name: provider.label, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.label).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                        Text(subtitle).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    status
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 12).frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle(isSelected: false))
            if isOpen { editor.padding(.leading, 54).padding(.trailing, 14).padding(.bottom, 14).padding(.top, 2) }
        }
        .onAppear { baseURL = provider.baseURL }
        .alert("Remove the \(provider.label) key?", isPresented: $confirmsRemove) {
            Button("Remove", role: .destructive) {
                if provider.group == .custom { keys.deleteCustom(provider.id) } else { keys.remove(provider.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything set to run on it stops until you add a key again.")
        }
    }

    private var subtitle: String {
        if let mask = keys.maskedPreview(for: provider.id) { return mask }
        return provider.blurb
    }

    @ViewBuilder private var status: some View {
        if isTesting {
            StatusPill(text: "Testing", tone: .neutral, busy: true)
        } else if let result {
            StatusPill(text: result.isOK ? result.message : "Failed", tone: result.isOK ? .good : .bad)
        } else if hasKey {
            StatusPill(text: "Saved", tone: .good)
        } else if provider.keyless {
            StatusPill(text: "Local", tone: .neutral)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if provider.keyless || provider.group == .custom {
                HStack(spacing: 8) {
                    Text("Address").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).frame(width: 52, alignment: .leading)
                    TextField("http://localhost:1234/v1", text: $baseURL).theoField().onSubmit(saveBaseURL)
                }
            }
            if !provider.keyless {
                HStack(spacing: 8) {
                    Group {
                        if reveals {
                            TextField(hasKey ? "Paste a new key to replace it" : provider.keyHint, text: $draft)
                        } else {
                            SecureField(hasKey ? "Paste a new key to replace it" : provider.keyHint, text: $draft)
                        }
                    }
                    .focused($fieldFocused)
                    .theoField(focused: fieldFocused)
                    .font(TheoType.mono)
                    .onSubmit(save)
                    Button { reveals.toggle() } label: { Image(systemName: reveals ? "eye.slash" : "eye").frame(width: 16) }
                        .buttonStyle(.theoGhost).help(reveals ? "Hide what you typed" : "Show what you typed")
                    Button("Paste") {
                        draft = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .buttonStyle(.theoSecondary)
                }
            }
            HStack(spacing: 8) {
                if !provider.keyless {
                    Button("Save", action: save).buttonStyle(.theoPrimary).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button(isTesting ? "Testing…" : "Test") { saveBaseURL(); Task { await keys.test(provider.id, draft: draft) } }
                    .buttonStyle(.theoSecondary)
                    .disabled(isTesting || (!provider.keyless && provider.group != .custom && !hasKey && draft.isEmpty))
                if hasKey || provider.group == .custom {
                    Button(provider.group == .custom ? "Delete" : "Remove") { confirmsRemove = true }.buttonStyle(.theoDestructive)
                }
                Spacer()
                if let console = provider.consoleURL.flatMap(URL.init(string:)) {
                    Link(destination: console) {
                        HStack(spacing: 3) {
                            Text(provider.keyless ? "Get \(provider.label)" : "Get a key")
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(TheoType.caption).foregroundColor(DS.Colors.accentText)
                    }
                }
            }
            if let result, !result.isOK {
                Text(result.message).font(TheoType.caption).foregroundColor(DS.Colors.destructiveText).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if let result, result.isOK {
                Text(result.message).font(TheoType.caption).foregroundColor(DS.Colors.success)
            }
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keys.save(trimmed, for: provider.id)
        draft = ""
        reveals = false
        Task { await keys.test(provider.id) }
    }

    private func saveBaseURL() {
        guard provider.keyless || provider.group == .custom else { return }
        var address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while address.hasSuffix("/") { address.removeLast() }
        guard !address.isEmpty, address != provider.baseURL else { return }
        if provider.group == .custom {
            var all = CustomProviders.all
            if let index = all.firstIndex(where: { $0.id == provider.id }) {
                all[index].baseURL = address
                all[index].blurb = address
                CustomProviders.all = all
            }
        } else {
            ProviderOverrides.setBaseURL(address, for: provider.id)
        }
    }
}

/// Name, base address and key for an OpenAI-compatible service Theo doesn't list.
struct CustomProviderSheet: View {
    let onDone: (ProviderInfo?) -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a provider").font(TheoType.title).foregroundColor(DS.Colors.textPrimary)
            Text("Any service that speaks the OpenAI chat API: a company gateway, vLLM, a tunnel to another Mac.")
                .font(TheoType.body).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            field("Name") { TextField("My gateway", text: $name).theoField() }
            field("Base URL") { TextField("https://example.com/v1", text: $address).theoField() }
            field("API key") { SecureField("Leave empty if it needs no key", text: $key).theoField() }
            if let problem { Text(problem).font(TheoType.caption).foregroundColor(DS.Colors.destructiveText) }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.buttonStyle(.theoGhost).keyboardShortcut(.cancelAction)
                Button("Add provider", action: add).buttonStyle(.theoPrimary).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(DS.Colors.surface)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(TheoType.label).foregroundColor(DS.Colors.textTertiary)
            content()
        }
    }

    private func add() {
        guard let provider = CustomProviders.make(name: name, baseURL: address) else {
            problem = "That doesn't look like a web address. It should start with http:// or https://."
            return
        }
        let keys = ProviderKeys.shared
        keys.addCustom(provider)
        if !key.isEmpty { keys.save(key, for: provider.id) }
        onDone(provider)
        Task { await keys.test(provider.id) }
    }
}
