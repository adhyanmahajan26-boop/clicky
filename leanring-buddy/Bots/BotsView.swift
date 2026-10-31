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
    @Published var pane: BotsPane = .bot("theo")
}

struct BotsRootView: View {
    @ObservedObject var store: BotsStore
    @ObservedObject var selection: BotsSelection
    /// Inside Theo's home window, Connectors is its own tab instead.
    var showsConnectors = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.white.opacity(0.06))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
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
            HStack {
                Text("Bots").font(.system(size: 15, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Menu {
                    Button { addingBot = true } label: { Label("New bot", systemImage: "plus.circle") }
                        .keyboardShortcut("n", modifiers: .command)
                    Button { editingGroup = Self.blankGroup } label: { Label("New group chat", systemImage: "person.2.badge.plus") }
                    Divider()
                    Button { namingSectionFor = ""; sectionName = "" } label: { Label("New section", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.08)))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("New bot (⌘N), group chat or section")
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let pinned = store.layout.pinned.filter(itemExists)
                    if !pinned.isEmpty {
                        sectionTitle("Pinned")
                        ForEach(pinned, id: \.self) { item in itemRow(item) }
                    }
                    ForEach(store.layout.sections) { section in
                        let items = section.items.filter { itemExists($0) && !store.isPinned($0) && !store.isHidden($0) }
                        sectionHeader(section)
                        ForEach(items, id: \.self) { item in itemRow(item) }
                        if items.isEmpty {
                            Text("Right-click a bot › Move to section").font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary)
                                .padding(.horizontal, 12).padding(.vertical, 2)
                        }
                    }
                    let loose = looseItems
                    if !loose.groups.isEmpty {
                        sectionTitle("Group chats")
                        ForEach(loose.groups, id: \.self) { item in itemRow(item) }
                    }
                    if !loose.bots.isEmpty {
                        sectionTitle("Bots")
                        ForEach(loose.bots, id: \.self) { item in itemRow(item) }
                    }
                    let hidden = store.layout.hidden.filter(itemExists)
                    if !hidden.isEmpty {
                        Button { withAnimation(.easeOut(duration: 0.15)) { showsHidden.toggle() } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showsHidden ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                                Text("HIDDEN BOTS · \(hidden.count)").font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                            }
                            .foregroundColor(DS.Colors.textTertiary).padding(.horizontal, 10).padding(.top, 12)
                        }
                        .buttonStyle(.plain)
                        if showsHidden { ForEach(hidden, id: \.self) { item in itemRow(item).opacity(0.6) } }
                    }
                }
                .padding(.bottom, 8)
            }
            Divider().overlay(Color.white.opacity(0.06))
            VStack(spacing: 2) {
                sidebarRow(.routines, title: "Routines", subtitle: routinesSubtitle) {
                    iconTile("clock.arrow.circlepath")
                }
                if showsConnectors {
                    sidebarRow(.connectors, title: "Connectors", subtitle: "Gmail, Notion and more") {
                        iconTile("point.3.connected.trianglepath.dotted")
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 6)
        .frame(width: 256)
        .background(DS.Colors.surface1)
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
                Text("New section").font(.system(size: 16, weight: .semibold))
                TextField("Work, Side projects, Daily…", text: $sectionName).textFieldStyle(.roundedBorder).frame(width: 300)
                HStack {
                    Spacer()
                    Button("Cancel") { namingSectionFor = nil }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        if request.item.isEmpty {
                            store.move("", toSection: nil, newSectionName: sectionName)
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
                sidebarRow(.clicky, title: "Clicky", subtitle: "Screen companion") { ClickyAvatar(size: 34) }
            } else if item.hasPrefix("bot:"), let bot = store.bot(String(item.dropFirst(4))) {
                let routineCount = store.routines(for: bot.id).filter { !$0.paused }.count
                sidebarRow(.bot(bot.id), title: bot.name,
                           subtitle: (bot.primary ? "CEO · " : "") + bot.modelLabel + (routineCount > 0 ? " · ⏰ \(routineCount)" : ""),
                           star: bot.primary, unread: store.unread[bot.id] ?? 0) {
                    BotAvatar(bot: bot, size: 34, state: store.replying[bot.id].map { $0.isEmpty ? .thinking : .typing } ?? .idle)
                }
            } else if let group = store.group(String(item.dropFirst(6))) {
                let members = store.members(of: group)
                let busy = members.contains { store.replying[$0.id] != nil }
                sidebarRow(pane(for: item), title: group.name,
                           subtitle: busy ? "Working…" : "Led by \(store.head(of: group)?.name ?? "nobody") · \(members.count) bots",
                           unread: store.unread[group.roomID] ?? 0) {
                    GroupAvatar(bots: members, size: 34)
                }
            }
        }
        .contextMenu { itemMenu(item) }
    }

    @ViewBuilder private func itemMenu(_ item: String) -> some View {
        Button(store.isPinned(item) ? "Unpin" : "Pin to top") { store.setPinned(!store.isPinned(item), item) }
        Menu("Move to section") {
            ForEach(store.layout.sections) { section in
                Button(section.name) { store.move(item, toSection: section.id) }
                    .disabled(section.items.contains(item))
            }
            if !store.layout.sections.isEmpty { Divider() }
            Button("New section…") { namingSectionFor = item; sectionName = "" }
            if store.layout.section(of: item) != nil {
                Button("Take out of section") { store.move(item, toSection: nil) }
            }
        }
        if item.hasPrefix("bot:"), let bot = store.bot(String(item.dropFirst(4))) {
            Divider()
            Button("Details and routines…") { detailsBot = bot }
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
        if selection.pane == pane(for: item) { selection.pane = .team }
        if item.hasPrefix("bot:") { store.deleteBot(String(item.dropFirst(4))) }
        if item.hasPrefix("group:") { store.deleteGroup(String(item.dropFirst(6))) }
    }

    private func sectionHeader(_ section: BotsLayout.Section) -> some View {
        HStack {
            Text(section.name.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(DS.Colors.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Delete section (keeps its bots)", role: .destructive) { store.deleteSection(section.id) }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 2)
    }

    private func sidebarRow<Icon: View>(_ pane: BotsPane, title: String, subtitle: String, star: Bool = false, unread: Int = 0,
                                        @ViewBuilder icon: () -> Icon) -> some View {
        Button { selection.pane = pane } label: {
            HStack(spacing: 10) {
                icon()
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 13, weight: unread > 0 ? .semibold : .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                        if star {
                            // Grok marks the Primary Bot with a star.
                            Image(systemName: "star.fill").font(.system(size: 8.5)).foregroundColor(DS.Colors.warning)
                        }
                    }
                    Text(subtitle).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if unread > 0 {
                    Text("\(unread)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.accent))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(selection.pane == pane ? Color.white.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var detail: some View {
        switch selection.pane {
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
            Divider().overlay(Color.white.opacity(0.06))
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain VStack: a lazy one guesses the heights of long replies it hasn't drawn, and
                    // scrolling to the end then lands in empty space until something redraws.
                    VStack(alignment: .leading, spacing: 18) {
                        if record.messages.isEmpty && inProgress.isEmpty { emptyState }
                        ForEach(record.messages) { message in
                            if message.author == "user" {
                                UserBubble(text: message.text)
                            } else if message.author == "routine" {
                                RoutineMarker(text: message.text, at: message.at)
                            } else if let author = store.bot(message.author) {
                                BotLine(bot: author, text: message.text, showsName: bot == nil,
                                        animatesIn: !settledIDs.contains(message.id), isLive: false)
                                if let runID = message.runID, let run = store.t3Runs.first(where: { $0.id == runID }) {
                                    T3ResultCard(run: run).padding(.leading, 46)
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
                                BotLine(bot: pending.0, text: pending.1, showsName: bot == nil, animatesIn: true, isLive: true)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24).padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: record.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: inProgress.map(\.1.count).reduce(0, +)) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
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

    private var header: some View {
        HStack(spacing: 10) {
            if let bot {
                BotAvatar(bot: bot, size: 28, state: store.replying[bot.id].map { $0.isEmpty ? .thinking : .typing } ?? .idle)
                VStack(alignment: .leading, spacing: 1) {
                    // Like Grok: the bot's name opens its details (instructions, apps, routines).
                    Button { showsDetails = true } label: {
                        HStack(spacing: 4) {
                            Text(bot.name).font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showsDetails) { BotDetailsSheet(store: store, botID: bot.id) { showsDetails = false } }
                    Text("\(["claude": "Claude", "grok": "Grok"][bot.provider] ?? "OpenCode") · \(bot.modelLabel)\(bot.effort.map { " · \($0)" } ?? "")")
                        .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                }
            } else {
                HStack(spacing: -8) {
                    ForEach(groupBots) { member in BotAvatar(bot: member, size: 24, state: .idle) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Button { editsGroup = true } label: {
                        HStack(spacing: 4) {
                            Text(group?.name ?? "Group chat").font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $editsGroup) {
                        if let group { GroupEditor(store: store, group: group) { _ in editsGroup = false } }
                    }
                    Text(isProjectRoom ? "Theo (CEO) and the project team turn your idea into a prompt for T3 Code"
                                       : "\(group.flatMap { store.head(of: $0) }?.name ?? "The head") leads; tag anyone with @Name")
                        .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer()
            if let bot {
                Button { showsModelSettings = true } label: {
                    Label("Model settings", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless).foregroundColor(DS.Colors.textSecondary).font(.system(size: 12))
                .popover(isPresented: $showsModelSettings, arrowEdge: .bottom) {
                    BotModelSettings(bot: bot) { store.save($0) }
                }
            }
            Button("New chat") {
                store.clearConversation(conversationID)
                settledIDs = []
            }
            .buttonStyle(.borderless).foregroundColor(DS.Colors.textSecondary).font(.system(size: 12))
            .disabled(!inProgress.isEmpty)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if let bot {
                BotAvatar(bot: bot, size: 84, state: .idle)
                Text(bot.name).font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text(bot.description).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center)
            } else if isProjectRoom {
                Text("Pitch an idea to the project team").font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text("Theo, your CEO, brings in the Project Manager, Design Critic and Code Improver, then writes one prompt you can send to T3 Code.")
                    .font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center)
            } else if let group, let head = store.head(of: group) {
                BotAvatar(bot: head, size: 84, state: .idle)
                Text("\(group.name) chat").font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text("\(head.name) leads this group: they hand your request to \(Self.list(groupBots.dropFirst().map(\.name))), then merge the answers. Ask them to build something and it goes to T3 Code.")
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

    private var composer: some View {
        VStack(spacing: 8) {
            if bot == nil {
                HStack(spacing: 6) {
                    ForEach(groupBots) { member in
                        Button { draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + "@\(member.name) " } label: {
                            HStack(spacing: 4) {
                                BotAvatar(bot: member, size: 16, state: .idle)
                                Text("@\(member.name)").font(.system(size: 11))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain).foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(bot.map { "Message \($0.name)" } ?? (isProjectRoom ? "Pitch an idea to Theo and the team" : "Message the \(group?.name ?? "group")"),
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .onSubmit(send)
                if !inProgress.isEmpty && draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        if let bot { store.stop(bot.id) } else if let groupID { store.stopGroup(groupID) }
                    } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .help("Stop the reply")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.12) : DS.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 22).fill(DS.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.07)))
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 6)
        .frame(maxWidth: .infinity)
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
            Spacer(minLength: 80)
            Text(text)
                .font(.system(size: 14)).foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 15).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.1)))
        }
    }
}

struct ThinkingLine: View {
    let bot: NativeBot
    let showsName: Bool
    @State private var sweep = false

    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(bot: bot, size: 34, state: .thinking)
            OrbitingDots(color: bot.accentColor)
            Text("\(bot.name) is thinking")
                .font(.system(size: 13))
                .foregroundStyle(
                    LinearGradient(colors: [DS.Colors.textTertiary, bot.accentColor, DS.Colors.textTertiary],
                                   startPoint: UnitPoint(x: sweep ? 1 : -1, y: 0.5), endPoint: UnitPoint(x: sweep ? 2 : 0, y: 0.5)))
                .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweep = true } }
        }
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
    @State private var shown = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BotAvatar(bot: bot, size: 34, state: isTyping ? .typing : .idle)
            VStack(alignment: .leading, spacing: 4) {
                if showsName {
                    Text(bot.name).font(.system(size: 11.5, weight: .semibold)).foregroundColor(bot.accentColor)
                }
                if isTyping {
                    (Text(String(text.prefix(shown))) + Text(" ")).font(.system(size: 14)).foregroundColor(DS.Colors.textPrimary)
                        .overlay(alignment: .bottomTrailing) { CometCaret(color: bot.accentColor).offset(x: 10, y: -4) }
                } else {
                    BotRichText(text: text)
                    if !isLive { BotMessageActions(text: text).padding(.top, 2) }
                }
            }
            .padding(.top, 6)
            Spacer(minLength: 40)
        }
        .task(id: text.count) { await typeOut() }
        .onAppear { if !animatesIn { shown = text.count } }
    }

    private var isTyping: Bool { animatesIn && (isLive || shown < text.count) }

    /// Reveals the text a few characters per frame, faster when far behind the stream.
    private func typeOut() async {
        guard animatesIn else { shown = text.count; return }
        while shown < text.count {
            let left = text.count - shown
            shown += max(1, left / 22)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }
}

/// Inline Markdown (bold, italics, code, links) for finished replies.
enum BotMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Motion

enum BotAvatarState { case idle, thinking, typing }

extension NativeBot {
    var bodyColor: Color { Color(hue: hue / 360, saturation: 0.62, brightness: 0.82) }
    var accentColor: Color { Color(hue: accentHue.truncatingRemainder(dividingBy: 360) / 360, saturation: 0.7, brightness: 0.95) }
}

/// A bot's face: a glowing orb with eyes and an orbit ring. Thinking, it floats and tilts while
/// the ring spins fast; typing, it nods along.
struct BotAvatar: View {
    let bot: NativeBot
    let size: CGFloat
    let state: BotAvatarState
    @State private var phase = false
    @State private var spin = false

    var body: some View {
        ZStack {
            let fill = RadialGradient(colors: [bot.accentColor, bot.bodyColor, bot.bodyColor.opacity(0.7)],
                                      center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.6)
            Group {
                if let symbol = bot.shapeSymbol {
                    // The shape picked for the bot (square, sparkle, clover, flower, heart, star).
                    Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(fill)
                        .frame(width: size * 0.72, height: size * 0.72)
                } else {
                    Circle().fill(fill).frame(width: size * 0.66, height: size * 0.66)
                }
            }
            .shadow(color: bot.accentColor.opacity(state == .idle ? 0.25 : 0.7), radius: state == .idle ? 3 : size * 0.18)
            HStack(spacing: size * 0.1) {
                Capsule().fill(Color.black.opacity(0.75)).frame(width: size * 0.07, height: size * (state == .thinking && phase ? 0.05 : 0.12))
                Capsule().fill(Color.black.opacity(0.75)).frame(width: size * 0.07, height: size * (state == .thinking && phase ? 0.05 : 0.12))
            }
            .offset(x: state == .thinking ? (phase ? size * 0.05 : -size * 0.05) : 0, y: -size * 0.02)
            Ellipse()
                .stroke(bot.accentColor.opacity(0.75), lineWidth: max(1, size * 0.035))
                .frame(width: size * 0.98, height: size * 0.34)
                .rotationEffect(.degrees(-18))
                .overlay(
                    Circle().fill(bot.accentColor).frame(width: size * 0.09, height: size * 0.09)
                        .offset(x: size * 0.49)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .scaleEffect(x: 1, y: 0.34)
                        .rotationEffect(.degrees(-18))
                )
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if size >= 24 {
                // The bot's role, so bots of similar colour are told apart at a glance.
                Image(systemName: bot.symbol)
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: size * 0.38, height: size * 0.38)
                    .background(Circle().fill(bot.bodyColor.opacity(0.95)))
                    .overlay(Circle().stroke(DS.Colors.background, lineWidth: max(1.5, size * 0.04)))
                    .offset(x: size * 0.04, y: size * 0.04)
            }
        }
        .rotationEffect(.degrees(state == .thinking ? (phase ? 9 : -9) : 0))
        .offset(y: state == .thinking ? (phase ? -size * 0.08 : size * 0.02) : 0)
        .scaleEffect(x: 1, y: state == .typing && phase ? 1.05 : 1, anchor: .bottom)
        .onAppear { restart() }
        .onChange(of: state) { _, _ in restart() }
    }

    private func restart() {
        phase = false
        spin = false
        let duration: Double = state == .thinking ? 0.9 : state == .typing ? 0.22 : 3.2
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) { phase = state != .idle }
        withAnimation(.linear(duration: state == .idle ? 6 : 1.1).repeatForever(autoreverses: false)) { spin = true }
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
        Circle().fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color, radius: pulse ? 7 : 3)
            .shadow(color: color.opacity(0.5), radius: 10, x: -6)
            .scaleEffect(pulse ? 0.65 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true } }
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
                Image(systemName: connector.symbol).font(.system(size: 14)).foregroundColor(DS.Colors.textSecondary)
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
        HStack {
            Spacer().frame(width: 46)
            Button {
                let prompt = BotsT3.promptBlock(in: text) ?? text
                BotsStore.shared.submitToT3(prompt: prompt, title: BotsT3.projectTitle(in: text, prompt: prompt), room: room)
                sentHere = true
            } label: {
                Label(sent ? "Submitted to T3 Code" : (BotsT3.promptBlock(in: text) != nil ? "Submit prompt to T3 Code" : "Submit to T3 Code"),
                      systemImage: sent ? "checkmark" : "arrow.up.forward.app")
                    .font(.system(size: prominent ? 12 : 11, weight: prominent ? .semibold : .regular))
                    .padding(.horizontal, prominent ? 12 : 0).padding(.vertical, prominent ? 6 : 0)
                    .background(Capsule().fill(prominent ? DS.Colors.accent.opacity(0.9) : .clear))
                    .foregroundColor(prominent ? .white : DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(sent)
            Spacer()
        }
    }
}

/// A coding run in T3 Code while it works: what it's on, for how long, and a way to watch it there.
struct T3RunCard: View {
    let run: T3Run

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Spacer().frame(width: 34)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(alignment: .top, spacing: 10) {
                    if run.phase == "waiting" {
                        Image(systemName: "questionmark.bubble").foregroundColor(.orange)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        let minutes = max(0, Int(context.date.timeIntervalSince(run.startedAt) / 60))
                        Text(run.phase == "waiting" ? "\(run.title): waiting for your answer (@T3)"
                                                    : "\(BotsT3.modelName) is coding \(run.title) · \(minutes) min")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        if let activity = run.activity, !activity.isEmpty {
                            Text(activity).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(2)
                        }
                        if run.link != nil {
                            Button("Watch in T3 Code") { BotsT3.openInApp(run) }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }
        }
    }
}

/// A bot's engine, model, effort, thinking and fast mode. Changes save as they're made and apply from
/// the bot's next reply.
struct BotModelSettings: View {
    @State var bot: NativeBot
    let onChange: (NativeBot) -> Void
    @ObservedObject private var catalog = BrainCatalog.shared

    private static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    private static let openCodeEfforts = ["minimal", "low", "medium", "high", "max"]

    private var isClaude: Bool { bot.provider == "claude" }

    private static let grokModels = ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"]
    private static let grokEfforts = ["low", "medium", "high"]

    private var models: [String] {
        let listed = bot.provider == "grok" ? Self.grokModels : catalog.models[isClaude ? .claude : .opencode] ?? []
        return listed.contains(bot.model) ? listed : [bot.model] + listed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BotAvatar(bot: bot, size: 26, state: .idle)
                Text("\(bot.name) · model").font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            }
            row("Engine") {
                Picker("Engine", selection: Binding(get: { bot.provider }, set: { provider in
                    bot.provider = provider
                    bot.model = ["claude": "claude-sonnet-5-5", "grok": "grok-4.6"][provider] ?? "opencode/deepseek-v4.1-flash-free"
                    bot.effort = nil
                    commit()
                })) {
                    Text("Claude").tag("claude")
                    Text("OpenCode").tag("opencode")
                    Text("Grok").tag("grok")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            row("Model") {
                Picker("Model", selection: Binding(get: { bot.model }, set: { bot.model = $0; commit() })) {
                    ForEach(models, id: \.self) { model in
                        Text(NativeBot.label(for: model)).tag(model)
                    }
                }
                .labelsHidden().frame(width: 260)
            }
            row("Effort") {
                Picker("Effort", selection: Binding(get: { bot.effort ?? "" }, set: { bot.effort = $0.isEmpty ? nil : $0; commit() })) {
                    Text("Default").tag("")
                    ForEach(isClaude ? Self.claudeEfforts : bot.provider == "grok" ? Self.grokEfforts : Self.openCodeEfforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden().frame(width: 160)
            }
            row("Thinking") {
                Toggle("Thinking", isOn: Binding(get: { bot.thinking ?? false }, set: { bot.thinking = $0; commit() }))
                    .toggleStyle(.switch).labelsHidden().disabled(!isClaude)
            }
            row("Fast mode") {
                Toggle("Fast mode", isOn: Binding(get: { bot.fast ?? false }, set: { bot.fast = $0; commit() }))
                    .toggleStyle(.switch).labelsHidden().disabled(!isClaude)
            }
            Text(isClaude ? "Applies from the next reply." : "Thinking and fast mode are for Claude models. \(bot.provider == "grok" ? "Grok takes the effort as its reasoning effort." : "OpenCode takes the effort as the model's variant.")")
                .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 400)
        .onAppear { catalog.load() }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary).frame(width: 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func commit() { onChange(bot) }
}
