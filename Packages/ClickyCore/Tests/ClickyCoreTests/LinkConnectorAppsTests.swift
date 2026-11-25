import Foundation
import Testing
@testable import ClickyCore

struct LinkConnectorAppsTests {
    private let studioList = Data("""
    {"version":1,"apps":[
      {"id":"gmail","name":"Gmail","kind":"claude-account","server":"claude.ai Gmail","readTools":["search_threads"],"writeTools":["create_draft"]},
      {"id":"notion","name":"Notion","kind":"claude-account","server":"claude.ai Notion","enabled":false},
      {"id":"linear","name":"Linear","kind":"remote","url":"https://mcp.linear.app/mcp","auth":"token"},
      {"id":"files","name":"My files","kind":"local","command":"npx","args":["-y","server","/Users/me/Notes"]}
    ]}
    """.utf8)

    @Test func sharesTheListButNeverLocalCommands() throws {
        let apps = try #require(LinkConnectorApps.sharedApps(fromConnectorList: studioList))
        #expect(apps.map(\.id) == ["gmail", "linear", "notion"])
        #expect(apps.first { $0.id == "notion" }?.enabled == false)
        #expect(apps.first { $0.id == "gmail" }?.enabled == true)
        // The entry keeps what the hub needs, and `enabled` only once, beside it.
        let gmail = try #require(apps.first { $0.id == "gmail" }?.entryForHub)
        #expect(gmail["server"] as? String == "claude.ai Gmail")
        #expect(gmail["enabled"] as? Bool == true)
    }

    @Test func anUnreadableListIsNotAnEmptyOne() {
        #expect(LinkConnectorApps.sharedApps(fromConnectorList: Data("not json".utf8)) == nil)
        #expect(LinkConnectorApps.sharedApps(fromConnectorList: Data(#"{"version":1}"#.utf8)) == nil)
        #expect(LinkConnectorApps.sharedApps(fromConnectorList: Data(#"{"version":1,"apps":[]}"#.utf8)) == [])
    }

