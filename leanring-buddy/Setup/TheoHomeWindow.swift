//
//  TheoHomeWindow.swift
//  leanring-buddy
//
//  Theo's own window (the Dock icon opens it): Home (status and quick actions),
//  Notes (everything Theo saved, with "Use in code"), Ask (type to Theo), T3 Code
//  (the T3 apps, the extension, and T3 Code with Theo built in), and Settings.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

/// A hosting view that takes the first click, so buttons work even before the window is key
/// (a background app's windows otherwise swallow the first click to become key).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
enum TheoHomeWindowController {
    private static var window: NSWindow?
    static let t3BuiltInDownloadURL = URL(string: "https://github.com/adhyanmahajan26-boop/clicky/releases/latest")!

    static func show(companionManager: CompanionManager, tab: TheoHomeView.Tab = .home) {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            created.title = "Theo"
            created.titlebarAppearsTransparent = true
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 860, height: 560)
            created.contentView = FirstMouseHostingView(rootView: TheoHomeView(companionManager: companionManager, initialTab: tab))
            created.center()
            if let screen = ClaudiaScreen.picked {
                let frame = screen.visibleFrame
                created.setFrameOrigin(NSPoint(x: frame.midX - created.frame.width / 2, y: frame.midY - created.frame.height / 2))
            }
            created.setFrameAutosaveName("TheoHome")
            // A remembered frame from another display loses to the display picked for Theo.
            if let screen = ClaudiaScreen.picked, created.screen != screen {
                let frame = screen.visibleFrame
                created.setFrameOrigin(NSPoint(x: frame.midX - created.frame.width / 2, y: frame.midY - created.frame.height / 2))
            }
            window = created
        }
        // A display picked after the window was made still wins the next time it opens.
        if let window, !window.isVisible { ClaudiaScreen.place(window) }
        NotificationCenter.default.post(name: .theoHomeSelectTab, object: tab.rawValue)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    /// Switches the open home window to a tab (object: the tab's raw value).
    static let theoHomeSelectTab = Notification.Name("TheoHomeSelectTab")
}

private let homeGradient = LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 0.93, green: 0.27, blue: 0.45), Color(red: 0.75, green: 0.27, blue: 0.9)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)

struct TheoHomeView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case home, notes, ask, bots, connectors, t3, settings
        var id: String { rawValue }
        /// The tabs in the sidebar. Asking Clicky lives in Bots now (Clicky is pinned there).
        static let shown: [Tab] = [.home, .bots, .notes, .connectors, .t3, .settings]
        var title: String {
            switch self {
            case .home: return "Home"
            case .notes: return "Notes"
            case .ask: return "Ask Clicky"
            case .bots: return "Bots"
            case .connectors: return "Connectors"
            case .t3: return "T3 Code"
            case .settings: return "Settings"
            }
        }
        var symbol: String {
            switch self {
            case .home: return "house"
            case .notes: return "note.text"
            case .ask: return "bubble.left.and.text.bubble.right"
            case .bots: return "person.2.wave.2"
            case .connectors: return "point.3.connected.trianglepath.dotted"
            case .t3: return "puzzlepiece.extension"
            case .settings: return "gearshape"
            }
        }
    }

    @ObservedObject var companionManager: CompanionManager
    @State private var tab: Tab
    @ObservedObject private var botsSelection = BotsSelection.shared

    init(companionManager: CompanionManager, initialTab: Tab) {
        self.companionManager = companionManager
        _tab = State(initialValue: initialTab)
        Self.route(initialTab)
    }

    /// One window, one sidebar (docs/DESIGN.md): the old tabs map onto its rows; Settings and T3 Code
    /// open the Settings window.
    static func route(_ tab: Tab) {
        let selection = BotsSelection.shared
        switch tab {
        case .home: selection.pane = .home
        case .notes: selection.pane = .notes
        case .ask: selection.pane = .clicky
        case .bots: if case .home = selection.pane { selection.pane = .bot(BotsStore.shared.primary?.id ?? "theo") }
        case .connectors: selection.pane = .connectors
        case .t3: Task { @MainActor in TheoSettingsWindowController.show(section: .coding) }
        case .settings: Task { @MainActor in TheoSettingsWindowController.show() }
        }
    }

    var body: some View {
        BotsRootView(store: BotsStore.shared, selection: botsSelection, showsConnectors: true)
            .frame(minWidth: 860, minHeight: 560)
            .onReceive(NotificationCenter.default.publisher(for: .theoHomeSelectTab)) { note in
                if let raw = note.object as? String, let next = Tab(rawValue: raw) { Self.route(next) }
            }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundColor(.secondary)
        }
    }
}

