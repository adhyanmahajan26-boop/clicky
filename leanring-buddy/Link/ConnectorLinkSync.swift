//
//  ConnectorLinkSync.swift
//  leanring-buddy
//
//  Keeps the connector hub's list of apps the same on both linked Macs (link key "connectors"), so a bot that has Gmail,
//  Notion and Drive on one Mac has them on the other too. Only the list travels, never a sign-in: an app reached through the
//  Claude account works there as soon as that Mac's Claude Code is signed in to the same account, and an app with its own
//  sign-in asks for it once on that Mac. The rules are ClickyCore `LinkConnectorApps`.
//

import ClickyCore
import Foundation

@MainActor
final class ConnectorLinkSync {
    static let shared = ConnectorLinkSync()

    /// When each shared app was last added, changed or removed on this Mac, and the list as last seen, to tell what changed.
    private struct SavedState: Codable {
        var stamps = LinkMerge.Stamps()
        var lastSeen: [LinkConnectorApp]?
    }

    private var state = SavedState()
    private var isApplying = false
    /// The last plan this Mac tried, and when: the live link compares every few seconds, and a plan that can't finish (no
    /// connector helper here) mustn't run the helper that often.
    private var lastTriedPlan: LinkConnectorApps.Plan?
    private var lastTriedAt: Date?
    private static let retryAfterSeconds: TimeInterval = 600

    private static var stateFile: URL {
        ConnectorHub.dataFolder.appendingPathComponent("Bots/link-connectors.json")
    }

    private static var connectorListFile: URL {
        ConnectorHub.dataFolder.appendingPathComponent("Connectors/connectors.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.stateFile), let saved = try? LinkCoding.decoder.decode(SavedState.self, from: data) { state = saved }
    }

    /// The hub's shared apps as they are now. Nil when there's no list to read (no hub here yet, or it can't be read).
    private func currentApps() -> [LinkConnectorApp]? {
        guard let data = try? Data(contentsOf: Self.connectorListFile) else { return nil }
        return LinkConnectorApps.sharedApps(fromConnectorList: data)
    }

    /// Notes what the owner changed here since last time, so a newer change on either Mac wins.
    private func noteChanges() -> [LinkConnectorApp]? {
        guard let apps = currentApps() else { return nil }
        if !isApplying {
            LinkMerge.noteChanges(from: state.lastSeen ?? [], to: apps, id: \.id, stamps: &state.stamps)
            if state.lastSeen != apps {
                state.lastSeen = apps
                save()
            }
        }
        return apps
    }

    /// The fingerprint both routes compare. The apps only, not when they changed, so two Macs with the same list agree.
    func digest() -> String? {
        guard ConnectorHub.isAvailable, let apps = noteChanges() else { return nil }
        return LinkCoding.digest(apps)
    }

    func payload() -> Data? {
        guard ConnectorHub.isAvailable, let apps = noteChanges() else { return nil }
        return try? LinkCoding.encoder.encode(LinkConnectorAppsItem(apps: apps, stamps: state.stamps))
    }

    /// The other Mac's list: merge it, then add, remove, switch on or off here what the merge says.
    func apply(_ data: Data) {
        guard ConnectorHub.isAvailable, !isApplying,
              let theirs = try? LinkCoding.decoder.decode(LinkConnectorAppsItem.self, from: data),
              let mine = noteChanges() else { return }
        let merged = LinkConnectorApps.merged(local: mine, localStamps: state.stamps, remote: theirs)
        let plan = LinkConnectorApps.plan(local: mine, merged: merged.apps)
        state.stamps = merged.stamps
        save()
        guard !plan.isEmpty else { return }
        if plan == lastTriedPlan, let lastTriedAt, Date().timeIntervalSince(lastTriedAt) < Self.retryAfterSeconds { return }
        lastTriedPlan = plan
        lastTriedAt = Date()
        isApplying = true
        Task {
            for app in plan.add {
                guard let entry = app.entryForHub else { continue }
                // No check here: an app reached through the Claude account is checked below, and one with its own sign-in
                // waits for the owner to sign in on this Mac.
                try? await ConnectorHub.add(entry: entry, check: false)
            }
            for appID in plan.remove { try? await ConnectorHub.remove(appID) }
            for appID in plan.enable { try? await ConnectorHub.setEnabled(appID, true) }
            for appID in plan.disable { try? await ConnectorHub.setEnabled(appID, false) }
            for app in plan.add where app.kind == HubAppRecord.Kind.claudeAccount.rawValue { try? await ConnectorHub.check(app.id) }
            _ = try? await ConnectorHub.list()
            // What the hub has now is what came from the other Mac, not a change made here.
            state.lastSeen = currentApps() ?? state.lastSeen
            save()
            isApplying = false
            await ConnectorHealth.shared.refresh()
            TheoLink.shared.syncSoon()
        }
    }

    private func save() {
        guard let data = try? LinkCoding.encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.stateFile, options: .atomic)
    }
}
