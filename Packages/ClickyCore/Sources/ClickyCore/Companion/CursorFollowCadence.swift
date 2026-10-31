//
//  CursorFollowCadence.swift
//  ClickyCore
//
//  How often the overlay's cursor-follow loop needs to run. While the
//  pointer moves (and for a short linger after, so the spark's
//  rest-then-hold click target can engage) it ticks at 60 Hz; once the
//  pointer has been still for `lingerSeconds` it drops to a slow 10 Hz
//  poll, which only exists as a fallback in case a mouse-moved event is
//  missed. Pointer motion seen by an event monitor switches straight back
//  to fast, so following never starts late.
//
//  Pure value type: the app's CursorFollowDriver owns the timer.
//

import CoreGraphics
import Foundation

public struct CursorFollowCadence: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        /// Pointer moving (or just stopped): tick every frame.
        case fast
        /// Pointer still: slow fallback poll only.
        case idle
    }

    public static let fastIntervalSeconds: TimeInterval = 1.0 / 60.0
    public static let idleIntervalSeconds: TimeInterval = 0.1
    /// Longer than CompanionSparkClickTarget.restSecondsBeforeHolding (0.6 s),
    /// so the spark's hold engages on a fast tick.
    public static let lingerSeconds: TimeInterval = 1.0
    /// Pointer movement below this (points per tick) doesn't count as moving.
    public static let movementThreshold: CGFloat = 0.5

    public private(set) var mode: Mode = .fast
    public private(set) var lastMotionTime: TimeInterval
    private var lastPointerLocation: CGPoint?

    public init(now: TimeInterval) {
        lastMotionTime = now
    }

    public var intervalSeconds: TimeInterval {
        mode == .fast ? Self.fastIntervalSeconds : Self.idleIntervalSeconds
    }

    /// Called on every tick with the pointer location. Returns the mode the
    /// next tick should run in. `keepsFast` holds fast mode regardless (for
    /// anything that needs per-frame ticks without pointer motion).
    @discardableResult
    public mutating func observe(pointer: CGPoint, at now: TimeInterval, keepsFast: Bool = false) -> Mode {
        if let lastPointerLocation {
            if hypot(pointer.x - lastPointerLocation.x, pointer.y - lastPointerLocation.y) > Self.movementThreshold {
                lastMotionTime = now
            }
        } else {
            lastMotionTime = now
        }
        lastPointerLocation = pointer
        mode = (keepsFast || now - lastMotionTime < Self.lingerSeconds) ? .fast : .idle
        return mode
    }

    /// A mouse-moved / dragged event arrived. Returns true when this woke
    /// the loop from idle (the caller should reschedule at the fast rate now).
    @discardableResult
    public mutating func noteMotionEvent(at now: TimeInterval) -> Bool {
        lastMotionTime = now
        guard mode == .idle else { return false }
        mode = .fast
        return true
    }

    public func idleSeconds(at now: TimeInterval) -> TimeInterval {
        max(0, now - lastMotionTime)
    }
}

/// Counts events in a sliding time window (e.g. overlay body evaluations or
/// loop ticks per second over the last 5 s) for the perfStatus probe.
public struct SlidingEventRate: Sendable, Equatable {
    public let windowSeconds: TimeInterval
    private var timestamps: [TimeInterval] = []
    private var firstLiveIndex = 0
    public private(set) var totalCount = 0

    public init(windowSeconds: TimeInterval = 5) {
        self.windowSeconds = windowSeconds
    }

    public mutating func record(at now: TimeInterval) {
        totalCount += 1
        timestamps.append(now)
        prune(now: now)
    }

    /// Events in the last `windowSeconds`.
    public mutating func count(at now: TimeInterval) -> Int {
        prune(now: now)
        return timestamps.count - firstLiveIndex
    }

    /// Events per second over the window.
    public mutating func ratePerSecond(at now: TimeInterval) -> Double {
        Double(count(at: now)) / windowSeconds
    }

    private mutating func prune(now: TimeInterval) {
        let cutoff = now - windowSeconds
        while firstLiveIndex < timestamps.count, timestamps[firstLiveIndex] < cutoff {
            firstLiveIndex += 1
        }
        // Compact now and then so the array never grows without bound.
        if firstLiveIndex > 512, firstLiveIndex * 2 > timestamps.count {
            timestamps.removeFirst(firstLiveIndex)
            firstLiveIndex = 0
        }
    }
}
