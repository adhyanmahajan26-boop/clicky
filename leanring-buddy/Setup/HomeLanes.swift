//
//  HomeLanes.swift
//  leanring-buddy
//
//  The top of Home (kit/SPEC.md section 8, board 07-home): a row of count pills, then two lanes. Left, what needs the
//  owner and what failed, as the same small cards the chat uses, so they can be answered right here. Right, who's working
//  (with a progress bar and timer), what finished today, and who's asleep.
//

import AppKit
import ClickyCore
import SwiftUI

struct HomeLanes: View {
    @ObservedObject var store: BotsStore
    @ObservedObject var selection: BotsSelection
    @ObservedObject private var health = ConnectorHealth.shared
    @ObservedObject private var products = TheoProducts.shared
    @ObservedObject private var folds = PixelCardFolds.shared

    private var team: [NativeBot] { store.bots.filter { !$0.primary && (products.isOn(.clicky) || $0.owner != BotsStore.clickyID) } }

    var body: some View {
        let states = Dictionary(uniqueKeysWithValues: team.map { ($0.id, store.pixelState(of: $0).state) })
        let needing = team.filter { states[$0.id] == .needs }
        let failed = team.filter { states[$0.id] == .failed }
        let working = team.filter { states[$0.id]?.lane == .working }
        let done = team.filter { states[$0.id] == .done }
        let asleep = team.filter { states[$0.id] == .idle }
        // Cards answered in the last ten minutes stay as their folded lines, so the answer shows where it was given.
        let justAnswered = folds.folds.filter { Date().timeIntervalSince($0.value.at) < 600 }.sorted { $0.value.at > $1.value.at }.prefix(4).map(\.key)
        let keyCard = products.isOn(.dictation) && products.dictationAccess == .needsKey
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                if needing.count + (keyCard ? 1 : 0) > 0 { StatusPill(text: "\(needing.count + (keyCard ? 1 : 0)) need you", tone: .warn) }
                if !failed.isEmpty { StatusPill(text: "\(failed.count) failed", tone: .bad) }
                if !working.isEmpty { StatusPill(text: "\(working.count) working", tone: .working) }
                if !done.isEmpty { StatusPill(text: "\(done.count) done", tone: .done) }
                if !asleep.isEmpty { StatusPill(text: "\(asleep.count) asleep", tone: .asleep) }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    laneTitle("Needs you", count: needing.count + (keyCard ? 1 : 0))
                    if needing.isEmpty && !keyCard && justAnswered.isEmpty { quiet("Nothing needs you right now.") }
                    ForEach(needing) { bot in needsCard(bot) }
                    if keyCard { SarvamKeyCard() }
                    ForEach(justAnswered, id: \.self) { card in folds.line(card) }
                    if !failed.isEmpty {
                        laneTitle("Failed", count: failed.count).padding(.top, 6)
                        ForEach(failed) { bot in FailedBotCard(bot: bot) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 10) {
                    laneTitle("Working now", count: working.count)
                    if working.isEmpty { quiet("Nobody's working. Give a bot a job.") }
                    ForEach(working) { bot in workingRow(bot) }
                    if !done.isEmpty {
                        laneTitle("Finished today", count: done.count).padding(.top, 6)
                        ForEach(done) { bot in
                            laneRow(bot, state: .done, detail: store.liveStatus(of: bot)) {
                                Button("Open") { selection.pane = .bot(bot.id) }.buttonStyle(.theo(.secondary, .small))
                            }
                        }
                    }
                    if !asleep.isEmpty {
                        laneTitle("Asleep", count: asleep.count).padding(.top, 6)
                        ForEach(asleep.prefix(5)) { bot in asleepRow(bot) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Needs you

    @ViewBuilder private func needsCard(_ bot: NativeBot) -> some View {
        if let connector = health.blockingConnector(of: bot.id) {
            AppSignInCard(bot: bot, connector: connector)
        } else if let harness = store.signedOutEngine(of: bot), let failed = store.conversation(bot.id).messages.last(where: { $0.author == bot.id }) {
            HarnessSignInCard(bot: bot, harness: harness, cardID: "failure:\(failed.id)")
        } else if let call = store.openCall(of: bot.id), let message = store.conversation(bot.id).messages.last {
            BotCallCard(call: call, author: bot, at: message.at, isOpen: true) { answer in store.send(answer, command: answer, to: bot.id) }
        } else if let run = store.liveRun(of: bot.id), run.phase == "waiting" {
            PixelCard(tone: .needs, lead: .bot(bot, .needs), name: bot.name, context: run.title,
                      question: BotsStore.firstLine(run.activity ?? "") .isEmpty ? "The coding agent has a question" : BotsStore.firstLine(run.activity ?? ""),
                      buttons: [PixelCardButton(title: "Answer", primary: true) { selection.pane = .bot(bot.id) }])
        } else {
            PixelCard(tone: .needs, lead: .bot(bot, .needs), name: bot.name, question: store.liveStatus(of: bot).replacingOccurrences(of: "Needs you · ", with: ""),
                      buttons: [PixelCardButton(title: "Open chat", primary: true) { selection.pane = .bot(bot.id) }])
        }
    }

    // MARK: Rows

    /// Working now: what it's doing, which step, the timer, and a progress bar.
    private func workingRow(_ bot: NativeBot) -> some View {
        let run = store.liveRun(of: bot.id)
        let fills = run.map { RunSteps.fills(phase: $0.phase, stage: $0.stage) } ?? [.active, .todo, .todo, .todo, .todo]
        let step = fills.firstIndex { $0 != .done } ?? 4
        let progress = CGFloat(fills.filter { $0 == .done }.count) / 5 + 0.1
        return HStack(spacing: 12) {
            CrewAvatar(look: bot.crewLook, size: 36, pose: store.pixelState(of: bot).state, name: bot.name, ring: DS.Colors.surface1)
            VStack(alignment: .leading, spacing: 5) {
                Text(bot.name).font(.system(size: 13.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(([store.liveStatus(of: bot)] + (run.map { ["step \(step + 1) of 5", T3RunCard.elapsed(since: $0.startedAt, now: context.date)] } ?? [])).joined(separator: " · "))
                        .font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                }
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Colors.borderStrong)
                        Capsule().fill(DS.Colors.success).frame(width: max(6, box.size.width * min(1, progress)))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { selection.pane = .bot(bot.id) }
    }

    @ViewBuilder private func asleepRow(_ bot: NativeBot) -> some View {
        if let routine = store.routines.filter({ $0.target == bot.id && !$0.paused }).min(by: { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }) {
            laneRow(bot, state: .idle, detail: "Next routine " + (routine.nextRunAt?.formatted(date: .omitted, time: .shortened)).map { "at \($0)" }.orEmpty) {
                Button("Run now") { store.runRoutineNow(routine.id) }.buttonStyle(.theo(.secondary, .small))
            }
        } else {
            laneRow(bot, state: .idle, detail: "Nothing to do") {
                Button("Give it a job") { selection.pane = .bot(bot.id) }.buttonStyle(.theo(.secondary, .small))
            }
        }
    }

    private func laneRow<Trailing: View>(_ bot: NativeBot, state: PixelState, detail: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            CrewAvatar(look: bot.crewLook, size: 36, pose: state, name: bot.name, ring: DS.Colors.surface1)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name).font(.system(size: 13.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).lineLimit(1) } else { Color.clear.frame(height: 22) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { selection.pane = .bot(bot.id) }
    }

    private func laneTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(1.2).foregroundColor(DS.Colors.textTertiary)
            Spacer()
            Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundColor(DS.Colors.textTertiary)
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundColor(DS.Colors.textTertiary).padding(.vertical, 4)
    }
}

/// A failed bot, from its failure record: what couldn't happen, why, what is safe, and the one fix. Used on Home and in the
/// menu bar panel.
struct FailedBotCard: View {
    let bot: NativeBot

    var body: some View {
        let failure = bot.lastFailure ?? BotFailureRecord(reason: "It stopped.")
        if let harness = BotFailureWords.signedOutHarness(in: failure.reason) {
            HarnessSignInCard(bot: bot, harness: harness, cardID: "failure-home:\(bot.id):\(Int(failure.at.timeIntervalSince1970))")
        } else {
            let first = failure.firstSentence
            let rest = failure.reason.dropFirst(min(failure.reason.count, first.count)).trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            PixelCard(tone: .failed, lead: .bot(bot, .failed), name: bot.name,
                      context: (failure.step.map { "stopped at \($0) · " } ?? "") + BotsStore.ago(failure.at),
                      question: Self.question(failure),
                      detail: first + "." + (rest.isEmpty ? "" : " " + rest + "."),
                      buttons: [
                        PixelCardButton(title: "Try again", primary: true) {
                            PixelCardFolds.shared.fold("failure-home:\(bot.id):\(Int(failure.at.timeIntervalSince1970))", did: "You tried again", about: "\(bot.name) · " + first)
                            BotFailureCardActions.retry(bot: bot)
                        },
                        PixelCardButton(title: "See details") { BotsSelection.shared.pane = .bot(bot.id) },
                      ])
        }
    }

    /// "<What couldn't happen>" as the question.
    static func question(_ failure: BotFailureRecord) -> String {
        switch failure.step {
        case "Push": return "Couldn't push to GitHub"
        case "PR": return "Couldn't open the pull request"
        case "Tests": return "The tests didn't pass"
        default: return failure.reason.lowercased().hasPrefix("can't reach") ? failure.firstSentence : "Couldn't finish the job"
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
