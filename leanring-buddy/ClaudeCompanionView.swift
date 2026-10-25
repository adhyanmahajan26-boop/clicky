//
//  ClaudeCompanionView.swift
//  leanring-buddy
//
//  The companion that follows the mouse: a Claude-style orange spark (the
//  "coordinator"). It breathes gently while idle and spins while it's
//  thinking. Each running worker (from a CompanionActivitySource) shows up as
//  a miniature spark orbiting the big one, spinning while it works and fading
//  out when it's done.
//
//  Everything is drawn in code, no logo image files. The spark shape itself
//  (ClaudeSparkShape) lives in ClickyCore so the notch pill draws the same mark.
//

import ClickyCore
import SwiftUI

struct ClaudeCompanionView: View {
    /// True while the coordinator is waiting on Claude (the old spinner state).
    let isCoordinatorThinking: Bool
    /// Workers currently running (at most 4). Finished workers are left out,
    /// which is what makes their mini fade away.
    let activeCompanionWorkers: [CompanionWorkerActivity]
    /// Pausing the animation clock when the companion isn't on this screen
    /// saves redrawing every overlay at 60fps.
    let isAnimationRunning: Bool

    static let coordinatorSparkDiameter: CGFloat = 24
    static let workerSparkDiameter: CGFloat = 10
    static let workerOrbitRadius: CGFloat = 25

    private let coordinatorThinkingSpinDegreesPerSecond: Double = 220
    private let idleBreathingCycleSeconds: Double = 3.2
    private let workerSpinDegreesPerSecond: Double = 400
    private let workerOrbitDegreesPerSecond: Double = 70

    /// Big enough to hold the orbit plus the minis' glow.
    static var companionFrameDiameter: CGFloat {
        (workerOrbitRadius + workerSparkDiameter) * 2 + 8
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isAnimationRunning)) { timelineContext in
            let secondsSinceReferenceDate = timelineContext.date.timeIntervalSinceReferenceDate

            ZStack {
                coordinatorSpark(secondsSinceReferenceDate: secondsSinceReferenceDate)
                orbitingWorkerSparks(secondsSinceReferenceDate: secondsSinceReferenceDate)
            }
        }
        .frame(width: Self.companionFrameDiameter, height: Self.companionFrameDiameter)
        .allowsHitTesting(false)
    }

    // MARK: - Coordinator

    private func coordinatorSpark(secondsSinceReferenceDate: Double) -> some View {
        let coordinatorRotationDegrees = isCoordinatorThinking
            ? (secondsSinceReferenceDate * coordinatorThinkingSpinDegreesPerSecond).truncatingRemainder(dividingBy: 360)
            : 0
        let breathingPhase = (secondsSinceReferenceDate / idleBreathingCycleSeconds) * 2 * .pi
        let coordinatorScale = isCoordinatorThinking ? 1.0 : 1.0 + 0.06 * sin(breathingPhase)

        return ClaudeSparkShape()
            .fill(DS.Colors.overlayCompanionOrange)
            .frame(width: Self.coordinatorSparkDiameter, height: Self.coordinatorSparkDiameter)
            .rotationEffect(.degrees(coordinatorRotationDegrees))
            .scaleEffect(coordinatorScale)
            .shadow(color: DS.Colors.overlayCompanionOrange.opacity(isCoordinatorThinking ? 0.9 : 0.6), radius: isCoordinatorThinking ? 9 : 6)
    }

    // MARK: - Workers

    /// The orbit's spin is applied to the whole ring, and each mini's slot
    /// angle is a separate rotation. That way the per-frame orbit motion never
    /// interrupts the spring that re-spaces the minis when one joins or leaves.
    private func orbitingWorkerSparks(secondsSinceReferenceDate: Double) -> some View {
        let workerSpinDegrees = (secondsSinceReferenceDate * workerSpinDegreesPerSecond).truncatingRemainder(dividingBy: 360)
        let orbitRotationDegrees = (secondsSinceReferenceDate * workerOrbitDegreesPerSecond).truncatingRemainder(dividingBy: 360)
        let activeWorkerCount = activeCompanionWorkers.count

        return ZStack {
            ForEach(Array(activeCompanionWorkers.enumerated()), id: \.element.id) { workerIndex, _ in
                ClaudeSparkShape()
                    .fill(DS.Colors.overlayCompanionOrange)
                    .frame(width: Self.workerSparkDiameter, height: Self.workerSparkDiameter)
                    .rotationEffect(.degrees(workerSpinDegrees))
                    .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.7), radius: 4)
                    .offset(x: Self.workerOrbitRadius)
                    .rotationEffect(.degrees(Self.evenlySpacedOrbitSlotDegrees(workerIndex: workerIndex, activeWorkerCount: activeWorkerCount)))
                    .transition(.opacity.combined(with: .scale(scale: 0.2)))
            }
        }
        .rotationEffect(.degrees(orbitRotationDegrees))
        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: activeCompanionWorkers.map(\.id))
    }

    /// 1 worker sits at the top, 2 are opposite each other, 3 form a
    /// triangle, 4 a cross.
    static func evenlySpacedOrbitSlotDegrees(workerIndex: Int, activeWorkerCount: Int) -> Double {
        guard activeWorkerCount > 0 else { return -90 }
        return -90 + Double(workerIndex) * (360 / Double(activeWorkerCount))
    }
}
