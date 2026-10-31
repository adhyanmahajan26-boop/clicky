//
//  VoiceCommandController.swift
//  leanring-buddy
//
//  P8 local fast path, the flow: CompanionManager hands every owner
//  transcript here before a Claude turn.
//   - handleEarlyTranscript: a pending confirm ("Lock the screen?" → "yes")
//     and dictation mode ("type what I say" … "stop typing": each line is
//     typed into the focused field, never a secure field or a terminal).
//   - handleFastPathTranscript: VoiceFastPathParser → facts (read-only) →
//     VoiceFastPathPolicy (the ActionTierClassifier tiers; the explicit
//     command counts as its own confirm except lock / unsaved close) →
//     VoiceFastPathExecutor. Anything not parsed, or not found on this Mac
//     ("open dark mode"), goes on to Claude as a normal turn.
//  Every fast-path action is a small .actionTask record on the Agents
//  dashboard, speaks a 1–3 word acknowledgement and shows briefly in the
//  notch ("Volume 40").
//

import AppKit
import ClickyCore
import Combine
import Foundation

@MainActor
final class VoiceCommandController: ObservableObject {
    /// The notch's short note after an action ("Volume 40"), cleared after a few seconds.
    @Published private(set) var notchStatusText: String?
    @Published private(set) var isDictating = false

    private unowned let companionManager: CompanionManager
    private lazy var executor = VoiceFastPathExecutor(companionManager: companionManager)
    private let confirmCard = ActionConfirmCardController()
    private var notchClearTask: Task<Void, Never>?

    private struct PendingConfirmation {
        let command: VoiceFastPathCommand
        let transcript: String
        let agentID: String
        let speaks: Bool
        let shownDate: Date
    }
    private var pendingConfirmation: PendingConfirmation?
    static let confirmationLifetimeSeconds: TimeInterval = 20
    static let dictationIdleSeconds: TimeInterval = 30

