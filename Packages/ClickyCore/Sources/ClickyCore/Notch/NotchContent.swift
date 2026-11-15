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

/// Which lane a bot's line sits in on the notch, most urgent first. Green is working, yellow needs you, red only ever failed.
public enum NotchBotLane: Int, CaseIterable, Comparable, Sendable {
    case needsYou, failed, working, done

    public static func < (lhs: NotchBotLane, rhs: NotchBotLane) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The lane for a PixelState name ("needs", "failed", "working", "thinking", "done"); nil for a bot with nothing to report.
    public static func lane(forPixelState state: String) -> NotchBotLane? {
        switch state {
        case "needs": return .needsYou
        case "failed": return .failed
        case "working", "thinking": return .working
        case "done": return .done
        default: return nil
        }
    }

    /// The colour of the lane's dot, chip and words: the Pixel faces' own colours.
    public var hex: UInt32 {
        switch self {
        case .needsYou: return 0xFFD938
        case .failed: return 0xFF4A5E
        case .working: return 0x22D391
        case .done: return 0xF4F4F5
        }
    }

    /// "need you", "failed", "working": the word after a count.
    public var countWord: String {
        switch self {
        case .needsYou: return "need you"
        case .failed: return "failed"
        case .working: return "working"
        case .done: return "done"
        }
    }
}

/// One bot on the notch: "Researcher · Sign in to Notion · [Sign in]", "Builder · Running the tests · 4m".
public struct NotchBotLine: Identifiable, Equatable, Sendable {
    public var botID: String
    public var name: String
    /// A PixelState name, for the face.
    public var state: String
    public var lane: NotchBotLane
    /// What it's doing, or what it needs, in one line.
    public var line: String
    /// The one button ("Sign in", "Answer", "Fix", "Open"); nil shows the time instead.
    public var button: String?
    /// How long it has been in this state ("4m", "1:42"), when known.
    public var sinceText: String?

    public var id: String { botID }

    /// "Researcher needs you", "Builder failed", "Builder is working", "Builder is done".
    public var title: String {
        switch lane {
        case .needsYou: return "\(name) needs you"
        case .failed: return "\(name) failed"
        case .working: return "\(name) is working"
        case .done: return "\(name) is done"
        }
    }

    public init(botID: String, name: String, state: String, lane: NotchBotLane, line: String, button: String? = nil, sinceText: String? = nil) {
        self.botID = botID
        self.name = name
        self.state = state
        self.lane = lane
        self.line = line
        self.button = button
        self.sinceText = sinceText
    }
}

/// How many bots are in each lane, for the chips that are always on the pill.
public struct NotchBotTally: Equatable, Sendable {
    public var needsYou: Int
    public var failed: Int
    public var working: Int

    public init(needsYou: Int = 0, failed: Int = 0, working: Int = 0) {
        self.needsYou = needsYou
        self.failed = failed
        self.working = working
    }

    public var isEmpty: Bool { needsYou == 0 && failed == 0 && working == 0 }

    /// The chips in the order they're drawn (needs you, failed, working), only the ones above zero.
    public var chips: [NotchBotChip] {
        [NotchBotChip(lane: .needsYou, count: needsYou), NotchBotChip(lane: .failed, count: failed), NotchBotChip(lane: .working, count: working)]
            .filter { $0.count > 0 }
    }

    /// "1 needs you, 2 failed, 3 working" for VoiceOver and tooltips.
    public var spokenText: String {
        chips.map { chip in chip.lane == .needsYou && chip.count == 1 ? "1 needs you" : "\(chip.count) \(chip.lane.countWord)" }.joined(separator: ", ")
    }

    /// A chip's number: up to 9, then "9+" so the chip keeps its width.
    public static func countText(_ count: Int) -> String { count > 9 ? "9+" : "\(count)" }
}

/// One count chip on the pill: a dot in the lane's colour and the number.
public struct NotchBotChip: Identifiable, Equatable, Sendable {
    public var lane: NotchBotLane
    public var count: Int
    public var id: Int { lane.rawValue }

    public init(lane: NotchBotLane, count: Int) {
        self.lane = lane
        self.count = count
    }
}

