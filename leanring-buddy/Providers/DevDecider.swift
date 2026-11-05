//
//  DevDecider.swift
//  leanring-buddy
//
//  Asks the engine set for each crew decision (Settings › Bots › Crew decisions): Off leaves today's path alone, Sonnet
//  asks `claude -p`, Prism and Wity answer with probabilities. A fast engine that isn't sure, fails, or is asked about a
//  bot with a thin card hands the decision to Sonnet. Every decision goes in ~/Library/Logs/Theo/decisions.jsonl with
//  its engine, options, answer, confidence and time. No keys, and the task only by its title.
//

import ClickyCore
import Foundation

enum DevDecider {
    static func engine(for kind: DevDecisionKind) -> DeciderEngine {
        DeciderEngine(rawValue: UserDefaults.standard.string(forKey: kind.settingKey) ?? "") ?? .off
    }

    static func set(_ engine: DeciderEngine, for kind: DevDecisionKind) {
        UserDefaults.standard.set(engine.rawValue, forKey: kind.settingKey)
    }

    static var anyOn: Bool { DevDecisionKind.allCases.contains { engine(for: $0) != .off } }

    /// "harness model effort" for each tier, e.g. "claude claude-haiku-5-5 low". Model and effort are optional. Empty means the usual coding target.
    static let lightRunnerKey = "v4.decider.tier.light"
    static let strongRunnerKey = "v4.decider.tier.strong"

    static func runner(for tier: DevTier) -> (harness: String, model: String?, effort: String?)? {
        let text = UserDefaults.standard.string(forKey: tier == .light ? lightRunnerKey : strongRunnerKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: " ").map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil, parts.count > 2 ? parts[2] : nil)
    }

    /// Who decided, what, and the log line for it. Nil verdict: no engine is on for this decision, or nothing answered, so today's path stands.
    struct Decision {
        var verdict: DevVerdict?
        var decidedBy: DeciderEngine
        var logs: [DevDecisionLog]
        var totalMs: Int { logs.reduce(0) { $0 + $1.ms } }
    }

    static func decide(_ kind: DevDecisionKind, task: String, question: FastDecisionQuestion,
                       verdict: @escaping ([String: PrismAnswer]?, DeciderEngine) -> DevVerdict?) async -> Decision {
        let chosen = engine(for: kind)
        guard chosen != .off else { return Decision(verdict: nil, decidedBy: .off, logs: []) }
        let options = question.question.criteria.keys.sorted()
        var logs: [DevDecisionLog] = []
        var fastNote: String?
        if chosen.isFast {
            if chosen.isWity, DevDecisions.optionCount(question) > DevDecisionPolicy.wityOptionsAtMost {
                fastNote = "over \(DevDecisionPolicy.wityOptionsAtMost) options"
            } else {
                let started = Date()
                var answers: [String: PrismAnswer]?
                var problem: String?
                do { answers = try await askFast(question, engine: chosen) } catch { problem = error.localizedDescription }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let got = verdict(answers, chosen)
                let stands = got?.stands == true
                logs.append(DevDecisionLog(kind: kind.rawValue, engine: chosen.rawValue, model: chosen == .prism ? PrismWire.model : "wity-1", task: String(task.prefix(80)),
                                           options: options, answer: got?.option ?? "none", confidence: got?.confidence, ms: ms,
                                           handedTo: stands ? nil : DeciderEngine.sonnet.rawValue, note: problem.map { String($0.prefix(120)) }))
                if stands {
                    record(logs)
                    return Decision(verdict: got, decidedBy: chosen, logs: logs)
                }
            }
        }
        // Sonnet decides: it was chosen, or the fast engine handed over.
        let started = Date()
        let reply = await askSonnet(question)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        var got = verdict(reply.flatMap { DevDecisions.sonnetAnswers($0, question: question) }, .sonnet)
        if got != nil { got?.stands = true }
        logs.append(DevDecisionLog(kind: kind.rawValue, engine: chosen.rawValue, model: "sonnet", task: String(task.prefix(80)), options: options,
                                   answer: got?.option ?? "none", confidence: got?.confidence, ms: ms, handedTo: nil,
                                   note: fastNote ?? (reply == nil ? "no answer from Sonnet" : nil)))
        record(logs)
        return Decision(verdict: got, decidedBy: .sonnet, logs: logs)
    }

    // MARK: Engines

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func askFast(_ question: FastDecisionQuestion, engine: DeciderEngine) async throws -> [String: PrismAnswer] {
        if engine == .prism { return try await PrismClient.ask(question, timeout: 6).all }
        return try await WityClient.ask(question, thinking: engine == .wityThinking, timeout: engine == .wityThinking ? 20 : 6)
    }

    /// One short Sonnet call with no tools, the way Theo's other quick checks ask it.
    static func askSonnet(_ question: FastDecisionQuestion) async -> String? {
        guard let claude = ClaudeCodeBridge.locateClaudeCodeExecutable() else { return nil }
        return try? await BotsT3.shell(claude, ["-p", "--model", "sonnet", "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"],
                                       stdin: DevDecisions.sonnetPrompt(question), limit: 60)
    }

    // MARK: The log

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recent: [DevDecisionLog] = []

    static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Theo/decisions.jsonl")
    }

    static func record(_ lines: [DevDecisionLog]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        lock.lock()
        recent.append(contentsOf: lines)
        if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        lock.unlock()
        let folder = logFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var text = ""
        for line in lines { if let data = try? encoder.encode(line) { text += String(decoding: data, as: UTF8.self) + "\n" } }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }

    static var recentLines: [DevDecisionLog] { lock.lock(); defer { lock.unlock() }; return recent }
}

/// Wity's fixed-choice API, which takes Prism's questions. The key is "wity" in Settings › Models & API keys.
enum WityClient {
    static let base = URL(string: "https://api.wity.alphanimble.com/v1/systemone")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    static var hasKey: Bool { key() != nil }

    /// A test profile may read a throwaway key from a file of its own (`test.wity.keyFile`), so no Keychain item is written for a test.
    static func key() -> String? {
        if TheoProfile.isTest, let path = UserDefaults.standard.string(forKey: "test.wity.keyFile"),
           let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ProviderKeychain.get("wity")
    }

    static func ask(_ question: FastDecisionQuestion, thinking: Bool, timeout: TimeInterval) async throws -> [String: PrismAnswer] {
        guard let key = await Task.detached(priority: .userInitiated, operation: { key() }).value else { throw DevDecider.Failure(message: "No Wity key") }
        var request = URLRequest(url: base, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = DevDecisions.wityBody(question, thinking: thinking)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DevDecider.Failure(message: "Wity \(status)") }
        guard let answers = PrismWire.answers(from: data) else { throw DevDecider.Failure(message: "No answer in Wity's reply") }
        return answers
    }

    /// Opens the connection ahead of time, like Prism's warm-up.
    static func warm() {
        Task.detached(priority: .utility) {
            let question = FastDecisionQuestion(state: "ok", question: PrismQuestion(kind: .noul, instructions: "Is this a word?", criteria: ["true": "Yes.", "false": "No."]))
            _ = try? await ask(question, thinking: false, timeout: 10)
        }
    }
}
