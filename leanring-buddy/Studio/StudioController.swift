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
import IOKit.pwr_mgt
import ScreenCaptureKit

/// What changes many times a second, apart from the controller: most of the window watches the controller, and only the panel
/// should redraw for these.
@MainActor
final class StudioLive: ObservableObject {
    @Published var thumbnails: [StudioTileID: CGImage] = [:]
    @Published var cpuPercent: Double = 0
    @Published var memoryMB: Double = 0
    @Published var measuredFPS: Double = 0
    @Published var hoveredTile: StudioTileID?
    @Published var expandedTile: StudioTileID?
}

@MainActor
final class StudioController: ObservableObject {
    let live = StudioLive()
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
        static let panelVisible = "theo.studio.panelVisible"
        static func owner(_ screen: Int) -> String { "theo.studio.owner.\(screen)" }
    }

    /// Remembered, so the panel is where it was left.
    @Published var panelVisible = UserDefaults.standard.bool(forKey: Keys.panelVisible) {
        didSet {
            UserDefaults.standard.set(panelVisible, forKey: Keys.panelVisible)
            refreshPreviewing()
        }
    }
    /// The tile the owner is hovering: it gets a faster picture.
    var hoveredTile: StudioTileID? {
        get { live.hoveredTile }
        set { if live.hoveredTile != newValue { live.hoveredTile = newValue } }
    }
    /// The tile opened large in the panel.
    var expandedTile: StudioTileID? {
        get { live.expandedTile }
        set { live.expandedTile = newValue }
    }
    /// What each tile's agent is reading, from the page itself. Shown when there's no picture.
    @Published private(set) var tilePages: [StudioTileID: StudioTilePage] = [:]
    /// Something's playing, so nothing is being captured.
    @Published private(set) var isPausedForVideo = false
    /// The Studio's panel, on a Mac that doesn't have screens of its own.
    @Published private(set) var remoteView: StudioRemoteView?
    /// Tiles whose window has been pulled onto the owner's monitor.
    @Published private(set) var pulledOut: Set<StudioTileID> = []
    @Published private(set) var isOn = false
    @Published private(set) var displays: [VirtualDisplay] = []
    @Published private(set) var roster = StudioRoster()
    private(set) var thumbnails: [StudioTileID: CGImage] {
        get { live.thumbnails }
        set { live.thumbnails = newValue }
    }
    @Published private(set) var problem: String?
    private(set) var cpuPercent: Double {
        get { live.cpuPercent }
        set { live.cpuPercent = newValue }
    }
    private(set) var memoryMB: Double {
        get { live.memoryMB }
        set { live.memoryMB = newValue }
    }
    private(set) var measuredFPS: Double {
        get { live.measuredFPS }
        set { live.measuredFPS = newValue }
    }
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
    private var lastFrames: [StudioTileID: Double] = [:]
    private var lastVideoCheck: Double = 0
    private var isCheckingVideo = false
    private var hasVideoAnswer = false
    private var lastPush: Double = 0
    private var lastPushHadTiles = false
    private var isStarting = false
    /// The owner's monitors just before Studio turned on, with the modes to put back if macOS ever changes one.
    private var monitorBaseline: [RealDisplayState] = []
    private var monitorModes: [UInt32: CGDisplayMode] = [:]
    /// What the last check of the owner's monitors found, for tests.
    private(set) var lastMonitorCheck = "none yet"

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

    /// On, and it never captures while anything's playing.
    var liveCapture: Bool {
        get { UserDefaults.standard.object(forKey: Keys.capture) as? Bool ?? true }
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
        if enabled, DeviceRoles.runsHere(.studioScreens) { start() } else { stop() }
    }

    /// At launch: back on if the owner left it on.
    func startIfEnabled() {
        if Self.isAvailable, isEnabled, DeviceRoles.runsHere(.studioScreens) { start() }
    }

    /// Settings › Devices changed where the screens belong.
    func followDeviceSetting() {
        if DeviceRoles.runsHere(.studioScreens) { startIfEnabled() } else { stop() }
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
        rememberMonitors()
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
        checkMonitors(after: "on")
        if moved {
            problem = "macOS moved one of your monitors to make room. Turn this off to put it back."
        } else if reachable {
            problem = "macOS put a hidden screen beside one of your monitors, so the pointer could wander onto it."
        }
    }

    // MARK: Leaving the owner's monitors exactly as they were

    private static func realMonitors() -> [(state: RealDisplayState, mode: CGDisplayMode)] {
        activeDisplayBounds().compactMap { id, box in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            let state = RealDisplayState(id: id, x: Int(box.minX), y: Int(box.minY), width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                                         pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate, rotation: CGDisplayRotation(id))
            return (state, mode)
        }
    }

    private func rememberMonitors() {
        let monitors = Self.realMonitors()
        monitorBaseline = monitors.map(\.state)
        monitorModes = Dictionary(uniqueKeysWithValues: monitors.map { ($0.state.id, $0.mode) })
    }

    private func monitorDifferences() -> [StudioDisplayGuard.Difference] {
        StudioDisplayGuard.differences(baseline: monitorBaseline, now: Self.realMonitors().map(\.state))
    }

    /// Compares the monitors with how they were. Anything different is logged and put back. Only ever until logout, and only
    /// what actually differs, so a monitor that's right is never touched.
    @discardableResult
    private func checkMonitors(after moment: String) -> Bool {
        let differences = monitorDifferences()
        guard !differences.isEmpty else {
            lastMonitorCheck = "\(moment): exact"
            return true
        }
        print("⚠️ Studio: monitors differ after \(moment): \(differences). Putting them back.")
        reapply(differences)
        let remaining = monitorDifferences()
        lastMonitorCheck = "\(moment): differed (\(differences.count)), \(remaining.isEmpty ? "put back" : "still \(remaining.count) off")"
        if !remaining.isEmpty {
            print("⚠️ Studio: monitors still differ after \(moment): \(remaining)")
            problem = "A monitor didn't go back to how it was. Check it in System Settings › Displays."
        }
        return remaining.isEmpty
    }

    private func reapply(_ differences: [StudioDisplayGuard.Difference]) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        for difference in differences {
            switch difference {
            case .moved(let id):
                if let before = monitorBaseline.first(where: { $0.id == id }) { CGConfigureDisplayOrigin(config, id, Int32(before.x), Int32(before.y)) }
            case .modeChanged(let id):
                if let mode = monitorModes[id] { CGConfigureDisplayWithDisplayMode(config, id, mode, nil) }
            case .rotated:
                break  // Nothing in this API can rotate a monitor. It's logged and reported.
            }
        }
        if CGCompleteDisplayConfiguration(config, .forSession) != .success { CGCancelDisplayConfiguration(config) }
    }

    /// macOS puts a monitor it moved back by itself a moment after a hidden screen goes, so this waits for that first.
    private func settleMonitors(after moment: String) {
        Task { @MainActor [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !self.isOn, !self.isStarting else { return }
                if self.monitorDifferences().isEmpty { break }
            }
            guard let self, !self.isOn, !self.isStarting else { return }
            self.checkMonitors(after: moment)
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
        settleMonitors(after: "off")
    }

    /// Theo quitting: there's no later, so it waits here for macOS to settle, then checks.
    func shutDown() {
        guard isOn else { return }
        stop()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !monitorDifferences().isEmpty { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        checkMonitors(after: "quit")
    }

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

    // MARK: Who owns each screen

    /// Both screens are for Clicky's research agents, until the owner changes it. Only signed-in Chrome windows ever go on
    /// these screens: coding runs keep their normal terminal on the owner's own monitors.
    func owner(ofScreen screen: Int) -> String? {
        if let saved = UserDefaults.standard.string(forKey: Keys.owner(screen)) { return saved.isEmpty ? nil : saved }
        return BotsStore.shared.teamBot(.researcher)?.id
    }

    func setOwner(_ botID: String?, ofScreen screen: Int) {
        UserDefaults.standard.set(botID ?? "", forKey: Keys.owner(screen))
        objectWillChange.send()
    }

    private var owners: [Int: String] {
        var result: [Int: String] = [:]
        for screen in 0..<screenCount { if let owner = owner(ofScreen: screen) { result[screen] = owner } }
        return result
    }

    /// Its own screen first, then the shared one.
    func freeTiles(for botID: String) -> [StudioTileID] {
        StudioOwnership.freeTiles(for: botID, owners: owners, roster: roster, screens: screenCount, tilesPerScreen: tilesPerScreen)
    }

    /// What's on the screens, for `studioState`. No page or chat text beyond a tile's short note.
    var report: [String: Any] {
        var tiles: [String: String] = [:]
        for (tile, bot) in roster.bots { tiles["\(tile.screen + 1).\(tile.tile + 1)"] = "\(bot): \(tileNotes[tile] ?? "")" }
        return ["on": isOn, "enabled": isEnabled, "tiles": tiles, "owners": owners.reduce(into: [String: String]()) { $0["\($1.key + 1)"] = $1.value },
                "monitorCheck": lastMonitorCheck, "problem": problem ?? "", "liveCapture": liveCapture, "panel": panelVisible,
                "pausedForVideo": isPausedForVideo, "pictures": thumbnails.count, "pages": tilePages.count]
    }

    /// Research takes a tile for one page. It holds no window of Theo's, so nothing here closes the browser's.
    func holdForResearch(_ tile: StudioTileID, botID: String, note: String, app: NSRunningApplication?) {
        roster.hold(botID, tile: tile)
        // The agents should be seen: the panel opens by itself.
        if !panelVisible { panelVisible = true }
        noteResearch(tile, note: note, app: app)
    }

    func notePage(_ page: StudioTilePage?, on tile: StudioTileID) {
        tilePages[tile] = page
    }

    func noteResearch(_ tile: StudioTileID, note: String, app: NSRunningApplication?) {
        tileNotes[tile] = note
        apps[tile] = app
        refreshPreviewing()
    }

    func releaseResearch(_ tile: StudioTileID) {
        defer { refreshPreviewing() }
        tilePages[tile] = nil
        tileNotes[tile] = nil
        apps[tile] = nil
        thumbnails[tile] = nil
        lastFrames[tile] = nil
        pulledOut.remove(tile)
        if expandedTile == tile { expandedTile = nil }
        roster.clear(tile)
        // The other Mac hears straight away that it's free.
        lastPush = 0
    }

    func clear(_ tile: StudioTileID) {
        defer { refreshPreviewing() }
        tileNotes[tile] = nil
        lastFrames[tile] = nil
        pulledOut.remove(tile)
        if expandedTile == tile { expandedTile = nil }
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
    /// With nothing on the tiles, nothing runs.
    private var shouldPreview: Bool { isOn && panelVisible && !roster.bots.isEmpty }

    private func refreshPreviewing(restart: Bool = false) {
        if restart { previewTimer?.invalidate(); previewTimer = nil }
        if shouldPreview, previewTimer == nil {
            // The clock runs at the fastest any tile may go; each tile is only drawn when it's due.
            let timer = Timer(timeInterval: 1 / Double(StudioPreviewSchedule.focusedFPS), repeats: true) { [weak self] _ in
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
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
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
        let now = ProcessInfo.processInfo.systemUptime
        let focused = expandedTile ?? hoveredTile
        var drew = false
        for (tile, window) in windows where window.isVisible && StudioPreviewSchedule.isDue(tile, last: lastFrames[tile], now: now, focused: focused, base: previewFPS) {
            if let image = Self.snapshot(of: window) {
                thumbnails[tile] = image
                lastFrames[tile] = now
                drew = true
            }
        }
        if drew { framesThisSecond += 1 }
        let elapsed = Date().timeIntervalSince(frameCountStart)
        if elapsed >= 2 {
            measuredFPS = Double(framesThisSecond) / elapsed
            framesThisSecond = 0
            frameCountStart = Date()
        }
        // Asked of macOS about once a second, off the main thread. A capture only starts once there's an answer.
        if now - lastVideoCheck >= 1, !apps.isEmpty, !isCheckingVideo {
            lastVideoCheck = now
            isCheckingVideo = true
            Task.detached(priority: .utility) { [weak self] in
                let playing = Self.somethingIsPlaying()
                await MainActor.run {
                    guard let self else { return }
                    self.isCheckingVideo = false
                    self.hasVideoAnswer = true
                    if playing != self.isPausedForVideo { self.isPausedForVideo = playing }
                    if playing { for tile in self.apps.keys { self.thumbnails[tile] = nil } }
                }
            }
        }
        if now - lastPush >= 2 { pushToOtherMac() }
        // Another app's window on a tile: with Live capture on, the permission already there, and nothing playing.
        if liveCapture, hasVideoAnswer, !isPausedForVideo, !apps.isEmpty, !frameIsCapturing, hasCapturePermission {
            let due = apps.keys.filter { StudioPreviewSchedule.isDue($0, last: lastFrames[$0], now: now, focused: focused, base: previewFPS) }
            if !due.isEmpty { captureAppTiles(due, at: now) }
        }
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

    /// Whether macOS says anything's playing right now.
    nonisolated static func somethingIsPlaying() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess, let all = unmanaged?.takeRetainedValue() as? [AnyHashable: [[String: Any]]] else {
            // Can't tell: don't risk it.
            return true
        }
        let names = all.values.flatMap { $0 }.compactMap { $0[kIOPMAssertionNameKey] as? String }
        return StudioCaptureGuard.videoIsPlaying(assertionNames: names)
    }

    // MARK: Showing the panel on the other Mac

    /// Theo's other Mac sees the same tiles: small pictures and what's being read, about once every 2 seconds, only while
    /// something's on them.
    private func pushToOtherMac() {
        guard TheoLink.shared.isConnected else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let busy = !roster.bots.isEmpty
        guard busy || lastPushHadTiles, now - lastPush >= 2 else { return }
        lastPush = now
        lastPushHadTiles = busy
        let parts = roster.bots.map { tile, bot in (tile: tile, bot: bot, note: tileNotes[tile], page: tilePages[tile], image: UncheckedImage(image: thumbnails[tile])) }
        let screens = screenCount, perScreen = tilesPerScreen, paused = isPausedForVideo, on = isOn
        // Making the pictures small is real work: not on the main thread.
        Task.detached(priority: .utility) {
            let tiles = parts.map { part in
                StudioRemoteView.Tile(screen: part.tile.screen, tile: part.tile.tile, bot: part.bot, note: part.note, page: part.page, jpeg: part.image.image.flatMap(Self.smallJPEG))
            }
            let view = StudioRemoteView(isOn: on, screens: screens, tilesPerScreen: perScreen, paused: paused, tiles: tiles)
            guard let data = try? JSONEncoder().encode(view) else { return }
            let encoded = data.base64EncodedString()
            await MainActor.run { _ = TheoLink.shared.request("studioView", ["view": encoded]) }
        }
    }

    private struct UncheckedImage: @unchecked Sendable { let image: CGImage? }

    nonisolated private static func smallJPEG(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.45])
    }

    /// From the other Mac.
    func receiveRemoteView(_ encoded: String) {
        guard !Self.isAvailable, let data = Data(base64Encoded: encoded), let view = try? JSONDecoder().decode(StudioRemoteView.self, from: data) else { return }
        remoteView = view
        if !view.tiles.isEmpty, !panelVisible { panelVisible = true }
    }

    /// Whether this Mac has a Studio panel at all: its own screens, or the other Mac's.
    static var hasPanel: Bool { isAvailable || TheoLink.shared.isPaired }

    /// One picture of each due tile's window, and of that window alone. It refuses anything not wholly on a hidden screen.
    private func captureAppTiles(_ tiles: [StudioTileID], at now: Double) {
        frameIsCapturing = true
        let hidden = displays.map { CGDisplayBounds($0.id) }
        let perScreen = tilesPerScreen
        let focused = expandedTile ?? hoveredTile
        let allowed = Set(apps.values.map(\.processIdentifier))
        Task { [weak self] in
            defer { self?.frameIsCapturing = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            for window in content.windows {
                guard let app = window.owningApplication, allowed.contains(app.processID),
                      StudioPreviewSchedule.mayCapture(window: window.frame, hiddenScreens: hidden),
                      window.frame.width > 200, window.frame.height > 200,
                      let tile = StudioPreviewSchedule.tile(of: window.frame, hiddenScreens: hidden, tilesPerScreen: perScreen), tiles.contains(tile) else { continue }
                let configuration = SCStreamConfiguration()
                let width = tile == focused ? 720 : 360
                configuration.width = width
                configuration.height = Int(CGFloat(width) * window.frame.height / window.frame.width)
                configuration.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: window)
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration), let self {
                    self.thumbnails[tile] = image
                    self.lastFrames[tile] = now
                    self.framesThisSecond += 1
                }
            }
        }
    }

    // MARK: Bringing a tile's window to the owner

    /// Pulls a tile's window onto the owner's own monitor, without taking the front from what they're doing.
    func showOnMyScreen(_ tile: StudioTileID) {
        guard isOn, let screen = NSScreen.ownerScreens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.ownerScreens.first else { return }
        let area = screen.visibleFrame
        let size = NSSize(width: min(1100, area.width - 80), height: min(800, area.height - 80))
        let frame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        if let window = windows[tile] {
            window.setFrame(frame, display: true)
            window.orderFrontRegardless()
        } else {
            BrowserResearcher.shared.moveWindow(on: tile, to: frame)
        }
        pulledOut.insert(tile)
    }

    func sendBack(_ tile: StudioTileID) {
        guard let frame = frame(of: tile) else { return }
        if let window = windows[tile] {
            window.setFrame(frame, display: false)
        } else {
            BrowserResearcher.shared.moveWindow(on: tile, to: frame)
        }
        pulledOut.remove(tile)
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
