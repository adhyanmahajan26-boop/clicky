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
    case activity
    case connectors
    /// A page of Settings, in this window.
    case settings(SettingsTab.Section)
}

@MainActor
final class BotsSelection: ObservableObject {
    static let shared = BotsSelection()
    @Published var pane: BotsPane = .home {
        // Clicky has a chat of its own, wherever a team page or a card links to it from.
        didSet { if pane == .bot(BotsStore.clickyID) { pane = .clicky } }
    }
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
    /// Status lines show a streaming reply's first line; this changes only when that line does.
    @ObservedObject private var headlines = BotLiveHeadline.shared
    /// Inside Theo's home window, Connectors is its own tab instead.
    var showsConnectors = true

    /// The bot's settings slide over the chat from the right; they never shrink it (docs/DESIGN.md).
    @State private var showsInspector = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The bot list shows the teams (each category with its manager first) unless switched to urgent first (needs you,
    /// failed, working, done, quiet). A new key, so a Mac that was left on urgent first by tapping a counter pill opens on
    /// the teams again.
    @AppStorage("theo.sidebar.sort.v2") private var sortMode = "teams"
    /// A counter pill under Theo's row filters the list to that lane.
    @State private var laneFilter: PixelState.Lane?
    @ObservedObject private var studio = StudioController.shared
    @ObservedObject private var dictation = ComposerDictation.shared
    /// Theo and Clicky are products of their own (Settings › Products): what's off leaves the sidebar.
    @ObservedObject private var products = TheoProducts.shared

    private var showsStudioPanel: Bool {
        guard StudioController.hasPanel, studio.panelVisible else { return false }
        if case .settings = selection.pane { return false }
        return true
    }

    var body: some View {
        HStack(spacing: 0) {
            if case .settings(let section) = selection.pane {
                SettingsSidebar(selection: selection, current: section)
            } else {
                sidebar
            }
            Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1).ignoresSafeArea(.container, edges: .top)
            detail
                .frame(minWidth: showsStudioPanel ? 460 : nil, maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Colors.background)
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
                            .background(DS.Colors.surface1)
                            .overlay(alignment: .leading) { Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1) }
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
            if showsStudioPanel {
                Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1).ignoresSafeArea(.container, edges: .top)
                StudioPanel(store: store, selection: selection)
                    .frame(width: 344)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(DS.Colors.background)
        .modifier(TheoAppearanceRoot())
        .onChange(of: selection.pane) { _, _ in showsInspector = false }
        .onReceive(NotificationCenter.default.publisher(for: .theoNewGroupChat)) { _ in editingGroup = Self.blankGroup }
        .onReceive(NotificationCenter.default.publisher(for: .theoOpenBot)) { note in
            if let id = note.object as? String { selection.pane = id == BotsStore.clickyID ? .clicky : .bot(id) }
        }
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

    private static let blankGroup = BotGroup(id: "", name: "", symbol: "person.2.fill", headID: nil, memberIDs: [])

    /// The Hairline sidebar: Theo, search, four rows, the teams, and Clicky at the bottom. Group chats and bots outside a
    /// team live on Home and in the ⌘K search.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if products.isOn(.theo) {
                workspaceRow
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 8)
                counterPills
            } else {
                Color.clear.frame(height: 12)
            }
            searchField
                .padding(.horizontal, 10).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !query.isEmpty {
                        sectionTitle("Results", count: searchResults.count)
                        ForEach(searchResults, id: \.self) { item in itemRow(item) }
                        if searchResults.isEmpty {
                            Text("Nothing matches").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary).padding(.horizontal, 20).padding(.vertical, 6)
                        }
                    } else {
                        hairlineRow("home", "Home", isSelected: selection.pane == .home) { selection.pane = .home }
                        if StudioController.hasPanel {
                            hairlineRow("studio", "Studio", trailing: studio.isOn ? "\(studio.liveCount) live" : (studio.remoteView?.tiles.isEmpty == false ? "\(studio.remoteView?.tiles.count ?? 0) live" : nil), isSelected: studio.panelVisible, live: studio.isOn && studio.liveCount > 0) {
                                withAnimation(DS.Motion.panel) { studio.panelVisible.toggle() }
                            }
                        }
                        if products.isOn(.theo) {
                            hairlineRow("routines", "Routines", trailing: store.routines.isEmpty ? nil : "\(store.routines.filter { !$0.paused }.count)",
                                        isSelected: selection.pane == .routines) { selection.pane = .routines }
                        }
                        hairlineRow("notes", "Notes", isSelected: selection.pane == .notes) { selection.pane = .notes }
                        if products.isOn(.theo) {
                            let pinned = pinnedItems
                            if !pinned.isEmpty {
                                sectionTitle("Pinned", count: pinned.count).dropTarget { items in items.forEach { store.setPinned(true, $0) } }
                                ForEach(pinned, id: \.self) { item in itemRow(item) }
                            }
                            sortSwitch
                            // A counter pill shows its lane for now without leaving the teams for good.
                            if sortMode == "urgent" || laneFilter != nil {
                                urgentList
                            } else {
                                // Clicky's own team leaves with Clicky (Settings › Products).
                                ForEach(store.rootSections.filter { products.isOn(.clicky) || $0.leaderID != BotsStore.clickyID }) { section in teamSection(section, depth: 0) }
                                unfiledBots
                                newCategoryButton
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            if products.isOn(.clicky) {
                clickyPill
                    .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 6)
            }
            // Always in reach, so a new build installs from here instead of by hand.
            if let companionManager = CompanionManager.current {
                UpdateButton(updateController: companionManager.updateController, placement: .sidebar)
                    .padding(.horizontal, 10).padding(.bottom, 2)
            }
            HStack(spacing: 2) {
                hairlineRow("connectors", "Connectors", isSelected: selection.pane == .connectors, inset: 0) { selection.pane = .connectors }
                hairlineRow("settings", "Settings", isSelected: false, inset: 0) { selection.openSettings(.look) }
            }
            .padding(.horizontal, 10).padding(.bottom, 12)
        }
        .frame(width: 264)
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
            Text(confirmingDelete.flatMap { store.bot(String($0.dropFirst(4))) }?.owner != nil
                 ? "Its chat goes too, and a hidden helper does this job for Clicky from now on. To keep it working out of sight, hide it instead."
                 : "Its chat and its routines go too. To keep it working out of sight, hide it instead.")
        }
    }

    private struct NamingRequest: Identifiable { let item: String; var id: String { item } }

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

    private func pane(for item: String) -> BotsPane {
        if item == "clicky" { return .clicky }
        if item.hasPrefix("bot:") { return .bot(String(item.dropFirst(4))) }
        let id = String(item.dropFirst(6))
        return id == BotGroup.projectID ? .team : .group(id)
    }

    private func isCEO(_ item: String) -> Bool { item == store.primary.map { "bot:\($0.id)" } }

    static let theoID = "theo"

    /// What sits under Pinned. Theo is always first: as the CEO it has the row at the very top, and if another bot was
    /// made primary, Theo heads this list instead, so it never drops into a team or the urgent lanes.
    private var pinnedItems: [String] {
        let theoItem = "bot:\(Self.theoID)"
        let others = store.layout.pinned.filter { $0 != theoItem && itemExists($0) && !store.isHidden($0) && !isCEO($0) }
        return itemExists(theoItem) && !isCEO(theoItem) ? [theoItem] + others : others
    }

    /// Bots in no category, so the teams view never loses one: they sit under "Other bots" until they're filed.
    @ViewBuilder private var unfiledBots: some View {
        let filed = Set(store.layout.sections.flatMap(\.items))
        let unfiled = store.bots.filter { bot in
            let item = BotsLayout.item(forBot: bot.id)
            return !filed.contains(item) && item != "clicky" && bot.id != Self.theoID && !isCEO(item) && !store.isPinned(item) && !store.isHidden(item)
                && (products.isOn(.clicky) || bot.owner != BotsStore.clickyID)
        }
        if !unfiled.isEmpty {
            sectionTitle("Other bots", count: unfiled.count)
            ForEach(unfiled, id: \.id) { bot in itemRow("bot:\(bot.id)") }
        }
    }

    /// Makes a category and opens its page, where it's named, filled and given a manager.
    private var newCategoryButton: some View {
        Button(action: newCategory) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("New category").font(.system(size: 11.5))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 20).frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().padding(.top, 6)
    }

    @ViewBuilder private func itemRow(_ item: String) -> some View {
        Group {
            if item == "clicky" {
                let clicky = store.clickyBot
                teamRow(.clicky, bot: clicky, unread: store.unread[BotsStore.clickyID] ?? 0)
            } else if item.hasPrefix("bot:"), let bot = store.bot(String(item.dropFirst(4))) {
                teamRow(.bot(bot.id), bot: bot, unread: store.unread[bot.id] ?? 0)
            } else if let group = store.group(String(item.dropFirst(6))) {
                let members = store.members(of: group)
                let busy = members.contains { store.replying[$0.id] != nil }
                rowButton(pane(for: item)) {
                    GroupAvatar(bots: members, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                        Text(busy ? "Working" : "\(members.count) bots").font(.system(size: 11.5)).foregroundColor(busy ? DS.Colors.textSecondary : DS.Colors.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if (store.unread[group.roomID] ?? 0) > 0 { Circle().fill(DS.Colors.textPrimary).frame(width: 6, height: 6) }
                }
            }
        }
        .contextMenu { itemMenu(item) }
        .draggable(item) {
            Text(itemName(item)).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(DS.Colors.accent))
        }
    }

    /// A bot's row: its face at 36 pt with its badge, its name (an orange dot for an unread result), its state word in the
    /// state's colour followed by what it's doing, and on the right how long it has been waiting or working.
    private func teamRow(_ pane: BotsPane, bot: NativeBot, unread: Int) -> some View {
        let state = store.pixelState(of: bot).state
        let working = state.lane == .working
        return rowButton(pane) {
            BotAvatar(bot: bot, size: 36, state: .idle, ring: selection.pane == pane ? DS.Colors.selected : DS.Colors.sidebar)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(bot.name).font(.system(size: 13, weight: unread > 0 ? .semibold : .medium))
                        .foregroundColor(bot.isOn ? DS.Colors.textPrimary : DS.Colors.textTertiary).lineLimit(1)
                    if store.layout.sections.contains(where: { $0.leaderID == bot.id }) {
                        // Spelled out, so it's plain at a glance who runs each team.
                        HStack(spacing: 2) {
                            Image(systemName: "crown.fill").font(.system(size: 8))
                            Text("Manager").font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.gold).fixedSize().help("Manager of this team: its members report here first")
                    }
                    if unread > 0 { Circle().fill(DS.Colors.accent).frame(width: 6, height: 6).help("Unread result") }
                }
                stateLine(bot: bot, state: state)
            }
            Spacer(minLength: 0)
            if StudioController.isAvailable, working || state == .needs, let tile = studio.roster.tile(of: bot.id) {
                StudioTileThumb(studio: studio, tile: tile).frame(width: 38, height: 24)
            } else {
                rowTime(bot: bot, state: state)
            }
        }
    }

    /// "Needs you · Sign in to Notion": the word in the state's colour, then the detail.
    private func stateLine(bot: NativeBot, state: PixelState) -> some View {
        let status = store.liveStatus(of: bot)
        let word = state.label
        var detail = status
        for prefix in ["Needs you · ", "Failed · ", "Off"] where detail.hasPrefix(prefix) { detail = String(detail.dropFirst(prefix.count)) }
        if detail == word { detail = "" }
        let tone = PixelTone(state: state)
        let wordColor: Color = tone == .quiet ? DS.Colors.textSecondary : tone == .done ? DS.Colors.textPrimary : tone.text
        return (Text(word).foregroundColor(wordColor) + Text(detail.isEmpty ? "" : " · " + detail).foregroundColor(DS.Colors.textTertiary))
            .font(.system(size: 11.5)).lineLimit(1)
    }

    /// How long it has been waiting or working: "4m", or a run's live timer.
    @ViewBuilder private func rowTime(bot: NativeBot, state: PixelState) -> some View {
        if let run = store.liveRun(of: bot.id), run.phase != "waiting" {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(T3RunCard.elapsed(since: run.startedAt, now: context.date)).font(.system(size: 11, design: .monospaced)).foregroundColor(DS.Colors.textTertiary)
            }
        } else if let since = store.stateSince(of: bot) ?? (state == .done ? store.conversation(bot.id).messages.last?.at : nil) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(BotsStore.shortAge(since: since, now: context.date)).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    /// "2 need you", "1 failed" under Theo's row; tapping one shows only those bots.
    @ViewBuilder private var counterPills: some View {
        let needing = store.bots.filter { $0.isOn && store.pixelState(of: $0).state == .needs }.count
        let failed = store.bots.filter { store.pixelState(of: $0).state == .failed }.count
        if needing + failed > 0 {
            HStack(spacing: 6) {
                if needing > 0 { counterPill(.needsYou, text: "\(needing) need\(needing == 1 ? "s" : "") you", tone: .warn) }
                if failed > 0 { counterPill(.failed, text: "\(failed) failed", tone: .bad) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    private func counterPill(_ lane: PixelState.Lane, text: String, tone: StatusPill.Tone) -> some View {
        Button {
            laneFilter = laneFilter == lane ? nil : lane
        } label: {
            StatusPill(text: text, tone: tone)
                .overlay(Capsule().strokeBorder(laneFilter == lane ? DS.Colors.textPrimary.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain).pointerCursor().help(laneFilter == lane ? "Show every bot" : "Show only these")
    }

    /// By team (the default) or urgent first, remembered.
    private var sortSwitch: some View {
        HStack {
            Text("Sort").font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary)
            Spacer()
            HairlineSegments(options: [("teams", "Teams"), ("urgent", "Urgent first")], selection: Binding(get: { laneFilter != nil ? "urgent" : sortMode }, set: { sortMode = $0; laneFilter = nil }))
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }

    /// Needs you, Failed, Working, Done, then Quiet (ready, asleep, off), each with a small mono heading and its count.
    @ViewBuilder private var urgentList: some View {
        let shown = store.bots.filter { !$0.primary && $0.id != Self.theoID && !store.isHidden("bot:\($0.id)") && (products.isOn(.clicky) || $0.owner != BotsStore.clickyID) }
        let lanes = Dictionary(grouping: shown) { store.pixelState(of: $0).state.lane }
        ForEach(PixelState.Lane.allCases.filter { laneFilter == nil || $0 == laneFilter }, id: \.self) { lane in
            if let bots = lanes[lane], !bots.isEmpty {
                HStack {
                    Text(lane.title.uppercased()).font(.system(size: 10.5, weight: .medium, design: .monospaced)).tracking(1).foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    Text("\(bots.count)").font(.system(size: 10.5, design: .monospaced)).foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
                ForEach(sortedInLane(bots), id: \.id) { bot in itemRow("bot:\(bot.id)") }
            }
        }
    }

    /// Longest waiting first within a lane; quiet bots by name.
    private func sortedInLane(_ bots: [NativeBot]) -> [NativeBot] {
        bots.sorted { left, right in
            let leftSince = store.stateSince(of: left) ?? .distantFuture
            let rightSince = store.stateSince(of: right) ?? .distantFuture
            if leftSince != rightSince { return leftSince < rightSince }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private func rowButton<Content: View>(_ pane: BotsPane, @ViewBuilder content: () -> Content) -> some View {
        Button { selection.pane = pane } label: {
            HStack(spacing: 10) { content() }
                .padding(.horizontal, 8).frame(height: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(isSelected: selection.pane == pane))
        .padding(.horizontal, 10)
    }

    /// Home, Studio, Routines, Notes, Connectors, Settings.
    private func hairlineRow(_ icon: String, _ title: String, trailing: String? = nil, isSelected: Bool, live: Bool = false, inset: CGFloat = 10, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HairlineIcon(name: icon, size: 20, color: isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary, selected: isSelected, live: live)
                Text(title).font(.system(size: 13)).foregroundColor(DS.Colors.textPrimary).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                if let trailing { Text(trailing).font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary).lineLimit(1) }
            }
            .padding(.horizontal, 8).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(isSelected: isSelected))
        .padding(.horizontal, inset)
    }

    /// Theo on top: its figure, how the team's doing, and the new-bot button.
    private var workspaceRow: some View {
        let ceo = store.primary
        let on = ceo.map { selection.pane == .bot($0.id) } ?? false
        let others = store.bots.filter { !$0.primary }.count
        return HStack(spacing: 4) {
            Button { if let ceo { selection.pane = .bot(ceo.id) } } label: {
                HStack(spacing: 10) {
                    if let ceo { BotAvatar(bot: ceo, size: 30, state: .idle) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ceo?.name ?? "Theo").font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                        Text("CEO · \(store.workingCount) of \(others) bots working").font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { addingBot = true } label: {
                HairlineIcon(name: "compose", size: 20, color: DS.Colors.textSecondary)
                    .frame(width: 24, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("New bot (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? DS.Colors.selected : DS.Colors.hover))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            HairlineIcon(name: "search", size: 18, color: DS.Colors.textTertiary, live: searchFocused)
            TextField("Search or jump to…", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(DS.Colors.textTertiary) }.buttonStyle(.plain)
            } else {
                Text("⌘K").font(.system(size: 10.5, weight: .medium)).foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 5).frame(height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            }
        }
        .padding(.horizontal, 8).frame(height: 32)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(searchFocused ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1))
        .background(Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command).opacity(0))
    }

    /// Clicky at the bottom, with what it's listening for.
    private var clickyPill: some View {
        let micDown = CompanionManager.current?.wakeWordController.isMicUnavailable == true
        let listening = ClickySettings.isWakeWordEnabled && !store.isClickyBusy && !micDown
        return Button { selection.pane = .clicky } label: {
            HStack(spacing: 10) {
                ClickyAvatar(size: 34, isActive: store.isClickyBusy)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Clicky").font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text(dictation.isActive ? "Dictating\u{2026}" : store.isClickyBusy ? "Working" : micDown ? "Mic unavailable" : listening ? "Listening for \u{201C}hey \(ClickySettings.assistantName)\u{201D}" : "Awake")
                        .font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if listening || dictation.isActive { ListeningWave() }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selection.pane == .clicky ? DS.Colors.selected : .clear))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func itemMenu(_ item: String) -> some View {
        if item != "bot:\(Self.theoID)" {
            Button(store.isPinned(item) ? "Unpin" : "Pin to top") { store.setPinned(!store.isPinned(item), item) }
        }
        Menu("Move to category") {
            ForEach(store.layout.sections) { section in
                Button(section.name) { store.move(item, toSection: section.id) }
                    .disabled(section.items.contains(item))
            }
            if !store.layout.sections.isEmpty { Divider() }
            Button("New category…") { namingSectionFor = item; sectionName = "" }
            if store.layout.section(of: item) != nil {
                Button("Take out of category") { store.move(item, toSection: nil) }
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
            if StudioController.isAvailable {
                Menu("Give a screen") { BotScreenPicker(botID: bot.id).pickerStyle(.inline) }
            }
            if !bot.primary && bot.owner == nil { Button("Make primary") { store.makePrimary(bot.id) } }
        } else if item.hasPrefix("group:"), let group = store.group(String(item.dropFirst(6))) {
            Divider()
            Button("Edit group chat…") { editingGroup = group }
        }
        Divider()
        if store.isHidden(item) {
            Button("Show in sidebar") { store.setHidden(false, item) }
        } else if item != "clicky", item != store.primary.map({ "bot:\($0.id)" }) {
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

    /// A team: a small label with its count (click for the team page, right-click for the rest), then its bots. The
    /// manager goes first, and sub-teams follow under it. Drop bots on the label to file them.
    private func teamSection(_ section: BotsLayout.Section, depth: Int) -> AnyView {
        // Theo has the top row and Clicky the pill at the bottom, so neither repeats in a team.
        let manager = section.leaderID.map(BotsLayout.item(forBot:)).flatMap { item in
            section.items.contains(item) && itemExists(item) && !store.isHidden(item) && !isCEO(item) && item != "clicky" ? item : nil
        }
        let items = section.items.filter { itemExists($0) && !store.isPinned($0) && !store.isHidden($0) && $0 != manager && !isCEO($0) && $0 != "clicky" }
        let children = store.subsections(of: section.id)
        let holdsSelection = (manager.map { [$0] } ?? []).contains { pane(for: $0) == selection.pane } || items.contains { pane(for: $0) == selection.pane }
        let collapsed = (section.collapsed ?? false) && !holdsSelection
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            teamLabel(section, count: store.members(of: section).count, collapsed: collapsed)
            if !collapsed {
                if let manager { itemRow(manager) }
                ForEach(items, id: \.self) { item in itemRow(item) }
                ForEach(children) { child in teamSection(child, depth: depth + 1) }
                if manager == nil && items.isEmpty && children.isEmpty {
                    Text("Drag bots here").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 12).frame(height: 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.Colors.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4])))
                        .padding(.horizontal, 18)
                        .dropTarget { dropped in dropped.forEach { store.move($0, toSection: section.id) } }
                }
            }
        })
    }

    private func teamLabel(_ section: BotsLayout.Section, count: Int, collapsed: Bool) -> some View {
        let members = store.members(of: section)
        return HStack(spacing: 4) {
            Button { selection.pane = .category(section.id) } label: {
                HStack {
                    Text(section.name.uppercased()).font(.system(size: 11, weight: .medium)).tracking(0.66)
                        .foregroundColor(selection.pane == .category(section.id) ? DS.Colors.textPrimary : DS.Colors.textTertiary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Open team page") { selection.pane = .category(section.id) }
                Button(collapsed ? "Show the team" : "Fold the team") { withAnimation(.easeOut(duration: 0.15)) { store.toggleCollapsed(section.id) } }
                Menu("Manager") {
                    Button("No manager (everyone reports to \(store.primary?.name ?? "the CEO"))") { store.setLeader(nil, of: section.id) }
                    ForEach(members) { bot in Button(bot.name) { store.setLeader(bot.id, of: section.id) } }
                }
                Button("Report to \(store.primary?.name ?? "the CEO") now") { store.reportToCEO(section.id) }.disabled(members.isEmpty)
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
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
        .contentShape(Rectangle())
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

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 11, weight: .medium)).tracking(0.66).foregroundColor(DS.Colors.textTertiary)
            Spacer()
            Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
        .contentShape(Rectangle())
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

    /// The panes that belong to Theo the product: chats, teams, routines and activity.
    private var paneIsTheos: Bool {
        switch selection.pane {
        case .team, .category, .group, .bot, .routines, .activity: return true
        default: return false
        }
    }

    @ViewBuilder private var detail: some View {
        if paneIsTheos && !products.isOn(.theo) {
            ProductOffView(product: .theo)
        } else if selection.pane == .clicky && !products.isOn(.clicky) {
            ProductOffView(product: .clicky)
        } else if selection.pane == .home && !products.isOn(.theo) {
            ProductsHomeView()
        } else {
            paneDetail
        }
    }

    @ViewBuilder private var paneDetail: some View {
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
            } else {
                TodayView(store: store, selection: selection)
            }
        case .clicky:
            ClickyChatScreen()
        case .bot(let id):
            if let bot = store.bot(id) {
                BotChatScreen(store: store, conversationID: id, bot: bot).id(id)
            } else {
                TodayView(store: store, selection: selection)
            }
        case .connectors:
            ConnectorsScreen(bots: store.bots)
        case .routines:
            RoutinesScreen(store: store)
        case .activity:
            ActivityScreen(store: store, selection: selection)
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
    /// Only the newest messages are drawn. The whole chat is one non-lazy stack, so every streamed word laid out all of it:
    /// on Theo's 167-message chat that kept the main thread pegged for a whole reply. Older ones are a click away.
    @State private var shownMessages = BotChatScreen.messagesPerPage
    static let messagesPerPage = 40
    @State private var showsModelSettings = false
    @State private var showsDetails = false
    @State private var editsGroup = false
    @State private var attachments: [URL] = []
    @ObservedObject private var studio = StudioController.shared
    @ObservedObject private var dictation = ComposerDictation.shared
    @AppStorage(ComposerDictationSettings.enabledKey) private var dictationEnabled = true
    @ObservedObject private var products = TheoProducts.shared

    private var record: BotConversationRecord { store.conversation(conversationID) }
    private var group: BotGroup? { groupID.flatMap { store.group($0) } }
    private var groupBots: [NativeBot] { group.map { store.members(of: $0) } ?? [] }
    private var isProjectRoom: Bool { groupID == BotGroup.projectID }
    /// Who's writing in this chat right now. A bot answering a private message or another chat isn't: it doesn't show here.
    private var inProgress: [NativeBot] {
        let ids = bot.map { [$0.id] } ?? groupBots.map(\.id)
        return ids.compactMap { id in
            guard store.replyingIn[id] == conversationID, store.replying[id] != nil else { return nil }
            return store.bot(id)
        }
    }
    /// Stop has something to stop: a bot writing here, a group's round, or private messages this chat set off.
    private var canStop: Bool { !inProgress.isEmpty || store.isBusy(conversationID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if record.messages.isEmpty && inProgress.isEmpty && !hasLiveRun {
                // A new chat: the bot in the middle of the pane, not stuck above the composer.
                Spacer(minLength: 0)
                emptyState.padding(.horizontal, 24)
                Spacer(minLength: 0)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain VStack: a lazy one guesses the heights of long replies it hasn't drawn, and
                    // scrolling to the end then lands in empty space until something redraws.
                    VStack(alignment: .leading, spacing: 14) {
                        if record.messages.count > shownMessages {
                            Button("Show earlier messages (\(record.messages.count - shownMessages) more)") { shownMessages += Self.messagesPerPage }
                                .buttonStyle(.theo(.ghost, .small))
                                .pointerCursor()
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(Array(record.messages.enumerated()).suffix(shownMessages), id: \.element.id) { index, message in
                            if let job = BotsStore.delegationID(of: message).flatMap({ store.delegation($0) }) {
                                // The pending card gives way to the finished one, which lands at the end of the chat.
                                if !message.text.isEmpty || job.isLive { DelegationCard(job: job) }
                            } else if let exchange = BotDMThread.parseCard(message.card) {
                                BotDMCard(store: store, senderID: message.author, targetID: exchange.targetID, exchangeID: exchange.exchangeID, at: message.at)
                            } else if let waiting = BotWaitingCard.id(of: message.card) {
                                BotWaitingCard(store: store, id: waiting, text: message.text)
                            } else if message.author == BotsStore.noteAuthor {
                                ChatNote(text: message.text)
                            } else if message.author == "user" {
                                UserBubble(text: message.text)
                            } else if message.author == "routine" {
                                RoutineMarker(text: message.text, at: message.at)
                            } else if let author = store.bot(message.author) {
                                let call = message.text.contains("[CHOOSE:") ? BotCallPrompt.parse(message.text) : nil
                                let brief = BotMessageCards.brief(for: message)
                                if let brief {
                                    BriefCardView(card: brief, text: message.text, at: message.at, author: author, cast: cast(in: message.text, besides: author))
                                } else if message.text.hasPrefix("Couldn't reply: ") {
                                    ReplyFailureCard(bot: author, message: message)
                                } else if call?.remainingText.isEmpty != true {
                                    BotLine(bot: author, text: call?.remainingText ?? message.text,
                                            showsName: index == 0 || record.messages[index - 1].author != message.author || record.messages[index - 1].card != nil,
                                            namesAuthor: bot == nil,
                                            animatesIn: !settledIDs.contains(message.id), isLive: false)
                                }
                                if let call {
                                    BotCallCard(call: call, author: author, at: message.at,
                                                   isOpen: !record.messages[(index + 1)...].contains { $0.author == "user" }, autoPicks: true) { answer in
                                        if let bot { store.send(answer, command: answer, to: bot.id) } else if let groupID { store.sendToGroup(answer, command: answer, groupID: groupID) }
                                    }
                                }
                                if let runID = message.runID, let run = store.t3Runs.first(where: { $0.id == runID }) {
                                    T3ResultCard(run: run).padding(.leading, 36)
                                }
                                if message.card == "settings" { BotSettingsChatCard(botID: author.id) }
                                if let card = message.card, card.hasPrefix("screen|") { BotScreenGiftCard(card: card) }
                                if let check = BrowserResearcher.checkID(of: message) { BrowserCheckCard(id: check) }
                                if let prompt = BotsT3.promptBlock(in: message.text) {
                                    let title = BotsT3.projectTitle(in: message.text, prompt: prompt)
                                    let sentRun = store.t3Runs.first { $0.prompt == prompt || ($0.prompt == nil && $0.title == title) }
                                    T3HandoffButton(text: message.text, room: conversationID, prominent: true,
                                                    alreadySent: sentRun != nil, sentRunHarness: sentRun?.harness)
                                }
                            }
                        }
                        if let bot { ChatStatusCards(bot: store.bot(bot.id) ?? bot) }
                        ForEach(store.t3Runs.filter { ($0.phase == "running" || $0.phase == "waiting" || $0.phase == "reporting") && ($0.room ?? BotsStore.teamID) == conversationID }) { run in
                            T3RunCard(run: run, bot: bot ?? store.primary)
                        }
                        ForEach(inProgress, id: \.id) { pending in
                            LiveReplyLine(bot: pending, showsName: record.messages.last?.author != pending.id, namesAuthor: bot == nil,
                                          proxy: proxy, lastLive: $lastLive)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 704)
                    .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                }
                // A reply typing itself out, or a card opening under it, keeps the newest line in view.
                .modifier(ChatScrollAnchor())
                .onChange(of: record.messages.count) { _, _ in
                    if let last = record.messages.last, let streamed = lastLive[last.author], streamed.count > 20,
                       last.text.hasPrefix(String(streamed.prefix(20))) {
                        // Already typed out live: the saved copy just stays.
                        settledIDs.insert(last.id)
                        lastLive[last.author] = nil
                    }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                    // Again as a tall card under the new message is laid out and its words finish typing in.
                    for delay in [0.3, 1.2, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo("end", anchor: .bottom) } }
                }
                .modifier(ChatRunScroll(proxy: proxy, runKeys: runKeys))
                .onDisappear { if store.viewing == conversationID { store.viewing = nil } }
                .onAppear {
                    store.viewing = conversationID
                    settledIDs = Set(record.messages.map(\.id))
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            }
            composer
        }
        .onAppear { store.viewing = conversationID }
    }

    /// Changes whenever a run in this chat starts or changes phase.
    private var runKeys: [String] {
        store.t3Runs.filter { ($0.room ?? BotsStore.teamID) == conversationID }.map { "\($0.id):\($0.phase)" }
    }

    private var hasLiveRun: Bool {
        store.t3Runs.contains { ($0.phase == "running" || $0.phase == "waiting" || $0.phase == "reporting") && ($0.room ?? BotsStore.teamID) == conversationID }
    }

    /// The bots a document names, for its cover.
    private func cast(in text: String, besides author: NativeBot) -> [NativeBot] {
        store.bots.filter { $0.id != author.id && text.localizedCaseInsensitiveContains($0.name) }
    }

    /// The chat's header: its figure, name, role, a live status line, Studio and everything else under ⋯.
    private var header: some View {
        HStack(spacing: 12) {
            if let bot {
                let shown = store.pixelState(of: bot, state: inProgress.isEmpty ? .idle : .thinking).state
                BotAvatar(bot: bot, size: 44, state: inProgress.isEmpty ? .idle : .thinking)
                Button { NotificationCenter.default.post(name: .theoShowBotSettings, object: nil) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(bot.name).font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                            if bot.primary {
                                Text("CEO").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(0.76).foregroundColor(DS.Colors.accentText)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(DS.Colors.accentSoft))
                            }
                            StatusPill(state: shown)
                        }
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(headerDetail(for: bot, state: shown, now: context.date)).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain).help("Settings for \(bot.name)")
            } else {
                GroupAvatar(bots: groupBots, size: 36)
                Button { editsGroup = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group?.name ?? "Group chat").font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        Text("Led by \(group.flatMap { store.head(of: $0) }?.name ?? "nobody") · \(groupBots.count) bots")
                            .font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $editsGroup) {
                    if let group { GroupEditor(store: store, group: group) { _ in editsGroup = false } }
                }
            }
            Spacer()
            if StudioController.hasPanel {
                Button { withAnimation(DS.Motion.panel) { studio.panelVisible.toggle() } } label: {
                    HStack(spacing: 6) {
                        HairlineIcon(name: "studio", size: 16, color: DS.Colors.textPrimary, selected: studio.panelVisible, live: studio.isOn && studio.liveCount > 0)
                        Text("Studio")
                    }
                }
                .buttonStyle(.theoSecondary).help("Show or hide your bots' screens")
            }
            HairlineIcon(name: "more", size: 18, color: DS.Colors.textSecondary).frame(width: 30, height: 30)
                .coverMenu(help: "More") {
                    if bot?.primary == true {
                        Button { TheoCallController.start() } label: { Label("Call \(bot?.name ?? "Theo")", systemImage: "phone") }
                    }
                    Button {
                        store.clearConversation(conversationID)
                        settledIDs = []
                    } label: { Label("New chat", systemImage: "square.and.pencil") }
                    .disabled(canStop)
                    if bot != nil {
                        Divider()
                        Button { NotificationCenter.default.post(name: .theoShowBotSettings, object: nil) } label: { Label("Settings for this chat", systemImage: "slider.horizontal.3") }
                    }
                }
        }
        .padding(.horizontal, 22).padding(.top, 12).frame(height: 72)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1) }
        // Runs up under the window's title bar, level with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// One line under the name: "Paused, waiting for you · 4 min", what it's doing, why it failed, or who it is.
    private func headerDetail(for bot: NativeBot, state: PixelState, now: Date) -> String {
        let since = store.stateSince(of: bot)
        let age = since.map { " · " + Self.minutes(since: $0, now: now) } ?? ""
        switch state {
        case .needs:
            if let connector = ConnectorHealth.shared.blockingConnector(of: bot.id) { return "Waiting for you to sign in to \(connector.name)" + age }
            return "Paused, waiting for you" + age
        case .failed:
            return (bot.lastFailure?.firstSentence ?? "It stopped") + age
        case .working, .thinking:
            let live = store.liveStatus(of: bot)
            return live + age
        default:
            return statusLine(for: bot)
        }
    }

    /// "4 min", "1 h".
    static func minutes(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return "\(Int(seconds / 3600)) h"
    }

    /// "Online · Claude Sonnet 5.5 · high · 2 routines" under the bot's name.
    private func statusLine(for bot: NativeBot) -> String {
        var parts = [!bot.isOn ? "Off" : inProgress.isEmpty ? "Online" : "Working"]
        parts.append(bot.modelLabel.replacingOccurrences(of: "Claude ", with: ""))
        if let effort = bot.effort { parts.append(effort) }
        if bot.primary { parts.append("leads \(store.bots.filter { !$0.primary }.count) bots") }
        for team in store.categories(of: bot.id) {
            parts.append(team.leaderID == bot.id ? "Manages \(team.name)" : "In \(team.name)")
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
                // Off, or stuck on an app: the card says so even before the first message.
                ChatStatusCards(bot: store.bot(bot.id) ?? bot).frame(maxWidth: 440).padding(.top, 8)
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
        .frame(maxWidth: 480).frame(maxWidth: .infinity)
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
        let dictating = dictation.isActive(for: conversationID)
        let isFinishing = dictating && dictation.phase == .finishing
        return VStack(alignment: .leading, spacing: 10) {
            if case .problem(let problem) = dictation.phase, dictation.ownerID == conversationID {
                ComposerDictationNote(problem: problem, onOpenSettings: dictation.openPermissionSettings, onDismiss: dictation.dismissNote)
            }
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
            if dictating {
                ComposerDictationField(live: dictation.live, isFinishing: isFinishing)
                ComposerDictationBar(live: dictation.live, isFinishing: isFinishing, onCancel: dictation.cancel, onKeep: dictation.stop)
            } else {
            TextField(bot.map { "Message \($0.name), or type / for commands" } ?? "Message \(group?.name ?? "the group")",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(send)
                .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 2)
            HStack(spacing: 6) {
                Button(action: chooseAttachments) {
                    HairlineIcon(name: "plus", size: 18, color: DS.Colors.textSecondary)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Attach files")
                HairlineIcon(name: "at", size: 18, color: DS.Colors.textSecondary).frame(width: 30, height: 30)
                    .coverMenu(help: "Mention a bot, or send work to the coding agent") {
                        ForEach(mentionable) { member in
                            Button("@\(member.name)") { draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + "@\(member.name) " }
                        }
                        Button("@code (straight to the coding agent)") { draft += "@code " }
                    }
                if let bot {
                    ModelChip(store: store, bot: bot)
                    EffortChip(store: store, bot: bot)
                }
                Spacer()
                if dictationEnabled && products.isOn(.dictation) {
                    Button { dictation.toggle(conversationID) } label: {
                        HairlineIcon(name: "mic", size: 18, color: DS.Colors.textSecondary)
                            .frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(dictationHelp)
                }
                if canStop && isEmpty {
                    Button {
                        if let bot {
                            if !inProgress.isEmpty { store.stop(bot.id) }
                            store.stopPrivateMessages(in: conversationID)
                        } else if let groupID {
                            store.stopGroup(groupID)
                        }
                    } label: {
                        HairlineIcon(name: "stop", size: 16, color: DS.Colors.textPrimary)
                            .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain).help("Stop")
                } else {
                    Button(action: send) {
                        HairlineIcon(name: "send", size: 18, color: isEmpty ? DS.Colors.textTertiary : DS.Colors.textOnAccent)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isEmpty ? DS.Colors.surface : DS.Colors.accent))
                    }
                    .buttonStyle(.plain).disabled(isEmpty).help("Send")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.surface1))
        .background(ComposerDictationAnchor())
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(dictating || composerFocused ? DS.Colors.accent.opacity(dictating ? 1 : 0.6) : DS.Colors.borderStrong, lineWidth: dictating || composerFocused ? 1.5 : 1))
        .onAppear { attachDictation() }
        .onDisappear { dictation.detach(conversationID) }
        .onChange(of: composerFocused) { _, focused in dictation.noteFocus(conversationID, focused: focused) }
        .frame(maxWidth: 704)
        .padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 6)
        .frame(maxWidth: .infinity)
        .dropDestination(for: URL.self) { files, _ in
            let local = files.filter(\.isFileURL)
            attachments += local.filter { !attachments.contains($0) }
            return !local.isEmpty
        }
    }

    private var dictationHelp: String {
        if products.dictationAccess == .needsKey { return "Dictation needs a Sarvam API key" }
        switch ComposerDictationSettings.shortcut {
        case .optionSpace: return "Dictate (⌥Space or ⌘⇧D)"
        case .commandShiftD: return "Dictate (⌘⇧D)"
        case .micButtonOnly: return "Dictate"
        }
    }

    private func attachDictation() {
        let draft = $draft
        let focused = $composerFocused
        dictation.attach(ComposerDictation.Composer(id: conversationID, text: { draft.wrappedValue }, land: { text, cursor in
            draft.wrappedValue = text
            focused.wrappedValue = true
            // The field comes back on the next pass, then its editor can take the cursor.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { ComposerDictation.shared.placeCursor(cursor) }
        }))
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

/// The composer's model: click for this engine's models, one click from the rest of the bot's settings.
struct ModelChip: View {
    @ObservedObject var store: BotsStore
    let bot: NativeBot
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Text(bot.modelLabel.replacingOccurrences(of: "Claude ", with: "")).font(.system(size: 12)).lineLimit(1)
                .foregroundColor(DS.Colors.textSecondary).padding(.horizontal, 9).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.selected))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Change the model")
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 1) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(BotModels.list(for: bot), id: \.self) { model in
                            Button {
                                var edited = bot
                                edited.model = model
                                store.save(edited)
                                open = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).frame(width: 12).opacity(bot.model == model ? 1 : 0)
                                    Text(BotModels.label(model, on: bot.provider)).font(.system(size: 13)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .foregroundColor(DS.Colors.textPrimary).padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(SidebarButtonStyle(isSelected: false))
                        }
                    }
                }
                .frame(maxHeight: 280)
                RowDivider().padding(.vertical, 4)
                Button {
                    open = false
                    NotificationCenter.default.post(name: .theoShowBotSettings, object: nil)
                } label: {
                    Text("Engine, effort and more…").font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(SidebarButtonStyle(isSelected: false))
            }
            .padding(6).frame(width: 260)
        }
    }
}

/// How hard the bot thinks: Auto until someone picks.
struct EffortChip: View {
    @ObservedObject var store: BotsStore
    let bot: NativeBot

    var body: some View {
        let levels = HarnessCatalog.info(bot.provider)?.efforts ?? []
        Text(bot.effort?.capitalized ?? "Auto").font(.system(size: 12)).lineLimit(1)
            .foregroundColor(DS.Colors.textSecondary).padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.selected))
            .coverMenu(help: "How hard it thinks") {
                Button("Auto") { set(nil) }
                ForEach(levels, id: \.self) { level in Button(level.capitalized) { set(level) } }
            }
    }

    private func set(_ effort: String?) {
        var edited = bot
        edited.effort = effort
        store.save(edited)
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
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous)
        HStack {
            Spacer(minLength: 120)
            Text(text)
                .font(.system(size: 14)).foregroundColor(DS.Colors.textPrimary).lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(shape.fill(DS.Colors.surface))
                .overlay(shape.strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        }
    }
}

struct ThinkingLine: View {
    let bot: NativeBot
    let showsName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                BotAvatar(bot: bot, size: 28, state: .thinking, badge: false)
                if showsName { Text(bot.name).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary) }
                TypingDots()
            }
        }
    }
}

