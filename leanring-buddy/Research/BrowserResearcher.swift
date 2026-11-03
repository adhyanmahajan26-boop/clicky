//
//  BrowserResearcher.swift
//  leanring-buddy
//
//  When a plain fetch can't read a page, Clicky's Researcher reads it in the owner's own Chrome: their profile and logins,
//  in a new window on a hidden Studio screen. It opens the window, moves it to a tile, reads the text through Accessibility
//  and closes it. It never clicks, types or runs anything in the page, and never touches cookies or passwords, so a page
//  can't talk it into doing anything: the words still go to a helper with no tools, as data.
//
//  Chrome won't take a debugging port on its default profile, and starting it with arguments makes a second process (from a
//  test profile, a second, empty Chrome). So Theo asks the running Chrome for a window with an Apple Event. That permission is
//  only ever asked for from a button in Settings: research checks it silently, and without it reads pages the plain way.
//  Reading uses Accessibility, which Theo already has.
//
//  Chrome brings itself to the front when it's told to open or navigate, and nothing in Apple Events stops it. So this waits
//  until the owner has paused, and hands the front straight back. It's a blink, not nothing, and only for blocked pages.
//
//  Sites see an ordinary signed-in person because that's what the browser is. Nothing here hides anything or gets past a
//  human check: that's a card in Researcher's chat, and the page waits for the owner.
//

import AppKit
import ApplicationServices
import ClickyCore
import Combine
import Foundation
import SwiftUI

@MainActor
final class BrowserResearcher: ObservableObject {
    static let shared = BrowserResearcher()
    static let chromeBundleID = "com.google.Chrome"

    enum Outcome {
        case page(title: String?, text: String)
        /// Not read. Says why, for the run's log. The helper reports the page as unreadable, as it always did.
        case skipped(String)
    }

    /// A page waiting for a person.
    struct HumanCheck: Identifiable, Equatable {
        let id: String
        let host: String
        var isShowing = false
    }

    enum OwnerAnswer { case done, skip }

    /// May Theo ask Chrome for windows? Reading this never brings up a prompt.
    enum Permission: String { case allowed, notAsked, refused, chromeNotRunning }

    /// A window Chrome made for us.
    private struct OpenWindow {
        let chromeID: Int
        let element: UncheckedAXElement
    }

    @Published private(set) var checks: [String: HumanCheck] = [:]

    private var queue = ResearchTileQueue()
    private var waiters: [String: CheckedContinuation<StudioTileID?, Never>] = [:]
    private var answers: [String: CheckedContinuation<OwnerAnswer, Never>] = [:]
    private var windows: [String: OpenWindow] = [:]
    private var tiles: [String: StudioTileID] = [:]
    private var isOpening = false

    // Counted for tests. Never the words.
    private(set) var report: [String: Any] = [:]
    private(set) var focusSlips = 0
    private(set) var pagesOpened = 0
    private(set) var pagesClosed = 0
    private(set) var placements: [[String: Any]] = []
    var testAllowsLocalHost = false

    private init() {}

    /// When the plain fetch gets to go first, tests can skip it. Only in a test profile.
    static var alwaysForTests: Bool { TheoProfile.isTest && UserDefaults.standard.bool(forKey: "test.research.alwaysBrowser") }

    private var researcherID: String? { BotsStore.shared.teamBot(.researcher)?.id }

    /// Whether a page can be read this way right now.
    var isReady: Bool {
        StudioController.isAvailable && StudioController.shared.isOn && StudioController.shared.researchUsesBrowser
            && DeviceRoles.runsHere(.researchBrowser) && researcherID != nil && AXIsProcessTrusted() && chromeURL != nil && permission != .refused && permission != .notAsked
    }

    var permission: Permission { Self.permission(asking: false) }

