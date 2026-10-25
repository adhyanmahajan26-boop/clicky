//
//  NamedProjectRouter.swift
//  leanring-buddy
//
//  "update it to the Claude Code project called Mahajan motor work": the
//  owner names a project other than this one (NamedProjectTrigger, his own
//  words only). Clicky looks for it on his Mac and, when it finds it, runs
//  a code-mode repo_change there; otherwise it offers to put the message
//  into the Claude app for him to send. Nothing is ever sent for him.
//
//  1. Candidates: the clones code mode indexes (v2.code.repoRoots) plus the
//     folders his Claude Code sessions ran in (the NAMES under
//     ~/.claude/projects decoded back to paths — no file there is opened).
//  2. ProjectDestinationMatcher: a saved alias (v2.code.projectAliases)
//     wins; else one clear match runs; close ones go on a small pick card
//     (non-activating, a mouse click per row, or the next turn: "the
//     website one", "billing", "the first one", "yes", "cancel"), the pick
//     saved as an alias so he's asked once; nothing close → the offer.
//  3. A match: code mode (said aloud and switched on when off — he named
//     the project and asked for the change), the 2 s "Opening <path>" card,
//     a worktree, his words verbatim as the instructions, the previous
//     turn's screenshot copied into the worktree for the agent to Read, and
//     his newest Claude Code session in that repo resumed as a FORK
//     (`--resume <id> --fork-session`, his history untouched). Every code
//     mode gate is unchanged: worktree edits only, anything outward only by
//     a real click in the review panel.
//  4. No match: "I can only send to the Clicky project right now. Want me
//     to open Claude at X …?" and, on a spoken yes within 60 s, the message
//     (plus "Screenshot: <path>") is put on the clipboard and Claude is
//     brought forward. Never pasted, never sent, Return never pressed.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

@MainActor
final class NamedProjectRouter {
    /// The Claude desktop app.
    static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"
    /// A screenshot older than this isn't "the previous turn's".
    static let screenshotFreshnessSeconds: TimeInterval = 10 * 60
    static let candidateCacheSeconds: TimeInterval = 5 * 60

    private weak var companionManager: CompanionManager?
    private var pendingOffer: NamedProjectOffer?
    private var pendingPick: PendingPick?
    private let pickCard = ProjectPickCardController()
    private var cachedCandidates: (date: Date, candidates: [ProjectFolderCandidate])?
    private var resolutionTask: Task<Void, Never>?
    /// The last few decisions, for the debug status.
    private(set) var recentEvents: [String] = []

    struct PendingPick {
        var spokenName: String
        var rows: [ProjectFolderCandidate]
        var preselectedIndex: Int
        var request: NamedRequest
        var createdAt: Date
    }

