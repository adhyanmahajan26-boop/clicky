//
//  AXObserverHub.swift
//  leanring-buddy
//
//  P6.8: one AXObserver per tracked app (every app whose windows were
//  walked), all on one background run-loop thread so AX IPC never touches
//  the main thread. Moved / resized / destroyed / focus / value (and a few
//  layout) notifications become AXWalkCache events: the notified element's
//  window is matched to the walked window nodes (CFEqual) to dirty just
//  that window, otherwise the whole app. Apps are dropped on terminate.
//

import AppKit
import ApplicationServices
import ClickyCore

nonisolated final class AXObserverHub: @unchecked Sendable {
    /// All must register for an app to count as observed (and be cached).
    private static let requiredNotifications: [String] = [
        kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
        kAXFocusedWindowChangedNotification, kAXValueChangedNotification
    ]
    /// Extra signals of changed content; registered when the app supports them.
    private static let optionalNotifications: [String] = [
        kAXFocusedUIElementChangedNotification, kAXWindowCreatedNotification, kAXTitleChangedNotification,
        kAXLayoutChangedNotification, kAXRowCountChangedNotification, kAXSelectedChildrenChangedNotification,
        "AXLoadComplete"
    ]
    /// These can't be pinned to one window (or the element is gone).
    private static let applicationWideNotifications: Set<String> = [
        kAXUIElementDestroyedNotification, kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification,
        kAXFocusedUIElementChangedNotification
    ]

    let cache: AXWalkCache
    private let readyLock = NSLock()
    private var observerRunLoop: CFRunLoop?
    // Touched only on the observer thread.
    private var observersByProcessIdentifier: [pid_t: AXObserver] = [:]
    private var windowNodesByProcessIdentifier: [pid_t: [CGWindowID: AXUIElement]] = [:]
    private var terminationObserver: NSObjectProtocol?

    init(cache: AXWalkCache) {
        self.cache = cache
        let readySemaphore = DispatchSemaphore(value: 0)
        let observerThread = Thread { [weak self] in
            let keepAlivePort = NSMachPort()
            RunLoop.current.add(keepAlivePort, forMode: .default)
            self?.readyLock.lock()
            self?.observerRunLoop = CFRunLoopGetCurrent()
            self?.readyLock.unlock()
            readySemaphore.signal()
            CFRunLoopRun()
        }
        observerThread.name = "clicky.ax.observers"
        observerThread.qualityOfService = .utility
        observerThread.start()
        // Thread start only (no AX work): returns in microseconds.
        _ = readySemaphore.wait(timeout: .now() + 1)

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.untrack(processIdentifier: application.processIdentifier)
        }
    }

    deinit {
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
    }

    /// Starts observing the app (once) and records its walked window nodes.
    func track(processIdentifier: pid_t, windowNodes: [CGWindowID: AXNodeReference]) {
        let windowElements = windowNodes.compactMapValues { reference -> AXUIElement? in
            CFGetTypeID(reference.underlyingObject) == AXUIElementGetTypeID() ? (reference.underlyingObject as! AXUIElement) : nil // swiftlint:disable:this force_cast
        }
        perform { [self] in
            windowNodesByProcessIdentifier[processIdentifier] = windowElements
            guard observersByProcessIdentifier[processIdentifier] == nil, !cache.hasObserverFailed(processIdentifier: processIdentifier) else { return }
            installObserver(processIdentifier: processIdentifier)
        }
    }

    func untrack(processIdentifier: pid_t) {
        cache.apply(.applicationTerminated(processIdentifier))
        perform { [self] in
            windowNodesByProcessIdentifier[processIdentifier] = nil
            guard let observer = observersByProcessIdentifier.removeValue(forKey: processIdentifier) else { return }
            if let observerRunLoop { CFRunLoopRemoveSource(observerRunLoop, AXObserverGetRunLoopSource(observer), .defaultMode) }
        }
    }

    // MARK: - Observer thread

    private func perform(_ block: @escaping () -> Void) {
        readyLock.lock()
        let runLoop = observerRunLoop
        readyLock.unlock()
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func installObserver(processIdentifier: pid_t) {
        var createdObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, notificationName, refcon in
            guard let refcon else { return }
            Unmanaged<AXObserverHub>.fromOpaque(refcon).takeUnretainedValue().handle(element: element, notification: notificationName as String)
        }
        guard AXObserverCreate(processIdentifier, callback, &createdObserver) == .success, let observer = createdObserver else {
            cache.apply(.observerFailed(processIdentifier))
            return
        }
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.25)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        func register(_ notification: String) -> Bool {
            let error = AXObserverAddNotification(observer, applicationElement, notification as CFString, refcon)
            return error == .success || error == .notificationAlreadyRegistered
        }
        let allRequiredRegistered = Self.requiredNotifications.map(register).allSatisfy { $0 }
        Self.optionalNotifications.forEach { _ = register($0) }
        guard allRequiredRegistered, let observerRunLoop else {
            cache.apply(.observerFailed(processIdentifier))
            return
        }
        CFRunLoopAddSource(observerRunLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        observersByProcessIdentifier[processIdentifier] = observer
        cache.apply(.observerInstalled(processIdentifier))
    }

    private func handle(element: AXUIElement, notification: String) {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else { return }
        // Nothing clean left for this app: no need to work out the window.
        guard cache.hasCleanEntries(processIdentifier: processIdentifier) else { return }
        if Self.applicationWideNotifications.contains(notification) {
            cache.apply(.applicationChanged(processIdentifier))
            return
        }
        guard let windowElement = window(of: element),
              let windowID = windowNodesByProcessIdentifier[processIdentifier]?.first(where: { CFEqual($0.value, windowElement) })?.key else {
            cache.apply(.applicationChanged(processIdentifier))
            return
        }
        cache.apply(.windowChanged(processIdentifier, windowID))
    }

    private func window(of element: AXUIElement) -> AXUIElement? {
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           (roleValue as? String) == kAXWindowRole {
            return element
        }
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        return (windowValue as! AXUIElement) // swiftlint:disable:this force_cast
    }
}
