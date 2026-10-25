//
//  ReviewPanelView.swift
//  ClickyCore
//
//  The SwiftUI content of Code mode's review panel. Modes: "Opening o/n #N"
//  (2 s, Esc cancels; the repo name big and its full path below it), live progress while the agent works (current step,
//  files changed so far, elapsed time, tasks queued; Hide / Stop — neither
//  sends anything), the top-4 repo chooser, a yes/no question (e.g.
//  unpushed work before cleanup) and the review itself: header, CI status,
//  the agent's summary, guard findings with ack toggles, the diff hunks,
//  every body and the commit message verbatim and editable, each button's
//  commands quoted, and the gated buttons. Rendered offscreen in tests
//  with `usesStaticButtons` (static buttons, no scroll view or text editor:
//  ImageRenderer can't draw NSView-backed views).
//

import AppKit
import SwiftUI

/// What the "Opening …" card shows for 2 s before a task starts: the repo
/// in big type and its full path, so a wrong pick is obvious before Esc.
public struct OpeningCard: Equatable, Sendable {
    /// "owner/name", or the folder name for a local-only repo.
    public var repositoryName: String
    /// The full local path (nil when there's no clone yet).
    public var path: String?
    public var pullRequestNumber: Int?
    /// Shown as "Starting in N s"; nil hides the countdown.
    public var secondsRemaining: Int?

    public init(repositoryName: String, path: String?, pullRequestNumber: Int? = nil, secondsRemaining: Int? = nil) {
        self.repositoryName = repositoryName
        self.path = path
        self.pullRequestNumber = pullRequestNumber
        self.secondsRemaining = secondsRemaining
    }

    /// "acme/app #12".
    public var titleText: String { repositoryName + (pullRequestNumber.map { " #\($0)" } ?? "") }
    /// The full path as is (never abbreviated with ~), or a GitHub-only note.
    public var pathText: String { path.map { ($0 as NSString).standardizingPath } ?? "GitHub only (no local clone yet)" }
}

@MainActor
public final class ReviewPanelState: ObservableObject {
    public enum Mode: Equatable {
        case opening(OpeningCard)
        case chooser(title: String, candidates: [RepoCandidate])
        /// A yes/no prompt whose confirm is itself a gated button (clone, remove unpushed work).
        case question(title: String, detail: String, confirmTitle: String, gatedAction: GatedAction)
        /// The agent is working: progress only, nothing to approve.
        case working(CodeTaskProgressSnapshot)
        case review
    }

    @Published public var mode: Mode
    @Published public var content: CodeReviewContent
    /// systemUptime when the panel became visible (the gate's clock).
    public var panelShownAt: TimeInterval = 0

    public var onEditText: (String, String) -> Void = { _, _ in }
    public var onToggleAck: (String, Bool) -> Void = { _, _ in }
    public var onApprove: (CodeReviewContent.ActionButton) -> Void = { _ in }
    public var onChooseRepository: (RepoCandidate) -> Void = { _ in }
    public var onConfirmQuestion: () -> Void = {}
    public var onCancel: () -> Void = {}
    /// "Stop" on the progress card: cancels the running task (nothing is sent).
    public var onStopTask: () -> Void = {}
    /// The live NSViews of the gated buttons (for Return / voice arming).
    public private(set) var buttonViews: [String: GatedActionButtonView] = [:]

    public init(mode: Mode = .review, content: CodeReviewContent) {
        self.mode = mode
        self.content = content
    }

    func register(buttonID: String, view: GatedActionButtonView) {
        buttonViews[buttonID] = view
    }

    public var primaryButtonView: GatedActionButtonView? {
        let primaryID = content.buttons.first(where: \.isPrimary)?.id ?? content.buttons.first?.id
        return primaryID.flatMap { buttonViews[$0] }
    }
}

public struct ReviewPanelView: View {
    @ObservedObject var state: ReviewPanelState
    var usesStaticButtons: Bool
    static let maximumDiffLinesShown = 1500

    public init(state: ReviewPanelState, usesStaticButtons: Bool = false) {
        self.state = state
        self.usesStaticButtons = usesStaticButtons
    }