    @Test func aSecretLookingFieldNeverTravels() throws {
        let list = Data(#"{"apps":[{"id":"x","name":"X","kind":"remote","url":"https://x.example/mcp","accessToken":"abc","client_secret":"def"}]}"#.utf8)
        let app = try #require(LinkConnectorApps.sharedApps(fromConnectorList: list)?.first)
        #expect(!app.entryJSON.contains("abc"))
        #expect(!app.entryJSON.contains("def"))
        #expect(app.entryJSON.contains("x.example"))
    }

    @Test func theAirGetsTheStudiosAppsAndKeepsItsOwn() throws {
        let studioApps = try #require(LinkConnectorApps.sharedApps(fromConnectorList: studioList))
        var studioStamps = LinkMerge.Stamps()
        LinkMerge.noteChanges(from: [], to: studioApps, id: \.id, stamps: &studioStamps, at: Date(timeIntervalSince1970: 100))
        let airApps = [LinkConnectorApp(id: "slack", kind: "remote", enabled: true, entryJSON: #"{"id":"slack","kind":"remote","name":"Slack","url":"https://slack.example/mcp"}"#)]
        var airStamps = LinkMerge.Stamps()
        LinkMerge.noteChanges(from: [], to: airApps, id: \.id, stamps: &airStamps, at: Date(timeIntervalSince1970: 200))

        let onTheAir = LinkConnectorApps.merged(local: airApps, localStamps: airStamps, remote: LinkConnectorAppsItem(apps: studioApps, stamps: studioStamps))
        let plan = LinkConnectorApps.plan(local: airApps, merged: onTheAir.apps)
        #expect(plan.add.map(\.id) == ["gmail", "linear", "notion"])
        #expect(plan.remove.isEmpty)

        // And the other way round the Studio gets Slack, so both end up with the same list.
        let onTheStudio = LinkConnectorApps.merged(local: studioApps, localStamps: studioStamps, remote: LinkConnectorAppsItem(apps: airApps, stamps: airStamps))
        #expect(LinkConnectorApps.plan(local: studioApps, merged: onTheStudio.apps).add.map(\.id) == ["slack"])
        #expect(Set(onTheAir.apps.map(\.id)) == Set(onTheStudio.apps.map(\.id)))
    }

    @Test func aRemovalAndASwitchOffTravel() throws {
        let start = Date(timeIntervalSince1970: 100)
        let apps = try #require(LinkConnectorApps.sharedApps(fromConnectorList: studioList))
        var stamps = LinkMerge.Stamps()
        LinkMerge.noteChanges(from: [], to: apps, id: \.id, stamps: &stamps, at: start)
        // On the Studio, later: Linear removed, Gmail switched off.
        var changed = apps.filter { $0.id != "linear" }
        changed[changed.firstIndex(where: { $0.id == "gmail" })!].enabled = false
        var studioStamps = stamps
        LinkMerge.noteChanges(from: apps, to: changed, id: \.id, stamps: &studioStamps, at: start.addingTimeInterval(60))

        let onTheAir = LinkConnectorApps.merged(local: apps, localStamps: stamps, remote: LinkConnectorAppsItem(apps: changed, stamps: studioStamps))
        let plan = LinkConnectorApps.plan(local: apps, merged: onTheAir.apps)
        #expect(plan.remove == ["linear"])
        #expect(plan.disable == ["gmail"])
        #expect(plan.add.isEmpty && plan.enable.isEmpty)
    }

    @Test func aMacsSameListPlansNothing() throws {
        let apps = try #require(LinkConnectorApps.sharedApps(fromConnectorList: studioList))
        #expect(LinkConnectorApps.plan(local: apps, merged: apps).isEmpty)
    }
}

struct LinkBotFilesTests {
    private let earlier = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    @Test func theNewerFileWinsAndAMissingOneArrives() {
        let mine = LinkBotFile(text: "old instructions", changedAt: earlier)
        let theirs = LinkBotFile(text: "new instructions", changedAt: later)
        #expect(LinkBotFiles.copyToWrite(mine: mine, theirs: theirs) == theirs)
        #expect(LinkBotFiles.copyToWrite(mine: theirs, theirs: mine) == nil)
        #expect(LinkBotFiles.copyToWrite(mine: nil, theirs: theirs) == theirs)
        #expect(LinkBotFiles.copyToWrite(mine: mine, theirs: nil) == nil)
        #expect(LinkBotFiles.copyToWrite(mine: theirs, theirs: LinkBotFile(text: "new instructions", changedAt: earlier)) == nil)
    }

    @Test func bothMacsPickTheSameCopyAtTheSameTime() {
        let first = LinkBotFile(text: "alpha", changedAt: later)
        let second = LinkBotFile(text: "beta", changedAt: later)
        // One Mac writes the other's copy and the other keeps its own: the same text ends up on both.
        #expect(LinkBotFiles.copyToWrite(mine: second, theirs: first) == first)
        #expect(LinkBotFiles.copyToWrite(mine: first, theirs: second) == nil)
    }

    @Test func theFingerprintIsTheTextsOnly() {
        let one = LinkBotFilesItem(instructions: LinkBotFile(text: "a", changedAt: earlier), nature: nil)
        let two = LinkBotFilesItem(instructions: LinkBotFile(text: "a", changedAt: later), nature: nil)
        #expect(one.digest == two.digest)
        #expect(one.digest != LinkBotFilesItem(instructions: nil, nature: LinkBotFile(text: "a", changedAt: earlier)).digest)
    }
}

struct LinkSyncFolderAutoSetupTests {
    private let drive = LinkSyncFolder.Suggestion(name: "Google Drive", url: URL(fileURLWithPath: "/Users/someone/Library/CloudStorage/GoogleDrive-x/My Drive"))
    private let iCloud = LinkSyncFolder.Suggestion(name: "iCloud Drive", url: URL(fileURLWithPath: "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs"))

    @Test func turnsOnInTheSameCloudFolderAsTheOtherMac() {
        #expect(LinkSyncFolder.autoSetup(otherMacFolder: "Google Drive", enabledHere: false, ownerTurnedOffHere: false, suggestions: [iCloud, drive]) == .use(drive))
    }

    @Test func saysWhatToInstallWhenThisMacHasNoSuchFolder() {
        #expect(LinkSyncFolder.autoSetup(otherMacFolder: "Google Drive", enabledHere: false, ownerTurnedOffHere: false, suggestions: [iCloud]) == .needsCloudApp("Google Drive"))
        #expect(LinkSyncFolder.cloudAppHelp("Google Drive").contains("Google Drive for desktop"))
    }

    @Test func leavesTheOwnersChoiceAlone() {
        #expect(LinkSyncFolder.autoSetup(otherMacFolder: "Google Drive", enabledHere: false, ownerTurnedOffHere: true, suggestions: [drive]) == .nothing)
        #expect(LinkSyncFolder.autoSetup(otherMacFolder: "Google Drive", enabledHere: true, ownerTurnedOffHere: false, suggestions: [drive]) == .nothing)
        #expect(LinkSyncFolder.autoSetup(otherMacFolder: nil, enabledHere: false, ownerTurnedOffHere: false, suggestions: [drive]) == .nothing)
        #expect(LinkSyncFolder.autoSetup(otherMacFolder: LinkSyncFolder.ownFolderName, enabledHere: false, ownerTurnedOffHere: false, suggestions: [drive]) == .askOwnerToChoose)
    }
}
