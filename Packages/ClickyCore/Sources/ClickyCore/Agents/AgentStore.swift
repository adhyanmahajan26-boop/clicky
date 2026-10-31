//
//  AgentStore.swift
//  ClickyCore
//
//  Every agent Clicky runs, as plain data for the Agents dashboard: the
//  main brain's turn, Haiku helper workers, whiteboard section helpers and
//  the board repair call, Code-mode Claude Code tasks, and tasks handed to
//  the owner's project coordinator ("send this to my project"). The app's
//  adapters feed the store (upsert / log / finish / cancel); the store keeps
//  the last ~20 log lines per agent, trims history to the newest 50
//  finished agents (running and queued ones are never trimmed), sums usage,
//  and encodes to the JSON the app keeps in
//  ~/Library/Application Support/Clicky/agents-history.json.
//  Pure Foundation: nothing here reads the disk or touches the UI.
//

import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    /// The main answer turn (the user's push-to-talk question).
    case brain
    /// A [WORKER:…] helper on Haiku.
    case worker
    /// P6.7: a [WORKER:s<k> …] helper drawing one whiteboard section.
    case boardSection
    /// The one-shot CLI call that repairs a board too broken to draw.
    case boardRepair
    /// A Code-mode Claude Code agent (<codetask>).
    case codeTask
    /// A task handed to the owner's project coordinator ("send this to my
    /// project …"). It runs outside Clicky: phase is a ProjectTaskPhase
    /// (queued → received → threadStarted → done / failed), from the inbox replies.
    case projectTask
    /// P7: an <actions> task Clicky runs on the owner's screen (open, click,
    /// type, highlight, summarize…), step by step with an observe turn
    /// between batches. `actionSteps` holds the live step list.
    case actionTask

    public var displayName: String {
        switch self {
        case .brain: return "Main brain"
        case .worker: return "Helper"
        case .boardSection: return "Board section"
        case .boardRepair: return "Board repair"
        case .codeTask: return "Code task"
        case .projectTask: return "Project task"
        case .actionTask: return "Action task"
        }
    }

    /// SF Symbol for the sidebar row.
    public var symbolName: String {
        switch self {
        case .brain: return "brain.head.profile"
        case .worker: return "sparkles"
        case .boardSection: return "rectangle.on.rectangle"
        case .boardRepair: return "wrench.and.screwdriver"
        case .codeTask: return "chevron.left.forwardslash.chevron.right"
        case .projectTask: return "paperplane"
        case .actionTask: return "cursorarrow.click.2"
        }
    }
}

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case done
    case failed
    case cancelled

    /// Queued or running: shown under Running, never trimmed.
    public var isActive: Bool { self == .queued || self == .running }

    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// What the main brain is doing right now (its record's `phase`).
public enum BrainPhase: String, Codable, CaseIterable, Sendable {
    case listening
    case thinking
    case speaking
    case done
    case failed
    case cancelled
}

/// Tokens and cost from a stream-json (or json) `result` event.
public struct AgentUsage: Codable, Equatable, Sendable {
    /// The model the CLI said it used (system/init), else the alias asked for.
    public var model: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    /// `total_cost_usd` when the CLI reports it.
    public var costUSD: Double?

