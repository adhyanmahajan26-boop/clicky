//
//  BotsView.swift
//  leanring-buddy
//
//  The Bots window: the team chat, one ongoing chat per bot, and the
//  Connectors page. Chats show only messages; while a bot thinks its avatar
//  floats and tilts, and while it replies the words type in behind a comet
//  caret in the bot's colour.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

enum BotsPane: Hashable {
    /// Today: what's going on (first page on launch).
    case home
    case notes
    /// The Project room (the project group's chat).
    case team
    case group(String)
    case bot(String)
    /// Clicky's own chat: Theo's on-screen companion.
    case clicky
    case routines
    case connectors
}

@MainActor
final class BotsSelection: ObservableObject {
    static let shared = BotsSelection()
    @Published var pane: BotsPane = .home
}

struct BotsRootView: View {
    @ObservedObject var store: BotsStore
    @ObservedObject var selection: BotsSelection
    /// Inside Theo's home window, Connectors is its own tab instead.
    var showsConnectors = true

    /// The bot's settings slide over the chat from the right; they never shrink it (docs/DESIGN.md).
    @State private var showsInspector = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Colors.background)
                .overlay(alignment: .topTrailing) {
                    if inspectorTarget != nil && !showsInspector {
                        Button { withAnimation(DS.Motion.panel) { showsInspector = true } } label: {
                            Image(systemName: "sidebar.right").font(.system(size: 14)).foregroundColor(DS.Colors.textSecondary)
                                .frame(width: 30, height: 30).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Settings for this chat")
                        .padding(.top, 11).padding(.trailing, 12)
                    }
                }
                .overlay {
                    if showsInspector, let target = inspectorTarget {
                        ZStack(alignment: .trailing) {
                            Color.black.opacity(0.18).ignoresSafeArea()
                                .onTapGesture { withAnimation(DS.Motion.panel) { showsInspector = false } }
                            Group {
                                switch target {
                                case .clicky: ClickyInspector()
                                case .bot(let id): BotInspector(store: store, botID: id).id(id)
                                default: EmptyView()
                                }
                            }
                            .frame(width: 340)
                            .background(DS.Colors.surface)
                            .overlay(alignment: .leading) { Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1) }
                            .shadow(color: .black.opacity(0.28), radius: 24, x: -2)
                            .overlay(alignment: .topTrailing) {
                                Button { withAnimation(DS.Motion.panel) { showsInspector = false } } label: {
                                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
                                        .frame(width: 26, height: 26).background(Circle().fill(DS.Colors.hover))
                                }
                                .buttonStyle(.plain).keyboardShortcut(.cancelAction).padding(12)
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
        }
        .background(DS.Colors.background)
        // Dark only for now: a few pieces still assume a dark backdrop (docs/DESIGN.md has the light palette).
        .preferredColorScheme(.dark)
        .onChange(of: selection.pane) { _, _ in showsInspector = false }
        .onReceive(NotificationCenter.default.publisher(for: .theoShowBotSettings)) { _ in
            if inspectorTarget != nil { withAnimation(DS.Motion.panel) { showsInspector = true } }
        }
    }

    @State private var editingGroup: BotGroup?
    @State private var addingBot = false
    @State private var detailsBot: NativeBot?
    @State private var namingSectionFor: String?
    @State private var sectionName = ""
    @State private var confirmingDelete: String?
    @State private var showsHidden = false

    private static let blankGroup = BotGroup(id: "", name: "", symbol: "person.2.fill", headID: nil, memberIDs: [])

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights.
            Color.clear.frame(height: 40)
            VStack(spacing: 1) {
                HStack(spacing: 0) {
                    Button { addingBot = true } label: { navLabel("square.and.pencil", "New bot") }
                        .buttonStyle(SidebarButtonStyle(isSelected: false))
                        .keyboardShortcut("n", modifiers: .command)
                    Menu {
                        Button { editingGroup = Self.blankGroup } label: { Label("New group chat", systemImage: "person.2") }
                        Button { namingSectionFor = ""; sectionName = "" } label: { Label("New category", systemImage: "folder.badge.plus") }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 28, height: 30).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("New group chat or category")
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).frame(width: 20)
                    TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(DS.Colors.textTertiary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(searchFocused ? DS.Colors.hover : .clear))
                .background(Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command).opacity(0))
                navRow(.home, "house", "Home")
            }
            .padding(.horizontal, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !query.isEmpty {
                        sectionTitle("Results")
                        ForEach(searchResults, id: \.self) { item in itemRow(item) }
                        if searchResults.isEmpty {
                            Text("No bots match").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary).padding(.horizontal, 10).padding(.vertical, 6)
                        }
                    } else {
                        let pinned = store.layout.pinned.filter(itemExists)
                        Color.clear.frame(height: 6).dropTarget { items in items.forEach { store.setPinned(true, $0) } }
                        ForEach(pinned, id: \.self) { item in itemRow(item) }
                        let loose = looseItems
                        if !store.rootSections.isEmpty || !loose.bots.isEmpty || store.bots.count > 1 {
                            sectionTitle("Bots").dropTarget { items in items.forEach { unfile($0) } }
                            ForEach(store.rootSections) { section in sectionTree(section, depth: 0) }
                            ForEach(loose.bots, id: \.self) { item in itemRow(item) }
                        }
                        if !loose.groups.isEmpty {
                            sectionTitle("Groups").dropTarget { items in items.forEach { unfile($0) } }
                            ForEach(loose.groups, id: \.self) { item in itemRow(item) }
                        }
                        if store.bots.count <= 1 && store.groups.isEmpty {
                            // A fresh setup: one quiet line pointing at the first bot.
                            Button { addingBot = true } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 20)
                                    Text("Add your first bot").font(.system(size: 13))
                                }
                                .foregroundColor(DS.Colors.textSecondary).padding(.horizontal, 8).frame(height: 32)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(SidebarButtonStyle(isSelected: false))
                            .padding(.top, 10)
                        }
                        let hidden = store.layout.hidden.filter(itemExists)
                        if !hidden.isEmpty {
                            Button { withAnimation(DS.Motion.hover) { showsHidden.toggle() } } label: {
                                HStack(spacing: 4) {
                                    Text("Hidden").font(.system(size: 11, weight: .semibold))
                                    Text("\(hidden.count)").font(.system(size: 11))
                                    Image(systemName: showsHidden ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                                }
                                .foregroundColor(DS.Colors.textTertiary).padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                            }
                            .buttonStyle(.plain)
                            if showsHidden { ForEach(hidden, id: \.self) { item in itemRow(item).opacity(0.55) } }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
            VStack(spacing: 1) {
                navRow(.notes, "note.text", "Notes")
                navRow(.routines, "clock.arrow.circlepath", "Routines",
                       trailing: store.routines.isEmpty ? nil : "\(store.routines.filter { !$0.paused }.count)")
                if showsConnectors { navRow(.connectors, "puzzlepiece.extension", "Connectors") }
                Button { TheoSettingsWindowController.show() } label: { navLabel("gearshape", "Settings", shortcut: "⌘,") }
                    .buttonStyle(SidebarButtonStyle(isSelected: false))
                    .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .frame(width: 248)
        .background(DS.Colors.sidebar)
        .sheet(item: $editingGroup) { group in
            GroupEditor(store: store, group: group) { saved in
                if let saved { selection.pane = saved.id == BotGroup.projectID ? .team : .group(saved.id) }
                editingGroup = nil
            }
        }
        .sheet(isPresented: $addingBot) {
            NewBotSheet(store: store) { bot in
                if let bot { selection.pane = .bot(bot.id) }
                addingBot = false
            }
        }
        .sheet(item: $detailsBot) { bot in
            BotDetailsSheet(store: store, botID: bot.id) { detailsBot = nil }
        }
        .sheet(item: Binding(get: { namingSectionFor.map { NamingRequest(item: $0) } }, set: { if $0 == nil { namingSectionFor = nil } })) { request in
            VStack(alignment: .leading, spacing: 14) {
                Text(request.item.hasPrefix("rename:") ? "Rename category" : request.item.hasPrefix("sub:") ? "New sub-category" : "New category")
                    .font(.system(size: 16, weight: .semibold))
                TextField("Work, Side projects, Daily…", text: $sectionName).textFieldStyle(.roundedBorder).frame(width: 300)
                HStack {
                    Spacer()
                    Button("Cancel") { namingSectionFor = nil }.keyboardShortcut(.cancelAction)
                    Button(request.item.hasPrefix("rename:") ? "Rename" : "Create") {
                        if request.item.hasPrefix("rename:") {
                            store.renameSection(String(request.item.dropFirst(7)), to: sectionName)
                        } else if request.item.hasPrefix("sub:") {
                            store.addSection(named: sectionName, parentID: String(request.item.dropFirst(4)))
                        } else if request.item.isEmpty {
                            store.addSection(named: sectionName)
                        } else {
                            store.move(request.item, toSection: nil, newSectionName: sectionName)
                        }
                        namingSectionFor = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sectionName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(22)
        }
        .alert("Delete \(confirmingDelete.map(itemName) ?? "")?", isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let item = confirmingDelete { delete(item) }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("Its chat and its routines go too. To keep it working out of sight, hide it instead.")
        }
    }

    private struct NamingRequest: Identifiable { let item: String; var id: String { item } }

    private var routinesSubtitle: String {
        let active = store.routines.filter { !$0.paused }.count
        return store.routines.isEmpty ? "Scheduled jobs" : "\(active) active · \(store.routines.count - active) paused"
    }

    private func iconTile(_ symbol: String) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Image(systemName: symbol).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary)
        }
        .frame(width: 34, height: 34)
    }

    // MARK: Items

    private func itemExists(_ item: String) -> Bool {
        if item == "clicky" { return true }
        if item.hasPrefix("bot:") { return store.bot(String(item.dropFirst(4))) != nil }
        if item.hasPrefix("group:") { return store.group(String(item.dropFirst(6)))?.headID != nil }
        return false
    }

    private func itemName(_ item: String) -> String {
        if item == "clicky" { return "Clicky" }
        if item.hasPrefix("bot:") { return store.bot(String(item.dropFirst(4)))?.name ?? "this bot" }
        return store.group(String(item.dropFirst(6)))?.name ?? "this group chat"
    }

    /// Items in no section, not pinned and not hidden.
    private var looseItems: (groups: [String], bots: [String]) {
        let placed = Set(store.layout.pinned + store.layout.hidden + store.layout.sections.flatMap(\.items))
        let groups = store.groups.filter { $0.headID != nil }.map { "group:\($0.id)" }.filter { !placed.contains($0) }
        let order = BotImport.starters.map(\.id)
        var bots = store.bots.sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
            .map { "bot:\($0.id)" }.filter { !placed.contains($0) }
        if !placed.contains("clicky") { bots.insert("clicky", at: 0) }
        return (groups, bots)
    }

    private func pane(for item: String) -> BotsPane {
        if item == "clicky" { return .clicky }
        if item.hasPrefix("bot:") { return .bot(String(item.dropFirst(4))) }
        let id = String(item.dropFirst(6))
        return id == BotGroup.projectID ? .team : .group(id)
    }

    @ViewBuilder private func itemRow(_ item: String) -> some View {
        Group {
            if item == "clicky" {
                sidebarRow(.clicky, title: "Clicky") { ClickyAvatar(size: 20) }
            } else if item.hasPrefix("bot:"), let bot = store.bot(String(item.dropFirst(4))) {
                sidebarRow(.bot(bot.id), title: bot.name, star: bot.primary, unread: store.unread[bot.id] ?? 0,
                           busy: store.replying[bot.id] != nil, dimmed: !bot.isOn) {
                    BotAvatar(bot: bot, size: 20, state: .idle)
                }
            } else if let group = store.group(String(item.dropFirst(6))) {
                let members = store.members(of: group)
                let busy = members.contains { store.replying[$0.id] != nil }
                sidebarRow(pane(for: item), title: group.name, unread: store.unread[group.roomID] ?? 0, busy: busy) {
                    GroupAvatar(bots: members, size: 20)
                }
            }
        }
        .contextMenu { itemMenu(item) }
        .draggable(item) {
            Text(itemName(item)).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(DS.Colors.accent))
        }
    }

    @ViewBuilder private func itemMenu(_ item: String) -> some View {
        Button(store.isPinned(item) ? "Unpin" : "Pin to top") { store.setPinned(!store.isPinned(item), item) }
        Menu("Move to category") {
            ForEach(store.layout.sections) { section in
                Button(section.name) { store.move(item, toSection: section.id) }
                    .disabled(section.items.contains(item))
            }
            if !store.layout.sections.isEmpty { Divider() }
            Button("New category…") { namingSectionFor = item; sectionName = "" }
            if store.layout.section(of: item) != nil {
                Button("Take out of section") { store.move(item, toSection: nil) }
            }
        }
        if item.hasPrefix("bot:"), let bot = store.bot(String(item.dropFirst(4))) {
            Divider()
            Button("Settings…") {
                selection.pane = .bot(bot.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(name: .theoShowBotSettings, object: nil)
                }
            }
            Button(bot.isOn ? "Turn off" : "Turn on") { store.setEnabled(!bot.isOn, botID: bot.id) }
            if !bot.primary { Button("Make primary") { store.makePrimary(bot.id) } }
        } else if item.hasPrefix("group:"), let group = store.group(String(item.dropFirst(6))) {
            Divider()
            Button("Edit group chat…") { editingGroup = group }
        }
        Divider()
        if store.isHidden(item) {
            Button("Show in sidebar") { store.setHidden(false, item) }
        } else if item != "clicky" {
            Button("Hide from sidebar") { store.setHidden(true, item) }
        }
        if canDelete(item) {
            Button("Delete…", role: .destructive) { confirmingDelete = item }
        }
    }

    private func canDelete(_ item: String) -> Bool {
        if item.hasPrefix("bot:") { return store.bot(String(item.dropFirst(4)))?.primary == false }
        if item.hasPrefix("group:") { return true }
        return false
    }

    private func delete(_ item: String) {
        if selection.pane == pane(for: item) { selection.pane = .home }
        if item.hasPrefix("bot:") { store.deleteBot(String(item.dropFirst(4))) }
        if item.hasPrefix("group:") { store.deleteGroup(String(item.dropFirst(6))) }
    }

    /// A category with its bots and its sub-categories, indented; drop bots on its name to file them.
    private func sectionTree(_ section: BotsLayout.Section, depth: Int) -> AnyView {
        let items = section.items.filter { itemExists($0) && !store.isPinned($0) && !store.isHidden($0) }
        let children = store.subsections(of: section.id)
        let collapsed = section.collapsed ?? false
        return AnyView(VStack(alignment: .leading, spacing: 2) {
            sectionHeader(section, collapsed: collapsed)
            if !collapsed {
                ForEach(items, id: \.self) { item in itemRow(item) }
                ForEach(children) { child in sectionTree(child, depth: depth + 1) }
                if items.isEmpty && children.isEmpty {
                    Text("Drag bots here").font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4])))
                        .padding(.horizontal, 8)
                        .dropTarget { dropped in dropped.forEach { store.move($0, toSection: section.id) } }
                }
            }
        }
        .padding(.leading, depth == 0 ? 0 : 12))
    }

    private func sectionHeader(_ section: BotsLayout.Section, collapsed: Bool) -> some View {
        HStack(spacing: 5) {
            Button { withAnimation(.easeOut(duration: 0.15)) { store.toggleCollapsed(section.id) } } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8.5, weight: .bold))
                    .frame(width: 10)
            }
            .buttonStyle(.plain).foregroundColor(DS.Colors.textTertiary)
            Text(section.name).font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
            Spacer()
            Menu {
                Button("New sub-category…") { namingSectionFor = "sub:\(section.id)"; sectionName = "" }
                Button("Rename…") { namingSectionFor = "rename:\(section.id)"; sectionName = section.name }
                Divider()
                Button("Delete category (keeps its bots)", role: .destructive) { store.deleteSection(section.id) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 10)).foregroundColor(DS.Colors.textTertiary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
        .contentShape(Rectangle())
        .dropTarget { dropped in dropped.forEach { store.move($0, toSection: section.id) } }
    }

    /// Takes an item out of its category (and pins) back to the plain lists.
    private func unfile(_ item: String) {
        store.move(item, toSection: nil)
        store.setPinned(false, item)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
            .contentShape(Rectangle())
    }

    /// One sidebar row (docs/DESIGN.md): 32 pt, a 20 pt tile, the name, and a trailing dot for work or unread.
    private func sidebarRow<Icon: View>(_ pane: BotsPane, title: String, star: Bool = false, unread: Int = 0, busy: Bool = false,
                                        dimmed: Bool = false, @ViewBuilder icon: () -> Icon) -> some View {
        Button { selection.pane = pane } label: {
            HStack(spacing: 8) {
                icon()
                Text(title).font(.system(size: 13, weight: unread > 0 ? .semibold : .medium))
                    .foregroundColor(dimmed ? DS.Colors.textTertiary : DS.Colors.textPrimary).lineLimit(1)
                if star { Image(systemName: "star.fill").font(.system(size: 8)).foregroundColor(DS.Colors.textTertiary) }
                Spacer(minLength: 0)
                if busy {
                    PulseDot(color: DS.Colors.accent)
                } else if unread > 0 {
                    Circle().fill(DS.Colors.textPrimary).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(isSelected: selection.pane == pane))
    }

    private func navLabel(_ symbol: String, _ title: String, shortcut: String? = nil, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundColor(DS.Colors.textSecondary).frame(width: 20)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textTertiary) }
        }
        .padding(.horizontal, 8).frame(height: 30)
        .contentShape(Rectangle())
    }

    private func navRow(_ pane: BotsPane, _ symbol: String, _ title: String, trailing: String? = nil) -> some View {
        Button { selection.pane = pane } label: { navLabel(symbol, title, trailing: trailing) }
            .buttonStyle(SidebarButtonStyle(isSelected: selection.pane == pane))
    }

    /// Bots, groups and Clicky whose name matches the search.
    private var searchResults: [String] {
        let needle = query.lowercased()
        var items: [String] = "clicky".contains(needle) ? ["clicky"] : []
        items += store.bots.filter { $0.name.lowercased().contains(needle) || $0.description.lowercased().contains(needle) }.map { "bot:\($0.id)" }
        items += store.groups.filter { $0.headID != nil && $0.name.lowercased().contains(needle) }.map { "group:\($0.id)" }
        return items
    }

    /// What the settings column shows: the open bot, or Clicky.
    private var inspectorTarget: BotsPane? {
        switch selection.pane {
        case .bot(let id): return store.bot(id) == nil ? nil : .bot(id)
        case .clicky: return .clicky
        case .team: return store.group(BotGroup.projectID)?.headID == nil ? store.primary.map { .bot($0.id) } : nil
        default: return nil
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection.pane {
        case .home:
            TodayView(store: store, selection: selection)
        case .notes:
            NotesScreen()
        case .team:
            if store.group(BotGroup.projectID)?.headID != nil {
                BotChatScreen(store: store, conversationID: BotsStore.teamID, bot: nil, groupID: BotGroup.projectID)
            } else if let primary = store.primary {
                BotChatScreen(store: store, conversationID: primary.id, bot: primary).id(primary.id)
            }
        case .group(let id):
            if let group = store.group(id) {
                BotChatScreen(store: store, conversationID: group.roomID, bot: nil, groupID: id).id(id)
            }
        case .clicky:
            ClickyChatScreen()
        case .bot(let id):
            if let bot = store.bot(id) {
                BotChatScreen(store: store, conversationID: id, bot: bot).id(id)
            }
        case .connectors:
            ConnectorsScreen(bots: store.bots)
        case .routines:
            RoutinesScreen(store: store)
        }
    }
}

