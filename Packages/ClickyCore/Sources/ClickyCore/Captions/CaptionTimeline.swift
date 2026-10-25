//
//  CaptionTimeline.swift
//  ClickyCore
//
//  How many characters of a segment the bubble shows. Only ever moves
//  forward. Exact progress (Apple's willSpeakRange) jumps straight to the
//  target; estimated progress (Qwen word timing, Apple without callbacks)
//  is approached by a 60 Hz tick in steps of ceil(gap / 3), so it catches
//  up in at most three frames (50 ms) and never jumps backwards.
//

import Foundation

public struct CaptionTimeline: Equatable, Sendable {
    public static let ticksPerSecond = 60.0
    public static let catchUpTicks = 3

    public let totalCharacters: Int
    public private(set) var revealed = 0
    public private(set) var target = 0
    private var stepSize = 0

    public init(totalCharacters: Int) {
        self.totalCharacters = totalCharacters
    }

    public var isCaughtUp: Bool { revealed >= target }
    public var isComplete: Bool { revealed >= totalCharacters }

    /// Exact progress: reveal immediately (forward only).
    public mutating func applyExact(_ spokenCharacters: Int) {
        let clamped = min(max(0, spokenCharacters), totalCharacters)
        target = max(target, clamped)
        revealed = max(revealed, clamped)
    }

    /// Estimated progress: the tick walks toward it.
    public mutating func applyEstimate(_ spokenCharacters: Int) {
        let clamped = min(max(0, spokenCharacters), totalCharacters)
        guard clamped > target else { return }
        target = clamped
        stepSize = max(1, Int((Double(target - revealed) / Double(Self.catchUpTicks)).rounded(.up)))
    }

    /// One 60 Hz frame; returns whether `revealed` changed.
    @discardableResult
    public mutating func tick() -> Bool {
        guard revealed < target else { return false }
        revealed = min(target, revealed + max(1, stepSize))
        return true
    }

    /// The segment finished playing: show all of it.
    public mutating func complete() {
        target = totalCharacters
        revealed = totalCharacters
    }
}
