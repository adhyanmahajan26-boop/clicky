//
//  ClaudeSparkShape.swift
//  ClickyCore
//
//  The companion's logo: Claude's orange spark, drawn in code. Used by the
//  cursor-following companion (ClaudeCompanionView in the app) and the notch
//  pill (NotchView), so both show the same mark. Moved here from
//  ClaudeCompanionView.swift unchanged.
//

import SwiftUI

public extension Color {
    /// The companion orange (the app's DS.Colors.overlayCompanionOrange, #D97757).
    static let clickyCompanionOrange = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
}

/// Claude's spark mark: twelve tapered rays of slightly uneven length and
/// spacing, thin where they meet in the middle and wider at their clipped
/// tips, so it reads as hand-drawn rather than a geometric star.
public struct ClaudeSparkShape: Shape {
    public init() {}

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

    public func path(in rect: CGRect) -> Path {
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
