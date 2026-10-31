//
//  CodeReviewContent.swift
//  ClickyCore
//
//  What the review panel shows for one task, as plain data: the header
//  (owner/name #N @old→new), CI status, the diff, every body and the commit
//  message verbatim (editable; edits rewrite the outbox file and so change
//  the ApprovalKey), each button's commands quoted, and the guard findings
//  with their ack toggles. `approveBlockers` lists why the buttons are
//  disabled: the agent group isn't reaped, processes still run under the
//  worktree/ctx, `git push --dry-run` failed, or a red finding isn't acked.
//

import Foundation

public struct CodeReviewContent: Equatable, Sendable {
    public struct EditableText: Equatable, Sendable, Identifiable {
        /// The outbox file name (also the id).
        public var fileName: String
        public var label: String
        public var text: String
        public var id: String { fileName }

        public init(fileName: String, label: String, text: String) {
            self.fileName = fileName
            self.label = label
            self.text = text
        }
    }

    public struct ActionButton: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var gatedAction: GatedAction
        public var commands: [OutwardCommand]
        public var isPrimary: Bool
        /// Local-only buttons (keep branch, dismiss) skip the outward checks.
        public var isOutward: Bool

        public init(id: String, title: String, gatedAction: GatedAction, commands: [OutwardCommand], isPrimary: Bool = false, isOutward: Bool = true) {
            self.id = id
            self.title = title
            self.gatedAction = gatedAction
            self.commands = commands
            self.isPrimary = isPrimary
            self.isOutward = isOutward
        }

        public var requiresHold: Bool { gatedAction.requiresHold }
    }

    public var repositoryFullName: String
    public var pullRequestNumber: Int?
    public var branch: String?
    public var oldOID: String?
    public var newOID: String?
    public var ciStatus: String?
    public var summary: String?
    public var notes: [String]
    public var diffFiles: [DiffFile]
    public var editableTexts: [EditableText]
    public var buttons: [ActionButton]
    public var findings: [CodeGuardFinding]
    public var acks: Set<String>
    public var approveBlockers: [String]
    /// A status line shown under the buttons ("Pushing…", "Done").
    public var progress: String?

    public init(repositoryFullName: String, pullRequestNumber: Int? = nil, branch: String? = nil, oldOID: String? = nil, newOID: String? = nil,
                ciStatus: String? = nil, summary: String? = nil, notes: [String] = [], diffFiles: [DiffFile] = [], editableTexts: [EditableText] = [],
                buttons: [ActionButton] = [], findings: [CodeGuardFinding] = [], acks: Set<String> = [], approveBlockers: [String] = [], progress: String? = nil) {
        self.repositoryFullName = repositoryFullName
        self.pullRequestNumber = pullRequestNumber
        self.branch = branch
        self.oldOID = oldOID
        self.newOID = newOID
        self.ciStatus = ciStatus
        self.summary = summary
        self.notes = notes
        self.diffFiles = diffFiles
        self.editableTexts = editableTexts
        self.buttons = buttons
        self.findings = findings
        self.acks = acks
        self.approveBlockers = approveBlockers
        self.progress = progress
    }

    /// "owner/name #12 @abc1234→def5678".
    public var headerText: String {
        var header = repositoryFullName
        if let pullRequestNumber { header += " #\(pullRequestNumber)" }
        if let oldOID, let newOID { header += " @\(oldOID.prefix(7))→\(newOID.prefix(7))" }
        else if let newOID { header += " @\(newOID.prefix(7))" }
        return header
    }

    public var isApproveEnabled: Bool { approveBlockers.isEmpty }
}

/// The checks that must all pass before any outward button works.
public struct ReviewApproveConditions: Equatable, Sendable {
    public var isAgentProcessGroupReaped: Bool
    /// Pids still found under the worktree/ctx after killAll.
    public var leftoverProcessIdentifiers: [Int32]
    /// nil when nothing is pushed.
    public var pushDryRunSucceeded: Bool?
    public var pushDryRunMessage: String?
    public var findings: [CodeGuardFinding]
    public var acks: Set<String>

    public init(isAgentProcessGroupReaped: Bool, leftoverProcessIdentifiers: [Int32], pushDryRunSucceeded: Bool?, pushDryRunMessage: String? = nil,
                findings: [CodeGuardFinding], acks: Set<String>) {
        self.isAgentProcessGroupReaped = isAgentProcessGroupReaped
        self.leftoverProcessIdentifiers = leftoverProcessIdentifiers
        self.pushDryRunSucceeded = pushDryRunSucceeded
        self.pushDryRunMessage = pushDryRunMessage
        self.findings = findings
        self.acks = acks
    }

    public var blockers: [String] {
        var blockers: [String] = []
        if !isAgentProcessGroupReaped { blockers.append("the agent is still running") }
        if !leftoverProcessIdentifiers.isEmpty { blockers.append("\(leftoverProcessIdentifiers.count) process(es) still run in the worktree") }
        if pushDryRunSucceeded == false { blockers.append("git push --dry-run failed\(pushDryRunMessage.map { ": \($0)" } ?? "")") }
        let unackedFindings = findings.filter { finding in
            finding.isBlocking || !(finding.ackIdentifier.map(acks.contains) ?? false)
        }
        let blockingCount = unackedFindings.filter(\.isBlocking).count
        let unackedCount = unackedFindings.count - blockingCount
        if blockingCount > 0 { blockers.append("\(blockingCount) red finding\(blockingCount == 1 ? "" : "s") can't be sent") }
        if unackedCount > 0 { blockers.append("\(unackedCount) finding\(unackedCount == 1 ? "" : "s") need\(unackedCount == 1 ? "s" : "") your ack") }
        return blockers
    }
}