private struct HomeTab: View {
    @ObservedObject var companionManager: CompanionManager
    let go: (TheoHomeView.Tab) -> Void
    @ObservedObject private var bots = BotsStore.shared
    @ObservedObject private var look = LookSettings.shared
    @State private var notes: [ClaudiaLibrary.Item] = []

    var body: some View {
        let t3 = ClaudiaT3Integration.status()
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if !companionManager.allPermissionsGranted {
                    banner("lock.shield", "Theo still needs a permission", "Open the Setup guide to allow the microphone, screen and accessibility.",
                           button: "Open Setup guide") { SetupGuideWindowController.show(companionManager: companionManager) }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    card("cursorarrow.rays", "Clicky", "Your screen companion on \(NativeBot.label(for: ClickyModels.main))",
                         detail: companionManager.isClickyCursorEnabled ? "Awake: say \u{201C}hey \(ClickySettings.assistantName)\u{201D}" : "Asleep",
                         ok: companionManager.isClickyCursorEnabled, action: "Chat with Clicky") {
                        BotsSelection.shared.pane = .clicky
                        go(.bots)
                    }
                    card("person.2.wave.2", "Bots", bots.bots.count <= 1 ? "Only Theo so far" : "\(bots.bots.count) bots · \(bots.groups.count) group chats",
                         detail: "\(bots.routines.filter { !$0.paused }.count) schedules running", ok: true,
                         action: bots.bots.count <= 1 ? "Add your first bot" : "Open bots") { go(.bots) }
                    card("note.text", "Notes", notes.isEmpty ? "No notes yet" : "\(notes.count) notes",
                         detail: notes.first.map { "Latest: \($0.title)" } ?? "Research, articles, whiteboards and screenshots land here",
                         ok: true, action: "Open notes") { go(.notes) }
                    card("puzzlepiece.extension", "T3 Code", t3.anyInstalled ? "Connected" : "Not connected yet",
                         detail: t3.anyInstalled ? "Type $ in a T3 thread to use Theo" : "One click connects Theo to your T3 Code",
                         ok: t3.anyInstalled, action: t3.anyInstalled ? "Manage" : "Connect") { go(.t3) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Cursor").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("More in Settings") { go(.settings) }.buttonStyle(.link).font(.system(size: 12))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(CompanionIconStyle.allCases, id: \.self) { style in
                                Button { look.sparkStyle = style } label: {
                                    VStack(spacing: 6) {
                                        CompanionIconPreview(style: style).frame(width: 30, height: 30)
                                        Text(style.displayName).font(.system(size: 10)).lineLimit(1)
                                    }
                                    .frame(width: 86, height: 74)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.6)))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(look.sparkStyle == style ? DS.Colors.accent : Color.white.opacity(0.06),
                                                                                       lineWidth: look.sparkStyle == style ? 2 : 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .background(DS.Colors.background)
        .task {
            let loaded = await Task.detached { ClaudiaLibrary.items() }.value
            notes = loaded
        }
    }

    private var hero: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(homeGradient).frame(width: 64, height: 64)
                    .shadow(color: Color(red: 0.93, green: 0.27, blue: 0.45).opacity(0.45), radius: 18)
                Image(systemName: "sparkles").font(.system(size: 26, weight: .semibold)).foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Hi, I'm \(ClickySettings.assistantName)").font(.system(size: 28, weight: .bold))
                Text("Talk to Clicky about your screen, run a team of bots, and hand builds to T3 Code.")
                    .font(.system(size: 13.5)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.27, blue: 0.45).opacity(0.16), Color(red: 0.75, green: 0.27, blue: 0.9).opacity(0.08), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.07)))
    }

    private func card(_ symbol: String, _ title: String, _ value: String, detail: String, ok: Bool, action: String,
                      perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(homeGradient.opacity(0.9)).frame(width: 36, height: 36)
                        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    }
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Circle().fill(ok ? DS.Colors.success : DS.Colors.warning).frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(value).font(.system(size: 14, weight: .medium))
                    Text(detail).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text(action).font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(DS.Colors.accentText)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(HoverLiftStyle())
    }

    private func banner(_ symbol: String, _ title: String, _ detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundColor(DS.Colors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            Spacer()
            Button(button, action: action).buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.warning.opacity(0.1)))
    }
}

