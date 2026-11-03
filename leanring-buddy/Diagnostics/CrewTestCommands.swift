//
//  CrewTestCommands.swift
//  leanring-buddy
//
//  Test-profile commands for the crew and Studio screens (TheoUIDriver only runs in the test profile):
//  uiCrew {pointer: {x, y}} moves a stand-in pointer in window points (the real one never moves); {pointer: null} lets go.
//  uiCrew {action: "state"} says what the driver is doing.
//  uiStudio {action: on|off|state|assign|clear|panel, botID, screen, tile}.
//  uiSeedDemo fills the test profile with a team and a chat showing each card.
//  uiSetDefaults {key, value}: a test profile preference.
//

import AppKit
import ClickyCore
import Foundation

@MainActor
enum CrewTestCommands {
    static func run(_ name: String, _ command: [String: Any], in window: NSWindow?) -> Any {
        switch name {
        case "uiCrew": return crew(command, window: window)
        case "uiStudio": return studio(command)
        case "uiSeedDemo": return seed()
        default:
            if let key = command["key"] as? String { UserDefaults.standard.set(command["value"], forKey: key) }
            return [:] as [String: Any]
        }
    }

    private static func crew(_ command: [String: Any], window: NSWindow?) -> Any {
        if let pointer = command["pointer"] as? [String: Any], let window,
           let x = (pointer["x"] as? NSNumber)?.doubleValue, let y = (pointer["y"] as? NSNumber)?.doubleValue {
            let inWindow = NSPoint(x: x, y: window.contentLayoutRect.maxY + window.titlebarHeightForTest - y)
            CrewDriver.shared.testPointer = window.convertPoint(toScreen: inWindow)
        } else if command["pointer"] is NSNull {
            CrewDriver.shared.testPointer = nil
        }
        if command["action"] as? String == "settings" { NotificationCenter.default.post(name: .theoShowBotSettings, object: nil) }
        return ["running": CrewDriver.shared.isRunning, "showing": CrewDriver.shared.showingCount, "motion": DS.Motion.level.rawValue] as [String: Any]
    }

    private static func studio(_ command: [String: Any]) -> Any {
        let controller = StudioController.shared
        let tile = StudioTileID(screen: command["screen"] as? Int ?? 0, tile: command["tile"] as? Int ?? 0)
        switch command["action"] as? String ?? "state" {
        case "on": controller.setEnabled(true)
        case "off": controller.setEnabled(false)
        case "panel": controller.panelVisible = command["visible"] as? Bool ?? true
        case "assign":
            if let bot = command["botID"] as? String { controller.assign(botID: bot, to: tile) }
            if let name = command["botName"] as? String, let bot = BotsStore.shared.bots.first(where: { $0.name == name }) { controller.assign(botID: bot.id, to: tile) }
        case "clear": controller.clear(tile)
        default: break
        }
        var roster: [String: String] = [:]
        for (key, value) in controller.roster.bots { roster["\(key.screen).\(key.tile)"] = value }
        return ["available": StudioController.isAvailable, "model": StudioGate.currentModel, "on": controller.isOn, "enabled": controller.isEnabled,
                "displays": controller.displayBounds(), "roster": roster, "thumbnails": controller.thumbnails.count,
                "captureAllowed": controller.hasCapturePermission, "liveCapture": controller.liveCapture, "problem": controller.problem ?? "", "monitorCheck": controller.lastMonitorCheck,
                "allScreens": NSScreen.screens.map { ["name": $0.localizedName, "x": $0.frame.minX, "y": $0.frame.minY, "w": $0.frame.width, "h": $0.frame.height] as [String: Any] },
                "ownerScreens": NSScreen.ownerScreens.map(\.localizedName)] as [String: Any]
    }

