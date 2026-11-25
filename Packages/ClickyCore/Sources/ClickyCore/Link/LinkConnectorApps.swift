//
//  LinkConnectorApps.swift
//  ClickyCore
//
//  The connector hub's list of apps, kept the same on both linked Macs. A bot's apps ("gmail", "notion") travel with the bot,
//  but the hub's own list (`connectors.json`) used to stay on the Mac it was made on, so on the other Mac the same bot had
//  apps that Mac's hub had never heard of. Now the list travels too, over the live link and the sync folder.
//
//  Only the list goes: never a sign-in. `connectors.json` never holds a token (the hub refuses one), and every sign-in stays
//  in its own Mac's vault. An app reached through the Claude account (`claude-account`) works on the other Mac as soon as its
//  Claude Code is signed in to the same account; an app with its own sign-in shows "sign in" there until the owner does.
//  Apps that start a command on the Mac (`local`) stay where they were made: their command and folders are that Mac's.
//

import Foundation

/// One app of the hub's list, as the other Mac gets it.
public struct LinkConnectorApp: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var enabled: Bool
    /// The app's entry without `enabled`, as JSON with sorted keys, so the same app is the same bytes on both Macs.
    public var entryJSON: String

    public init(id: String, kind: String, enabled: Bool, entryJSON: String) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.entryJSON = entryJSON
    }

    /// The entry to hand to the hub's `add`, with `enabled` put back.
    public var entryForHub: [String: Any]? {
        guard var entry = (try? JSONSerialization.jsonObject(with: Data(entryJSON.utf8))) as? [String: Any] else { return nil }
        entry["enabled"] = enabled
        return entry
    }
}

/// What one Mac sends: its shared apps, and when each was last added, changed or removed there.
public struct LinkConnectorAppsItem: Codable, Equatable, Sendable {
    public var apps: [LinkConnectorApp]
    public var stamps: LinkMerge.Stamps

    public init(apps: [LinkConnectorApp], stamps: LinkMerge.Stamps) {
        self.apps = apps
        self.stamps = stamps
    }
}

public enum LinkConnectorApps {
    /// The kinds that go to the other Mac. `local` apps run a command of this Mac's, so they stay here.
    public static let sharedKinds: Set<String> = ["remote", "claude-account"]

    /// The shared apps in a `connectors.json`, by id. Nil when the file can't be read as a list of apps: then nothing is
    /// known, which must never be taken for "every app was removed".
    public static func sharedApps(fromConnectorList data: Data) -> [LinkConnectorApp]? {
        guard let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = file["apps"] as? [[String: Any]] else { return nil }
        var apps: [LinkConnectorApp] = []
        for entry in entries {
            guard let id = entry["id"] as? String, !id.isEmpty, let kind = entry["kind"] as? String, sharedKinds.contains(kind) else { continue }
            var shared = entry.filter { key, _ in key != "enabled" && !looksSecret(key) }
            // The hub keeps an app's plain settings for a local command in `env`; a shared kind has none, but leave out any anyway.
            shared["env"] = nil
            guard JSONSerialization.isValidJSONObject(shared),
                  let json = try? JSONSerialization.data(withJSONObject: shared, options: [.sortedKeys]) else { continue }
            apps.append(LinkConnectorApp(id: id, kind: kind, enabled: entry["enabled"] as? Bool ?? true, entryJSON: String(decoding: json, as: UTF8.self)))
        }
        return apps.sorted { $0.id < $1.id }
    }

    /// A field the hub would refuse as a secret. `connectors.json` never has one; this is only so a mistake can't travel.
    public static func looksSecret(_ fieldName: String) -> Bool {
        let name = fieldName.lowercased().replacingOccurrences(of: "_", with: "")
        return ["token", "secret", "password", "apikey", "credential"].contains { name.contains($0) }
    }

    /// What this Mac's hub has to do so its list matches the merged one.
    public struct Plan: Equatable, Sendable {
        public var add: [LinkConnectorApp] = []
        public var remove: [String] = []
        public var enable: [String] = []
        public var disable: [String] = []
        public init() {}
        public var isEmpty: Bool { add.isEmpty && remove.isEmpty && enable.isEmpty && disable.isEmpty }
    }

    /// The steps from this Mac's shared apps to the merged list. An app changed in other ways keeps this Mac's entry: only
    /// being added, removed, switched on and switched off travel.
    public static func plan(local: [LinkConnectorApp], merged: [LinkConnectorApp]) -> Plan {
        var plan = Plan()
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mergedIDs = Set(merged.map(\.id))
        for app in merged.sorted(by: { $0.id < $1.id }) {
            guard let mine = localByID[app.id] else {
                plan.add.append(app)
                continue
            }
            if mine.enabled != app.enabled { app.enabled ? plan.enable.append(app.id) : plan.disable.append(app.id) }
        }
        plan.remove = local.map(\.id).filter { !mergedIDs.contains($0) }.sorted()
        return plan
    }

    /// Both Macs' lists together: the newer change to an app wins, and a removal wins over anything older (`LinkMerge.byID`).
    public static func merged(local: [LinkConnectorApp], localStamps: LinkMerge.Stamps, remote: LinkConnectorAppsItem) -> (apps: [LinkConnectorApp], stamps: LinkMerge.Stamps) {
        let result = LinkMerge.byID(local: local, localStamps: localStamps, remote: remote.apps, remoteStamps: remote.stamps, id: \.id)
        return (result.items.filter { sharedKinds.contains($0.kind) }, result.stamps)
    }
}

/// A bot's own files (`instructions.md`, `nature.md`), kept the same on both linked Macs (link key "botFiles/<id>"). Before,
/// they stayed on the Mac they were written on, so the same bot had other instructions on the other Mac.
public struct LinkBotFile: Codable, Equatable, Sendable {
    public var text: String
    /// When the file was last written, on the Mac it came from.
    public var changedAt: Date

    public init(text: String, changedAt: Date) {
        self.text = text
        self.changedAt = changedAt
    }
}

public struct LinkBotFilesItem: Codable, Equatable, Sendable {
    public var instructions: LinkBotFile?
    public var nature: LinkBotFile?

    public init(instructions: LinkBotFile?, nature: LinkBotFile?) {
        self.instructions = instructions
        self.nature = nature
    }

    /// What both Macs compare: the texts only, so two copies written at different moments still agree.
    public var digest: String {
        LinkCoding.digest([instructions?.text ?? "", "\u{0}", nature?.text ?? ""])
    }
}

public enum LinkBotFiles {
    /// Which copy of one file this Mac should write, or nil to keep its own. The newer one wins; with the same time on both,
    /// the text that sorts first, so both Macs choose the same. A file only one Mac has goes to the other.
    public static func copyToWrite(mine: LinkBotFile?, theirs: LinkBotFile?) -> LinkBotFile? {
        guard let theirs else { return nil }
        guard let mine else { return theirs }
        guard mine.text != theirs.text else { return nil }
        if theirs.changedAt != mine.changedAt { return theirs.changedAt > mine.changedAt ? theirs : nil }
        return theirs.text < mine.text ? theirs : nil
    }
}
