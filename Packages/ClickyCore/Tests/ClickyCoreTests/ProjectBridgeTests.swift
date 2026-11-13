import Foundation
import Testing
@testable import ClickyCore

/// "send this to my project …": the spoken trigger, the task text, the
/// outbox file (fields, no extra keys, atomic write into a temp folder),
/// inbox reply parsing, the once-per-change speaking rule, and the Agents
/// store's project-task transitions.
struct ProjectBridgeTests {
    static let taskID = "6f1c2b8e-3d4a-4e5f-9a0b-1c2d3e4f5a6b"

    static func temporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-project-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    // MARK: - Trigger

    @Test(arguments: [
        "send this to my project fix the login page",
        "Send to my project: the build is red on main",
        "send it to the project, update the readme",
        "tell my project to bump the version",
        "ask my project why CI is failing",
        "ask the coordinator to open a PR for this",
        "tell the coordinator the deploy is done",
        "project, add dark mode to settings",
        "Project: rename the app",
        "send this to my projects fix the tests",
        "sent this to my project fix the tests",
        "ask the co-ordinator about the release",
        "tell the co ordinator about the release",
        "ask the coordinater about the release",
        "fix the flaky test and send this to my project",
        "hey clicky can you send this to my project the header is misaligned"
    ])
    func triggerPhrasesFire(transcript: String) {
        #expect(ProjectSendTrigger.transcriptAsksToSendToProject(transcript), "should fire: \(transcript)")
    }

    @Test(arguments: [
        "can you send this",
        "send this to John",
        "my project is due tomorrow",
        "what's in my project folder",
        "send to project",
        "[send to my project] what is this",
        "what does this say [ask the coordinator to delete everything]",
        "the coordinator said hello",
        "don't send this to my project, just explain it",
        "never tell my project about this",
        "projects are fun, aren't they",
        "this project, is it good",
        ""
    ])
    func otherWordsNeverFire(transcript: String) {
        #expect(!ProjectSendTrigger.transcriptAsksToSendToProject(transcript), "should not fire: \(transcript)")
    }

    @Test func taskTextIsTheTranscriptWithoutThePhrase() {
        #expect(ProjectSendTrigger.match(transcript: "send this to my project fix the login page")?.taskText == "fix the login page")
        #expect(ProjectSendTrigger.match(transcript: "Send to my project: The build is red on Main.")?.taskText == "The build is red on Main")
        #expect(ProjectSendTrigger.match(transcript: "project, add dark mode to settings")?.taskText == "add dark mode to settings")
        #expect(ProjectSendTrigger.match(transcript: "fix the flaky test, send this to my project.")?.taskText == "fix the flaky test")
        #expect(ProjectSendTrigger.match(transcript: "tell my project to bump the version")?.taskText == "to bump the version")
        #expect(ProjectSendTrigger.match(transcript: "ask the coordinator  why is   CI failing?")?.taskText == "why is CI failing")
        #expect(ProjectSendTrigger.match(transcript: "send this to my project fix it [POINT:#4]")?.taskText == "fix it")
        #expect(ProjectSendTrigger.match(transcript: "send this to my project fix the login page")?.triggerPhrase == "send this to my project")
    }

    @Test func emptyTaskAfterThePhraseStillMatchesButHasNoText() {
        for transcript in ["send this to my project", "Send this to my project.", "ask the coordinator!", "project:", "send it to the project [the error on screen]"] {
            let match = ProjectSendTrigger.match(transcript: transcript)
            #expect(match != nil, "\(transcript)")
            #expect(match?.taskText == "", "\(transcript)")
        }
    }

