//
//  NotchContent.swift
//  ClickyCore
//
//  What the notch pill shows, decided from the app's existing state: the
//  companion phase (CompanionManager's voice state), the AgentStore the
//  Agents dashboard already uses, the caption bubble's CaptionState and the
//  Code mode switch. Nothing is stored here; the app rebuilds a NotchContent
//  whenever one of those changes (and once a second while expanded, for the
//  elapsed times).
//

import Foundation

/// The companion's own state, from CompanionManager's voice state.
public enum NotchCompanionPhase: String, Equatable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
}

/// One agent line in the expanded panel.
public struct NotchAgentRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: AgentKind
    public let title: String
    public let status: AgentStatus
    /// "Running", "Queued", a brain phase ("Speaking") or a finished status.
    public let statusText: String
    public let model: String?
    public let elapsedText: String
    public let costText: String?
    public let isCancellable: Bool
    public let canOpenReview: Bool

    public init(id: String, kind: AgentKind, title: String, status: AgentStatus, statusText: String, model: String?, elapsedText: String,
                costText: String?, isCancellable: Bool, canOpenReview: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.statusText = statusText
        self.model = model
        self.elapsedText = elapsedText
        self.costText = costText
        self.isCancellable = isCancellable
        self.canOpenReview = canOpenReview
    }

    /// "Running · sonnet · 0:42 · $0.03".
    public var detailText: String {
        [statusText, model, elapsedText, costText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public struct NotchContent: Equatable, Sendable {
    public var phase: NotchCompanionPhase
    /// The collapsed pill's short status ("" shows the logo alone).
    public var statusText: String
    /// Running helper agents drawn as minis orbiting the logo (at most 4).
    public var orbitingAgentIDs: [String]
    public var agentRows: [NotchAgentRow]
    /// Agents not listed (they're in the Agents window).
    public var hiddenAgentCount: Int
    /// True when the rows are recent finished agents (nothing is running).
    public var agentRowsAreRecent: Bool
    public var captionText: String?
    public var isCodeModeOn: Bool
    public var selectedAgentID: String?
    /// The agent Cancel acts on: the selected one if it can be cancelled,
    /// else the first running one that can.
    public var cancelTargetID: String?
    /// The code task whose review panel "Open review" shows.
    public var reviewTargetID: String?

    public init(phase: NotchCompanionPhase = .idle, statusText: String = "", orbitingAgentIDs: [String] = [], agentRows: [NotchAgentRow] = [],
                hiddenAgentCount: Int = 0, agentRowsAreRecent: Bool = false, captionText: String? = nil, isCodeModeOn: Bool = false,
                selectedAgentID: String? = nil, cancelTargetID: String? = nil, reviewTargetID: String? = nil) {
        self.phase = phase
        self.statusText = statusText
        self.orbitingAgentIDs = orbitingAgentIDs
        self.agentRows = agentRows
        self.hiddenAgentCount = hiddenAgentCount
        self.agentRowsAreRecent = agentRowsAreRecent
        self.captionText = captionText
        self.isCodeModeOn = isCodeModeOn
        self.selectedAgentID = selectedAgentID
        self.cancelTargetID = cancelTargetID
        self.reviewTargetID = reviewTargetID
    }

    /// True while the logo should move (spin, pulse or carry orbiting minis);
    /// an idle pill with nothing running stays still and costs nothing.
    public var isLogoAnimating: Bool { phase != .idle || !orbitingAgentIDs.isEmpty }
}

public enum NotchStatus {
    /// Longest repository name in "coding: …" before it is cut.
    static let maximumCodingNameLength = 22

    /// The collapsed status line. The companion's own phase wins (you're
    /// talking to it); otherwise the helper agents: one code task is
    /// "coding: <repo>", several agents "N agents", one helper "1 agent".
    /// Idle with nothing running is "" (just the logo).
    public static func statusText(phase: NotchCompanionPhase, activeHelperAgents: [AgentRecord]) -> String {
        switch phase {
        case .listening: return "listening…"
        case .thinking: return "thinking…"
        case .speaking: return "speaking"
        case .idle: break
        }
        switch activeHelperAgents.count {
        case 0:
            return ""
        case 1:
            let onlyAgent = activeHelperAgents[0]
            if onlyAgent.kind == .codeTask { return "coding: \(codingName(onlyAgent))" }
            return "1 agent"
        default:
            return "\(activeHelperAgents.count) agents"
        }
    }

    /// "octo/clicky-scratch" → "clicky-scratch"; else the worktree folder; else the title.
    static func codingName(_ record: AgentRecord) -> String {
        let candidates = [record.repository.map { ($0 as NSString).lastPathComponent },
                          record.worktreePath.map { ($0 as NSString).lastPathComponent },
                          record.title]
        let name = candidates.compactMap { $0 }.first { !$0.isEmpty } ?? "code"
        return name.count > maximumCodingNameLength ? String(name.prefix(maximumCodingNameLength - 1)) + "…" : name
    }

    /// The companion phase from the app's voice state flags.
    public static func phase(isListening: Bool, isProcessing: Bool, isResponding: Bool, isCoordinatorThinking: Bool) -> NotchCompanionPhase {
        if isListening { return .listening }
        if isProcessing { return .thinking }
        if isResponding { return .speaking }
        return isCoordinatorThinking ? .thinking : .idle
    }

    /// The words the caption bubble is showing right now: the revealed part
    /// of the current segment, or the "Give me a second…" status. Nil while
    /// the bubble is hidden.
    public static func captionText(_ caption: CaptionState) -> String? {
        guard caption.isVisible else { return nil }
        if let currentSegment = caption.current {
            let revealedCount = caption.revealedDisplayCharacters
            let text = revealedCount > 0 && revealedCount < currentSegment.display.count
                ? String(currentSegment.display.prefix(revealedCount))
                : currentSegment.display
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty { return trimmedText }
        }
        let status = caption.statusText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return status.isEmpty ? nil : status
    }

    /// Builds everything the pill shows from the existing state.
    /// `canCancel` / `canOpenReview` are the dashboard's own checks.
    public static func content(phase: NotchCompanionPhase, store: AgentStore, captionText: String?, isCodeModeOn: Bool, selectedAgentID: String?,
                               now: Date, canCancel: (AgentRecord) -> Bool, canOpenReview: (AgentRecord) -> Bool) -> NotchContent {
        let runningRecords = store.runningRecords
        let activeHelperAgents = runningRecords.filter { $0.kind != .brain }
        let orbitingAgentIDs = Array(activeHelperAgents.filter { $0.status == .running }.prefix(NotchGeometry.maximumAgentRows).map(\.id))

        let agentRowsAreRecent = runningRecords.isEmpty
        let listedRecords = agentRowsAreRecent ? Array(store.recentRecords.prefix(3)) : runningRecords
        let rows = listedRecords.prefix(NotchGeometry.maximumAgentRows).map { record in
            NotchAgentRow(id: record.id, kind: record.kind, title: record.title, status: record.status, statusText: rowStatusText(record),
                          model: record.usage?.model.map(shortModelName) ?? record.model, elapsedText: AgentRecord.elapsedText(seconds: record.elapsedSeconds(now: now)),
                          costText: record.usage?.costText, isCancellable: canCancel(record), canOpenReview: canOpenReview(record))
        }
        let hiddenAgentCount = agentRowsAreRecent ? 0 : max(0, runningRecords.count - rows.count)

        let selectedRow = rows.first { $0.id == selectedAgentID }
        let cancelTargetID = (selectedRow?.isCancellable == true ? selectedRow?.id : nil) ?? rows.first(where: \.isCancellable)?.id
        let reviewTargetID = (selectedRow?.canOpenReview == true ? selectedRow?.id : nil) ?? rows.first(where: \.canOpenReview)?.id

        return NotchContent(phase: phase, statusText: statusText(phase: phase, activeHelperAgents: activeHelperAgents), orbitingAgentIDs: orbitingAgentIDs,
                            agentRows: Array(rows), hiddenAgentCount: hiddenAgentCount, agentRowsAreRecent: agentRowsAreRecent, captionText: captionText,
                            isCodeModeOn: isCodeModeOn, selectedAgentID: selectedRow?.id, cancelTargetID: cancelTargetID, reviewTargetID: reviewTargetID)
    }

    /// The brain shows its phase ("Speaking"); code tasks their step; others their status.
    static func rowStatusText(_ record: AgentRecord) -> String {
        if record.kind == .brain, record.status.isActive, let phase = record.phase, !phase.isEmpty {
            return phase.prefix(1).uppercased() + phase.dropFirst()
        }
        if record.kind == .codeTask, record.status == .running, let currentStep = record.currentStep, !currentStep.isEmpty {
            return currentStep
        }
        return record.status.displayName
    }

    /// "claude-sonnet-4-5-20250929" → "sonnet-4-5"; aliases stay as they are.
    static func shortModelName(_ model: String) -> String {
        var name = model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
        if let dateRange = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(dateRange) }
        return name
    }
}
