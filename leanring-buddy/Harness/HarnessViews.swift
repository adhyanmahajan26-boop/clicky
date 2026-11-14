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
    /// The projects folder as shown, refreshed when it's changed here.
    @State private var projectsFolderWords = BotsT3.projectsWords

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Install them, sign in, or use your own key. Theo runs each one in its own terminal.").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Button { center.refresh(force: true) } label: {
                        Label(center.isRefreshing ? "Checking…" : "Re-check all", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.theo(.ghost, .small)).disabled(center.isRefreshing)
                }
                ForEach(HarnessCatalog.all, id: \.id) { info in
                    HarnessCard(info: info, openTerminal: { task in
                        // The test profile's CLIs are the real ones, signed in with the real account: only a fake one may sign in or out.
                        if TheoProfile.isTest, task.kind != .install, HarnessCatalog.executable(for: task.info.id)?.path.contains("/fake-bin/") != true { return }
                        terminalTask = task
                    })
                }
            }
            TheoSection(title: "Defaults", hint: "T3 Code tracks a build in its own app. Any other harness runs in a live terminal inside Theo. Every bot can pick its own engine in its settings.") {
                defaultRow(title: "Builds go to", harnesses: HarnessCatalog.codingTargets, selection: Binding(get: { center.codingTarget }, set: { center.codingTarget = $0 }),
                           model: Binding(get: { center.codingModel ?? "" }, set: { center.codingModel = $0.isEmpty ? nil : $0 }),
                           effort: Binding(get: { center.codingEffort ?? "" }, set: { center.codingEffort = $0.isEmpty ? nil : $0 }))
                RowDivider()
                defaultRow(title: "New bots run on", harnesses: HarnessCatalog.botEngines, selection: Binding(get: { center.defaultHarness }, set: { center.defaultHarness = $0 }),
                           model: Binding(get: { center.defaultModel(for: center.defaultHarness) ?? "" }, set: { center.setDefaultModel($0.isEmpty ? nil : $0, for: center.defaultHarness) }),
                           effort: Binding(get: { center.defaultEffort(for: center.defaultHarness) ?? "" }, set: { center.setDefaultEffort($0.isEmpty ? nil : $0, for: center.defaultHarness) }))
                RowDivider()
                projectsFolderRow
            }
        }
        .onAppear { center.refresh() }
        .sheet(item: $terminalTask) { task in
            HarnessTerminalSheet(task: task) { terminalTask = nil }
        }
    }

    /// Where new project folders go (`v2.code.projectsFolder`). The folder is made when the first project needs it.
    private var projectsFolderRow: some View {
        HStack(spacing: 10) {
            Text("Projects folder").font(TheoType.body).foregroundColor(DS.Colors.textPrimary).frame(width: 110, alignment: .leading).fixedSize()
            Text(projectsFolderWords).font(TheoType.body).foregroundColor(DS.Colors.textSecondary).lineLimit(1).truncationMode(.middle)
                .help("New project folders go here, and bots and coding runs list your projects from it.")
            Button("Change\u{2026}") {
                if ProjectsFolderChooser.chooseWithPanel() { projectsFolderWords = BotsT3.projectsWords }
            }
            .buttonStyle(.theo(.ghost, .small)).pointerCursor()
            if ClickySettings.projectsFolderSetting != ProjectsFolder.defaultSetting {
                Button("Use \(ProjectsFolder.defaultSetting)") {
                    ClickySettings.projectsFolderSetting = ProjectsFolder.defaultSetting
                    projectsFolderWords = BotsT3.projectsWords
                }
                .buttonStyle(.theo(.ghost, .small)).pointerCursor()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func defaultRow(title: String, harnesses: [HarnessInfo], selection: Binding<String>, model: Binding<String>, effort: Binding<String>) -> some View {
        // One line when there's room, two in a narrow window.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(title).font(TheoType.body).foregroundColor(DS.Colors.textPrimary).frame(width: 110, alignment: .leading).fixedSize()
                targetPicker(title: title, harnesses: harnesses, selection: selection)
                HarnessModelPicker(harness: selection.wrappedValue, model: model, effort: effort)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(title).font(TheoType.body).foregroundColor(DS.Colors.textPrimary).frame(width: 110, alignment: .leading).fixedSize()
                    targetPicker(title: title, harnesses: harnesses, selection: selection)
                }
                HarnessModelPicker(harness: selection.wrappedValue, model: model, effort: effort).padding(.leading, 120)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func targetPicker(title: String, harnesses: [HarnessInfo], selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(harnesses, id: \.id) { info in
                let status = center.status(for: info.id)
                Text(info.label + (center.statuses[info.id] == nil ? "" : status.installed ? (status.loggedIn == false ? " (not signed in)" : "") : " (not installed)")).tag(info.id)
            }
        }
        .labelsHidden().frame(width: 230)
    }
}

/// Picks the projects folder with the system's panel, from Settings › Harnesses or a run's card.
@MainActor
enum ProjectsFolderChooser {
    /// True when the owner chose a folder (the setting changed).
    @discardableResult
    static func chooseWithPanel() -> Bool {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for projects"
        panel.message = "New project folders go here, and bots and coding runs list your projects from it."
        let currentFolder = BotsT3.projectsFolder
        panel.directoryURL = FileManager.default.fileExists(atPath: currentFolder.path) ? currentFolder : homeDirectory
        guard panel.runModal() == .OK, let chosenFolder = panel.url else { return false }
        ClickySettings.projectsFolderSetting = ProjectsFolder.setting(forChosenPath: chosenFolder.path, homeDirectory: homeDirectory.path)
        return true
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
    @State private var showsMore = false

    private var status: HarnessStatus { center.status(for: info.id) }
    private var isChecking: Bool { center.statuses[info.id] == nil || center.checking.contains(info.id) }
    private var setup: HarnessCatalog.Setup? { HarnessCatalog.setups[info.id] }
    private var keyProvider: ProviderInfo? { setup?.keyProvider.flatMap { ProviderInfo.info(for: $0) } }
    private var usesKey: Bool { center.usesAPIKey(info.id) }
    private var isSignedIn: Bool { status.installed && status.loggedIn == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandLogo(id: info.id, name: info.label, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(info.label).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        if let version = status.version { Text(version).font(TheoType.micro).foregroundColor(DS.Colors.textTertiary).lineLimit(1) }
                    }
                    Text(subtitle).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                pill
                mainAction
                Button { center.recheck(info.id) } label: { Image(systemName: "arrow.clockwise").frame(width: 14) }
                    .buttonStyle(.theo(.ghost, .small)).help("Re-check \(info.label)").disabled(isChecking)
                if hasMore && !alwaysShowsMore {
                    Button { withAnimation(DS.Motion.hover) { showsMore.toggle() } } label: {
                        Image(systemName: "chevron.right").frame(width: 14).rotationEffect(.degrees(showsMore ? 90 : 0))
                    }
                    .buttonStyle(.theo(.ghost, .small)).help(showsMore ? "Fewer options" : "More options")
                }
            }
            .padding(.horizontal, 14).frame(minHeight: 56)
            if hasMore && (showsMore || alwaysShowsMore) {
                RowDivider()
                moreActions.padding(.horizontal, 14).padding(.vertical, 8)
            }
            if info.id == "t3" && (showsConnect || !status.installed) { t3Details.padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 6) }
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
            StatusPill(text: "API key", tone: .good)
        } else if status.loggedIn == false {
            StatusPill(text: "Signed out", tone: .warn)
        } else if status.loggedIn == true {
            StatusPill(text: info.id == "t3" ? "Ready" : "Signed in", tone: .good)
        } else {
            StatusPill(text: "Ready", tone: .good)
        }
    }

    /// The one thing this harness needs right now, on its own line. A signed-in harness needs nothing.
    @ViewBuilder private var mainAction: some View {
        if !status.installed && !isChecking {
            Button { openTerminal(.install(info)) } label: { Label("Install", systemImage: "arrow.down.circle") }.buttonStyle(.theo(.primary, .small))
        } else if info.id == "t3" {
            Button { showsConnect.toggle() } label: { Label(showsConnect ? "Hide" : "Connect Theo", systemImage: "link") }
                .buttonStyle(.theo(showsConnect ? .ghost : .secondary, .small))
        } else if status.installed && status.loggedIn != true && info.id != "opencode" {
            Button { openTerminal(.signIn(info)) } label: { Label("Sign in", systemImage: "person.crop.circle.badge.checkmark") }.buttonStyle(.theo(.primary, .small))
        }
    }

    /// Signed out, using a key instead is one of the two ways forward, so it stays in view.
    private var alwaysShowsMore: Bool { !status.installed || status.loggedIn == false }

    private var hasMore: Bool {
        guard status.installed else { return setup?.installPage != nil }
        if info.id == "t3" { return false }
        return info.id == "opencode" || keyProvider != nil || (isSignedIn && (setup?.signIn != nil || setup?.signOut != nil))
    }

    /// What's still there when it's needed, out of the way until then.
    @ViewBuilder private var moreActions: some View {
        HStack(spacing: 8) {
            if !status.installed {
                if let page = setup.flatMap({ URL(string: $0.installPage) }) {
                    Link(destination: page) { Text("Install page") }.buttonStyle(.theo(.ghost, .small))
                }
            } else {
                if info.id == "opencode" {
                    Button("Add a provider") { openTerminal(.signIn(info)) }.buttonStyle(.theo(.secondary, .small))
                } else if isSignedIn {
                    Button("Sign in again") { openTerminal(.signIn(info)) }.buttonStyle(.theo(.ghost, .small))
                    if setup?.signOut != nil { Button("Sign out") { confirmsSignOut = true }.buttonStyle(.theo(.ghost, .small)) }
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

    /// Theo/Harness/gemini-sign-in, with .gemini/settings.json that turns Gemini's auto-update off.
    static func geminiSignInFolder() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("Theo/Harness/gemini-sign-in", isDirectory: true)
        let settings = folder.appendingPathComponent(".gemini/settings.json")
        do {
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try EngineSetupRules.geminiQuietSettingsData().write(to: settings, options: .atomic)
            return folder
        } catch {
            return nil
        }
    }

    init(task: HarnessTerminalTask) {
        self.task = task
        wasSignedIn = HarnessCenter.shared.status(for: task.info.id).loggedIn == true
        var environment = TerminalSession.defaultEnvironment()
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
        // A test must not open browser tabs on the owner's screen.
        if TheoProfile.isTest { environment["NO_OPEN_BROWSER"] = "1"; environment["BROWSER"] = "/usr/bin/true" }
        var folder = FileManager.default.homeDirectoryForCurrentUser.path
        // Gemini checks for updates (and installs them) from its interactive screen, which is what a sign-in is. It runs in
        // a folder of Theo's own whose settings turn that off, so the installed version stays as it is and the owner's
        // ~/.gemini is never written to.
        if task.info.id == "gemini", task.kind == .signIn, let quiet = Self.geminiSignInFolder() {
            folder = quiet.path
            environment.merge(EngineSetupRules.geminiSignInEnvironment) { _, new in new }
        }
        session = TerminalSessions.shared.start(id: "setup:\(task.id)", title: task.title, command: "/bin/zsh",
                                                arguments: ["-lc", task.shellCommand()], environment: environment,
                                                workingDirectory: folder)
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
            // Signing out has nothing more to look for. An installer's or a sign-in's exit gets a last look below.
            if task.kind == .signOut { timer?.invalidate() }
        }
        guard task.kind != .signOut, ticks % 3 == 0, !probing else { return }
        probing = true
        let info = task.info
        let kind = task.kind
        Task.detached(priority: .userInitiated) { [weak self] in
            if kind == .install { HarnessCatalog.findNpmGlobalFolder() }
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
        // Already signed in, the check can't tell anything changed, so it takes the CLI's own word or its clean exit.
        case .signIn: finished = status.loggedIn == true && (!wasSignedIn || phase == .exited(0) || saysSignedIn)
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

    private var saysSignedIn: Bool {
        (session?.unwrappedScreenText() ?? "").range(of: #"(?i)(successfully|now) (logged|signed) in|login successful|logged in (successfully|as)"#, options: .regularExpression) != nil
    }

    /// The web link on screen to sign in at. Not a CLI's own local server, which it prints first ("http://localhost:1455").
    static func link(in screen: String) -> URL? {
        var links: [URL] = []
        var rest = screen[...]
        while let range = rest.range(of: #"https?://[^\s"'<>\)\]]+"#, options: .regularExpression) {
            if let url = URL(string: String(rest[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))) { links.append(url) }
            rest = rest[range.upperBound...]
        }
        return links.first { !["localhost", "127.0.0.1"].contains($0.host ?? "") } ?? links.first
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
        case .running: StatusPill(text: task.kind == .signIn ? "Waiting for sign-in" : task.kind == .install ? "Installing" : "Running", tone: task.kind == .signIn ? .warn : .checking)
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
