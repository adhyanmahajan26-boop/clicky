//
//  WhiteboardScene.swift
//  ClickyCore
//
//  Everything the board view needs that doesn't change while it narrates:
//  the adapted board, its layout, the camera plan and the viewport it was
//  laid out for. Plus WhiteboardRenderState, the part that does change
//  (what's revealed since when, what's highlighted, where the camera looks,
//  the subtitle). Both are plain values so offscreen renders are exact.
//

import CoreGraphics
import Foundation

public struct WhiteboardScene: Sendable {
    /// Header (title, step) and subtitle bar around the board viewport.
    public static let headerHeight: CGFloat = 40
    public static let subtitleBarHeight: CGFloat = 58

    public let adapted: WBAdaptedBoard
    public let layout: WBBoardLayout
    public let cameraPlan: WBCameraPlan
    /// The board area (panel minus header and subtitle bar).
    public let viewportSize: CGSize

    public var board: WBBoard { adapted.board }

    public init(board: WBBoard, viewportSize: CGSize) {
        self.viewportSize = viewportSize
        adapted = WBLayoutAdapter.adapt(board, viewportSize: viewportSize)
        layout = WBBoardLayoutEngine.layout(adapted.input)
        cameraPlan = WBCamera.plan(layout: layout, steps: adapted.cameraSteps, viewportSize: viewportSize)
    }

    /// The board viewport for a whole panel of `panelSize`.
    public static func viewportSize(forPanelSize panelSize: CGSize) -> CGSize {
        CGSize(width: max(200, panelSize.width), height: max(160, panelSize.height - headerHeight - subtitleBarHeight))
    }

    /// The camera for step `stepIndex` (nil → the whole board).
    public func cameraTransform(forStep stepIndex: Int?) -> WBCameraTransform {
        guard let stepIndex, cameraPlan.stepTransforms.indices.contains(stepIndex) else { return cameraPlan.boardTransform }
        return cameraPlan.stepTransforms[stepIndex]
    }

    /// The whole board, 1:1, origin at the board margin (exports).
    public var actualSizeTransform: WBCameraTransform {
        WBCameraTransform(framedRect: layout.bounds, scale: 1, translation: .zero)
    }
}

public struct WhiteboardRenderState: Equatable, Sendable {
    /// Board element id → when it starts appearing (clock seconds); missing = not yet.
    public var revealTimes: [String: TimeInterval]
    public var highlightedIdentifiers: [String]
    public var camera: WBCameraTransform
    public var subtitle: String
    /// "3 / 7"
    public var stepLabel: String
    public var isPaused: Bool
    /// Shown over an empty board ("Drawing…").
    public var statusText: String?

    public init(revealTimes: [String: TimeInterval] = [:], highlightedIdentifiers: [String] = [], camera: WBCameraTransform,
                subtitle: String = "", stepLabel: String = "", isPaused: Bool = false, statusText: String? = nil) {
        self.revealTimes = revealTimes
        self.highlightedIdentifiers = highlightedIdentifiers
        self.camera = camera
        self.subtitle = subtitle
        self.stepLabel = stepLabel
        self.isPaused = isPaused
        self.statusText = statusText
    }

    /// Everything drawn, nothing highlighted: exports and goldens.
    public static func fullyRevealed(_ scene: WhiteboardScene, camera: WBCameraTransform? = nil, subtitle: String = "") -> WhiteboardRenderState {
        var revealTimes: [String: TimeInterval] = [:]
        for element in scene.board.elements { revealTimes[element.id] = BoardNarrator.instantRevealTime }
        return WhiteboardRenderState(revealTimes: revealTimes, camera: camera ?? scene.cameraPlan.boardTransform, subtitle: subtitle,
                                     stepLabel: scene.board.steps.isEmpty ? "" : "\(scene.board.steps.count) / \(scene.board.steps.count)")
    }
}
