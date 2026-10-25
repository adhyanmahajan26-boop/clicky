//
//  AgentsCenter.swift
//  leanring-buddy
//
//  The app side of the Agents dashboard: owns ClickyCore's AgentStore,
//  takes updates from the adapters (the main brain turn in
//  CompanionManager, helper / board-section workers and the board repair in
//  AnswerSession, Code-mode tasks in CodeModeController), keeps each
//  running agent's cancel path (the existing ones: barge-in, the worker's
//  task, CodeModeController's stop), and saves the history to
//  ~/Library/Application Support/Clicky/agents-history.json, debounced and
//  off the main actor. Updates only change published state; nothing here
//  opens, orders or focuses a window.
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class AgentsCenter: ObservableObject {
    @Published private(set) var store: AgentStore

    /// Cancel paths for running agents (removed when the agent ends).
    private var cancelHandlers: [String: () -> Void] = [:]
    private let historyFileURL: URL?
    private var pendingSaveTask: Task<Void, Never>?
    private static let saveDelayNanoseconds: UInt64 = 1_000_000_000

    nonisolated static var defaultHistoryFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clicky", isDirectory: true)
            .appendingPathComponent("agents-history.json")
    }

    /// `historyFileURL` nil keeps everything in memory (unit tests).
    init(historyFileURL: URL? = AgentsCenter.defaultHistoryFileURL) {
        self.historyFileURL = historyFileURL
        let historyLimit = ClickySettings.agentsHistoryLimit
        if let historyFileURL, let savedData = try? Data(contentsOf: historyFileURL) {
            do {
                store = try AgentStore.decoded(from: savedData, maximumFinishedRecords: historyLimit)
            } catch {
                print("⚠️ Agents: couldn't read \(historyFileURL.path): \(error)")
                store = AgentStore(maximumFinishedRecords: historyLimit)
            }
        } else {
            store = AgentStore(maximumFinishedRecords: historyLimit)
        }
    }

    // MARK: - Adapter API

    /// Adds a running (or queued) agent and returns its id.
    @discardableResult
    func begin(kind: AgentKind, title: String, model: String?, parentID: String? = nil, status: AgentStatus = .running, phase: String? = nil) -> String {
        let record = AgentRecord(kind: kind, title: Self.cleanTitle(title), model: model, status: status, phase: phase, startedAt: Date(), parentID: parentID)
        store.upsert(record)
        scheduleSave()
        return record.id
    }

    func log(_ agentID: String?, _ text: String) {
        guard let agentID else { return }
        if store.appendLog(agentID, text) { scheduleSave() }
    }

    func update(_ agentID: String?, _ change: (inout AgentRecord) -> Void) {
        guard let agentID else { return }
        if store.update(agentID, change) { scheduleSave() }
    }

    func setBrainPhase(_ agentID: String?, _ phase: BrainPhase) {
        update(agentID) { record in
            guard record.status.isActive, record.phase != phase.rawValue else { return }
            record.phase = phase.rawValue
        }
    }

    func addUsage(_ agentID: String?, _ usage: AgentUsage?) {
        guard let agentID, let usage else { return }
        if store.addUsage(agentID, usage) { scheduleSave() }
    }

    func finish(_ agentID: String?, status: AgentStatus, usage: AgentUsage? = nil, errorDescription: String? = nil) {
        guard let agentID else { return }
        cancelHandlers[agentID] = nil
        if store.finish(agentID, status: status, usage: usage, errorDescription: errorDescription) { scheduleSave() }
    }

    func remove(_ agentID: String?) {
        guard let agentID else { return }
        cancelHandlers[agentID] = nil
        if store.remove(agentID) { scheduleSave() }
    }

    func setCancelHandler(_ agentID: String?, _ cancelHandler: @escaping () -> Void) {
        guard let agentID else { return }
        cancelHandlers[agentID] = cancelHandler
    }

    func record(_ agentID: String?) -> AgentRecord? {
        agentID.flatMap { store[$0] }
    }

    // MARK: - Dashboard actions

    func canCancel(_ record: AgentRecord) -> Bool {
        record.status.isActive && cancelHandlers[record.id] != nil
    }

    /// Runs the agent's own cancel path; the agent's adapter records the end.
    /// If the path didn't end it (nothing was really running any more), it's
    /// marked cancelled here.
    func cancel(_ record: AgentRecord) {
        guard let cancelHandler = cancelHandlers[record.id] else { return }
        print("🤖 Agents: cancel \(record.kind.rawValue) \"\(record.title.prefix(60))\"")
        log(record.id, "Cancel pressed in the Agents window.")
        cancelHandler()
        if store[record.id]?.status.isActive == true && record.kind != .brain {
            finish(record.id, status: .cancelled)
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard historyFileURL != nil else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the history off the main actor. `waitsForWrite` (Clicky is
    /// quitting) writes it right here instead, so it's on disk before exit.
    func saveNow(waitsForWrite: Bool = false) {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        guard let historyFileURL else { return }
        let encodedData: Data
        do {
            encodedData = try store.encoded()
        } catch {
            print("⚠️ Agents: couldn't encode the history: \(error)")
            return
        }
        // One serial queue, so an older write can never land after a newer one.
        if waitsForWrite {
            Self.historyWriteQueue.sync { Self.write(encodedData, to: historyFileURL) }
        } else {
            Self.historyWriteQueue.async { Self.write(encodedData, to: historyFileURL) }
        }
    }

    private static let historyWriteQueue = DispatchQueue(label: "local.clicky.agents-history", qos: .utility)

    nonisolated private static func write(_ encodedData: Data, to historyFileURL: URL) {
        do {
            try FileManager.default.createDirectory(at: historyFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encodedData.write(to: historyFileURL, options: .atomic)
        } catch {
            print("⚠️ Agents: couldn't save \(historyFileURL.path): \(error)")
        }
    }

    /// One line, at most 120 characters ("compare these three laptops for me").
    static func cleanTitle(_ title: String) -> String {
        let oneLine = title.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !oneLine.isEmpty else { return "Untitled" }
        return oneLine.count > 120 ? String(oneLine.prefix(119)) + "…" : oneLine
    }
}