/// The bot board: every bot that needs the owner, failed, is working or just finished, sorted and cut to what fits.
public enum NotchBots {
    /// Rows in the expanded panel; the rest are counted in a "+N more" line.
    public static let maximumRows = 4

    public struct Board: Equatable, Sendable {
        public var lines: [NotchBotLine]
        public var hiddenCount: Int
        public var tally: NotchBotTally

        public init(lines: [NotchBotLine] = [], hiddenCount: Int = 0, tally: NotchBotTally = NotchBotTally()) {
            self.lines = lines
            self.hiddenCount = hiddenCount
            self.tally = tally
        }
    }

    /// Needs you first, then failed, then working, then done (each lane keeps the order it was given in).
    /// Done bots only fill rows nothing more urgent wants, and are never counted in the tally.
    public static func board(from lines: [NotchBotLine], maximumRows: Int = maximumRows) -> Board {
        let sorted = lines.enumerated().sorted { first, second in
            first.element.lane == second.element.lane ? first.offset < second.offset : first.element.lane < second.element.lane
        }.map(\.element)
        let tally = NotchBotTally(needsYou: sorted.filter { $0.lane == .needsYou }.count,
                                  failed: sorted.filter { $0.lane == .failed }.count,
                                  working: sorted.filter { $0.lane == .working }.count)
        let shown = Array(sorted.prefix(maximumRows))
        let hiddenUrgentOrWorking = sorted.dropFirst(maximumRows).filter { $0.lane != .done }.count
        return Board(lines: shown, hiddenCount: hiddenUrgentOrWorking, tally: tally)
    }

    /// The collapsed pill's words when the companion itself is quiet: the most urgent bot by name
    /// ("Researcher needs you"), else who's working ("Builder is working", "3 bots working"). "" when nothing is going on.
    public static func collapsedStatus(board: Board) -> String {
        if let first = board.lines.first, first.lane == .needsYou || first.lane == .failed { return first.title }
        switch board.tally.working {
        case 0: return ""
        case 1: return board.lines.first { $0.lane == .working }?.title ?? "1 bot working"
        default: return "\(board.tally.working) bots working"
        }
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
    /// P7: the wake word's small mic dot on the collapsed logo.
    public var wakeIndicator: NotchWakeIndicator
    /// P7: the running action task's newest step lines (at most NotchGeometry.maximumActionStepLines).
    public var actionStepLines: [String]
    /// The bots that need the owner, failed, are working or just finished (at most NotchBots.maximumRows).
    public var botLines: [NotchBotLine]
    /// Bots not listed that still need the owner, failed or are working (they're on Home).
    public var hiddenBotCount: Int
    /// How many bots are in each lane: the chips that are always on the pill.
    public var botTally: NotchBotTally

    public init(phase: NotchCompanionPhase = .idle, statusText: String = "", orbitingAgentIDs: [String] = [], agentRows: [NotchAgentRow] = [],
                hiddenAgentCount: Int = 0, agentRowsAreRecent: Bool = false, captionText: String? = nil, isCodeModeOn: Bool = false,
                selectedAgentID: String? = nil, cancelTargetID: String? = nil, reviewTargetID: String? = nil,
                wakeIndicator: NotchWakeIndicator = .hidden, actionStepLines: [String] = [], botBoard: NotchBots.Board = NotchBots.Board()) {
        self.botLines = botBoard.lines
        self.hiddenBotCount = botBoard.hiddenCount
        self.botTally = botBoard.tally
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
        self.wakeIndicator = wakeIndicator
        self.actionStepLines = actionStepLines
    }

    /// True while the logo should move (spin, pulse or carry orbiting minis);
    /// an idle pill with nothing running stays still and costs nothing.
    public var isLogoAnimating: Bool { phase != .idle || !orbitingAgentIDs.isEmpty }

    /// Puts the bot board on the pill. With the companion quiet and no helper status of its own,
    /// the collapsed words name the most urgent bot, so a glance says who needs you.
    public mutating func apply(botBoard: NotchBots.Board) {
        botLines = botBoard.lines
        hiddenBotCount = botBoard.hiddenCount
        botTally = botBoard.tally
        if phase == .idle, statusText.isEmpty { statusText = NotchBots.collapsedStatus(board: botBoard) }
    }
}

public enum NotchStatus {
    /// Longest repository name in "coding: …" before it is cut.
    static let maximumCodingNameLength = 22

