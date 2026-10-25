//
//  ProjectBridgeController.swift
//  leanring-buddy
//
//  "send this to my project …": the owner hands a task to his Claude Code
//  project coordinator, a separate session that watches
//  ~/.clicky/project-outbox and relays it. Clicky only writes one small
//  JSON file there and reads the coordinator's replies from
//  ~/.clicky/project-inbox/<id>.json (formats in ClickyCore's
//  ProjectBridgeFiles.swift).
//
//  The trigger reads only the owner's speech transcript for the turn
//  (ProjectSendTrigger), so on-screen text or a model tag never sends. A
//  triggered turn is answered here ("Sent to your project.") without a
//  brain turn. The task shows in the Agents dashboard as a .projectTask and
//  in the notch for a few seconds ("sent to project").
//
//  Replies: every 2 s, only while a project task is waiting, the inbox file
//  of each waiting task is checked (its modification date first, then at
//  most 16 KB read). A forward phase change updates the dashboard and the
//  notch, and is said once (thread started / done / couldn't), after
//  Clicky finishes whatever it's saying, and never with
//  v2.project.speakUpdates off. The note is shown and spoken only; the link
//  is shown, never opened. Nothing here opens a window or takes focus.
//
//  A named OTHER project ("update it to the Claude Code project called X",
//  "send this to the X project") goes to NamedProjectRouter first, before
//  this project's trigger: a local repo match runs as a code-mode task,
//  otherwise Clicky offers to put the message into the Claude app.
//

import AppKit
import ClickyCore
import Combine
import Foundation

@MainActor
final class ProjectBridgeController: ObservableObject {
    /// The notch's short-lived status ("sent to project", "project: done"); nil otherwise.
    @Published private(set) var notchStatusText: String?

    enum SendOutcome: Equatable {
        /// No trigger phrase in the owner's words: the brain handles the turn.
        case notTriggered
        /// v2.project.enabled is off: the brain handles the turn.
        case disabled
        /// The phrase without a task: Clicky asked what to send.
        case askedForTask
        /// A named other project ("… the project called X"), or the answer to
        /// its offer / pick card: NamedProjectRouter handles it.
        case namedProject
        case sent(id: String, path: String)
        case failed(reason: String)

        /// True when this turn is answered here (no brain turn).
        var isHandledLocally: Bool {
            switch self {
            case .notTriggered, .disabled: return false
            case .askedForTask, .namedProject, .sent, .failed: return true
            }
        }
    }

    private weak var companionManager: CompanionManager?
    private let outboxDirectoryURL: URL
    private let inboxDirectoryURL: URL
    private var spokenUpdateQueue = ProjectSpokenUpdateQueue()
    /// Tasks sent with speak:false (debug): their updates stay silent too.
    private var silentTaskIDs: Set<String> = []
    /// Each waiting task's reply file as last read, so an unchanged file isn't parsed again.
    private var lastReadReplyModificationDates: [String: Date] = [:]
    private var pollTimer: Timer?
    private var notchStatusClearTask: Task<Void, Never>?
    /// "send this to the X project" for a project other than this one.
    private(set) lazy var namedProjectRouter: NamedProjectRouter? = companionManager.map { NamedProjectRouter(companionManager: $0) }

    private static let pollIntervalSeconds: TimeInterval = 2
    private static let notchStatusSeconds: UInt64 = 4

