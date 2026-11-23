import Foundation
import Testing
@testable import ClickyCore

struct LinkSyncFolderTests {
    private let code = "K7QM-2XPA-ABCD-EFGH-JKMN"

    @Test func sealedDataOpensOnlyWithTheSameCode() throws {
        let plain = Data("the bots and their chats".utf8)
        let sealed = try #require(LinkSyncFolder.seal(plain, code: code))
        #expect(sealed != plain)
        #expect(!String(decoding: sealed, as: UTF8.self).contains("bots"))
        #expect(LinkSyncFolder.open(sealed, code: code) == plain)
        #expect(LinkSyncFolder.open(sealed, code: "ZZZZ-2XPA-ABCD-EFGH-JKMN") == nil)
    }

    @Test func aFileCutShortOrChangedIsNotOpened() throws {
        let sealed = try #require(LinkSyncFolder.seal(Data("whole".utf8), code: code))
        #expect(LinkSyncFolder.open(sealed.prefix(sealed.count - 3), code: code) == nil)
        var changed = sealed
        changed[changed.startIndex + 14] ^= 0xFF
        #expect(LinkSyncFolder.open(changed, code: code) == nil)
        #expect(LinkSyncFolder.open(Data(), code: code) == nil)
    }

    @Test func folderNamesAreTheSameOnBothMacsAndSayNothing() {
        let pair = LinkSyncFolder.pairFolderName(forCode: code)
        #expect(pair == LinkSyncFolder.pairFolderName(forCode: code))
        #expect(pair != LinkSyncFolder.pairFolderName(forCode: "ZZZZ-2XPA-ABCD-EFGH-JKMN"))
        #expect(!pair.contains("K7QM"))
        let studio = LinkSyncFolder.macFolderName(forCode: code, macID: "STUDIO-UUID")
        let air = LinkSyncFolder.macFolderName(forCode: code, macID: "AIR-UUID")
        #expect(studio != air)
        #expect(!studio.contains("STUDIO"))
        // A chat key has a slash: its file name mustn't.
        #expect(!LinkSyncFolder.itemFileName(forCode: code, key: "chat/theo").contains("/"))
        #expect(LinkSyncFolder.itemFileName(forCode: code, key: "chat/theo") != LinkSyncFolder.itemFileName(forCode: code, key: "chat/clicky"))
    }

    @Test func writesOnlyWhatChanged() {
        let written = ["bots": "a", "chat/theo": "b"]
        let now = ["bots": "a", "chat/theo": "c", "chat/clicky": "d"]
        #expect(LinkSyncFolder.keysToWrite(current: now, lastWritten: written) == ["chat/clicky", "chat/theo"])
        #expect(LinkSyncFolder.keysToWrite(current: written, lastWritten: written).isEmpty)
    }

    @Test func theManifestIsRewrittenOnChangesAndNowAndThen() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(LinkSyncFolder.shouldWriteManifest(changedKeys: [], lastWrittenAt: nil, now: start))
        #expect(LinkSyncFolder.shouldWriteManifest(changedKeys: ["bots"], lastWrittenAt: start, now: start.addingTimeInterval(5)))
        #expect(!LinkSyncFolder.shouldWriteManifest(changedKeys: [], lastWrittenAt: start, now: start.addingTimeInterval(60)))
        #expect(LinkSyncFolder.shouldWriteManifest(changedKeys: [], lastWrittenAt: start, now: start.addingTimeInterval(601)))
    }

    @Test func readsWhatDiffersHasNotBeenMergedAndIsWanted() {
        let theirs = ["bots": "new", "groups": "same", "chat/old-bot": "x", "chat/theo": "merged-before"]
        let mine = ["bots": "old", "groups": "same", "chat/theo": "mine"]
        let merged = ["chat/theo": "merged-before"]
        let keys = LinkSyncFolder.keysToRead(theirs: theirs, mine: mine, alreadyMerged: merged, wants: { $0 != "chat/old-bot" })
        #expect(keys == ["bots"])
    }

    @Test func manifestRoundTripsThroughTheSeal() throws {
        let manifest = LinkSyncFolder.Manifest(macName: "Adhyan’s Mac Studio", macID: "STUDIO-UUID", build: 202611230149,
                                               writtenAt: Date(timeIntervalSince1970: 1_800_000_000), digests: ["bots": "a"])
        let sealed = try #require(LinkSyncFolder.seal(try LinkCoding.encoder.encode(manifest), code: code))
        let opened = try #require(LinkSyncFolder.open(sealed, code: code))
        #expect(try LinkCoding.decoder.decode(LinkSyncFolder.Manifest.self, from: opened) == manifest)
    }

    @Test func suggestsGoogleDriveFirstThenICloud() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let found = LinkSyncFolder.suggestedFolders(cloudStorageEntries: ["Dropbox", "GoogleDrive-someone@example.com"],
                                                    cloudStorage: cloudStorage, iCloudDrive: iCloud, iCloudDriveExists: true)
        #expect(found.map(\.name) == ["Google Drive", "iCloud Drive", "Dropbox"])
        #expect(found[0].url.path == "/Users/someone/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive")
        #expect(LinkSyncFolder.suggestedFolders(cloudStorageEntries: [], cloudStorage: cloudStorage, iCloudDrive: iCloud, iCloudDriveExists: false).isEmpty)
    }
}

struct ChatMacMarkerTests {
    @Test func namesTheMacOnlyWhereTheChatMovedToAnotherOne() {
        let studio = "Adhyan’s Mac Studio"
        let air = "Adhyan’s MacBook Air"
        // Everything on this Mac: no line.
        #expect(ChatMacMarker.macToName(messageMac: studio, previousMac: nil, thisMac: studio) == nil)
        #expect(ChatMacMarker.macToName(messageMac: studio, previousMac: studio, thisMac: studio) == nil)
        // The chat started on the other Mac, or moved there.
        #expect(ChatMacMarker.macToName(messageMac: air, previousMac: nil, thisMac: studio) == air)
        #expect(ChatMacMarker.macToName(messageMac: air, previousMac: studio, thisMac: studio) == air)
        // And back.
        #expect(ChatMacMarker.macToName(messageMac: studio, previousMac: air, thisMac: studio) == studio)
        // Older messages say nothing.
        #expect(ChatMacMarker.macToName(messageMac: nil, previousMac: air, thisMac: studio) == nil)
    }
}
