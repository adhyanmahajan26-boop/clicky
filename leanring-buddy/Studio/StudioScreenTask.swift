//
//  StudioScreenTask.swift
//  leanring-buddy
//
//  A screen job a bot hands out runs on a hidden tile: the app's window goes there and Clicky works it through accessibility
//  actions alone, with a cursor drawn on the tile. No real pointer, no keys, no clipboard. If an app won't take that, or takes
//  the front, the job stops and says so. Clicky on the owner's real screen is only for what the owner asks it themself.
//

import AppKit
import ApplicationServices
import ClickyCore

struct StudioScreenTaskResult {
    let finished: Bool
    let report: String
}

@MainActor
final class StudioScreenTask {
    static let shared = StudioScreenTask()

    private static let maximumSteps = 20
    /// How long the result stays up on the tile.
    private static let lingerSeconds: UInt64 = 30
    private static let tileWaitSeconds = 45
    private static let maximumElements = 150

    private final class Job {
        let task: String
        let tile: StudioTileID
        var app: NSRunningApplication?
        var openedHere = false
        var ownersWindows: Set<AXUIElement> = []
        var moved: [(window: AXUIElement, frame: CGRect)] = []
        var elements: [AXUIElement] = []
        var history: [String] = []
        var lastStepFailed = false
        init(task: String, tile: StudioTileID) { self.task = task; self.tile = tile }
    }

    private var jobs: [StudioTileID: Job] = [:]

    private init() {}

    func run(_ task: String, bot: NativeBot, onDone: @escaping (StudioScreenTaskResult) -> Void) {
        Task { @MainActor in
            guard AXIsProcessTrusted() else {
                onDone(StudioScreenTaskResult(finished: false, report: "I couldn't do that on the hidden screen: Theo doesn't have Accessibility here. Nothing was done."))
                return
            }
            guard StudioController.shared.config.choice(for: bot.id) != .none else {
                onDone(StudioScreenTaskResult(finished: false, report: "I couldn't do that: I'm set to have no screen. Addy can change that in my settings. Nothing was done."))
                return
            }
            guard let tile = await claimTile(for: bot) else {
                onDone(StudioScreenTaskResult(finished: false, report: "I couldn't do that: every tile I may use stayed busy. Nothing was done."))
                return
            }
            let job = Job(task: task, tile: tile)
            jobs[tile] = job
            let studio = StudioController.shared
            studio.holdForResearch(tile, botID: bot.id, note: "Clicky: \(task)", app: nil)
            let result = await work(job)
            studio.noteResearch(tile, note: (result.finished ? "Done: " : "Couldn't: ") + result.report, app: job.app)
            studio.clearCursor(on: tile)
            onDone(result)
            try? await Task.sleep(nanoseconds: (job.moved.isEmpty ? 8 : Self.lingerSeconds) * 1_000_000_000)
            finish(job)
        }
    }