    /// The collapsed status line. The companion's own phase wins (you're
    /// talking to it); otherwise the helper agents: one code task is
    /// "coding: <repo>", several agents "N agents", one helper "1 agent".
    /// Idle with nothing running is "" (just the logo). A project task's
    /// short-lived note ("sent to project") wins over the helper count while
    /// idle; waiting project tasks themselves run outside Clicky and don't count.
    public static func statusText(phase: NotchCompanionPhase, activeHelperAgents: [AgentRecord], projectStatusText: String? = nil) -> String {
        switch phase {
        case .listening: return "listening…"
        case .thinking: return "thinking…"
        case .speaking: return "speaking"
        case .idle: break
        }
        if let projectStatusText, !projectStatusText.isEmpty { return projectStatusText }
        let activeHelperAgents = activeHelperAgents.filter { $0.kind != .projectTask }
        switch activeHelperAgents.count {
        case 0:
            return ""
        case 1:
            let onlyAgent = activeHelperAgents[0]
            if onlyAgent.kind == .codeTask { return "coding: \(codingName(onlyAgent))" }
            if onlyAgent.kind == .actionTask { return "doing: \(codingName(onlyAgent))" }
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
    /// `projectStatusText`: the few-seconds "sent to project" / "project: done" note.
    public static func content(phase: NotchCompanionPhase, store: AgentStore, captionText: String?, isCodeModeOn: Bool, selectedAgentID: String?,
                               now: Date, projectStatusText: String? = nil, wakeIndicator: NotchWakeIndicator = .hidden,
                               canCancel: (AgentRecord) -> Bool, canOpenReview: (AgentRecord) -> Bool) -> NotchContent {
        let runningRecords = store.runningRecords
        let activeHelperAgents = runningRecords.filter { $0.kind != .brain }
        // Project tasks run in another session: listed, but not drawn as Clicky's own orbiting helpers.
        let orbitingAgentIDs = Array(activeHelperAgents.filter { $0.status == .running && $0.kind != .projectTask }.prefix(NotchGeometry.maximumAgentRows).map(\.id))

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

        return NotchContent(phase: phase, statusText: statusText(phase: phase, activeHelperAgents: activeHelperAgents, projectStatusText: projectStatusText), orbitingAgentIDs: orbitingAgentIDs,
                            agentRows: Array(rows), hiddenAgentCount: hiddenAgentCount, agentRowsAreRecent: agentRowsAreRecent, captionText: captionText,
                            isCodeModeOn: isCodeModeOn, selectedAgentID: selectedRow?.id, cancelTargetID: cancelTargetID, reviewTargetID: reviewTargetID,
                            wakeIndicator: wakeIndicator,
                            actionStepLines: actionStepLines(store: store))
    }

    /// The live step list of the running action task (newest last), else none.
    static func actionStepLines(store: AgentStore) -> [String] {
        guard let actionRecord = store.runningRecords.first(where: { $0.kind == .actionTask }) else { return [] }
        var lines = actionRecord.actionSteps ?? []
        if let currentStep = actionRecord.currentStep, !currentStep.isEmpty { lines.append("▸ " + currentStep) }
        return Array(lines.suffix(NotchGeometry.maximumActionStepLines))
    }

    /// The brain shows its phase ("Speaking"); code tasks their step; others their status.
    static func rowStatusText(_ record: AgentRecord) -> String {
        if record.kind == .brain, record.status.isActive, let phase = record.phase, !phase.isEmpty {
            return phase.prefix(1).uppercased() + phase.dropFirst()
        }
        if record.kind == .codeTask || record.kind == .actionTask, record.status == .running, let currentStep = record.currentStep, !currentStep.isEmpty {
            return currentStep
        }
        if record.kind == .projectTask, let phaseDisplayText = record.phaseDisplayText {
            return phaseDisplayText
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
