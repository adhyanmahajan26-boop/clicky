//
//  PrismClient.swift
//  leanring-buddy
//
//  Asks Sarvam Prism one fixed-choice question with the owner's Sarvam key, and gives up quickly. Every caller treats
//  nil the same way: Prism didn't answer in time, so things go down the path they always did. The rules and wording
//  are in ClickyCore's FastDecisions.
//

import ClickyCore
import Foundation

enum PrismClient {
    static let settingKey = "v3.prism.fastDecisions"

    /// On unless the owner turned it off. It needs a Sarvam key too.
    static var isOn: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    /// One keep-alive connection, so all but the first call skip the TLS handshake.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    struct Outcome {
        var answer: PrismAnswer
        var all: [String: PrismAnswer]
        var milliseconds: Int
    }

    /// Nil on no key, a failure or a timeout. The reason goes to `lastProblem`, never the key.
    static func decide(_ question: FastDecisionQuestion, timeout: TimeInterval) async -> Outcome? {
        guard isOn else { return nil }
        do { return try await ask(question, timeout: timeout) } catch {
            lastProblem.set(error.localizedDescription)
            // A short budget can run out on a connection that went cold: open one for next time.
            if (error as? URLError)?.code == .timedOut { warm() }
            return nil
        }
    }

    static func ask(_ question: FastDecisionQuestion, timeout: TimeInterval) async throws -> Outcome {
        let key = await Task.detached(priority: .userInitiated) { ProviderKeychain.get("sarvam") }.value
        guard let key else { throw SarvamError.missingKey }
        var request = URLRequest(url: SarvamClient.restBaseURL.appendingPathComponent(PrismWire.path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        request.httpBody = PrismWire.body(state: question.state, questions: question.questions)
        let started = Date()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw PrismFailure(status: status, message: PrismWire.errorMessage(from: data)) }
        guard let all = PrismWire.answers(from: data), let answer = all[FastDecisionQuestion.id] else {
            throw PrismFailure(status: status, message: "No answer in the reply")
        }
        return Outcome(answer: answer, all: all, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// Opens the connection ahead of time, so the first real decision isn't the slow one. Costs a request with no question, which Prism refuses unbilled.
    static func warm() {
        guard isOn else { return }
        Task.detached(priority: .utility) {
            guard let key = ProviderKeychain.get("sarvam") else { return }
            var request = URLRequest(url: SarvamClient.restBaseURL.appendingPathComponent(PrismWire.path), timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "api-subscription-key")
            request.httpBody = Data("{}".utf8)
            _ = try? await session.data(for: request)
        }
    }

    /// A question asked while the app is doing real work, and what it picked. Only the decision, never the words.
    @discardableResult
    static func decide(_ kind: String, _ question: FastDecisionQuestion, timeout: TimeInterval) async -> PrismAnswer? {
        let outcome = await decide(question, timeout: timeout)
        record.add(kind: kind, pick: outcome?.answer.choice, probability: outcome?.answer.probability, milliseconds: outcome?.milliseconds)
        return outcome?.answer
    }

    /// The same, for a decision made of several questions.
    static func decideAll(_ kind: String, _ question: FastDecisionQuestion, timeout: TimeInterval) async -> [String: PrismAnswer]? {
        let outcome = await decide(question, timeout: timeout)
        record.add(kind: kind, pick: outcome?.answer.choice, probability: outcome?.answer.probability, milliseconds: outcome?.milliseconds)
        return outcome?.all
    }

    /// The last decisions, for the `fastDecisions` control command.
    final class DecisionRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [[String: Any]] = []
        func add(kind: String, pick: String?, probability: Double?, milliseconds: Int?) {
            lock.lock(); defer { lock.unlock() }
            rows.append(["kind": kind, "pick": pick ?? NSNull(), "p": probability ?? NSNull(), "ms": milliseconds ?? NSNull(), "at": Date().timeIntervalSince1970])
            if rows.count > 200 { rows.removeFirst(rows.count - 200) }
        }
        var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows }
    }
    static let record = DecisionRecord()

    final class ProblemNote: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return text }
    }
    static let lastProblem = ProblemNote()
}
