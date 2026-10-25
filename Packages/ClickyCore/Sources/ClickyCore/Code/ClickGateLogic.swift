//
//  ClickGateLogic.swift
//  ClickyCore
//
//  The pure decision behind the review panel's approve button. Only a real
//  mouse press and release on the button, in the key panel window, with the
//  app active, approves — and only after the panel has been on screen for
//  0.5 s (no click-through from whatever was under the cursor). Actions that
//  are hard to undo need a 1.5 s hold. Events Clicky posts itself carry a tag
//  in eventSourceUserData and are always refused, so Clicky can never click
//  its own approve button. Return and voice only arm the button (5 s) —
//  they never approve. Force push and branch delete are never offered.
//

import Foundation

public enum GatedAction: String, CaseIterable, Sendable {
    case approve
    case requestChanges
    case merge
    case updateBranch
    case push
    case prCreate
    case fork
    case clone
    case reply
    case resolve
    case comment
    case edit
    case apply
    case forcePush
    case branchDelete

    /// Needs mouseUp − mouseDown ≥ ClickGateLogic.minimumHoldDuration.
    public var requiresHold: Bool {
        switch self {
        case .approve, .requestChanges, .merge, .updateBranch: return true
        default: return false
        }
    }

    public var isNeverAllowed: Bool { self == .forcePush || self == .branchDelete }
}

public struct GateInputEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case mouseDown
        case mouseUp
        case keyDown(isReturnKey: Bool)
        case voice
    }

    public var kind: Kind
    /// Seconds, same clock as panelShownAt (e.g. NSEvent.timestamp).
    public var timestamp: TimeInterval
    public var windowNumber: Int
    /// CGEvent field eventSourceUserData.
    public var eventSourceUserData: Int64
    public var isAppActive: Bool
    /// When the panel became visible (same clock).
    public var panelShownAt: TimeInterval
    /// The event's location hit-tests to the target button.
    public var isOnTargetButton: Bool

    public init(kind: Kind, timestamp: TimeInterval, windowNumber: Int, eventSourceUserData: Int64 = 0, isAppActive: Bool = true, panelShownAt: TimeInterval, isOnTargetButton: Bool = true) {
        self.kind = kind
        self.timestamp = timestamp
        self.windowNumber = windowNumber
        self.eventSourceUserData = eventSourceUserData
        self.isAppActive = isAppActive
        self.panelShownAt = panelShownAt
        self.isOnTargetButton = isOnTargetButton
    }
}

public enum ClickGateRejection: Equatable, Sendable {
    case syntheticEvent
    case wrongWindow
    case appInactive
    case notOnTargetButton
    case panelShownTooRecently(visibleFor: TimeInterval)
    case mouseUpWithoutMouseDown
    case holdTooShort(heldFor: TimeInterval)
    /// A key other than Return.
    case keyIgnored
    case actionNeverAllowed
}

public enum ClickGateDecision: Equatable, Sendable {
    /// The click is complete and valid: run the action.
    case approved
    /// A valid mouseDown; waiting for its mouseUp (show hold progress).
    case pressStarted
    /// Return or voice: highlight/focus the button until `expiresAt`; a click is still needed.
    case armed(expiresAt: TimeInterval)
    case rejected(ClickGateRejection)
}

public struct ClickGateLogic: Sendable {
    public static let minimumPanelVisibleDuration: TimeInterval = 0.5
    public static let minimumHoldDuration: TimeInterval = 1.5
    public static let armDuration: TimeInterval = 5
    /// "CLICKY" in ASCII. SyntheticEventTag in Process/ owns the canonical
    /// value; this copy only keeps the gate pure and must stay equal to it.
    private static let syntheticEventTag: Int64 = 0x434C49434B59

    public let action: GatedAction
    /// The review panel's window number (it must be the key window).
    public let panelWindowNumber: Int
    public private(set) var acceptedMouseDownTimestamp: TimeInterval?
    public private(set) var armedUntil: TimeInterval?

    public init(action: GatedAction, panelWindowNumber: Int) {
        self.action = action
        self.panelWindowNumber = panelWindowNumber
    }

    public func isArmed(at timestamp: TimeInterval) -> Bool {
        guard let armedUntil else { return false }
        return timestamp < armedUntil
    }

    public static func isSyntheticEvent(userData: Int64) -> Bool { userData == syntheticEventTag }

    public mutating func handle(_ event: GateInputEvent) -> ClickGateDecision {
        if action.isNeverAllowed { acceptedMouseDownTimestamp = nil; return .rejected(.actionNeverAllowed) }
        if Self.isSyntheticEvent(userData: event.eventSourceUserData) { acceptedMouseDownTimestamp = nil; return .rejected(.syntheticEvent) }

        switch event.kind {
        case .voice:
            return arm(at: event.timestamp)
        case .keyDown(let isReturnKey):
            guard isReturnKey else { return .rejected(.keyIgnored) }
            guard event.isAppActive, event.windowNumber == panelWindowNumber else { return .rejected(event.isAppActive ? .wrongWindow : .appInactive) }
            return arm(at: event.timestamp)
        case .mouseDown:
            acceptedMouseDownTimestamp = nil
            if let rejection = pointerRejection(for: event) { return .rejected(rejection) }
            let visibleDuration = event.timestamp - event.panelShownAt
            guard visibleDuration >= Self.minimumPanelVisibleDuration else { return .rejected(.panelShownTooRecently(visibleFor: visibleDuration)) }
            acceptedMouseDownTimestamp = event.timestamp
            return .pressStarted
        case .mouseUp:
            guard let mouseDownTimestamp = acceptedMouseDownTimestamp else { return .rejected(.mouseUpWithoutMouseDown) }
            acceptedMouseDownTimestamp = nil
            if let rejection = pointerRejection(for: event) { return .rejected(rejection) }
            let heldDuration = event.timestamp - mouseDownTimestamp
            if action.requiresHold, heldDuration < Self.minimumHoldDuration { return .rejected(.holdTooShort(heldFor: heldDuration)) }
            armedUntil = nil
            return .approved
        }
    }

    private func pointerRejection(for event: GateInputEvent) -> ClickGateRejection? {
        if !event.isAppActive { return .appInactive }
        if event.windowNumber != panelWindowNumber { return .wrongWindow }
        if !event.isOnTargetButton { return .notOnTargetButton }
        return nil
    }

    private mutating func arm(at timestamp: TimeInterval) -> ClickGateDecision {
        let expiry = timestamp + Self.armDuration
        armedUntil = expiry
        return .armed(expiresAt: expiry)
    }
}
