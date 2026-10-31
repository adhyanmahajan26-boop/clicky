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
    static let t3BuiltInDownloadURL = URL(string: "https://github.com/adhyanmahajan26-boop/claudia-releases/releases/latest")!

    static func show(companionManager: CompanionManager, tab: TheoHomeView.Tab = .home) {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
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
            window = created
        }
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
        var title: String {
            switch self {
            case .home: return "Home"
            case .notes: return "Notes"
            case .ask: return "Ask Theo"
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
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(homeGradient)
                        Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    }
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ClickySettings.assistantName).font(.system(size: 15, weight: .bold))
                        Text("Cursor assistant for T3 Code").font(.system(size: 10.5)).foregroundColor(.secondary)
                    }
                }
                .padding(.bottom, 18)
                ForEach(Tab.allCases) { item in
                    Button(action: { tab = item }) {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(item.title).font(.system(size: 13, weight: tab == item ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(tab == item ? Color.secondary.opacity(0.16) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 46)
            .frame(width: 220)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.secondary.opacity(0.06))
            Divider()
            Group {
                switch tab {
                case .home: HomeTab(companionManager: companionManager, go: { tab = $0 })
                case .notes: NotesTab()
                case .ask: AskTab()
                case .bots: BotsRootView(store: BotsStore.shared, selection: botsSelection, showsConnectors: false)
                case .connectors: ConnectorsScreen(bots: BotsStore.shared.bots).preferredColorScheme(.dark)
                case .t3: T3Tab()
                case .settings: SettingsTab(companionManager: companionManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onReceive(NotificationCenter.default.publisher(for: .theoHomeSelectTab)) { note in
            if let raw = note.object as? String, let next = Tab(rawValue: raw) { tab = next }
        }
    }
}

private struct PageHeader: View {
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

    var body: some View {
        let brain = BrainModel(setting: ClickyModels.main)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Hi, I'm \(ClickySettings.assistantName)", subtitle: "Say “hey \(ClickySettings.assistantName)” any time. Here's how things stand.")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    statusCard("brain", "Brain", brain.provider.displayName, ClickyModels.main.replacingOccurrences(of: "codex:", with: ""), ok: true)
                    statusCard("waveform", "Voice", ClickySettings.isSilentModeEnabled ? "Silent: captions only" : "Speaks answers", "Listening for “hey \(ClickySettings.assistantName)”", ok: true)
                    statusCard("lock.shield", "Permissions", companionManager.allPermissionsGranted ? "All allowed" : "Some still needed",
                               companionManager.allPermissionsGranted ? "Microphone, screen, accessibility" : "Open the Setup guide to allow them", ok: companionManager.allPermissionsGranted)
                    let status = ClaudiaT3Integration.status()
                    statusCard("puzzlepiece.extension", "T3 Code extension", status.anyInstalled ? "Installed" : "Not added yet",
                               status.anyInstalled ? "Type $ in a T3 thread for Theo's skills" : "Add it from the T3 Code tab", ok: status.anyInstalled)
                }
                HStack(spacing: 10) {
                    Button(action: { go(.ask) }) { Label("Ask Theo", systemImage: "bubble.left") }.buttonStyle(.borderedProminent)
                    Button(action: { go(.notes) }) { Label("My notes", systemImage: "note.text") }
                    Button(action: { go(.t3) }) { Label("T3 Code", systemImage: "puzzlepiece.extension") }
                    Button(action: { SetupGuideWindowController.show(companionManager: companionManager) }) { Label("Setup guide", systemImage: "wand.and.stars") }
                }
                .controlSize(.large)
            }
            .padding(32)
        }
    }

    private func statusCard(_ symbol: String, _ title: String, _ value: String, _ detail: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.secondary)
                Text(value).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer()
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
    }
}