// MARK: - Chat

struct BotChatScreen: View {
    @ObservedObject var store: BotsStore
    let conversationID: String
    /// Nil for a group chat.
    let bot: NativeBot?
    /// The group whose chat this is (with no bot).
    var groupID: String? = nil
    @State private var draft = ""
    /// Replies that were there when the chat opened show at once; new ones type in.
    @State private var settledIDs: Set<String> = []
    /// The text each bot last streamed here, so its finished message doesn't type out a second time.
    @State private var lastLive: [String: String] = [:]
    @State private var showsModelSettings = false
    @State private var showsDetails = false
    @State private var editsGroup = false

    private var record: BotConversationRecord { store.conversation(conversationID) }
    private var group: BotGroup? { groupID.flatMap { store.group($0) } }
    private var groupBots: [NativeBot] { group.map { store.members(of: $0) } ?? [] }
    private var isProjectRoom: Bool { groupID == BotGroup.projectID }
    private var inProgress: [(NativeBot, String)] {
        let ids = bot.map { [$0.id] } ?? groupBots.map(\.id)
        return ids.compactMap { id in store.replying[id].flatMap { text in store.bot(id).map { ($0, text) } } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain VStack: a lazy one guesses the heights of long replies it hasn't drawn, and
                    // scrolling to the end then lands in empty space until something redraws.
                    VStack(alignment: .leading, spacing: 18) {
                        if record.messages.isEmpty && inProgress.isEmpty { emptyState }
                        ForEach(Array(record.messages.enumerated()), id: \.element.id) { index, message in
                            if message.author == "user" {
                                UserBubble(text: message.text)
                            } else if message.author == "routine" {
                                RoutineMarker(text: message.text, at: message.at)
                            } else if let author = store.bot(message.author) {
                                BotLine(bot: author, text: message.text,
                                        showsName: index == 0 || record.messages[index - 1].author != message.author,
                                        animatesIn: !settledIDs.contains(message.id), isLive: false)
                                if let runID = message.runID, let run = store.t3Runs.first(where: { $0.id == runID }) {
                                    T3ResultCard(run: run).padding(.leading, 44)
                                }
                                if let prompt = BotsT3.promptBlock(in: message.text) {
                                    let title = BotsT3.projectTitle(in: message.text, prompt: prompt)
                                    T3HandoffButton(text: message.text, room: conversationID, prominent: true,
                                                    alreadySent: store.t3Runs.contains { $0.title == title }
                                                        || record.messages.contains { $0.text.hasPrefix("Submitted to T3 Code: **\(title)**") })
                                }
                            }
                        }
                        if bot == nil || bot?.primary == true {
                            ForEach(store.t3Runs.filter { ($0.phase == "running" || $0.phase == "waiting") && ($0.room ?? BotsStore.teamID) == conversationID }) { run in
                                T3RunCard(run: run)
                            }
                        }
                        ForEach(inProgress, id: \.0.id) { pending in
                            if pending.1.isEmpty {
                                ThinkingLine(bot: pending.0, showsName: bot == nil)
                            } else {
                                BotLine(bot: pending.0, text: pending.1, showsName: record.messages.last?.author != pending.0.id, animatesIn: true, isLive: true)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: record.messages.count) { _, _ in
                    if let last = record.messages.last, let streamed = lastLive[last.author], streamed.count > 20,
                       last.text.hasPrefix(String(streamed.prefix(20))) {
                        // Already typed out live: the saved copy just stays.
                        settledIDs.insert(last.id)
                        lastLive[last.author] = nil
                    }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: inProgress.map { "\($0.0.id):\($0.1.count / 200)" }) { _, _ in
                    for (bot, text) in inProgress where !text.isEmpty { lastLive[bot.id] = text }
                }
                .onChange(of: inProgress.map(\.1.count).reduce(0, +) / 240) { _, _ in
                    // Follows a streaming reply every few lines rather than on every chunk.
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onDisappear { if store.viewing == conversationID { store.viewing = nil } }
                .onAppear {
                    store.viewing = conversationID
                    settledIDs = Set(record.messages.map(\.id))
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            composer
        }
    }

    /// The chat's toolbar (docs/DESIGN.md): avatar, name (opens settings), model, and new chat.
    private var header: some View {
        HStack(spacing: 10) {
            if let bot {
                BotAvatar(bot: bot, size: 24, state: .idle)
                Button { NotificationCenter.default.post(name: .theoShowBotSettings, object: nil) } label: {
                    Text(bot.name).font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                }
                .buttonStyle(.plain).help("Settings for \(bot.name)")
                Text(bot.modelLabel + (bot.effort.map { " · \($0)" } ?? ""))
                    .font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.hover))
                if !bot.isOn {
                    Text("Off").font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textTertiary)
                }
            } else {
                GroupAvatar(bots: groupBots, size: 24)
                Button { editsGroup = true } label: {
                    Text(group?.name ?? "Group chat").font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $editsGroup) {
                    if let group { GroupEditor(store: store, group: group) { _ in editsGroup = false } }
                }
                Text("Led by \(group.flatMap { store.head(of: $0) }?.name ?? "nobody") · \(groupBots.count) bots")
                    .font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Button {
                store.clearConversation(conversationID)
                settledIDs = []
            } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 14)).foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("New chat")
            .disabled(!inProgress.isEmpty)
        }
        // Room on the right for the settings button.
        .padding(.leading, 20).padding(.trailing, 48).frame(height: 52)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if let bot {
                BotAvatar(bot: bot, size: 84, state: .idle)
                Text(bot.name).font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text(bot.description).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center)
            } else if isProjectRoom {
                Text("Group chat").font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text("Theo leads this group: the head hands your request to the others and merges their answers.")
                    .font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center)
            } else if let group, let head = store.head(of: group) {
                BotAvatar(bot: head, size: 84, state: .idle)
                Text("\(group.name) chat").font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text("\(head.name) leads this group: they hand your request to \(Self.list(groupBots.dropFirst().map(\.name))), then merge the answers. Ask them to build something and it goes to \(HarnessCatalog.label(HarnessPrefs.codingTarget)).")
                    .font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "the others" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    @FocusState private var composerFocused: Bool

    /// The composer (docs/DESIGN.md): text on top; under it @-mentions, the model, and send or stop.
    private var composer: some View {
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            TextField(bot.map { "Message \($0.name)" } ?? "Message \(group?.name ?? "the group")",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(send)
            HStack(spacing: 6) {
                Menu {
                    ForEach(mentionable) { member in
                        Button("@\(member.name)") { draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + "@\(member.name) " }
                    }
                    if bot?.primary == true { Button("@T3 (send a change to the coding agent)") { draft += "@T3 " } }
                } label: {
                    Image(systemName: "at").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(mentionable.isEmpty && bot?.primary != true)
                .help("Mention a bot")
                if let bot {
                    Button { NotificationCenter.default.post(name: .theoShowBotSettings, object: nil) } label: {
                        HStack(spacing: 4) {
                            Text(bot.modelLabel).font(.system(size: 12, weight: .medium))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.textSecondary).padding(.horizontal, 8).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.hover))
                    }
                    .buttonStyle(.plain).help("Change the model")
                }
                Spacer()
                if !inProgress.isEmpty && isEmpty {
                    Button {
                        if let bot { store.stop(bot.id) } else if let groupID { store.stopGroup(groupID) }
                    } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
                            .frame(width: 28, height: 28).background(Circle().fill(DS.Colors.surface))
                            .overlay(Circle().strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain).help("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(isEmpty ? DS.Colors.textDisabled : DS.Colors.accent))
                    }
                    .buttonStyle(.plain).disabled(isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(composerFocused ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle, lineWidth: composerFocused ? 1.5 : 1))
        .frame(maxWidth: 720)
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 4)
        .frame(maxWidth: .infinity)
    }

    /// Who an @ can reach from here: the group's bots, or the bots this one may message.
    private var mentionable: [NativeBot] {
        if let bot { return store.reachable(from: bot) }
        return groupBots
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if let bot { store.send(text, to: bot.id) } else if let groupID { store.sendToGroup(text, groupID: groupID) }
    }
}

struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 120)
            Text(text)
                .font(.system(size: 15)).foregroundColor(DS.Colors.textPrimary).lineSpacing(4)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4,
                                                   topTrailingRadius: 16, style: .continuous).fill(DS.Colors.surface))
        }
        .padding(.top, 8)
    }
}