struct BotLine: View {
    let bot: NativeBot
    let text: String
    let showsName: Bool
    /// In a group chat the name goes above the words; in a bot's own chat the figure says who it is.
    var namesAuthor = true
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
        HStack(alignment: .top, spacing: 10) {
            if showsName {
                BotAvatar(bot: bot, size: 28, state: typing ? .typing : .idle, badge: false)
            } else {
                Color.clear.frame(width: 26, height: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
            if showsName && namesAuthor {
                Text(bot.name).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
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
            .frame(maxWidth: ChatText.measure, alignment: .leading)
            }
            .padding(.top, 3)
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
        .task(id: "\(total)|\(isLive)") {
            // Marks the reveal done once it has caught up and the stream has ended. A stale isLive here once kept finished lines
            // redrawing at 30 fps for good, so this is keyed on it and waits once rather than polling.
            guard !finished, !isLive else { return }
            let left = Double(total - shownCount(at: Date())) / rate
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000) + 50_000_000) }
            if !Task.isCancelled { finished = true }
        }
    }

    /// With Reduce Motion the words just appear as they arrive.
    private var typing: Bool { animatesIn && !finished && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A timeline's date can be a moment before the anchor, so this never goes below what was already showing.
    private func shownCount(at date: Date) -> Int {
        min(total, anchorCount + Int(max(0, date.timeIntervalSince(anchorDate)) * rate))
    }

    @ViewBuilder private func typedContent(count: Int) -> some View {
        let shown = String(text.prefix(count))
        let split = shown.range(of: "\n\n", options: .backwards)
        let done = split.map { String(shown[..<$0.lowerBound]) } ?? ""
        let current = split.map { String(shown[$0.upperBound...]) } ?? shown
        VStack(alignment: .leading, spacing: 14) {
            if !done.isEmpty { RichBlock(text: done).equatable() }
            // The same style as the finished text, so nothing jumps when typing ends. The dot sits right after the last word.
            (Text(BotMarkdown.attributed(current)) + Text(" ●").font(.system(size: 8)).foregroundColor(bot.accentColor))
                .font(ChatText.font).foregroundColor(DS.Colors.textPrimary).lineSpacing(ChatText.lineSpacing)
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
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // Inline code reads as a small chip.
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(size: 13.5, design: .monospaced)
            result[run.range].backgroundColor = DS.Colors.selected
        }
        return result
    }
}

