//
//  BotDetailsView.swift
//  leanring-buddy
//
//  A bot's details, opened from its name (as in Grok Bot): its look,
//  instructions, model, apps and routines, and deleting it. Plus the
//  Routines page, where every schedule can be watched, paused, run or
//  removed, and the small pieces both use.
//

import AppKit
import ClickyCore
import SwiftUI

// MARK: - Details

struct BotDetailsSheet: View {
    @ObservedObject var store: BotsStore
    let botID: String
    let onDone: () -> Void
    @State private var tab = 0
    @State private var draft: NativeBot?
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let bot = draft ?? store.bot(botID) {
                HStack(spacing: 12) {
                    BotAvatar(bot: bot, size: 46, state: .idle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bot.name).font(.system(size: 17, weight: .semibold))
                        Text(bot.description).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Done") { commit(); onDone() }.keyboardShortcut(.defaultAction)
                }
                .padding(20)
                Picker("", selection: $tab) {
                    Text("Details").tag(0)
                    Text("Routines (\(store.routines(for: botID).count))").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20)
                Divider().padding(.top, 12)
                ScrollView {
                    if tab == 0 { details } else { RoutineList(store: store, target: botID, showsTarget: false).padding(20) }
                }
            }
        }
        .frame(width: 560, height: 640)
        .onAppear { draft = store.bot(botID) }
        .alert("Delete \(draft?.name ?? "this bot")?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
                if BotsSelection.shared.pane == .bot(botID) { BotsSelection.shared.pane = .team }
                store.deleteBot(botID)
                onDone()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its chat and routines go too. Hide it from the sidebar instead to keep it working.")
        }
    }

    private func commit() { if let draft { store.save(draft) } }

    @ViewBuilder private var details: some View {
        if let binding = Binding($draft) {
            VStack(alignment: .leading, spacing: 18) {
                field("Name") { TextField("Name", text: binding.name).textFieldStyle(.roundedBorder) }
                field("What it does") { TextField("Shown under its name", text: binding.description).textFieldStyle(.roundedBorder) }
                field("Look") { LookButton(bot: binding) }
                field("Instructions") {
                    TextEditor(text: binding.instructions)
                        .font(.system(size: 12.5)).frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }
                field("Model") {
                    BotModelSettings(bot: binding.wrappedValue) { updated in
                        // Model settings save as they change; keep the draft in step.
                        draft?.provider = updated.provider
                        draft?.model = updated.model
                        draft?.effort = updated.effort
                        draft?.thinking = updated.thinking
                        draft?.fast = updated.fast
                        store.save(updated)
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.hover))
                }
                field("Apps") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(BotConnectors.known) { connector in
                            Toggle(isOn: Binding(get: { binding.wrappedValue.apps.contains(connector.id) }, set: { on in
                                if on { draft?.apps.append(connector.id) } else { draft?.apps.removeAll { $0 == connector.id } }
                            })) {
                                Label(connector.name, systemImage: connector.symbol).font(.system(size: 12.5))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                field("Memory") {
                    Button("Open its memory file") {
                        let path = (binding.wrappedValue.memoryPath as NSString).expandingTildeInPath
                        if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    .buttonStyle(.link)
                }
                if !binding.wrappedValue.primary {
                    Divider()
                    HStack {
                        Button(store.isHidden("bot:\(botID)") ? "Show in sidebar" : "Hide from sidebar") {
                            store.setHidden(!store.isHidden("bot:\(botID)"), "bot:\(botID)")
                        }
                        Spacer()
                        Button("Delete bot…", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .padding(20)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.secondary)
            content()
        }
    }
}

// MARK: - Routines

/// Every routine, in one place: watch the schedules, pause, resume, run now, delete, and see the runs.
struct RoutinesScreen: View {
    @ObservedObject var store: BotsStore
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Routines").font(TheoType.title).foregroundColor(DS.Colors.textPrimary)
                    Text("Bots doing a job on a schedule. Ask any bot in chat (\"every weekday at 8, check my inbox…\") or add one here.")
                        .font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Button { adding = true } label: { Label("New routine", systemImage: "plus") }.buttonStyle(.theoSecondary)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            Divider().overlay(DS.Colors.hover)
            ScrollView {
                if store.routines.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 40)).foregroundColor(DS.Colors.textTertiary)
                        Text("No routines yet").font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        Text("Try telling a bot: \"every weekday at 8:30, sum up what needs a reply\".")
                            .font(.system(size: 12.5)).foregroundColor(DS.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 90)
                } else {
                    RoutineList(store: store, target: nil, showsTarget: true).padding(24)
                }
            }
        }
        .sheet(isPresented: $adding) { RoutineEditor(store: store, routine: nil, fixedTarget: nil) { adding = false } }
    }
}

