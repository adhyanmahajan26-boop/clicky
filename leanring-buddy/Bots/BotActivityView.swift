//
//  BotActivityView.swift
//  leanring-buddy
//
//  Everything the bots said to each other and to the owner, in one line of time across every chat, with who said it to whom and
//  what went wrong picked out. It's the place to see where a piece of work got stuck.
//

import ClickyCore
import SwiftUI

struct ActivityItem: Identifiable {
    let id: String
    let at: Date
    let from: String
    let to: String
    let text: String
    let isProblem: Bool
    let room: String?
}

extension BotsStore {
    private func activityName(_ id: String) -> String {
        if id == "user" { return "You" }
        if id == Self.clickyID { return "Clicky" }
        if id == "routine" { return "Call" }
        return bot(id)?.name ?? group(forRoom: id)?.name ?? (id == Self.teamID ? "Project room" : id)
    }

    private static let problemWords = #"(?i)\b(couldn't|could not|can't|cannot|failed|stopped before|error|not connected|isn't answering|unreadable|didn't start|lost track|nothing has been sent)\b"#

    /// The last two days, oldest first.
    var activityItems: [ActivityItem] {
        let since = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        var items: [ActivityItem] = []
        for (room, record) in conversations {
            for message in record.messages where message.at >= since {
                var text = message.text
                var from = activityName(message.author)
                var to = message.author == room ? "You" : activityName(room)
                // A private thread: from one bot to the other.
                if let partner = BotDMThread.partner(of: message.author, in: room) { to = activityName(partner) }
                var failed = false
                if let jobID = Self.delegationID(of: message), let job = delegation(jobID) {
                    if text.isEmpty {
                        text = job.task
                        from = activityName(room)
                        to = job.workerName
                    }
                    failed = message.text.isEmpty ? false : job.phase == .failed
                }
                guard !text.isEmpty else { continue }
                let isProblem = failed || (message.author != "user" && text.range(of: Self.problemWords, options: .regularExpression) != nil)
                items.append(ActivityItem(id: room + message.id, at: message.at, from: from, to: to, text: text, isProblem: isProblem, room: room))
            }
        }
        for run in t3Runs where run.startedAt >= since {
            let engine = run.harness.map(HarnessCatalog.label) ?? "T3 Code"
            let model = run.model.map { " on \(NativeBot.label(for: $0))" } ?? ""
            items.append(ActivityItem(id: "run-start" + run.id, at: run.startedAt, from: "Theo", to: engine, text: "Started \(run.title)\(model), in \(run.folder)", isProblem: false, room: run.room))
            if let finished = run.finishedAt {
                items.append(ActivityItem(id: "run-end" + run.id, at: finished, from: engine, to: "Theo", text: "\(run.title): \(run.phase)", isProblem: run.phase == "failed", room: run.room))
            }
        }
        return items.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
    }

    func pane(forRoom room: String) -> BotsPane {
        if room == Self.clickyID { return .clicky }
        // A private thread opens on one of its two bots, whose settings list it.
        if let pair = BotDMThread.members(of: room) { return .bot(pair.first) }
        if let group = group(forRoom: room) { return .group(group.id) }
        return .bot(room)
    }
}

struct ActivityScreen: View {
    @ObservedObject var store: BotsStore
    @ObservedObject var selection: BotsSelection
    @State private var onlyProblems = false
    @State private var opened: Set<String> = []

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm:ss"
        return formatter
    }()

    var body: some View {
        let items = store.activityItems.filter { !onlyProblems || $0.isProblem }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity").font(TheoType.title).foregroundColor(DS.Colors.textPrimary)
                    Text("Every message between you and the bots, across all chats, in order.").font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
                }
                Spacer()
                Toggle("Only problems", isOn: $onlyProblems).toggleStyle(.switch).font(TheoType.body)
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if items.isEmpty {
                            Text(onlyProblems ? "Nothing's gone wrong in the last two days." : "Nothing in the last two days.").font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
                        }
                        ForEach(items) { item in row(item).id(item.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { if let last = items.last { reader.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .padding(24)
    }

    private func row(_ item: ActivityItem) -> some View {
        let isOpen = opened.contains(item.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if item.isProblem { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(DS.Colors.warning) }
                Text("\(item.from) → \(item.to)").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                Text(Self.time.string(from: item.at)).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                Spacer()
                if let room = item.room {
                    Button("Open chat") { selection.pane = store.pane(forRoom: room) }.buttonStyle(.theo(.ghost, .small))
                }
            }
            Text(item.text).font(TheoType.body).foregroundColor(DS.Colors.textSecondary).lineLimit(isOpen ? nil : 3).textSelection(.enabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.surface1))
        .contentShape(Rectangle())
        .onTapGesture { if isOpen { opened.remove(item.id) } else { opened.insert(item.id) } }
    }
}
