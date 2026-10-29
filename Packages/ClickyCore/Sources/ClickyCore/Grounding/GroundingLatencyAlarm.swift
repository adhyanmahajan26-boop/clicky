//
//  GroundingLatencyAlarm.swift
//  ClickyCore
//
//  P6.8: watches key-up → grounding-ready time over the last 20 turns and
//  raises an alarm when the warm p95 passes 150 ms or the cold p95 passes
//  300 ms (P1b measured warm p95 120 / cold p95 177 ms on a quiet machine).
//  Logged as a warning and flagged in turn.json.
//

import Foundation

public struct GroundingLatencyAlarm: Sendable {
    public static let windowTurnCount = 20
    public static let warmP95LimitMilliseconds = 150.0
    public static let coldP95LimitMilliseconds = 300.0
    /// Fewer samples of a kind than this: no verdict for that kind.
    public static let minimumSampleCount = 5

    public struct Status: Sendable, Equatable {
        public let warmP95Milliseconds: Double?
        public let coldP95Milliseconds: Double?
        public let isWarmOverLimit: Bool
        public let isColdOverLimit: Bool

        public var isAlarming: Bool { isWarmOverLimit || isColdOverLimit }

        /// e.g. "warm p95 182 ms > 150" — nil when fine.
        public var warningText: String? {
            var parts: [String] = []
            if isWarmOverLimit, let warmP95Milliseconds {
                parts.append("warm p95 \(Int(warmP95Milliseconds.rounded())) ms > \(Int(GroundingLatencyAlarm.warmP95LimitMilliseconds))")
            }
            if isColdOverLimit, let coldP95Milliseconds {
                parts.append("cold p95 \(Int(coldP95Milliseconds.rounded())) ms > \(Int(GroundingLatencyAlarm.coldP95LimitMilliseconds))")
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    private var recentTurns: [(milliseconds: Double, isWarm: Bool)] = []

    public init() {}

    /// Adds one turn and returns the status over the last 20.
    @discardableResult
    public mutating func record(keyUpToReadyMilliseconds: Double, isWarm: Bool) -> Status {
        recentTurns.append((keyUpToReadyMilliseconds, isWarm))
        if recentTurns.count > Self.windowTurnCount { recentTurns.removeFirst(recentTurns.count - Self.windowTurnCount) }
        return status
    }

    public var status: Status {
        let warmSamples = recentTurns.filter(\.isWarm).map(\.milliseconds)
        let coldSamples = recentTurns.filter { !$0.isWarm }.map(\.milliseconds)
        let warmP95 = warmSamples.count >= Self.minimumSampleCount ? Self.percentile(95, of: warmSamples) : nil
        let coldP95 = coldSamples.count >= Self.minimumSampleCount ? Self.percentile(95, of: coldSamples) : nil
        return Status(warmP95Milliseconds: warmP95, coldP95Milliseconds: coldP95,
                      isWarmOverLimit: (warmP95 ?? 0) > Self.warmP95LimitMilliseconds,
                      isColdOverLimit: (coldP95 ?? 0) > Self.coldP95LimitMilliseconds)
    }

    /// Nearest-rank percentile (p in 0...100); nil for no samples.
    public static func percentile(_ percent: Double, of samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sortedSamples = samples.sorted()
        let rank = Int((percent / 100 * Double(sortedSamples.count)).rounded(.up))
        return sortedSamples[min(sortedSamples.count, max(1, rank)) - 1]
    }
}
