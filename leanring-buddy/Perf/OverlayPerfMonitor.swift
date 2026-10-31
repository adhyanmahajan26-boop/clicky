//
//  OverlayPerfMonitor.swift
//  leanring-buddy
//
//  Cheap counters for the idle-CPU guard (debug inbox "perfStatus"): how
//  often the overlay and notch SwiftUI bodies are evaluated, how often the
//  cursor-follow loop ticks and actually writes SwiftUI state, and how often
//  the Core Animation companion is reconfigured, each as a rate over the
//  last 5 s. With the pointer still and nothing animating, every rate
//  except the 10 Hz idle loop should be ~0.
//

import ClickyCore
import Foundation
import QuartzCore

@MainActor
final class OverlayPerfMonitor {
    static let shared = OverlayPerfMonitor()

    enum Counter: String, CaseIterable {
        /// BlueCursorView.body (all screens together).
        case overlayBodyEvaluations
        /// CursorFollowDriver ticks (one per tick, however many screens).
        case cursorLoopTicks
        /// cursorPosition / isCursorOnThisScreen writes from the loop.
        case cursorStateWrites
        /// ClaudeCompanionView.updateNSView calls.
        case companionLayerUpdates
        /// NotchRootView.body.
        case notchBodyEvaluations
    }

    private var rates: [Counter: SlidingEventRate] = [:]

    private init() {
        for counter in Counter.allCases { rates[counter] = SlidingEventRate(windowSeconds: 5) }
    }

    func note(_ counter: Counter) {
        rates[counter]?.record(at: CACurrentMediaTime())
    }

    /// Rates per second over the last 5 s plus totals since launch.
    func snapshot() -> [String: Any] {
        let now = CACurrentMediaTime()
        var perSecond: [String: Double] = [:]
        var totals: [String: Int] = [:]
        for counter in Counter.allCases {
            guard var rate = rates[counter] else { continue }
            perSecond[counter.rawValue] = (rate.ratePerSecond(at: now) * 10).rounded() / 10
            totals[counter.rawValue] = rate.totalCount
            rates[counter] = rate
        }
        return ["windowSeconds": 5, "perSecond": perSecond, "totals": totals]
    }
}