/// Routines (of one bot, or all of them) as cards with their controls and recent runs.
struct RoutineList: View {
    @ObservedObject var store: BotsStore
    /// A bot id, or nil for every routine.
    let target: String?
    let showsTarget: Bool
    @State private var editing: BotRoutine?
    @State private var adding = false
    @State private var expanded: Set<String> = []

    private var items: [BotRoutine] { target.map { store.routines(for: $0) } ?? store.routines }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if target != nil {
                HStack {
                    Text(items.isEmpty ? "No routines yet. Ask the bot in chat (\"every morning at 9, …\") or add one." : "")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Button { adding = true } label: { Label("New routine", systemImage: "plus") }.buttonStyle(.theo(.secondary, .small))
                }
            }
            ForEach(items) { routine in card(routine) }
        }
        .sheet(item: $editing) { routine in RoutineEditor(store: store, routine: routine, fixedTarget: nil) { editing = nil } }
        .sheet(isPresented: $adding) { RoutineEditor(store: store, routine: nil, fixedTarget: target) { adding = false } }
    }

    private func card(_ routine: BotRoutine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: routine.paused ? "pause.circle.fill" : "clock.fill")
                    .font(.system(size: 18)).foregroundColor(routine.paused ? DS.Colors.textTertiary : DS.Colors.success)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(routine.name).font(.system(size: 13.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        if showsTarget {
                            Text(store.targetName(routine.target)).font(.system(size: 10.5, weight: .medium)).foregroundColor(DS.Colors.accentText)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(DS.Colors.accent.opacity(0.15)))
                        }
                        if routine.paused {
                            Text("Paused").font(.system(size: 10.5, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    Text(routine.schedule.label + nextText(routine)).font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary)
                    Text(routine.instruction).font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary).lineLimit(2)
                }
                Spacer()
                HStack(spacing: 6) {
                    control(routine.paused ? "Resume" : "Pause", routine.paused ? "play.fill" : "pause.fill") {
                        store.setPaused(!routine.paused, routineID: routine.id)
                    }
                    control("Run now", "bolt.fill") { store.runRoutineNow(routine.id) }
                    Menu {
                        Button("Edit…") { editing = routine }
                        Button("Delete", role: .destructive) { store.deleteRoutine(routine.id) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            if !routine.runs.isEmpty {
                Button {
                    if expanded.contains(routine.id) { expanded.remove(routine.id) } else { expanded.insert(routine.id) }
                } label: {
                    HStack(spacing: 6) {
                        if let last = routine.lastRun { statusDot(last.status) }
                        Text(lastRunText(routine)).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                        Image(systemName: expanded.contains(routine.id) ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                .buttonStyle(.plain).padding(.leading, 28)
                if expanded.contains(routine.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(routine.runs.reversed()) { run in
                            HStack(alignment: .top, spacing: 6) {
                                statusDot(run.status)
                                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary)
                                Text(run.summary ?? run.status).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.surface1))
    }

    private func nextText(_ routine: BotRoutine) -> String {
        guard !routine.paused, let next = routine.nextRunAt else { return "" }
        return " · next \(next.formatted(.relative(presentation: .named)))"
    }

    private func lastRunText(_ routine: BotRoutine) -> String {
        guard let last = routine.lastRun else { return "" }
        return "Last run \(last.startedAt.formatted(.relative(presentation: .named))): \(last.status) · \(routine.runs.count) run\(routine.runs.count == 1 ? "" : "s")"
    }

    private func statusDot(_ status: String) -> some View {
        Circle().fill(status == "done" ? DS.Colors.success : status == "running" ? DS.Colors.blue : status == "failed" ? DS.Colors.destructiveText : DS.Colors.textTertiary)
            .frame(width: 7, height: 7).padding(.top, 4)
    }

    private func control(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(DS.Colors.hover))
        }
        .buttonStyle(.plain).foregroundColor(DS.Colors.textPrimary)
    }
}

struct RoutineEditor: View {
    @ObservedObject var store: BotsStore
    @State private var routine: BotRoutine
    let onDone: () -> Void
    private let isNew: Bool
    private let fixedTarget: String?

    init(store: BotsStore, routine: BotRoutine?, fixedTarget: String?, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        self.fixedTarget = fixedTarget
        isNew = routine == nil
        _routine = State(initialValue: routine ?? BotRoutine(name: "", target: fixedTarget ?? store.bots.first?.id ?? "",
                                                              instruction: "", schedule: .init(kind: .weekdays, hour: 9, minute: 0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New routine" : "Edit routine").font(.system(size: 17, weight: .semibold))
            TextField("Name (Morning inbox, Weekly report…)", text: $routine.name).textFieldStyle(.roundedBorder)
            if fixedTarget == nil {
                Picker("Who runs it", selection: $routine.target) {
                    ForEach(store.bots) { bot in Text(bot.name).tag(bot.id) }
                    ForEach(store.groups.filter { $0.headID != nil }) { group in Text("\(group.name) (group chat)").tag("group:\(group.id)") }
                }
            }
            Text("Instruction").font(.system(size: 11.5, weight: .semibold)).foregroundColor(.secondary)
            TextEditor(text: $routine.instruction).font(.system(size: 12.5)).frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text("When to run").font(.system(size: 11.5, weight: .semibold)).foregroundColor(.secondary)
            HStack {
                Picker("", selection: $routine.schedule.kind) {
                    Text("Every day").tag(BotRoutine.Kind.daily)
                    Text("Weekdays").tag(BotRoutine.Kind.weekdays)
                    Text("Weekly").tag(BotRoutine.Kind.weekly)
                    Text("Every hour").tag(BotRoutine.Kind.hourly)
                    Text("Every N minutes").tag(BotRoutine.Kind.every)
                }
                .labelsHidden().frame(width: 150)
                switch routine.schedule.kind {
                case .daily, .weekdays, .weekly:
                    if routine.schedule.kind == .weekly {
                        Picker("", selection: $routine.schedule.weekday) {
                            ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
                        }
                        .labelsHidden().frame(width: 120)
                    }
                    DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute).labelsHidden()
                case .hourly:
                    Stepper("at :\(String(format: "%02d", routine.schedule.minute))", value: $routine.schedule.minute, in: 0...59, step: 5)
                case .every:
                    Stepper("every \(routine.schedule.intervalMinutes) min", value: $routine.schedule.intervalMinutes, in: 5...1440, step: 5)
                }
            }
            Text(routine.schedule.label).font(.system(size: 11)).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add routine" : "Save") {
                    var saved = routine
                    if saved.name.trimmingCharacters(in: .whitespaces).isEmpty { saved.name = String(saved.instruction.prefix(40)) }
                    store.save(saved)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(routine.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || routine.target.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: routine.schedule.hour, minute: routine.schedule.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            routine.schedule.hour = Calendar.current.component(.hour, from: date)
            routine.schedule.minute = Calendar.current.component(.minute, from: date)
        })
    }
}

// MARK: - Small pieces

/// A routine's run in a chat: a quiet marker instead of a message from you.
struct RoutineMarker: View {
    let text: String
    let at: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill").font(.system(size: 10))
            Text(text.replacingOccurrences(of: "⏰ ", with: "")).font(.system(size: 11.5)).lineLimit(2)
            Text("· " + at.formatted(date: .omitted, time: .shortened)).font(.system(size: 11))
        }
        .foregroundColor(DS.Colors.textTertiary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(DS.Colors.hover))
        .frame(maxWidth: .infinity)
    }
}

/// A group chat's tile: its first four bots as a 2x2 mosaic inside one rounded square.
struct GroupAvatar: View {
    let bots: [NativeBot]
    let size: CGFloat

    var body: some View {
        let tile = size * 0.4
        let gap = max(1.5, size * 0.06)
        let shown = Array(bots.prefix(4))
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(DS.Colors.surface)
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .overlay(
                VStack(spacing: gap) {
                    HStack(spacing: gap) { cell(shown, 0, tile); cell(shown, 1, tile) }
                    HStack(spacing: gap) { cell(shown, 2, tile); cell(shown, 3, tile) }
                }
            )
            .frame(width: size, height: size)
    }

    @ViewBuilder private func cell(_ shown: [NativeBot], _ index: Int, _ tile: CGFloat) -> some View {
        if index < shown.count {
            CrewAvatar(look: shown[index].crewLook, size: tile, moves: false, interactive: false)
        } else {
            RoundedRectangle(cornerRadius: tile * 0.3, style: .continuous).fill(DS.Colors.hover).frame(width: tile, height: tile)
        }
    }
}

extension NativeBot {
    /// The SF Symbol drawn as the avatar's body for its shape.
    var shapeSymbol: String? {
        switch shape ?? "orb" {
        case "square": return "app.fill"
        case "sparkle": return "sparkle"
        case "clover": return "suit.club.fill"
        case "flower": return "camera.macro"
        case "heart": return "heart.fill"
        case "star": return "star.fill"
        default: return nil
        }
    }
}
