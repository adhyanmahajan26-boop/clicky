//
//  TypeConfirmGate.swift
//  ClickyCore
//
//  The pure decision behind the Type card's confirm. Only a real Return
//  keyDown (not auto-repeat) or a real mouse press on the Type button
//  starts a confirm, and the matching keyUp / mouseUp completes it — so
//  the key is already released when typing starts. Events Clicky posts
//  itself (SyntheticEventTag) never count. Input in the first 0.5 s after
//  the card appears (or after a first confirm) is ignored, the card
//  expires 30 s after it appeared or after any focus/app change, and one
//  confirm is one insertion: once confirmed the gate is spent. Terminals
//  need two confirms.
//

import Foundation

public struct TypeConfirmInput: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case returnKeyDown(isRepeat: Bool)
        case returnKeyUp
        case mouseDown(isOnTypeButton: Bool)
        case mouseUp(isOnTypeButton: Bool)
    }

    public var kind: Kind
    /// Seconds on the card's clock (NSEvent.timestamp / systemUptime).
    public var timestamp: TimeInterval
    /// The CGEvent's eventSourceUserData.
    public var eventSourceUserData: Int64

    public init(kind: Kind, timestamp: TimeInterval, eventSourceUserData: Int64 = 0) {
        self.kind = kind
        self.timestamp = timestamp
        self.eventSourceUserData = eventSourceUserData
    }
}

public enum TypeConfirmRejection: Equatable, Sendable {
    case syntheticEvent
    case typingNotAllowed
    case shownTooRecently
    case autoRepeat
    case releaseWithoutPress
    case notOnTypeButton
    case expired
    case alreadyConfirmed
}

public enum TypeConfirmDecision: Equatable, Sendable {
    /// A valid press; waiting for its release.
    case pressStarted
    /// First of two confirms (terminals): show "press Return again".
    case needsAnotherConfirm(remaining: Int)
    /// Insert now. Happens at most once per gate.
    case confirmed
    case rejected(TypeConfirmRejection)
}

public struct TypeConfirmGate: Sendable {
    public static let ignoreWindow: TimeInterval = 0.5
    public static let expiryInterval: TimeInterval = 30

    public enum PendingPress: Equatable, Sendable { case returnKey, mouse }

    public let isTypingAllowed: Bool
    public let requiredConfirmCount: Int
    public private(set) var shownAt: TimeInterval
    /// The 0.5 s ignore window restarts after each confirm (two quick Returns can't double-confirm).
    public private(set) var ignoreUntil: TimeInterval
    public private(set) var confirmCount = 0
    public private(set) var pendingPress: PendingPress?
    public private(set) var isInvalidated = false

    public init(shownAt: TimeInterval, isTypingAllowed: Bool, requiredConfirmCount: Int = 1) {
        self.shownAt = shownAt
        self.ignoreUntil = shownAt + Self.ignoreWindow
        self.isTypingAllowed = isTypingAllowed
        self.requiredConfirmCount = max(1, requiredConfirmCount)
    }

    public var isSpent: Bool { confirmCount >= requiredConfirmCount }

    /// 30 s after the card appeared, or once invalidated by a focus change.
    public func isExpired(at timestamp: TimeInterval) -> Bool {
        isInvalidated || timestamp - shownAt >= Self.expiryInterval
    }

    /// Focus moved to another element, or another app came forward.
    public mutating func invalidateForFocusChange() {
        isInvalidated = true
        pendingPress = nil
    }

    public mutating func handle(_ input: TypeConfirmInput) -> TypeConfirmDecision {
        if SyntheticEventTag.isTagged(userData: input.eventSourceUserData) { pendingPress = nil; return .rejected(.syntheticEvent) }
        guard isTypingAllowed else { return .rejected(.typingNotAllowed) }
        if isSpent { return .rejected(.alreadyConfirmed) }
        if isExpired(at: input.timestamp) { pendingPress = nil; return .rejected(.expired) }

        switch input.kind {
        case .returnKeyDown(let isRepeat):
            if isRepeat { return .rejected(.autoRepeat) }
            guard input.timestamp >= ignoreUntil else { pendingPress = nil; return .rejected(.shownTooRecently) }
            pendingPress = .returnKey
            return .pressStarted
        case .mouseDown(let isOnTypeButton):
            pendingPress = nil
            guard isOnTypeButton else { return .rejected(.notOnTypeButton) }
            guard input.timestamp >= ignoreUntil else { return .rejected(.shownTooRecently) }
            pendingPress = .mouse
            return .pressStarted
        case .returnKeyUp:
            guard pendingPress == .returnKey else { return .rejected(.releaseWithoutPress) }
            return completeConfirm(at: input.timestamp)
        case .mouseUp(let isOnTypeButton):
            guard pendingPress == .mouse else { return .rejected(.releaseWithoutPress) }
            guard isOnTypeButton else { pendingPress = nil; return .rejected(.notOnTypeButton) }
            return completeConfirm(at: input.timestamp)
        }
    }

    private mutating func completeConfirm(at timestamp: TimeInterval) -> TypeConfirmDecision {
        pendingPress = nil
        confirmCount += 1
        if isSpent { return .confirmed }
        ignoreUntil = timestamp + Self.ignoreWindow
        return .needsAnotherConfirm(remaining: requiredConfirmCount - confirmCount)
    }
}