    nonisolated private static func permission(asking: Bool) -> Permission {
        let target = NSAppleEventDescriptor(bundleIdentifier: chromeBundleID)
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, asking) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .refused
        case OSStatus(procNotFound): return .chromeNotRunning
        default: return .notAsked
        }
    }

    /// The Settings button, and only that: macOS asks the owner once. Chrome has to be running for it to ask.
    func askForPermission() async -> Permission {
        if chromeApp == nil { _ = await startChromeQuietly() }
        let answer = await Task.detached { Self.permission(asking: true) }.value
        objectWillChange.send()
        return answer
    }

    private var chromeURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeBundleID) }
    private var chromeApp: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundleID).first { !$0.isTerminated } }

    // MARK: Reading a page

    /// `label`: the agent's job, shown on its tile. `agent`: holds one tile across pages until `endAgent`; with none, the tile is
    /// freed after this page.
    func read(_ url: URL, label: String? = nil, agent: String? = nil) async -> Outcome {
        guard isReady, let researcherID else { return .skipped("Studio screens or my browser aren't available") }
        guard BrowserResearchPolicy.mayOpen(url, allowsLocalHostForTests: testAllowsLocalHost) else { return .skipped("not opened in your browser: it looks private") }
        let host = url.host ?? "page"
        let prefix = label.map { "\($0) · " } ?? ""
        let id = agent ?? UUID().uuidString
        guard let tile = await acquireTile(id), let frame = StudioController.shared.frame(of: tile), !Task.isCancelled else {
            finishTile(id, tile: nil)
            return .skipped(Task.isCancelled ? "cancelled" : "no tile came free")
        }
        let studio = StudioController.shared
        studio.holdForResearch(tile, botID: researcherID, note: "\(prefix)Opening \(host)", app: chromeApp)
        tiles[id] = tile
        defer {
            if agent == nil {
                finishTile(id, tile: tile)
                tiles[id] = nil
            } else {
                studio.noteResearch(tile, note: "\(prefix)Between pages", app: chromeApp)
            }
        }

        guard let window = await openWindow(url, frame: frame) else { return .skipped("Chrome didn't open a window") }
        windows[id] = window
        pagesOpened += 1
        defer {
            if windows[id] != nil { close(id) }
        }
        studio.noteResearch(tile, note: "\(prefix)Reading \(host)", app: chromeApp)
        holdPageTree()
        await BackgroundWebTree.waitUntilBuilt()
        await Self.waitForLoad(chromeID: window.chromeID)

        var page = await settledText(of: window.element)
        if page.title == nil { page.title = Self.chromeTitle(of: window.chromeID) }
        if BrowserResearchPolicy.isHumanCheck(title: page.title, text: page.text) {
            studio.noteResearch(tile, note: "\(prefix)Needs you · \(host)", app: chromeApp)
            switch await askOwner(id: id, host: host, botID: researcherID) {
            case .skip: return .skipped("human check on \(host) skipped")
            case .done:
                studio.noteResearch(tile, note: "\(prefix)Reading \(host)", app: chromeApp)
                page = await settledText(of: window.element)
                if BrowserResearchPolicy.isHumanCheck(title: page.title, text: page.text) { return .skipped("still a human check on \(host)") }
            }
        }
        guard !Task.isCancelled else { return .skipped("cancelled") }
        guard !page.text.isEmpty else { return .skipped("nothing to read") }
        return .page(title: page.title, text: page.text)
    }

    /// An agent is done: its tile goes back.
    func endAgent(_ agent: String) {
        let tile = tiles.removeValue(forKey: agent)
        queue.leave(agent)
        finishTile(agent, tile: tile)
    }

    /// Studio is going off: its windows would land on the owner's monitors, so they close first.
    func closeEverything() {
        for id in Array(windows.keys) { close(id) }
        for (id, answer) in answers { answer.resume(returning: .skip); checks[id] = nil }
        answers = [:]
    }

    // MARK: Tiles

    /// Its own screen first, then the shared browser screen.
    private var ownTiles: [StudioTileID] { researcherID.map { StudioController.shared.freeTiles(for: $0) } ?? [] }

    private func acquireTile(_ id: String) async -> StudioTileID? {
        if let tile = queue.request(id, free: ownTiles) { return tile }
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(BrowserResearchPolicy.secondsToWaitForATile * 1_000_000_000))
                guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                self.queue.leave(id)
                waiter.resume(returning: nil)
            }
        }
    }

    private func finishTile(_ id: String, tile: StudioTileID?) {
        queue.leave(id)
        queue.release(id)
        if let tile { StudioController.shared.releaseResearch(tile) }
        while let next = queue.grantNext(free: ownTiles) {
            if let waiter = waiters.removeValue(forKey: next.id) { waiter.resume(returning: next.tile) } else { queue.release(next.id) }
        }
    }

    // MARK: The window

    /// Chrome with no windows, in the background, as itself. Never from a test profile: Chrome would take that profile's
    /// home folder for its own and come up empty and signed out.
    private func startChromeQuietly() async -> Bool {
        guard !TheoProfile.isTest, let chromeURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = ["--no-startup-window"]
        guard (try? await NSWorkspace.shared.openApplication(at: chromeURL, configuration: configuration)) != nil else { return false }
        for _ in 0..<30 where chromeApp == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        return chromeApp != nil
    }

    /// A new window in the running Chrome, sent straight to the tile, with Chrome's own front window put back. One at a time.
    private func openWindow(_ url: URL, frame: NSRect) async -> OpenWindow? {
        while isOpening { try? await Task.sleep(nanoseconds: 100_000_000) }
        isOpening = true
        defer { isOpening = false }
        if chromeApp == nil, !(await startChromeQuietly()) { return nil }
        guard permission == .allowed, let app = chromeApp else { return nil }
        guard await waitForOwnerPause() else { return nil }
        let frontBefore = NSWorkspace.shared.frontmostApplication
        let handBack = handFrontBack(to: frontBefore)
        defer { NSWorkspace.shared.notificationCenter.removeObserver(handBack) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let top = Int(primaryHeight - frame.maxY), left = Int(frame.minX)
        let address = url.absoluteString.replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "\"", with: "%22")
        let script = """
        with timeout of 5 seconds
            tell application id "\(Self.chromeBundleID)"
                set frontID to missing value
                if (count of windows) > 0 then set frontID to id of window 1
                set newWindow to make new window
                set bounds of newWindow to {\(left), \(top), \(left + Int(frame.width)), \(top + Int(frame.height))}
                set URL of active tab of newWindow to "\(address)"
                if frontID is not missing value then set index of window id frontID to 1
                return id of newWindow
            end tell
        end timeout
        """
        var failure: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&failure)
        guard failure == nil, let idText = result?.stringValue ?? result.map({ String($0.int32Value) }), let chromeID = Int(idText) else {
            print("⚠️ Research: Chrome didn't make a window (\(failure?[NSAppleScript.errorNumber] ?? "?"))")
            return nil
        }
        // Chrome can get there just after the script returns.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var found: AXUIElement?
        for _ in 0..<50 {
            found = Self.windows(of: app.processIdentifier).first { Self.isWindow($0, in: frame) }
            if found != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        placements.append(["placed": found != nil, "window": found.flatMap { TypeForMeAccessibility.frameCG(of: $0) }.map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } as Any? ?? NSNull(),
                           "tile": ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]])
        guard let found else {
            Self.closeInChrome(chromeID)
            return nil
        }
        AXUIElementSetMessagingTimeout(found, 2)
        return OpenWindow(chromeID: chromeID, element: UncheckedAXElement(element: found))
    }

    /// Opening a window makes Chrome come forward, so it waits for a gap in the owner's typing and pointing. If they don't
    /// pause, the page goes unread rather than interrupt them.
    private func waitForOwnerPause() async -> Bool {
        let deadline = Date().addingTimeInterval(BrowserResearchPolicy.secondsToWaitForAPause)
        while Date() < deadline, !Task.isCancelled {
            let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            if BrowserResearchPolicy.ownerHasPaused(secondsSinceInput: seconds) { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    /// While a window opens: the moment Chrome comes forward, the front goes back to whoever had it.
    private func handFrontBack(to app: NSRunningApplication?) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard activated?.bundleIdentifier == Self.chromeBundleID, let app, app.bundleIdentifier != Self.chromeBundleID else { return }
            app.activate()
            MainActor.assumeIsolated { self?.focusSlips += 1 }
        }
    }

    private static func closeInChrome(_ chromeID: Int) {
        var failure: NSDictionary?
        _ = NSAppleScript(source: """
        with timeout of 5 seconds
            tell application id "\(chromeBundleID)" to close (every window whose id is \(chromeID))
        end timeout
        """)?.executeAndReturnError(&failure)
    }

    private static func windows(of processIdentifier: pid_t) -> [AXUIElement] {
        TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: TypeForMeAccessibility.applicationElement(processIdentifier: processIdentifier))
    }

    private static func isWindow(_ window: AXUIElement, in frame: NSRect) -> Bool {
        guard let actual = TypeForMeAccessibility.frameCG(of: window) else { return false }
        // Chrome can keep a window a pixel or two inside what it's asked for.
        return abs(actual.minX - frame.minX) < 8 && abs(actual.width - frame.width) < 8
    }

    private func close(_ id: String) {
        guard let window = windows.removeValue(forKey: id) else { return }
        Self.closeInChrome(window.chromeID)
        pagesClosed += 1
    }

    // MARK: Reading

    /// Chrome only shows a page to Accessibility with this on.
    private func holdPageTree() {
        if let app = chromeApp { BackgroundWebTree.hold(app.processIdentifier, bundleIdentifier: Self.chromeBundleID, evenInFront: true) }
    }

    /// The tab's title, from Chrome itself: a very thin page can show nothing to Accessibility. Only a question: it doesn't bring Chrome forward.
    private static func chromeTitle(of chromeID: Int) -> String? {
        var failure: NSDictionary?
        return NSAppleScript(source: """
        with timeout of 3 seconds
            tell application id "\(chromeBundleID)" to return title of active tab of (first window whose id is \(chromeID))
        end timeout
        """)?.executeAndReturnError(&failure).stringValue
    }

    private static func waitForLoad(chromeID: Int) async {
        let script = NSAppleScript(source: """
        with timeout of 3 seconds
            tell application id "\(chromeBundleID)" to return loading of active tab of (first window whose id is \(chromeID))
        end timeout
        """)
        for _ in 0..<30 {
            var failure: NSDictionary?
            let result = script?.executeAndReturnError(&failure)
            if failure != nil || result?.booleanValue == false { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Walks the page until its text stops growing: a page in a real browser arrives in pieces.
    private func settledText(of window: UncheckedAXElement) async -> (title: String?, text: String) {
        var last: (title: String?, text: String) = (nil, "")
        var steady = 0
        for _ in 0..<15 {
            if Task.isCancelled { return last }
            let current = await Self.pageText(of: window)
            steady = !current.text.isEmpty && current.text.count == last.text.count ? steady + 1 : 0
            last = current
            if steady >= 1 && current.text.count > 200 { break }
            if steady >= 3 { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return last
    }

    private static func pageText(of window: UncheckedAXElement) async -> (title: String?, text: String) {
        await Task.detached(priority: .userInitiated) {
            let walk = ArticleReader.walkArticle(window: window.element, deadline: ProcessInfo.processInfo.systemUptime + 4)
            let runs = walk.nodes.map { (text: $0.text, block: $0.blockIdentifier) }
            return (walk.title, BrowserResearchPolicy.joined(runs: runs))
        }.value
    }

    // MARK: The owner

    private func askOwner(id: String, host: String, botID: String) async -> OwnerAnswer {
        checks[id] = HumanCheck(id: id, host: host)
        var message = BotChatMessage(author: botID, text: "\(host) wants a person to check you're human. I won't try to get past it, so this page is waiting for you.")
        message.card = "browserCheck:\(id)"
        BotsStore.shared.post(message, to: botID)
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<OwnerAnswer, Never>) in
            answers[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(BrowserResearchPolicy.secondsToWaitForTheOwner * 1_000_000_000))
                self?.answer(id, with: .skip)
            }
        }
        checks[id] = nil
        return answer
    }

    func answer(_ id: String, with answer: OwnerAnswer) {
        guard let continuation = answers.removeValue(forKey: id) else { return }
        continuation.resume(returning: answer)
    }

    /// The panel's "Show on my screen" and "Send back".
    func moveWindow(on tile: StudioTileID, to frame: NSRect) {
        guard let id = tiles.first(where: { $0.value == tile })?.key, let window = windows[id]?.element else { return }
        _ = StudioController.place(window.element, in: frame)
    }

    /// The owner clicked to see it: the window comes to their monitor, in front. Only ever from that click.
    func showToOwner(_ id: String) {
        guard let window = windows[id]?.element, let screen = NSScreen.ownerScreens.first else { return }
        let area = screen.visibleFrame
        let frame = NSRect(x: area.midX - 600, y: area.midY - 400, width: 1200, height: 800)
        _ = StudioController.place(window.element, in: frame)
        checks[id]?.isShowing = true
        guard !TheoProfile.isTest else { return }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        chromeApp?.activate()
    }

    var needsOwner: Bool { !checks.isEmpty }

    static func checkID(of message: BotChatMessage) -> String? {
        guard let card = message.card, card.hasPrefix("browserCheck:") else { return nil }
        return String(card.dropFirst("browserCheck:".count))
    }

    // MARK: Test hook

    func testState() -> [String: Any] {
        var line: [String: Any] = [:]
        line["ready"] = isReady
        line["permission"] = permission.rawValue
        line["holding"] = queue.holding.count
        line["waiting"] = queue.waiting.count
        line["openWindows"] = windows.count
        line["opened"] = pagesOpened
        line["closed"] = pagesClosed
        line["focusSlips"] = focusSlips
        line["placements"] = placements
        line["checks"] = checks.values.map(\.host)
        line["chromeWindows"] = chromeApp.map { Self.windows(of: $0.processIdentifier).count } as Any? ?? NSNull()
        line["frontmost"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        return line
    }

    /// Yes or no only: is this browser signed in here? It looks for the site's own account label and never returns any of it.
    func testSignedIn(_ url: URL, accountWords: [String], signedOutWords: [String]) async -> [String: Any] {
        guard isReady, let researcherID else { return ["error": "not ready"] }
        let id = UUID().uuidString
        guard let tile = await acquireTile(id), let frame = StudioController.shared.frame(of: tile) else { return ["error": "no tile"] }
        StudioController.shared.holdForResearch(tile, botID: researcherID, note: "Checking \(url.host ?? "")", app: chromeApp)
        defer { finishTile(id, tile: tile) }
        guard let window = await openWindow(url, frame: frame) else { return ["error": "no window"] }
        windows[id] = window
        pagesOpened += 1
        defer { close(id) }
        holdPageTree()
        await BackgroundWebTree.waitUntilBuilt()
        await Self.waitForLoad(chromeID: window.chromeID)
        _ = await settledText(of: window.element)
        let labels = await Task.detached(priority: .userInitiated) { Self.labels(in: window.element.element) }.value
        let lowered = labels.map { $0.lowercased() }
        return ["host": url.host ?? "", "labelsSeen": labels.count,
                "accountLabel": accountWords.contains { word in lowered.contains { $0.contains(word) } },
                "signedOutLabel": signedOutWords.contains { word in lowered.contains { $0 == word } }]
    }

    nonisolated private static func labels(in window: AXUIElement) -> [String] {
        var labels: [String] = []
        var stack = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 6_000 {
            visited += 1
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let text = TypeForMeAccessibility.stringAttribute(attribute, of: element), !text.isEmpty, text.count < 200 { labels.append(text) }
            }
            stack.append(contentsOf: TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element))
        }
        return labels
    }
}

