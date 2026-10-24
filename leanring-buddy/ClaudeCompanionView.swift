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
//  Everything is drawn in code, no logo image files.
//

import SwiftUI

/// Claude's spark mark: twelve tapered rays of slightly uneven length and
/// spacing, thin where they meet in the middle and wider at their clipped
/// tips, so it reads as hand-drawn rather than a geometric star.
struct ClaudeSparkShape: Shape {
    private struct SparkRay {
        /// Direction in degrees: 0 points right, increasing clockwise.
        let angleDegrees: CGFloat
        /// 1.0 reaches the edge of the frame.
        let relativeLength: CGFloat
        /// Half the width of the tip, as a fraction of the spark's radius.
        let relativeTipHalfWidth: CGFloat
    }

    /// Angles and lengths measured from the real mark, so the unevenness
    /// matches it instead of being random.
    private static let sparkRays: [SparkRay] = [
        SparkRay(angleDegrees: 15, relativeLength: 0.93, relativeTipHalfWidth: 0.104),
        SparkRay(angleDegrees: 44, relativeLength: 0.95, relativeTipHalfWidth: 0.111),
        SparkRay(angleDegrees: 60, relativeLength: 0.93, relativeTipHalfWidth: 0.098),
        SparkRay(angleDegrees: 95, relativeLength: 0.96, relativeTipHalfWidth: 0.098),
        SparkRay(angleDegrees: 123, relativeLength: 0.96, relativeTipHalfWidth: 0.104),
        SparkRay(angleDegrees: 146, relativeLength: 0.92, relativeTipHalfWidth: 0.098),
        SparkRay(angleDegrees: 179, relativeLength: 0.96, relativeTipHalfWidth: 0.078),
        SparkRay(angleDegrees: 212, relativeLength: 0.95, relativeTipHalfWidth: 0.104),
        SparkRay(angleDegrees: 242, relativeLength: 1.00, relativeTipHalfWidth: 0.111),
        SparkRay(angleDegrees: 279, relativeLength: 0.87, relativeTipHalfWidth: 0.091),
        SparkRay(angleDegrees: 311, relativeLength: 0.91, relativeTipHalfWidth: 0.104),
        SparkRay(angleDegrees: 353, relativeLength: 0.90, relativeTipHalfWidth: 0.104)
    ]

    /// Where the rays start, and their half-width there. Rays start inside
    /// the hub so they merge into one solid centre.
    private static let relativeRayBaseRadius: CGFloat = 0.10
    private static let relativeRayBaseHalfWidth: CGFloat = 0.05
    private static let relativeHubRadius: CGFloat = 0.2
    /// How far back from the tip its corners are clipped.
    private static let relativeTipChamferLength: CGFloat = 0.07

    func path(in rect: CGRect) -> Path {
        let sparkCenter = CGPoint(x: rect.midX, y: rect.midY)
        let sparkRadius = min(rect.width, rect.height) / 2

        /// Maps a point in a ray's own frame (x along the ray, y across it)
        /// to the view, rotated to the ray's direction.
        func pointAlongRay(angleRadians: CGFloat, alongRay: CGFloat, acrossRay: CGFloat) -> CGPoint {
            CGPoint(
                x: sparkCenter.x + (cos(angleRadians) * alongRay - sin(angleRadians) * acrossRay) * sparkRadius,
                y: sparkCenter.y + (sin(angleRadians) * alongRay + cos(angleRadians) * acrossRay) * sparkRadius
            )
        }

        var sparkPath = Path()

        // Every subpath winds the same way so the default non-zero fill
        // merges the overlapping rays and hub instead of punching holes.
        for sparkRay in Self.sparkRays {
            let rayAngleRadians = sparkRay.angleDegrees * .pi / 180
            let tipDistance = sparkRay.relativeLength
            let tipHalfWidth = sparkRay.relativeTipHalfWidth
            let rayOutline: [(alongRay: CGFloat, acrossRay: CGFloat)] = [
                (Self.relativeRayBaseRadius, -Self.relativeRayBaseHalfWidth),
                (tipDistance - Self.relativeTipChamferLength, -tipHalfWidth),
                (tipDistance, -tipHalfWidth * 0.45),
                (tipDistance, tipHalfWidth * 0.45),
                (tipDistance - Self.relativeTipChamferLength, tipHalfWidth),
                (Self.relativeRayBaseRadius, Self.relativeRayBaseHalfWidth)
            ]
            sparkPath.addLines(rayOutline.map {
                pointAlongRay(angleRadians: rayAngleRadians, alongRay: $0.alongRay, acrossRay: $0.acrossRay)
            })
            sparkPath.closeSubpath()
        }

        let hubCornerCount = 24
        sparkPath.addLines((0..<hubCornerCount).map { hubCornerIndex in
            let hubAngleRadians = CGFloat(hubCornerIndex) / CGFloat(hubCornerCount) * 2 * .pi
            return pointAlongRay(angleRadians: hubAngleRadians, alongRay: Self.relativeHubRadius, acrossRay: 0)
        })
        sparkPath.closeSubpath()

        return sparkPath
    }
}

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
