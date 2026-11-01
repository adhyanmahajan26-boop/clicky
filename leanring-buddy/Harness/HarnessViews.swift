//
//  HarnessViews.swift
//  leanring-buddy
//
//  Settings › Harnesses and the first-run setup: one card per coding harness with its logo, whether it's installed
//  and signed in (and as whom), and working buttons: Install and Sign in run inside Theo's own terminal and the card
//  flips by itself when the check passes, Re-check, Sign out, and "use my API key". Above the cards, where builds go
//  and what new bots run on.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

/// Settings › Harnesses.
struct CodingSettingsView: View {
    @ObservedObject private var center = HarnessCenter.shared
    @State private var terminalTask: HarnessTerminalTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "Defaults", hint: "T3 Code tracks a build in its own app. Any other harness runs in a live terminal inside Theo. Every bot can pick its own engine in its settings.") {
                defaultRow(title: "Builds go to", harnesses: HarnessCatalog.codingTargets, selection: Binding(get: { center.codingTarget }, set: { center.codingTarget = $0 }),
                           model: Binding(get: { center.codingModel ?? "" }, set: { center.codingModel = $0.isEmpty ? nil : $0 }),
                           effort: Binding(get: { center.codingEffort ?? "" }, set: { center.codingEffort = $0.isEmpty ? nil : $0 }))
                RowDivider()
                defaultRow(title: "New bots run on", harnesses: HarnessCatalog.botEngines, selection: Binding(get: { center.defaultHarness }, set: { center.defaultHarness = $0 }),
                           model: Binding(get: { center.defaultModel(for: center.defaultHarness) ?? "" }, set: { center.setDefaultModel($0.isEmpty ? nil : $0, for: center.defaultHarness) }),
                           effort: Binding(get: { center.defaultEffort(for: center.defaultHarness) ?? "" }, set: { center.setDefaultEffort($0.isEmpty ? nil : $0, for: center.defaultHarness) }))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Harnesses").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Button { center.refresh(force: true) } label: {
                        Label(center.isRefreshing ? "Checking…" : "Re-check all", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.theo(.ghost, .small)).disabled(center.isRefreshing)
                }
                ForEach(HarnessCatalog.all, id: \.id) { info in
                    HarnessCard(info: info, openTerminal: { terminalTask = $0 })
                }
            }
        }
        .onAppear { center.refresh() }
        .sheet(item: $terminalTask) { task in
            HarnessTerminalSheet(task: task) { terminalTask = nil }
        }
    }

    private func defaultRow(title: String, harnesses: [HarnessInfo], selection: Binding<String>, model: Binding<String>, effort: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(TheoType.body).foregroundColor(DS.Colors.textPrimary).frame(width: 110, alignment: .leading)
            Picker(title, selection: selection) {
                ForEach(harnesses, id: \.id) { info in
                    let status = center.status(for: info.id)
                    Text(info.label + (center.statuses[info.id] == nil ? "" : status.installed ? (status.loggedIn == false ? " (not signed in)" : "") : " (not installed)")).tag(info.id)
                }
            }
            .labelsHidden().frame(width: 200)
            HarnessModelPicker(harness: selection.wrappedValue, model: model, effort: effort)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
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
        HStack(spacing: 8) {
            if models.isEmpty {
                TextField(harness == "t3" ? "T3 Code's default model" : "Default model", text: $model).theoField().frame(maxWidth: 200)
            } else {
                Picker("Model", selection: $model) {
                    if !models.contains(where: { $0.id == model }) { Text(model.isEmpty ? "Default model" : model).tag(model) }
                    ForEach(models) { item in Text(item.label).tag(item.id) }
                }
                .labelsHidden().frame(maxWidth: 200)
            }
            let efforts = center.efforts(for: harness, model: model)
            if !efforts.isEmpty {
                Picker("Effort", selection: $effort) {
                    Text("Default effort").tag("")
                    ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden().frame(width: 124)
            }
        }
    }
}

/// One harness: its logo, state and the buttons that move it along.
struct HarnessCard: View {
    let info: HarnessInfo
    let openTerminal: (HarnessTerminalTask) -> Void
    @ObservedObject private var center = HarnessCenter.shared
    @ObservedObject private var keys = ProviderKeys.shared
    @State private var confirmsSignOut = false
    @State private var showsConnect = false

