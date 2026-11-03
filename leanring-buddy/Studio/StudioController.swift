//
//  StudioController.swift
//  leanring-buddy
//
//  Studio screens: two hidden 1440×900 displays, two tiles each, on a Mac Studio only and off until the owner turns them
//  on. Nothing moves onto them except windows Theo puts there. Bots don't use them by themselves yet; this is the
//  plumbing (`open(window:…)`, `open(app:…)`) and a manual Assign menu on each tile.
//
//  Thumbnails: a tile holding a window of Theo's own draws its thumbnail from that window, which needs no permission and
//  isn't a capture. Another app's window can only be shown by capturing the hidden display. Capturing can make macOS black
//  out protected video (Netflix) the way screen recording does, and needs Screen Recording permission, so that stays
//  behind "Live capture" (default off), never asks for the permission, and only ever captures Theo's own hidden displays.
//

import AppKit
import ClickyCore
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
final class StudioController: ObservableObject {
    static let shared = StudioController()

    /// Mac Studio only. On any other Mac the feature isn't there at all.
    static let isAvailable: Bool = {
        // uiStudio's model override is for tests of the gate.
        let model = UserDefaults.standard.string(forKey: "test.studio.model").flatMap { TheoProfile.isTest ? $0 : nil } ?? StudioGate.currentModel
        return StudioGate.isMacStudio(model: model, productName: productName(whenModelIs: model))
    }()

    /// Only asked of the real machine, so a test's override isn't overruled by it.
    private static func productName(whenModelIs model: String) -> String? {
        guard model == StudioGate.currentModel else { return nil }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    enum Keys {
        static let enabled = "theo.studio.enabled"
        static let tiles = "theo.studio.tilesPerScreen"
        static let screens = "theo.studio.screens"
        static let fps = "theo.studio.previewFPS"
        static let capture = "theo.studio.liveCapture"
        static let researchBrowser = "theo.studio.researchBrowser"
    }

    @Published var panelVisible = false { didSet { refreshPreviewing() } }
    @Published private(set) var isOn = false
    @Published private(set) var displays: [VirtualDisplay] = []
    @Published private(set) var roster = StudioRoster()
    @Published private(set) var thumbnails: [StudioTileID: CGImage] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var cpuPercent: Double = 0
    @Published private(set) var memoryMB: Double = 0
    @Published private(set) var measuredFPS: Double = 0
    /// What a tile's bot is doing there, when it's a page being read.
    @Published private(set) var tileNotes: [StudioTileID: String] = [:]
    /// What each tile holds.
    private var windows: [StudioTileID: NSWindow] = [:]
    private var apps: [StudioTileID: NSRunningApplication] = [:]
    private var previewTimer: Timer?
    private var meterTimer: Timer?
    private var lastCPU: (time: Double, cpu: Double)?
    private var framesThisSecond = 0
    private var frameCountStart = Date()
    private var screensObserver: NSObjectProtocol?
    private var frameIsCapturing = false
    private var isStarting = false

    private init() {
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    // MARK: Settings

    var tilesPerScreen: Int {
        get { let value = UserDefaults.standard.integer(forKey: Keys.tiles); return value == 1 ? 1 : 2 }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.tiles)
            objectWillChange.send()
            retile()
        }
    }

    var screenCount: Int {
        get { let value = UserDefaults.standard.integer(forKey: Keys.screens); return value == 1 ? 1 : 2 }
        set {
            UserDefaults.standard.set(min(2, max(1, newValue)), forKey: Keys.screens)
            objectWillChange.send()
            guard isOn else { return }
            // Rebuilt rather than patched: a screen coming or going moves the rest.
            stop()
            start()
        }
    }

    var previewFPS: Int {
        get { let value = UserDefaults.standard.integer(forKey: Keys.fps); return value > 0 ? value : 2 }
        set {
            UserDefaults.standard.set(min(5, max(1, newValue)), forKey: Keys.fps)
            objectWillChange.send()
            refreshPreviewing(restart: true)
        }
    }