struct ThinkingLine: View {
    let bot: NativeBot
    let showsName: Bool
    @State private var phase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                BotAvatar(bot: bot, size: 28, state: .thinking)
                Text(bot.name).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            }
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(DS.Colors.textTertiary).frame(width: 5, height: 5)
                        .opacity(phase ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(index) * 0.15), value: phase)
                }
            }
            .padding(.leading, 38).frame(height: 20)
        }
        .padding(.top, 8)
        .onAppear { phase = true }
    }
}

struct BotLine: View {
    let bot: NativeBot
    let text: String
    let showsName: Bool
    /// New replies type in; old ones show at once.
    let animatesIn: Bool
    /// Still streaming from the engine.
    let isLive: Bool
    /// The reveal is time-based: `anchorCount` characters were showing at `anchorDate`, and it advances
    /// at `rate` characters a second from there (faster when far behind the stream).
    @State private var anchorDate = Date()
    @State private var anchorCount = 0
    @State private var total = 0
    @State private var rate: Double = 320
    @State private var finished = false

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsName {
                HStack(spacing: 10) {
                    BotAvatar(bot: bot, size: 28, state: typing ? .typing : .idle)
                    Text(bot.name).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                }
                .padding(.top, 8)
            }
            Group {
                if typing {
                    // About 30 redraws a second, and only the paragraph being typed is laid out again:
                    // finished paragraphs are drawn once, with their final formatting.
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { context in
                        typedContent(count: shownCount(at: context.date))
                    }
                } else {
                    RichBlock(text: text).equatable()
                    if !isLive {
                        BotMessageActions(text: text).opacity(hovering ? 1 : 0).padding(.top, 2)
                    }
                }
            }
            .padding(.leading, 38)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(DS.Motion.hover) { hovering = inside } }
        .onAppear {
            total = text.count
            if !animatesIn { finished = true; anchorCount = total }
        }
        .onChange(of: text) { _, newText in
            let now = Date()
            anchorCount = shownCount(at: now)
            anchorDate = now
            total = newText.count
            rate = max(320, Double(total - anchorCount) * 2.5)
        }
        .task(id: total) {
            // Marks the reveal done once it has caught up and the stream has ended.
            while !finished {
                if !isLive && shownCount(at: Date()) >= total { finished = true; break }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private var typing: Bool { animatesIn && !finished }

    private func shownCount(at date: Date) -> Int {
        min(total, anchorCount + Int(date.timeIntervalSince(anchorDate) * rate))
    }

    @ViewBuilder private func typedContent(count: Int) -> some View {
        let shown = String(text.prefix(count))
        let split = shown.range(of: "\n\n", options: .backwards)
        let done = split.map { String(shown[..<$0.lowerBound]) } ?? ""
        let current = split.map { String(shown[$0.upperBound...]) } ?? shown
        VStack(alignment: .leading, spacing: 8) {
            if !done.isEmpty { RichBlock(text: done).equatable() }
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(current).font(.system(size: 15)).foregroundColor(DS.Colors.textPrimary).lineSpacing(5)
                CometCaret(color: bot.accentColor)
            }
        }
    }
}

