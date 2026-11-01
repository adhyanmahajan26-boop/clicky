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
    /// A category's team page: its members, leader and reports to the CEO.
    case category(String)
    case bot(String)
    /// Clicky's own chat: Theo's on-screen companion.
    case clicky
    case routines
    case connectors
    /// A page of Settings, in this window.
    case settings(SettingsTab.Section)
}

@MainActor
final class BotsSelection: ObservableObject {
    static let shared = BotsSelection()
    @Published var pane: BotsPane = .home
    /// Where "Back to Theo" returns to.
    private var paneBeforeSettings: BotsPane = .home

    func openSettings(_ section: SettingsTab.Section) {
        if case .settings = pane {} else { paneBeforeSettings = pane }
        pane = .settings(section)
    }

    func closeSettings() { pane = paneBeforeSettings }
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
            if case .settings(let section) = selection.pane {
                SettingsSidebar(selection: selection, current: section)
            } else {
                sidebar
            }
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
        .modifier(TheoAppearanceRoot())
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
                        Button(action: newCategory) { Label("New category", systemImage: "folder.badge.plus") }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 28, height: 30).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("New group chat or category")
                }
                HStack(spacing: 8) {
                    NavIcon(symbol: "magnifyingglass")
                    TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(DS.Colors.textTertiary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).frame(height: 36)
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
                        sectionTitle("Pinned").dropTarget { items in items.forEach { store.setPinned(true, $0) } }
                        ForEach(pinned, id: \.self) { item in itemRow(item) }
                        let loose = looseItems
                        sectionTitle("Categories", add: ("New category", newCategory))
                        ForEach(store.rootSections) { section in sectionTree(section, depth: 0) }
                        if store.rootSections.isEmpty {
                            emptyHint("Make a category, add bots, pick a leader", action: newCategory)
                        }
                        sectionTitle("Bots", add: ("New bot", { addingBot = true }))
                            .dropTarget { items in items.forEach { unfile($0) } }
                        ForEach(loose.bots, id: \.self) { item in itemRow(item) }
                        if loose.bots.isEmpty {
                            emptyHint("Make a bot from a stencil") { addingBot = true }
                        }
                        sectionTitle("Group chats", add: ("New group chat", { editingGroup = Self.blankGroup }))
                            .dropTarget { items in items.forEach { unfile($0) } }
                        ForEach(loose.groups, id: \.self) { item in itemRow(item) }
                        if loose.groups.isEmpty {
                            emptyHint("Start a group chat with a head bot") { editingGroup = Self.blankGroup }
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
                Button { selection.openSettings(.look) } label: { navLabel("gearshape", "Settings", shortcut: "⌘,") }
                    .buttonStyle(SidebarButtonStyle(isSelected: false))
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
            Circle().fill(DS.Colors.hover)
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
                sidebarRow(.bot(bot.id), title: bot.name, star: bot.primary, leads: store.layout.sections.contains { $0.leaderID == bot.id },
                           unread: store.unread[bot.id] ?? 0,
                           busy: store.replying[bot.id] != nil, dimmed: !bot.isOn) {
                    BotAvatar(bot: bot, size: 22, state: store.replying[bot.id] != nil ? .thinking : .idle)
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
                ForEach(items, id: \.self) { item in itemRow(item).padding(.leading, 14) }
                ForEach(children) { child in sectionTree(child, depth: depth + 1) }
                if items.isEmpty && children.isEmpty {
                    Text("Drag bots here").font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.Colors.hover, style: StrokeStyle(lineWidth: 1, dash: [4])))
                        .padding(.horizontal, 8)
                        .dropTarget { dropped in dropped.forEach { store.move($0, toSection: section.id) } }
                }
            }
        }
        .padding(.leading, depth == 0 ? 0 : 12))
    }

    private func sectionHeader(_ section: BotsLayout.Section, collapsed: Bool) -> some View {
        let leader = section.leaderID.flatMap { store.bot($0) }
        let members = store.members(of: section)
        let busy = members.contains { store.replying[$0.id] != nil }
        return HStack(spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.15)) { store.toggleCollapsed(section.id) } } label: {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(DS.Colors.textTertiary)
            Button { selection.pane = .category(section.id) } label: {
                HStack(spacing: 8) {
                    CategoryTile(section: section, size: 20)
                    Text(section.name).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    if leader != nil {
                        Image(systemName: "crown.fill").font(.system(size: 8.5)).foregroundColor(Color(hex: 0xF5B13D)).help("Led by \(leader!.name)")
                    }
                    Spacer(minLength: 0)
                    if busy { PulseDot(color: DS.Colors.accent) } else {
                        Text("\(members.count)").font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textTertiary)
                    }
                }
                .padding(.horizontal, 6).frame(height: 32).contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle(isSelected: selection.pane == .category(section.id)))
            .contextMenu {
                Button("Open team page") { selection.pane = .category(section.id) }
                Menu("Leader") {
                    Button("No leader (everyone reports)") { store.setLeader(nil, of: section.id) }
                    ForEach(members) { bot in Button(bot.name) { store.setLeader(bot.id, of: section.id) } }
                }
                Button("Report to the CEO now") { store.reportToCEO(section.id) }.disabled(members.isEmpty)
                Divider()
                Button("New sub-category…") { namingSectionFor = "sub:\(section.id)"; sectionName = "" }
                Button("Rename…") { namingSectionFor = "rename:\(section.id)"; sectionName = section.name }
                Divider()
                Button("Delete category (keeps its bots)", role: .destructive) {
                    if selection.pane == .category(section.id) { selection.pane = .home }
                    store.deleteSection(section.id)
                }
            }
        }
        .padding(.top, 2)
        .dropTarget { dropped in dropped.forEach { store.move($0, toSection: section.id) } }
    }

    /// A new category opens straight on its page, where it's named and filled.
    private func newCategory() {
        let count = store.layout.sections.count
        if let id = store.addSection(named: count == 0 ? "New category" : "New category \(count + 1)") {
            selection.pane = .category(id)
        }
    }

    /// Takes an item out of its category (and pins) back to the plain lists.
    private func unfile(_ item: String) {
        store.move(item, toSection: nil)
        store.setPinned(false, item)
    }

    private func sectionTitle(_ title: String, add: (help: String, action: () -> Void)? = nil,
                              more: (help: String, action: () -> Void)? = nil) -> some View {
        HStack(spacing: 2) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(DS.Colors.textTertiary)
            Spacer()
            ForEach(Array([more.map { ("folder.badge.plus", $0) }, add.map { ("plus", $0) }].compactMap { $0 }.enumerated()), id: \.offset) { _, button in
                Button(action: button.1.action) {
                    MotionSymbol(name: button.0, size: 11, weight: .semibold)
                        .frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(button.1.help)
            }
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.top, 18).padding(.bottom, 4)
        .contentShape(Rectangle())
    }

    /// A quiet "+ …" row under an empty section, so every feature shows from the first launch.
    private func emptyHint(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.Colors.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                Text(text).font(.system(size: 12.5))
            }
            .foregroundColor(DS.Colors.textTertiary).padding(.horizontal, 7).frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(isSelected: false))
    }

    /// One sidebar row (docs/DESIGN.md): 32 pt, a 20 pt tile, the name, and a trailing dot for work or unread.
    private func sidebarRow<Icon: View>(_ pane: BotsPane, title: String, star: Bool = false, leads: Bool = false, unread: Int = 0, busy: Bool = false,
                                        dimmed: Bool = false, @ViewBuilder icon: () -> Icon) -> some View {
        Button { selection.pane = pane } label: {
            HStack(spacing: 8) {
                icon()
                Text(title).font(.system(size: 13, weight: unread > 0 ? .semibold : .medium))
                    .foregroundColor(dimmed ? DS.Colors.textTertiary : DS.Colors.textPrimary).lineLimit(1)
                if star { Text("CEO").font(.system(size: 8.5, weight: .bold)).foregroundColor(DS.Colors.accent) }
                if leads { Image(systemName: "crown.fill").font(.system(size: 8.5)).foregroundColor(Color(hex: 0xF5B13D)) }
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

    private func navLabel(_ symbol: String, _ title: String, shortcut: String? = nil, trailing: String? = nil, active: Bool = false) -> some View {
        HStack(spacing: 8) {
            NavIcon(symbol: symbol, active: active)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textTertiary) }
        }
        .padding(.horizontal, 8).frame(height: 36)
        .contentShape(Rectangle())
    }

    private func navRow(_ pane: BotsPane, _ symbol: String, _ title: String, trailing: String? = nil) -> some View {
        Button { selection.pane = pane } label: { navLabel(symbol, title, trailing: trailing, active: selection.pane == pane) }
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
        case .category(let id):
            CategoryScreen(store: store, selection: selection, sectionID: id).id(id)
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
        case .settings(let section):
            SettingsPage(section: section)
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
    @State private var attachments: [URL] = []

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
                                    T3ResultCard(run: run).padding(.leading, 38)
                                }
                                if let prompt = BotsT3.promptBlock(in: message.text) {
                                    let title = BotsT3.projectTitle(in: message.text, prompt: prompt)
                                    T3HandoffButton(text: message.text, room: conversationID, prominent: true,
                                                    alreadySent: store.t3Runs.contains { $0.prompt == prompt || ($0.prompt == nil && $0.title == title) })
                                }
                            }
                        }
                        ForEach(store.t3Runs.filter { ($0.phase == "running" || $0.phase == "waiting" || $0.phase == "reporting") && ($0.room ?? BotsStore.teamID) == conversationID }) { run in
                            T3RunCard(run: run)
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
                // A reply typing itself out, or a card opening under it, keeps the newest line in view.
                .defaultScrollAnchor(.bottom)
                .onChange(of: record.messages.count) { _, _ in
                    if let last = record.messages.last, let streamed = lastLive[last.author], streamed.count > 20,
                       last.text.hasPrefix(String(streamed.prefix(20))) {
                        // Already typed out live: the saved copy just stays.
                        settledIDs.insert(last.id)
                        lastLive[last.author] = nil
                    }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                    // Once more when a tall card under the new message has been laid out.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("end", anchor: .bottom) }
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
                BotAvatar(bot: bot, size: 34, state: inProgress.isEmpty ? .idle : .thinking)
                Button { NotificationCenter.default.post(name: .theoShowBotSettings, object: nil) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(bot.name).font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                            if bot.primary {
                                Text("PRIMARY").font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundColor(DS.Colors.accent)
                                    .padding(.horizontal, 5).frame(height: 16)
                                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.Colors.accent.opacity(0.14)))
                            }
                        }
                        HStack(spacing: 5) {
                            Circle().fill(!bot.isOn ? DS.Colors.textDisabled : inProgress.isEmpty ? DS.Colors.success : DS.Colors.warning)
                                .frame(width: 6, height: 6)
                            Text(statusLine(for: bot)).font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain).help("Settings for \(bot.name)")
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
        .padding(.leading, 20).padding(.trailing, 48).frame(height: 60)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1) }
    }

    /// "Working · Claude Sonnet 5.5 · high · 2 routines" under the bot's name.
    private func statusLine(for bot: NativeBot) -> String {
        var parts = [!bot.isOn ? "Off" : inProgress.isEmpty ? "Ready" : "Working"]
        parts.append(bot.modelLabel)
        if let effort = bot.effort { parts.append(effort) }
        for team in store.categories(of: bot.id) {
            parts.append(team.leaderID == bot.id ? "Leads \(team.name)" : "In \(team.name)")
        }
        let routines = store.routines.filter { $0.target == bot.id && !$0.paused }.count
        if routines > 0 { parts.append("\(routines) routine" + (routines == 1 ? "" : "s")) }
        return parts.joined(separator: " · ")
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
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { file in
                            HStack(spacing: 5) {
                                Image(systemName: "doc.fill").font(.system(size: 10)).foregroundColor(DS.Colors.textTertiary)
                                Text(file.lastPathComponent).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                                Button { attachments.removeAll { $0 == file } } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(DS.Colors.textTertiary).frame(width: 14, height: 14).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).help("Remove")
                            }
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(Capsule().fill(DS.Colors.hover))
                        }
                    }
                }
            }
            TextField(bot.map { "Message \($0.name)" } ?? "Message \(group?.name ?? "the group")",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(send)
            HStack(spacing: 6) {
                Button(action: chooseAttachments) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Attach files")
                Menu {
                    ForEach(mentionable) { member in
                        Button("@\(member.name)") { draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + "@\(member.name) " }
                    }
                    Button("@code (straight to the coding agent)") { draft += "@code " }
                } label: {
                    Image(systemName: "at").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Mention a bot, or send work to the coding agent")
                if let bot {
                    Menu {
                        ForEach(BotModels.list(for: bot), id: \.self) { model in
                            Toggle(BotModels.label(model, on: bot.provider), isOn: Binding(get: { bot.model == model }, set: { _ in
                                var edited = bot
                                edited.model = model
                                store.save(edited)
                            }))
                        }
                        Divider()
                        Button("Engine and more…") { NotificationCenter.default.post(name: .theoShowBotSettings, object: nil) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(bot.modelLabel).font(.system(size: 12, weight: .medium))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.textSecondary).padding(.horizontal, 8).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.hover))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Change the model")
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
                    .buttonStyle(.plain).disabled(isEmpty).help("Send")
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
        .dropDestination(for: URL.self) { files, _ in
            let local = files.filter(\.isFileURL)
            attachments += local.filter { !attachments.contains($0) }
            return !local.isEmpty
        }
    }

    /// Who an @ can reach from here: the group's bots, or the bots this one may message.
    private var mentionable: [NativeBot] {
        if let bot { return store.reachable(from: bot) }
        return groupBots
    }

    private func send() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !attachments.isEmpty else { return }
        // A group with a bare API in it gets the text of small files, since that bot can't open a path.
        let engine = bot?.provider ?? (groupBots.contains { $0.provider.hasPrefix("api:") } ? "api:" : "claude")
        let text = typed + BotAttachments.promptText(for: attachments, on: engine)
        draft = ""
        attachments = []
        if let bot { store.send(text, command: typed, to: bot.id) } else if let groupID { store.sendToGroup(text, command: typed, groupID: groupID) }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        attachments += panel.urls.filter { !attachments.contains($0) }
    }
}