/// Cards lift a little under the pointer.
private struct HoverLiftStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : hovering ? 1.01 : 1)
            .shadow(color: .black.opacity(hovering ? 0.35 : 0), radius: 14, y: 6)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct NotesTab: View {
    @State private var items: [ClaudiaLibrary.Item] = []
    @State private var selected: Set<String> = ClaudiaLibrary.selectedIDs
    @State private var filter = "all"
    @State private var query = ""
    @State private var pendingDelete: ClaudiaLibrary.Item?

    private static let filters: [(id: String, title: String, symbol: String)] = [
        ("all", "All", "square.grid.2x2"), ("notes", "Articles", "doc.text"), ("research", "Research", "sparkle.magnifyingglass"),
        ("whiteboard", "Whiteboards", "scribble.variable"), ("screenshot", "Screenshots", "camera.viewfinder"),
    ]

    private func count(for filterID: String) -> Int {
        filterID == "all" ? items.count : items.filter { $0.kind == filterID }.count
    }

    private var visibleItems: [ClaudiaLibrary.Item] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            (filter == "all" || item.kind == filter) && (needle.isEmpty || item.title.lowercased().contains(needle) || item.kind.contains(needle))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Notes").font(.system(size: 26, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
                            Text("\(items.count)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                        Text("Everything Theo saved. Pick notes to attach them to code tasks.")
                            .font(.system(size: 13)).foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer()
                    if !selected.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                            Text("\(selected.count) picked for code").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(NotesAccent.gradient.opacity(0.28)))
                        .overlay(Capsule().strokeBorder(NotesAccent.gradient, lineWidth: 1))
                        .transition(.opacity)
                    }
                    NotesSearchField(text: $query)
                }
                HStack(spacing: 8) {
                    ForEach(Self.filters, id: \.id) { entry in
                        NotesFilterChip(title: entry.title, symbol: entry.symbol, count: count(for: entry.id), isActive: filter == entry.id) {
                            withAnimation(.easeOut(duration: 0.18)) { filter = entry.id }
                        }
                    }
                    Spacer()
                }
            }
            ScrollView {
                if visibleItems.isEmpty {
                    NotesEmptyState(isFiltering: !items.isEmpty)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 236, maximum: 340), spacing: 18)], spacing: 18) {
                        ForEach(visibleItems, id: \.id) { item in
                            NotesLibraryCard(item: item, isPicked: selected.contains(item.id),
                                             onTogglePick: { togglePick(item) }, onDelete: { pendingDelete = item })
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 2).padding(.bottom, 24)
                }
            }
        }
        .padding(.horizontal, 32).padding(.top, 32)
        .animation(.easeOut(duration: 0.18), value: selected)
        .confirmationDialog("Move to Trash?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { item in
            Button("Move to Trash", role: .destructive) { trash(item) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text("\u{201C}\(item.title)\u{201D} moves to the Trash. You can put it back from there.")
        }
        .task {
            // Live refresh: scan off the main thread every 2 s, only touch state when the folder contents changed.
            while !Task.isCancelled {
                let fresh = await Task.detached(priority: .utility) { ClaudiaLibrary.items() }.value
                if fresh.map({ "\($0.id)\($0.date.timeIntervalSince1970)" }) != items.map({ "\($0.id)\($0.date.timeIntervalSince1970)" }) { items = fresh }
                let ids = ClaudiaLibrary.selectedIDs
                if ids != selected { selected = ids }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func togglePick(_ item: ClaudiaLibrary.Item) {
        var ids = ClaudiaLibrary.selectedIDs
        if ids.contains(item.id) { ids.remove(item.id) } else { ids.insert(item.id) }
        ClaudiaLibrary.selectedIDs = ids
        selected = ids
    }

    private func trash(_ item: ClaudiaLibrary.Item) {
        pendingDelete = nil
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            var ids = ClaudiaLibrary.selectedIDs
            if ids.remove(item.id) != nil { ClaudiaLibrary.selectedIDs = ids; selected = ids }
            withAnimation(.easeOut(duration: 0.2)) { items.removeAll { $0.id == item.id } }
        } catch {
            NSSound.beep()
        }
    }
}

private struct AskTab: View {
    @State private var question = ""
    @State private var turns: [[String: Any]] = []
    @State private var isBusy = false
    @State private var speaks = !ClickySettings.isSilentModeEnabled

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "Ask Theo", subtitle: "Typed instead of spoken. Theo still sees your screens, marks things and draws boards.")
                    if isBusy {
                        HStack { ProgressView().controlSize(.small); Text("Theo is on it…").foregroundColor(.secondary) }
                    }
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(turn["you"] as? String ?? "")
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor)).foregroundColor(.white)
                            HStack {
                                Text(turn["claudia"] as? String ?? "")
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.1)))
                                    .textSelection(.enabled)
                                Spacer(minLength: 60)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(32)
            }
            Divider()
            HStack(spacing: 10) {
                TextField("Ask Theo about your screen, to draw a flowchart, research, or do something…", text: $question)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .onSubmit(send)
                Toggle("Speak", isOn: $speaks).toggleStyle(.switch).controlSize(.small)
                Button("Send", action: send).buttonStyle(.borderedProminent).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
            }
            .padding(16)
        }
        .onAppear(perform: load)
    }

    private func load() {
        ClaudiaControlInbox.shared?.execute(["cmd": "turns", "limit": 20]) { _, result, _ in
            turns = result as? [[String: Any]] ?? []
        }
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        question = ""
        isBusy = true
        ClaudiaControlInbox.shared?.execute(["cmd": "ask", "text": text, "speak": speaks]) { _, _, _ in
            isBusy = false
            load()
        }
    }
}

