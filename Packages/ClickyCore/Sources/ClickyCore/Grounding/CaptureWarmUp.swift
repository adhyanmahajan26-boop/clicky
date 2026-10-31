//
//  CaptureWarmUp.swift
//  ClickyCore
//
//  The first capture(s) after Clicky launches (also seen after a display
//  change / wake) can come back with every other app's window solid black
//  while the wallpaper and widgets are fine (turns 20261025-161115-e20dbed3,
//  -161147-ebba28af, -165737-d8803941: each in the first 1–2 asks after a
//  relaunch). So the app takes throwaway captures in the background shortly
//  after launch, every `attemptInterval`, until one passes the black check
//  (BlackFrameDetector) or there are no app windows to judge, for at most
//  `maximumDuration`; the user's first ask then gets a good frame (it waits
//  up to `askWaitSeconds` for a warm-up still running). This is the pure
//  schedule; the clock is injected.
//
//  Priming: no explicit "prime" call is known to be needed beyond this.
//  Each warm-up attempt is the same SCShareableContent fetch +
//  SCScreenshotManager.captureImage an ask makes (fresh content every time,
//  never cached), so it is itself the first-use priming; it only runs when
//  CGPreflightScreenCaptureAccess() says capture is allowed (that call never
//  prompts). Whether one call suffices or the condition just has to time
//  out couldn't be measured without relaunching Clicky; the turn log's
//  blackFrameRetry.warmUp ("launch: good after N attempts in M ms") answers
//  it from the next relaunches.
//

import Foundation

public struct CaptureWarmUp: Sendable, Equatable {
    public static let initialDelay: TimeInterval = 0.5
    public static let attemptInterval: TimeInterval = 1.5
    public static let maximumDuration: TimeInterval = 30
    /// How long an ask waits for a warm-up that's still running.
    public static let askWaitSeconds: TimeInterval = 1.0

    public enum Outcome: Sendable, Equatable {
        /// The capture passed the black check.
        case good
        /// No app window big enough to judge (nothing to prove either way).
        case noAppWindows
        /// App windows came back black.
        case black
        /// The capture threw (no permission yet, display gone, …).
        case failed
    }

    public enum Result: Sendable, Equatable {
        case good(attempts: Int)
        case noAppWindows(attempts: Int)
        /// Still black / failing at `maximumDuration`.
        case gaveUp(attempts: Int)
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case running(startedAt: Date, attempts: Int, blackAttempts: Int, nextAttemptAt: Date)
        case finished(Result)
    }

    public enum Step: Sendable, Equatable {
        /// Take a throwaway capture now and `record` its outcome.
        case captureNow
        /// Nothing to do until then.
        case wait(seconds: TimeInterval)
        /// Not running (idle or finished).
        case done
    }

    public private(set) var phase: Phase = .idle
    public let initialDelay: TimeInterval
    public let attemptInterval: TimeInterval
    public let maximumDuration: TimeInterval

    public init(initialDelay: TimeInterval = CaptureWarmUp.initialDelay, attemptInterval: TimeInterval = CaptureWarmUp.attemptInterval,
                maximumDuration: TimeInterval = CaptureWarmUp.maximumDuration) {
        self.initialDelay = initialDelay
        self.attemptInterval = attemptInterval
        self.maximumDuration = maximumDuration
    }

    public var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// (Re)starts the schedule: launch, display change, wake. A run already
    /// in progress starts over (its deadline moves) so the new condition gets
    /// its full time.
    public mutating func start(at now: Date) {
        phase = .running(startedAt: now, attempts: 0, blackAttempts: 0, nextAttemptAt: now.addingTimeInterval(initialDelay))
    }

    public func nextStep(at now: Date) -> Step {
        guard case .running(_, _, _, let nextAttemptAt) = phase else { return .done }
        let remaining = nextAttemptAt.timeIntervalSince(now)
        return remaining <= 0 ? .captureNow : .wait(seconds: remaining)
    }

    public mutating func record(_ outcome: Outcome, at now: Date) {
        guard case .running(let startedAt, let attempts, let blackAttempts, _) = phase else { return }
        let attemptCount = attempts + 1
        switch outcome {
        case .good:
            phase = .finished(.good(attempts: attemptCount))
        case .noAppWindows:
            phase = .finished(.noAppWindows(attempts: attemptCount))
        case .black, .failed:
            let nextAttemptAt = now.addingTimeInterval(attemptInterval)
            if nextAttemptAt.timeIntervalSince(startedAt) > maximumDuration {
                phase = .finished(.gaveUp(attempts: attemptCount))
            } else {
                phase = .running(startedAt: startedAt, attempts: attemptCount, blackAttempts: blackAttempts + (outcome == .black ? 1 : 0),
                                 nextAttemptAt: nextAttemptAt)
            }
        }
    }

    /// For logs: "good after 3 attempts", "running (2 black)", …
    public var description: String {
        switch phase {
        case .idle: return "idle"
        case .running(_, let attempts, let blackAttempts, _): return "running (\(attempts) attempts, \(blackAttempts) black)"
        case .finished(.good(let attempts)): return "good after \(attempts) attempt\(attempts == 1 ? "" : "s")"
        case .finished(.noAppWindows(let attempts)): return "no app windows after \(attempts) attempt\(attempts == 1 ? "" : "s")"
        case .finished(.gaveUp(let attempts)): return "gave up after \(attempts) attempts"
        }
    }
}
