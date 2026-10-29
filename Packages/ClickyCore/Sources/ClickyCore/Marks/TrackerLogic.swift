//
//  TrackerLogic.swift
//  ClickyCore
//
//  The decisions behind live-mark tracking, free of AX and timers so they
//  can be tested: how much of a mark is visible, when to hide/reshow it,
//  when a reused row means the mark is stale, how often to poll, and which
//  events clear marks that can't be tracked (OCR / raw-point marks).
//

import CoreGraphics
import Foundation

public enum TrackerLogic {
    public static let hideBelowVisibleFraction: CGFloat = 0.5
    public static let labelDriftThreshold = 0.8
    public static let fastInterval: TimeInterval = 0.1
    public static let slowInterval: TimeInterval = 1.0
    public static let fastWindow: TimeInterval = 1.0

    /// Visible part of `rect`: ∩ its scroll/web clip (if any) ∩ its window.
    public static func visibleRect(_ rect: CGRect, clip: CGRect?, window: CGRect?) -> CGRect {
        var visible = rect
        if let clip { visible = visible.intersection(clip) }
        if let window { visible = visible.intersection(window) }
        return visible.isNull ? .zero : visible
    }

    public static func visibleFraction(_ rect: CGRect, clip: CGRect?, window: CGRect?) -> CGFloat {
        guard rect.area > 0 else {
            // A zero-size target is visible iff its point is.
            let point = rect.center
            let isInside = (clip?.contains(point) ?? true) && (window?.contains(point) ?? true)
            return isInside ? 1 : 0
        }
        return visibleRect(rect, clip: clip, window: window).area / rect.area
    }

    /// Hide below 50 % visible; show again at ≥ 50 %.
    public static func isShown(visibleFraction: CGFloat) -> Bool {
        visibleFraction >= hideBelowVisibleFraction
    }

    /// A moved element whose label no longer matches was a reused row/cell.
    public static func labelDrifted(original: String?, current: String?) -> Bool {
        guard let original, !original.isEmpty else { return false }
        guard let current, !current.isEmpty else { return true }
        return LabelSimilarity.labelSim(original, candidates: [current]) < labelDriftThreshold
    }

    public static func hasMoved(_ previous: CGRect, _ current: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(previous.minX - current.minX) > tolerance || abs(previous.minY - current.minY) > tolerance
            || abs(previous.width - current.width) > tolerance || abs(previous.height - current.height) > tolerance
    }

    /// Poll cadence: 100 ms for 1 s after activity, else 1 s.
    public struct Cadence: Sendable {
        public private(set) var lastActivity: Date?

        public init() {}

        public mutating func noteActivity(at date: Date) {
            lastActivity = date
        }

        public func interval(at date: Date) -> TimeInterval {
            guard let lastActivity, date.timeIntervalSince(lastActivity) < TrackerLogic.fastWindow else { return TrackerLogic.slowInterval }
            return TrackerLogic.fastInterval
        }
    }

    /// Events that clear OCR / raw-point marks (they have no AX element to follow).
    public enum UntrackedEvent: Sendable {
        case scrollWheel(locationCG: CGPoint)
        case applicationActivated(processIdentifier: pid_t)
        case windowChanged(windowID: CGWindowID, newFrame: CGRect?)
        case screenParametersChanged
    }

    /// Whether `event` clears an untracked mark sitting in `windowID` (frame
    /// `windowFrame` when the mark was made).
    public static func clearsUntrackedMark(_ event: UntrackedEvent, markWindowID: CGWindowID?, markWindowFrame: CGRect?,
                                           ownProcessIdentifier: pid_t) -> Bool {
        switch event {
        case .scrollWheel(let locationCG):
            guard let markWindowFrame else { return false }
            return markWindowFrame.contains(locationCG)
        case .applicationActivated(let processIdentifier):
            return processIdentifier != ownProcessIdentifier
        case .windowChanged(let windowID, let newFrame):
            guard windowID == markWindowID else { return false }
            guard let newFrame, let markWindowFrame else { return true }
            return hasMoved(markWindowFrame, newFrame)
        case .screenParametersChanged:
            return true
        }
    }
}