/// Formatted text that redraws only when its words change.
struct RichBlock: View, Equatable {
    let text: String
    var body: some View { BotRichText(text: text) }
}

/// Inline Markdown (bold, italics, code, links) for finished replies.
enum BotMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Motion

enum BotAvatarState { case idle, thinking, typing }

/// The ten tile colours from docs/DESIGN.md: a soft two-hue gradient each.
enum BotPalette {
    struct Swatch: Identifiable, Equatable { let id: String; let from: UInt32; let to: UInt32 }
    static let swatches: [Swatch] = [
        Swatch(id: "ember", from: 0xF2784B, to: 0xE0476A), Swatch(id: "amber", from: 0xF5B13D, to: 0xE8782E),
        Swatch(id: "lime", from: 0x9BD14B, to: 0x3FA65C), Swatch(id: "teal", from: 0x3FC8B4, to: 0x2E8FB8),
        Swatch(id: "sky", from: 0x4EA8F0, to: 0x4A6FE0), Swatch(id: "indigo", from: 0x6E7BF0, to: 0x8A55E0),
        Swatch(id: "violet", from: 0xA468EB, to: 0xD152B8), Swatch(id: "rose", from: 0xF06A8F, to: 0xE24A58),
        Swatch(id: "slate", from: 0x7C8697, to: 0x4D5666), Swatch(id: "graphite", from: 0x3A3A42, to: 0x1E1E24),
    ]
    /// The swatch nearest a stored hue (bots keep a hue number), Theo always graphite.
    static func swatch(for bot: NativeBot) -> Swatch {
        if bot.id == "theo" && bot.shape == nil { return swatches[9] }
        if let named = swatches.first(where: { $0.id == bot.shape }) { return named }
        let hues: [Double] = [8, 32, 100, 172, 210, 238, 290, 345, 215, 0]
        let target = bot.hue.truncatingRemainder(dividingBy: 360)
        let index = hues.indices.prefix(8).min { abs(hues[$0] - target) < abs(hues[$1] - target) } ?? 0
        return swatches[index]
    }
}

