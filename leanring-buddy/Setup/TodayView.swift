//
//  TodayView.swift
//  leanring-buddy
//
//  Home: what's going on today, plainly. Clicky's state, the schedules due,
//  the latest builds and notes. No banners or gradients (docs/DESIGN.md).
//

import AppKit
import ClickyCore
import SwiftUI

struct TodayView: View {
    @ObservedObject var store: BotsStore
    @ObservedObject var selection: BotsSelection
    @State private var notes: [ClaudiaLibrary.Item] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center) {
                        Text(greeting).font(TheoType.title).foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        Button { TheoCallController.start() } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "phone.fill").font(.system(size: 12, weight: .semibold))
                                Text("Call \(store.primary?.name ?? "Theo")").font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white).padding(.horizontal, 14).frame(height: 34)
                            .background(Capsule().fill(Color(hex: 0x2FA36B)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).help("Start a voice call")
                    }
                    Text("Say \u{201C}hey \(ClickySettings.assistantName)\u{201D} for Clicky, or open a bot on the left.")
                        .font(.system(size: 14)).foregroundColor(DS.Colors.textSecondary)
                }
                section("Your team") {
                    OrgChart(store: store, selection: selection) {
                        let count = store.layout.sections.count
                        if let id = store.addSection(named: count == 0 ? "New category" : "New category \(count + 1)") {
                            selection.pane = .category(id)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(18)
                }
                section("Companion") {
                    row(icon: AnyView(ClickyAvatar(size: 28)), title: "Clicky",
                        detail: "Screen companion on \(NativeBot.label(for: ClickyModels.main))",
                        trailing: (CompanionManager.current?.isClickyCursorEnabled ?? true) ? "Awake" : "Asleep") {
                        selection.pane = .clicky
                    }
                }
                section("Schedules") {
                    let upcoming = store.routines.filter { !$0.paused }.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
                    if upcoming.isEmpty {
                        empty("No schedules yet. Ask any bot \u{201C}every weekday at 9, \u{2026}\u{201D} and it sets one up.")
                    }
                    ForEach(upcoming.prefix(4)) { routine in
                        row(icon: AnyView(target(routine.target)), title: routine.name,
                            detail: routine.schedule.label + " · " + store.targetName(routine.target),
                            trailing: routine.nextRunAt.map { $0.formatted(.relative(presentation: .named)) }) {
                            selection.pane = .routines
                        }
                    }
                }
                section("Builds") {
                    let runs = store.t3Runs.suffix(3).reversed()
                    if runs.isEmpty {
                        empty("Ask Theo to build something and the coding run shows here with its result.")
                    }
                    ForEach(Array(runs)) { run in
                        row(icon: AnyView(symbolTile(run.phase == "done" ? "checkmark" : run.phase == "failed" ? "exclamationmark" : "hammer")),
                            title: run.title,
                            detail: (run.activity ?? run.phase.capitalized).replacingOccurrences(of: "─", with: "").trimmingCharacters(in: .whitespaces),
                            trailing: (run.finishedAt ?? run.startedAt).formatted(.relative(presentation: .named))) {
                            if let room = run.room, let bot = store.bot(room) { selection.pane = .bot(bot.id) }
                            else if let room = run.room, let group = store.groups.first(where: { $0.roomID == room }) { selection.pane = .group(group.id) }
                            else if let primary = store.primary { selection.pane = .bot(primary.id) }
                        }
                    }
                }
                section("Notes") {
                    if notes.isEmpty { empty("Research, articles, whiteboards and screenshots land here.") }
                    ForEach(notes.prefix(4), id: \.id) { note in
                        row(icon: AnyView(symbolTile(note.kind == "whiteboard" ? "scribble.variable" : note.kind == "screenshot" ? "camera.viewfinder" : "doc.text")),
                            title: note.title.hasPrefix("Research ") ? String(note.title.dropFirst(9)) : note.title, detail: note.kind.capitalized,
                            trailing: note.date.formatted(.relative(presentation: .named))) {
                            selection.pane = .notes
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 40)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(DS.Colors.background)
        .task { notes = await Task.detached { ClaudiaLibrary.items() }.value }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 5 ? "Working late" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        }
    }

    private func row(icon: AnyView, title: String, detail: String, trailing: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    Text(detail).font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary) }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 14).frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(isSelected: false))
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
    }

    private func symbolTile(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.surface)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textSecondary))
            .frame(width: 28, height: 28)
    }

    @ViewBuilder private func target(_ target: String) -> some View {
        if let bot = store.bot(target) { BotAvatar(bot: bot, size: 28, state: .idle) } else { symbolTile("person.2") }
    }
}

/// The notes library as a page of the main window.
struct NotesScreen: View {
    var body: some View { NotesTab().background(DS.Colors.background) }
}