    init(companionManager: CompanionManager, outboxDirectoryURL: URL = ProjectOutbox.defaultDirectoryURL,
         inboxDirectoryURL: URL = ProjectInbox.defaultDirectoryURL) {
        self.companionManager = companionManager
        self.outboxDirectoryURL = outboxDirectoryURL
        self.inboxDirectoryURL = inboxDirectoryURL
    }

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollInboxAndSpeakPendingUpdates() }
        }
        pollInboxAndSpeakPendingUpdates()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        notchStatusClearTask?.cancel()
    }

    // MARK: - Sending

    /// The owner's transcript for this turn. When it holds a trigger phrase
    /// (and the bridge is on) the task is written to the outbox and answered
    /// here; `speaks` false (a silent debug ask) says nothing now or later.
    @discardableResult
    func handleSpokenTranscript(_ transcript: String, speaks: Bool = true) -> SendOutcome {
        // A named other project (or the answer to its offer / pick card) comes
        // first: "send it to the project called X" must not reach this project.
        if ClickySettings.isProjectBridgeEnabled, namedProjectRouter?.handleSpokenTranscript(transcript, speaks: speaks) == true {
            return .namedProject
        }
        guard let triggerMatch = ProjectSendTrigger.match(transcript: transcript) else { return .notTriggered }
        guard ClickySettings.isProjectBridgeEnabled else {
            print("📮 Project: trigger heard but v2.project.enabled is off")
            return .disabled
        }
        guard !triggerMatch.taskText.isEmpty else {
            print("📮 Project: \"\(triggerMatch.triggerPhrase)\" without a task, asking for one")
            if speaks { companionManager?.speakCodeModeLine(ProjectUpdateSpeech.askForTaskLine) }
            return .askedForTask
        }

        let message = makeOutboxMessage(taskText: triggerMatch.taskText)
        let writtenFileURL: URL
        do {
            writtenFileURL = try ProjectOutbox.write(message, to: outboxDirectoryURL)
        } catch {
            print("⚠️ Project: couldn't write the outbox file: \(error)")
            if speaks { companionManager?.speakCodeModeLine(ProjectUpdateSpeech.couldNotWriteLine) }
            return .failed(reason: "couldn't write the outbox file: \(error.localizedDescription)")
        }
        print("📮 Project: sent \(message.id) → \(writtenFileURL.path)")

        if let agentsCenter = companionManager?.agentsCenter {
            agentsCenter.begin(id: message.id, kind: .projectTask, title: triggerMatch.taskText, model: nil, status: .queued, phase: ProjectTaskPhase.queued.rawValue)
            agentsCenter.update(message.id) { record in
                record.repository = message.repoRoot
                record.currentStep = ProjectTaskPhase.queued.displayName
            }
            agentsCenter.log(message.id, "sent to your project: \(writtenFileURL.lastPathComponent)")
            if let frontAppName = message.frontApp.name { agentsCenter.log(message.id, "front app: \(frontAppName)") }
        }
        if !speaks { silentTaskIDs.insert(message.id) }
        flashNotchStatus(ProjectTaskPhase.queued.notchStatusText)
        if speaks { companionManager?.speakCodeModeLine(ProjectUpdateSpeech.sentLine) }
        return .sent(id: message.id, path: writtenFileURL.path)
    }

    /// The front app, its window title (read the same read-only way as Code
    /// mode's "this repo"), the window's git root when it maps to one (never a
    /// Clicky checkout) and the display under the pointer. Nothing else.
    private func makeOutboxMessage(taskText: String) -> ProjectOutboxMessage {
        let frontApplication = NSWorkspace.shared.frontmostApplication
        let frontWindowContext = FrontWindowProbe.capture()
        var repoRoot: String?
        if let frontWindowContext, let codeModeController = companionManager?.codeModeController {
            let resolution = FrontWindowRepoResolver.resolve(frontWindowContext, localRepos: codeModeController.indexedLocalReposForFrontWindow)
            repoRoot = ProjectOutboxMessage.repoRoot(from: resolution)
        }
        let mouseLocation = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
        let cursorDisplay = cursorScreen.map { screen in
            ProjectOutboxMessage.CursorDisplay(id: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                                               name: screen.localizedName)
        }
        return ProjectOutboxMessage(
            transcript: taskText,
            frontApp: ProjectOutboxMessage.FrontApp(bundleId: frontApplication?.bundleIdentifier, name: frontApplication?.localizedName),
            frontWindowTitle: frontWindowContext?.windowTitle,
            repoRoot: repoRoot,
            cursorDisplay: cursorDisplay
        )
    }

    // MARK: - Replies

    /// One cheap pass: nothing at all unless a project task is waiting or a
    /// spoken update is queued.
    private func pollInboxAndSpeakPendingUpdates() {
        guard let companionManager else { return }
        let agentsCenter = companionManager.agentsCenter
        agentsCenter.expireStaleProjectTasks()
        for waitingRecord in agentsCenter.store.activeProjectTaskRecords {
            readReply(forTaskID: waitingRecord.id, agentsCenter: agentsCenter)
        }
        speakPendingUpdatesIfIdle()
    }

    private func readReply(forTaskID taskID: String, agentsCenter: AgentsCenter) {
        guard let modificationDate = ProjectInbox.modificationDate(forTaskID: taskID, in: inboxDirectoryURL),
              modificationDate != lastReadReplyModificationDates[taskID] else { return }
        lastReadReplyModificationDates[taskID] = modificationDate
        guard let reply = ProjectInbox.readReply(forTaskID: taskID, in: inboxDirectoryURL) else {
            print("⚠️ Project: ignored an unreadable, oversized or malformed reply for \(taskID)")
            return
        }
        guard let newPhase = agentsCenter.applyProjectReply(reply) else { return }
        print("📮 Project: \(taskID) → \(newPhase.rawValue)")
        flashNotchStatus(newPhase.notchStatusText)
        if !newPhase.agentStatus.isActive { lastReadReplyModificationDates[taskID] = nil }
        let speaksUpdates = ClickySettings.isProjectSpeakUpdatesEnabled && !silentTaskIDs.contains(taskID)
        spokenUpdateQueue.noteChange(taskID: taskID, phase: newPhase, note: reply.note, speaksUpdates: speaksUpdates)
    }

    /// Queued updates wait until Clicky is idle (not listening, thinking or talking).
    private func speakPendingUpdatesIfIdle() {
        guard let companionManager, !spokenUpdateQueue.pendingLines.isEmpty else { return }
        let isClickyIdle = companionManager.voiceState == .idle && !companionManager.speechOutputClient.isPlaying
        let linesToSpeak = spokenUpdateQueue.takeLinesToSpeak(isClickyIdle: isClickyIdle)
        guard !linesToSpeak.isEmpty else { return }
        // A setting switched off while a line waited: drop it.
        guard ClickySettings.isProjectSpeakUpdatesEnabled else { return }
        companionManager.speakCodeModeLine(linesToSpeak.joined(separator: " "))
    }

    // MARK: - Notch

    private func flashNotchStatus(_ text: String) {
        notchStatusText = text
        notchStatusClearTask?.cancel()
        notchStatusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.notchStatusSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notchStatusText = nil
        }
    }

    // MARK: - Debug

    /// The dashboard's project tasks, newest first (debug `projectStatus`).
    func statusSnapshot() -> [String: Any] {
        let isoFormatter = ISO8601DateFormatter()
        let projectRecords = (companionManager?.agentsCenter.store.records ?? [])
            .filter { $0.kind == .projectTask }
            .sorted { $0.startedAt > $1.startedAt }
        let tasks: [[String: Any]] = projectRecords.map { record in
            [
                "id": record.id,
                "title": record.title,
                "status": record.status.rawValue,
                "phase": record.phase ?? NSNull(),
                "note": record.note ?? NSNull(),
                "link": record.link ?? NSNull(),
                "repoRoot": record.repository ?? NSNull(),
                "error": record.errorDescription ?? NSNull(),
                "startedAt": isoFormatter.string(from: record.startedAt),
                "endedAt": record.endedAt.map { isoFormatter.string(from: $0) } ?? NSNull()
            ]
        }
        return [
            "enabled": ClickySettings.isProjectBridgeEnabled,
            "speakUpdates": ClickySettings.isProjectSpeakUpdatesEnabled,
            "outbox": outboxDirectoryURL.path,
            "inbox": inboxDirectoryURL.path,
            "notchStatus": notchStatusText ?? NSNull(),
            "pendingSpokenUpdates": spokenUpdateQueue.pendingLines.map(\.text),
            "namedProject": namedProjectRouter?.statusSnapshot() ?? NSNull(),
            "tasks": tasks
        ]
    }
}
