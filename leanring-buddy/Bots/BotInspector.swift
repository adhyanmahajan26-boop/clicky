//
//  BotInspector.swift
//  leanring-buddy
//
//  The settings column beside a chat, like Grok Bot's: everything about the
//  bot in one place, edited in place and saved as you go. Name, description,
//  on/off, look, brain, authority and whom it may message, instructions, apps
//  (with their logos and whether they're connected) and schedules (each with
//  its own on/off). Clicky gets its own column: brain, helpers, cursor, voice.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

// MARK: - Bot column

struct BotInspector: View {
    @ObservedObject var store: BotsStore
    let botID: String
    @State private var draft: NativeBot?
    @State private var addingRoutine = false
    @State private var confirmsDelete = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            if let bot = draft {
                VStack(alignment: .leading, spacing: 20) {
                    identity(bot)
                    InspectorSection("Brain") {
                        BotModelSettings(bot: bot, onChange: { updated in
                            // Only the brain's fields: the rest of the snapshot may be older than the column.
                            draft?.provider = updated.provider
                            draft?.model = updated.model
                            draft?.effort = updated.effort
                            draft?.thinking = updated.thinking
                            draft?.fast = updated.fast
                            commit()
                        }, compact: true)
                        .id(bot.provider + bot.model)
                    }
                    authority(bot)
                    InspectorSection("Screen", hint: StudioController.isAvailable ? "Where this bot's screen jobs and its desk go: its own screen first, then the shared pool. A coder's terminal stays on your monitors." : "Screens live on the Mac Studio.") {
                        if StudioController.isAvailable { BotScreenPicker(botID: bot.id).labelsHidden() }
                    }
                    InspectorSection("Instructions", hint: "Your words come first. Every bot also learns Theo's harness guide: how to message, hand over, schedule and start code.") {
                        TextEditor(text: Binding(get: { draft?.instructions ?? "" }, set: { draft?.instructions = $0; saveSoon() }))
                            .font(.system(size: 12.5)).scrollContentBackground(.hidden)
                            .padding(8).frame(minHeight: 130)
                            .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.hover))
                        Button { NSWorkspace.shared.open(BotMemory.guideFile) } label: {
                            Label("Read the harness guide", systemImage: "book")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.theo(.ghost, .small))
                        .pointerCursor()
                    }
                    apps(bot)
                    schedules(bot)
                    BotPrivateThreadsList(store: store, botID: bot.id)
                    if !bot.primary {
                        if bot.owner == nil {
                            Button {
                                commit()
                                store.makePrimary(bot.id)
                                draft = store.bot(botID)
                            } label: {
                                Label("Make \(bot.name) the primary bot", systemImage: "star")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.theo(.ghost, .small))
                        }
                        danger(bot)
                    }
                }
                .padding(18)
                .frame(width: 340)
            }
        }
        .frame(width: 340)
        .clipped()
        .background(DS.Colors.surface1)
        .onAppear { draft = store.bot(botID) }
        .onChange(of: botID) { _, id in draft = store.bot(id) }
        // A change made elsewhere (make primary, the sidebar's on/off, the control inbox) shows here,
        // unless an edit of this column is still waiting to be saved.
        .onReceive(store.$bots) { bots in
            guard saveTask == nil, let fresh = bots.first(where: { $0.id == botID }) else { return }
            if fresh != draft { draft = fresh }
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            commit()
        }
        .sheet(isPresented: $addingRoutine) { RoutineEditor(store: store, routine: nil, fixedTarget: botID) { addingRoutine = false } }
        .alert("Delete \(draft?.name ?? "this bot")?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
                saveTask?.cancel()
                saveTask = nil
                draft = nil
                BotsSelection.shared.pane = .bot(store.primary?.id ?? "theo")
                store.deleteBot(botID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(draft?.owner != nil
                 ? "Its chat goes too, and a hidden helper does this job for Clicky from now on. Turn it off or hide it instead to keep it."
                 : "Its chat and routines go too. Turn it off or hide it instead to keep it.")
        }
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            saveTask = nil
            commit()
        }
    }

    /// Saves the column's edits. A bot that was deleted meanwhile stays deleted.
    private func commit() {
        guard let draft, let stored = store.bot(botID), draft != stored else { return }
        store.save(draft)
    }

    // MARK: Parts

    private func identity(_ bot: NativeBot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                LookButton(bot: Binding(get: { draft ?? bot }, set: { draft = $0; commit() }))
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0; saveSoon() }))
                        .textFieldStyle(.plain).font(.system(size: 17, weight: .semibold))
                        // The close button sits at this height.
                        .padding(.trailing, 28)
                    TextField("What it does", text: Binding(get: { draft?.description ?? "" }, set: { draft?.description = $0; saveSoon() }), axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).lineLimit(1...3)
                }
            }
            HStack {
                Label(bot.isOn ? "On" : "Off", systemImage: bot.isOn ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(bot.isOn ? DS.Colors.success : DS.Colors.textTertiary)
                Text(bot.isOn ? "Answers, runs its schedules and joins group chats" : "Paused: no replies, schedules or group turns")
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(2)
                Spacer()
                Toggle("", isOn: Binding(get: { draft?.isOn ?? true }, set: { draft?.enabled = $0; commit() }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.hover))
        }
    }

    private func authority(_ bot: NativeBot) -> some View {
        InspectorSection("Authority", hint: "Who this bot may give work to. A CEO can message any bot; a lead, the bots of the group chats it heads; anyone, the bots you tick.") {
            Picker("", selection: Binding(get: { draft?.authorityLevel ?? "member" }, set: { draft?.authority = $0; commit() })) {
                Text("Member").tag("member")
                Text("Lead").tag("lead")
                Text("CEO").tag("ceo")
            }
            .pickerStyle(.segmented).labelsHidden()
            let others = store.bots.filter { $0.id != bot.id }
            if !others.isEmpty && (draft?.authorityLevel ?? "member") != "ceo" {
                Text("Can also message").font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textTertiary).padding(.top, 4)
                FlowChips(items: others.map { ($0.id, $0.name) }, selected: Set(draft?.canMessage ?? [])) { id, on in
                    var list = draft?.canMessage ?? []
                    if on { list.append(id) } else { list.removeAll { $0 == id } }
                    draft?.canMessage = list
                    commit()
                }
            }
        }
    }

    private func apps(_ bot: NativeBot) -> some View {
        InspectorSection("Apps", hint: "Click to give or take away an app. The dot shows whether it's connected for this bot's engine.") {
            AppsGrid(selected: Set(bot.apps), provider: bot.provider) { id, on in
                if on { draft?.apps.append(id) } else { draft?.apps.removeAll { $0 == id } }
                commit()
            }
        }
    }

    private func schedules(_ bot: NativeBot) -> some View {
        InspectorSection("Schedules") {
            let routines = store.routines(for: bot.id)
            if routines.isEmpty {
                Text("None yet. Ask \(bot.name) in chat (\"every weekday at 9, …\") or add one.")
                    .font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary)
            }
            ForEach(routines) { routine in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routine.name).font(.system(size: 12.5, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                        Text(routine.schedule.label).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer()
                    Button { store.runRoutineNow(routine.id) } label: { Image(systemName: "bolt.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundColor(DS.Colors.textSecondary).help("Run now")
                    Toggle("", isOn: Binding(get: { !routine.paused }, set: { store.setPaused(!$0, routineID: routine.id) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 9).fill(DS.Colors.hover))
                .contextMenu { Button("Delete", role: .destructive) { store.deleteRoutine(routine.id) } }
            }
            Button { addingRoutine = true } label: { Label("Add schedule", systemImage: "plus") .font(.system(size: 12, weight: .medium)) }
                .buttonStyle(.plain).foregroundColor(DS.Colors.accentText)
        }
    }

    private func danger(_ bot: NativeBot) -> some View {
        HStack {
            Button(store.isHidden("bot:\(bot.id)") ? "Show in sidebar" : "Hide from sidebar") {
                store.setHidden(!store.isHidden("bot:\(bot.id)"), "bot:\(bot.id)")
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Button("Delete bot") { confirmsDelete = true }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.destructiveText)
        }
        .padding(.top, 6)
    }
}

// MARK: - Clicky column

/// Clicky's own column: the brain it thinks with, its helpers, its cursor (one click), voice and listening.
struct ClickyInspector: View {
    @State private var main = ClickyModels.main
    @State private var helper = ClickyModels.helper
    @State private var style = ClickySettings.sparkStyle
    @State private var silent = ClickySettings.isSilentModeEnabled
    @State private var listens = ClickySettings.isWakeWordEnabled
    @State private var actions = ClickySettings.isActionsEnabled
    @State private var memoryQuery = ""
    @State private var memoryHits: [ClickyMemoryHit] = []
    @ObservedObject private var store = BotsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    LookButton(bot: Binding(get: { store.clickyBot }, set: { if let look = $0.look { store.setLook(look, for: BotsStore.clickyID) } }))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Clicky").font(.system(size: 17, weight: .semibold))
                        Text("Your screen companion. Sees your screens, points, draws boards, researches and acts on Theo's own screen.")
                            .font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                    }
                }
                HStack {
                    Label(clickyOn ? "On" : "Off", systemImage: clickyOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(clickyOn ? DS.Colors.success : DS.Colors.textTertiary)
                    Text(clickyOn ? "Listening, with its cursor on screen" : "Asleep: no listening, cursor hidden")
                        .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    Toggle("", isOn: Binding(get: { clickyOn }, set: { setClicky($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.hover))
                team
                InspectorSection("Brain") {
                    Text("Thinks with").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                    BrainModelPicker(title: "Thinks with", setting: Binding(get: { main }, set: { value in
                        main = value
                        if let manager = CompanionManager.current { manager.setSelectedModel(value) } else { ClickyModels.main = value }
                    }))
                    Text("Hidden helpers").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                    BrainModelPicker(title: "Hidden helpers", setting: Binding(get: { helper }, set: { helper = $0; ClickyModels.helper = $0 }))
                    Button("All of Clicky's settings") { TheoSettingsWindowController.show(section: .clicky) }.buttonStyle(.theo(.ghost, .small))
                }
                InspectorSection("Cursor", hint: "One click changes it everywhere.") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(CompanionIconStyle.allCases, id: \.self) { item in
                            Button { style = item; ClickySettings.sparkStyle = item } label: {
                                VStack(spacing: 4) {
                                    CompanionIconPreview(style: item).frame(width: 26, height: 26)
                                    Text(item.displayName).font(.system(size: 9.5)).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.surface))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(style == item ? DS.Colors.accent : DS.Colors.hover, lineWidth: style == item ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                InspectorSection("Voice") {
                    Button("Choose Clicky's voice") { TheoSettingsWindowController.show(section: .clicky) }.buttonStyle(.theo(.ghost, .small))
                }
                InspectorSection("Behaviour") {
                    toggle("Listens for \"hey \(ClickySettings.assistantName)\"", $listens) { value in
                        if let manager = CompanionManager.current { manager.wakeWordController.setEnabled(value) } else { ClickySettings.isWakeWordEnabled = value }
                    }
                    toggle("Speaks answers", Binding(get: { !silent }, set: { silent = !$0 })) { value in ClickySettings.isSilentModeEnabled = !value }
                    toggle("Acts on screen (opens, clicks, types)", $actions) { value in
                        UserDefaults.standard.set(value, forKey: ClickySettings.Keys.actionsEnabled)
                    }
                }
            }
            .padding(18)
            .frame(width: 340)
        }
        .frame(width: 340)
        .clipped()
        .background(DS.Colors.surface1)
    }

    /// The bots Clicky runs, and what Memory has kept.
    private var team: some View {
        InspectorSection("Team", hint: "Clicky hands these bots its background jobs. Rename or remove any of them; a hidden helper does a removed bot's job.") {
            ForEach(store.clickyTeam) { bot in
                Button { BotsSelection.shared.pane = .bot(bot.id) } label: {
                    HStack(spacing: 10) {
                        BotAvatar(bot: bot, size: 26, state: store.replying[bot.id] != nil ? .thinking : .idle)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bot.name).font(.system(size: 12.5, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                            Text((store.replying[bot.id] != nil ? "Working" : bot.isOn ? "Ready" : "Off") + " · " + bot.modelLabel)
                                .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if store.clickyTeam.isEmpty {
                Text("Hidden helpers do the team's jobs now.").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
            }
            TextField("Search what you've said to Clicky", text: $memoryQuery)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.hover))
                .onChange(of: memoryQuery) { _, query in
                    memoryHits = query.trimmingCharacters(in: .whitespaces).count < 2 ? [] : store.memoryStore.search(query, limit: 6)
                }
            ForEach(Array(memoryHits.enumerated()), id: \.offset) { _, hit in
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.text).font(.system(size: 12)).foregroundColor(DS.Colors.textPrimary).lineLimit(3).textSelection(.enabled)
                    Text(hit.at.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary)
                }
            }
            if memoryHits.isEmpty, memoryQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text("Nothing on that yet.").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private var clickyOn: Bool { listens || (CompanionManager.current?.isClickyCursorEnabled ?? true) }

    /// Clicky on or off as a whole: its wake word and its cursor together.
    private func setClicky(_ on: Bool) {
        listens = on
        if let manager = CompanionManager.current {
            manager.wakeWordController.setEnabled(on)
            manager.setClickyCursorEnabled(on)
        } else {
            ClickySettings.isWakeWordEnabled = on
        }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>, apply: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; apply($0) })) {
            Text(title).font(.system(size: 12.5))
        }
        .toggleStyle(.switch).controlSize(.small)
    }
}

// MARK: - Pieces

struct InspectorSection<Content: View>: View {
    let title: String
    let hint: String?
    let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(DS.Colors.textTertiary)
            content
            if let hint { Text(hint).font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// The avatar, which opens the gallery of characters.
struct LookButton: View {
    @Binding var bot: NativeBot
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            BotAvatar(bot: bot, size: 52, state: .idle)
                // Top corner: the bottom one is the status badge's.
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "paintbrush.pointed.fill").font(.system(size: 8)).foregroundColor(.white)
                        .padding(4).background(Circle().fill(Color.black.opacity(0.7)))
                }
        }
        .buttonStyle(.plain).help("Make your bot")
        .sheet(isPresented: $open) {
            MakeYourBotSheet(name: bot.name, look: bot.crewLook, isClicky: bot.id == BotsStore.clickyID) { saved in
                if let saved { bot.look = saved }
                open = false
            }
        }
    }
}

