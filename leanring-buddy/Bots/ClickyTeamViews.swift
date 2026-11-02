//
//  ClickyTeamViews.swift
//  leanring-buddy
//
//  A job on a card: who has it, what it is, how it's going and what came back. In Clicky's chat for its team's jobs, and in
//  the CEO's chat for the CEO's orders to Clicky.
//

import AppKit
import ClickyCore
import SwiftUI

struct DelegationCard: View {
    let job: ClickyDelegation
    @ObservedObject private var store = BotsStore.shared
    @State private var showsAll = false

    private static let shortResult = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.workerName).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    Text(job.isOrder ? "Order from \(store.primary?.name ?? "the CEO")" : "Job from Clicky" + (job.reportsToCEO == true ? ", for \(store.primary?.name ?? "the CEO")" : ""))
                        .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                status
            }
            Text(job.task).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let result = job.result, !result.isEmpty {
                Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
                BotRichText(text: showsAll || result.count <= Self.shortResult ? result : String(result.prefix(Self.shortResult)) + "…")
                HStack(spacing: 6) {
                    if result.count > Self.shortResult {
                        Button(showsAll ? "Show less" : "Show all") { withAnimation(DS.Motion.hover) { showsAll.toggle() } }.buttonStyle(.theo(.ghost, .small))
                    }
                    if let worker = job.workerID, worker != BotsStore.clickyID, store.bot(worker) != nil {
                        Button("Open \(job.workerName)'s chat") { BotsSelection.shared.pane = .bot(worker) }.buttonStyle(.theo(.ghost, .small))
                    }
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(.theo(.ghost, .small)).help("Copy")
                }
            } else if job.isLive, let worker = job.workerID, worker != BotsStore.clickyID {
                Button("Watch in \(job.workerName)'s chat") { BotsSelection.shared.pane = .bot(worker) }.buttonStyle(.theo(.ghost, .small))
            }
            if let result = job.result, let prompt = BotsT3.promptBlock(in: result), !store.t3Runs.contains(where: { $0.prompt == prompt }), job.workerID == nil {
                T3HandoffButton(text: result, room: BotsStore.clickyID, prominent: true)
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(job.isLive ? DS.Colors.accent.opacity(0.45) : DS.Colors.borderSubtle, lineWidth: 1))
        .padding(.leading, 38)
    }

    /// Its bot, lit while it works. A hidden helper has no bot of its own, so Clicky's mark stands in.
    @ViewBuilder private var avatar: some View {
        if let worker = job.workerID, let bot = store.bot(worker) {
            BotAvatar(bot: bot, size: 30, state: job.isLive ? .thinking : .idle)
        } else {
            ClickyAvatar(size: 30, isActive: job.isLive)
        }
    }

    @ViewBuilder private var status: some View {
        switch job.phase {
        case .queued:
            StatusPill(text: "Waiting", tone: .neutral, busy: true)
        case .working:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                StatusPill(text: "Working · " + T3RunCard.elapsed(since: job.startedAt, now: context.date), tone: .info, busy: true)
            }
        case .done:
            StatusPill(text: "Done" + took, tone: .good)
        case .failed:
            StatusPill(text: "Didn't finish", tone: .warn)
        }
    }

    private var took: String {
        guard let finished = job.finishedAt else { return "" }
        return " · " + T3RunCard.elapsed(since: job.startedAt, now: finished)
    }
}

/// One line of Clicky's chat, in time order: a turn, or something its team or the CEO sent.
enum ClickyChatEntry: Identifiable {
    case turn(id: String, you: String, answer: String, at: Date)
    case message(BotChatMessage)

    var id: String {
        switch self {
        case .turn(let id, _, _, _): return id
        case .message(let message): return message.id
        }
    }

    var at: Date {
        switch self {
        case .turn(_, _, _, let at): return at
        case .message(let message): return message.at
        }
    }

    private static let turnFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Turn folders are named by their start: 20261102-120301-ab12cd34.
    static func date(ofTurn id: String) -> Date { turnFormat.date(from: String(id.prefix(15))) ?? .distantPast }
}
