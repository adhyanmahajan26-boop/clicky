//
//  HealthSettings.swift
//  leanring-buddy
//
//  Settings › Health and Home's "Finish setting up": the health check (`BotsStore.doctorFindings`, the same one `/doctor`
//  answers in a chat) with a button beside every problem, like `hermes doctor` and `openclaw doctor --fix`, but a fix only
//  runs when the owner presses it. Rules and wording: ClickyCore `TheoDoctor`, `TheoDoctorFix`.
//

import AVFoundation
import ClickyCore
import SwiftUI

@MainActor
final class TheoHealth: ObservableObject {
    static let shared = TheoHealth()

    @Published private(set) var findings: [TheoDoctorFinding] = []
    @Published private(set) var lastChecked: Date?
    /// The fix that's running (a sign-in waits for the browser), by its wire word.
    @Published private(set) var running: String?
    /// What the last fix said, for the line under the list.
    @Published private(set) var lastFixNote: String?

    /// What's left to set up, for Home's card.
    var leftToSetUp: [TheoDoctorFinding] { TheoDoctor.leftToSetUp(findings) }

    /// Reads everything again. Apps are checked against what the Connectors page last saw, so this never contacts an app.
    func refresh() {
        findings = BotsStore.shared.doctorFindings()
        lastChecked = Date()
    }

    /// Refreshes when the last look is over a minute old (Home and the Health page call this as they appear).
    func refreshIfStale() {
        guard lastChecked.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        refresh()
    }

    /// One fix, pressed by the owner. A test profile records what it would do instead of asking macOS or opening a browser.
    func perform(_ fix: TheoDoctorFix) {
        if TheoProfile.isTest {
            TheoOpen.record("health fix \(fix.wire)")
            lastFixNote = "Recorded \(fix.wire)."
            return
        }
        switch fix {
        case .openSettings(let sectionID):
            BotsSelection.shared.openSettings(SettingsTab.Section(rawValue: sectionID) ?? .health)
        case .askPermission(let kind):
            switch kind {
            case "accessibility": _ = TheoPermissions.askForAccessibility()
            case "screenRecording": _ = TheoPermissions.askForScreenRecording()
            case "microphone":
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in TheoHealth.shared.refresh() } }
                } else {
                    TheoPermissions.openSettingsPane("Privacy_Microphone")
                }
            default: BotsSelection.shared.openSettings(.permissions)
            }
            // macOS answers in its own window: look again shortly after.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.refresh()
            }
        case .signInApp(let appID):
            running = fix.wire
            Task { @MainActor in
                defer { self.running = nil }
                do {
                    let status = try await ConnectorHub.signIn(appID) { url in TheoOpen.url(url) }
                    self.lastFixNote = status == "connected" ? "Signed in." : "Not connected yet (\(status)). Try again, or open Connectors."
                } catch {
                    self.lastFixNote = error.localizedDescription
                }
                await ConnectorHealth.shared.refresh()
                self.refresh()
            }
        case .openConnectors:
            BotsSelection.shared.pane = .connectors
        case .installUpdate:
            CompanionManager.current?.updateController.installAvailableUpdate()
        }
    }
}

/// Settings › Health.
struct HealthSettingsContent: View {
    @ObservedObject private var health = TheoHealth.shared

    var body: some View {
        let sorted = Self.worstFirst(health.findings)
        let left = health.leftToSetUp.count
        TheoSection(title: "", hint: footer) {
            SettingRow(title: left == 0 ? "Everything is set up" : TheoDoctor.leftToSetUpTitle(count: left),
                       detail: "The same check runs when you type /doctor in any chat.") {
                Button("Check again") {
                    Task { @MainActor in
                        await ConnectorHealth.shared.refresh()
                        health.refresh()
                    }
                }
                .buttonStyle(.theo(.secondary, .small))
            }
            ForEach(Array(sorted.enumerated()), id: \.offset) { _, finding in
                RowDivider()
                HealthFindingRow(finding: finding)
            }
        }
        .onAppear { health.refresh() }
    }

    private var footer: String? {
        if let note = health.lastFixNote { return note }
        return health.lastChecked.map { "Checked \($0.formatted(date: .omitted, time: .shortened)). Fixes only run when you press them." }
    }

    static func worstFirst(_ findings: [TheoDoctorFinding]) -> [TheoDoctorFinding] {
        let order: [TheoDoctorFinding.Level: Int] = [.fail: 0, .warn: 1, .ok: 2]
        return findings.enumerated().sorted { (order[$0.element.level]!, $0.offset) < (order[$1.element.level]!, $1.offset) }.map(\.element)
    }
}

/// One finding: its pill, what it is, what's wrong, and its button.
struct HealthFindingRow: View {
    let finding: TheoDoctorFinding
    @ObservedObject private var health = TheoHealth.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusPill(text: pillWord, tone: pillTone).frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.check).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                Text(finding.detail).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let fix = finding.fix {
                Button(health.running == fix.wire ? "Waiting…" : fix.buttonTitle) { health.perform(fix) }
                    .buttonStyle(.theo(finding.level == .fail ? .primary : .secondary, .small))
                    .disabled(health.running == fix.wire)
                    .pointerCursor()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var pillWord: String {
        switch finding.level {
        case .ok: return "OK"
        case .warn: return "Check"
        case .fail: return "Needs you"
        }
    }

    private var pillTone: StatusPill.Tone {
        switch finding.level {
        case .ok: return .good
        case .warn: return .warn
        case .fail: return .bad
        }
    }
}

/// Home's card while anything is left to set up: the first three, each with its button, and the way to the rest.
struct FinishSetupCard: View {
    @ObservedObject private var health = TheoHealth.shared
    @ObservedObject var selection: BotsSelection

    var body: some View {
        let left = health.leftToSetUp
        if !left.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Finish setting up").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                    Text(TheoDoctor.leftToSetUpTitle(count: left.count)).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    Button("See all") { selection.openSettings(.health) }.buttonStyle(.theo(.secondary, .small)).pointerCursor()
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(left.prefix(3).enumerated()), id: \.offset) { index, finding in
                        if index > 0 { RowDivider() }
                        HealthFindingRow(finding: finding)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