/// Short chats start at the top and long ones at the newest line (macOS 15's roles; the bottom on 14).
/// A run card appearing, changing to its result, or opening its terminal stays in view whole.
struct ChatRunScroll: ViewModifier {
    let proxy: ScrollViewProxy
    let runKeys: [String]

    func body(content: Content) -> some View {
        content
            .onChange(of: runKeys) { _, _ in
                for delay in [0.3, 1.2, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .theoScrollChatToEnd)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) } }
            }
    }
}

struct ChatScrollAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
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
    /// A bot's colour: its screen glow.
    static func swatch(for bot: NativeBot) -> Swatch {
        let glow = CrewLook.hex(bot.crewLook.glow)
        return Swatch(id: bot.id, from: glow, to: glow)
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

/// A bot's crew figure, in the pose its real state calls for.
struct BotAvatar: View {
    let bot: NativeBot
    let size: CGFloat
    let state: BotAvatarState
    var badge = true
    /// The face follows the bot's real state, so it watches what that state comes from.
    @ObservedObject private var store = BotsStore.shared
    @ObservedObject private var health = ConnectorHealth.shared
    /// The surface behind it, for the badge's ring.
    var ring: Color? = nil

    var body: some View {
        // The newest copy of the bot: a row can hold one from before its failure was recorded or cleared.
        let current = store.bot(bot.id) ?? bot
        let shown = store.pixelState(of: current, state: state)
        CrewAvatar(look: current.crewLook, size: size, pose: shown.state, poseUntil: shown.until, badge: badge, name: bot.name, ring: ring)
    }
}

/// A thin line in the sidebar from a team's tile down to its members: a stem and a tick to each row.
struct TeamGuideLine: Shape {
    var isLast: Bool
    /// How far down the row the tick lands; nil is the row's middle.
    var tickAt: CGFloat? = nil

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = tickAt ?? rect.midY
        path.move(to: CGPoint(x: 1, y: rect.minY))
        path.addLine(to: CGPoint(x: 1, y: isLast ? y : rect.maxY))
        path.move(to: CGPoint(x: 1, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        return path
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
            .onAppear {
                guard !DS.Motion.isReduced else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

// MARK: - Connectors

struct ConnectorsScreen: View {
    let bots: [NativeBot]
    @ObservedObject private var health = ConnectorHealth.shared
    @ObservedObject private var store = BotsStore.shared
    @State private var note: String?
    @State private var working: String?
    /// The row whose details are open.
    @State private var openRow: String?

    private var connectors: [BotConnector] {
        BotConnectors.known.filter { $0.id != "calendar" }
            .enumerated()
            .sorted { left, right in
                let leftOrder = health.state(of: left.element).sortOrder
                let rightOrder = health.state(of: right.element).sortOrder
                return leftOrder != rightOrder ? leftOrder < rightOrder : left.offset < right.offset
            }
            .map(\.element)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connectors").font(TheoType.title).foregroundColor(DS.Colors.textPrimary)
                    Text("Bots on Claude use your claude.ai connectors. Bots on OpenCode and Grok reach Gmail, Notion and Google through Theo, on the same account, read and draft only.")
                        .font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    summaryPills
                    Spacer(minLength: 16)
                    Button { Task { await health.refresh() } } label: {
                        Label(health.isChecking ? "Checking…" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(health.isChecking).buttonStyle(.theo(.secondary, .small))
                }
                if let note {
                    Text(note).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(connectors.enumerated()), id: \.element.id) { index, connector in
                        if index > 0 { RowDivider() }
                        row(connector)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                otherServersSection
            }
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await health.refresh() }
    }

    /// "6 connected", "1 needs sign-in", "1 can't connect".
    @ViewBuilder private var summaryPills: some View {
        let states = BotConnectors.known.filter { $0.id != "calendar" && !$0.isSkill }.map { health.state(of: $0) }
        let connected = states.filter { [.connected, .claudeOnly, .othersOnly].contains($0) }.count
        let signIn = states.filter { $0 == .needsSignIn }.count
        let failed = states.filter { if case .failed = $0 { return true }; return false }.count
        if health.lastChecked == nil, health.isChecking {
            StatusPill(text: "Checking", tone: .checking)
        } else {
            if connected > 0 { StatusPill(text: "\(connected) connected", tone: .good) }
            if signIn > 0 { StatusPill(text: "\(signIn) need\(signIn == 1 ? "s" : "") sign-in", tone: .warn) }
            if failed > 0 { StatusPill(text: "\(failed) can't connect", tone: .bad) }
        }
    }

    /// One row per connector: its tile, who uses it (each bot's micro face, then the names), one status pill and one button.
    private func row(_ connector: BotConnector) -> some View {
        let users = bots.filter { $0.apps.contains(connector.id) || (connector.id == "notion" && $0.apps.contains("calendar")) }
        let state = health.state(of: connector)
        let waiting = health.botsWaiting(on: connector.id).compactMap { store.bot($0) }
        let pill = state.pill
        return VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: openRow == connector.id ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(DS.Colors.textTertiary).frame(width: 10)
            AppLogo(connector: connector, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(connector.name).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                HStack(spacing: 5) {
                    if users.isEmpty {
                        Text("No bot uses it yet").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                    } else {
                        HStack(spacing: -3) {
                            ForEach(users.prefix(4)) { bot in
                                CrewAvatar(look: bot.crewLook, size: 16, pose: store.pixelState(of: bot).state, moves: false, interactive: false, badge: false, name: bot.name)
                            }
                        }
                        Text(users.map(\.name).joined(separator: ", ")).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                    }
                }
                if let extra = extraLine(connector, state: state, waiting: waiting) {
                    Text(extra.text).font(TheoType.caption).foregroundColor(extra.color).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            StatusPill(text: pill.text, tone: PixelCard<EmptyView>.legacy(pill.tone))
            Group {
                switch state {
                case .needsSignIn:
                    Button(working == connector.id ? "Signing in…" : "Sign in") { signIn(connector, bot: waiting.first) }
                        .buttonStyle(.theo(.primary, .small)).disabled(working != nil)
                case .failed:
                    Button("Try again") { Task { await health.refresh() } }.buttonStyle(.theo(.secondary, .small)).disabled(health.isChecking)
                case .missing, .claudeOnly, .othersOnly:
                    if canConnect(connector, state: state) {
                        // Next to "Claude bots only", Connect would read as if it weren't connected at all: say what it adds.
                        Button(working == connector.id ? "Signing in…" : state == .claudeOnly ? "Connect OpenCode" : "Connect") { connect(connector, state: state) }
                            .buttonStyle(.theo(.secondary, .small)).disabled(working != nil)
                            // Its own width: in the fixed slot "Connect OpenCode" was cut to "Connect OpenC…".
                            .fixedSize()
                    } else {
                        Color.clear
                    }
                default:
                    Color.clear
                }
            }
            // At least the old slot (so pills line up), wider only for a longer button; fixedSize keeps an empty slot from
            // stretching and pushing the pill left.
            .frame(minWidth: 128, minHeight: 26, maxHeight: 26, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 56)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(DS.Motion.hover) { openRow = openRow == connector.id ? nil : connector.id } }
        .pointerCursor()
        if openRow == connector.id { details(connector, state: state, users: users) }
        }
    }

    /// What a row opens to: each engine's own answer, the reason if it isn't answering, when it last worked, who uses it.
    private func details(_ connector: BotConnector, state: ConnectorHealth.RowState, users: [NativeBot]) -> some View {
        let claudeSide = health.onClaude(connector)
        let openCodeSide = health.onOpenCode(connector)
        return VStack(alignment: .leading, spacing: 6) {
            detailLine("Bots on Claude", connector.claudeServer == nil ? "Not available" : claudeSide.label)
            detailLine("Bots on OpenCode and Grok", BotConnectors.bridged(connector) ? "Through Theo, on your Claude sign-in" : (connector.openCodeServer == nil ? "Not available" : openCodeSide.label))
            if let reason = claudeSide.failureReason ?? openCodeSide.failureReason { detailLine("What it said", reason) }
            detailLine("Last worked", health.lastConnected[connector.id].map { ConnectorListing.workedAgo($0).replacingOccurrences(of: "worked ", with: "") } ?? "Not seen connected yet")
            detailLine("Used by", users.isEmpty ? "No bot yet" : users.map(\.name).joined(separator: ", "))
            if let server = connector.claudeServer { detailLine("Name in Claude Code", server) }
        }
        .padding(.leading, 66).padding(.trailing, 14).padding(.bottom, 12)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).frame(width: 170, alignment: .leading)
            Text(value).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every other server the engines list (a claude.ai connector added on the web, a local MCP server), with its state.
    @ViewBuilder private var otherServersSection: some View {
        let others = health.otherServers()
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Other servers your engines see").font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.element.name) { index, server in
                        if index > 0 { RowDivider() }
                        HStack(spacing: 12) {
                            AppTile(symbol: "server.rack", size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ConnectorHealth.displayName(server.name)).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                                Text(server.state.failureReason.map { "On \(server.engine) · " + $0 } ?? "On \(server.engine)").font(TheoType.caption).foregroundColor(server.state.isFailed ? PixelTone.failed.text : DS.Colors.textTertiary).lineLimit(2)
                            }
                            Spacer(minLength: 12)
                            StatusPill(text: server.state.label, tone: server.state == .connected ? .good : server.state == .needsSignIn ? .warn : server.state.isFailed ? .bad : .neutral)
                            Group {
                                if server.state == .needsSignIn, server.name.hasPrefix("claude.ai") {
                                    Button("Sign in") { BotConnectors.openClaudeConnectors() }.buttonStyle(.theo(.primary, .small))
                                } else if server.state.isFailed {
                                    Button("Try again") { Task { await health.refresh() } }.buttonStyle(.theo(.secondary, .small))
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 128, height: 26, alignment: .trailing)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 52)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            }
        }
    }

    /// "Researcher is waiting on this" in yellow, the reason and when it last worked in red, or what other engines can't do.
    private func extraLine(_ connector: BotConnector, state: ConnectorHealth.RowState, waiting: [NativeBot]) -> (text: String, color: Color)? {
        switch state {
        case .needsSignIn where !waiting.isEmpty:
            return (BotChatScreen.list(waiting.map(\.name)) + (waiting.count == 1 ? " is" : " are") + " waiting on this", PixelTone.needs.text)
        case .failed(let reason):
            let worked = health.lastConnected[connector.id].map { " · " + ConnectorListing.workedAgo($0) } ?? ""
            return (ConnectorListing.plainReason(reason, app: connector.name) + worked, PixelTone.failed.text)
        case .claudeOnly:
            return ("Bots on OpenCode and Grok can't use it yet", DS.Colors.textTertiary)
        default:
            return connector.id == "notion" ? ("Includes Notion Calendar", DS.Colors.textTertiary) : nil
        }
    }

    private func canConnect(_ connector: BotConnector, state: ConnectorHealth.RowState) -> Bool {
        if state == .claudeOnly { return !BotConnectors.bridged(connector) && connector.openCodeURL != nil }
        return connector.claudeServer?.hasPrefix("claude.ai") == true || connector.openCodeURL != nil
    }

    private func connect(_ connector: BotConnector, state: ConnectorHealth.RowState) {
        if state == .missing, connector.claudeServer?.hasPrefix("claude.ai") == true {
            BotConnectors.openClaudeConnectors()
            note = "claude.ai's connector page is open. Add \(connector.name) there; Theo checks again when you press Refresh."
            return
        }
        working = connector.id
        Task {
            if TheoProfile.isTest {
                TheoOpen.record("opencode mcp add+auth \(connector.openCodeServer ?? connector.id)")
                note = "Adding \(connector.name) to OpenCode (recorded in the test profile)."
            } else {
                note = await BotConnectors.addToOpenCode(connector)
            }
            working = nil
            await health.refresh()
        }
    }

    private func signIn(_ connector: BotConnector, bot: NativeBot?) {
        working = connector.id
        Task {
            note = await health.signIn(connector, forBot: bot)
            working = nil
            await health.refresh()
        }
    }
}

/// A coding run while it works, for someone who has never read a terminal: where it's got to in plain words, with the
/// raw terminal one click away. Stop asks first.
struct T3RunCard: View {
    let run: T3Run
    /// Whose work it is, for its figure and its tile.
    var bot: NativeBot? = nil
    @ObservedObject private var terminals = TerminalSessions.shared
    @ObservedObject private var studio = StudioController.shared
    @State private var showsTerminal = false
    @State private var confirmsStop = false

    private var engine: String { run.harness.map(HarnessCatalog.label) ?? "T3 Code" }
    private var session: TerminalSession? { terminals.session(for: run.id) }
    private var tile: StudioTileID? { bot.flatMap { studio.roster.tile(of: $0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                if let bot {
                    CrewAvatar(look: bot.crewLook, size: 28, pose: run.phase == "waiting" ? .needs : .working, name: bot.name, ring: DS.Colors.surface1)
                } else {
                    BrandLogo(id: run.harness ?? "t3", name: engine, size: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    (Text(bot?.name ?? engine).font(.system(size: 12.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                     + Text(" · \(run.title)").font(.system(size: 12.5)).foregroundColor(DS.Colors.textSecondary)).lineLimit(1)
                    HStack(spacing: 6) {
                        RunMacChip(run: run)
                        Text(detailLine).font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // The pill carries the timer while working, "Waiting 2:10" when paused on the owner.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let time = Self.elapsed(since: run.startedAt, now: context.date)
                    StatusPill(text: run.phase == "waiting" ? "Waiting \(time)" : run.phase == "reporting" ? "Finishing \(time)" : time,
                               tone: run.phase == "waiting" ? .warn : .working)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
            }
            RunStepBar(fills: RunSteps.fills(phase: run.phase, stage: run.stage), stopping: run.stoppedByOwner == true)
                .padding(.top, 12)
            RunTerminalLine(text: terminalLine, waiting: run.phase == "waiting")
                .padding(.top, 10)
            if run.phase == "waiting" {
                RunFollowupBox(run: run, placeholder: "Answer it here").padding(.top, 10)
            }
            HStack(spacing: 8) {
                if let tile {
                    Button { studio.panelVisible = true } label: {
                        HStack(spacing: 6) { HairlineIcon(name: "eye", size: 15, color: DS.Colors.textPrimary); Text("Watch on Screen \(tile.screen + 1)") }
                    }
                    .buttonStyle(.theoSecondary).help("Show its tile in the Studio panel")
                }
                if session != nil {
                    Button {
                        withAnimation(DS.Motion.hover) { showsTerminal.toggle() }
                        NotificationCenter.default.post(name: .theoScrollChatToEnd, object: nil)
                    } label: {
                        HStack(spacing: 6) { HairlineIcon(name: "term", size: 15, color: DS.Colors.textSecondary); Text(showsTerminal ? "Hide terminal" : "Show terminal") }
                    }
                    .buttonStyle(.theoGhost)
                    if showsTerminal {
                        Button { TerminalWindowController.pop(sessionID: run.id) } label: { Image(systemName: "arrow.up.forward.square").frame(width: 14) }
                            .buttonStyle(.theoGhost).help("Open in its own window")
                    }
                } else if run.isRemote {
                    RemoteRunBadge(run: run, showsTerminal: $showsTerminal)
                } else if run.link != nil || run.harness != nil {
                    Button { BotsT3.openInApp(run) } label: { Label(run.harness == nil ? "Open in T3 Code" : "Watch", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.theoGhost)
                }
                Spacer(minLength: 0)
                if run.phase != "reporting" {
                    Button { confirmsStop = true } label: {
                        HStack(spacing: 6) { HairlineIcon(name: "stop", size: 15, color: DS.Colors.textSecondary); Text("Stop") }
                    }
                    .buttonStyle(.theoGhost).help(run.harness == nil ? "Stop following this run" : "Stop this run")
                }
            }
            .padding(.top, 10)
            if showsTerminal, run.isRemote { RemoteRunTerminal(run: run).padding(.top, 10) }
            if showsTerminal, let session {
                // The harness's own terminal, live: watch it work and type into it.
                TerminalPanel(session: session)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                    .padding(.top, 10)
            }
        }
        .padding(.top, 12).padding(.horizontal, 13).padding(.bottom, 13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(run.phase == "waiting" ? PixelTone.needs.cardBorder : DS.Colors.borderSubtle, lineWidth: 1))
        .alert("Stop this run?", isPresented: $confirmsStop) {
            Button("Stop", role: .destructive) { BotsStore.shared.stopRun(run.id) }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text(run.harness == nil ? "The agent stops and its thread stays in T3 Code." : "The agent stops now. What it did so far stays on its branch.")
        }
    }

    /// The agent's latest words, without Markdown marks, or what it's doing in general until it has said something.
    private var terminalLine: String {
        if run.stoppedByOwner == true { return "Stopping. What it did so far is being saved." }
        let words = (run.activity ?? "").replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return words.isEmpty ? "Reading the code and working out what to change." : words
    }

    private var detailLine: String {
        var parts = [engine]
        if let chat = run.continuedChat { parts.append("Continuing \(chat)") } else if let model = run.model { parts.append(NativeBot.label(for: model)) }
        if run.chatUnknown == true { parts.append("Couldn't tell which chat it made") }
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

/// Branch, Code, Tests, Push, PR: five segments and their names. Finished steps green, the current one half green, a step
/// waiting on the owner yellow, the step that failed red.
struct RunStepBar: View {
    let fills: [RunSteps.Fill]
    var stopping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    GeometryReader { box in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.Colors.borderStrong)
                            if fills[index] != .todo {
                                Capsule().fill(color(fills[index])).frame(width: fills[index] == .active ? box.size.width * 0.5 : box.size.width)
                            }
                        }
                    }
                    .frame(height: 4)
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    Text(RunSteps.titles[index]).font(.system(size: 10.5))
                        .foregroundColor(fills[index] == .failed ? PixelTone.failed.text : fills[index] == .waiting ? PixelTone.needs.text : fills[index] == .active ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func color(_ fill: RunSteps.Fill) -> Color {
        if stopping { return DS.Colors.textTertiary }
        switch fill {
        case .done, .active: return DS.Colors.success
        case .waiting: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
        case .todo: return .clear
        }
    }
}

/// One line of the run's terminal with a blinking caret. It stays dark in both themes.
struct RunTerminalLine: View {
    let text: String
    var waiting = false
    @State private var caretOn = true

    var body: some View {
        HStack(spacing: 6) {
            Text("$").foregroundColor(Color(hex: 0x777777))
            Text(text).foregroundColor(Color(hex: 0xCFCFCF)).lineLimit(1).truncationMode(.head)
            if !waiting {
                Rectangle().fill(Color(hex: 0xDDDDDD)).frame(width: 7, height: 13).opacity(caretOn ? 1 : 0)
                    .task {
                        guard DS.Motion.level != .off else { return }
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            caretOn.toggle()
                        }
                    }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct RunFollowupBox: View {
    let run: T3Run
    var placeholder = "Ask for a change"
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                .onSubmit(send)
                .theoField(focused: focused)
            Button("Send", action: send).buttonStyle(.theo(.secondary, .small)).disabled(trimmed.isEmpty)
        }
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        BotsStore.shared.sendFollowup(trimmed, on: run)
        text = ""
    }
}

/// What a bot answers when asked to change how it runs: its settings, working, right in the chat.
struct BotSettingsChatCard: View {
    let botID: String
    @ObservedObject private var store = BotsStore.shared
    @State private var addsSchedule = false

    var body: some View {
        if let bot = store.bot(botID) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    BotAvatar(bot: bot, size: 26, state: .idle)
                    Text("\(bot.name)'s settings").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                    Spacer(minLength: 8)
                    Button("All settings") { NotificationCenter.default.post(name: .theoShowBotSettings, object: nil) }
                        .buttonStyle(.theo(.ghost, .small))
                }
                // Changes from elsewhere (a message, the column) redraw the pickers.
                BotModelSettings(bot: bot, onChange: { store.save($0) }, compact: true)
                    .id("\(bot.provider)|\(bot.model)|\(bot.effort ?? "")|\(bot.thinking ?? false)|\(bot.fast ?? false)")
                Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
                HStack {
                    Text("Schedules").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Button { addsSchedule = true } label: { Label("Add schedule", systemImage: "plus") }.buttonStyle(.theo(.ghost, .small))
                }
                let routines = store.routines(for: bot.id)
                if routines.isEmpty {
                    Text("None yet. Say \"every weekday at 9, …\" or add one here.").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                }
                ForEach(routines) { routine in
                    HStack(spacing: 8) {
                        Image(systemName: routine.paused ? "pause.circle" : "clock").font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(routine.name).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                            Text(routine.schedule.label).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                        }
                        Spacer(minLength: 8)
                        Button(routine.paused ? "Resume" : "Pause") { store.setPaused(!routine.paused, routineID: routine.id) }.buttonStyle(.theo(.ghost, .small))
                        Button("Run now") { store.runRoutineNow(routine.id) }.buttonStyle(.theo(.secondary, .small))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 400, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .padding(.leading, 38)
            .sheet(isPresented: $addsSchedule) { RoutineEditor(store: store, routine: nil, fixedTarget: bot.id) { addsSchedule = false } }
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
                        let offered = keys.usableChatProviders(for: bot.primary ? .theo : .bots)
                        ForEach(offered) { provider in
                            Text(provider.label).tag("api:\(provider.id)")
                        }
                        if bot.provider.hasPrefix("api:"), !offered.contains(where: { "api:\($0.id)" == bot.provider }) {
                            let hasKey = keys.usableChatProviders.contains { "api:\($0.id)" == bot.provider }
                            Text("\(String(bot.provider.dropFirst(4)))\(hasKey ? "" : " (no key)")").tag(bot.provider)
                        }
                        Text("Add a key…").tag("__add_key")
                    }
                }
                .labelsHidden().frame(maxWidth: compact ? .infinity : 260)
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
                    .labelsHidden().frame(maxWidth: compact ? .infinity : 260)
                }
            }
            row("Effort") {
                Picker("Effort", selection: Binding(get: { bot.effort ?? "" }, set: { bot.effort = $0.isEmpty ? nil : $0; commit() })) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden().frame(maxWidth: compact ? .infinity : 160)
            }
            row("Thinking") {
                Spacer(minLength: 0)
                Toggle("Thinking", isOn: Binding(get: { bot.thinking ?? false }, set: { bot.thinking = $0; commit() }))
                    .toggleStyle(.switch).labelsHidden().disabled(!isClaude)
            }
            row("Fast mode") {
                Spacer(minLength: 0)
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

extension Notification.Name {
    /// Opens the bot settings slide-over (the bot's name in the chat header sends it).
    static let theoShowBotSettings = Notification.Name("TheoShowBotSettings")
    static let theoScrollChatToEnd = Notification.Name("theoScrollChatToEnd")
    /// Home's "New group chat".
    static let theoNewGroupChat = Notification.Name("theoNewGroupChat")
    /// Opens a bot's chat (the object is its id): an alert's or the menu bar's button.
    static let theoOpenBot = Notification.Name("theoOpenBot")
}

/// One bot's reply while it streams. It's the only view that watches the words, so a chunk redraws this line and nothing else.
private struct LiveReplyLine: View {
    let bot: NativeBot
    let showsName: Bool
    let namesAuthor: Bool
    let proxy: ScrollViewProxy
    @Binding var lastLive: [String: String]
    @ObservedObject private var live = BotLiveText.shared

    private var text: String { live.text[bot.id] ?? "" }

    var body: some View {
        Group {
            if text.isEmpty {
                ThinkingLine(bot: bot, showsName: namesAuthor)
            } else {
                BotLine(bot: bot, text: text, showsName: showsName, namesAuthor: namesAuthor, animatesIn: true, isLive: true)
            }
        }
        // Remembered so the finished message doesn't type out a second time.
        .onChange(of: "\(text.isEmpty) \(text.count / 200)") { _, _ in if !text.isEmpty { lastLive[bot.id] = text } }
        // Follows the reply every few lines rather than on every chunk.
        .onChange(of: text.count / 240) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        .onDisappear { if !text.isEmpty { lastLive[bot.id] = text } }
    }
}
