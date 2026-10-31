//
//  HarnessViews.swift
//  leanring-buddy
//
//  Choosing harnesses: the list of CLIs on this Mac with whether each is
//  signed in, the default one and its model and effort, and where coding
//  runs go. Used by Settings › Coding and the first-run setup.
//

import AppKit
import SwiftUI

/// One harness as a selectable row: name, account or why it isn't ready, and a check when chosen.
struct HarnessRow: View {
    let info: HarnessInfo
    let status: HarnessStatus
    let isSelected: Bool
    var isChecking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.surface)
                    .overlay(Image(systemName: Self.symbol(info.id)).font(.system(size: 14, weight: .medium)).foregroundColor(DS.Colors.textSecondary))
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.label).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
                Spacer()
                Circle().fill(dot).frame(width: 7, height: 7)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundColor(isSelected ? DS.Colors.accent : DS.Colors.textDisabled)
            }
            .padding(.horizontal, 12).frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(isSelected: isSelected))
        .disabled(!status.installed && !isChecking)
        .opacity(status.installed || isChecking ? 1 : 0.55)
    }

    private var subtitle: String {
        if isChecking { return "Checking…" }
        if !status.installed { return "Not installed" }
        if status.loggedIn == false { return "Not signed in · \(Self.signIn(info.id))" }
        return status.account ?? status.detail ?? "Ready"
    }

    private var dot: Color {
        if !status.installed { return DS.Colors.textDisabled }
        return status.loggedIn == false ? DS.Colors.warning : DS.Colors.success
    }

    static func symbol(_ id: String) -> String {
        ["t3": "macwindow", "claude": "sparkle", "codex": "chevron.left.forwardslash.chevron.right", "cursor": "cursorarrow",
         "opencode": "curlybraces", "grok": "bolt", "gemini": "diamond"][id] ?? "terminal"
    }

    /// How to sign in, said plainly (run in Terminal).
    static func signIn(_ id: String) -> String {
        ["claude": "run claude, then /login", "codex": "run codex login", "cursor": "run cursor-agent login",
         "grok": "run grok login", "gemini": "run gemini"][id] ?? "sign in from Terminal"
    }
}

/// A model and effort picker for one harness, from its live catalogue (free text when it has none).
struct HarnessModelPicker: View {
    @ObservedObject var center = HarnessCenter.shared
    let harness: String
    @Binding var model: String
    @Binding var effort: String

    var body: some View {
        let models = center.models(for: harness)
        HStack(spacing: 10) {
            if models.isEmpty {
                TextField(harness == "t3" ? "T3 Code's default model" : "Model id", text: $model)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            } else {
                Picker("Model", selection: $model) {
                    if !models.contains(where: { $0.id == model }) { Text(model.isEmpty ? "Default" : model).tag(model) }
                    ForEach(models) { item in Text(item.label).tag(item.id) }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
            let efforts = center.efforts(for: harness, model: model)
            if !efforts.isEmpty {
                Picker("Effort", selection: $effort) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden().frame(width: 120)
            }
        }
    }
}

/// Settings › Coding: the harnesses on this Mac, the default for new bots, and where builds go.
struct CodingSettingsView: View {
    @ObservedObject private var center = HarnessCenter.shared
    @State private var botModel = ""
    @State private var botEffort = ""
    @State private var codingModel = ""
    @State private var codingEffort = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("Builds go to", "When a bot writes a build prompt, this is where it's coded. T3 Code tracks it in its own app; any other harness runs in a live terminal inside Theo.") {
                VStack(spacing: 0) {
                    ForEach(HarnessCatalog.codingTargets, id: \.id) { info in
                        HarnessRow(info: info, status: center.status(for: info.id), isSelected: center.codingTarget == info.id,
                                   isChecking: center.statuses[info.id] == nil) {
                            center.codingTarget = info.id
                            codingModel = center.codingModel ?? ""
                        }
                    }
                }
                HStack {
                    Text("Model").font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).frame(width: 60, alignment: .leading)
                    HarnessModelPicker(harness: center.codingTarget, model: $codingModel, effort: $codingEffort)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .onChange(of: codingModel) { _, value in center.codingModel = value.isEmpty ? nil : value }
                .onChange(of: codingEffort) { _, value in center.codingEffort = value.isEmpty ? nil : value }
            }
            group("New bots run on", "The default for bots you create. Each bot can use any harness in its own settings.") {
                VStack(spacing: 0) {
                    ForEach(HarnessCatalog.botEngines, id: \.id) { info in
                        HarnessRow(info: info, status: center.status(for: info.id), isSelected: center.defaultHarness == info.id,
                                   isChecking: center.statuses[info.id] == nil) {
                            center.defaultHarness = info.id
                            botModel = center.defaultModel(for: info.id) ?? ""
                            botEffort = center.defaultEffort(for: info.id) ?? ""
                        }
                    }
                }
                HStack {
                    Text("Model").font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).frame(width: 60, alignment: .leading)
                    HarnessModelPicker(harness: center.defaultHarness, model: $botModel, effort: $botEffort)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .onChange(of: botModel) { _, value in center.setDefaultModel(value.isEmpty ? nil : value, for: center.defaultHarness) }
                .onChange(of: botEffort) { _, value in center.setDefaultEffort(value.isEmpty ? nil : value, for: center.defaultHarness) }
            }
            HStack {
                Button { center.refresh(force: true) } label: {
                    Label(center.isRefreshing ? "Checking…" : "Check again", systemImage: "arrow.clockwise")
                }
                .disabled(center.isRefreshing)
                Spacer()
            }
            if center.codingTarget == "t3" { T3ConnectView() }
        }
        .onAppear {
            center.refresh()
            codingModel = center.codingModel ?? ""
            codingEffort = center.codingEffort ?? ""
            botModel = center.defaultModel(for: center.defaultHarness) ?? ""
            botEffort = center.defaultEffort(for: center.defaultHarness) ?? ""
        }
    }

    private func group<Content: View>(_ title: String, _ hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            Text(hint).font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