/// Files attached to a message. Engines with file tools get their paths to read. An engine with no tools (a bare API)
/// gets the text of small text files in the message itself.
enum BotAttachments {
    static let inlineLimit = 40_000

    static func promptText(for files: [URL], on provider: String) -> String {
        guard !files.isEmpty else { return "" }
        let lines = files.map { "- \($0.path)" }.joined(separator: "\n")
        guard provider.hasPrefix("api:") else { return "\n\nAttached (read these):\n\(lines)" }
        var text = ""
        for file in files {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            if size <= inlineLimit * 4, let body = try? String(contentsOf: file, encoding: .utf8), body.count <= inlineLimit {
                text += "\n\nAttached file \(file.lastPathComponent):\n```\n\(body)\n```"
            } else {
                text += "\n\nAttached file \(file.lastPathComponent) can't be read on this engine (too big, or not text)."
            }
        }
        return text
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                BotAvatar(bot: bot, size: 28, state: .thinking)
                Text(bot.name).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            }
            TypingDots().padding(.leading, 38)
        }
        .padding(.top, 8)
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

    /// A timeline's date can be a moment before the anchor, so this never goes below what was already showing.
    private func shownCount(at date: Date) -> Int {
        min(total, anchorCount + Int(max(0, date.timeIntervalSince(anchorDate)) * rate))
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
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(hex: swatch.from), Color(hex: swatch.to)], startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                BotFace(seed: bot.id, isTheo: bot.id == "theo", size: size, awake: state != .idle)
            } else {
                // Alive: it blinks, glances around and bobs; while it works its eyes scan and glow.
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { timeline in
                    BotFace(seed: bot.id, isTheo: bot.id == "theo", size: size, awake: state != .idle && bot.isOn,
                            time: bot.isOn ? timeline.date.timeIntervalSinceReferenceDate : 0)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            // The glyph picked for the bot rides on a small badge.
            if size >= 30, let glyph = bot.glyph, !glyph.isEmpty {
                Image(systemName: glyph).font(.system(size: size * 0.2, weight: .bold)).foregroundColor(Color(hex: swatch.to))
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().strokeBorder(DS.Colors.background, lineWidth: 1.5))
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
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

/// A little robot face, the same for a bot every time (picked from its id): eyes, mouth and antenna.
/// Theo wears an ember visor. While the bot works, its eyes glow brighter.
struct BotFace: View {
    let seed: String
    let isTheo: Bool
    let size: CGFloat
    var awake = false
    /// Seconds on a running clock; nil draws it still.
    var time: Double? = nil

    private var phase: Double {
        Double(seed.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }) / 6553.5
    }

    private var traits: (eyes: Int, mouth: Int, antenna: Int) {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return (Int(hash % 5), Int((hash / 5) % 4), Int((hash / 20) % 3))
    }

    var body: some View {
        Canvas { context, canvas in
            let w = canvas.width
            let eye = Color.white
            let dark = Color.black.opacity(0.32)
            let (eyes, mouth, antenna) = isTheo ? (2, 3, 1) : traits
            let t = (time ?? 0) + phase
            let moving = time != nil
            // A gentle bob of the whole face, a blink every few seconds, and a glance left or right.
            let bob = moving ? sin(t * 1.8) * w * 0.018 : 0
            let period = 3.4 + phase.truncatingRemainder(dividingBy: 1.6)
            let blinkPhase = t.truncatingRemainder(dividingBy: period)
            let blink = moving && blinkPhase < 0.16 ? max(0.12, abs(blinkPhase - 0.08) / 0.08) : 1
            let glance: Double = {
                guard moving else { return 0 }
                if awake { return sin(t * 3.2) * w * 0.035 }
                let slot = Int(t / 2.6) % 4
                return [0, w * 0.03, 0, -w * 0.03][slot]
            }()
            context.translateBy(x: 0, y: bob)
            // Antenna.
            if size >= 18 && antenna > 0 {
                var stem = Path()
                stem.move(to: CGPoint(x: w * 0.5, y: w * 0.17)); stem.addLine(to: CGPoint(x: w * 0.5, y: w * 0.07))
                context.stroke(stem, with: .color(eye.opacity(0.85)), lineWidth: max(1, w * 0.035))
                let r = w * (antenna == 1 ? 0.055 : 0.04)
                let pulse = moving ? (awake ? 0.55 + 0.45 * (sin(t * 6) * 0.5 + 0.5) : 0.75 + 0.25 * sin(t * 1.3)) : 1
                context.fill(Path(ellipseIn: CGRect(x: w * 0.5 - r, y: w * 0.07 - r, width: r * 2, height: r * 2)),
                             with: .color((isTheo ? Color(hex: 0xFF8A5B) : eye).opacity(pulse)))
            }
            // Face plate.
            let plate = CGRect(x: w * 0.17, y: w * 0.24, width: w * 0.66, height: w * 0.56)
            context.fill(Path(roundedRect: plate, cornerRadius: w * 0.16, style: .continuous), with: .color(dark))
            let eyeColor = isTheo ? Color(hex: 0xFF8A5B) : eye
            let glow = awake ? 1.0 : 0.92
            let cy = plate.minY + plate.height * 0.42
            var eyeLayer = context
            eyeLayer.translateBy(x: glance, y: cy)
            eyeLayer.scaleBy(x: 1, y: blink)
            eyeLayer.translateBy(x: 0, y: -cy)
            if awake {
                // The eyes glow while it works.
                eyeLayer.addFilter(.shadow(color: eyeColor.opacity(0.9), radius: w * 0.06))
            }
            switch eyes {
            case 0: // round eyes
                for x in [0.38, 0.62] {
                    let r = w * 0.065
                    eyeLayer.fill(Path(ellipseIn: CGRect(x: w * x - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(eyeColor.opacity(glow)))
                }
            case 1: // tall eyes
                for x in [0.39, 0.61] {
                    eyeLayer.fill(Path(roundedRect: CGRect(x: w * x - w * 0.045, y: cy - w * 0.09, width: w * 0.09, height: w * 0.18), cornerRadius: w * 0.045),
                                 with: .color(eyeColor.opacity(glow)))
                }
            case 2: // visor
                let visor = CGRect(x: plate.minX + w * 0.07, y: cy - w * 0.055, width: plate.width - w * 0.14, height: w * 0.11)
                eyeLayer.fill(Path(roundedRect: visor, cornerRadius: w * 0.055), with: .color(eyeColor.opacity(glow)))
                for x in [0.4, 0.6] {
                    let r = w * 0.03
                    eyeLayer.fill(Path(ellipseIn: CGRect(x: w * x - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(.white))
                }
            case 3: // happy arcs
                for x in [0.39, 0.61] {
                    var arc = Path()
                    arc.addArc(center: CGPoint(x: w * x, y: cy + w * 0.03), radius: w * 0.07, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                    eyeLayer.stroke(arc, with: .color(eyeColor.opacity(glow)), style: StrokeStyle(lineWidth: max(1.2, w * 0.05), lineCap: .round))
                }
            default: // one big eye
                let r = w * 0.11
                eyeLayer.fill(Path(ellipseIn: CGRect(x: w * 0.5 - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(eyeColor.opacity(glow)))
                let p = w * 0.045
                eyeLayer.fill(Path(ellipseIn: CGRect(x: w * 0.5 - p, y: cy - p, width: p * 2, height: p * 2)), with: .color(.black.opacity(0.55)))
            }
            // Mouth.
            guard size >= 18 else { return }
            let my = plate.minY + plate.height * 0.76
            switch mouth {
            case _ where awake && moving:
                // Talking while it works.
                let open = (sin(t * 11) * 0.5 + 0.5) * w * 0.06 + w * 0.015
                context.fill(Path(roundedRect: CGRect(x: w * 0.44, y: my - open / 2, width: w * 0.12, height: open), cornerRadius: open / 2),
                             with: .color(eye.opacity(0.85)))
            case 0:
                var line = Path(); line.move(to: CGPoint(x: w * 0.43, y: my)); line.addLine(to: CGPoint(x: w * 0.57, y: my))
                context.stroke(line, with: .color(eye.opacity(0.8)), style: StrokeStyle(lineWidth: max(1, w * 0.035), lineCap: .round))
            case 1:
                var smile = Path()
                smile.addArc(center: CGPoint(x: w * 0.5, y: my - w * 0.05), radius: w * 0.07, startAngle: .degrees(30), endAngle: .degrees(150), clockwise: false)
                context.stroke(smile, with: .color(eye.opacity(0.85)), style: StrokeStyle(lineWidth: max(1, w * 0.035), lineCap: .round))
            case 2:
                for i in 0..<3 {
                    let r = w * 0.016
                    context.fill(Path(ellipseIn: CGRect(x: w * (0.44 + Double(i) * 0.06) - r, y: my - r, width: r * 2, height: r * 2)), with: .color(eye.opacity(0.8)))
                }
            default:
                context.fill(Path(roundedRect: CGRect(x: w * 0.42, y: my - w * 0.02, width: w * 0.16, height: w * 0.04), cornerRadius: w * 0.02),
                             with: .color(eyeColor.opacity(0.75)))
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
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
            AppLogo(connector: connector, size: 36)
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

/// A bot's finished build prompt, ready to go: which harness, which folder, and Start.
struct T3HandoffButton: View {
    let text: String
    var room: String = BotsStore.teamID
    let prominent: Bool
    var alreadySent = false
    @ObservedObject private var center = HarnessCenter.shared
    @ObservedObject private var keys = ProviderKeys.shared
    @State private var sentHere = false
    @State private var harness = HarnessPrefs.codingTarget
    @State private var folder: URL?
    private var sent: Bool { sentHere || alreadySent }

    /// The folder from the message itself, when it names one.
    private var namedFolder: URL? { BotsT3.targetRepo(answer: text, pitch: "") }

    var body: some View {
        let target = folder ?? namedFolder
        VStack(alignment: .leading, spacing: 8) {
            if sent {
                Label("Sent to \(HarnessCatalog.label(harness))", systemImage: "checkmark").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
            } else {
                HStack(spacing: 8) {
                    BrandLogo(id: harness, name: HarnessCatalog.label(harness), size: 24)
                    Picker("Run on", selection: $harness) {
                        ForEach(HarnessCatalog.codingTargets, id: \.id) { info in
                            let status = center.status(for: info.id)
                            Text(info.label + (status.installed ? "" : " (not installed)")).tag(info.id)
                        }
                        if keys.hasKey(for: "cursor") { Text("Cursor cloud agent").tag(CursorCloud.harnessID) }
                    }
                    .labelsHidden().frame(width: 180)
                    Button { chooseFolder() } label: {
                        Label(target?.lastPathComponent ?? "Choose a folder…", systemImage: "folder").lineLimit(1)
                    }
                    .buttonStyle(.theo(.secondary, .small))
                    .help(target?.path ?? "A git repo gets its own branch and a draft PR. A plain folder is edited in place.")
                    Spacer(minLength: 0)
                    Button { start(in: target) } label: { Label(target == nil ? "Start as a new project" : "Start run", systemImage: "play.fill") }
                        .buttonStyle(.theo(.primary, .small))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            }
        }
        .padding(.leading, 38)
        .onAppear { center.refresh() }
    }

    private func start(in target: URL?) {
        let prompt = BotsT3.promptBlock(in: text) ?? text
        BotsStore.shared.submitToT3(prompt: prompt, title: BotsT3.projectTitle(in: text, prompt: prompt), repo: target, room: room, harness: harness)
        sentHere = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        folder = chosen
    }
}

/// A coding run while it works: its harness, status, time so far, the live terminal, Stop and pop out.
struct T3RunCard: View {
    let run: T3Run
    @ObservedObject private var terminals = TerminalSessions.shared
    @State private var showsTerminal = true
    @State private var confirmsStop = false

    private var engine: String { run.harness.map(HarnessCatalog.label) ?? "T3 Code" }
    private var session: TerminalSession? { terminals.session(for: run.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                BrandLogo(id: run.harness ?? "t3", name: engine, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    Text(detailLine).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    StatusPill(text: (run.phase == "waiting" ? "Waiting for you · " : run.phase == "reporting" ? "Finishing up · " : "Working · ") + Self.elapsed(since: run.startedAt, now: context.date),
                               tone: run.phase == "waiting" ? .warn : .info, busy: run.phase != "waiting")
                }
                if session != nil {
                    Button { showsTerminal.toggle() } label: { Image(systemName: showsTerminal ? "chevron.up" : "terminal").frame(width: 14) }
                        .buttonStyle(.theo(.ghost, .small)).help(showsTerminal ? "Hide the terminal" : "Show the terminal")
                    Button { TerminalWindowController.pop(sessionID: run.id) } label: { Image(systemName: "arrow.up.forward.square").frame(width: 14) }
                        .buttonStyle(.theo(.ghost, .small)).help("Open in its own window")
                } else if run.link != nil || run.harness != nil {
                    Button("Watch") { BotsT3.openInApp(run) }.buttonStyle(.theo(.secondary, .small))
                }
                if run.phase != "reporting" {
                    Button { confirmsStop = true } label: { Image(systemName: "stop.fill").frame(width: 14) }
                        .buttonStyle(.theo(.ghost, .small)).help(run.harness == nil ? "Stop following this run" : "Stop this run")
                }
            }
            if let activity = run.activity, !activity.isEmpty, session == nil || !showsTerminal {
                Text(activity).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(2)
            }
            if showsTerminal, let session {
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
        .alert("Stop this run?", isPresented: $confirmsStop) {
            Button("Stop", role: .destructive) { BotsStore.shared.stopRun(run.id) }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text(run.harness == nil ? "T3 Code keeps its thread: open it there to stop the agent. Theo stops following it here." : "The agent stops now. What it did so far stays on its branch.")
        }
    }

    private var detailLine: String {
        var parts = [engine]
        if let model = run.model { parts.append(NativeBot.label(for: model)) }
        if let branch = run.branch { parts.append(branch) } else { parts.append(URL(fileURLWithPath: run.folder).lastPathComponent) }
        return parts.joined(separator: " · ")
    }

    /// "4:07", "1:02:30".
    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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

    static let grokModels = ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"]
    private static let grokEfforts = ["low", "medium", "high"]

    @ObservedObject private var harnesses = HarnessCenter.shared
    @ObservedObject private var keys = ProviderKeys.shared

    private var models: [String] { BotModels.list(for: bot) }

    private var efforts: [String] {
        if bot.provider.hasPrefix("api:") { return [] }
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
                    if provider == "__add_key" {
                        TheoSettingsWindowController.show(section: .keys)
                        return
                    }
                    bot.provider = provider
                    if provider.hasPrefix("api:") {
                        let info = ProviderInfo.info(for: String(provider.dropFirst(4)))
                        bot.model = info.flatMap { keys.models(for: $0).first } ?? ""
                        bot.effort = nil
                    } else {
                        bot.model = BotModels.startingModel(for: provider)
                        bot.effort = HarnessPrefs.defaultEffort(provider)
                    }
                    commit()
                })) {
                    Section("Subscriptions") {
                        ForEach(HarnessCatalog.botEngines, id: \.id) { info in
                            let status = harnesses.status(for: info.id)
                            Text(info.label + (status.installed ? (status.loggedIn == false ? " (not signed in)" : "") : " (not installed)"))
                                .tag(info.id)
                        }
                    }
                    Section("API keys") {
                        ForEach(keys.usableChatProviders) { provider in
                            Text(provider.label).tag("api:\(provider.id)")
                        }
                        if bot.provider.hasPrefix("api:"), !keys.usableChatProviders.contains(where: { "api:\($0.id)" == bot.provider }) {
                            Text("\(String(bot.provider.dropFirst(4))) (no key)").tag(bot.provider)
                        }
                        Text("Add a key…").tag("__add_key")
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
                            Text(BotModels.label(model, on: bot.provider)).tag(model)
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