    private(set) var recentEvents: [String] = []
    private(set) var executedCount = 0
    private(set) var dictatedLineCount = 0

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        confirmCard.onConfirm = { [weak self] in self?.resolvePendingConfirmation(approved: true, how: "click") }
        confirmCard.onCancel = { [weak self] in self?.resolvePendingConfirmation(approved: false, how: "click") }
    }

    // MARK: - Early: confirm replies and dictation

    /// True when the transcript was a reply to a pending confirm or a dictated line.
    func handleEarlyTranscript(_ transcript: String, speaks: Bool) -> Bool {
        if let pendingConfirmation {
            if Date().timeIntervalSince(pendingConfirmation.shownDate) > Self.confirmationLifetimeSeconds {
                resolvePendingConfirmation(approved: false, how: "timed out")
            } else {
                switch ActionConfirmReply.parse(transcript) {
                case .yes:
                    resolvePendingConfirmation(approved: true, how: "spoken yes")
                    return true
                case .no:
                    resolvePendingConfirmation(approved: false, how: "spoken no")
                    return true
                case .notAReply:
                    // Anything else: the confirm is dropped and the words are a new request.
                    resolvePendingConfirmation(approved: false, how: "another request")
                }
            }
        }
        guard isDictating else { return false }
        if VoiceFastPathParser.parse(transcript) == .stopDictation || WakeFollowUpEndPhrase.isEndPhrase(transcript) {
            stopDictation(speaks: speaks, reason: "stopped by voice")
            return true
        }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        Task { [weak self] in
            guard let self else { return }
            if let refusal = await self.executor.typeDictatedText(text) {
                self.note("dictation: not typed — \(refusal)")
                if speaks { self.companionManager.speakCodeModeLine("Can't type there.") }
                self.flashNotch("can't type there")
            } else {
                self.dictatedLineCount += 1
                self.note("dictation: typed \(text.count) characters")
                self.flashNotch("typed")
            }
            // Keep listening for the next line without the wake word.
            self.companionManager.wakeWordController.keepFollowUpOpen(forSeconds: Self.dictationIdleSeconds)
        }
        return true
    }

    private func startDictation(speaks: Bool) {
        isDictating = true
        note("dictation on")
        companionManager.wakeWordController.keepFollowUpOpen(forSeconds: Self.dictationIdleSeconds)
    }

    func stopDictation(speaks: Bool, reason: String) {
        guard isDictating else { return }
        isDictating = false
        note("dictation off (\(reason))")
        if speaks { companionManager.speakCodeModeLine(VoiceFastPathCommand.stopDictation.acknowledgement()) }
        flashNotch("stopped typing")
    }

    // MARK: - Fast path

    /// True when the transcript is a fast-path command (done here, or handed to Claude later if this
    /// Mac has nothing by that name). `onFinished` is called once, here or by the Claude turn.
    func handleFastPathTranscript(_ transcript: String, speaks: Bool, fallBackToClaude: @escaping () -> Void,
                                  onFinished: @escaping () -> Void) -> Bool {
        guard ClickySettings.isVoiceFastPathEnabled, let command = VoiceFastPathParser.parse(transcript) else { return false }
        if command == .stopDictation && !isDictating { return false }
        let startDate = Date()
        let facts = executor.readFacts(for: command)
        let decision = VoiceFastPathPolicy.decide(command, facts: facts, transcript: transcript)
        let agentID = companionManager.agentsCenter.begin(kind: .actionTask, title: "voice: \(Self.describe(command))", model: nil)
        companionManager.agentsCenter.log(agentID, "heard: \(transcript)")
        companionManager.agentsCenter.log(agentID, "fast path \(command.actionName) — \(decision.tierName): \(Self.reason(of: decision))")

        switch decision {
        case .refuse(let reason):
            finishRecord(agentID, status: .failed, line: "refused: \(reason)")
            note("refused \(command.actionName): \(reason)")
            if speaks { companionManager.speakCodeModeLine("Can't do that here.") }
            flashNotch("can't do that")
            onFinished()
            return true

        case .confirm(let prompt, _):
            pendingConfirmation = PendingConfirmation(command: command, transcript: transcript, agentID: agentID, speaks: speaks, shownDate: Date())
            confirmCard.show(title: prompt, detail: "Say \u{201C}yes\u{201D} or click Confirm.")
            companionManager.agentsCenter.update(agentID) { $0.currentStep = "waiting for your yes" }
            note("confirm \(command.actionName)")
            if speaks { companionManager.speakCodeModeLine(prompt) }
            // The reply comes without the wake word (the follow-up window after a wake turn, or push-to-talk).
            companionManager.wakeWordController.keepFollowUpOpen(forSeconds: Self.confirmationLifetimeSeconds)
            onFinished()
            return true

        case .execute:
            if command == .startDictation {
                startDictation(speaks: speaks)
                finishRecord(agentID, status: .done, line: "dictation on")
                if speaks { companionManager.speakCodeModeLine(command.acknowledgement()) }
                flashNotch("typing what you say")
                onFinished()
                return true
            }
            if command == .stopDictation {
                stopDictation(speaks: speaks, reason: "stopped by voice")
                finishRecord(agentID, status: .done, line: "dictation off")
                onFinished()
                return true
            }
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.executor.perform(command, transcript: transcript)
                self.finish(command: command, outcome: outcome, agentID: agentID, speaks: speaks, startDate: startDate,
                            fallBackToClaude: fallBackToClaude, onFinished: onFinished)
            }
            return true
        }
    }

    private func finish(command: VoiceFastPathCommand, outcome: VoiceFastPathOutcome, agentID: String, speaks: Bool, startDate: Date,
                        fallBackToClaude: () -> Void, onFinished: () -> Void) {
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startDate) * 1000)
        switch outcome {
        case .done(let detail, let acknowledgement):
            executedCount += 1
            finishRecord(agentID, status: .done, line: "\(detail) (\(elapsedMilliseconds) ms)")
            note("\(command.actionName): \(detail) in \(elapsedMilliseconds) ms")
            if speaks, !acknowledgement.isEmpty { companionManager.speakCodeModeLine(acknowledgement) }
            flashNotch(acknowledgement.isEmpty ? Self.describe(command) : acknowledgement.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            onFinished()
        case .notHandled(let reason):
            finishRecord(agentID, status: .cancelled, line: "not on this Mac (\(reason)); asking Claude")
            note("\(command.actionName): \(reason) → Claude")
            fallBackToClaude()
        case .failed(let reason, let spokenLine):
            finishRecord(agentID, status: .failed, line: reason)
            note("\(command.actionName) failed: \(reason)")
            if speaks { companionManager.speakCodeModeLine(spokenLine) }
            flashNotch("couldn't do that")
            onFinished()
        }
    }

    private func resolvePendingConfirmation(approved: Bool, how: String) {
        guard let pendingConfirmation else { return }
        self.pendingConfirmation = nil
        confirmCard.hide()
        companionManager.agentsCenter.log(pendingConfirmation.agentID, approved ? "confirmed by \(how)" : "declined (\(how))")
        guard approved else {
            finishRecord(pendingConfirmation.agentID, status: .cancelled, line: "not confirmed (\(how))")
            note("\(pendingConfirmation.command.actionName) not confirmed (\(how))")
            if how == "spoken no" || how == "click", pendingConfirmation.speaks { companionManager.speakCodeModeLine("Okay.") }
            return
        }
        let command = pendingConfirmation.command
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.executor.perform(command, transcript: pendingConfirmation.transcript)
            self.finish(command: command, outcome: outcome, agentID: pendingConfirmation.agentID, speaks: pendingConfirmation.speaks,
                        startDate: Date(), fallBackToClaude: {}, onFinished: {})
        }
    }

    private func finishRecord(_ agentID: String, status: AgentStatus, line: String) {
        companionManager.agentsCenter.update(agentID) { record in
            record.actionSteps = [line]
            record.currentStep = nil
        }
        companionManager.agentsCenter.log(agentID, line)
        companionManager.agentsCenter.finish(agentID, status: status)
    }

    // MARK: - Notch and log

    func flashNotch(_ text: String) {
        notchStatusText = text
        notchClearTask?.cancel()
        notchClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notchStatusText = nil
        }
    }

    private func note(_ line: String) {
        print("⚡️ Fast path: \(line)")
        recentEvents.append("\(Self.timeFormatter.string(from: Date())) \(line)")
        if recentEvents.count > 30 { recentEvents.removeFirst(recentEvents.count - 30) }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func describe(_ command: VoiceFastPathCommand) -> String {
        let parameterText = command.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return parameterText.isEmpty ? command.actionName : "\(command.actionName) \(parameterText)"
    }

    static func reason(of decision: VoiceFastPathDecision) -> String {
        switch decision {
        case .execute(let reason), .refuse(let reason): return reason
        case .confirm(_, let reason): return reason
        }
    }

    /// {action, parameters…} for the debug inbox.
    static func parsedDictionary(_ command: VoiceFastPathCommand) -> [String: Any] {
        var dictionary: [String: Any] = ["action": command.actionName]
        for (key, value) in command.parameters { dictionary[key] = value }
        return dictionary
    }

    // MARK: - Debug inbox

    /// `voiceCommand {text, dryRun}`: {parsed: {action, …} | null, decision, reason, facts, executed, outcome}.
    /// dryRun (the default) only parses and decides; nothing is pressed, moved or spoken.
    func debugRun(text: String, isDryRun: Bool) async -> [String: Any] {
        guard let command = VoiceFastPathParser.parse(text) else {
            return ["text": text, "parsed": NSNull(), "executed": false, "goesToClaude": true, "dryRun": isDryRun]
        }
        let facts = executor.readFacts(for: command)
        let decision = VoiceFastPathPolicy.decide(command, facts: facts, transcript: text)
        var result: [String: Any] = [
            "text": text,
            "parsed": Self.parsedDictionary(command),
            "decision": decision.tierName,
            "reason": Self.reason(of: decision),
            "dryRun": isDryRun,
            "facts": [
                "app": facts.frontmost?.applicationName ?? NSNull(),
                "bundle": facts.frontmost?.bundleIdentifier ?? NSNull(),
                "unsavedChanges": facts.frontWindowHasUnsavedChanges,
                "netflixOrSafariLikelyPlaying": facts.isNetflixOrSafariLikelyPlaying
            ] as [String: Any],
            "fastPathEnabled": ClickySettings.isVoiceFastPathEnabled
        ]
        guard !isDryRun, case .execute = decision, command != .startDictation, command != .stopDictation else {
            result["executed"] = false
            return result
        }
        let startDate = Date()
        let outcome = await executor.perform(command, transcript: text)
        result["elapsedMs"] = Int(Date().timeIntervalSince(startDate) * 1000)
        switch outcome {
        case .done(let detail, let acknowledgement):
            result["executed"] = true
            result["outcome"] = detail
            result["acknowledgement"] = acknowledgement
        case .notHandled(let reason):
            result["executed"] = false
            result["outcome"] = "not handled: \(reason)"
            result["goesToClaude"] = true
        case .failed(let reason, _):
            result["executed"] = false
            result["outcome"] = "failed: \(reason)"
        }
        return result
    }

    func statusSnapshot() -> [String: Any] {
        [
            "enabled": ClickySettings.isVoiceFastPathEnabled,
            "dictating": isDictating,
            "pendingConfirmation": pendingConfirmation.map { $0.command.actionName } ?? NSNull(),
            "executed": executedCount,
            "dictatedLines": dictatedLineCount,
            "recentEvents": recentEvents
        ]
    }
}
