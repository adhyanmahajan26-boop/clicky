//
//  CodeModeChipGate.swift
//  ClickyCore
//
//  The pure decision behind the small "Turn on code mode" chip. The chip
//  appears when the main brain asked for [CODEMODE:on] but the user never
//  said "code mode" (CodeModeToggle refused it). It lives in a
//  non-activating panel that never takes focus, so keys and voice never
//  reach it; only a real mouse press and release on the chip turns Code
//  mode on. Like the review panel's click gate: events Clicky posts itself
//  (SyntheticEventTag in eventSourceUserData) are refused, nothing counts
//  in the first 0.5 s after the chip appears (no click-through), the
//  release must follow an accepted press on the chip in the same window,
//  the chip expires after 15 s, and one click is spent.
//

import Foundation

public struct CodeModeChipInput: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case mouseDown
        case mouseUp
        /// Any key (Return included): never confirms.
        case key
        /// A spoken "yes": never confirms (only "turn on code mode" in speech does, through CodeModeToggle).
        case voice
    }

    public var kind: Kind
    /// Seconds, same clock as `shownAt` (NSEvent.timestamp / systemUptime).
    public var timestamp: TimeInterval
    public var windowNumber: Int
    /// CGEvent field eventSourceUserData.
    public var eventSourceUserData: Int64
    /// The event's location hit-tests to the chip button.
    public var isOnChip: Bool

    public init(kind: Kind, timestamp: TimeInterval, windowNumber: Int, eventSourceUserData: Int64 = 0, isOnChip: Bool = true) {
        self.kind = kind
        self.timestamp = timestamp
        self.windowNumber = windowNumber
        self.eventSourceUserData = eventSourceUserData
        self.isOnChip = isOnChip
    }
}

public enum CodeModeChipRejection: Equatable, Sendable {
    case syntheticEvent
    case notAMouseClick
    case wrongWindow
    case notOnChip
    case shownTooRecently
    case releaseWithoutPress
    case expired
    case alreadyUsed
}

public enum CodeModeChipDecision: Equatable, Sendable {
    case pressStarted
    /// Turn Code mode on now. At most once per chip.
    case turnOn
    case rejected(CodeModeChipRejection)
}

public struct CodeModeChipGate: Sendable {
    public static let minimumVisibleDuration: TimeInterval = 0.5
    public static let lifetime: TimeInterval = 15
    /// Same value as SyntheticEventTag / ClickGateLogic ("CLICKY" in ASCII).
    private static let syntheticEventTag: Int64 = 0x434C49434B59

    public let windowNumber: Int
    public let shownAt: TimeInterval
    public private(set) var acceptedPressTimestamp: TimeInterval?
    public private(set) var isUsed = false

    public init(windowNumber: Int, shownAt: TimeInterval) {
        self.windowNumber = windowNumber
        self.shownAt = shownAt
    }

    public func isExpired(at timestamp: TimeInterval) -> Bool { timestamp - shownAt > Self.lifetime }

    public mutating func handle(_ input: CodeModeChipInput) -> CodeModeChipDecision {
        if isUsed { return .rejected(.alreadyUsed) }
        if input.eventSourceUserData == Self.syntheticEventTag {
            acceptedPressTimestamp = nil
            return .rejected(.syntheticEvent)
        }
        switch input.kind {
        case .key, .voice:
            return .rejected(.notAMouseClick)
        case .mouseDown:
            acceptedPressTimestamp = nil
            if let rejection = pointerRejection(input) { return .rejected(rejection) }
            guard input.timestamp - shownAt >= Self.minimumVisibleDuration else { return .rejected(.shownTooRecently) }
            acceptedPressTimestamp = input.timestamp
            return .pressStarted
        case .mouseUp:
            guard acceptedPressTimestamp != nil else { return .rejected(.releaseWithoutPress) }
            acceptedPressTimestamp = nil
            if let rejection = pointerRejection(input) { return .rejected(rejection) }
            isUsed = true
            return .turnOn
        }
    }

    private func pointerRejection(_ input: CodeModeChipInput) -> CodeModeChipRejection? {
        if isExpired(at: input.timestamp) { return .expired }
        if input.windowNumber != windowNumber { return .wrongWindow }
        if !input.isOnChip { return .notOnChip }
        return nil
    }
}