    /// Off by default: see the note at the top.
    var liveCapture: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.capture) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.capture)
            objectWillChange.send()
        }
    }

    /// On by default once Studio is on: pages a plain fetch can't read open in the owner's own browser, on a tile.
    var researchUsesBrowser: Bool {
        get { UserDefaults.standard.object(forKey: Keys.researchBrowser) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.researchBrowser)
            objectWillChange.send()
        }
    }

    /// The permission as it stands. This only looks; it can never bring up the prompt.
    var hasCapturePermission: Bool { CGPreflightScreenCaptureAccess() }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Keys.enabled) }

    func setEnabled(_ enabled: Bool) {
        guard Self.isAvailable else { return }
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        if enabled { start() } else { stop() }
    }

    /// At launch: back on if the owner left it on.
    func startIfEnabled() {
        if Self.isAvailable, isEnabled { start() }
    }

    // MARK: Displays

    /// macOS brings a new display online a moment after it's made, and slots it in beside the main one, pushing a real
    /// monitor aside. So this waits for them, then puts every real monitor back where it was and the hidden screens off
    /// at a corner, and reads the result back to be sure.
    private func start() {
        guard Self.isAvailable, !isOn, !isStarting else { return }
        isStarting = true
        problem = nil
        let realOrigins = Self.activeDisplayBounds()
        var made: [VirtualDisplay] = []
        for index in 0..<screenCount {
            guard let display = VirtualDisplay(name: "Theo Studio \(index + 1)", serial: UInt32(0x7400 + index), size: StudioLayout.screenSize) else {
                problem = "This version of macOS wouldn't make the hidden screens."
                made.forEach { $0.remove() }
                isStarting = false
                return
            }
            made.append(display)
        }
        StudioDisplays.virtualIDs = Set(made.map(\.id))
        Task { @MainActor [weak self] in
            for _ in 0..<40 {
                if made.allSatisfy({ CGDisplayBounds($0.id).width > 0 }) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self else { return }
            self.isStarting = false
            guard self.isEnabled else {
                made.forEach { $0.remove() }
                StudioDisplays.virtualIDs = []
                return
            }
            self.displays = made
            self.isOn = true
            self.place(made, realOrigins: realOrigins)
            self.roster.trim(screens: self.screenCount, tilesPerScreen: self.tilesPerScreen)
            self.refreshPreviewing()
        }
    }

    private func place(_ made: [VirtualDisplay], realOrigins: [CGDirectDisplayID: CGRect]) {
        let origins = StudioLayout.origins(forScreens: made.count, besides: Array(realOrigins.values))
        if let refusal = VirtualDisplay.arrange(made, at: origins, restoring: realOrigins.mapValues(\.origin)) {
            problem = "macOS wouldn't place the hidden screens off to the side (\(refusal))."
            return
        }
        let now = Self.activeDisplayBounds()
        let moved = realOrigins.contains { now[$0.key]?.origin != $0.value.origin }
        let hidden = made.map { CGDisplayBounds($0.id) }
        let reachable = hidden.contains { box in realOrigins.values.contains { StudioLayout.shareAnEdge($0, box) } }
        if moved {
            problem = "macOS moved one of your monitors to make room. Turn this off to put it back."
        } else if reachable {
            problem = "macOS put a hidden screen beside one of your monitors, so the pointer could wander onto it."
        }
    }

    private static func activeDisplayBounds() -> [CGDirectDisplayID: CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        var result: [CGDirectDisplayID: CGRect] = [:]
        for id in ids.prefix(Int(count)) where !StudioDisplays.virtualIDs.contains(id) { result[id] = CGDisplayBounds(id) }
        return result
    }

    private func stop() {
        guard isOn else { return }
        BrowserResearcher.shared.closeEverything()
        for tile in Array(windows.keys) { clear(tile) }
        apps = [:]
        tileNotes = [:]
        displays.forEach { $0.remove() }
        displays = []
        StudioDisplays.virtualIDs = []
        roster = StudioRoster()
        thumbnails = [:]
        isOn = false
        refreshPreviewing()
    }

    /// Theo quitting.
    func shutDown() { stop() }

    /// Screens that really exist right now, by tile, in top-left global coordinates for the meter and tests.
    func displayBounds() -> [[String: Double]] {
        displays.map {
            let box = CGDisplayBounds($0.id)
            return ["id": Double($0.id), "x": box.minX, "y": box.minY, "width": box.width, "height": box.height]
        }
    }

    // MARK: Tiles

    var allTiles: [StudioTileID] { StudioTileID.all(screens: screenCount, tilesPerScreen: tilesPerScreen) }
    var liveCount: Int { roster.bots.count }

    /// Where a tile is, in AppKit's global coordinates.
    func frame(of tile: StudioTileID) -> NSRect? {
        guard displays.indices.contains(tile.screen), let screen = displays[tile.screen].screen else { return nil }
        let local = StudioLayout.tileFrame(index: tile.tile, tilesPerScreen: tilesPerScreen, in: screen.frame.size)
        return NSRect(x: screen.frame.minX + local.minX, y: screen.frame.minY + local.minY, width: local.width, height: local.height)
    }

    /// Puts a bot on a tile with its desk: a small window of Theo's own showing what it's doing. A bot only holds one
    /// tile, so assigning it again moves it.
    func assign(botID: String, to tile: StudioTileID) {
        guard isOn, BotsStore.shared.bot(botID) != nil else { return }
        if let old = roster.tile(of: botID) { clear(old) }
        clear(tile)
        roster.assign(botID, to: tile)
        open(window: StudioDeskWindow.make(botID: botID), for: botID, into: tile)
    }

    /// The API for later: a window of Theo's own, into a tile. The tile keeps it until it's cleared.
    func open(window: NSWindow, for botID: String, into tile: StudioTileID) {
        guard isOn, let frame = frame(of: tile) else { return }
        windows[tile]?.close()
        roster.assign(botID, to: tile)
        windows[tile] = window
        window.setFrame(frame, display: false)
        // Never key, never in front of anything the owner can see: it's the only thing on that screen.
        window.orderFrontRegardless()
        refreshPreviewing()
    }

    /// The API for later: opens an app for a bot and moves its front window into a tile. Moving another app's window needs
    /// Accessibility; without it the app still opens and the answer says so. It never asks.
    @discardableResult
    func open(app url: URL, for botID: String, into tile: StudioTileID) async -> Bool {
        guard isOn, let frame = frame(of: tile) else { return false }
        roster.assign(botID, to: tile)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        guard let running = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) else { return false }
        apps[tile] = running
        guard AXIsProcessTrusted() else {
            problem = "Moving another app's window needs Accessibility, so \(running.localizedName ?? "it") stayed where it opened."
            return false
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        return Self.move(running, to: frame)
    }

    private static func move(_ app: NSRunningApplication, to frame: NSRect) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        return place(unsafeBitCast(raw, to: AXUIElement.self), in: frame)
    }

    /// Another app's window to a frame in AppKit's global coordinates.
    static func place(_ window: AXUIElement, in frame: NSRect) -> Bool {
        let top = (NSScreen.screens.first?.frame.height ?? 0) - frame.maxY
        var origin = CGPoint(x: frame.minX, y: top)
        var size = frame.size
        guard let originValue = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue) == .success
            && AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
    }

    /// Tiles nobody holds.
    var freeTiles: [StudioTileID] { allTiles.filter { roster.bots[$0] == nil } }

    /// Research takes a tile for one page. It holds no window of Theo's, so nothing here closes the browser's.
    func holdForResearch(_ tile: StudioTileID, botID: String, note: String, app: NSRunningApplication?) {
        roster.hold(botID, tile: tile)
        noteResearch(tile, note: note, app: app)
    }

    func noteResearch(_ tile: StudioTileID, note: String, app: NSRunningApplication?) {
        tileNotes[tile] = note
        apps[tile] = app
        refreshPreviewing()
    }

    func releaseResearch(_ tile: StudioTileID) {
        tileNotes[tile] = nil
        apps[tile] = nil
        thumbnails[tile] = nil
        roster.clear(tile)
    }

    func clear(_ tile: StudioTileID) {
        tileNotes[tile] = nil
        windows[tile]?.close()
        windows[tile] = nil
        apps[tile] = nil
        thumbnails[tile] = nil
        roster.clear(tile)
    }

    private func retile() {
        roster.trim(screens: screenCount, tilesPerScreen: tilesPerScreen)
        for tile in Array(windows.keys) {
            if roster.bots[tile] == nil {
                windows[tile]?.close()
                windows[tile] = nil
                thumbnails[tile] = nil
            } else if let frame = frame(of: tile) {
                windows[tile]?.setFrame(frame, display: false)
            }
        }
    }

    // MARK: Thumbnails

    /// Only while someone can see them: the panel open and the window up.
    private var shouldPreview: Bool { isOn && panelVisible }

    private func refreshPreviewing(restart: Bool = false) {
        if restart { previewTimer?.invalidate(); previewTimer = nil }
        if shouldPreview, previewTimer == nil {
            let timer = Timer(timeInterval: 1 / Double(previewFPS), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.previewTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            previewTimer = timer
            previewTick()
        } else if !shouldPreview {
            previewTimer?.invalidate()
            previewTimer = nil
            measuredFPS = 0
        }
        if panelVisible, meterTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMeter() }
            }
            RunLoop.main.add(timer, forMode: .common)
            meterTimer = timer
            updateMeter()
        } else if !panelVisible {
            meterTimer?.invalidate()
            meterTimer = nil
        }
    }

    private func previewTick() {
        for (tile, window) in windows where window.isVisible {
            if let image = Self.snapshot(of: window) { thumbnails[tile] = image }
        }
        framesThisSecond += 1
        let elapsed = Date().timeIntervalSince(frameCountStart)
        if elapsed >= 2 {
            measuredFPS = Double(framesThisSecond) / elapsed
            framesThisSecond = 0
            frameCountStart = Date()
        }
        // Another app's window on a tile, and only with Live capture on and the permission already there.
        if liveCapture, hasCapturePermission, !apps.isEmpty, !frameIsCapturing { captureAppTiles() }
    }

    /// A window of Theo's own drawn into a small image. No screen capture is involved.
    private static func snapshot(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView, view.bounds.width > 0 else { return nil }
        // A thumbnail's worth of pixels, not a whole screen's.
        let width = 360, height = Int(CGFloat(width) * view.bounds.height / view.bounds.width)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size
        return autoreleasepool {
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.cgImage
        }
    }

    private func captureAppTiles() {
        frameIsCapturing = true
        let wanted = Set(displays.map(\.id))
        let tiles = Array(apps.keys)
        Task { [weak self] in
            defer { self?.frameIsCapturing = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            for tile in tiles {
                guard let self, self.displays.indices.contains(tile.screen) else { continue }
                let id = self.displays[tile.screen].id
                // Only Theo's own hidden displays, never a real monitor.
                guard wanted.contains(id), let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                let configuration = SCStreamConfiguration()
                configuration.width = 720
                configuration.height = 450
                configuration.showsCursor = false
                let local = StudioLayout.tileFrame(index: tile.tile, tilesPerScreen: self.tilesPerScreen)
                configuration.sourceRect = local
                let filter = SCContentFilter(display: display, excludingWindows: [])
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                    self.thumbnails[tile] = image
                }
            }
        }
    }

    // MARK: The meter

    private func updateMeter() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let time = ProcessInfo.processInfo.systemUptime
        if let last = lastCPU, time > last.time { cpuPercent = (cpu - last.cpu) / (time - last.time) * 100 }
        lastCPU = (time, cpu)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        if result == KERN_SUCCESS { memoryMB = Double(info.phys_footprint) / 1_048_576 }
    }
}
