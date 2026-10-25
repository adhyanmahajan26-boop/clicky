//
//  MarkTracker.swift
//  leanring-buddy
//
//  Keeps live marks on their targets after they're drawn. AX-backed marks
//  follow their element: each tick reads position + size in one
//  AXUIElementCopyMultipleAttributeValues call (plus the clip frame), hides
//  the mark below 50 % visible, fades it when a moved element's label no
//  longer matches (a reused row) or the element is gone. OCR / raw marks
//  can't be followed, so they clear when their window scrolls, moves or
//  vanishes, or another app comes to the front.
//
//  Ticks run on their own serial queue: every 100 ms for 1 s after a scroll,
//  drag, key press, window frame change or a tick that saw motion, otherwise
//  every 1 s. The window list is read at 2 Hz while marks are live.
//

import AppKit
import ApplicationServices
import ClickyCore

final class MarkTracker: @unchecked Sendable {
    enum Removal: String {
        case elementGone = "element-gone"
        case labelDrifted = "label-drifted"
        case scrolled
        case appActivated = "app-activated"
        case windowMoved = "window-moved"
        case screenChanged = "screen-changed"
    }

    /// Called on the main queue.
    var onUpdate: ((UUID, CGRect, Bool) -> Void)?
    var onRemove: ((UUID, Removal) -> Void)?
    var onLog: (([String: Any]) -> Void)?

    private struct TrackedMark {
        let id: UUID
        let source: LiveScreenMarkSource
        let element: AXUIElement?
        let clipElement: AXUIElement?
        let labelElement: AXUIElement?
        let originalLabel: String?
        let windowID: CGWindowID?
        var windowFrame: CGRect?
        var lastRect: CGRect
        var isShown = true
    }

    private let queue = DispatchQueue(label: "clicky.marks.tracker", qos: .userInitiated)
    private var trackedMarks: [UUID: TrackedMark] = [:]
    private var cadence = TrackerLogic.Cadence()
    private var tickTimer: DispatchSourceTimer?
    private var windowListTimer: DispatchSourceTimer?
    private var windowFramesByID: [CGWindowID: CGRect] = [:]
    private var axCallCount = 0
    private var axCallWindowStart = Date()
    private var eventMonitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private let ownProcessIdentifier = getpid()

    // MARK: Public (main thread)

    @MainActor
    func track(_ marks: [LiveScreenMark]) {
        startEventMonitorsIfNeeded()
        let tracksAX = ClickySettings.isMarkTrackingEnabled
        queue.async { [self] in
            for mark in marks {
                let element = tracksAX ? mark.ax.map { $0.underlyingObject as! AXUIElement } : nil
                if let element { AXUIElementSetMessagingTimeout(element, 0.1) }
                trackedMarks[mark.id] = TrackedMark(
                    id: mark.id, source: mark.source, element: element,
                    clipElement: mark.clipAX.map { $0.underlyingObject as! AXUIElement },
                    labelElement: mark.labelAX.map { $0.underlyingObject as! AXUIElement },
                    originalLabel: mark.originalLabel, windowID: mark.windowID, windowFrame: mark.windowFrameCG, lastRect: mark.rectCG
                )
            }
            startTimersIfNeeded()
        }
    }

    @MainActor
    func stopAll() {
        queue.async { [self] in
            trackedMarks.removeAll()
            stopTimers()
        }
        stopEventMonitors()
    }

    @MainActor
    func stop(_ markID: UUID) {
        queue.async { [self] in
            trackedMarks[markID] = nil
            if trackedMarks.isEmpty { stopTimers() }
        }
    }

    /// Screen layout changed: OCR / raw marks are dropped (their pixels moved).
    @MainActor
    func screenParametersChanged() {
        queue.async { [self] in handleUntracked(.screenParametersChanged, removal: .screenChanged) }
    }

    // MARK: Setup on creation