extension NativeBot {
    var bodyColor: Color { Color(hex: BotPalette.swatch(for: self).from) }
    var accentColor: Color { Color(hex: BotPalette.swatch(for: self).from) }
    /// The tile's mark: the glyph picked for the bot, else its initials.
    var monogram: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// A bot's tile: a rounded square in its colour with its glyph or initials (docs/DESIGN.md). While it
/// thinks, a soft ring breathes around it; nothing else moves.
struct BotAvatar: View {
    let bot: NativeBot
    let size: CGFloat
    let state: BotAvatarState
    @State private var breathing = false

    var body: some View {
        let swatch = BotPalette.swatch(for: bot)
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(hex: swatch.from), Color(hex: swatch.to)], startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            if let glyph = bot.glyph, !glyph.isEmpty {
                Image(systemName: glyph).font(.system(size: size * 0.44, weight: .semibold)).foregroundColor(.white.opacity(0.96))
            } else if bot.primary && bot.id == "theo" {
                Text("T").font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.96))
            } else {
                Text(bot.monogram).font(.system(size: size * (bot.monogram.count > 1 ? 0.38 : 0.46), weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.96))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if state != .idle {
                shape.inset(by: -3).stroke(Color(hex: swatch.from).opacity(breathing ? 0.85 : 0.25), lineWidth: 2)
            }
        }
        .opacity(bot.isOn ? 1 : 0.45)
        .onAppear { restart() }
        .onChange(of: state) { _, _ in restart() }
    }

    private func restart() {
        breathing = false
        guard state != .idle else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathing = true }
    }
}