    private var status: HarnessStatus { center.status(for: info.id) }
    private var isChecking: Bool { center.statuses[info.id] == nil || center.checking.contains(info.id) }
    private var setup: HarnessCatalog.Setup? { HarnessCatalog.setups[info.id] }
    private var keyProvider: ProviderInfo? { setup?.keyProvider.flatMap { ProviderInfo.info(for: $0) } }
    private var usesKey: Bool { center.usesAPIKey(info.id) }
    private var isSignedIn: Bool { status.installed && status.loggedIn == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandLogo(id: info.id, name: info.label, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(info.label).font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        if let version = status.version { Text(version).font(TheoType.micro).foregroundColor(DS.Colors.textTertiary) }
                    }
                    Text(subtitle).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                pill
                Button { center.recheck(info.id) } label: { Image(systemName: "arrow.clockwise").frame(width: 14) }
                    .buttonStyle(.theo(.ghost, .small)).help("Re-check \(info.label)").disabled(isChecking)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            RowDivider()
            actions.padding(.horizontal, 14).padding(.vertical, 10)
            if info.id == "t3" && (showsConnect || !status.installed) { t3Details.padding(.horizontal, 14).padding(.bottom, 14) }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        .alert("Sign out of \(info.label)?", isPresented: $confirmsSignOut) {
            Button("Sign out", role: .destructive) { openTerminal(.signOut(info)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bots and builds on \(info.label) stop working until you sign in again.")
        }
    }

    private var subtitle: String {
        if isChecking && center.statuses[info.id] == nil { return "Checking…" }
        if !status.installed { return setup?.install ?? "Not installed" }
        if usesKey, let mask = keyProvider.flatMap({ keys.maskedPreview(for: $0.id) }) { return "Running on your \(keyProvider?.label ?? "") API key \(mask)" }
        if info.id == "t3" { return status.account.map { "\($0), with its t3 command" } ?? "The t3 command is here, the app isn't" }
        if status.loggedIn == false { return status.detail ?? setup?.signInHint ?? "Signed out" }
        return status.account ?? status.detail ?? "Ready"
    }

    @ViewBuilder private var pill: some View {
        if isChecking {
            StatusPill(text: "Checking", tone: .neutral, busy: true)
        } else if !status.installed {
            StatusPill(text: "Not installed", tone: .neutral)
        } else if usesKey {
            StatusPill(text: "API key", tone: .info)
        } else if status.loggedIn == false {
            StatusPill(text: "Signed out", tone: .warn)
        } else if status.loggedIn == true {
            StatusPill(text: info.id == "t3" ? "Ready" : "Signed in", tone: .good)
        } else {
            StatusPill(text: "Ready", tone: .good)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if !status.installed && !isChecking {
                Button { openTerminal(.install(info)) } label: { Label("Install", systemImage: "arrow.down.circle") }.buttonStyle(.theoPrimary)
                if let page = setup.flatMap({ URL(string: $0.installPage) }) {
                    Link(destination: page) { Text("Install page") }.buttonStyle(.theoGhost)
                }
            } else if info.id == "t3" {
                Button { showsConnect.toggle() } label: { Label(showsConnect ? "Hide" : "Connect Theo to T3 Code", systemImage: "link") }
                    .buttonStyle(showsConnect ? .theoSecondary : .theoPrimary)
            } else if status.installed {
                if status.loggedIn == true {
                    Button("Sign in again") { openTerminal(.signIn(info)) }.buttonStyle(.theoSecondary)
                    if setup?.signOut != nil { Button("Sign out") { confirmsSignOut = true }.buttonStyle(.theoGhost) }
                } else {
                    Button { openTerminal(.signIn(info)) } label: { Label(info.id == "opencode" ? "Add a provider" : "Sign in", systemImage: "person.crop.circle.badge.checkmark") }
                        .buttonStyle(info.id == "opencode" ? .theoSecondary : .theoPrimary)
                }
            }
            Spacer(minLength: 0)
            apiKeyControl
        }
    }

    @ViewBuilder private var apiKeyControl: some View {
        if status.installed, let keyProvider {
            if keys.hasKey(for: keyProvider.id) {
                Toggle(isOn: Binding(get: { usesKey }, set: { center.setUsesAPIKey($0, for: info.id) })) {
                    Text("Use my \(keyProvider.label) key").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                }
                .toggleStyle(.switch).controlSize(.mini)
            } else {
                Button("Use my API key instead") { TheoSettingsWindowController.show(section: .keys) }.buttonStyle(.theo(.ghost, .small))
            }
        } else if status.installed, info.id == "opencode" {
            Toggle(isOn: Binding(get: { usesKey }, set: { center.setUsesAPIKey($0, for: info.id) })) {
                Text("Pass my saved keys").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
            }
            .toggleStyle(.switch).controlSize(.mini)
        }
    }

    @ViewBuilder private var t3Details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !status.installed {
                Text("No T3 Code on this Mac. Install it above, or send builds to a terminal harness instead.")
                    .font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                if let ready = center.readyHarnesses.first(where: { $0.id != "t3" }) {
                    Button("Send builds to \(ready.label)") { center.codingTarget = ready.id }.buttonStyle(.theoSecondary)
                }
            }
            T3ConnectView()
        }
    }
}

