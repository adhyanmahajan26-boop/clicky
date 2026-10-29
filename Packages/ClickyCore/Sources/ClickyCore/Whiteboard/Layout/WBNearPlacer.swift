//
//  WBNearPlacer.swift
//  ClickyCore
//
//  `near:id pos:side` for text and callouts: the requested side (12 pt off
//  the target, centred on it), then the other three (opposite first), then
//  ±16 pt nudges along each side in the same order (up to 12 tries per
//  side), keeping the first spot that overlaps nothing. When everything is
//  taken it goes below all obstacles, under the target — never on top of
//  anything.
//

import CoreGraphics
import Foundation

public enum WBNearPlacer {
    public static let gap: CGFloat = 12
    public static let nudgeStep: CGFloat = 16
    public static let maximumNudgeTries = 12

    public struct Placement: Equatable, Sendable {
        public let rect: CGRect
        public let side: WBLayoutSide
        /// 0 when on the side's centre line, else the nudge applied.
        public let nudge: CGFloat
        /// False only for the below-everything fallback.
        public let isBeside: Bool
    }

    public static func sideOrder(startingWith requested: WBLayoutSide) -> [WBLayoutSide] {
        let opposite: WBLayoutSide
        switch requested {
        case .top: opposite = .bottom
        case .bottom: opposite = .top
        case .left: opposite = .right
        case .right: opposite = .left
        }
        let perpendicular = WBLayoutSide.allCases.filter { $0 != requested && $0 != opposite }
        return [requested, opposite] + perpendicular
    }

    public static func rect(size: CGSize, beside target: CGRect, side: WBLayoutSide, nudge: CGFloat = 0) -> CGRect {
        switch side {
        case .top:
            return CGRect(x: target.midX - size.width / 2 + nudge, y: target.minY - gap - size.height, width: size.width, height: size.height)
        case .bottom:
            return CGRect(x: target.midX - size.width / 2 + nudge, y: target.maxY + gap, width: size.width, height: size.height)
        case .left:
            return CGRect(x: target.minX - gap - size.width, y: target.midY - size.height / 2 + nudge, width: size.width, height: size.height)
        case .right:
            return CGRect(x: target.maxX + gap, y: target.midY - size.height / 2 + nudge, width: size.width, height: size.height)
        }
    }

    /// `obstacles` should hold everything already placed (target included).
    public static func place(size: CGSize, near target: CGRect, side requestedSide: WBLayoutSide, obstacles: [CGRect]) -> Placement {
        func isClean(_ candidate: CGRect) -> Bool { !obstacles.contains { WBLayoutGeometry.overlaps($0, candidate) } }
        let sides = sideOrder(startingWith: requestedSide)
        for side in sides {
            let candidate = rect(size: size, beside: target, side: side)
            if isClean(candidate) { return Placement(rect: candidate, side: side, nudge: 0, isBeside: true) }
        }
        let nudges: [CGFloat] = (1...(maximumNudgeTries / 2)).flatMap { step in [CGFloat(step) * nudgeStep, -CGFloat(step) * nudgeStep] }
        for side in sides {
            for nudge in nudges {
                let candidate = rect(size: size, beside: target, side: side, nudge: nudge)
                if isClean(candidate) { return Placement(rect: candidate, side: side, nudge: nudge, isBeside: true) }
            }
        }
        let lowestObstacleEdge = obstacles.reduce(target.maxY) { max($0, $1.maxY) }
        let fallback = CGRect(x: target.minX, y: lowestObstacleEdge + gap, width: size.width, height: size.height)
        return Placement(rect: fallback, side: .bottom, nudge: 0, isBeside: false)
    }
}
