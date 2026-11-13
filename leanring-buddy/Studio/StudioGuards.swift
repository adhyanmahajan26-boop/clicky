//
//  StudioGuards.swift
//  leanring-buddy
//
//  macOS treats a virtual display as part of the owner's desktop, with no setting to keep it out. So while the hidden screens
//  exist, the owner's pointer is put straight back if it gets onto one, and any window that isn't a bot job's is moved back to
//  the main monitor. They run only while the screens are on, and on events: pointer moves, apps opening, windows opening or moving.
//

import AppKit
import ApplicationServices
import ClickyCore

@MainActor
final class StudioGuards {
    static let shared = StudioGuards()

    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var sweepTimer: Timer?
    private var appObservers: [pid_t: AXObserver] = [:]
    private var checkIsDue = false
    private(set) var pointerCatches = 0
    private(set) var windowsMovedBack = 0

    private init() {}

    private var hidden: [CGRect] { StudioController.shared.displays.map { CGDisplayBounds($0.id) } }

    private var monitors: [CGRect] {
        NSScreen.ownerScreens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayBounds($0.uint32Value) } }
    }

    func start() {
        guard mouseMonitor == nil else { return }
        // Only when the pointer moves, and only warps when it's on a hidden screen.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { _ in
            MainActor.assumeIsolated { StudioGuards.shared.checkPointer() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let launched = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    if let launched { StudioGuards.shared.watch(launched) }
                    StudioGuards.shared.windowsChanged()
                }
            })
        }
        NSWorkspace.shared.runningApplications.forEach(watch)
        // Every app says when a window opens or moves. This is only in case one doesn't.
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { StudioGuards.shared.checkWindows() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
        checkPointer()
        checkWindows()
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        sweepTimer?.invalidate()
        sweepTimer = nil
        for observer in appObservers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        appObservers = [:]
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), appObservers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { StudioGuards.shared.windowsChanged() } }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = TypeForMeAccessibility.applicationElement(processIdentifier: pid)
        for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        appObservers[pid] = observer
    }

    /// Dragging a window sends many of these: one look shortly after is enough.
    private func windowsChanged() {
        guard !checkIsDue else { return }
        checkIsDue = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self?.checkIsDue = false
            self?.checkWindows()
        }
    }

    func landing(for point: CGPoint) -> CGPoint? {
        StudioGuardRules.pointerLanding(for: point, hidden: hidden, monitors: monitors)
    }

    private func checkPointer() {
        guard let location = CGEvent(source: nil)?.location, let landing = landing(for: location) else { return }
        CGWarpMouseCursorPosition(landing)
        // A warp otherwise freezes the pointer for a moment.
        CGAssociateMouseAndMouseCursorPosition(1)
        pointerCatches += 1
    }

    private func checkWindows() {
        let studio = StudioController.shared
        let hidden = self.hidden
        guard !hidden.isEmpty, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let held = studio.heldTileOriginsCG
        let jobs = studio.jobProcessIDs
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width >= 50, frame.height >= 50,
                  StudioGuardRules.mustMoveBack(window: frame, ownerPID: pid, theoPID: getpid(), jobPIDs: jobs, heldTileOrigins: held, hidden: hidden) else { continue }
            moveBack(frame, of: pid)
        }
    }

    private func moveBack(_ frame: CGRect, of pid: pid_t) {
        let app = TypeForMeAccessibility.applicationElement(processIdentifier: pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: app).first(where: { TypeForMeAccessibility.frameCG(of: $0)?.origin == frame.origin }),
              let main = NSScreen.ownerScreens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.ownerScreens.first else { return }
        let box = CGDisplayBounds((main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID())
        var origin = CGPoint(x: box.minX + max(0, (box.width - frame.width) / 2), y: box.minY + max(40, (box.height - frame.height) / 2))
        if let value = AXValueCreate(.cgPoint, &origin), AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success {
            windowsMovedBack += 1
        }
    }
}
