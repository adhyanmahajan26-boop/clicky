//
//  StudioActivity.swift
//  leanring-buddy
//
//  So work Theo hands out can be seen: each working bot gets a tile with its desk, a window of Theo's own showing the bot, its
//  task, progress and latest lines. It's only a mirror. A coder's real terminal stays on the owner's machine and never comes
//  here. When the tiles are full the rest wait in the panel's list, and research takes a desk's tile if it needs one.
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class StudioActivity {
    static let shared = StudioActivity()

    /// How long a finished bot's desk stays up, so its last lines can be read.
    private static let lingerSeconds: TimeInterval = 6

    private var desks: [String: StudioTileID] = [:]
    private var finishedAt: [String: Date] = [:]
    private var subscription: AnyCancellable?
    private var lingerTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard subscription == nil else { return }
        let store = BotsStore.shared
        subscription = store.$replying.map { _ in () }.merge(with: store.$t3Runs.map { _ in () })
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.follow() }
    }

    func stop() {
        subscription = nil
        lingerTask?.cancel()
        desks = [:]
        finishedAt = [:]
    }

    private func isWorking(_ bot: NativeBot, in store: BotsStore) -> Bool {
        store.replying[bot.id] != nil || store.liveRun(of: bot.id) != nil
    }

    private func follow() {
        let store = BotsStore.shared
        let studio = StudioController.shared
        guard studio.isOn else { return }
        let researcher = store.teamBot(.researcher)?.id
        let working = store.bots.filter { $0.id != researcher && isWorking($0, in: store) }
        // Done bots go after a moment.
        for (id, tile) in desks where !working.contains(where: { $0.id == id }) {
            let done = finishedAt[id] ?? Date()
            finishedAt[id] = done
            if Date().timeIntervalSince(done) >= Self.lingerSeconds {
                desks[id] = nil
                finishedAt[id] = nil
                studio.clear(tile)
            }
        }
        for bot in working {
            finishedAt[bot.id] = nil
            guard desks[bot.id] == nil, studio.roster.tile(of: bot.id) == nil, let tile = studio.freeTiles.first else { continue }
            desks[bot.id] = tile
            studio.assign(botID: bot.id, to: tile)
            if !studio.panelVisible { studio.panelVisible = true }
        }
        if !finishedAt.isEmpty {
            lingerTask?.cancel()
            lingerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((Self.lingerSeconds + 0.5) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.follow()
            }
        }
    }

    /// Research needs a real tile more than a desk needs its mirror: a finished bot's goes first.
    func makeRoomForResearch() {
        guard StudioController.shared.freeTiles.isEmpty else { return }
        let id = desks.keys.first { finishedAt[$0] != nil } ?? desks.keys.first
        guard let id, let tile = desks.removeValue(forKey: id) else { return }
        finishedAt[id] = nil
        StudioController.shared.clear(tile)
    }
}
