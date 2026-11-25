//
//  LinkSyncFolderController.swift
//  leanring-buddy
//
//  The sync folder: Theo Link's second way of keeping two Macs in step, through a folder both Macs can see (Google Drive,
//  iCloud Drive, Dropbox, any folder the owner picks), for when they can't reach each other or are never open at once.
//
//  Every 20 seconds this Mac writes what changed into its own folder (the same payloads the live link sends, sealed with a key
//  made from the link code), then reads the other Mac's folder and merges whatever differs with the live link's own rules
//  (`BotsStore.applyLinkPayload`). Each Mac only ever writes its own folder, so the cloud never has two writers on one file.
//  API keys never go in it, same as the live link. The pure parts are ClickyCore `LinkSyncFolder`.
//

import AppKit
import ClickyCore
import Combine
import Foundation
import SwiftUI

@MainActor
final class LinkSyncFolderController: ObservableObject {
    static let shared = LinkSyncFolderController()

    private static let enabledKey = "v5.link.syncFolder.enabled"
    private static let pathKey = "v5.link.syncFolder.path"
    /// The owner switched the sync folder off on this Mac: it's never turned back on by itself after that.
    private static let ownerTurnedOffKey = "v5.link.syncFolder.ownerTurnedOff"
    /// Vello's chat was told once about the other Mac's sync folder (the cloud folder's name), so it isn't told again.
    private static let toldAboutOtherMacKey = "v5.link.syncFolder.toldAboutOtherMac"
    private static let tickSeconds: TimeInterval = 20

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: LinkSyncFolderController.enabledKey)
    @Published private(set) var folderPath = UserDefaults.standard.string(forKey: LinkSyncFolderController.pathKey)
    @Published private(set) var lastWrittenAt: Date?
    @Published private(set) var lastReadAt: Date?
    /// The other Mac's name and when it last wrote, from its manifest.
    @Published private(set) var otherMacName: String?
    @Published private(set) var otherMacWrittenAt: Date?
    @Published private(set) var problem: String?
    /// The other Mac syncs through a folder this Mac can't use yet: what to do about it, for Settings.
    @Published private(set) var otherMacSetupNote: String?

    private var timer: Timer?
    /// While this Mac's folder is off: looks every two minutes whether the other Mac's cloud folder has appeared here.
    private var watchTimer: Timer?
    private var isTicking = false
    private var isSoonQueued = false

    /// What this Mac last wrote, and what it last merged from each other Mac's folder, so nothing is written or merged twice.
    private struct SavedState: Codable {
        var lastWritten: [String: String] = [:]
        var manifestWrittenAt: Date?
        var merged: [String: [String: String]] = [:]
        /// The folder and code these were for: a new folder or a new code starts over.
        var forFolder: String?
        var forPair: String?
    }

    private var state = SavedState()

    private static var stateFile: URL {
        // A test profile has a home folder of its own, so its state never mixes with the owner's.
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/sync-folder-state.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.stateFile), let saved = try? LinkCoding.decoder.decode(SavedState.self, from: data) { state = saved }
        lastWrittenAt = state.manifestWrittenAt
    }

    // MARK: Settings

    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// Google Drive, iCloud Drive, Dropbox or OneDrive as found on this Mac, best first.
    var suggestedFolders: [LinkSyncFolder.Suggestion] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let iCloudDrive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path)) ?? []
        return LinkSyncFolder.suggestedFolders(cloudStorageEntries: entries, cloudStorage: cloudStorage, iCloudDrive: iCloudDrive,
                                               iCloudDriveExists: FileManager.default.fileExists(atPath: iCloudDrive.path))
    }

    /// A name for the chosen folder: "Google Drive" rather than its long path, when it is one.
    var folderDisplayName: String? {
        guard let folderURL else { return nil }
        if let known = suggestedFolders.first(where: { $0.url.standardizedFileURL.path == folderURL.standardizedFileURL.path }) { return known.name }
        return folderURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    func use(folder: URL, byOwner: Bool = true) {
        folderPath = folder.standardizedFileURL.path
        UserDefaults.standard.set(folderPath, forKey: Self.pathKey)
        setEnabled(true, byOwner: byOwner)
    }

    /// What this Mac tells the other in its `DeviceSnapshot`: the kind of folder it syncs through, nil while it's off.
    var folderKindForOtherMac: String? {
        guard isEnabled, let folderURL else { return nil }
        let path = folderURL.standardizedFileURL.path
        return suggestedFolders.first(where: { $0.url.standardizedFileURL.path == path })?.name ?? LinkSyncFolder.ownFolderName
    }

    /// The other Mac's sync folder is on: turn this Mac's on in the same cloud folder, so the owner sets it up once. If this
    /// Mac doesn't have that cloud folder, Settings and Vello's chat say what to install. Never undoes the owner turning it off.
    func followOtherMac(_ otherMac: DeviceSnapshot?) {
        guard TheoLink.shared.isPaired else { return }
        let otherName = TheoLink.shortName(otherMac?.name ?? TheoLink.shared.knownPeerName ?? "other Mac")
        let decision = LinkSyncFolder.autoSetup(otherMacFolder: otherMac?.syncFolder, enabledHere: isEnabled,
                                                ownerTurnedOffHere: UserDefaults.standard.bool(forKey: Self.ownerTurnedOffKey),
                                                suggestions: suggestedFolders)
        switch decision {
        case .nothing:
            otherMacSetupNote = nil
        case .use(let suggestion):
            otherMacSetupNote = nil
            use(folder: suggestion.url, byOwner: false)
            tellVelloOnce(about: suggestion.name, "Your \(otherName) keeps both Macs in step through \(suggestion.name), so this Mac does too now. Your bots, categories, chats and apps reach each other even when the Macs aren't on the same network or open at the same time.")
        case .needsCloudApp(let cloudName):
            let help = LinkSyncFolder.cloudAppHelp(cloudName)
            otherMacSetupNote = "Your \(otherName) keeps both Macs in step through \(cloudName), which isn't on this Mac. \(help), and this Mac turns it on by itself."
            tellVelloOnce(about: cloudName, "Your \(otherName) keeps both Macs in step through \(cloudName), but this Mac doesn't have \(cloudName) yet, so what changes here only reaches it while both Macs are open on the same network. \(help), and Vello turns the sync folder on by itself.")
        case .askOwnerToChoose:
            otherMacSetupNote = "Your \(otherName) keeps both Macs in step through a folder of its own. Pick the same folder here with Choose…."
        }
    }

    private func tellVelloOnce(about cloudName: String, _ text: String) {
        guard UserDefaults.standard.string(forKey: Self.toldAboutOtherMacKey) != cloudName, let vello = BotsStore.shared.primary else { return }
        UserDefaults.standard.set(cloudName, forKey: Self.toldAboutOtherMacKey)
        BotsStore.shared.post(BotChatMessage(author: BotsStore.noteAuthor, text: text), to: vello.id)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Pick a folder both Macs can see, like one in Google Drive or iCloud Drive. Vello makes a \"\(LinkSyncFolder.rootFolderName)\" folder inside it."
        panel.directoryURL = folderURL ?? suggestedFolders.first?.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(folder: url)
    }

    func setEnabled(_ enabled: Bool, byOwner: Bool = true) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if byOwner { UserDefaults.standard.set(!enabled, forKey: Self.ownerTurnedOffKey) }
        problem = nil
        if enabled { start() } else { stop() }
        // The other Mac hears at once, and turns its own on in the same place.
        TheoLink.shared.syncSoon()
    }

    // MARK: Running

    func start() {
        watchOtherMac()
        guard isEnabled, folderURL != nil, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func watchOtherMac() {
        followOtherMac(BotsStore.shared.peerDevice)
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isEnabled else { return }
                self.followOtherMac(BotsStore.shared.peerDevice)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Something just changed: write it within a few seconds rather than at the next round.
    func syncSoon() {
        guard isEnabled, timer != nil, !isSoonQueued else { return }
        isSoonQueued = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.isSoonQueued = false
            self?.tick()
        }
    }

    var statusReport: [String: Any] {
        let formatter = ISO8601DateFormatter()
        return ["enabled": isEnabled, "folder": folderPath ?? NSNull(), "lastWritten": lastWrittenAt.map(formatter.string) ?? NSNull(),
                "lastRead": lastReadAt.map(formatter.string) ?? NSNull(), "otherMac": otherMacName ?? NSNull(),
                "otherMacWritten": otherMacWrittenAt.map(formatter.string) ?? NSNull(), "problem": problem ?? NSNull()]
    }

    /// Test profiles: a round now, without waiting for the timer (`uiSyncFolder {action: tick}`).
    func tickNowForTest() { tick() }

    private func tick() {
        guard isEnabled, !isTicking, let folderURL else { return }
        guard let code = TheoLink.shared.code else {
            problem = "Link this Mac first: the sync folder is sealed with your link code."
            return
        }
        isTicking = true
        Task {
            defer { isTicking = false }
            let pairFolder = folderURL.appendingPathComponent(LinkSyncFolder.rootFolderName, isDirectory: true)
                .appendingPathComponent(LinkSyncFolder.pairFolderName(forCode: code), isDirectory: true)
            let ownFolderName = LinkSyncFolder.macFolderName(forCode: code, macID: DeviceRoles.thisMacID)
            // A new folder or a new code: nothing written or merged before counts.
            if state.forFolder != folderURL.path || state.forPair != LinkSyncFolder.pairFolderName(forCode: code) {
                state = SavedState(forFolder: folderURL.path, forPair: LinkSyncFolder.pairFolderName(forCode: code))
            }
            do {
                try await writeOwnCopy(code: code, pairFolder: pairFolder, ownFolderName: ownFolderName)
                await readOtherCopies(code: code, pairFolder: pairFolder, ownFolderName: ownFolderName)
                problem = nil
            } catch {
                problem = "Can't write to \(folderDisplayName ?? "the sync folder"): \(error.localizedDescription)"
            }
            saveState()
        }
    }

    /// Writes what changed since last time, then the manifest, so the other Mac never reads a manifest ahead of its files.
    private func writeOwnCopy(code: String, pairFolder: URL, ownFolderName: String) async throws {
        let store = BotsStore.shared
        let digests = await TheoLink.shared.currentDigests()
        let changed = LinkSyncFolder.keysToWrite(current: digests, lastWritten: state.lastWritten)
        let now = Date()
        guard LinkSyncFolder.shouldWriteManifest(changedKeys: changed, lastWrittenAt: state.manifestWrittenAt, now: now) else { return }
        var sealedItems: [(fileName: String, data: Data)] = []
        var written = state.lastWritten
        for key in changed {
            guard let payload = store.linkPayload(key), let digest = digests[key],
                  let plain = try? LinkCoding.encoder.encode(LinkSyncFolder.Item(key: key, digest: digest, payload: payload)),
                  let sealed = LinkSyncFolder.seal(plain, code: code) else { continue }
            sealedItems.append((LinkSyncFolder.itemFileName(forCode: code, key: key), sealed))
            written[key] = digest
        }
        // Only what's still shared goes in the manifest; files for things gone (a deleted bot's chat) are cleared away.
        for key in written.keys where digests[key] == nil { written[key] = nil }
        let manifest = LinkSyncFolder.Manifest(macName: TheoLink.localName, macID: DeviceRoles.thisMacID, build: localBuild, writtenAt: now, digests: written)
        guard let manifestData = try? LinkCoding.encoder.encode(manifest), let sealedManifest = LinkSyncFolder.seal(manifestData, code: code) else { return }
        let keepFileNames = Set(written.keys.map { LinkSyncFolder.itemFileName(forCode: code, key: $0) } + [LinkSyncFolder.manifestFileName])
        let ownFolder = pairFolder.appendingPathComponent(ownFolderName, isDirectory: true)
        let itemsToWrite = sealedItems
        try await Task.detached(priority: .utility) {
            let files = FileManager.default
            try files.createDirectory(at: ownFolder, withIntermediateDirectories: true)
            for item in itemsToWrite { try item.data.write(to: ownFolder.appendingPathComponent(item.fileName), options: .atomic) }
            try sealedManifest.write(to: ownFolder.appendingPathComponent(LinkSyncFolder.manifestFileName), options: .atomic)
            for name in (try? files.contentsOfDirectory(atPath: ownFolder.path)) ?? [] where !keepFileNames.contains(name) && name.hasSuffix(".sealed") {
                try? files.removeItem(at: ownFolder.appendingPathComponent(name))
            }
        }.value
        state.lastWritten = written
        state.manifestWrittenAt = now
        lastWrittenAt = now
    }

    /// Reads every other Mac's folder in the pair's folder and merges what differs.
    private func readOtherCopies(code: String, pairFolder: URL, ownFolderName: String) async {
        let manifests: [(folder: String, manifest: LinkSyncFolder.Manifest)] = await Task.detached(priority: .utility) {
            let files = FileManager.default
            let folders = ((try? files.contentsOfDirectory(atPath: pairFolder.path)) ?? []).filter { $0 != ownFolderName && !$0.hasPrefix(".") }
            return folders.compactMap { folder -> (String, LinkSyncFolder.Manifest)? in
                let url = pairFolder.appendingPathComponent(folder).appendingPathComponent(LinkSyncFolder.manifestFileName)
                guard let sealed = try? Data(contentsOf: url), let plain = LinkSyncFolder.open(sealed, code: code),
                      let manifest = try? LinkCoding.decoder.decode(LinkSyncFolder.Manifest.self, from: plain) else { return nil }
                return (folder, manifest)
            }
        }.value
        let store = BotsStore.shared
        for (folder, manifest) in manifests.sorted(by: { $0.manifest.writtenAt < $1.manifest.writtenAt }) {
            var mine = await TheoLink.shared.currentDigests()
            // Each Mac describes itself, so its description is compared with the copy of it held here, as the live link does.
            mine["device"] = store.peerDevice.map { LinkCoding.digest($0) }
            let theirs = manifest.digests
            // Memory and skills that are the same on both: that's the other Mac's copy now, for the next three-way merge.
            for (key, value) in theirs where key.hasPrefix("botMemory/") && mine[key] == value { BotMemory.agreed(botID: String(key.dropFirst("botMemory/".count))) }
            if let skills = theirs["skills"], mine["skills"] == skills { BotSkills.agreed(botIDs: store.bots.map(\.id)) }
            var merged = state.merged[folder] ?? [:]
            let wanted = LinkSyncFolder.keysToRead(theirs: theirs, mine: mine, alreadyMerged: merged, wants: { store.wantsLinkItem($0) })
            let macFolder = pairFolder.appendingPathComponent(folder, isDirectory: true)
            let items: [LinkSyncFolder.Item] = await Task.detached(priority: .utility) {
                wanted.compactMap { key -> LinkSyncFolder.Item? in
                    let url = macFolder.appendingPathComponent(LinkSyncFolder.itemFileName(forCode: code, key: key))
                    guard let sealed = try? Data(contentsOf: url), let plain = LinkSyncFolder.open(sealed, code: code),
                          let item = try? LinkCoding.decoder.decode(LinkSyncFolder.Item.self, from: plain), item.key == key else { return nil }
                    return item
                }
            }.value
            for item in items {
                // A file older than the manifest means the cloud hasn't brought the new one yet: it's read again next round.
                guard theirs[item.key] == item.digest else { continue }
                store.applyLinkPayload(item.key, item.payload)
                merged[item.key] = item.digest
            }
            state.merged[folder] = merged.filter { theirs[$0.key] != nil }
            otherMacName = manifest.macName
            otherMacWrittenAt = manifest.writtenAt
            TheoLink.shared.rememberOtherMacName(manifest.macName)
            lastReadAt = Date()
        }
    }

    private func saveState() {
        guard let data = try? LinkCoding.encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.stateFile, options: .atomic)
    }

    private var localBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
}