    private static func seed() -> Any {
        let store = BotsStore.shared
        func bot(_ name: String, _ role: String) -> NativeBot {
            store.bots.first { $0.name == name } ?? store.addBot(name: name, description: role, instructions: "You are \(name).", provider: "claude", model: "claude-haiku-5-5", groupID: nil)
        }
        let team: [(String, [(String, String)])] = [
            ("Engineering", [("Builder", "Builds what's asked"), ("Designer", "Draws screens"), ("Code Reviewer", "Reviews every change")]),
            ("Growth", [("Researcher", "Reads and summarises"), ("Inbox Triage", "Sorts the mail"), ("Copy Editor", "Polishes the words")]),
        ]
        var made: [String: NativeBot] = [:]
        for (section, members) in team {
            let id = store.layout.sections.first { $0.name == section }?.id ?? store.addSection(named: section)
            for (name, role) in members {
                var dressed = bot(name, role)
                dressed.look = .standard(id: dressed.id, name: name)
                store.save(dressed)
                made[name] = dressed
                if let id { store.move("bot:\(dressed.id)", toSection: id) }
            }
        }
        guard let theo = store.primary else { return ["ok": false] }
        let now = Date()
        func message(_ author: String, _ text: String, _ ago: TimeInterval) -> BotChatMessage {
            var item = BotChatMessage(author: author, text: text)
            item.at = now.addingTimeInterval(-ago)
            return item
        }
        let brief = """
        # Studio Screens: four bots, two hidden displays

        Two invisible 1440×900 screens, each split into two tiles. Your bots work side by side while you watch small live views inside Theo, and nothing lands on your own monitors.

        ## Why
        Bots that open browsers and terminals on your screens get in the way. A screen nobody sees is the simplest place for that work to happen, and Builder and Designer can keep at it while you do something else entirely.

        ## How it works
        Theo makes two virtual displays when you turn the feature on and removes them when you turn it off or quit. Each display is split into a left and a right tile, and a bot gets one tile. Small views at two frames a second sit in the Studio panel, only while it's open.

        ## Cost on Studio
        About three percent of the CPU and 180 MB with four tiles live. Thumbnails stop the moment the panel closes.

        ## Rollout
        Mac Studio only for now, and off until you turn it on. Bots don't move onto the tiles by themselves yet; that comes after you've tried it.
        """
        store.seedForTest(theo.id, messages: [
            message("user", "Plan the Studio screens launch and get Builder started on the tiles.", 200),
            message(theo.id, "Done. Here's the brief, Builder is already on it, and I need one quick call from you.", 190),
            message(theo.id, brief, 185),
            message(theo.id, "[CHOOSE: How should each screen be split? | Side by side: Best for code and browsers | Stacked: Better for wide timelines]", 20),
        ])
        var run = T3Run(id: "demo-run", title: "Add virtual screen tiles", folder: "/tmp/theo-demo", branch: "theo/studio-tiles")
        run.phase = "running"
        run.activity = "swift build ▸ Compiling TileView.swift (12/31)"
        run.startedAt = now.addingTimeInterval(-102)
        run.room = theo.id
        run.harness = "claude"
        run.model = "claude-haiku-5-5"
        store.injectRunForTest(run)
        if let builder = made["Builder"] {
            var live = run
            live.id = "demo-run-builder"
            live.room = builder.id
            store.injectRunForTest(live)
        }
        if let reviewer = made["Code Reviewer"] { store.seedForTest(reviewer.id, messages: [message(reviewer.id, "Approved #41", 120)]) }
        if let researcher = made["Researcher"] {
            var live = run
            live.id = "demo-run-research"
            live.room = researcher.id
            live.title = "Reading 6 sources"
            live.activity = "Reading 6 sources"
            store.injectRunForTest(live)
        }
        if let inbox = made["Inbox Triage"] {
            store.seedForTest(inbox.id, messages: [message(inbox.id, "Sorted 42 emails. [CHOOSE: Send the three replies? | Send them: They're drafted | Hold: I'll read them first]", 60)])
        }
        if let copy = made["Copy Editor"] { store.seedForTest(copy.id, messages: [message(copy.id, "Draft v2 ready", 86400)]) }
        return ["ok": true, "bots": store.bots.map(\.name)]
    }
}

private extension NSWindow {
    /// The driver's window points run from the very top of the window, title bar included.
    var titlebarHeightForTest: CGFloat { frame.height - contentLayoutRect.maxY }
}

extension BotsStore {
    /// Test profile only: a chat's messages, as if they'd happened.
    func seedForTest(_ id: String, messages: [BotChatMessage]) {
        guard TheoProfile.isTest else { return }
        var record = conversation(id)
        record.messages = messages
        setConversationForTest(id, record)
    }
}