    /// Finds the element's clip (nearest scroll/web area, ≤ 12 parents), the
    /// element that carries its label, that label, and the window it's in.
    static func trackingContext(for element: AXNodeReference?, rectCG: CGRect, ax: AXQuerying) -> (clip: AXNodeReference?, label: AXNodeReference?, originalLabel: String?, windowID: CGWindowID?, windowFrame: CGRect?) {
        var clipNode: AXNodeReference?
        var labelNode: AXNodeReference?
        var originalLabel: String?
        if let element {
            var currentNode: AXNodeReference? = ax.parent(of: element)
            var depth = 0
            while let node = currentNode, depth < 12, clipNode == nil {
                let role = ax.stringAttribute(kAXRoleAttribute, of: node)
                if role == kAXScrollAreaRole || role == "AXWebArea" { clipNode = node }
                currentNode = ax.parent(of: node)
                depth += 1
            }
            if let ownLabel = readLabel(of: element, ax: ax) {
                labelNode = element
                originalLabel = ownLabel
            } else if let staticText = ax.children(of: element, role: ax.stringAttribute(kAXRoleAttribute, of: element), limit: 8).first(where: { ax.stringAttribute(kAXRoleAttribute, of: $0) == kAXStaticTextRole }) {
                labelNode = staticText
                originalLabel = readLabel(of: staticText, ax: ax)
            }
        }
        let window = topmostWindow(at: rectCG.center)
        return (clipNode, labelNode, originalLabel, window?.id, window?.frame)
    }

    static func readLabel(of node: AXNodeReference, ax: AXQuerying) -> String? {
        for attributeName in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if let text = ax.stringAttribute(attributeName, of: node), !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        return nil
    }