    /// What the owner asked, as heard.
    struct NamedRequest {
        var projectName: String
        /// The transcript without the destination phrase (clipboard text).
        var taskText: String
        /// The whole transcript, brackets removed (code-mode instructions).
        var spokenWords: String
        var speaks: Bool
    }

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        pickCard.onChoose = { [weak self] rowIndex in self?.choosePickRow(rowIndex, how: "click") }
        pickCard.onCancel = { [weak self] in self?.cancelPick(how: "click") }
    }

    // MARK: - Entry

    /// True when this turn is answered here (no brain turn): an answer to a
    /// pending offer or pick card, or a named-project request.
    func handleSpokenTranscript(_ transcript: String, speaks: Bool) -> Bool {
        let now = Date()
        if let pendingPick {
            if now.timeIntervalSince(pendingPick.createdAt) <= NamedProjectOffer.lifetime {
                switch ProjectPickReply.parse(transcript, rows: pendingPick.rows, preselectedIndex: pendingPick.preselectedIndex) {
                case .choose(let rowIndex):
                    choosePickRow(rowIndex, how: "voice")
                    return true
                case .cancel:
                    cancelPick(how: "voice")
                    return true
                case .notAReply:
                    break
                }
            }
            note("pick card dropped (another request)")
            self.pendingPick = nil
            pickCard.hide()
        }
        if let offer = pendingOffer {
            pendingOffer = nil
            switch NamedProjectOffer.resolve(offer, transcript: transcript, now: now) {
            case .accept(let acceptedOffer):
                note("offer accepted for \(acceptedOffer.projectName)")
                putMessageIntoClaude(acceptedOffer, speaks: speaks)
                return true
            case .decline:
                note("offer declined")
                say(NamedProjectSpeech.declineLine, speaks: speaks)
                return true
            case .notAnAnswer:
                note("offer dropped (expired or another request)")
            }
        }

        guard let match = NamedProjectTrigger.match(transcript: transcript) else { return false }
        let spokenWords = ProjectSendTrigger.cleanedTaskText(ProjectSendTrigger.withoutBracketedText(transcript))
        note("named project \"\(match.projectName)\" from \"\(match.destinationPhrase)\"")
        guard !match.taskText.isEmpty else {
            say(NamedProjectSpeech.askForTaskLine(projectName: match.projectName), speaks: speaks)
            return true
        }
        let request = NamedRequest(projectName: match.projectName, taskText: match.taskText, spokenWords: spokenWords, speaks: speaks)
        resolutionTask?.cancel()
        resolutionTask = Task { [weak self] in await self?.resolve(request) }
        return true
    }

    // MARK: - Finding the project

    private func resolve(_ request: NamedRequest) async {
        let candidates = await projectCandidates()
        guard !Task.isCancelled else { return }
        let decision = ProjectDestinationMatcher.decide(spokenName: request.projectName, requestText: request.spokenWords,
                                                        candidates: candidates, aliases: ClickySettings.projectAliases)
        note("\(candidates.count) candidate folders → \(Self.describe(decision))")
        switch decision {
        case .alias(let candidate):
            proceed(with: candidate, request: request, savesAliasAs: nil)
        case .confident(let scored):
            proceed(with: scored.candidate, request: request, savesAliasAs: nil)
        case .pick(let rows, let preselectedIndex):
            let rowCandidates = rows.map(\.candidate)
            pendingPick = PendingPick(spokenName: request.projectName, rows: rowCandidates, preselectedIndex: preselectedIndex,
                                      request: request, createdAt: Date())
            pickCard.show(title: "Which \u{201C}\(request.projectName)\u{201D}?", rows: rowCandidates, preselectedIndex: preselectedIndex)
            let spokenNames = ([rowCandidates[preselectedIndex]] + rowCandidates.enumerated().filter { $0.offset != preselectedIndex }.map(\.element))
                .map(\.folderName)
            say(NamedProjectSpeech.whichProjectLine(Array(spokenNames.prefix(2))), speaks: request.speaks)
        case .noMatch:
            offerClaudeApp(for: request, prefix: nil)
        }
    }

    private func choosePickRow(_ rowIndex: Int, how: String) {
        guard let pick = pendingPick, pick.rows.indices.contains(rowIndex) else { return }
        pendingPick = nil
        pickCard.hide()
        let chosen = pick.rows[rowIndex]
        note("picked \(chosen.path) by \(how)")
        proceed(with: chosen, request: pick.request, savesAliasAs: pick.spokenName)
    }

    private func cancelPick(how: String) {
        guard let pick = pendingPick else { return }
        pendingPick = nil
        pickCard.hide()
        note("pick cancelled by \(how)")
        say(NamedProjectSpeech.declineLine, speaks: pick.request.speaks)
    }

    /// Repos (with remotes) and decoded session folders, cached for a few minutes.
    private func projectCandidates() async -> [ProjectFolderCandidate] {
        if let cachedCandidates, Date().timeIntervalSince(cachedCandidates.date) < Self.candidateCacheSeconds {
            return cachedCandidates.candidates
        }
        let localRepos = await companionManager?.codeModeController.localRepositoriesForProjectLookup() ?? []
        let repositories = localRepos.map { entry in
            ProjectFolderCandidate(path: entry.folderPath, isGitRepository: true, remoteURL: entry.originURL ?? entry.upstreamURL, source: .localRepository)
        }
        let claudeProjects = await Task.detached(priority: .userInitiated) { Self.decodedClaudeProjectFolders() }.value
        let merged = ProjectFolderCandidate.merged(repositories: repositories, claudeProjects: claudeProjects)
        cachedCandidates = (Date(), merged)
        return merged
    }

    /// ~/.claude/projects directory NAMES → existing folders under the home
    /// folder (not ~/Library, not hidden, not Clicky's own checkouts).
    nonisolated static func decodedClaudeProjectFolders() -> [ProjectFolderCandidate] {
        let fileManager = FileManager.default
        let homeDirectory = NSHomeDirectory()
        let projectsDirectory = (homeDirectory as NSString).appendingPathComponent(".claude/projects")
        guard let directoryNames = try? fileManager.contentsOfDirectory(atPath: projectsDirectory) else { return [] }
        var folders: [ProjectFolderCandidate] = []
        for directoryName in directoryNames.sorted() where ClaudeProjectDirectory.isCandidateName(directoryName, homeDirectory: homeDirectory) {
            let decodedPath = ClaudeProjectDirectory.decodedPath(fromDirectoryName: directoryName) { path in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            guard let decodedPath, decodedPath != homeDirectory, !CodeRepoDenylist.isDeniedLocalRoot(decodedPath) else { continue }
            let isGitRepository = fileManager.fileExists(atPath: (decodedPath as NSString).appendingPathComponent(".git"))
            folders.append(ProjectFolderCandidate(path: decodedPath, isGitRepository: isGitRepository, source: .claudeProject))
        }
        return folders
    }

    /// The newest session file NAME in the repo's ~/.claude/projects folder
    /// (by modification date; never opened).
    nonisolated static func newestOwnerSessionIdentifier(forRepositoryPath repositoryPath: String) -> String? {
        let sessionsDirectory = ((NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects") as NSString)
            .appendingPathComponent(ClaudeProjectDirectory.encodedName(forPath: repositoryPath))
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory) else { return nil }
        let entries: [(name: String, modificationDate: Date)] = fileNames.compactMap { fileName in
            guard fileName.hasSuffix(".jsonl"),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: (sessionsDirectory as NSString).appendingPathComponent(fileName)),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modificationDate = attributes[.modificationDate] as? Date else { return nil }
            return (fileName, modificationDate)
        }
        return ClaudeProjectDirectory.newestSessionIdentifier(in: entries)
    }

    // MARK: - A match: code mode in that repo

    private func proceed(with candidate: ProjectFolderCandidate, request: NamedRequest, savesAliasAs spokenName: String?) {
        guard candidate.isGitRepository else {
            note("\(candidate.path) isn't a git repo: offering the Claude app instead")
            offerClaudeApp(for: request, prefix: NamedProjectSpeech.notAGitRepositoryLine(folderName: candidate.folderName))
            return
        }
        if let spokenName {
            ClickySettings.saveProjectAlias(spokenName: spokenName, path: candidate.path)
            note("saved alias \"\(ProjectAliasBook.key(forSpokenName: spokenName))\" → \(candidate.path)")
        }
        guard let companionManager else { return }
        let sessionIdentifier = Self.newestOwnerSessionIdentifier(forRepositoryPath: candidate.path)
        note(sessionIdentifier.map { "\(candidate.folderName): forking the owner's newest session \($0)" } ?? "\(candidate.folderName): no Claude Code session there, starting fresh")
        let screenshotURLs = Self.recentScreenshotURL().map { [$0] } ?? []
        if let screenshotURL = screenshotURLs.first { note("attaching \(screenshotURL.path)") }
        companionManager.codeModeController.startNamedProjectTask(
            rootPath: candidate.path, displayName: candidate.folderName, instructions: request.spokenWords, transcript: request.spokenWords,
            launchOptions: CodeTaskLaunchOptions(attachmentFileURLs: screenshotURLs, ownerSessionIdentifier: sessionIdentifier))
    }

    /// SnapshotCapture's last PNG, when it was taken in the last few minutes.
    static func recentScreenshotURL(now: Date = Date()) -> URL? {
        guard let screenshotURL = SnapshotCapture.lastSavedPNGURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: screenshotURL.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modificationDate) <= screenshotFreshnessSeconds else { return nil }
        return screenshotURL
    }

    // MARK: - No match: the Claude app

    private func offerClaudeApp(for request: NamedRequest, prefix: String?) {
        pendingOffer = NamedProjectOffer(projectName: request.projectName, taskText: request.taskText, createdAt: Date())
        let offerLine = NamedProjectSpeech.offerLine(projectName: request.projectName)
        say(prefix.map { $0 + " " + offerLine } ?? offerLine, speaks: request.speaks)
    }

    /// The owner said yes. Which path is reliable was checked READ-ONLY on
    /// 2026-10-25 with the debug `axfind` walk of com.anthropic.claudefordesktop
    /// (no AXManualAccessibility / AXEnhancedUserInterface written by that check):
    ///   - the tree was there (1723 nodes): AXWebArea, an AXGroup "Sidebar",
    ///     AXButton "Projects Beta", and the sidebar's chats as AXButtons
    ///     ("MAHAJAN MOTORS WORK", "Sunday and Mahajans redesign"), plus two
    ///     AXTextArea "Prompt" fields (two panes open);
    ///   - but it is only there because Clicky's own EnhancedUserInterface
    ///     controller turns AXEnhancedUserInterface + AXManualAccessibility on
    ///     for any frontmost Electron app (the "electron" entry of
    ///     v2.grounding.enhancedUIBundleIDs), so it can't be shown to appear
    ///     without writing attributes;
    ///   - the sidebar rows are chats, not projects (the projects list is a
    ///     separate page behind "Projects Beta"), so "the project named X" has
    ///     no stable row to press;
    ///   - with two "Prompt" areas the target box is ambiguous, and setting
    ///     AXValue on Electron's text area doesn't fire the page's input
    ///     events, so the send button may not see the text.
    /// Not reliable → the fallback: clipboard + bring Claude forward, and he
    /// opens the project and pastes. Nothing is typed, pasted or sent here.
    private func putMessageIntoClaude(_ offer: NamedProjectOffer, speaks: Bool) {
        let screenshotPath = Self.recentScreenshotURL()?.path
        let clipboardText = NamedProjectSpeech.clipboardText(taskText: offer.taskText, screenshotPath: screenshotPath)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clipboardText, forType: .string)
        note("copied \(clipboardText.count) characters\(screenshotPath.map { " (with \($0))" } ?? "")")
        if let claudeApplication = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundleIdentifier).first {
            claudeApplication.activate()
            say(NamedProjectSpeech.pasteFallbackLine(projectName: offer.projectName), speaks: speaks)
        } else if let claudeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.claudeBundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: claudeURL, configuration: configuration) { _, _ in }
            say(NamedProjectSpeech.pasteFallbackLine(projectName: offer.projectName), speaks: speaks)
        } else {
            say(NamedProjectSpeech.claudeNotRunningLine, speaks: speaks)
        }
    }

    // MARK: - Helpers

    private func say(_ line: String, speaks: Bool) {
        note("said: \(line)")
        if speaks { companionManager?.speakCodeModeLine(line) }
    }

    private func note(_ line: String) {
        print("📮 Named project: \(line)")
        recentEvents.append(line)
        if recentEvents.count > 30 { recentEvents.removeFirst(recentEvents.count - 30) }
    }

    static func describe(_ decision: ProjectDestinationDecision) -> String {
        switch decision {
        case .alias(let candidate): return "alias \(candidate.path)"
        case .confident(let scored): return "confident \(scored.candidate.path) (\(String(format: "%.2f", scored.score)))"
        case .pick(let rows, let preselectedIndex):
            return "pick " + rows.enumerated().map { "\($0.offset == preselectedIndex ? "*" : "")\($0.element.candidate.folderName) \(String(format: "%.2f", $0.element.score))" }
                .joined(separator: ", ")
        case .noMatch: return "no match"
        }
    }

    /// For the debug `projectStatus` command.
    func statusSnapshot() -> [String: Any] {
        [
            "pendingOffer": pendingOffer.map { ["project": $0.projectName, "task": $0.taskText] as [String: Any] } ?? NSNull(),
            "pendingPick": pendingPick.map { pick in
                ["project": pick.spokenName, "rows": pick.rows.map(\.path), "preselected": pick.preselectedIndex] as [String: Any]
            } ?? NSNull(),
            "aliases": ClickySettings.projectAliases,
            "events": recentEvents
        ]
    }
}

