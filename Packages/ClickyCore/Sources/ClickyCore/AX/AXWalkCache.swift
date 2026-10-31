//
//  AXWalkCache.swift
//  ClickyCore
//
//  P6.8: the last finished walk's elements per (pid, window), so an app
//  whose windows haven't changed isn't walked again (the front app's walk
//  on key-up usually reuses the prewarm's). An AXObserver per tracked app
//  (app side, on a background run loop) turns moved / resized / destroyed /
//  focus / value notifications into `Event`s that mark entries dirty; a
//  dirty, moved, missing or old entry is a miss. Entries stored before the
//  app's observer was installed are never trusted (events may have been
//  missed), and an app without a working observer is never cached. Any
//  event for the app while a walk ran (its generation moved on) means that
//  walk is not stored either.
//  Thread-safe: events arrive on the observer thread, lookups on main.
//

import CoreGraphics
import Foundation

public struct AXWalkCacheKey: Hashable, Sendable {
    public let processIdentifier: pid_t
    public let windowID: CGWindowID

    public init(processIdentifier: pid_t, windowID: CGWindowID) {
        self.processIdentifier = processIdentifier
        self.windowID = windowID
    }
}

public final class AXWalkCache: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// The app's observer is registered: from now on changes are seen.
        case observerInstalled(pid_t)
        /// Its notifications can't be observed: never cache it.
        case observerFailed(pid_t)
        /// Something in that window changed.
        case windowChanged(pid_t, CGWindowID)
        /// Something changed and the window isn't known: the whole app.
        case applicationChanged(pid_t)
        case applicationTerminated(pid_t)
    }

    public enum Lookup: Sendable, Equatable {
        case hit([GroundingElement])
        case miss(String)

        public var elements: [GroundingElement]? {
            if case .hit(let elements) = self { return elements }
            return nil
        }
    }

    struct WindowEntry {
        let boundsCG: CGRect
        let scope: AXEnumerationRequest.Scope
        let elements: [GroundingElement]
        let storedDate: Date
        var isDirty: Bool
    }

    enum ObserverState {
        case installed
        case failed
    }

    /// Safety net for content that changes without any notification.
    public let maximumAge: TimeInterval
    private let lock = NSLock()
    private var entries: [AXWalkCacheKey: WindowEntry] = [:]
    private var observerStates: [pid_t: ObserverState] = [:]
    /// Bumped by every event for the app.
    private var generations: [pid_t: Int] = [:]

    public init(maximumAge: TimeInterval = 15) {
        self.maximumAge = maximumAge
    }

    /// Read before starting a walk; pass it back to `store`.
    public func generation(of processIdentifier: pid_t) -> Int {
        lock.lock(); defer { lock.unlock() }
        return generations[processIdentifier] ?? 0
    }

    /// Keeps a FINISHED walk's elements, per on-screen window of the app.
    /// `windowStack` is the one the walk ran against; `walkStartGeneration`
    /// is `generation(of:)` from just before it started.
    public func store(processIdentifier: pid_t, scope: AXEnumerationRequest.Scope, elements: [GroundingElement],
                      windowStack: WindowStack, walkStartGeneration: Int, at date: Date) {
        guard scope == .frontApplication || scope == .otherApplication else { return }
        let appWindows = Self.applicationWindows(of: processIdentifier, in: windowStack)
        let elementsByWindowID = Dictionary(grouping: elements.filter { $0.windowID != nil }, by: { $0.windowID! })
        lock.lock(); defer { lock.unlock() }
        guard observerStates[processIdentifier] == .installed else { return }
        entries = entries.filter { $0.key.processIdentifier != processIdentifier }
        // Something changed while it walked: the result may be stale already.
        guard (generations[processIdentifier] ?? 0) == walkStartGeneration else { return }
        for window in appWindows {
            entries[AXWalkCacheKey(processIdentifier: processIdentifier, windowID: window.windowID)] = WindowEntry(
                boundsCG: window.boundsCG, scope: scope, elements: elementsByWindowID[window.windowID] ?? [],
                storedDate: date, isDirty: false)
        }
    }

    /// The app's elements if every one of its current on-screen windows has
    /// a clean, unmoved, recent entry of the same scope. Z order and the
    /// front-window flag are recomputed from `windowStack`.
    public func lookup(processIdentifier: pid_t, scope: AXEnumerationRequest.Scope, windowStack: WindowStack, at date: Date) -> Lookup {
        let appWindows = Self.applicationWindows(of: processIdentifier, in: windowStack)
        guard !appWindows.isEmpty else { return .miss("no windows") }
        lock.lock(); defer { lock.unlock() }
        guard observerStates[processIdentifier] == .installed else { return .miss("not observed") }
        var elements: [GroundingElement] = []
        let frontWindowID = appWindows.first?.windowID
        for window in appWindows {
            guard let entry = entries[AXWalkCacheKey(processIdentifier: processIdentifier, windowID: window.windowID)] else { return .miss("new window") }
            guard entry.scope == scope else { return .miss("scope") }
            guard !entry.isDirty else { return .miss("dirty") }
            guard date.timeIntervalSince(entry.storedDate) <= maximumAge else { return .miss("expired") }
            guard Self.isSameBounds(entry.boundsCG, window.boundsCG) else { return .miss("moved") }
            let zIndex = windowStack.zIndex(of: window.windowID) ?? 0
            elements += entry.elements.map { cachedElement in
                var element = cachedElement
                element.windowZIndex = zIndex
                element.isInFrontWindow = scope == .frontApplication && window.windowID == frontWindowID
                return element
            }
        }
        return .hit(elements)
    }

    public func apply(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .observerInstalled(let processIdentifier), .observerFailed(let processIdentifier),
             .windowChanged(let processIdentifier, _), .applicationChanged(let processIdentifier):
            generations[processIdentifier, default: 0] += 1
        case .applicationTerminated(let processIdentifier):
            generations[processIdentifier] = nil
        }
        switch event {
        case .observerInstalled(let processIdentifier):
            observerStates[processIdentifier] = .installed
            // Stored before anything was listening: can't be trusted.
            markDirty { $0.processIdentifier == processIdentifier }
        case .observerFailed(let processIdentifier):
            observerStates[processIdentifier] = .failed
            entries = entries.filter { $0.key.processIdentifier != processIdentifier }
        case .windowChanged(let processIdentifier, let windowID):
            markDirty { $0.processIdentifier == processIdentifier && $0.windowID == windowID }
        case .applicationChanged(let processIdentifier):
            markDirty { $0.processIdentifier == processIdentifier }
        case .applicationTerminated(let processIdentifier):
            observerStates[processIdentifier] = nil
            entries = entries.filter { $0.key.processIdentifier != processIdentifier }
        }
    }

    /// True when the app has at least one clean entry (the observer skips
    /// resolving notifications for apps with nothing left to dirty).
    public func hasCleanEntries(processIdentifier: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.contains { $0.key.processIdentifier == processIdentifier && !$0.value.isDirty }
    }

    public func isObserved(processIdentifier: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return observerStates[processIdentifier] == .installed
    }

    /// Known to have no usable observer (don't try again).
    public func hasObserverFailed(processIdentifier: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return observerStates[processIdentifier] == .failed
    }

    public var entryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    private func markDirty(where matches: (AXWalkCacheKey) -> Bool) {
        for key in entries.keys where matches(key) { entries[key]?.isDirty = true }
    }

    static func applicationWindows(of processIdentifier: pid_t, in windowStack: WindowStack) -> [WindowInfo] {
        windowStack.windows.filter { $0.processIdentifier == processIdentifier && $0.isApplicationWindowLayer }
    }

    static func isSameBounds(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= 1 && abs(first.minY - second.minY) <= 1
            && abs(first.width - second.width) <= 1 && abs(first.height - second.height) <= 1
    }
}