// MARK: - The in-app terminal sheet

/// Something a harness needs done in a terminal: install, sign in or sign out.
struct HarnessTerminalTask: Identifiable {
    enum Kind { case install, signIn, signOut }
    let id = UUID().uuidString
    let kind: Kind
    let info: HarnessInfo

    static func install(_ info: HarnessInfo) -> HarnessTerminalTask { HarnessTerminalTask(kind: .install, info: info) }
    static func signIn(_ info: HarnessInfo) -> HarnessTerminalTask { HarnessTerminalTask(kind: .signIn, info: info) }
    static func signOut(_ info: HarnessInfo) -> HarnessTerminalTask { HarnessTerminalTask(kind: .signOut, info: info) }

    var title: String {
        switch kind {
        case .install: return "Install \(info.label)"
        case .signIn: return "Sign in to \(info.label)"
        case .signOut: return "Sign out of \(info.label)"
        }
    }

    /// The line shown above the terminal, and what the shell runs.
    var commandLine: String {
        let setup = HarnessCatalog.setups[info.id]
        let binary = info.binaries.first ?? info.id
        switch kind {
        case .install: return setup?.install ?? ""
        case .signIn: return ([binary] + (setup?.signIn ?? [])).joined(separator: " ")
        case .signOut: return ([binary] + (setup?.signOut ?? [])).joined(separator: " ")
        }
    }

    /// The command for the shell: the harness by its full path, so a PATH problem can't break it.
    func shellCommand() -> String {
        guard kind != .install, let executable = HarnessCatalog.executable(for: info.id) else { return commandLine }
        let setup = HarnessCatalog.setups[info.id]
        let arguments = kind == .signIn ? setup?.signIn ?? [] : setup?.signOut ?? []
        return ([executable.path] + arguments).map(HarnessCoding.quoted).joined(separator: " ")
    }
}

/// Runs a harness's own command in a real terminal, watches its screen for the sign-in link and any code, and
/// flips to done by itself when the harness says it worked.
@MainActor
final class HarnessTerminalModel: ObservableObject {
    enum Phase: Equatable { case running, succeeded(String), exited(Int32) }
    let task: HarnessTerminalTask
    @Published private(set) var session: TerminalSession?
    @Published private(set) var phase: Phase = .running
    @Published private(set) var link: URL?
    @Published private(set) var code: String?
    @Published private(set) var failedToStart = false
    private var timer: Timer?
    private var probing = false
    private var ticks = 0
    private var wasSignedIn = false