/// In Researcher's chat, under its message: a page wants a person.
struct BrowserCheckCard: View {
    let id: String
    @ObservedObject private var browser = BrowserResearcher.shared

    var body: some View {
        if let check = browser.checks[id] {
            HStack(spacing: 8) {
                Circle().fill(DS.Colors.accent).frame(width: 7, height: 7)
                Text("Needs you · \(check.host)").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                Spacer(minLength: 8)
                Button("Skip") { browser.answer(id, with: .skip) }.buttonStyle(.theoSecondary)
                if check.isShowing {
                    Button("Done, keep reading") { browser.answer(id, with: .done) }.buttonStyle(.theoPrimary)
                } else {
                    Button("Show me") { browser.showToOwner(id) }.buttonStyle(.theoPrimary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
            .padding(.leading, 36)
        }
    }
}

/// Settings › Studio: whether Theo may ask Chrome for windows. macOS asks only when this button is clicked.
struct ResearchBrowserPermissionRow: View {
    @ObservedObject private var browser = BrowserResearcher.shared
    @State private var isAsking = false

    var body: some View {
        switch browser.permission {
        case .allowed, .chromeNotRunning:
            SettingRow(title: "Chrome", detail: browser.permission == .allowed ? "Theo can open windows in your Chrome" : "Starts in the background when a page needs it") { EmptyView() }
        case .notAsked:
            SettingRow(title: "Let Theo open windows in Chrome", detail: "macOS asks once. Until then, research reads pages the plain way.") {
                Button(isAsking ? "Asking…" : "Allow") {
                    isAsking = true
                    Task { @MainActor in
                        _ = await browser.askForPermission()
                        isAsking = false
                    }
                }
                .buttonStyle(.theoSecondary).disabled(isAsking)
            }
        case .refused:
            SettingRow(title: "Theo isn't allowed to control Chrome", detail: "Turn on Google Chrome under Theo in Privacy & Security › Automation.") {
                Button("Open Settings") {
                    if !TheoProfile.isTest, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.theoSecondary)
            }
        }
    }
}

enum ResearchAgentSettings {
    static let countKey = "v3.research.agentsPerQuestion"
    static func roleKey(_ role: ResearchRole) -> String { "v3.research.role.\(role.rawValue)" }

    static var count: Int { UserDefaults.standard.object(forKey: countKey) as? Int ?? ResearchAgentPlan.defaultCount }
    static func isOn(_ role: ResearchRole) -> Bool { UserDefaults.standard.object(forKey: roleKey(role)) as? Bool ?? true }
    static var roles: [ResearchRole] { ResearchAgentPlan.roles(enabled: Set(ResearchRole.allCases.filter(isOn)), count: count) }
}

/// Settings › Studio: how many agents a question gets, and which jobs they can have.
struct ResearchAgentSettingsSection: View {
    @AppStorage(ResearchAgentSettings.countKey) private var count = ResearchAgentPlan.defaultCount

    var body: some View {
        TheoSection(title: "Research agents", hint: "Each question is split between agents with different jobs, one tile each. Clicky merges what they find into one brief.") {
            SettingRow(title: "Research agents per question") {
                HairlineSegments(options: ResearchAgentPlan.countRange.map { (String($0), String($0)) }, selection: Binding(get: { String(count) }, set: { count = Int($0) ?? ResearchAgentPlan.defaultCount }))
                    .frame(width: 120)
            }
            ForEach(ResearchRole.allCases) { role in
                RowDivider()
                ResearchRoleRow(role: role)
            }
        }
    }
}

private struct ResearchRoleRow: View {
    let role: ResearchRole
    @AppStorage private var isOn: Bool

    init(role: ResearchRole) {
        self.role = role
        _isOn = AppStorage(wrappedValue: true, ResearchAgentSettings.roleKey(role))
    }

    var body: some View {
        SettingRow(title: role.title, detail: role.detail) {
            Toggle(role.title, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(DS.Colors.accent)
        }
    }
}
