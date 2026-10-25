//
//  WBCamera.swift
//  ClickyCore
//
//  Where the board view looks during each narration step. If the whole
//  board fits the viewport at scale ≥ 0.85 the camera is fixed on it (never
//  zoomed past 1). Otherwise each step frames union(show, hl, focus) grown
//  by a 10% margin, merged with the previous step's frame when the two
//  overlap (no ping-pong between neighbours), at min(1.3, fit). A step that
//  names nothing known keeps the previous frame. The view animates between
//  transforms with a 0.6 s spring; this file only decides the targets.
//

import CoreGraphics
import Foundation

public struct WBCameraStep: Equatable, Sendable {
    public var show: [String]
    public var highlight: [String]
    public var focus: [String]

    public init(show: [String] = [], highlight: [String] = [], focus: [String] = []) {
        self.show = show
        self.highlight = highlight
        self.focus = focus
    }

    public var allIDs: [String] { show + highlight + focus }
}

/// board point p → view point (p.x · scale + translation.dx, p.y · scale + translation.dy)
public struct WBCameraTransform: Equatable, Sendable {
    /// The board rect being framed.
    public let framedRect: CGRect
    public let scale: CGFloat
    public let translation: CGVector

    public func viewPoint(for boardPoint: CGPoint) -> CGPoint {
        CGPoint(x: boardPoint.x * scale + translation.dx, y: boardPoint.y * scale + translation.dy)
    }

    /// The board rect actually on screen.
    public func visibleBoardRect(viewportSize: CGSize) -> CGRect {
        CGRect(x: -translation.dx / scale, y: -translation.dy / scale, width: viewportSize.width / scale, height: viewportSize.height / scale)
    }
}

public enum WBCameraMode: String, Sendable, Equatable {
    case fixed, perStep
}

public struct WBCameraPlan: Equatable, Sendable {
    public let mode: WBCameraMode
    /// The whole-board transform (what a fixed camera uses throughout).
    public let boardTransform: WBCameraTransform
    /// One per step, in order.
    public let stepTransforms: [WBCameraTransform]
    public let springDuration: TimeInterval
}

public enum WBCamera {
    public static let fixedMinimumScale: CGFloat = 0.85
    public static let fixedMaximumScale: CGFloat = 1
    public static let stepMaximumScale: CGFloat = 1.3
    public static let stepMarginFraction: CGFloat = 0.10
    public static let springDuration: TimeInterval = 0.6

    public static func fitScale(_ rect: CGRect, viewportSize: CGSize) -> CGFloat {
        guard rect.width > 0, rect.height > 0 else { return 1 }
        return min(viewportSize.width / rect.width, viewportSize.height / rect.height)
    }

    /// `rect` centred in the viewport at min(maximumScale, fit).
    public static func transform(framing rect: CGRect, viewportSize: CGSize, maximumScale: CGFloat) -> WBCameraTransform {
        let scale = min(maximumScale, fitScale(rect, viewportSize: viewportSize))
        let translation = CGVector(dx: viewportSize.width / 2 - rect.midX * scale, dy: viewportSize.height / 2 - rect.midY * scale)
        return WBCameraTransform(framedRect: rect, scale: scale, translation: translation)
    }

    public static func plan(layout: WBBoardLayout, steps: [WBCameraStep], viewportSize: CGSize) -> WBCameraPlan {
        plan(boardBounds: layout.bounds, steps: steps, viewportSize: viewportSize, rectForID: layout.rect(forID:))
    }

    public static func plan(boardBounds: CGRect, steps: [WBCameraStep], viewportSize: CGSize, rectForID: (String) -> CGRect?) -> WBCameraPlan {
        let boardTransform = transform(framing: boardBounds, viewportSize: viewportSize, maximumScale: fixedMaximumScale)
        if fitScale(boardBounds, viewportSize: viewportSize) >= fixedMinimumScale {
            return WBCameraPlan(mode: .fixed, boardTransform: boardTransform,
                                stepTransforms: Array(repeating: boardTransform, count: steps.count), springDuration: springDuration)
        }
        var stepTransforms: [WBCameraTransform] = []
        var previousStepRect: CGRect?
        var previousTransform = boardTransform
        for step in steps {
            let namedRect = step.allIDs.compactMap(rectForID).reduce(CGRect.null) { $0.union($1) }
            guard !namedRect.isNull else {
                stepTransforms.append(previousTransform)
                continue
            }
            let marginedRect = namedRect.insetBy(dx: -namedRect.width * stepMarginFraction, dy: -namedRect.height * stepMarginFraction)
            var framedRect = marginedRect
            if let previousStepRect, previousStepRect.intersects(marginedRect) { framedRect = previousStepRect.union(marginedRect) }
            let stepTransform = transform(framing: framedRect, viewportSize: viewportSize, maximumScale: stepMaximumScale)
            stepTransforms.append(stepTransform)
            previousStepRect = marginedRect
            previousTransform = stepTransform
        }
        return WBCameraPlan(mode: .perStep, boardTransform: boardTransform, stepTransforms: stepTransforms, springDuration: springDuration)
    }
}