private struct NotesTab: View {
    @State private var items: [ClaudiaLibrary.Item] = []
    @State private var selected: Set<String> = ClaudiaLibrary.selectedIDs
    @State private var filter = "all"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                PageHeader(title: "Notes", subtitle: "Everything Theo saved. Tick “Use in code” and attach it from any T3 Code thread.")
                Spacer()
                Picker("", selection: $filter) {
                    Text("All").tag("all"); Text("Notes").tag("notes"); Text("Research").tag("research")
                    Text("Whiteboards").tag("whiteboard"); Text("Screenshots").tag("screenshot")
                }
                .pickerStyle(.segmented).frame(width: 420)
            }
            Text("\(selected.count) picked for code").font(.system(size: 12, weight: .medium)).foregroundColor(.accentColor)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    ForEach(items.filter { filter == "all" || $0.kind == filter }, id: \.id) { item in
                        card(item)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 32).padding(.top, 32)
        .onAppear(perform: reload)
    }

    private func reload() {
        items = ClaudiaLibrary.items()
        selected = ClaudiaLibrary.selectedIDs
    }

    private func card(_ item: ClaudiaLibrary.Item) -> some View {
        let isPicked = selected.contains(item.id)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if item.isImage, let image = NSImage(contentsOf: item.url) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: item.kind == "research" ? "magnifyingglass" : "doc.text").font(.system(size: 28)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 120).frame(maxWidth: .infinity).clipped()
                .background(Color.secondary.opacity(0.1))
                Button(action: {
                    var ids = ClaudiaLibrary.selectedIDs
                    if ids.contains(item.id) { ids.remove(item.id) } else { ids.insert(item.id) }
                    ClaudiaLibrary.selectedIDs = ids
                    selected = ids
                }) {
                    Label(isPicked ? "In code" : "Use in code", systemImage: isPicked ? "checkmark" : "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(isPicked ? Color.accentColor : Color.black.opacity(0.55)))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.kind.uppercased()).font(.system(size: 10, weight: .bold)).foregroundColor(.accentColor)
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isPicked ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isPicked ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
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
                VStack(alignment: .leading, spacing: 10) {
                    Text("T3 Code on this Mac").font(.system(size: 13, weight: .semibold))
                    if apps.isEmpty { Text("No T3 Code app found in Applications.").font(.system(size: 12)).foregroundColor(.secondary) }
                    ForEach(apps, id: \.self) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 26, height: 26)
                            Text(app.deletingPathExtension().lastPathComponent).font(.system(size: 13))
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(app) }
                        }
                    }
                    if !apps.contains(where: { $0.lastPathComponent == "T3 Code Cursor Assistant.app" }) {
                        Divider()
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "sparkles.rectangle.stack").font(.system(size: 20)).foregroundStyle(homeGradient)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("T3 Code Cursor Assistant").font(.system(size: 13, weight: .semibold))
                                Text("T3 Code with Theo built in: a Theo page with your notes, Ask Theo, and a notes button next to the paperclip in every thread. It runs beside T3 Code Nightly.")
                                    .font(.system(size: 11.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Download") { NSWorkspace.shared.open(TheoHomeWindowController.t3BuiltInDownloadURL) }
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                T3IntegrationSection()
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
            }
            .padding(32)
        }
        .onAppear { apps = ClaudiaT3Integration.t3Apps }
    }
}

private struct SettingsTab: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var showsInDock = ClickySettings.showsInDock

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Settings", subtitle: "Brain, voice, permissions, screen, spark, extension and updates.")
            HStack(spacing: 10) {
                Button(action: { SetupGuideWindowController.show(companionManager: companionManager, step: .welcome) }) { Label("Run the Setup guide", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent)
                Button(action: { SetupWindowController.show(companionManager: companionManager) {} }) { Label("All settings", systemImage: "slider.horizontal.3") }
            }
            .controlSize(.large)
            Toggle("Show Theo in the Dock", isOn: $showsInDock)
                .toggleStyle(.switch)
                .onChange(of: showsInDock) { _, newValue in
                    ClickySettings.showsInDock = newValue
                    NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                }
            Text("Off: Theo lives only in the menu bar.").font(.system(size: 11.5)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(32)
    }
}
