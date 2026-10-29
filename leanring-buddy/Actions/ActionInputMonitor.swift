//
//  ActionInputMonitor.swift
//  leanring-buddy
//
//  P7: while an action batch runs (and during its countdowns), any physical
//  input from the owner cancels the task. Global + local NSEvent monitors
//  feed ActionCancelLogic (ClickyCore), which ignores Clicky's own tagged
//  events and tiny mouse jitter. Installed only while armed, so nothing is
//  watched the rest of the time.
//

import AppKit
import ClickyCore

@MainActor
final class ActionInputMonitor {
    /// Called once per armed run with the reason ("you moved the mouse").
    var onPhysicalInput: (String) -> Void = { _ in }

    private var logic = ActionCancelLogic()
    private var monitors: [Any] = []

    static let watchedEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                                       .rightMouseDragged, .keyDown, .scrollWheel, .flagsChanged]

    var isArmed: Bool { logic.isArmed }

    func arm() {
        logic.arm()
        guard monitors.isEmpty else { return }
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.watchedEvents, handler: { [weak self] event in
            let physicalEvent = Self.physicalEvent(from: event)
            MainActor.assumeIsolated { self?.handle(physicalEvent) }
        }) {
            monitors.append(globalMonitor)
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.watchedEvents, handler: { [weak self] event in
            self?.handle(Self.physicalEvent(from: event))
            return event
        }) {
            monitors.append(localMonitor)
        }
    }

    func disarm() {
        logic.disarm()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    func noteSyntheticPointerEvent() {
        logic.noteSyntheticPointerEvent(at: ProcessInfo.processInfo.systemUptime)
    }

    private func handle(_ physicalEvent: PhysicalInputEvent?) {
        guard let physicalEvent else { return }
        if case .cancel(let reason) = logic.handle(physicalEvent) {
            print("🛑 Actions: physical input — \(reason)")
            onPhysicalInput(reason)
        }
    }

    nonisolated static func physicalEvent(from event: NSEvent) -> PhysicalInputEvent? {
        let kind: PhysicalInputEvent.Kind
        switch event.type {
        case .mouseMoved: kind = .mouseMoved(deltaX: event.deltaX, deltaY: event.deltaY)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        case .leftMouseDragged, .rightMouseDragged: kind = .mouseDragged
        case .keyDown: kind = .keyDown(keyCode: event.keyCode)
        case .scrollWheel: kind = .scrollWheel
        case .flagsChanged: kind = .flagsChanged
        default: return nil
        }
        return PhysicalInputEvent(kind: kind, eventSourceUserData: GateEventMapping.eventSourceUserData(of: event), timestamp: event.timestamp)
    }
}
