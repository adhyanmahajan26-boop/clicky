//
//  WindowList.swift
//  ClickyCore
//
//  Which windows are on screen, front to back, and whether something is
//  hidden behind another app's window (then it is listed as "behind" and
//  never badged). Read once per question.
//

import CoreGraphics
import Foundation

public struct WindowInfo: Sendable, Equatable {
    public let windowID: CGWindowID
    public let processIdentifier: pid_t
    public let layer: Int
    public let boundsCG: CGRect
    public let alpha: Double
    public let ownerName: String
    public let title: String?

    /// Normal app windows and their floating panels/utility windows
    /// (layers 0–19). The Dock (20) and menu bar (24/25) are system chrome;
    /// 101 is an open menu.
    public var isApplicationWindowLayer: Bool { layer >= 0 && layer < 20 }

    public init(windowID: CGWindowID, processIdentifier: pid_t, layer: Int, boundsCG: CGRect, alpha: Double, ownerName: String, title: String?) {
        self.windowID = windowID
        self.processIdentifier = processIdentifier
        self.layer = layer
        self.boundsCG = boundsCG
        self.alpha = alpha
        self.ownerName = ownerName
        self.title = title
    }
}

public struct WindowStack: Sendable {
    /// Front to back, without invisible windows and without Clicky's own.
    public let windows: [WindowInfo]
    public let displays: [DisplayInfo]

    public init(windows rawWindows: [WindowInfo], ownProcessIdentifier: pid_t, displays: [DisplayInfo]) {
        self.windows = rawWindows.filter { $0.alpha > 0.01 && $0.processIdentifier != ownProcessIdentifier && $0.boundsCG.area > 0 }
        self.displays = displays
    }

    /// Index in front-to-back order (0 = frontmost) of a window id.
    public func zIndex(of windowID: CGWindowID) -> Int? {
        windows.firstIndex { $0.windowID == windowID }
    }

    /// True when the first app window (layers 0–19) or menu (layer 101) over
    /// `point` belongs to a different app than `processIdentifier`. Wide
    /// overlay-ish windows above layer 0 (≥ 90% of their display's width,
    /// e.g. full-screen tints) are ignored.
    public func isBehind(point: CGPoint, processIdentifier: pid_t) -> Bool {
        for window in windows where window.boundsCG.contains(point) {
            if window.layer > 0 && isNearlyFullWidth(window) { continue }
            guard window.isApplicationWindowLayer || window.layer == 101 else { continue }
            return window.processIdentifier != processIdentifier
        }
        return false
    }

    private func isNearlyFullWidth(_ window: WindowInfo) -> Bool {
        guard let display = displays.first(where: { $0.boundsCG.intersects(window.boundsCG) }) else { return false }
        return window.boundsCG.width >= 0.9 * display.boundsCG.width
    }

    /// Matches an AX window (bounds + title) to a CG window of the same app:
    /// bounds within 1 pt first, then title.
    public func matchWindow(processIdentifier: pid_t, axBoundsCG: CGRect, axTitle: String?) -> WindowInfo? {
        let sameAppWindows = windows.filter { $0.processIdentifier == processIdentifier && $0.isApplicationWindowLayer }
        if let boundsMatch = sameAppWindows.first(where: {
            abs($0.boundsCG.minX - axBoundsCG.minX) <= 1 && abs($0.boundsCG.minY - axBoundsCG.minY) <= 1
                && abs($0.boundsCG.width - axBoundsCG.width) <= 1 && abs($0.boundsCG.height - axBoundsCG.height) <= 1
        }) {
            return boundsMatch
        }
        if let axTitle, !axTitle.isEmpty {
            return sameAppWindows.first { $0.title == axTitle }
        }
        return nil
    }
}