    public init(model: String? = nil, inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0, costUSD: Double? = nil) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
    }

    /// Every token counted, cache reads and writes included.
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    /// The `result` event's `usage` object and `total_cost_usd`. Nil when the
    /// event has neither (an error result without usage, a non-result event).
    public static func fromResultEvent(_ resultEvent: [String: Any], model: String?) -> AgentUsage? {
        let usageObject = resultEvent["usage"] as? [String: Any]
        let costUSD = number(resultEvent["total_cost_usd"]) ?? number(resultEvent["cost_usd"])
        guard usageObject != nil || costUSD != nil else { return nil }
        func count(_ key: String) -> Int { number(usageObject?[key]).map { Int($0) } ?? 0 }
        return AgentUsage(model: model,
                          inputTokens: count("input_tokens"),
                          outputTokens: count("output_tokens"),
                          cacheReadTokens: count("cache_read_input_tokens"),
                          cacheCreationTokens: count("cache_creation_input_tokens"),
                          costUSD: costUSD)
    }

    /// Same, from one raw stdout line or a whole `--output-format json` reply
    /// (the whole text first, then its last line that is a result event).
    public static func fromResultLine(_ lineData: Data, model: String?) -> AgentUsage? {
        func resultEvent(_ data: Data) -> [String: Any]? {
            guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], event["type"] as? String == "result" else { return nil }
            return event
        }
        if let event = resultEvent(lineData) { return fromResultEvent(event, model: model) }
        for line in lineData.split(separator: 0x0A).reversed() {
            if let event = resultEvent(Data(line)) { return fromResultEvent(event, model: model) }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !(value is Bool) { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    /// Two runs of one agent (a main answer plus its follow-up after workers).
    /// The cost is summed when either side has one; the model keeps the first.
    public static func + (lhs: AgentUsage, rhs: AgentUsage) -> AgentUsage {
        let costUSD: Double? = (lhs.costUSD == nil && rhs.costUSD == nil) ? nil : (lhs.costUSD ?? 0) + (rhs.costUSD ?? 0)
        return AgentUsage(model: lhs.model ?? rhs.model,
                          inputTokens: lhs.inputTokens + rhs.inputTokens,
                          outputTokens: lhs.outputTokens + rhs.outputTokens,
                          cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
                          cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
                          costUSD: costUSD)
    }

    /// "12.3k in · 410 out · 98k cache" (short, for the detail pane).
    public var tokenSummary: String {
        var parts = ["\(Self.compact(inputTokens)) in", "\(Self.compact(outputTokens)) out"]
        if cacheReadTokens > 0 { parts.append("\(Self.compact(cacheReadTokens)) cache read") }
        if cacheCreationTokens > 0 { parts.append("\(Self.compact(cacheCreationTokens)) cache write") }
        return parts.joined(separator: " · ")
    }

    /// "$0.0123", or nil without a cost.
    public var costText: String? {
        costUSD.map { String(format: $0 < 0.01 ? "$%.4f" : "$%.2f", $0) }
    }

    static func compact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 10_000 { return String(format: "%.0fk", Double(count) / 1_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }
}

public struct AgentLogLine: Codable, Equatable, Sendable {
    public var date: Date
    public var text: String

    public init(date: Date, text: String) {
        self.date = date
        self.text = text
    }
}

public struct AgentRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: AgentKind
    public var title: String
    /// The alias or model id the agent runs on ("haiku", "sonnet", "claude-opus-…").
    public var model: String?
    public var status: AgentStatus
    /// Kind-specific live state: a BrainPhase raw value for the brain.
    public var phase: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var usage: AgentUsage?
    public var logLines: [AgentLogLine]
    /// The brain turn a helper belongs to.
    public var parentID: String?
    public var errorDescription: String?

    // Code tasks.
    public var repository: String?
    public var clonePath: String?
    public var branch: String?
    public var worktreePath: String?
    public var currentStep: String?
    public var changedFiles: [String]
    /// Code tasks waiting behind this one when it was last updated.
    public var queuedBehindCount: Int?

    // Project tasks (the coordinator's reply; display only, never followed or opened).
    public var note: String?
    public var link: String?

    // Action tasks (P7): one display line per step ("✓ open Chrome", "▸ type “hi” in 1.5 s").
    public var actionSteps: [String]?

    public init(id: String = UUID().uuidString.lowercased(), kind: AgentKind, title: String, model: String? = nil, status: AgentStatus = .running,
                phase: String? = nil, startedAt: Date = Date(), endedAt: Date? = nil, usage: AgentUsage? = nil, logLines: [AgentLogLine] = [],
                parentID: String? = nil, errorDescription: String? = nil, repository: String? = nil, clonePath: String? = nil, branch: String? = nil,
                worktreePath: String? = nil, currentStep: String? = nil, changedFiles: [String] = [], queuedBehindCount: Int? = nil,
                note: String? = nil, link: String? = nil, actionSteps: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.model = model
        self.status = status
        self.phase = phase
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.usage = usage
        self.logLines = logLines
        self.parentID = parentID
        self.errorDescription = errorDescription
        self.repository = repository
        self.clonePath = clonePath
        self.branch = branch
        self.worktreePath = worktreePath
        self.currentStep = currentStep
        self.changedFiles = changedFiles
        self.queuedBehindCount = queuedBehindCount
        self.note = note
        self.link = link
        self.actionSteps = actionSteps
    }

    /// The phase as the status badge shows it ("Thread started", "Speaking").
    public var phaseDisplayText: String? {
        guard let phase, !phase.isEmpty else { return nil }
        if kind == .projectTask, let projectPhase = ProjectTaskPhase(rawValue: phase) { return projectPhase.displayName }
        return phase.prefix(1).uppercased() + phase.dropFirst()
    }

    /// Seconds from start to end (or to `now` while it runs).
    public func elapsedSeconds(now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// "0:42", "12:05", "1:02:03".
    public static func elapsedText(seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds) }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    /// The log as plain text (Copy log).
    public var logText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        var lines = ["\(kind.displayName): \(title)", "status: \(status.rawValue)\(phase.map { " (\($0))" } ?? "")", "model: \(model ?? "-")"]
        if let usage { lines.append("usage: \(usage.tokenSummary)\(usage.costText.map { " · \($0)" } ?? "")") }
        if let worktreePath { lines.append("worktree: \(worktreePath)\(branch.map { " (\($0))" } ?? "")") }
        if let errorDescription { lines.append("error: \(errorDescription)") }
        if let note { lines.append("note: \(note)") }
        if let link { lines.append("link: \(link)") }
        if let actionSteps, !actionSteps.isEmpty { lines.append("steps:"); lines += actionSteps.map { "  \($0)" } }
        lines.append("")
        lines += logLines.map { "\(formatter.string(from: $0.date)) \($0.text)" }
        return lines.joined(separator: "\n")
    }
}

