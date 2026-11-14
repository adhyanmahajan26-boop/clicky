//
//  TheoHomeWindow.swift
//  leanring-buddy
//
//  Theo's one window (the Dock icon opens it): the sidebar with Home, the chats, Notes, Routines, Connectors and
//  Settings, all in this window (BotsRootView).
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
    static let t3BuiltInDownloadURL: URL? = UpdateFeed.bundledReleasesRepository.flatMap(UpdateFeed.releasesPageURL(repository:))

    /// `activates` false opens it without taking focus (a launch in the background).
    static func show(companionManager: CompanionManager, tab: TheoHomeView.Tab = .home, activates: Bool = true) {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            created.title = "Theo"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 860, height: 560)
            let host = FirstMouseHostingView(rootView: TheoHomeView(companionManager: companionManager, initialTab: tab))
            // Only the floor comes from the content. Its natural size would pull the window in to 860 wide the moment layout settled.
            host.sizingOptions = [.minSize]
            created.contentView = host
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
        if activates {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    /// Switches the open home window to a tab (object: the tab's raw value).
    static let theoHomeSelectTab = Notification.Name("TheoHomeSelectTab")
}

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
        // Settings was asked for just before this window was made: that's where it should open.
        case .home: if case .settings = selection.pane {} else { selection.pane = .home }
        case .notes: selection.pane = .notes
        case .ask: selection.pane = .clicky
        case .bots: if case .home = selection.pane, let primary = BotsStore.shared.primary { selection.pane = .bot(primary.id) }
        case .connectors: selection.pane = .connectors
        case .t3: selection.openSettings(.coding)
        case .settings: selection.openSettings(.look)
        }
    }

    var body: some View {
        BotsRootView(store: BotsStore.shared, selection: botsSelection, showsConnectors: true)
            .frame(minWidth: 860, minHeight: 560)
            .onReceive(NotificationCenter.default.publisher(for: .theoHomeSelectTab)) { note in
                // Reopening the window (Dock, menu bar) keeps the chat that was open; other tabs go where asked.
                if let raw = note.object as? String, let next = Tab(rawValue: raw), next != .home { Self.route(next) }
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
                            Text("Notes").font(TheoType.title).foregroundColor(DS.Colors.textPrimary)
                            Text("\(items.count)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(DS.Colors.hover))
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.filters, id: \.id) { entry in
                            NotesFilterChip(title: entry.title, symbol: entry.symbol, count: count(for: entry.id), isActive: filter == entry.id) {
                                withAnimation(.easeOut(duration: 0.18)) { filter = entry.id }
                            }
                        }
                    }
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

