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
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

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
        static let config = "theo.studio.config"
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
        set { if live.hoveredTile != newValue { live.hoveredTile = newValue; syncStreams() } }
    }
    /// The tile opened large in the panel.
    var expandedTile: StudioTileID? {
        get { live.expandedTile }
        set { live.expandedTile = newValue; syncStreams() }
    }
    /// What each tile's agent is reading, from the page itself. Shown when there's no picture.
    @Published private(set) var tilePages: [StudioTileID: StudioTilePage] = [:]
    /// Clicky's cursor on a tile while it does a screen job.
    @Published private(set) var tileCursors: [StudioTileID: StudioTileCursor] = [:]
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
    private var screenFilters: [CGDirectDisplayID: (SCContentFilter, CGSize)] = [:]
    private var streams: [CGDirectDisplayID: StudioScreenStream] = [:]
    private var streamSettings: [CGDirectDisplayID: (rate: Int, width: Int)] = [:]
    private static let videoTestSeconds: Double = 15
    private var videoTestUntil: Double = 0
    private var videoTestFrames = 0
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

    /// The screens as they stand.
    @Published private(set) var config = StudioController.loadConfig()
    /// The same, with what Settings has changed but not applied yet.
    @Published var draft = StudioController.loadConfig()
    @Published private(set) var isWaitingToApply = false
    @Published private(set) var measuredAfterApply: String?
    private var waitToApply: Task<Void, Never>?

    var hasStagedChanges: Bool { draft != config }
    var stagedNeedsRebuild: Bool { draft.needsRebuild(from: config) }
    var screenCount: Int { config.screens.count }

    func tiles(onScreen screen: Int) -> Int {
        config.screens.indices.contains(screen) ? config.screens[screen].tiles : 0
    }

    nonisolated private static func loadConfig() -> StudioScreensConfig {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.config), let saved = StudioScreensConfig.decoded(data) { return saved }
        return .migrated(screenCount: defaults.integer(forKey: Keys.screens), tilesPerScreen: defaults.integer(forKey: Keys.tiles),
                         previewFPS: defaults.integer(forKey: Keys.fps)) { defaults.string(forKey: Keys.owner($0)) }
    }

    private func saveConfig() {
        UserDefaults.standard.set(config.encoded(), forKey: Keys.config)
    }

    /// Who a bot belongs with. No display changes, so it holds from the bot's next job.
    func setScreen(_ choice: StudioScreenChoice, forBot botID: String) {
        config.set(choice, for: botID)
        draft.set(choice, for: botID)
        saveConfig()
    }

    func stageNewScreen() { draft.addScreen() }

    func discardDraft() {
        cancelWaitingToApply()
        draft = config
    }

    func cancelWaitingToApply() {
        waitToApply?.cancel()
        waitToApply = nil
        isWaitingToApply = false
    }

    /// `wait`: when a display has to be made again, not while anything plays or an agent is on a tile.
    func applyDraft(wait: Bool) {
        cancelWaitingToApply()
        guard wait, stagedNeedsRebuild, isOn else { return applyNow() }
        isWaitingToApply = true
        waitToApply = Task { [weak self] in
            var quietSeconds = 0
            // A change in the moment is fine when nothing's going on; otherwise a full minute of quiet.
            let needed = (await Task.detached { Self.somethingIsPlaying() }.value) || self?.liveCount != 0 ? 60 : 0
            while !Task.isCancelled, quietSeconds < needed {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let playing = await Task.detached { Self.somethingIsPlaying() }.value
                quietSeconds = playing || self?.liveCount != 0 ? 0 : quietSeconds + 1
            }
            guard !Task.isCancelled, let self else { return }
            self.isWaitingToApply = false
            self.applyNow()
        }
    }

    private func applyNow() {
        let rebuild = isOn && stagedNeedsRebuild
        config = draft
        saveConfig()
        stopStreams()
        screenFilters = [:]
        objectWillChange.send()
        if rebuild {
            // Rebuilt rather than patched: a screen coming or going moves the rest.
            stop()
            start()
        } else {
            retile()
            refreshPreviewing(restart: true)
        }
        measuredAfterApply = "Applied. Measuring…"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self else { return }
            let live = self.live
            self.measuredAfterApply = "Measured after Apply: Theo \(Int(live.cpuPercent))% CPU, \(Int(live.memoryMB)) MB memory, \(Int(live.measuredFPS)) fps. Estimated for the screens: \(StudioScreenCost.total(self.config.screens).label). macOS doesn't report graphics memory per display, so that part stays an estimate."
        }
    }

    /// For measuring, by hand: turns the screens on or off, or changes every screen's refresh.
    func setForTest(enabled: Bool?, refresh: Int?) {
        if let refresh {
            for index in draft.screens.indices { draft.screens[index].refresh = refresh }
            applyNow()
        }
        if let enabled { setEnabled(enabled) }
    }

    private func previewFPS(forScreen screen: Int) -> Int {
        config.screens.indices.contains(screen) ? config.screens[screen].previewFPS : StudioPreviewSchedule.defaultFPS
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
        for (index, spec) in config.screens.enumerated() {
            guard let display = VirtualDisplay(name: "Theo Studio \(index + 1)", serial: UInt32(0x7400 + index), size: spec.size, hiDPI: spec.hiDPI, refresh: Double(spec.refresh)) else {
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
            StudioGuards.shared.start()
            self.place(made, realOrigins: realOrigins)
            // Somewhere the pointer could reach, or that macOS refused: try again, then don't keep them.
            for _ in 0..<2 where self.problem != nil {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.problem = nil
                self.place(made, realOrigins: realOrigins)
            }
            if let trouble = self.problem {
                self.setEnabled(false)
                self.problem = trouble + " So I turned them off."
                return
            }
            self.trimRoster()
            self.refreshPreviewing()
            StudioActivity.shared.start()
        }
    }

    private func place(_ made: [VirtualDisplay], realOrigins: [CGDirectDisplayID: CGRect]) {
        let origins = StudioLayout.origins(forSizes: config.screens.prefix(made.count).map(\.size), besides: Array(realOrigins.values))
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
        StudioGuards.shared.stop()
        stopStreams()
        screenFilters = [:]
        BrowserResearcher.shared.closeEverything()
        StudioActivity.shared.stop()
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

    var allTiles: [StudioTileID] { config.allTiles }
    var liveCount: Int { roster.bots.count }

    /// Where a tile is, in AppKit's global coordinates.
    func frame(of tile: StudioTileID) -> NSRect? {
        guard displays.indices.contains(tile.screen), let screen = displays[tile.screen].screen else { return nil }
        let local = StudioLayout.tileFrame(index: tile.tile, tilesPerScreen: tiles(onScreen: tile.screen), in: screen.frame.size)
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
        refreshPreviewing(restart: true)
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

    /// Only signed-in Chrome windows and simple screen jobs go on these screens: coding runs keep their normal terminal on the
    /// owner's own monitors.
    func owner(ofScreen screen: Int) -> String? {
        config.screens.indices.contains(screen) ? config.screens[screen].owners.first : nil
    }

    func setOwner(_ botID: String?, ofScreen screen: Int) {
        guard config.screens.indices.contains(screen) else { return }
        config.screens[screen].owners = botID.map { [$0] } ?? []
        if draft.screens.indices.contains(screen) { draft.screens[screen].owners = config.screens[screen].owners }
        saveConfig()
    }

    /// Its own screen first, then the shared pool, never another bot's.
    /// For the window guard: where a job's window may sit, top-left coordinates.
    var heldTileOriginsCG: [CGPoint] {
        roster.bots.keys.compactMap { tile -> CGPoint? in
            guard displays.indices.contains(tile.screen), let frame = frame(of: tile), let screen = displays[tile.screen].screen else { return nil }
            let box = CGDisplayBounds(displays[tile.screen].id)
            return CGPoint(x: box.minX + frame.minX - screen.frame.minX, y: box.minY + screen.frame.maxY - frame.maxY)
        }
    }

    var jobProcessIDs: Set<Int32> { Set(apps.values.map(\.processIdentifier)) }

    func freeTiles(for botID: String) -> [StudioTileID] {
        config.freeTiles(for: botID, roster: roster)
    }

    /// What's on the screens, for `studioState`. No page or chat text beyond a tile's short note.
    var report: [String: Any] {
        var tiles: [String: String] = [:]
        for (tile, bot) in roster.bots { tiles["\(tile.screen + 1).\(tile.tile + 1)"] = "\(bot): \(tileNotes[tile] ?? "")" }
        return ["on": isOn, "enabled": isEnabled, "tiles": tiles, "owners": config.screens.enumerated().reduce(into: [String: String]()) { $0["\($1.offset + 1)"] = $1.element.owners.joined(separator: ",") },
                "monitorCheck": lastMonitorCheck, "problem": problem ?? "", "liveCapture": liveCapture, "panel": panelVisible,
                "pointerCatches": StudioGuards.shared.pointerCatches, "windowsMovedBack": StudioGuards.shared.windowsMovedBack, "pausedForVideo": isPausedForVideo, "liveViewPaused": liveViewPaused, "videoTestFrames": videoTestFrames, "pictures": thumbnails.count, "pages": tilePages.count]
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

    func moveCursor(on tile: StudioTileID, to point: CGPoint, clicks: Bool) {
        let clicked = (tileCursors[tile]?.clicks ?? 0) + (clicks ? 1 : 0)
        tileCursors[tile] = StudioTileCursor(point: point, clicks: clicked)
    }

    func clearCursor(on tile: StudioTileID) { tileCursors[tile] = nil }

    func isPulledOut(_ tile: StudioTileID) -> Bool { pulledOut.contains(tile) }

    func releaseResearch(_ tile: StudioTileID) {
        defer { refreshPreviewing() }
        tileCursors[tile] = nil
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

    private func trimRoster() {
        let valid = Set(allTiles)
        for tile in roster.bots.keys where !valid.contains(tile) { roster.clear(tile) }
    }

    private func retile() {
        trimRoster()
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
    private var shouldPreview: Bool { isOn && panelVisible }

    private func refreshPreviewing(restart: Bool = false) {
        if restart { previewTimer?.invalidate(); previewTimer = nil }
        if shouldPreview, previewTimer == nil {
            // The clock runs at the fastest any tile may go; each tile is only drawn when it's due.
            // Pictures arrive by themselves. This is for windows of Theo's own, and to check on video: once a second is plenty without them.
            let timer = Timer(timeInterval: windows.isEmpty ? 1 : 1 / Double(StudioPreviewSchedule.focusedFPS), repeats: true) { [weak self] _ in
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
        for (tile, window) in windows where window.isVisible && StudioPreviewSchedule.isDue(tile, last: lastFrames[tile], now: now, focused: focused, base: previewFPS(forScreen: tile.screen)) {
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
        if now - lastVideoCheck >= 1, !isCheckingVideo {
            lastVideoCheck = now
            isCheckingVideo = true
            Task.detached(priority: .utility) { [weak self] in
                let playing = Self.somethingIsPlaying()
                await MainActor.run {
                    guard let self else { return }
                    self.isCheckingVideo = false
                    self.hasVideoAnswer = true
                    if playing != self.isPausedForVideo { self.isPausedForVideo = playing }
                }
            }
        }
        if now - lastPush >= 2 { pushToOtherMac() }
        syncStreams()
    }

    /// Live pictures stop while video plays, because capturing might black the video out. The test below finds out.
    var liveViewPaused: Bool { isPausedForVideo && ProcessInfo.processInfo.systemUptime >= videoTestUntil }

    /// One short run of pictures with video playing, asked for by hand, to see whether the video survives it.
    func startVideoTest() {
        videoTestUntil = ProcessInfo.processInfo.systemUptime + Self.videoTestSeconds
        videoTestFrames = 0
    }

    private var panelCanBeSeen: Bool {
        NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && $0.occlusionState.contains(.visible) }
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
        let screens = screenCount, perScreen = config.screens.map(\.tiles).max() ?? 2, paused = isPausedForVideo, on = isOn
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

    struct UncheckedImage: @unchecked Sendable { let image: CGImage? }

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

    /// One running stream a hidden screen, cut into its tiles, while the panel can be seen and nothing's playing. A stream only
    /// delivers when the picture changes, and macOS checks its permission once. Taking separate pictures made it check on every
    /// frame, which cost about a whole core across systemstatusd, tccd and ControlCenter. Only Theo's own virtual displays are ever
    /// captured, never a monitor of the owner's. A window of Theo's on a tile is drawn without capture instead.
    private func syncStreams() {
        let wanted = isOn && liveCapture && hasVideoAnswer && !liveViewPaused && hasCapturePermission && panelCanBeSeen
        guard wanted else { return stopStreams() }
        guard !frameIsCapturing else { return }
        let focused = expandedTile ?? hoveredTile
        for (screen, display) in displays.enumerated() where StudioDisplays.virtualIDs.contains(display.id) && config.screens.indices.contains(screen) {
            let id = display.id
            let isFocused = focused?.screen == screen
            let rate = isFocused ? max(StudioPreviewSchedule.focusedFPS, previewFPS(forScreen: screen)) : NSApp.isActive ? previewFPS(forScreen: screen) : 1
            let grid = StudioLayout.grid(forTiles: tiles(onScreen: screen))
            let width = (isFocused ? 720 : 360) * grid.columns
            if streams[id] != nil, streamSettings[id]?.rate == rate, streamSettings[id]?.width == width { continue }
            frameIsCapturing = true
            streamSettings[id] = (rate, width)
            Task { [weak self] in
                defer { self?.frameIsCapturing = false }
                guard let self, let (filter, size) = await self.screenFilter(for: id) else { return }
                let configuration = SCStreamConfiguration()
                configuration.width = width
                configuration.height = Int(CGFloat(width) * size.height / size.width)
                configuration.showsCursor = false
                configuration.queueDepth = 3
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate))
                if let running = self.streams[id] {
                    await running.update(configuration)
                    return
                }
                let made = StudioScreenStream(filter: filter, configuration: configuration, onFrame: { [weak self] image in
                    let picture = UncheckedImage(image: image)
                    Task { @MainActor in self?.receive(picture.image, fromScreen: screen, display: id) }
                }, onStopped: { [weak self] in
                    Task { @MainActor in
                        self?.streams[id] = nil
                        self?.screenFilters[id] = nil
                    }
                })
                self.streams[id] = made
                if await made?.start() != true { self.streams[id] = nil }
            }
        }
    }

    private func stopStreams() {
        guard !streams.isEmpty else { return }
        let stopping = Array(streams.values)
        streams = [:]
        streamSettings = [:]
        Task { for stream in stopping { await stream.stop() } }
    }

    private func receive(_ image: CGImage?, fromScreen screen: Int, display: CGDirectDisplayID) {
        guard let image, isOn, !liveViewPaused, streams[display] != nil else { return }
        let count = tiles(onScreen: screen)
        let grid = StudioLayout.grid(forTiles: count)
        var pictures = thumbnails
        let tileWidth = image.width / grid.columns, tileHeight = image.height / grid.rows
        let now = ProcessInfo.processInfo.systemUptime
        for tile in 0..<count {
            let id = StudioTileID(screen: screen, tile: tile)
            guard windows[id] == nil else { continue }
            lastFrames[id] = now
            pictures[id] = image.cropping(to: CGRect(x: (tile % grid.columns) * tileWidth, y: (tile / grid.columns) * tileHeight, width: tileWidth, height: tileHeight))
        }
        thumbnails = pictures
        framesThisSecond += 1
        videoTestFrames += 1
    }

    /// Kept between pictures, since asking macOS for the list of displays is the slow part.
    private func screenFilter(for id: CGDirectDisplayID) async -> (SCContentFilter, CGSize)? {
        if let kept = screenFilters[id] { return kept }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let made = (SCContentFilter(display: display, excludingWindows: []), CGSize(width: display.width, height: display.height))
        screenFilters[id] = made
        return made
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
        } else if StudioScreenTask.shared.holds(tile) {
            StudioScreenTask.shared.moveWindows(on: tile, to: frame)
        } else {
            BrowserResearcher.shared.moveWindow(on: tile, to: frame)
        }
        pulledOut.insert(tile)
    }

    func sendBack(_ tile: StudioTileID) {
        guard let frame = frame(of: tile) else { return }
        if let window = windows[tile] {
            window.setFrame(frame, display: false)
        } else if StudioScreenTask.shared.holds(tile) {
            StudioScreenTask.shared.moveWindows(on: tile, to: frame)
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

/// One hidden screen's pictures, delivered as they change.
final class StudioScreenStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "theo.studio.stream", qos: .utility)
    private let onFrame: @Sendable (CGImage) -> Void
    private let onStopped: @Sendable () -> Void

    init?(filter: SCContentFilter, configuration: SCStreamConfiguration, onFrame: @escaping @Sendable (CGImage) -> Void, onStopped: @escaping @Sendable () -> Void) {
        self.onFrame = onFrame
        self.onStopped = onStopped
        super.init()
        let made = SCStream(filter: filter, configuration: configuration, delegate: self)
        guard (try? made.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)) != nil else { return nil }
        stream = made
    }

    func start() async -> Bool {
        do {
            try await stream?.startCapture()
            return stream != nil
        } catch {
            return false
        }
    }

    func stop() async { try? await stream?.stopCapture() }

    func update(_ configuration: SCStreamConfiguration) async { try? await stream?.updateConfiguration(configuration) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              (info.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)) == .complete else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        if let image { onFrame(image) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStopped() }
}
