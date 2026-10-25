//
//  ExecutionPlan.swift
//  ClickyCore
//
//  The outward steps Clicky runs after approval, in a fixed order: push,
//  thread replies, thread resolves, a comment, PR create (only the steps
//  the task needs). It stops at the first failure — a failed push means no
//  replies claiming "fixed in abc123" — and is saved to state.json after
//  every step, so a retry skips what already succeeded and resumes at the
//  failed step. The runner is a protocol so tests use a mock.
//

import Foundation

public enum OutwardStepKind: String, Codable, CaseIterable, Sendable {
    case push
    case replies
    case resolves
    case comment
    case prCreate

    /// Position in the fixed order.
    var orderIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public protocol OutwardStepRunner {
    /// Runs one step; throws on failure.
    func run(_ step: OutwardStepKind) async throws
}

public struct ExecutionPlan: Codable, Equatable, Sendable {
    public enum StepStatus: String, Codable, Sendable {
        case pending
        case succeeded
        case failed
    }

    public struct Step: Codable, Equatable, Sendable {
        public var kind: OutwardStepKind
        public var status: StepStatus
        public var failureMessage: String?
    }

    public enum Outcome: Equatable, Sendable {
        case completed
        case stopped(at: OutwardStepKind, message: String)
    }

    public private(set) var steps: [Step]

    /// Only the given kinds, always in the fixed order (duplicates collapse).
    public init(steps stepKinds: [OutwardStepKind]) {
        steps = Set(stepKinds).sorted { $0.orderIndex < $1.orderIndex }.map { Step(kind: $0, status: .pending, failureMessage: nil) }
    }

    public var isComplete: Bool { steps.allSatisfy { $0.status == .succeeded } }
    public var failedStep: Step? { steps.first { $0.status == .failed } }

    /// The step to run now: nil when done, or when a step has failed (call prepareForRetry first).
    public func next() -> OutwardStepKind? {
        guard failedStep == nil else { return nil }
        return steps.first { $0.status == .pending }?.kind
    }

    public mutating func recordSuccess(_ kind: OutwardStepKind) {
        guard let stepIndex = steps.firstIndex(where: { $0.kind == kind }) else { return }
        steps[stepIndex].status = .succeeded
        steps[stepIndex].failureMessage = nil
    }

    public mutating func recordFailure(_ kind: OutwardStepKind, message: String) {
        guard let stepIndex = steps.firstIndex(where: { $0.kind == kind }) else { return }
        steps[stepIndex].status = .failed
        steps[stepIndex].failureMessage = message
    }

    /// Failed steps become pending again; succeeded ones stay done.
    public mutating func prepareForRetry() {
        for stepIndex in steps.indices where steps[stepIndex].status == .failed {
            steps[stepIndex].status = .pending
            steps[stepIndex].failureMessage = nil
        }
    }

    // MARK: - Persistence

    public static let stateFileName = "state.json"

    public func save(to stateFileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: stateFileURL, options: .atomic)
    }

    public static func load(from stateFileURL: URL) throws -> ExecutionPlan {
        try JSONDecoder().decode(ExecutionPlan.self, from: Data(contentsOf: stateFileURL))
    }

    // MARK: - Running

    /// Runs pending steps in order until done or the first failure, saving
    /// after each step when `stateFileURL` is given.
    @discardableResult
    public mutating func execute(using runner: OutwardStepRunner, stateFileURL: URL? = nil) async -> Outcome {
        while let stepKind = next() {
            do {
                try await runner.run(stepKind)
                recordSuccess(stepKind)
            } catch {
                recordFailure(stepKind, message: String(describing: error))
            }
            if let stateFileURL { try? save(to: stateFileURL) }
            if let failedStep { return .stopped(at: failedStep.kind, message: failedStep.failureMessage ?? "") }
        }
        return .completed
    }
}