// MARK: - The pick card

/// Never key, never main: a click picks a row without taking focus.
final class ProjectPickCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click reach a row in the never-key panel.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ProjectPickCardModel: ObservableObject {
    @Published var title = ""
    @Published var rows: [ProjectFolderCandidate] = []
    @Published var preselectedIndex = 0
}

@MainActor
final class ProjectPickCardController {
    var onChoose: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}
    /// Clicks this soon after the card appears are ignored (one already on its way).
    static let minimumSecondsBeforeClick: TimeInterval = 0.5
    static let lifetimeSeconds: TimeInterval = NamedProjectOffer.lifetime

    private let model = ProjectPickCardModel()
    private var panel: ProjectPickCardPanel?
    private var shownAt: TimeInterval = 0
    private var hideTask: Task<Void, Never>?

    func show(title: String, rows: [ProjectFolderCandidate], preselectedIndex: Int) {
        model.title = title
        model.rows = rows
        model.preselectedIndex = preselectedIndex
        let panel = panel ?? makePanel()
        self.panel = panel
        let size = NSSize(width: 380, height: CGFloat(78 + rows.count * 44))
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screenFrame.maxX - size.width - 16, y: screenFrame.maxY - size.height - 16, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        shownAt = ProcessInfo.processInfo.systemUptime
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lifetimeSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    /// A real, not-too-early mouse click (Clicky's own synthetic events never count).
    private func isAcceptableClick() -> Bool {
        guard ProcessInfo.processInfo.systemUptime - shownAt >= Self.minimumSecondsBeforeClick else { return false }
        if let cgEvent = NSApp.currentEvent?.cgEvent, SyntheticEventTag.isTagged(userData: cgEvent.getIntegerValueField(.eventSourceUserData)) { return false }
        return true
    }

    private func makePanel() -> ProjectPickCardPanel {
        let panel = ProjectPickCardPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200), styleMask: [.nonactivatingPanel, .borderless],
                                         backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        let cardView = ProjectPickCardView(model: model, onChoose: { [weak self] rowIndex in
            guard let self, self.isAcceptableClick() else { return }
            self.onChoose(rowIndex)
        }, onCancel: { [weak self] in
            guard let self, self.isAcceptableClick() else { return }
            self.onCancel()
        })
        panel.contentView = FirstMouseHostingView(rootView: cardView)
        return panel
    }
}

private struct ProjectPickCardView: View {
    @ObservedObject var model: ProjectPickCardModel
    let onChoose: (Int) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
            Text("Click one, or say \u{201C}the first one\u{201D} or its name.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            ForEach(Array(model.rows.enumerated()), id: \.offset) { rowIndex, row in
                Button(action: { onChoose(rowIndex) }) {
                    HStack(spacing: 8) {
                        Image(systemName: row.isGitRepository ? "folder.badge.gearshape" : "folder")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.folderName).font(.system(size: 12, weight: .medium))
                            Text(Self.detail(for: row)).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 6).fill(rowIndex == model.preselectedIndex ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffectBackground())
    }

    static func detail(for row: ProjectFolderCandidate) -> String {
        let path = (row.path as NSString).abbreviatingWithTildeInPath
        if !row.isGitRepository { return "\(path) · not a git repo" }
        if let remote = row.remoteURL.flatMap(GitHubRemote.parse) { return "\(path) · \(remote.fullName)" }
        return "\(path) · no remote"
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