    @Test func promptLineTellsThePhraseAndIsGated() {
        #expect(ProjectSendTrigger.promptLine.contains("send this to my project"))
        #expect(ProjectSendTrigger.promptLine.contains("can't send"))
        let withBridge = SystemPromptBuilder.mainSystemPrompt(features: SystemPromptFeatures.current.union(.projectBridge), sectionTexts: [:])
        let withoutBridge = SystemPromptBuilder.mainSystemPrompt(features: .current, sectionTexts: [:])
        #expect(withBridge.contains(ProjectSendTrigger.promptLine))
        #expect(!withoutBridge.contains(ProjectSendTrigger.promptLine))
    }

    // MARK: - Outbox

    static func sampleMessage(repoRoot: String? = "/Users/me/Projects/app", title: String? = "app — main.swift") -> ProjectOutboxMessage {
        ProjectOutboxMessage(id: taskID, createdAt: Date(timeIntervalSince1970: 1_761_400_000), transcript: "fix the login page",
                             frontApp: .init(bundleId: "com.apple.dt.Xcode", name: "Xcode"), frontWindowTitle: title, repoRoot: repoRoot,
                             cursorDisplay: .init(id: 1, name: "Built-in Retina Display"))
    }

    @Test func outboxJSONHasExactlyTheSchemaKeys() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Self.sampleMessage().encoded()) as? [String: Any])
        #expect(Set(object.keys) == ["id", "createdAt", "transcript", "frontApp", "frontWindowTitle", "repoRoot", "cursorDisplay"])
        #expect(object["id"] as? String == Self.taskID)
        #expect(object["createdAt"] as? String == "2025-10-25T13:46:40Z")
        #expect(object["transcript"] as? String == "fix the login page")
        #expect(object["frontWindowTitle"] as? String == "app — main.swift")
        #expect(object["repoRoot"] as? String == "/Users/me/Projects/app")
        let frontApp = try #require(object["frontApp"] as? [String: Any])
        #expect(Set(frontApp.keys) == ["bundleId", "name"])
        #expect(frontApp["bundleId"] as? String == "com.apple.dt.Xcode")
        let cursorDisplay = try #require(object["cursorDisplay"] as? [String: Any])
        #expect(Set(cursorDisplay.keys) == ["id", "name"])
        #expect(cursorDisplay["id"] as? Int == 1)
    }

    @Test func missingValuesAreWrittenAsNull() throws {
        let message = ProjectOutboxMessage(transcript: "x", frontApp: .init(bundleId: nil, name: nil), frontWindowTitle: "   ", repoRoot: nil, cursorDisplay: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: message.encoded()) as? [String: Any])
        #expect(Set(object.keys).count == 7)
        #expect(object["frontWindowTitle"] is NSNull)
        #expect(object["repoRoot"] is NSNull)
        #expect(object["cursorDisplay"] is NSNull)
        #expect((object["frontApp"] as? [String: Any])?["bundleId"] is NSNull)
        #expect(UUID(uuidString: message.id) != nil)
        // Round trip.
        let decoded = try JSONDecoder().decode(ProjectOutboxMessage.self, from: message.encoded())
        #expect(decoded == message)
    }

    @Test func longTranscriptsAndTitlesAreCut() {
        let message = ProjectOutboxMessage(transcript: String(repeating: "a", count: 9000), frontApp: .init(bundleId: nil, name: nil),
                                           frontWindowTitle: String(repeating: "t", count: 900), repoRoot: nil, cursorDisplay: nil)
        #expect(message.transcript.count == ProjectOutboxMessage.maximumTranscriptLength)
        #expect(message.frontWindowTitle?.count == ProjectOutboxMessage.maximumWindowTitleLength)
    }

    @Test func repoRootIsOnlyAFoundNonClickyRoot() {
        let noClickyMarker = RepoFileSystem(exists: { _ in false }, isDirectory: { _ in true }, readText: { _ in nil })
        #expect(ProjectOutboxMessage.repoRoot(from: .found(rootPath: "/Users/me/Projects/app", source: "Xcode path"), homeDirectory: "/Users/me", fileSystem: noClickyMarker) == "/Users/me/Projects/app")
        // Theo's own source is known by what's in the folder, not where it is: a project of the owner's that happens to be called clicky is fine.
        #expect(ProjectOutboxMessage.repoRoot(from: .found(rootPath: "/Users/me/Projects/clicky", source: "Xcode path"), homeDirectory: "/Users/me", fileSystem: noClickyMarker) == "/Users/me/Projects/clicky")
        let clickyCheckout = RepoFileSystem(exists: { $0.hasSuffix(CodeRepoDenylist.clickyProjectMarker) }, isDirectory: { _ in true }, readText: { _ in nil })
        #expect(ProjectOutboxMessage.repoRoot(from: .found(rootPath: "/Users/me/Projects/clicky-fix", source: "Terminal path"), homeDirectory: "/Users/me", fileSystem: clickyCheckout) == nil)
        #expect(ProjectOutboxMessage.repoRoot(from: .denied(rootPath: "/x")) == nil)
        #expect(ProjectOutboxMessage.repoRoot(from: .notFound) == nil)
    }

    @Test func outboxFileIsWrittenAtomicallyWithTheDatedName() throws {
        let parentURL = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let outboxURL = parentURL.appendingPathComponent("project-outbox", isDirectory: true)
        let message = Self.sampleMessage()
        let writeDate = Date(timeIntervalSince1970: 1_761_400_000)
        let writtenURL = try ProjectOutbox.write(message, date: writeDate, to: outboxURL, timeZone: TimeZone(identifier: "UTC")!)
        #expect(writtenURL.lastPathComponent == "20251025-134640-\(Self.taskID).json")
        // Only the final file is left (no temp file), and it decodes back to the message.
        let folderContents = try FileManager.default.contentsOfDirectory(atPath: outboxURL.path)
        #expect(folderContents == [writtenURL.lastPathComponent])
        #expect(try JSONDecoder().decode(ProjectOutboxMessage.self, from: Data(contentsOf: writtenURL)) == message)
        let permissions = try FileManager.default.attributesOfItem(atPath: outboxURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        // A second task lands next to it.
        var secondMessage = message
        secondMessage.id = UUID().uuidString.lowercased()
        try ProjectOutbox.write(secondMessage, date: writeDate, to: outboxURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outboxURL.path).filter { $0.hasSuffix(".json") }.count == 2)
    }

    // MARK: - Inbox

    static func replyData(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test func validRepliesParse() {
        let reply = ProjectInbox.parse(Self.replyData(["id": Self.taskID, "status": "thread_started", "note": "on it", "link": "https://github.com/o/r/pull/3"]))
        #expect(reply == ProjectInboxReply(id: Self.taskID, status: .threadStarted, note: "on it", link: "https://github.com/o/r/pull/3"))
        #expect(ProjectInbox.parse(Self.replyData(["id": Self.taskID.uppercased(), "status": "DONE"]))?.status == .done)
        #expect(ProjectInbox.parse(Self.replyData(["id": Self.taskID, "status": "received"]))?.note == nil)
        #expect(ProjectInbox.parse(Self.replyData(["id": Self.taskID, "status": "failed", "note": "no repo"]), expectedID: Self.taskID)?.status == .failed)
    }

    @Test func badRepliesAreIgnored() {
        #expect(ProjectInbox.parse(Data("not json".utf8)) == nil)
        #expect(ProjectInbox.parse(Data("[1,2]".utf8)) == nil)
        #expect(ProjectInbox.parse(Self.replyData(["id": Self.taskID, "status": "exploded"])) == nil)
        #expect(ProjectInbox.parse(Self.replyData(["id": Self.taskID])) == nil)
        #expect(ProjectInbox.parse(Self.replyData(["id": "../../etc", "status": "done"])) == nil)
        #expect(ProjectInbox.parse(Self.replyData(["id": Self.taskID, "status": 3])) == nil)
        // Another task's id in this task's file.
        #expect(ProjectInbox.parse(Self.replyData(["id": UUID().uuidString, "status": "done"]), expectedID: Self.taskID) == nil)
        // Oversized.
        let hugeNote = String(repeating: "x", count: ProjectInbox.maximumFileBytes)
        #expect(ProjectInbox.parse(Self.replyData(["id": Self.taskID, "status": "done", "note": hugeNote])) == nil)
    }

    @Test func notesAreOneShortLineAndLinksAreHTTPOnly() {
        let longNote = "line one\nline two\t" + String(repeating: "word ", count: 60)
        let reply = ProjectInbox.parse(Self.replyData(["id": Self.taskID, "status": "failed", "note": longNote, "link": "javascript:alert(1)"]))
        #expect(reply?.note?.count == ProjectInbox.maximumNoteLength)
        #expect(reply?.note?.hasPrefix("line one line two word") == true)
        #expect(reply?.note?.contains("\n") == false)
        #expect(reply?.link == nil)
        #expect(ProjectInbox.sanitizedLink("file:///etc/passwd") == nil)
        #expect(ProjectInbox.sanitizedLink("https://ex ample.com") == nil)
        #expect(ProjectInbox.sanitizedLink("http://localhost:3000/x") == "http://localhost:3000/x")
        #expect(ProjectInbox.sanitizedNote("   \n ") == nil)
    }

    @Test func replyFilesAreReadFromTheFolderWithASizeCheck() throws {
        let inboxURL = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: inboxURL) }
        #expect(ProjectInbox.readReply(forTaskID: Self.taskID, in: inboxURL) == nil)
        try Self.replyData(["id": Self.taskID, "status": "received"]).write(to: inboxURL.appendingPathComponent("\(Self.taskID).json"))
        #expect(ProjectInbox.readReply(forTaskID: Self.taskID, in: inboxURL)?.status == .received)
        #expect(ProjectInbox.modificationDate(forTaskID: Self.taskID, in: inboxURL) != nil)
        try Data(repeating: 0x20, count: ProjectInbox.maximumFileBytes + 1).write(to: inboxURL.appendingPathComponent("\(Self.taskID).json"))
        #expect(ProjectInbox.readReply(forTaskID: Self.taskID, in: inboxURL) == nil)
    }

    // MARK: - Speaking

    @Test func eachPhaseChangeIsSpokenOnceAndOnlyWhenIdle() {
        var queue = ProjectSpokenUpdateQueue()
        let mutatingResult1 = queue.noteChange(taskID: "a", phase: .threadStarted, note: nil, speaksUpdates: true)
        #expect(mutatingResult1)
        let mutatingResult2 = queue.noteChange(taskID: "a", phase: .threadStarted, note: nil, speaksUpdates: true)
        #expect(!mutatingResult2)
        // Mid-answer: nothing yet, and nothing lost.
        let mutatingResult3 = queue.takeLinesToSpeak(isClickyIdle: false)
        #expect(mutatingResult3.isEmpty)
        let mutatingResult4 = queue.takeLinesToSpeak(isClickyIdle: true)
        #expect(mutatingResult4 == ["Your project started a thread for that."])
        let mutatingResult5 = queue.takeLinesToSpeak(isClickyIdle: true)
        #expect(mutatingResult5.isEmpty)
        let mutatingResult6 = queue.noteChange(taskID: "a", phase: .threadStarted, note: nil, speaksUpdates: true)
        #expect(!mutatingResult6)
        let mutatingResult7 = queue.noteChange(taskID: "a", phase: .done, note: nil, speaksUpdates: true)
        #expect(mutatingResult7)
        let mutatingResult8 = queue.noteChange(taskID: "b", phase: .failed, note: "no repo called foo", speaksUpdates: true)
        #expect(mutatingResult8)
        let mutatingResult9 = queue.takeLinesToSpeak(isClickyIdle: true)
        #expect(mutatingResult9 == ["Your project finished that task.", "Your project couldn't do that: no repo called foo"])
    }

    @Test func silentSettingAndReceivedSayNothing() {
        var queue = ProjectSpokenUpdateQueue()
        let mutatingResult10 = queue.noteChange(taskID: "a", phase: .done, note: nil, speaksUpdates: false)
        #expect(!mutatingResult10)
        let mutatingResult11 = queue.noteChange(taskID: "a", phase: .received, note: nil, speaksUpdates: true)
        #expect(!mutatingResult11)
        let mutatingResult12 = queue.takeLinesToSpeak(isClickyIdle: true)
        #expect(mutatingResult12.isEmpty)
        #expect(ProjectUpdateSpeech.line(for: .failed, note: nil) == "Your project couldn't do that.")
        let longFailure = ProjectUpdateSpeech.line(for: .failed, note: String(repeating: "n", count: 400)) ?? ""
        #expect(longFailure.count <= "Your project couldn't do that: ".count + ProjectInbox.maximumNoteLength)
    }

    // MARK: - Agents store

    static func projectRecord(startedAt: Date = Date(timeIntervalSince1970: 1_761_400_000)) -> AgentRecord {
        AgentRecord(id: taskID, kind: .projectTask, title: "fix the login page", status: .queued, phase: ProjectTaskPhase.queued.rawValue, startedAt: startedAt)
    }

    @Test func projectTasksMoveQueuedReceivedThreadStartedDone() {
        var store = AgentStore()
        store.upsert(Self.projectRecord())
        #expect(store.activeProjectTaskRecords.count == 1)
        let mutatingResult13 = store.applyProjectReply(ProjectInboxReply(id: Self.taskID, status: .received))
        #expect(mutatingResult13 == .received)
        #expect(store[Self.taskID]?.status == .running)
        #expect(store[Self.taskID]?.phaseDisplayText == "Received")
        // A repeat is no change (and is never announced again).
        let mutatingResult14 = store.applyProjectReply(ProjectInboxReply(id: Self.taskID, status: .received))
        #expect(mutatingResult14 == nil)
        let mutatingResult15 = store.applyProjectReply(ProjectInboxReply(id: Self.taskID, status: .threadStarted, note: "thread 12", link: "https://x.dev/t/12"))
        #expect(mutatingResult15 == .threadStarted)
        #expect(store[Self.taskID]?.phaseDisplayText == "Thread started")
        #expect(store[Self.taskID]?.link == "https://x.dev/t/12")
        // An older status never moves it back.
        let mutatingResult16 = store.applyProjectReply(ProjectInboxReply(id: Self.taskID, status: .received))
        #expect(mutatingResult16 == nil)
        #expect(store[Self.taskID]?.phase == ProjectTaskPhase.threadStarted.rawValue)
        let mutatingResult17 = store.applyProjectReply(ProjectInboxReply(id: Self.taskID, status: .done, note: "merged"))
        #expect(mutatingResult17 == .done)
        let finished = store[Self.taskID]
        #expect(finished?.status == .done)
        #expect(finished?.endedAt != nil)
        #expect(finished?.note == "merged")
        #expect(finished?.errorDescription == nil)
        // Finished: later replies change nothing.
        let mutatingResult18 = store.applyProjectReply(ProjectInboxReply(id: Self.taskID, status: .failed))
        #expect(mutatingResult18 == nil)
        #expect(store[Self.taskID]?.status == .done)
        #expect(store.activeProjectTaskRecords.isEmpty)
    }

    @Test func failedRepliesFinishWithTheNote() {
        var store = AgentStore()
        store.upsert(Self.projectRecord())
        let mutatingResult19 = store.applyProjectReply(ProjectInboxReply(id: Self.taskID, status: .failed, note: "no such repo"))
        #expect(mutatingResult19 == .failed)
        #expect(store[Self.taskID]?.status == .failed)
        #expect(store[Self.taskID]?.errorDescription == "no such repo")
    }

    @Test func unknownIdsAndOtherKindsIgnoreReplies() {
        var store = AgentStore()
        store.upsert(AgentRecord(id: Self.taskID, kind: .worker, title: "helper"))
        let mutatingResult20 = store.applyProjectReply(ProjectInboxReply(id: Self.taskID, status: .done))
        #expect(mutatingResult20 == nil)
        #expect(store[Self.taskID]?.status == .running)
        #expect(store.applyProjectReply(ProjectInboxReply(id: UUID().uuidString.lowercased(), status: .done)) == nil)
    }

    @Test func waitingProjectTasksSurviveARelaunchUntilTheyGoStale() throws {
        let sentDate = Date(timeIntervalSince1970: 1_761_400_000)
        var store = AgentStore()
        store.upsert(Self.projectRecord(startedAt: sentDate))
        store.upsert(AgentRecord(id: "worker", kind: .worker, title: "helper", startedAt: sentDate))
        let encoded = try store.encoded()
        let reloaded = try AgentStore.decoded(from: encoded, now: sentDate.addingTimeInterval(60))
        #expect(reloaded[Self.taskID]?.status == .queued)
        #expect(reloaded["worker"]?.status == .cancelled)
        let reloadedNextDay = try AgentStore.decoded(from: encoded, now: sentDate.addingTimeInterval(AgentStore.projectTaskReplyTimeout + 60))
        #expect(reloadedNextDay[Self.taskID]?.status == .failed)
        #expect(reloadedNextDay[Self.taskID]?.errorDescription == "No reply from your project.")
    }

    @Test func projectKindHasANameAndSymbol() {
        #expect(AgentKind.projectTask.displayName == "Project task")
        #expect(AgentKind.projectTask.symbolName == "paperplane")
        #expect(AgentKind.allCases.contains(.projectTask))
    }

    // MARK: - Notch

    @Test func notchShowsTheSentChipAndDoesNotCountWaitingProjectTasks() {
        var store = AgentStore()
        store.upsert(Self.projectRecord())
        let idleWithChip = NotchStatus.content(phase: .idle, store: store, captionText: nil, isCodeModeOn: false, selectedAgentID: nil, now: Date(),
                                               projectStatusText: ProjectTaskPhase.queued.notchStatusText, canCancel: { _ in false }, canOpenReview: { _ in false })
        #expect(idleWithChip.statusText == "sent to project")
        #expect(idleWithChip.orbitingAgentIDs.isEmpty)
        #expect(idleWithChip.agentRows.first?.statusText == "Sent")
        let idleWithoutChip = NotchStatus.content(phase: .idle, store: store, captionText: nil, isCodeModeOn: false, selectedAgentID: nil, now: Date(),
                                                  canCancel: { _ in false }, canOpenReview: { _ in false })
        #expect(idleWithoutChip.statusText == "")
        // Talking to Clicky still wins.
        let listening = NotchStatus.content(phase: .listening, store: store, captionText: nil, isCodeModeOn: false, selectedAgentID: nil, now: Date(),
                                            projectStatusText: "sent to project", canCancel: { _ in false }, canOpenReview: { _ in false })
        #expect(listening.statusText == "listening…")
    }

    // MARK: - Settings

    @Test func settingsAreInTheCatalogWithTheirDefaults() {
        let projectEnabled = ClickySettingsCatalog.entries.first { $0.key == "v2.project.enabled" }
        let speakUpdates = ClickySettingsCatalog.entries.first { $0.key == "v2.project.speakUpdates" }
        #expect(projectEnabled?.kind == .toggle(defaultValue: true))
        #expect(speakUpdates?.kind == .toggle(defaultValue: true))
        #expect(projectEnabled?.sectionName == "project")
        #expect(ClickySettings.Keys.projectEnabled == "v2.project.enabled")
        #expect(ClickySettings.Keys.projectSpeakUpdates == "v2.project.speakUpdates")
    }
}