    private func claimTile(for bot: NativeBot) async -> StudioTileID? {
        let studio = StudioController.shared
        if let desk = StudioActivity.shared.takeDesk(of: bot.id) { return desk }
        for _ in 0..<Self.tileWaitSeconds {
            guard studio.isOn else { return nil }
            if let tile = studio.freeTiles(for: bot.id).first { return tile }
            StudioActivity.shared.makeRoomForResearch()
            if let tile = studio.freeTiles(for: bot.id).first { return tile }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return nil
    }

    // MARK: The steps

    private func work(_ job: Job) async -> StudioScreenTaskResult {
        for _ in 0..<Self.maximumSteps {
            guard StudioController.shared.isOn else { return stopped(job, "the hidden screens went off") }
            takeNewWindows(job)
            let window = readWindows(job)
            let menus = job.app.map { menuLines(of: $0.processIdentifier) } ?? []
            let prompt = ScreenTaskPolicy.prompt(job: job.task, history: job.history, window: window, menus: menus)
            guard let step = await nextStep(prompt: prompt) else { return stopped(job, "Clicky's helper didn't give a step it could use") }
            switch step {
            case .done(let say):
                if job.history.isEmpty || job.lastStepFailed { return stopped(job, "the last step didn't work") }
                return StudioScreenTaskResult(finished: true, report: say + " Steps: " + job.history.joined(separator: "; ") + ".")
            case .cant(let say):
                return stopped(job, say)
            case .open(let name):
                if let problem = await open(name, job) { return stopped(job, problem) }
            case .press(let id):
                guard job.elements.indices.contains(id) else { fail(job, "there's no control \(id)"); continue }
                let title = describe(job.elements[id])
                if let refusal = ScreenTaskPolicy.refusal(pressing: title) { return stopped(job, refusal) }
                note(job, "pressing \(title)")
                await showCursor(on: job.elements[id], job, clicks: true)
                let pressed = await watchingFocus(job) { TypeForMeAccessibility.press(job.elements[id]) }
                if let pressed { record(job, pressed ? "pressed \(title)" : "\(title) wouldn't press", failed: !pressed) } else { return tookFocus(job) }
            case .menu(let path):
                let title = path.joined(separator: " > ")
                if let refusal = ScreenTaskPolicy.refusal(pressing: title) { return stopped(job, refusal) }
                guard let pid = job.app?.processIdentifier, let item = menuItem(path, of: pid) else { fail(job, "there's no menu item \(title)"); continue }
                note(job, "choosing \(title)")
                StudioController.shared.moveCursor(on: job.tile, to: CGPoint(x: 0.14, y: 0.03), clicks: true)
                try? await Task.sleep(nanoseconds: 500_000_000)
                let pressed = await watchingFocus(job) { TypeForMeAccessibility.press(item) }
                if let pressed { record(job, pressed ? "chose \(title)" : "\(title) wouldn't press", failed: !pressed) } else { return tookFocus(job) }
            case .type(let id, let text):
                guard job.elements.indices.contains(id) else { fail(job, "there's no control \(id)"); continue }
                note(job, "writing \"\(text.prefix(40))\"")
                await showCursor(on: job.elements[id], job, clicks: false)
                let wrote = await watchingFocus(job) { Self.write(text, into: job.elements[id]) }
                if let wrote {
                    record(job, wrote ? "wrote \"\(text)\" and read it back" : "the app wouldn't take the text \"\(text)\" without focus", failed: !wrote)
                } else { return tookFocus(job) }
            }
        }
        return stopped(job, "it took more than \(Self.maximumSteps) steps")
    }

    private func nextStep(prompt: String) async -> ScreenTaskStep? {
        let turn = Task { () -> String? in
            try? await CompanionWorkerRunner.makeWorkerClaudeCodeBridge().runTurn(
                systemPromptFileName: "studio-screen-task-prompt.md", systemPrompt: ScreenTaskPolicy.systemPrompt,
                contentBlocks: [.text(prompt)]).text
        }
        let timeout = Task { try? await Task.sleep(nanoseconds: 45_000_000_000); turn.cancel() }
        defer { timeout.cancel() }
        return await turn.value.flatMap(ScreenTaskStep.parse)
    }

    private func stopped(_ job: Job, _ why: String) -> StudioScreenTaskResult {
        let done = job.history.isEmpty ? "Nothing was done." : "What happened: " + job.history.joined(separator: "; ") + "."
        return StudioScreenTaskResult(finished: false, report: "I couldn't finish that on the hidden screen: \(why). \(done)")
    }

    private func tookFocus(_ job: Job) -> StudioScreenTaskResult {
        stopped(job, "\(job.app?.localizedName ?? "the app") took the front when I did that, so I handed the front back and stopped")
    }

    private func fail(_ job: Job, _ what: String) { record(job, what, failed: true) }

    private func record(_ job: Job, _ what: String, failed: Bool) {
        job.history.append(what)
        job.lastStepFailed = failed
    }

    private func note(_ job: Job, _ what: String) {
        StudioController.shared.noteResearch(job.tile, note: "Clicky: \(what)", app: job.app)
    }

    /// Does one action and hands the front back if the app took it. Nil means it took the front.
    private func watchingFocus<T>(_ job: Job, _ action: () -> T) async -> T? {
        let pid = job.app?.processIdentifier
        let before = BackgroundInput.FrontmostSnapshot.capture()
        let result = action()
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard let pid, before.application?.processIdentifier != pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return result }
        handFrontBack(before, from: pid)
        return nil
    }