/// Three moons circling while a bot thinks.
struct OrbitingDots: View {
    let color: Color
    @State private var turning = false
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(color.opacity(1 - Double(index) * 0.28)).frame(width: 5, height: 5)
                    .offset(y: -7).rotationEffect(.degrees(Double(index) * 120))
            }
        }
        .frame(width: 18, height: 18)
        .rotationEffect(.degrees(turning ? 360 : 0))
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { turning = true } }
    }
}

/// The glowing dot that leads typed text.
struct CometCaret: View {
    let color: Color
    @State private var pulse = false
    var body: some View {
        // A plain pulsing dot: no blurred shadows to redraw with every typed character.
        Circle().fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulse ? 0.35 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

// MARK: - Connectors

struct ConnectorsScreen: View {
    let bots: [NativeBot]
    @State private var claude: [String: BotConnectors.Status] = [:]
    @State private var openCode: [String: BotConnectors.Status] = [:]
    @State private var checking = true
    @State private var note: String?
    @State private var working: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connectors").font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text("Bots on Claude use your claude.ai connectors. Bots on OpenCode and Grok reach Gmail, Notion and Google through Theo, on the same account, for reading and drafts.")
                        .font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Button(checking ? "Checking…" : "Refresh") { Task { await refresh() } }
                    .disabled(checking).buttonStyle(.borderless).foregroundColor(DS.Colors.textSecondary)
            }
            .padding(20)
            if let note {
                Text(note).font(.system(size: 12)).foregroundColor(DS.Colors.accentText).padding(.horizontal, 20).padding(.bottom, 8)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(BotConnectors.known.filter { $0.id != "calendar" }) { connector in row(connector) }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .task { await refresh() }
    }

    private func row(_ connector: BotConnector) -> some View {
        let users = bots.filter { $0.apps.contains(connector.id) || (connector.id == "notion" && $0.apps.contains("calendar")) }
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07))
                AppLogo(connector: connector, size: 22)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(connector.name).font(.system(size: 13.5, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                Text(users.isEmpty ? "No bot uses it yet" : "Used by " + users.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            if connector.isSkill {
                badge("Skills", .connected)
            } else {
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Claude").font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary)
                        badge(status(claude, connector.claudeServer), status(claude, connector.claudeServer))
                        if !checking && status(claude, connector.claudeServer) != .connected && connector.claudeServer?.hasPrefix("claude.ai") == true {
                            Button("Connect") { BotConnectors.openClaudeConnectors() }.buttonStyle(.borderless).font(.system(size: 11))
                        }
                    }
                    HStack(spacing: 6) {
                        Text("OpenCode & Grok").font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary)
                        if BotConnectors.bridged(connector) && status(openCode, connector.openCodeServer) != .connected {
                            // Reached through Theo's claudia_app tool on the Claude account, read-only.
                            let viaClaude = status(claude, connector.claudeServer)
                            badge(viaClaude == .connected ? "Via Claude" : viaClaude.label, viaClaude)
                        } else {
                            badge(status(openCode, connector.openCodeServer), status(openCode, connector.openCodeServer))
                        }
                        if !checking && !BotConnectors.bridged(connector) && status(openCode, connector.openCodeServer) != .connected && connector.openCodeURL != nil {
                            Button(working == connector.id ? "Signing in…" : "Connect") {
                                working = connector.id
                                Task {
                                    note = await BotConnectors.addToOpenCode(connector)
                                    working = nil
                                    await refresh()
                                }
                            }
                            .buttonStyle(.borderless).font(.system(size: 11)).disabled(working != nil)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.surface1))
    }

    private func status(_ map: [String: BotConnectors.Status], _ name: String?) -> BotConnectors.Status {
        guard let name else { return .missing }
        if checking && map.isEmpty { return .unknown }
        return map[name] ?? .missing
    }

    private func badge(_ status: BotConnectors.Status, _ tone: BotConnectors.Status) -> some View {
        badge(status.label, tone)
    }

    private func badge(_ label: String, _ tone: BotConnectors.Status) -> some View {
        let color: Color = tone == .connected ? .green : tone == .needsSignIn ? .orange : tone == .unknown ? .gray : Color.white.opacity(0.4)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func refresh() async {
        checking = true
        async let claudeListing = BotConnectors.listing(.claude)
        async let openCodeListing = BotConnectors.listing(.opencode)
        let (claudeText, openCodeText) = await (claudeListing, openCodeListing)
        claude = BotConnectors.parseClaude(claudeText)
        openCode = BotConnectors.parseOpenCode(openCodeText)
        checking = false
    }
}

// MARK: - Hand-off to T3 Code

struct T3HandoffButton: View {
    let text: String
    var room: String = BotsStore.teamID
    let prominent: Bool
    var alreadySent = false
    @State private var sentHere = false
    private var sent: Bool { sentHere || alreadySent }

    var body: some View {
        let target = HarnessCatalog.label(HarnessPrefs.codingTarget)
        HStack(spacing: 10) {
            Button {
                let prompt = BotsT3.promptBlock(in: text) ?? text
                BotsStore.shared.submitToT3(prompt: prompt, title: BotsT3.projectTitle(in: text, prompt: prompt), room: room)
                sentHere = true
            } label: {
                Label(sent ? "Sent to \(target)" : "Send to \(target)", systemImage: sent ? "checkmark" : "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(sent ? DS.Colors.surface : DS.Colors.accent))
                    .foregroundColor(sent ? DS.Colors.textSecondary : .white)
            }
            .buttonStyle(.plain)
            .disabled(sent)
            if !sent {
                Button("Change") { TheoSettingsWindowController.show(section: .coding) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
        }
        .padding(.leading, 38)
    }
}

/// A coding run in T3 Code while it works: what it's on, for how long, and a way to watch it there.
struct T3RunCard: View {
    let run: T3Run
    @State private var showsTerminal = true

    private var engine: String { run.harness.map(HarnessCatalog.label) ?? "T3 Code" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    if run.phase == "waiting" {
                        Image(systemName: "questionmark.bubble").foregroundColor(DS.Colors.warning)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        let minutes = max(0, Int(context.date.timeIntervalSince(run.startedAt) / 60))
                        Text(run.phase == "waiting" ? "\(run.title) is waiting for your answer"
                                                    : "Building \(run.title) in \(engine) · \(minutes) min")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        if let activity = run.activity, !activity.isEmpty {
                            Text(activity).font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let session = TerminalSessions.shared.session(for: run.id) {
                        Button { showsTerminal.toggle() } label: {
                            Image(systemName: showsTerminal ? "chevron.up" : "terminal").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundColor(DS.Colors.textSecondary).help(showsTerminal ? "Hide the terminal" : "Show the terminal")
                        Button { TerminalWindowController.pop(sessionID: session.id) } label: {
                            Image(systemName: "arrow.up.forward.square").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundColor(DS.Colors.textSecondary).help("Open in its own window")
                    } else if run.link != nil || run.harness != nil {
                        Button("Watch") { BotsT3.openInApp(run) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                    }
                }
                if showsTerminal, let session = TerminalSessions.shared.session(for: run.id) {
                    // The harness's own terminal, live: watch it work and type into it.
                    TerminalPanel(session: session)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .padding(.leading, 38)
        }
    }
}

/// A bot's engine, model, effort, thinking and fast mode. Changes save as they're made and apply from
/// the bot's next reply.
struct BotModelSettings: View {
    @State var bot: NativeBot
    let onChange: (NativeBot) -> Void
    /// Inside the settings column: no title, and it fits the column's width.
    var compact = false
    @ObservedObject private var catalog = BrainCatalog.shared

    private static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    private static let openCodeEfforts = ["minimal", "low", "medium", "high", "max"]

    private var isClaude: Bool { bot.provider == "claude" }

    private static let grokModels = ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"]
    private static let grokEfforts = ["low", "medium", "high"]

    @ObservedObject private var harnesses = HarnessCenter.shared

    private var models: [String] {
        var listed: [String]
        switch bot.provider {
        case "grok": listed = Self.grokModels
        case "claude": listed = catalog.models[.claude] ?? HarnessCatalog.claudeModels.map(\.id)
        case "opencode": listed = catalog.models[.opencode] ?? harnesses.models(for: "opencode").map(\.id)
        default: listed = harnesses.models(for: bot.provider).map(\.id)
        }
        return listed.contains(bot.model) || bot.model.isEmpty ? listed : [bot.model] + listed
    }

    private var efforts: [String] {
        switch bot.provider {
        case "claude": return Self.claudeEfforts
        case "grok": return Self.grokEfforts
        case "opencode": return Self.openCodeEfforts
        default: return harnesses.efforts(for: bot.provider, model: bot.model)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !compact {
                HStack(spacing: 10) {
                    BotAvatar(bot: bot, size: 26, state: .idle)
                    Text("\(bot.name) · model").font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                }
            }
            row("Engine") {
                Picker("Engine", selection: Binding(get: { bot.provider }, set: { provider in
                    bot.provider = provider
                    bot.model = HarnessPrefs.defaultModel(provider)
                        ?? ["claude": "claude-sonnet-5-5", "grok": "grok-4.6", "opencode": "opencode/deepseek-v4.1-flash-free"][provider]
                        ?? harnesses.models(for: provider).first?.id ?? ""
                    bot.effort = HarnessPrefs.defaultEffort(provider)
                    commit()
                })) {
                    ForEach(HarnessCatalog.botEngines, id: \.id) { info in
                        let status = harnesses.status(for: info.id)
                        Text(info.label + (status.installed ? (status.loggedIn == false ? " (not signed in)" : "") : " (not installed)"))
                            .tag(info.id)
                    }
                }
                .labelsHidden().frame(width: compact ? nil : 260)
            }
            row("Model") {
                if models.isEmpty {
                    TextField("Model id", text: Binding(get: { bot.model }, set: { bot.model = $0; commit() }))
                        .textFieldStyle(.roundedBorder).frame(width: compact ? nil : 260)
                } else {
                    Picker("Model", selection: Binding(get: { bot.model }, set: { bot.model = $0; commit() })) {
                        ForEach(models, id: \.self) { model in
                            Text(harnesses.models(for: bot.provider).first { $0.id == model }?.label ?? NativeBot.label(for: model)).tag(model)
                        }
                    }
                    .labelsHidden().frame(width: compact ? nil : 260)
                }
            }
            row("Effort") {
                Picker("Effort", selection: Binding(get: { bot.effort ?? "" }, set: { bot.effort = $0.isEmpty ? nil : $0; commit() })) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden().frame(width: compact ? nil : 160)
            }
            row("Thinking") {
                Toggle("Thinking", isOn: Binding(get: { bot.thinking ?? false }, set: { bot.thinking = $0; commit() }))
                    .toggleStyle(.switch).labelsHidden().disabled(!isClaude)
            }
            row("Fast mode") {
                Toggle("Fast mode", isOn: Binding(get: { bot.fast ?? false }, set: { bot.fast = $0; commit() }))
                    .toggleStyle(.switch).labelsHidden().disabled(!isClaude)
            }
            Text(isClaude ? "Applies from the next reply." : "Thinking and fast mode are for Claude models.")
                .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 0 : 18)
        .frame(width: compact ? nil : 400)
        .onAppear {
            catalog.load()
            harnesses.refresh()
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary).frame(width: compact ? 62 : 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func commit() { onChange(bot) }
}

extension View {
    /// Accepts sidebar items ("bot:<id>", "group:<id>", "clicky") dragged onto this view, with a highlight.
    func dropTarget(_ perform: @escaping ([String]) -> Void) -> some View {
        modifier(SidebarDropTarget(perform: perform))
    }
}

private struct SidebarDropTarget: ViewModifier {
    let perform: ([String]) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8).fill(isTargeted ? DS.Colors.accent.opacity(0.18) : .clear))
            .dropDestination(for: String.self) { items, _ in
                let valid = items.filter { $0 == "clicky" || $0.hasPrefix("bot:") || $0.hasPrefix("group:") }
                guard !valid.isEmpty else { return false }
                withAnimation(.easeOut(duration: 0.15)) { perform(valid) }
                return true
            } isTargeted: { isTargeted = $0 }
    }
}

/// Sidebar rows: hover and selected fills from the palette, no borders.
struct SidebarButtonStyle: ButtonStyle {
    let isSelected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? DS.Colors.selected : (hovering || configuration.isPressed) ? DS.Colors.hover : .clear))
            .onHover { inside in withAnimation(DS.Motion.hover) { hovering = inside } }
    }
}

/// A small dot that breathes while a bot works.
struct PulseDot: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6).opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true } }
    }
}

extension Notification.Name {
    /// Opens the bot settings slide-over (the bot's name in the chat header sends it).
    static let theoShowBotSettings = Notification.Name("TheoShowBotSettings")
}