    public var body: some View {
        Group {
            switch state.mode {
            case .opening(let card):
                openingCard(card)
            case .chooser(let title, let candidates):
                compactCard(title: title, detail: "Which repo did you mean?") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                            Button { state.onChooseRepository(candidate) } label: {
                                HStack {
                                    Text(candidate.fullName).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(candidate.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "GitHub only")
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        Button("Cancel") { state.onCancel() }.keyboardShortcut(.cancelAction)
                    }
                }
            case .question(let title, let detail, let confirmTitle, let gatedAction):
                compactCard(title: title, detail: detail) {
                    HStack {
                        Button("Not now") { state.onCancel() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        actionButton(CodeReviewContent.ActionButton(id: "question-confirm", title: confirmTitle, gatedAction: gatedAction, commands: [], isPrimary: true, isOutward: false),
                                     isEnabled: true) { state.onConfirmQuestion() }
                    }
                }
            case .working(let snapshot):
                compactCard(title: snapshot.title, detail: snapshot.stepLine) {
                    VStack(alignment: .leading, spacing: 6) {
                        if snapshot.changedFiles.isEmpty {
                            Text("No files changed yet.").font(.system(size: 11)).foregroundColor(.secondary)
                        } else {
                            Text("Changed so far (\(snapshot.changedFiles.count))").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                            ForEach(Array(snapshot.changedFiles.suffix(6).enumerated()), id: \.offset) { _, filePath in
                                Text(filePath).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if snapshot.queuedCount > 0 {
                            Text("\(snapshot.queuedCount) more task\(snapshot.queuedCount == 1 ? "" : "s") queued after this one.").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Text("Edits stay in a separate worktree. Nothing is sent until you review it.").font(.system(size: 10.5)).foregroundColor(.secondary)
                        HStack {
                            Button("Hide") { state.onCancel() }.keyboardShortcut(.cancelAction)
                            Spacer()
                            Button("Stop") { state.onStopTask() }
                        }
                    }
                }
            case .review:
                reviewBody
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Review

    private var content: CodeReviewContent { state.content }

    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)
            Divider()
            scrollContainer {
                VStack(alignment: .leading, spacing: 14) {
                    if let summary = content.summary, !summary.isEmpty {
                        section("Summary") { Text(summary).font(.system(size: 13)).textSelection(.enabled) }
                    }
                    ForEach(content.notes, id: \.self) { note in
                        Text(note).font(.system(size: 12)).foregroundColor(.secondary).textSelection(.enabled)
                    }
                    if !content.findings.isEmpty { findingsSection }
                    if !content.diffFiles.isEmpty { diffSection }
                    ForEach(content.editableTexts) { editableText in
                        EditableOutboxTextView(editableText: editableText, isSnapshot: usesStaticButtons) { newText in state.onEditText(editableText.fileName, newText) }
                    }
                    if !content.buttons.isEmpty { commandsSection }
                }
                .padding(14)
            }
            Divider()
            footer
                .padding(14)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(content.headerText).font(.system(size: 15, weight: .bold, design: .monospaced)).textSelection(.enabled)
                if let branch = content.branch {
                    Text(branch).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            Spacer()
            if let ciStatus = content.ciStatus {
                Text("CI: \(ciStatus)")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(ciColor(ciStatus).opacity(0.18)))
                    .foregroundColor(ciColor(ciStatus))
            }
        }
    }

    private func ciColor(_ status: String) -> Color {
        if status.contains("fail") { return .red }
        if status.contains("pending") { return .orange }
        if status.contains("passed") { return .green }
        return .secondary
    }

    private var findingsSection: some View {
        section("Checks before sending") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(content.findings.enumerated()), id: \.offset) { _, finding in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: finding.isBlocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(finding.isBlocking ? .red : .orange)
                        Text(finding.message).font(.system(size: 12)).textSelection(.enabled)
                        Spacer()
                        if let ackIdentifier = finding.ackIdentifier {
                            Toggle("I've checked this", isOn: Binding(
                                get: { content.acks.contains(ackIdentifier) },
                                set: { state.onToggleAck(ackIdentifier, $0) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                        }
                    }
                }
            }
        }
    }

    private var diffSection: some View {
        section("Changes (\(content.diffFiles.count) file\(content.diffFiles.count == 1 ? "" : "s"))") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(diffFilesToShow.enumerated()), id: \.offset) { _, shown in
                    DiffFileView(file: shown.file, lineBudget: shown.lineBudget)
                }
            }
        }
    }

    /// Each file with how many lines it may still show (the total is capped).
    private var diffFilesToShow: [(file: DiffFile, lineBudget: Int)] {
        var remainingLines = Self.maximumDiffLinesShown
        return content.diffFiles.map { file in
            let budget = remainingLines
            remainingLines = max(0, remainingLines - file.hunks.reduce(0) { $0 + $1.lines.count + 1 })
            return (file, budget)
        }
    }