    init(task: HarnessTerminalTask) {
        self.task = task
        wasSignedIn = HarnessCenter.shared.status(for: task.info.id).loggedIn == true
        var environment = TerminalSession.defaultEnvironment()
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
        // A test must not open browser tabs on the owner's screen.
        if TheoProfile.isTest { environment["NO_OPEN_BROWSER"] = "1"; environment["BROWSER"] = "/usr/bin/true" }
        session = TerminalSessions.shared.start(id: "setup:\(task.id)", title: task.title, command: "/bin/zsh",
                                                arguments: ["-lc", task.shellCommand()], environment: environment,
                                                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        failedToStart = session == nil
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let session else { return }
        ticks += 1
        let screen = session.unwrappedScreenText()
        if let found = Self.link(in: screen) { link = found }
        if let found = Self.code(in: screen) { code = found }
        if !session.isRunning, phase == .running {
            phase = .exited(session.exitCode ?? -1)
            HarnessCenter.shared.recheck(task.info.id)
            if task.kind != .signIn { timer?.invalidate() }
        }
        guard task.kind == .signIn || task.kind == .install, ticks % 3 == 0, !probing, phase != .succeeded("") else { return }
        probing = true
        let info = task.info
        let kind = task.kind
        Task.detached(priority: .userInitiated) { [weak self] in
            let status = HarnessDetector.status(for: info.id)
            await MainActor.run {
                guard let self else { return }
                self.probing = false
                self.note(status, kind: kind)
            }
        }
    }

    private func note(_ status: HarnessStatus, kind: HarnessTerminalTask.Kind) {
        let finished: Bool
        switch kind {
        case .install: finished = status.installed
        case .signIn: finished = status.loggedIn == true && (!wasSignedIn || phase == .exited(0))
        case .signOut: finished = false
        }
        guard finished else { return }
        phase = .succeeded(status.account ?? (kind == .install ? "Installed" : "Signed in"))
        HarnessCenter.shared.recheck(task.info.id)
        timer?.invalidate()
        // Gemini CLI's sign-in happens inside its interactive screen, which stays open afterwards.
        if kind == .signIn { session?.terminate() }
    }

    func close() {
        timer?.invalidate()
        TerminalSessions.shared.close("setup:\(task.id)")
        HarnessCenter.shared.recheck(task.info.id)
    }

    /// The first web link on screen.
    static func link(in screen: String) -> URL? {
        guard let range = screen.range(of: #"https?://[^\s"'<>\)\]]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(screen[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;")))
    }

    /// A device code like ABCD-1234, when a CLI shows one.
    static func code(in screen: String) -> String? {
        guard let range = screen.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b"#, options: .regularExpression) else { return nil }
        return String(screen[range])
    }
}

struct HarnessTerminalSheet: View {
    let task: HarnessTerminalTask
    let onClose: () -> Void
    @StateObject private var model: HarnessTerminalModel

    init(task: HarnessTerminalTask, onClose: @escaping () -> Void) {
        self.task = task
        self.onClose = onClose
        _model = StateObject(wrappedValue: HarnessTerminalModel(task: task))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BrandLogo(id: task.info.id, name: task.info.label, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(TheoType.headline).foregroundColor(DS.Colors.textPrimary)
                    Text(hint).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).lineLimit(2)
                }
                Spacer()
                stateView
            }
            HStack(spacing: 6) {
                Text("$").foregroundColor(DS.Colors.textTertiary)
                Text(task.commandLine).foregroundColor(DS.Colors.textSecondary).textSelection(.enabled)
                Spacer()
                Button { copy(task.commandLine) } label: { Image(systemName: "doc.on.doc").frame(width: 14) }
                    .buttonStyle(.theo(.ghost, .small)).help("Copy the command")
            }
            .font(TheoType.mono)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.surface1))
            Group {
                if let session = model.session {
                    TerminalPanel(session: session)
                } else {
                    Text("The terminal couldn't start. Copy the command above and run it in Terminal.")
                        .font(TheoType.body).foregroundColor(DS.Colors.destructiveText).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            if model.link != nil || model.code != nil { linkRow }
            HStack {
                Spacer()
                Button(isDone ? "Done" : "Close") {
                    model.close()
                    onClose()
                }
                .buttonStyle(isDone ? .theoPrimary : .theoSecondary)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720)
        .background(DS.Colors.surface)
        .onChange(of: model.phase) { _, phase in
            guard case .succeeded = phase else { return }
            // It worked: the sheet shows that for a moment and closes itself.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                model.close()
                onClose()
            }
        }
    }

    private var isDone: Bool { if case .succeeded = model.phase { return true } else { return false } }

    private var hint: String {
        switch task.kind {
        case .install: return "Runs the official installer in this terminal."
        case .signIn: return HarnessCatalog.setups[task.info.id]?.signInHint ?? "Sign in in your browser."
        case .signOut: return "Removes this Mac's sign-in for \(task.info.label)."
        }
    }

    @ViewBuilder private var stateView: some View {
        switch model.phase {
        case .running: StatusPill(text: task.kind == .signIn ? "Waiting for sign-in" : "Running", tone: .neutral, busy: true)
        case .succeeded(let detail): StatusPill(text: detail, tone: .good)
        case .exited(let code): StatusPill(text: code == 0 ? "Finished" : "Exited with \(code)", tone: code == 0 ? .good : .bad)
        }
    }

    private var linkRow: some View {
        HStack(spacing: 8) {
            if let link = model.link {
                Text(link.host ?? link.absoluteString).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                Button { NSWorkspace.shared.open(link) } label: { Label("Open in browser", systemImage: "safari") }.buttonStyle(.theoSecondary)
                Button { copy(link.absoluteString) } label: { Label("Copy link", systemImage: "link") }.buttonStyle(.theoGhost)
            }
            Spacer()
            if let code = model.code {
                Text(code).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundColor(DS.Colors.textPrimary)
                Button { copy(code) } label: { Label("Copy code", systemImage: "doc.on.doc") }.buttonStyle(.theoSecondary)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
