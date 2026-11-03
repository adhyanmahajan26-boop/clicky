//
//  StudioGuards.swift
//  leanring-buddy
//
//  macOS treats a virtual display as part of the owner's desktop, with no setting to keep it out. So while the hidden screens
//  exist, the owner's pointer is put straight back if it gets onto one, and any window that isn't a bot job's is moved back to
//  the main monitor. They run only while the screens are on.
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
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { StudioGuards.shared.checkWindows() }
            })
        }
        // A window can also open or move with no app change. The same list the notch already reads each second.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { StudioGuards.shared.checkWindows() }
        }
        timer.tolerance = 0.2
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
    }

    private func checkPointer() {
        guard let location = CGEvent(source: nil)?.location,
              let landing = StudioGuardRules.pointerLanding(for: location, hidden: hidden, monitors: monitors) else { return }
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
