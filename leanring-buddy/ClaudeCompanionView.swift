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

/// A radial burst of rounded rays, like Claude's spark mark. Ray lengths vary
/// slightly so it looks hand-drawn rather than like a perfect asterisk.
struct ClaudeSparkShape: Shape {
    /// Relative length of each ray (1.0 = reaches the edge of the frame).
    /// Fixed values, not random, so every spark looks the same.
    private static let relativeRayLengths: [CGFloat] = [
        1.00, 0.84, 0.94, 0.80, 0.98, 0.87, 0.92, 0.82, 1.00, 0.86, 0.95, 0.81
    ]

    func path(in rect: CGRect) -> Path {
        let sparkCenter = CGPoint(x: rect.midX, y: rect.midY)
        let sparkRadius = min(rect.width, rect.height) / 2
        // Rays are stroked with round caps, so pull the tips in by half the
        // stroke width to keep them inside the frame.
        let rayStrokeWidth = sparkRadius * 0.26
        let rayInnerRadius = sparkRadius * 0.12
        let rayCount = Self.relativeRayLengths.count

        var raySkeletonPath = Path()
        for rayIndex in 0..<rayCount {
            // Start pointing straight up and go clockwise.
            let rayAngle = (CGFloat(rayIndex) / CGFloat(rayCount)) * 2 * .pi - .pi / 2
            let rayOuterRadius = (sparkRadius - rayStrokeWidth / 2) * Self.relativeRayLengths[rayIndex]
            raySkeletonPath.move(to: CGPoint(
                x: sparkCenter.x + cos(rayAngle) * rayInnerRadius,
                y: sparkCenter.y + sin(rayAngle) * rayInnerRadius
            ))
            raySkeletonPath.addLine(to: CGPoint(
                x: sparkCenter.x + cos(rayAngle) * rayOuterRadius,
                y: sparkCenter.y + sin(rayAngle) * rayOuterRadius
            ))
        }

        // Turning the stroke into a filled outline lets callers use .fill()
        // like any other shape, and overlapping rays merge cleanly at the center.
        return raySkeletonPath.strokedPath(StrokeStyle(lineWidth: rayStrokeWidth, lineCap: .round))
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

    static let coordinatorSparkDiameter: CGFloat = 20
    static let workerSparkDiameter: CGFloat = 9
    static let workerOrbitRadius: CGFloat = 22

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
