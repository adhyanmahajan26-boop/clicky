//
//  LinkSyncFolder.swift
//  ClickyCore
//
//  The pure parts of the sync folder: Theo Link's way of keeping two Macs in step through a folder both can see (Google Drive,
//  iCloud Drive, Dropbox, a shared disk), for when they can't reach each other or are never open at the same time.
//
//  Each Mac writes only its own folder, so nothing two Macs write can clash: a manifest (the fingerprint of every thing it
//  shares, the same fingerprints the live link sends) and one file per thing, holding exactly what the live link would send
//  for it. The other Mac reads them and merges with the same rules as the live link (`LinkMerge`), so both end up the same
//  whichever route the changes took.
//
//  Everything written is sealed (AES-GCM) with a key made from the link code, so the cloud only holds data it can't read. The
//  folder names are made from the code and the Mac's id too, so they say nothing about whose Macs these are.
//

import CryptoKit
import Foundation

public enum LinkSyncFolder {
    /// The folder Vello makes inside the one the owner picked.
    public static let rootFolderName = "Vello Sync"
    public static let manifestFileName = "manifest.sealed"

    /// The key everything is sealed with. Different from the live link's key, so one can't stand in for the other.
    public static func sealingKey(forCode code: String) -> SymmetricKey {
        SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: Data("vello-sync-folder-v1".utf8), using: SymmetricKey(data: Data(code.utf8))))
    }

    /// The folder this pair of Macs shares, inside `rootFolderName`: the same on both Macs, and nothing anyone else can work out.
    public static func pairFolderName(forCode code: String) -> String {
        shortHash("pair|" + code)
    }

    /// One Mac's own folder inside the pair's folder.
    public static func macFolderName(forCode code: String, macID: String) -> String {
        shortHash("mac|" + code + "|" + macID)
    }

    /// The file one shared thing goes in. Keys like "chat/<id>" have slashes, so the file is named by a hash of the key.
    public static func itemFileName(forCode code: String, key: String) -> String {
        shortHash("item|" + code + "|" + key) + ".sealed"
    }

    private static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Sealed bytes: nonce, cipher text and tag together. Nil only if CryptoKit can't seal, which it always can.
    public static func seal(_ plain: Data, code: String) -> Data? {
        try? AES.GCM.seal(plain, using: sealingKey(forCode: code)).combined
    }

    /// The plain bytes. Nil when it was sealed with another code, was cut short by a cloud copy still arriving, or was changed.
    public static func open(_ sealed: Data, code: String) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: sealingKey(forCode: code))
    }

    /// What one Mac says it holds.
    public struct Manifest: Codable, Equatable, Sendable {
        /// The Mac's full name, as Theo Link knows it ("Adhyan’s Mac Studio").
        public var macName: String
        /// `LinkedMac.id` of the Mac that wrote it.
        public var macID: String
        public var build: Int
        public var writtenAt: Date
        /// The same fingerprints the live link sends: key → digest.
        public var digests: [String: String]

        public init(macName: String, macID: String, build: Int, writtenAt: Date, digests: [String: String]) {
            self.macName = macName
            self.macID = macID
            self.build = build
            self.writtenAt = writtenAt
            self.digests = digests
        }
    }

    /// One shared thing: its key, the fingerprint it had when written, and the payload the live link would send for it.
    public struct Item: Codable, Equatable, Sendable {
        public var key: String
        public var digest: String
        public var payload: Data

        public init(key: String, digest: String, payload: Data) {
            self.key = key
            self.digest = digest
            self.payload = payload
        }
    }

    /// The keys worth writing again: new or changed since this Mac last wrote, or never written.
    public static func keysToWrite(current: [String: String], lastWritten: [String: String]) -> [String] {
        current.filter { lastWritten[$0.key] != $0.value }.map(\.key).sorted()
    }

    /// The manifest is written again when something changed, and otherwise now and then, so the other Mac sees this one is alive.
    public static func shouldWriteManifest(changedKeys: [String], lastWrittenAt: Date?, now: Date, heartbeat: TimeInterval = 600) -> Bool {
        guard changedKeys.isEmpty else { return true }
        guard let lastWrittenAt else { return true }
        return now.timeIntervalSince(lastWrittenAt) >= heartbeat
    }

    /// The other Mac's things worth reading: different from what this Mac holds, not already merged from that exact version, and
    /// wanted here. "device" is compared with the copy of the other Mac's description held here, as the live link does.
    /// Bots and groups come first: whether a chat is wanted here depends on its bot or group being known.
    public static func keysToRead(theirs: [String: String], mine: [String: String], alreadyMerged: [String: String], wants: (String) -> Bool) -> [String] {
        let firstKeys = ["bots", "groups", "layout"]
        let differing = theirs.filter { key, digest in mine[key] != digest && alreadyMerged[key] != digest }.map(\.key)
        let first = firstKeys.filter(differing.contains)
        let rest = differing.filter { !firstKeys.contains($0) }.sorted()
        // `wants` is asked before anything here is merged: the chat of a bot that's only just arriving is read on the next round.
        return first + rest.filter(wants)
    }

    /// A cloud folder found on this Mac.
    public struct Suggestion: Equatable, Sendable, Identifiable {
        public var name: String
        public var url: URL
        public var id: String { url.path }

        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    /// Where the owner's cloud folders usually are on a Mac, best first: Google Drive's My Drive, then iCloud Drive.
    /// `cloudStorage` is ~/Library/CloudStorage and `iCloudDrive` is ~/Library/Mobile Documents/com~apple~CloudDocs.
    public static func suggestedFolders(cloudStorageEntries: [String], cloudStorage: URL, iCloudDrive: URL, iCloudDriveExists: Bool) -> [Suggestion] {
        var found: [Suggestion] = []
        for entry in cloudStorageEntries.sorted() where entry.hasPrefix("GoogleDrive-") {
            found.append(Suggestion(name: "Google Drive", url: cloudStorage.appendingPathComponent(entry).appendingPathComponent("My Drive")))
        }
        if iCloudDriveExists { found.append(Suggestion(name: "iCloud Drive", url: iCloudDrive)) }
        for entry in cloudStorageEntries.sorted() where entry.hasPrefix("Dropbox") || entry.hasPrefix("OneDrive") {
            found.append(Suggestion(name: entry.hasPrefix("Dropbox") ? "Dropbox" : "OneDrive", url: cloudStorage.appendingPathComponent(entry)))
        }
        return found
    }
}

/// Where a shared chat moved from one Mac to the other: a small "On MacBook Air" line goes before the first message written on
/// another Mac than the one before it. A chat that only ever happened on this Mac shows none.
public enum ChatMacMarker {
    /// The Mac to name before a message, or nil. `previousMac` is the nearest earlier message's Mac that is known.
    public static func macToName(messageMac: String?, previousMac: String?, thisMac: String) -> String? {
        guard let messageMac, !messageMac.isEmpty else { return nil }
        if let previousMac { return previousMac == messageMac ? nil : messageMac }
        return messageMac == thisMac ? nil : messageMac
    }
}
