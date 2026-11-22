//
//  BotTeamsSettings.swift
//  leanring-buddy
//
//  Settings › Bot teams: ready-made teams, each a category with a manager and the bots who report to it, added whole in
//  one click. The owner can change any of them (names, jobs, instructions, models, who manages), make their own, save a
//  category they already have as a team, and import or export team files (the same files Windows reads). The library is
//  `ReadyMadeTeamLibrary`; adding a team is `BotsStore.addReadyMadeTeam`.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct BotTeamsSettingsContent: View {
    @ObservedObject private var library = ReadyMadeTeamLibrary.shared
    @ObservedObject private var store = BotsStore.shared
    /// The team being edited in the sheet: a copy, saved only on Save.
    @State private var editing: ReadyMadeTeam?
    /// What the last Add, import or save did, under the team it was about (nil id: at the top).
    @State private var lastNote: (teamID: String?, text: String)?
    @State private var openTeamIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "", hint: "Adding a team makes its category, its manager and its bots in the sidebar, on your CEO's brain. Adding it again makes a second copy with numbered names. You can also ask \(store.primary?.name ?? "Vello") in chat: \u{201C}add the Research Desk\u{201D}.") {
                HStack(spacing: 8) {
                    Button { editing = library.blankTeam() } label: { Label("New team", systemImage: "plus") }
                        .buttonStyle(.theoSecondary).pointerCursor()
                    Button { importTeams() } label: { Label("Import a team file…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.theoSecondary).pointerCursor()
                    saveCategoryMenu
                    Spacer(minLength: 0)
                }
                .padding(12)
                if let lastNote, lastNote.teamID == nil {
                    RowDivider()
                    noteLine(lastNote.text)
                }
            }
            ForEach(library.teams) { team in teamCard(team) }
            if library.hasRemovedBuiltIns {
                Button("Show Vello's teams I removed") { library.restoreBuiltIns() }
                    .buttonStyle(.theoGhost).pointerCursor()
            }
        }
        .sheet(item: $editing) { draft in
            ReadyMadeTeamEditor(team: draft, isNew: library.team(draft.id) == nil) { saved in
                let problem = library.save(saved)
                if problem == nil {
                    editing = nil
                    lastNote = (saved.id, "Saved. Add it to put its bots in the sidebar.")
                }
                return problem
            } onCancel: { editing = nil }
        }
    }

    // MARK: - One team

    private func teamCard(_ team: ReadyMadeTeam) -> some View {
        let isOpen = openTeamIDs.contains(team.id)
        let isBuiltIn = ReadyMadeTeams.isBuiltIn(team.id)
        return TheoSection(title: "") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(team.name).font(TheoType.headline).foregroundColor(DS.Colors.textPrimary)
                    if !isBuiltIn { chip("Yours") } else if ReadyMadeTeams.isChanged(team) { chip("Changed") }
                    Spacer(minLength: 8)
                    Text("\(team.members.count) bots").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                }
                if !team.purpose.isEmpty {
                    Text(team.purpose).font(TheoType.body).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                memberRow(team.manager, isManager: true, showsJob: true)
                if isOpen {
                    ForEach(Array(team.workers.enumerated()), id: \.offset) { _, worker in memberRow(worker, isManager: false, showsJob: true) }
                } else {
                    Text("Reporting to \(team.manager.name): " + TeamBuildOrder.listedInWords(team.workers.map(\.name)) + ".")
                        .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                HStack(spacing: 8) {
                    Button("Add to Vello") { add(team) }.buttonStyle(.theoPrimary).pointerCursor()
                    Button("Edit") { editing = team }.buttonStyle(.theoSecondary).pointerCursor()
                    Button(isOpen ? "Hide jobs" : "Show every job") {
                        if isOpen { openTeamIDs.remove(team.id) } else { openTeamIDs.insert(team.id) }
                    }
                    .buttonStyle(.theoGhost).pointerCursor()
                    Spacer(minLength: 0)
                    Menu {
                        Button("Duplicate") { let copy = library.duplicate(team); lastNote = (copy.id, "A copy of \(team.name), yours to change.") }
                        Button("Export to a file…") { export([team]) }
                        if isBuiltIn && ReadyMadeTeams.isChanged(team) {
                            Button("Put back Vello's version") { library.reset(team.id) }
                        }
                        Divider()
                        Button(isBuiltIn ? "Remove from this list" : "Delete this team", role: .destructive) { library.remove(team.id) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 30, height: 26).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointerCursor()
                    .help("More for \(team.name)")
                }
                .padding(.top, 2)
                if let lastNote, lastNote.teamID == team.id {
                    Text(lastNote.text).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private func memberRow(_ member: ReadyMadeTeam.Member, isManager: Bool, showsJob: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isManager ? "crown.fill" : "circle.fill")
                .font(.system(size: isManager ? 10 : 5)).foregroundColor(isManager ? DS.Colors.accent : DS.Colors.textTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(member.name).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                    if isManager { Text("Manager").font(TheoType.micro).foregroundColor(DS.Colors.textTertiary) }
                    if let model = member.model { Text(model).font(TheoType.micro).foregroundColor(DS.Colors.textTertiary) }
                }
                if showsJob && !member.does.isEmpty {
                    Text(member.does).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(TheoType.micro).foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(DS.Colors.hover))
    }

    private func noteLine(_ text: String) -> some View {
        Text(text).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Every category in the sidebar with bots of its own, to keep as a team.
    private var saveCategoryMenu: some View {
        let categories = store.layout.sections.filter { section in
            section.leaderID != BotsStore.clickyID && store.members(of: section).contains { !$0.primary && $0.owner == nil && $0.id != BotsStore.clickyID }
        }
        return Menu {
            ForEach(categories, id: \.id) { section in
                Button(section.name) {
                    if let team = library.saveCategory(section.id, store: store) {
                        lastNote = (team.id, "Saved \(section.name) as a team with \(team.members.count) bots, \(team.manager.name) managing.")
                    }
                }
            }
        } label: {
            Label("Save a category as a team", systemImage: "square.and.arrow.down.on.square")
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(categories.isEmpty).pointerCursor()
        .help(categories.isEmpty ? "Make a category with bots in it first." : "Keep one of your categories here, to add again or send to someone.")
    }

    // MARK: - Actions

    private func add(_ team: ReadyMadeTeam) {
        let note = store.addReadyMadeTeam(team)
        lastNote = (team.id, note)
    }

    private func importTeams() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a Vello team file (.json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let added = library.importFile(url)
        lastNote = added.isEmpty
            ? (nil, "That file has no team Vello can read. A team file comes from Export, here or in Vello on Windows.")
            : (nil, "Imported " + TeamBuildOrder.listedInWords(added.map(\.name)) + ". Add " + (added.count == 1 ? "it" : "them") + " below to make the bots.")
    }

    private func export(_ teams: [ReadyMadeTeam]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = (teams.count == 1 ? teams[0].name : "Vello teams") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let wrote = library.export(teams, to: url)
        lastNote = (teams.count == 1 ? teams[0].id : nil, wrote ? "Saved to \(url.lastPathComponent)." : "Vello couldn't write that file.")
    }
}

// MARK: - Editor

/// Changes one team: its name and purpose, the manager, and every bot under it. Nothing is kept until Save.
struct ReadyMadeTeamEditor: View {
    @State var team: ReadyMadeTeam
    let isNew: Bool
    /// Saves the team; returns what's wrong with it instead, which the sheet shows.
    let onSave: (ReadyMadeTeam) -> String?
    let onCancel: () -> Void
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New team" : "Edit \(team.name)").font(TheoType.headline).foregroundColor(DS.Colors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            RowDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Team name") { TextField("Research Desk", text: $team.name).theoField() }
                    field("What it's for") { TextField("One line: it becomes the category's purpose", text: $team.purpose).theoField() }
                    Text("MANAGER").font(TheoType.label).tracking(0.6).foregroundColor(DS.Colors.textTertiary).padding(.top, 4)
                    memberEditor($team.manager, index: nil)
                    HStack {
                        Text("BOTS REPORTING TO THE MANAGER").font(TheoType.label).tracking(0.6).foregroundColor(DS.Colors.textTertiary)
                        Spacer()
                        Text("\(team.workers.count) of \(ReadyMadeTeams.mostWorkers)").font(TheoType.micro).foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.top, 4)
                    ForEach(team.workers.indices, id: \.self) { index in
                        memberEditor(worker(at: index), index: index)
                    }
                    Button { team.workers.append(.init(name: "", does: "")) } label: { Label("Add a bot", systemImage: "plus") }
                        .buttonStyle(.theoSecondary).pointerCursor()
                        .disabled(team.workers.count >= ReadyMadeTeams.mostWorkers)
                }
                .padding(20)
            }
            RowDivider()
            HStack(spacing: 8) {
                if let problem {
                    Text(problem).font(TheoType.caption).foregroundColor(DS.Colors.destructiveText).lineLimit(2)
                }
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.theoSecondary).keyboardShortcut(.cancelAction).pointerCursor()
                Button("Save") { problem = onSave(team) }.buttonStyle(.theoPrimary).keyboardShortcut(.defaultAction).pointerCursor()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 640, height: 680)
        .background(DS.Colors.background)
    }

    /// A bot under the manager, read and written by place. Checked against the count, so a field that's still drawing as
    /// its row is removed doesn't reach past the end.
    private func worker(at index: Int) -> Binding<ReadyMadeTeam.Member> {
        Binding(get: { index < team.workers.count ? team.workers[index] : ReadyMadeTeam.Member(name: "", does: "") },
                set: { if index < team.workers.count { team.workers[index] = $0 } })
    }

    /// One bot's fields. `index` is its place under the manager, nil for the manager itself.
    private func memberEditor(_ member: Binding<ReadyMadeTeam.Member>, index: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(index == nil ? "Manager's name" : "Bot's name", text: member.name).theoField()
                TextField("Model (empty: the usual one)", text: Binding(get: { member.wrappedValue.model ?? "" },
                                                                    set: { member.wrappedValue.model = $0.isEmpty ? nil : $0 }))
                    .theoField().frame(width: 210)
                    .help("Words a team block takes: \u{201C}haiku\u{201D}, \u{201C}Claude Opus 5.5\u{201D}, or an exact model id. A model this Mac doesn't have uses the usual one, and the note says so.")
            }
            TextField("One line on its job", text: member.does).theoField()
            TextEditor(text: member.instructions)
                .font(.system(size: 12.5)).frame(height: 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if member.wrappedValue.instructions.isEmpty {
                        Text("Its instructions, written to it as \u{201C}You are …\u{201D}. Empty: \u{201C}You are <name>. <its job>\u{201D}")
                            .font(.system(size: 12.5)).foregroundColor(DS.Colors.textTertiary).padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            if let index {
                HStack(spacing: 8) {
                    Button("Make manager") {
                        let oldManager = team.manager
                        team.manager = team.workers[index]
                        team.workers[index] = oldManager
                    }
                    .buttonStyle(.theo(.ghost, .small)).pointerCursor()
                    Button("Remove") { team.workers.remove(at: index) }
                        .buttonStyle(.theo(.destructive, .small)).pointerCursor()
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
            content()
        }
    }
}