    private func handFrontBack(_ before: BackgroundInput.FrontmostSnapshot, from pid: pid_t) {
        let last = BackgroundInput.lastTheoApp
        before.restore(ifStolenBy: [pid])
        BackgroundInput.lastTheoApp = last
    }

    private static func write(_ text: String, into element: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success,
           TypeForMeAccessibility.value(of: element)?.contains(text) == true { return true }
        return TypeForMeAccessibility.setSelectedText(text, of: element) && TypeForMeAccessibility.value(of: element)?.contains(text) == true
    }

    // MARK: The app and its windows

    /// Nil when it's open, else what stopped it.
    private func open(_ name: String, _ job: Job) async -> String? {
        if let refusal = ScreenTaskPolicy.refusal(app: name) { return refusal }
        guard let found = ActionExecutor.findApplication(name: name, bundleIdentifier: nil), let path = found.path else { return "I couldn't find an app called \(name)" }
        if let refusal = ScreenTaskPolicy.refusal(app: found.name) { return refusal }
        note(job, "opening \(found.name)")
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path && !$0.isTerminated }
        if let running {
            // The windows already open are the owner's and stay where they are. Only new ones come over.
            job.ownersWindows = Set(windows(of: running.processIdentifier))
        }
        job.openedHere = running == nil
        let before = BackgroundInput.FrontmostSnapshot.capture()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        guard let opened = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) else { return "\(found.name) wouldn't open" }
        job.app = opened
        for _ in 0..<40 {
            takeNewWindows(job)
            if !job.moved.isEmpty { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        // A fresh app can grab the front as it starts: that's the launch, not the job, so it's only handed back.
        if before.application?.processIdentifier != opened.processIdentifier, NSWorkspace.shared.frontmostApplication?.processIdentifier == opened.processIdentifier {
            handFrontBack(before, from: opened.processIdentifier)
        }
        record(job, job.moved.isEmpty ? "opened \(found.name), which has no new window on the hidden screen yet" : "opened \(found.name) on the hidden screen", failed: false)
        return nil
    }

    private func windows(of pid: pid_t) -> [AXUIElement] {
        let app = TypeForMeAccessibility.applicationElement(processIdentifier: pid)
        return TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: app)
    }

    /// Any window of the job's app that isn't the owner's goes on the tile, and its old place is kept for afterwards.
    private func takeNewWindows(_ job: Job) {
        guard let app = job.app, let frame = StudioController.shared.frame(of: job.tile) else { return }
        for window in windows(of: app.processIdentifier) where !job.ownersWindows.contains(window) && !job.moved.contains(where: { $0.window == window }) {
            guard let original = TypeForMeAccessibility.frameCG(of: window) else { continue }
            _ = StudioController.place(window, in: frame)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            job.moved.append((window, original))
        }
        StudioController.shared.noteResearch(job.tile, note: StudioController.shared.tileNotes[job.tile] ?? "Clicky: \(job.task)", app: app)
    }

    private func readWindows(_ job: Job) -> String {
        job.elements = []
        guard job.app != nil else { return "No app is open yet." }
        guard !job.moved.isEmpty else { return "No window of this app is on the hidden screen. Its other windows are Addy's and can't be used. Make a new one from the menus, or say cant." }
        var lines: [String] = []
        for (window, _) in job.moved.reversed() { walk(window, depth: 0, job: job, lines: &lines) }
        return lines.isEmpty ? "The window shows no controls." : lines.joined(separator: "\n")
    }

    private func walk(_ element: AXUIElement, depth: Int, job: Job, lines: inout [String]) {
        guard depth < 9, job.elements.count < Self.maximumElements else { return }
        let role = TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: element) ?? ""
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        let canPress = (actions as? [String])?.contains(kAXPressAction as String) == true
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let title = describe(element)
        let value = TypeForMeAccessibility.value(of: element).map { String($0.prefix(120)) }
        if canPress || settable.boolValue || !title.isEmpty || value?.isEmpty == false {
            var line = "[\(job.elements.count)] \(role.replacingOccurrences(of: "AX", with: ""))"
            if !title.isEmpty { line += " \"\(title)\"" }
            if let value, !value.isEmpty { line += " value=\"\(value)\"" }
            if canPress { line += " pressable" }
            if settable.boolValue { line += " text-settable" }
            job.elements.append(element)
            lines.append(line)
        }
        for child in TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element) { walk(child, depth: depth + 1, job: job, lines: &lines) }
    }

    private func describe(_ element: AXUIElement) -> String {
        let title = TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: element) ?? ""
        return title.isEmpty ? TypeForMeAccessibility.stringAttribute(kAXDescriptionAttribute, of: element) ?? "" : title
    }

    private func showCursor(on element: AXUIElement, _ job: Job, clicks: Bool) async {
        guard let target = TypeForMeAccessibility.frameCG(of: element),
              let window = job.moved.last.flatMap({ TypeForMeAccessibility.frameCG(of: $0.window) }), window.width > 0, window.height > 0 else { return }
        StudioController.shared.moveCursor(on: job.tile, to: CGPoint(x: (target.midX - window.minX) / window.width, y: (target.midY - window.minY) / window.height), clicks: clicks)
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: Menus

    /// Skips the Apple and app menus, which hold nothing a job needs.
    private func topMenus(of pid: pid_t) -> [(title: String, items: [AXUIElement])] {
        let app = TypeForMeAccessibility.applicationElement(processIdentifier: pid)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        // swiftlint:disable:next force_cast
        return TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: bar as! AXUIElement).dropFirst(2).compactMap { top in
            guard let menu = TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: top).first else { return nil }
            return (describe(top), TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: menu))
        }
    }

    private func menuLines(of pid: pid_t) -> [String] {
        topMenus(of: pid).prefix(6).map { top in
            let names = top.items.map { describe($0) }.filter { !$0.isEmpty }.prefix(30)
            return "\(top.title): \(names.joined(separator: ", "))"
        }
    }

    private func menuItem(_ path: [String], of pid: pid_t) -> AXUIElement? {
        func same(_ one: String, _ other: String) -> Bool { one.compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard let top = topMenus(of: pid).first(where: { same($0.title, path[0]) }) else { return nil }
        var items = top.items
        var found: AXUIElement?
        for part in path.dropFirst() {
            guard let item = items.first(where: { same(describe($0), part) }) else { return nil }
            found = item
            items = TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: item).first.map { TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: $0) } ?? []
        }
        return found
    }

    // MARK: Afterwards

    /// True when a job's windows are on this tile, for the panel's Show on my screen.
    func holds(_ tile: StudioTileID) -> Bool { jobs[tile]?.moved.isEmpty == false }

    func moveWindows(on tile: StudioTileID, to frame: NSRect) {
        for (window, _) in jobs[tile]?.moved ?? [] { _ = StudioController.place(window, in: frame) }
    }

    /// Windows go back where they came from before the tile is freed, so nothing is left stranded on a hidden screen. An app
    /// this job opened is quit politely, which keeps what it wrote. If the owner pulled it out, it's theirs now.
    private func finish(_ job: Job) {
        let studio = StudioController.shared
        if !studio.isPulledOut(job.tile) {
            for (window, frame) in job.moved {
                var origin = frame.origin
                var size = frame.size
                if let position = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
                if let measure = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, measure) }
            }
            if job.openedHere { job.app?.terminate() }
        }
        jobs[job.tile] = nil
        studio.releaseResearch(job.tile)
    }
}

struct StudioTileCursor: Equatable {
    var point: CGPoint
    var clicks: Int
}