    /// Topmost app window (layers 0–19, like WindowInfo.isApplicationWindowLayer)
    /// at a CG point that isn't Clicky's.
    static func topmostWindow(at pointCG: CGPoint) -> (id: CGWindowID, frame: CGRect)? {
        guard let windowInfos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownProcessIdentifier = getpid()
        for windowInfo in windowInfos {
            guard let layer = windowInfo[kCGWindowLayer as String] as? Int, (0..<20).contains(layer),
                  (windowInfo[kCGWindowOwnerPID as String] as? pid_t) != ownProcessIdentifier,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary), bounds.contains(pointCG),
                  let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else { continue }
            return (windowID, bounds)
        }
        return nil
    }

    // MARK: Timers (queue)

    private func startTimersIfNeeded() {
        guard !trackedMarks.isEmpty else { return }
        if windowListTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.readWindowList() }
            timer.resume()
            windowListTimer = timer
        }
        if tickTimer == nil { scheduleNextTick(after: TrackerLogic.fastInterval) }
    }

    private func stopTimers() {
        tickTimer?.cancel()
        tickTimer = nil
        windowListTimer?.cancel()
        windowListTimer = nil
    }

    private func scheduleNextTick(after interval: TimeInterval) {
        tickTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        tickTimer = timer
    }

    private func noteActivity() {
        cadence.noteActivity(at: Date())
        // Pull a slow tick in so motion is picked up within 100 ms.
        if !trackedMarks.isEmpty { scheduleNextTick(after: TrackerLogic.fastInterval) }
    }

    private func tick() {
        guard !trackedMarks.isEmpty else { stopTimers(); return }
        var sawMotion = false
        for (markID, var trackedMark) in trackedMarks {
            guard trackedMark.source == .accessibility, let element = trackedMark.element else { continue }
            guard let currentRect = readFrame(of: element) else {
                trackedMarks[markID] = nil
                emitRemove(markID, .elementGone)
                continue
            }
            let hasMoved = TrackerLogic.hasMoved(trackedMark.lastRect, currentRect)
            if hasMoved {
                sawMotion = true
                if let labelElement = trackedMark.labelElement {
                    axCallCount += 1
                    var labelValue: CFTypeRef?
                    var currentLabel: String?
                    for attributeName in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                        if AXUIElementCopyAttributeValue(labelElement, attributeName as CFString, &labelValue) == .success,
                           let text = labelValue as? String, !text.isEmpty {
                            currentLabel = text
                            break
                        }
                    }
                    if TrackerLogic.labelDrifted(original: trackedMark.originalLabel, current: currentLabel) {
                        trackedMarks[markID] = nil
                        emitRemove(markID, .labelDrifted)
                        continue
                    }
                }
            }
            let clipFrame = trackedMark.clipElement.flatMap { readFrame(of: $0) }
            let windowFrame = trackedMark.windowID.flatMap { windowFramesByID[$0] } ?? trackedMark.windowFrame
            let fraction = TrackerLogic.visibleFraction(currentRect, clip: clipFrame, window: windowFrame)
            let isShown = TrackerLogic.isShown(visibleFraction: fraction)
            if hasMoved || isShown != trackedMark.isShown {
                // A visibility change is named even when the element also moved.
                let eventName = isShown != trackedMark.isShown ? (isShown ? "show" : "hide") : "move"
                trackedMark.lastRect = currentRect
                trackedMark.isShown = isShown
                trackedMarks[markID] = trackedMark
                let callback = onUpdate
                DispatchQueue.main.async { callback?(markID, currentRect, isShown) }
                log(["event": eventName, "id": markID.uuidString,
                     "rectCG": [currentRect.minX, currentRect.minY, currentRect.width, currentRect.height],
                     "visible": (Double(fraction) * 100).rounded() / 100, "alpha": isShown ? 1 : 0])
            }
        }
        if sawMotion { cadence.noteActivity(at: Date()) }
        logAXRateIfDue()
        if !trackedMarks.isEmpty { scheduleNextTick(after: cadence.interval(at: Date())) }
    }

    /// Position + size in one AX call; nil when the element is gone.
    private func readFrame(of element: AXUIElement) -> CGRect? {
        axCallCount += 1
        var values: CFArray?
        let attributeNames = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        let error = AXUIElementCopyMultipleAttributeValues(element, attributeNames, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        if error == .invalidUIElement { return nil }
        guard error == .success, let attributeValues = values as? [AnyObject], attributeValues.count == 2 else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(attributeValues[0]) == AXValueGetTypeID(), CFGetTypeID(attributeValues[1]) == AXValueGetTypeID(),
              AXValueGetValue(attributeValues[0] as! AXValue, .cgPoint, &position),
              AXValueGetValue(attributeValues[1] as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func readWindowList() {
        guard !trackedMarks.isEmpty else { return }
        guard let windowInfos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var framesByID: [CGWindowID: CGRect] = [:]
        for windowInfo in windowInfos {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { continue }
            framesByID[windowID] = bounds
        }
        let previousFrames = windowFramesByID
        windowFramesByID = framesByID
        for (markID, trackedMark) in trackedMarks {
            guard let windowID = trackedMark.windowID else { continue }
            let newFrame = framesByID[windowID]
            let referenceFrame = previousFrames[windowID] ?? trackedMark.windowFrame
            if let newFrame, let referenceFrame, TrackerLogic.hasMoved(referenceFrame, newFrame) {
                noteActivity()
            }
            if trackedMark.source != .accessibility,
               TrackerLogic.clearsUntrackedMark(.windowChanged(windowID: windowID, newFrame: newFrame), markWindowID: windowID,
                                                markWindowFrame: trackedMark.windowFrame, ownProcessIdentifier: ownProcessIdentifier) {
                trackedMarks[markID] = nil
                emitRemove(markID, .windowMoved)
            }
        }
    }

    private func handleUntracked(_ event: TrackerLogic.UntrackedEvent, removal: Removal) {
        for (markID, trackedMark) in trackedMarks where trackedMark.source != .accessibility {
            if TrackerLogic.clearsUntrackedMark(event, markWindowID: trackedMark.windowID, markWindowFrame: trackedMark.windowFrame,
                                                ownProcessIdentifier: ownProcessIdentifier) {
                trackedMarks[markID] = nil
                emitRemove(markID, removal)
            }
        }
    }

    private func emitRemove(_ markID: UUID, _ removal: Removal) {
        let callback = onRemove
        DispatchQueue.main.async { callback?(markID, removal) }
        log(["event": "remove", "id": markID.uuidString, "reason": removal.rawValue, "alpha": 0])
        if trackedMarks.isEmpty { stopTimers() }
    }

    private func logAXRateIfDue() {
        let elapsed = Date().timeIntervalSince(axCallWindowStart)
        guard elapsed >= 5 else { return }
        log(["event": "axRate", "callsPerSecond": (Double(axCallCount) / elapsed * 10).rounded() / 10, "marks": trackedMarks.count])
        axCallCount = 0
        axCallWindowStart = Date()
    }

    private func log(_ event: [String: Any]) {
        var stampedEvent = event
        stampedEvent["t"] = (Date().timeIntervalSince1970 * 1000).rounded()
        let callback = onLog
        DispatchQueue.main.async { callback?(stampedEvent) }
    }

    // MARK: Global events (main thread)

    @MainActor
    private func startEventMonitorsIfNeeded() {
        guard eventMonitors.isEmpty else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged, .keyDown], handler: { [weak self] event in
            guard let self else { return }
            let locationCG = event.cgEvent?.location
            let isScroll = event.type == .scrollWheel
            self.queue.async {
                self.noteActivity()
                if isScroll, let locationCG {
                    self.handleUntracked(.scrollWheel(locationCG: locationCG), removal: .scrolled)
                }
            }
        }) {
            eventMonitors.append(monitor)
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let processIdentifier = application.processIdentifier
            self.queue.async {
                self.noteActivity()
                self.handleUntracked(.applicationActivated(processIdentifier: processIdentifier), removal: .appActivated)
            }
        }
    }

    @MainActor
    private func stopEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }
}