/// Bots as tappable chips, ticked or not.
struct FlowChips: View {
    let items: [(String, String)]
    let selected: Set<String>
    let onToggle: (String, Bool) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { id, name in
                let on = selected.contains(id)
                Button { onToggle(id, !on) } label: {
                    Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 9).padding(.vertical, 5).frame(maxWidth: .infinity)
                        .background(Capsule().fill(on ? DS.Colors.selected : DS.Colors.hover))
                        .overlay(Capsule().strokeBorder(on ? DS.Colors.borderStrong : .clear, lineWidth: 1))
                        .foregroundColor(on ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The apps a bot can use, as logo tiles: tap to give or take one away. Each tile wears a tick, "?" or cross on its corner
/// for whether the app works for this bot's engine.
struct AppsGrid: View {
    let selected: Set<String>
    let provider: String
    let onToggle: (String, Bool) -> Void
    @ObservedObject private var health = ConnectorHealth.shared

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
            ForEach(BotConnectors.known) { connector in
                let on = selected.contains(connector.id)
                let state = health.state(for: connector, provider: provider)
                Button { onToggle(connector.id, !on) } label: {
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottomTrailing) {
                            AppLogo(connector: connector, size: 28)
                            if let badge = Self.badge(state) {
                                PixelBadge(tone: badge, size: 15, ring: DS.Colors.surface1).offset(x: 6, y: 5)
                            }
                        }
                        Text(connector.name.replacingOccurrences(of: " (screen, voice, notes)", with: ""))
                            .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        Text(health.label(for: connector, provider: provider)).font(.system(size: 9.5)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 78)
                    .background(RoundedRectangle(cornerRadius: 11).fill(on ? DS.Colors.accent.opacity(0.16) : DS.Colors.hover))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(on ? DS.Colors.accent : DS.Colors.hover, lineWidth: on ? 1.5 : 1))
                    .overlay(alignment: .topTrailing) {
                        if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(DS.Colors.accent).padding(5) }
                    }
                }
                .buttonStyle(.plain)
                .help(health.label(for: connector, provider: provider))
            }
        }
        .onAppear { health.refreshIfStale() }
    }

    static func badge(_ state: ConnectorState) -> PixelTone? {
        switch state {
        case .connected: return .ok
        case .needsSignIn: return .needs
        case .failed: return .failed
        case .missing, .unknown: return nil
        }
    }
}

/// A connector's real logo, bundled with the app (Assets.xcassets/Logos). Theo's own tools show Clicky's tile.
struct AppLogo: View {
    let connector: BotConnector
    let size: CGFloat

    var body: some View {
        if connector.id == "theo" {
            ClickyAvatar(size: size)
        } else if BrandLogo.hasLogo(connector.id) {
            BrandLogo(id: connector.id, name: connector.name, size: size)
        } else {
            IconTile(symbol: connector.symbol, colors: connector.id == "studio" ? TileColors.violet : TileColors.ember, size: size)
        }
    }
}