/// Usage summed over a set of agents.
public struct AgentUsageTotals: Equatable, Sendable {
    public var agentCount: Int
    public var agentsWithUsage: Int
    public var usage: AgentUsage

    public init(agentCount: Int = 0, agentsWithUsage: Int = 0, usage: AgentUsage = AgentUsage()) {
        self.agentCount = agentCount
        self.agentsWithUsage = agentsWithUsage
        self.usage = usage
    }
}

public struct AgentStore: Codable, Equatable, Sendable {
    public static let defaultMaximumFinishedRecords = 50
    public static let maximumLogLines = 20
    /// A single log line longer than this is cut (a worker's whole reply on one line).
    public static let maximumLogLineLength = 400
    static let fileFormatVersion = 1

    /// Oldest first.
    public private(set) var records: [AgentRecord]
    public var maximumFinishedRecords: Int

    public init(records: [AgentRecord] = [], maximumFinishedRecords: Int = AgentStore.defaultMaximumFinishedRecords) {
        self.records = records
        self.maximumFinishedRecords = max(1, maximumFinishedRecords)
        trimHistory()
    }

    public subscript(id: String) -> AgentRecord? {
        records.first { $0.id == id }
    }

    // MARK: - Changes

    /// Adds the record, or replaces the one with its id (keeping its place).
    public mutating func upsert(_ record: AgentRecord) {
        var record = record
        record.logLines = Array(record.logLines.suffix(Self.maximumLogLines))
        if let existingIndex = records.firstIndex(where: { $0.id == record.id }) {
            records[existingIndex] = record
        } else {
            records.append(record)
        }
        trimHistory()
    }

