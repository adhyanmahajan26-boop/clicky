//
//  CursorFollowDriver.swift
//  leanring-buddy
//
//  The one loop that drives every overlay's cursor following (it replaces a
//  60 Hz Timer per screen). It ticks every frame only while the pointer
//  moves and for CursorFollowCadence.lingerSeconds after; with the pointer
//  still it falls back to a 10 Hz poll, and mouse-moved / dragged events
//  (global + local monitors, no extra permission needed) wake it to the fast
//  rate at once so following never starts late. The monitors are installed
//  only while idle: during motion the 60 Hz loop reads the pointer itself,
//  so a high-rate mouse doesn't wake the main thread per event. Subscribers (one per
//  BlueCursorView) do their own work on each tick and only write SwiftUI
//  state when a value actually changed.
//

import AppKit
import ClickyCore
import QuartzCore

@MainActor
final class CursorFollowDriver {
    static let shared = CursorFollowDriver()

    typealias Subscription = UUID

    private var subscribers: [UUID: () -> Void] = [:]
    private var subscriberOrder: [UUID] = []
    private var cadence = CursorFollowCadence(now: CACurrentMediaTime())
    private var timer: Timer?
    private var scheduledInterval: TimeInterval = 0
    private var globalMotionMonitor: Any?
    private var localMotionMonitor: Any?

    private static let motionEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    private init() {}

    var isRunning: Bool { timer != nil }
    var mode: CursorFollowCadence.Mode { cadence.mode }

    func subscribe(_ onTick: @escaping () -> Void) -> Subscription {
        let subscription = UUID()
        subscribers[subscription] = onTick
        subscriberOrder.append(subscription)
        startIfNeeded()
        return subscription
    }

    func unsubscribe(_ subscription: Subscription?) {
        guard let subscription else { return }
        subscribers[subscription] = nil
        subscriberOrder.removeAll { $0 == subscription }
        if subscribers.isEmpty { stop() }
    }

    func statusSnapshot() -> [String: Any] {
        let now = CACurrentMediaTime()
        return [
            "running": isRunning,
            "mode": cadence.mode.rawValue,
            "intervalMs": isRunning ? (scheduledInterval * 1000 * 10).rounded() / 10 : 0,
            "subscribers": subscribers.count,
            "pointerIdleSeconds": (cadence.idleSeconds(at: now) * 10).rounded() / 10,
            "motionMonitorsInstalled": globalMotionMonitor != nil
        ]
    }

    // MARK: - Loop

    private func startIfNeeded() {
        if timer == nil {
            cadence.noteMotionEvent(at: CACurrentMediaTime())
            schedule(interval: cadence.intervalSeconds)
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        setMotionMonitorsInstalled(false)
    }

    private func setMotionMonitorsInstalled(_ shouldInstall: Bool) {
        if shouldInstall {
            if globalMotionMonitor == nil {
                globalMotionMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.motionEvents) { _ in
                    MainActor.assumeIsolated { CursorFollowDriver.shared.motionEventArrived() }
                }
            }
            if localMotionMonitor == nil {
                localMotionMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.motionEvents) { event in
                    MainActor.assumeIsolated { CursorFollowDriver.shared.motionEventArrived() }
                    return event
                }
            }
        } else {
            if let globalMotionMonitor { NSEvent.removeMonitor(globalMotionMonitor) }
            if let localMotionMonitor { NSEvent.removeMonitor(localMotionMonitor) }
            globalMotionMonitor = nil
            localMotionMonitor = nil
        }
    }

    private func schedule(interval: TimeInterval) {
        setMotionMonitorsInstalled(cadence.mode == .idle)
        guard interval != scheduledInterval || timer == nil else { return }
        timer?.invalidate()
        scheduledInterval = interval
        let newTimer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { CursorFollowDriver.shared.tick() }
        }
        // The idle poll may drift a little; the fast one should not.
        newTimer.tolerance = interval == CursorFollowCadence.fastIntervalSeconds ? 0 : interval * 0.5
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func motionEventArrived() {
        guard timer != nil else { return }
        if cadence.noteMotionEvent(at: CACurrentMediaTime()) {
            schedule(interval: cadence.intervalSeconds)
            tick()
        }
    }

    private func tick() {
        OverlayPerfMonitor.shared.note(.cursorLoopTicks)
        for subscription in subscriberOrder {
            subscribers[subscription]?()
        }
        cadence.observe(pointer: NSEvent.mouseLocation, at: CACurrentMediaTime())
        schedule(interval: cadence.intervalSeconds)
    }
}
