//
//  ActionCancelLogic.swift
//  ClickyCore
//
//  P7: while Clicky executes steps (and during a countdown), ANY physical
//  input from the owner cancels the task at once — a key, a click, a
//  scroll, a modifier press (push-to-talk too), or a real mouse move.
//  Clicky's own events carry SyntheticEventTag in eventSourceUserData and
//  never cancel. Pure: the app feeds every NSEvent from its global and local
//  monitors in, with uptime timestamps.
//
//  Two allowances, both only for mouse *moves*:
//   - jitter: moves adding up to ≤ 3 pt since arming are ignored (a desk
//     bump, sensor noise);
//   - the cursor jump of Clicky's own click: an untagged move within
//     0.15 s of a tagged pointer event Clicky just posted is ignored
//     (WindowServer can emit one for the warp). Keys and clicks are never
//     excused.
//   - after the owner's click on the confirm card: moves until the given
//     uptime are ignored (`arm(excusingMouseMovesUntilUptime:)`), since the
//     hand is still on the mouse; it used to cancel the very step he had
//     just said yes to ("confirmed by click", then "you moved the mouse").
//  While disarmed (idle, waiting for Claude, waiting for the owner's yes)
//  nothing cancels: the owner's click on the confirm card is his answer.
//

import CoreGraphics
import Foundation

public struct PhysicalInputEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case mouseMoved(deltaX: CGFloat, deltaY: CGFloat)
        case mouseDown
        case mouseDragged
        case scrollWheel
        case keyDown(keyCode: UInt16)
        case flagsChanged
    }

    public var kind: Kind
    public var eventSourceUserData: Int64
    /// Seconds (systemUptime, NSEvent.timestamp's clock).
    public var timestamp: TimeInterval

    public init(kind: Kind, eventSourceUserData: Int64 = 0, timestamp: TimeInterval) {
        self.kind = kind
        self.eventSourceUserData = eventSourceUserData
        self.timestamp = timestamp
    }
}

public enum ActionCancelDecision: Equatable, Sendable {
    case ignore
    case cancel(reason: String)
}

public struct ActionCancelLogic: Equatable, Sendable {
    public static let mouseJitterTolerance: CGFloat = 3
    /// While Vello works on a call the owner's hand often rests on the trackpad: a brush of it moved the pointer a few
    /// points and stopped the work ("you moved the mouse" ended seven tasks on the Air). Only a real move counts then.
    public static let handsFreeMouseTolerance: CGFloat = 80
    public static let syntheticPointerGraceSeconds: TimeInterval = 0.15

    public private(set) var isArmed = false
    public private(set) var accumulatedMouseDistance: CGFloat = 0
    /// How far the mouse may move before it counts as the owner taking over.
    public private(set) var mouseTolerance: CGFloat = ActionCancelLogic.mouseJitterTolerance
    private var lastSyntheticPointerEventTime: TimeInterval?
    /// Mouse moves before this uptime don't cancel (right after a click on the confirm card).
    private var mouseMovesExcusedUntilUptime: TimeInterval?
    /// Once cancelled, stays cancelled until re-armed (one cancel per run).
    public private(set) var hasCancelled = false

    public init() {}

    public mutating func arm(excusingMouseMovesUntilUptime: TimeInterval? = nil, mouseTolerance: CGFloat = ActionCancelLogic.mouseJitterTolerance) {
        isArmed = true
        self.mouseTolerance = mouseTolerance
        accumulatedMouseDistance = 0
        hasCancelled = false
        mouseMovesExcusedUntilUptime = excusingMouseMovesUntilUptime
    }

    public mutating func disarm() {
        isArmed = false
        accumulatedMouseDistance = 0
    }

    /// Clicky just posted a tagged pointer event (its cursor may warp).
    public mutating func noteSyntheticPointerEvent(at timestamp: TimeInterval) {
        lastSyntheticPointerEventTime = timestamp
    }

    public mutating func handle(_ event: PhysicalInputEvent) -> ActionCancelDecision {
        guard isArmed, !hasCancelled else { return .ignore }
        if SyntheticEventTag.isTagged(userData: event.eventSourceUserData) {
            if case .mouseMoved = event.kind { lastSyntheticPointerEventTime = event.timestamp }
            if case .mouseDown = event.kind { lastSyntheticPointerEventTime = event.timestamp }
            return .ignore
        }
        let reason: String
        switch event.kind {
        case .mouseMoved(let deltaX, let deltaY):
            if let lastSyntheticPointerEventTime, event.timestamp - lastSyntheticPointerEventTime <= Self.syntheticPointerGraceSeconds,
               event.timestamp >= lastSyntheticPointerEventTime {
                return .ignore
            }
            if let mouseMovesExcusedUntilUptime, event.timestamp < mouseMovesExcusedUntilUptime { return .ignore }
            accumulatedMouseDistance += hypot(deltaX, deltaY)
            guard accumulatedMouseDistance > mouseTolerance else { return .ignore }
            reason = "you moved the mouse"
        case .mouseDown: reason = "you clicked"
        case .mouseDragged: reason = "you dragged the mouse"
        case .scrollWheel: reason = "you scrolled"
        case .keyDown(let keyCode): reason = keyCode == 53 ? "you pressed Escape" : "you pressed a key"
        case .flagsChanged: reason = "you pressed a modifier key"
        }
        hasCancelled = true
        return .cancel(reason: reason)
    }
}