    private var commandsSection: some View {
        section("Exactly what each button runs") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(content.buttons) { button in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(button.title).font(.system(size: 12, weight: .semibold))
                        if button.commands.isEmpty {
                            Text("Nothing leaves this Mac.").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        ForEach(Array(button.commands.enumerated()), id: \.offset) { _, command in
                            Text(command.quoted)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !content.approveBlockers.isEmpty {
                Text("Can't send yet: " + content.approveBlockers.joined(separator: "; "))
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.red)
            }
            if let progress = content.progress {
                Text(progress).font(.system(size: 11)).foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Button("Close") { state.onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                ForEach(content.buttons) { button in
                    actionButton(button, isEnabled: !button.isOutward || content.isApproveEnabled) { state.onApprove(button) }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ button: CodeReviewContent.ActionButton, isEnabled: Bool, onApproved: @escaping () -> Void) -> some View {
        if usesStaticButtons {
            Text(button.requiresHold ? "\(button.title) (hold)" : button.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(button.isPrimary ? .white : .primary)
                .padding(.horizontal, 14).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(button.isPrimary ? Color.blue : Color.gray.opacity(0.25)))
                .opacity(isEnabled ? 1 : 0.45)
        } else {
            GatedActionButton(button: button, isEnabled: isEnabled, panelShownAtProvider: { [weak state] in state?.panelShownAt ?? .infinity },
                              onApproved: onApproved, onViewCreated: { [weak state] buttonID, view in state?.register(buttonID: buttonID, view: view) })
                .frame(width: max(130, CGFloat(button.title.count) * 8 + (button.requiresHold ? 60 : 34)), height: 30)
        }
    }

    // MARK: - Pieces

    /// A ScrollView on screen; a plain stack offscreen (ImageRenderer can't draw NSScrollView).
    @ViewBuilder
    private func scrollContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if usesStaticButtons {
            content().frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content() }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            content()
        }
    }

    /// The repo name big and the full path clearly readable, then the countdown and Cancel.
    private func openingCard(_ card: OpeningCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OPENING").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Text(card.titleText)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.pathText)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.14)))
            HStack {
                Text(card.secondsRemaining.map { "Starting in \($0) s. Press Esc to cancel." } ?? "Press Esc to cancel.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { state.onCancel() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 540, alignment: .leading)
    }

    private func compactCard<Actions: View>(title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .bold))
            Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
            actions()
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
    }
}

/// One editable body (commit message, reply, PR body, comment).
struct EditableOutboxTextView: View {
    let editableText: CodeReviewContent.EditableText
    let isSnapshot: Bool
    let onChange: (String) -> Void
    @State private var draft: String

    init(editableText: CodeReviewContent.EditableText, isSnapshot: Bool = false, onChange: @escaping (String) -> Void) {
        self.editableText = editableText
        self.isSnapshot = isSnapshot
        self.onChange = onChange
        _draft = State(initialValue: editableText.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editableText.label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            Group {
                if isSnapshot {
                    Text(draft).frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading).padding(4)
                } else {
                    TextEditor(text: $draft)
                        .frame(minHeight: 60, maxHeight: 160)
                        .onChange(of: draft) { _, newValue in onChange(newValue) }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.35)))
        }
    }
}

/// One file of the diff: path line, then hunks with +/- colouring.
struct DiffFileView: View {
    let file: DiffFile
    let lineBudget: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pathLine)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.15))
            if file.isBinary {
                Text("binary file").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).padding(6)
            }
            ForEach(Array(shownLines.enumerated()), id: \.offset) { _, shownLine in
                Text(shownLine.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(shownLine.color == .clear ? .primary : shownLine.color)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(shownLine.color == .clear ? Color.clear : shownLine.color.opacity(0.1))
            }
            if hiddenLineCount > 0 {
                Text("… \(hiddenLineCount) more line\(hiddenLineCount == 1 ? "" : "s")").font(.system(size: 11)).foregroundColor(.secondary).padding(6)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3)))
    }

    private var pathLine: String {
        var line = file.displayPath
        if file.isRename, let oldPath = file.oldPath { line = "\(oldPath) → \(file.newPath ?? "")" + (file.similarityPercent.map { " (\($0)%)" } ?? "") }
        if file.isNewFile { line += "  (new)" }
        if file.isDeletedFile { line += "  (deleted)" }
        if file.isModeChange { line += "  (mode \(file.oldMode ?? "") → \(file.newMode ?? ""))" }
        return line
    }

    private var allLines: [(text: String, color: Color)] {
        var lines: [(String, Color)] = []
        for hunk in file.hunks {
            lines.append(("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.sectionHeading)", .purple))
            for line in hunk.lines {
                switch line.kind {
                case .added: lines.append(("+" + line.text, .green))
                case .removed: lines.append(("-" + line.text, .red))
                case .context: lines.append((" " + line.text, .clear))
                }
            }
        }
        return lines
    }

    private var shownLines: [(text: String, color: Color)] { Array(allLines.prefix(max(0, lineBudget))) }
    private var hiddenLineCount: Int { max(0, allLines.count - max(0, lineBudget)) }
}