// MARK: - Settings

/// Settings › Your other Mac › Sync folder.
struct SyncFolderSettingsSection: View {
    @ObservedObject private var syncFolder = LinkSyncFolderController.shared
    @ObservedObject private var link = TheoLink.shared

    var body: some View {
        TheoSection(title: "Sync folder", hint: "For when your Macs can't reach each other, or aren't open at the same time. Each Mac writes its own copy of your bots, categories, chats, runs and memory into this folder and reads the other's, so it works through Google Drive, iCloud Drive or any folder both Macs can see. Everything in it is sealed with your link code, so the cloud can't read it. API keys never go in it.") {
            SettingRow(title: "Keep both Macs in step through a folder", detail: folderLine) {
                Toggle("", isOn: Binding(get: { syncFolder.isEnabled }, set: { enabled in
                    if enabled && syncFolder.folderURL == nil {
                        if let first = syncFolder.suggestedFolders.first { syncFolder.use(folder: first.url) } else { syncFolder.chooseFolder() }
                    } else {
                        syncFolder.setEnabled(enabled)
                    }
                }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!link.isPaired)
            }
            if let note = syncFolder.otherMacSetupNote, !syncFolder.isEnabled {
                RowDivider()
                Text(note).font(TheoType.body).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            RowDivider()
            SettingRow(title: "Where", detail: syncFolder.folderDisplayName ?? "Not picked yet") {
                HStack(spacing: 8) {
                    ForEach(Array(syncFolder.suggestedFolders.prefix(2))) { suggestion in
                        if suggestion.url.standardizedFileURL.path != syncFolder.folderURL?.standardizedFileURL.path {
                            Button("Use \(suggestion.name)") { syncFolder.use(folder: suggestion.url) }
                                .buttonStyle(.theo(.secondary, .small)).pointerCursor()
                        }
                    }
                    Button("Choose…") { syncFolder.chooseFolder() }.buttonStyle(.theo(.ghost, .small)).pointerCursor()
                }
            }
        }
    }

    private var folderLine: String {
        guard link.isPaired else { return "Link this Mac first: the folder is sealed with your link code." }
        if let problem = syncFolder.problem { return problem }
        guard syncFolder.isEnabled else { return "Off" }
        let relative = RelativeDateTimeFormatter()
        var parts: [String] = []
        if let written = syncFolder.lastWrittenAt { parts.append("This Mac wrote \(relative.localizedString(for: written, relativeTo: Date()))") }
        if let name = syncFolder.otherMacName, let at = syncFolder.otherMacWrittenAt {
            parts.append("\(TheoLink.shortName(name)) wrote \(relative.localizedString(for: at, relativeTo: Date()))")
        } else {
            parts.append("Nothing from your other Mac yet. It turns this on by itself in the same folder once it's open and linked, if it has that folder too.")
        }
        return parts.joined(separator: " · ")
    }
}
