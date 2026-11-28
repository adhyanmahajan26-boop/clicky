//
//  TeamStage.swift
//  leanring-buddy
//
//  A team drawn as its bots instead of a line of text: the manager on top with a crown, a line down to each bot, and every
//  face showing what that bot is doing right now (working, needs you, failed, done, resting). Settings › Bot teams draws
//  each ready-made team this way. Before a team is added the faces are the ones its bots will get, dimmed and resting;
//  once it is in Vello they are the real bots, live, and a click opens one. Which category and bots belong to a team is
//  ClickyCore's `TeamLiveView`.
//

import ClickyCore
import SwiftUI

/// One place on a team: the ready-made member, and its bot in Vello when the team has been added.
struct TeamStageMember: Identifiable {
    let id: Int
    let name: String
    let does: String
    let bot: NativeBot?
}

/// A ready-made team as it stands in Vello right now.
struct TeamLive {
    /// The category made from the team (the first copy), nil before it is added.
    let section: BotsLayout.Section?
    /// How many copies of the team are in the sidebar.
    let copies: Int
    let manager: TeamStageMember
    let workers: [TeamStageMember]

    var isAdded: Bool { section != nil }

    @MainActor
    static func of(_ team: ReadyMadeTeam, in store: BotsStore) -> TeamLive {
        let sections = store.layout.sections
        let indices = TeamLiveView.categoryIndices(teamName: team.name, categoryNames: sections.map(\.name))
        let section = indices.first.map { sections[$0] }
        let bots = section.map { store.members(of: $0) } ?? []
        let found = TeamLiveView.members(team.members.map(\.name), among: bots.map(\.name))
        let places = team.members.enumerated().map { index, member in
            TeamStageMember(id: index, name: member.name, does: member.does, bot: found[index].map { bots[$0] })
        }
        return TeamLive(section: section, copies: indices.count, manager: places[0], workers: Array(places.dropFirst()))
    }

    /// The states of the bots that are really there.
    @MainActor
    func states(in store: BotsStore) -> [PixelState] {
        ([manager] + workers).compactMap(\.bot).map { store.pixelState(of: store.bot($0.id) ?? $0).state }
    }
}

struct TeamStage: View {
    let live: TeamLive
    /// The team's colour: its category's, or the one it will get.
    let accent: Color
    var onOpen: (NativeBot) -> Void = { _ in }
    @ObservedObject private var store = BotsStore.shared
    @ObservedObject private var health = ConnectorHealth.shared

    var body: some View {
        VStack(spacing: 0) {
            figure(live.manager, size: 54, isManager: true)
            if !live.workers.isEmpty {
                OrgBranches(count: live.workers.count)
                    .stroke(accent.opacity(live.isAdded ? 0.55 : 0.3), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(height: 22)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(live.workers) { member in
                        figure(member, size: 40, isManager: false).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.top, 18).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(live.isAdded ? 0.16 : 0.07), accent.opacity(0.0)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(live.isAdded ? 0.28 : 0.12), lineWidth: 1))
    }

    @ViewBuilder
    private func figure(_ member: TeamStageMember, size: CGFloat, isManager: Bool) -> some View {
        let bot = member.bot.map { store.bot($0.id) ?? $0 }
        let shown = bot.map { store.pixelState(of: $0) }
        let look = bot?.crewLook ?? CrewLook.standard(id: "team-preview-" + member.name.lowercased(), name: member.name)
        let content = VStack(spacing: 4) {
            CrewAvatar(look: look, size: size, pose: shown?.state ?? .idle, poseUntil: shown?.until, moves: bot != nil,
                       interactive: false, dimmed: bot == nil, badge: bot != nil, name: member.name)
                .overlay(alignment: .top) {
                    if isManager {
                        Image(systemName: "crown.fill").font(.system(size: 11)).foregroundColor(DS.Colors.gold).offset(y: -12)
                    }
                }
                .padding(.top, isManager ? 4 : 0)
            Text(bot?.name ?? member.name)
                .font(.system(size: isManager ? 12.5 : 11.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            stateLine(bot: bot, state: shown?.state, isManager: isManager)
        }
        .padding(.horizontal, 4)
        .help(bot.map { "\($0.name): \(store.liveStatus(of: $0))" } ?? member.does)
        if let bot {
            Button { onOpen(bot) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(LiftButtonStyle()).pointerCursor()
        } else {
            content
        }
    }

    /// "● Working" in the face's own colour, "Manager · Resting" for the manager; "Manager" or the bot's job before it is added.
    @ViewBuilder
    private func stateLine(bot: NativeBot?, state: PixelState?, isManager: Bool) -> some View {
        if let state, bot != nil {
            HStack(spacing: 4) {
                Circle().fill(Color(hex: state.hex)).frame(width: 6, height: 6)
                Text((isManager ? "Manager · " : "") + (state.lane == .quiet ? "Resting" : state.label))
                    .font(.system(size: 10.5, weight: state.lane == .quiet ? .regular : .medium))
                    .foregroundColor(state.lane == .quiet ? DS.Colors.textTertiary : Color(hex: state.hex))
                    .lineLimit(1)
            }
        } else {
            Text(isManager ? "Manager" : "Not added")
                .font(.system(size: 10.5)).foregroundColor(isManager ? DS.Colors.gold.opacity(0.8) : DS.Colors.textTertiary).lineLimit(1)
        }
    }
}

/// "● 2 working · 1 needs you" in the colour of whatever needs the owner most.
struct TeamTallyPill: View {
    let states: [PixelState]

    var body: some View {
        let tally = TeamLiveView.Tally(states)
        let lead: PixelState = tally.needsYou > 0 ? .needs : tally.failed > 0 ? .failed : tally.working > 0 ? .working : tally.done > 0 ? .done : .idle
        HStack(spacing: 5) {
            Circle().fill(Color(hex: lead.hex)).frame(width: 7, height: 7)
                .shadow(color: lead.lane == .quiet ? .clear : Color(hex: lead.hex).opacity(0.7), radius: 3)
            Text(tally.words).font(.system(size: 11, weight: .medium))
                .foregroundColor(lead.lane == .quiet ? DS.Colors.textTertiary : DS.Colors.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 22)
        .background(Capsule().fill(DS.Colors.hover))
    }
}