    /// Changes one record in place. False when there's no such record.
    @discardableResult
    public mutating func update(_ id: String, _ change: (inout AgentRecord) -> Void) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        change(&records[index])
        records[index].logLines = Array(records[index].logLines.suffix(Self.maximumLogLines))
        return true
    }

    /// One log line per non-empty line of `text`; the newest 20 are kept.
    @discardableResult
    public mutating func appendLog(_ id: String, _ text: String, at date: Date = Date()) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.count > Self.maximumLogLineLength ? String($0.prefix(Self.maximumLogLineLength - 1)) + "…" : $0 }
        guard !lines.isEmpty else { return records.contains { $0.id == id } }
        return update(id) { record in
            record.logLines += lines.map { AgentLogLine(date: date, text: $0) }
        }
    }

    /// Ends a queued or running agent. Usage is added to what it already had
    /// (a brain turn's follow-up stream). A finished agent isn't changed again,
    /// so a late failure can't overwrite a cancel.
    @discardableResult
    public mutating func finish(_ id: String, status: AgentStatus, usage: AgentUsage? = nil, errorDescription: String? = nil, at date: Date = Date()) -> Bool {
        let didFinish = update(id) { record in
            guard record.status.isActive else { return }
            record.status = status.isActive ? .done : status
            record.endedAt = date
            if let usage { record.usage = record.usage.map { $0 + usage } ?? usage }
            if let errorDescription { record.errorDescription = errorDescription }
            if record.kind == .brain {
                switch record.status {
                case .done: record.phase = BrainPhase.done.rawValue
                case .failed: record.phase = BrainPhase.failed.rawValue
                case .cancelled: record.phase = BrainPhase.cancelled.rawValue
                case .queued, .running: break
                }
            }
        }
        trimHistory()
        return didFinish
    }

    @discardableResult
    public mutating func cancel(_ id: String, at date: Date = Date()) -> Bool {
        finish(id, status: .cancelled, at: date)
    }

    /// Adds usage to a record that may still be running (a stream that ended
    /// while the answer is still being spoken).
    @discardableResult
    public mutating func addUsage(_ id: String, _ usage: AgentUsage) -> Bool {
        update(id) { record in record.usage = record.usage.map { $0 + usage } ?? usage }
    }

    @discardableResult
    public mutating func remove(_ id: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        records.remove(at: index)
        return true
    }

    /// Agents that were still running when Clicky last quit: cancelled, with a note.
    /// Project tasks run outside Clicky and keep waiting for their reply.
    public mutating func markInterruptedAgents(at date: Date = Date()) {
        for record in records where record.status.isActive && record.kind != .projectTask {
            update(record.id) { interruptedRecord in
                interruptedRecord.logLines.append(AgentLogLine(date: date, text: "Clicky quit while this was running."))
            }
            finish(record.id, status: .cancelled, errorDescription: "Clicky quit while this was running.", at: date)
        }
    }

    /// Keeps every active record plus the newest `maximumFinishedRecords` finished ones.
    public mutating func trimHistory() {
        let finishedRecords = records.filter { !$0.status.isActive }
        let excessCount = finishedRecords.count - maximumFinishedRecords
        guard excessCount > 0 else { return }
        let oldestFinishedIDs = Set(finishedRecords
            .sorted { ($0.endedAt ?? $0.startedAt, $0.startedAt) < ($1.endedAt ?? $1.startedAt, $1.startedAt) }
            .prefix(excessCount)
            .map(\.id))
        records.removeAll { oldestFinishedIDs.contains($0.id) }
    }

    // MARK: - Project tasks

    /// How long a project task waits for its last reply before it's marked failed.
    public static let projectTaskReplyTimeout: TimeInterval = 24 * 60 * 60

    /// Applies one inbox reply to its project task. Returns the new phase
    /// when the phase moved forward (the only time Clicky announces it); a
    /// repeat, an older status, an unknown id, another kind of agent or a
    /// finished task returns nil (a repeat may still refresh the note/link).
    @discardableResult
    public mutating func applyProjectReply(_ reply: ProjectInboxReply, at date: Date = Date()) -> ProjectTaskPhase? {
        guard let record = self[reply.id], record.kind == .projectTask, record.status.isActive else { return nil }
        let currentPhase = record.phase.flatMap(ProjectTaskPhase.init(rawValue:)) ?? .queued
        let newPhase = ProjectTaskPhase(reply.status)
        guard newPhase.rank > currentPhase.rank else {
            if newPhase == currentPhase, reply.note != nil || reply.link != nil {
                update(reply.id) { sameRecord in
                    if let note = reply.note { sameRecord.note = note }
                    if let link = reply.link { sameRecord.link = link }
                }
            }
            return nil
        }
        update(reply.id) { changedRecord in
            changedRecord.phase = newPhase.rawValue
            changedRecord.currentStep = newPhase.displayName
            if let note = reply.note { changedRecord.note = note }
            if let link = reply.link { changedRecord.link = link }
            // Done / failed are set by finish() below (which also stamps the end time).
            if newPhase.agentStatus.isActive { changedRecord.status = newPhase.agentStatus }
        }
        appendLog(reply.id, "project: \(newPhase.displayName.lowercased())\(reply.note.map { " — \($0)" } ?? "")", at: date)
        if !newPhase.agentStatus.isActive {
            let failureText = newPhase == .failed ? (reply.note ?? "Your project couldn't do that.") : nil
            finish(reply.id, status: newPhase.agentStatus, errorDescription: failureText, at: date)
        }
        return newPhase
    }

    /// Project tasks still waiting a day after they were sent: failed, "no reply".
    public mutating func expireStaleProjectTasks(now: Date = Date(), timeout: TimeInterval = AgentStore.projectTaskReplyTimeout) {
        for record in records where record.kind == .projectTask && record.status.isActive && now.timeIntervalSince(record.startedAt) > timeout {
            update(record.id) { staleRecord in
                staleRecord.phase = ProjectTaskPhase.failed.rawValue
                staleRecord.currentStep = ProjectTaskPhase.failed.displayName
            }
            finish(record.id, status: .failed, errorDescription: "No reply from your project.", at: now)
        }
    }

    /// Project tasks still waiting for a reply.
    public var activeProjectTaskRecords: [AgentRecord] {
        records.filter { $0.kind == .projectTask && $0.status.isActive }
    }

    // MARK: - Views of the store

    /// Queued and running agents, the brain first, then by start.
    public var runningRecords: [AgentRecord] {
        records.filter(\.status.isActive).sorted { lhs, rhs in
            if (lhs.kind == .brain) != (rhs.kind == .brain) { return lhs.kind == .brain }
            if lhs.status != rhs.status { return lhs.status == .running }
            return lhs.startedAt < rhs.startedAt
        }
    }

    /// Finished agents, newest first.
    public var recentRecords: [AgentRecord] {
        records.filter { !$0.status.isActive }.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
    }

    /// Helpers that belong to a brain turn, by start.
    public func children(of parentID: String) -> [AgentRecord] {
        records.filter { $0.parentID == parentID }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Usage summed over the matching records.
    public func usageTotals(where isIncluded: (AgentRecord) -> Bool = { _ in true }) -> AgentUsageTotals {
        var totals = AgentUsageTotals()
        for record in records where isIncluded(record) {
            totals.agentCount += 1
            guard let usage = record.usage else { continue }
            totals.agentsWithUsage += 1
            var usageWithoutModel = usage
            usageWithoutModel.model = nil
            totals.usage = totals.usage + usageWithoutModel
        }
        return totals
    }

    /// Usage per model (records without a model are grouped under "unknown").
    public func usageTotalsByModel() -> [String: AgentUsageTotals] {
        let modelNames = Set(records.map(Self.modelName(of:)))
        var totalsByModel: [String: AgentUsageTotals] = [:]
        for modelName in modelNames {
            totalsByModel[modelName] = usageTotals { Self.modelName(of: $0) == modelName }
        }
        return totalsByModel
    }

    private static func modelName(of record: AgentRecord) -> String {
        record.usage?.model ?? record.model ?? "unknown"
    }

    // MARK: - Persistence

    private struct FileContents: Codable {
        var version: Int
        var records: [AgentRecord]
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(FileContents(version: Self.fileFormatVersion, records: records))
    }

    /// The saved history. Agents saved while running come back cancelled.
    public static func decoded(from data: Data, maximumFinishedRecords: Int = AgentStore.defaultMaximumFinishedRecords, now: Date = Date()) throws -> AgentStore {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = try decoder.decode(FileContents.self, from: data)
        var store = AgentStore(records: contents.records, maximumFinishedRecords: maximumFinishedRecords)
        store.markInterruptedAgents(at: now)
        store.expireStaleProjectTasks(now: now)
        return store
    }

    private enum CodingKeys: String, CodingKey {
        case records, maximumFinishedRecords
    }
}
