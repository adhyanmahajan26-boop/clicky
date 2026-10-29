//
//  CompanionActivitySource.swift
//  leanring-buddy
//
//  What the spark companion shows: whether the coordinator ("main brain") is
//  thinking, and which workers are running around it. The overlay doesn't
//  care where that comes from, so a real source (for example the threads of
//  a Claude project) can be plugged in later without touching the drawing.
//
//  For now the only source is SimulatedCompanionActivitySource, driven from
//  the debug controls in the menu bar panel.
//

import Foundation

/// One worker (for example one thread) the coordinator has running.
struct CompanionWorkerActivity: Identifiable, Equatable {
    let id: String
    let workerTitle: String
    /// False once the worker has finished. Finished workers fade off the orbit.
    let isWorking: Bool
}

@MainActor
protocol CompanionActivitySource: AnyObject {
    /// True while the coordinator itself is thinking. The spark also spins
    /// while Clicky's own answer is in flight, regardless of this.
    var coordinatorIsThinking: Bool { get }
    /// Every worker the source knows about, working or finished.
    var workers: [CompanionWorkerActivity] { get }
    /// The source calls this whenever either value changes, so
    /// CompanionManager can republish them to the overlay.
    var onActivityChanged: (() -> Void)? { get set }
}

enum CompanionActivityLimits {
    /// The orbit has room for four minis; anything beyond that isn't drawn.
    static let maximumVisibleWorkers = 4

    /// The workers the overlay should draw: only running ones, first four.
    static func visibleWorkers(from workers: [CompanionWorkerActivity]) -> [CompanionWorkerActivity] {
        Array(workers.filter(\.isWorking).prefix(maximumVisibleWorkers))
    }
}

/// A stand-in source for trying the visuals before a real one exists.
@MainActor
final class SimulatedCompanionActivitySource: CompanionActivitySource {
    private(set) var coordinatorIsThinking = false
    private(set) var workers: [CompanionWorkerActivity] = []
    var onActivityChanged: (() -> Void)?

    private var nextSimulatedWorkerNumber = 1

    func setSimulatedCoordinatorThinking(_ isThinking: Bool) {
        coordinatorIsThinking = isThinking
        onActivityChanged?()
    }

    /// Adds or finishes workers until exactly `requestedWorkerCount` are
    /// running, clamped to 0...4. Finishing removes the newest first, so the
    /// remaining minis keep their places and re-space smoothly.
    func setSimulatedWorkingWorkerCount(_ requestedWorkerCount: Int) {
        let clampedWorkerCount = max(0, min(requestedWorkerCount, CompanionActivityLimits.maximumVisibleWorkers))
        var runningWorkers = workers.filter(\.isWorking)

        while runningWorkers.count < clampedWorkerCount {
            runningWorkers.append(CompanionWorkerActivity(
                id: "simulated-worker-\(nextSimulatedWorkerNumber)",
                workerTitle: "Simulated thread \(nextSimulatedWorkerNumber)",
                isWorking: true
            ))
            nextSimulatedWorkerNumber += 1
        }
        if runningWorkers.count > clampedWorkerCount {
            runningWorkers.removeLast(runningWorkers.count - clampedWorkerCount)
        }

        workers = runningWorkers
        onActivityChanged?()
    }
}