private struct T3Tab: View {
    @State private var apps = ClaudiaT3Integration.t3Apps

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "T3 Code", subtitle: "Theo inside T3 Code: the extension for every agent, or T3 Code with Theo built in.")
                T3ConnectView()
            }
            .padding(32)
        }
        .onAppear { apps = ClaudiaT3Integration.t3Apps }
    }
}

struct SettingsTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case look, brain, coding, keys, voice, screen, permissions, updates, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .look: return "Look"
            case .brain: return "Brain"
            case .coding: return "Coding"
            case .keys: return "API keys"
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
            case .brain: return "Which agent Theo thinks with, and the models it uses."
            case .coding: return "Your harnesses, the default subscription and model, and where builds go."
            case .keys: return "Keys for Sarvam and other model providers, kept in your Keychain."
            case .voice: return "How Theo speaks to you."
            case .screen: return "Which display Theo uses, and the T3 Code extension."
            case .permissions: return "What Theo needs to hear, see and point."
            case .updates: return "Keep Theo current."
            case .about: return "Dock, setup guide and version."
            }
        }
        var symbol: String {
            switch self {
            case .look: return "sparkles"
            case .brain: return "brain"
            case .coding: return "terminal"
            case .keys: return "key"
            case .voice: return "waveform"
            case .screen: return "display"
            case .permissions: return "checkmark.shield"
            case .updates: return "arrow.down.circle"
            case .about: return "info.circle"
            }
        }
    }

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var model: SetupModel
    @ObservedObject private var look = LookSettings.shared
    @State private var section: Section
    @State private var showsInDock = ClickySettings.showsInDock

    init(companionManager: CompanionManager, section: Section = .look) {
        self.companionManager = companionManager
        _section = State(initialValue: section)
        _model = ObservedObject(wrappedValue: SetupWindowController.sharedModel(companionManager: companionManager))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SETTINGS").font(.system(size: 10.5, weight: .bold)).tracking(0.8).foregroundColor(.secondary)
                    .padding(.leading, 10).padding(.bottom, 8)
                ForEach(Section.allCases) { item in
                    Button(action: { withAnimation(.easeOut(duration: 0.15)) { section = item } }) {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol).font(.system(size: 13)).frame(width: 18)
                                .foregroundColor(section == item ? Color.accentColor : .secondary)
                            Text(item.title).font(.system(size: 13, weight: section == item ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(section == item ? Color.accentColor.opacity(0.14) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 40)
            .frame(width: 168)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: section.title, subtitle: section.subtitle)
                    sectionContent
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { look.reload() }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .look: lookContent
        case .brain: SetupView(model: model, forcedPage: .brain)
        case .coding: CodingSettingsView()
        case .keys: VStack(alignment: .leading, spacing: 18) { ProviderKeysView(); SarvamVoiceSettings() }
        case .voice: SetupView(model: model, forcedPage: .voice)
        case .screen: screenContent
        case .permissions: SetupView(model: model, forcedPage: .permissions)
        case .updates: SetupView(model: model, forcedPage: .updates)
        case .about: aboutContent
        }
    }

    // MARK: Look

    private var lookContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("Cursor", "The spark that follows you. Pick a style.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 12)], spacing: 12) {
                    ForEach(CompanionIconStyle.allCases, id: \.self) { style in
                        CursorTile(style: style, isSelected: look.sparkStyle == style) { look.sparkStyle = style }
                    }
                }
            }
            card("Spark behaviour", "Follow the pointer, or sit in a corner of Theo's screen.") {
                chips([(ClickySettings.SparkMode.cursor, "Follows my pointer", "cursorarrow.motionlines"),
                       (.docked, "Lives in a corner", "rectangle.bottomthird.inset.filled")], selection: $look.sparkMode)
            }
            card("Theme", "Colours for Notes and T3 Code.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(ClaudiaTheme.allCases, id: \.self) { theme in
                        ThemeTile(theme: theme, isSelected: look.theme == theme) { look.theme = theme }
                    }
                }
            }
            card("Pill", "Where Theo's status pill lives.") {
                chips([(ClickySettings.IslandPlacement.notch, "Notch", "rectangle.topthird.inset.filled"),
                       (.floating, "Floating", "rectangle.dashed"),
                       (.corner, "Top-right corner", "rectangle.inset.topright.filled")], selection: $look.placement)
            }
            card("Theo's screen", "Browser windows, apps, boards and notes open here.") { screenPicker }
        }
    }

    private var screenPicker: some View {
        HStack {
            Picker("", selection: $look.screenName) {
                Text("Wherever my pointer is").tag("")
                ForEach(look.screenNames, id: \.self) { name in Text(name).tag(name) }
                if !look.screenName.isEmpty && !look.screenNames.contains(look.screenName) {
                    Text("\(look.screenName) (not connected)").tag(look.screenName)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
        }
    }

    // MARK: Screen

    private var screenContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("Theo's screen", "With a screen picked, Theo leaves your main screen alone.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    screenTile(name: "", title: "Follow my pointer", symbol: "cursorarrow.rays")
                    ForEach(look.screenNames, id: \.self) { name in screenTile(name: name, title: name, symbol: "display") }
                }
            }
            card("T3 Code extension", "Theo's skills inside every T3 Code agent.") { T3IntegrationSection() }
        }
    }

    private func screenTile(name: String, title: String, symbol: String) -> some View {
        let selected = look.screenName == name
        return Button(action: { look.screenName = name }) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundColor(selected ? Color.accentColor : .secondary)
                Text(title).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).multilineTextAlignment(.center).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: About

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("Theo", "This is Theo \(companionManager.updateController.currentVersionLabel).") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show Theo in the Dock", isOn: $showsInDock)
                        .toggleStyle(.switch)
                        .onChange(of: showsInDock) { _, newValue in
                            ClickySettings.showsInDock = newValue
                            NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                        }
                    Text("Off: Theo lives only in the menu bar.").font(.system(size: 11.5)).foregroundColor(.secondary)
                    Button(action: { SetupGuideWindowController.show(companionManager: companionManager, step: .welcome) }) { Label("Run the Setup guide", systemImage: "wand.and.stars") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
    }

    // MARK: Pieces

    private func card<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
    }

    /// A row of one-click options (an icon and a label each); the chosen one is filled.
    private func chips<T: Hashable>(_ options: [(T, String, String)], selection: Binding<T>) -> some View {
        HStack(spacing: 10) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = selection.wrappedValue == option.0
                Button(action: { selection.wrappedValue = option.0 }) {
                    HStack(spacing: 8) {
                        Image(systemName: option.2).font(.system(size: 14))
                        Text(option.1).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    }
                    .foregroundColor(selected ? Color.accentColor : .primary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A big cursor-style tile: the spark on black, its name, and a check when it's the one in use.
private struct CursorTile: View {
    let style: CompanionIconStyle
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                CompanionIconPreview(style: style).frame(width: 44, height: 44).padding(10)
                Text(style.displayName).font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.center).lineLimit(2).foregroundColor(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, minHeight: 112)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.82)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isSelected ? Color.accentColor : Color.white.opacity(isHovering ? 0.25 : 0.06), lineWidth: isSelected ? 2.5 : 1))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundColor(.accentColor).padding(8)
                }
            }
            .scaleEffect(isHovering ? 1.03 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovering)
            .animation(.easeOut(duration: 0.15), value: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A theme swatch: the theme's background, panel and accent colours with its name.
private struct ThemeTile: View {
    let theme: ClaudiaTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let palette = theme.palette
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.map { ClaudiaTheme.color($0.background) } ?? Color.secondary.opacity(0.3))
                    if let palette {
                        Circle().fill(ClaudiaTheme.color(palette.accent)).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "circle.lefthalf.filled").font(.system(size: 14)).foregroundColor(.secondary)
                    }
                }
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                Text(theme.displayName).font(.system(size: 11.5, weight: isSelected ? .semibold : .regular)).multilineTextAlignment(.leading).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
