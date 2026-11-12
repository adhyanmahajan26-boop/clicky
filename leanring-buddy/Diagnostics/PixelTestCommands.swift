//
//  PixelTestCommands.swift
//  leanring-buddy
//
//  Test-profile commands for the Pixel faces and the status language (TheoUIDriver only runs in the test profile):
//  uiPixel {action: "gallery", look?, theme?}      a Theo window with every state at 16, 28, 36 and 112 pt.
//  uiPixel {action: "seed"}                         the crew, each bot in a different state, for the list, Home and the menu bar.
//  uiPixel {action: "fail", bot, reason, step?}     a failure as a run or reply would record it.
//  uiPixel {action: "block", bot, connector}        a bot that reached for an app that needs a sign-in.
//  uiPixel {action: "connector", id, status}        stands in for `claude mcp list` (connected | needsSignIn | failed:<reason> | missing | clear).
//  uiPixel {action: "state", bot}                   which face shows and why.
//  uiPixel {action: "opened"}                       what the cards' buttons would have opened (links are recorded, never opened).
//  uiPixel {action: "alert", which?}                shows the newest alert inside a Theo window.
//  uiPixel {action: "reply", bot, text?}            a bot shown replying (text nil: stop).
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

@MainActor
enum PixelTestCommands {
    private static var windows: [String: NSWindow] = [:]

    static func run(_ command: [String: Any]) -> Any {
        let store = BotsStore.shared
        func bot(_ key: String = "bot") -> NativeBot? {
            guard let value = command[key] as? String else { return nil }
            return store.bot(value) ?? store.bots.first { $0.name.lowercased() == value.lowercased() }
        }
        switch command["action"] as? String ?? "" {
        case "gallery":
            return showGallery(look: command["look"] as? String ?? "theo", theme: command["theme"] as? String)
        case "seed":
            return seed()
        case "fail":
            guard let bot = bot() else { return ["error": "No such bot."] }
            store.recordFailure(of: bot.id, reason: command["reason"] as? String ?? "It stopped.", step: command["step"] as? String, runID: command["run"] as? String)
            return ["state": store.pixelState(of: bot).state.rawValue]
        case "clearFailure":
            guard let bot = bot() else { return ["error": "No such bot."] }
            store.clearFailure(of: bot.id)
            return ["state": store.pixelState(of: bot).state.rawValue]
        case "block":
            guard let bot = bot(), let connector = command["connector"] as? String else { return ["error": "Needs bot and connector."] }
            ConnectorHealth.shared.setBlock(bot.id, connectorID: connector, room: bot.id)
            return ["state": store.pixelState(of: bot).state.rawValue]
        case "connector":
            guard let id = command["id"] as? String, let status = command["status"] as? String else { return ["error": "Needs id and status."] }
            var map = UserDefaults.standard.dictionary(forKey: ConnectorHealth.testStatusKey) as? [String: String] ?? [:]
            map[id] = status == "clear" ? nil : status
            UserDefaults.standard.set(map, forKey: ConnectorHealth.testStatusKey)
            ConnectorHealth.shared.objectWillChange.send()
            store.objectWillChange.send()
            Task { await ConnectorHealth.shared.refresh() }
            return ["map": map]
        case "state":
            guard let bot = bot() else { return ["error": "No such bot."] }
            let facts = store.pixelFacts(of: bot)
            return ["state": store.pixelState(of: bot).state.rawValue, "status": store.liveStatus(of: bot), "failure": bot.lastFailure?.reason ?? NSNull(),
                    "blockedOn": ConnectorHealth.shared.block(of: bot.id)?.connectorID ?? NSNull(),
                    "facts": ["waiting": facts.isWaitingOnOwner, "failed": facts.hasUnseenFailure, "working": facts.isWorking, "thinking": facts.isThinking,
                              "done": facts.finishedRecently, "awake": facts.isAwake, "on": facts.isOn]] as [String: Any]
        case "opened":
            return ["opened": TheoOpen.recorded]
        case "alert":
            return showAlert()
        case "menubar":
            let summary = MenuBarFace.summary()
            let view = MenuBarPreview(current: summary).environment(\.colorScheme, .dark)
            var result = show(id: "menubar", title: "Menu bar", size: NSSize(width: 720, height: 300), view: view, theme: nil) as? [String: Any] ?? [:]
            result["state"] = summary.state.rawValue
            result["count"] = summary.count
            return result
        case "notch":
            let view = NotchPreview().environment(\.colorScheme, .dark)
            return show(id: "notch", title: "Notch", size: NSSize(width: 620, height: 560), view: view, theme: nil)
        case "notchLine":
            let line = NotchPanelController.botLine(store: store)
            return ["title": line?.title as Any? ?? NSNull(), "line": line?.line as Any? ?? NSNull(), "button": line?.button as Any? ?? NSNull()] as [String: Any]
        case "panel":
            guard let manager = CompanionManager.current else { return ["error": "No companion."] }
            let view = TheoPanelView(companionManager: manager, close: {}).padding(16).background(Color.black)
            return show(id: "panel", title: "Menu bar panel", size: NSSize(width: 360, height: 820), view: view, theme: nil)
        case "alerts":
            return ["alerts": BotAlerts.shared.recent.map { ["bot": $0.botID, "state": $0.state.rawValue, "title": $0.title, "line": $0.line] }]
        case "reply":
            guard let bot = bot() else { return ["error": "No such bot."] }
            store.setReplyingForTest(bot.id, text: command["text"] as? String)
            return ["state": store.pixelState(of: bot).state.rawValue]
        case "unread":
            guard let bot = bot() else { return ["error": "No such bot."] }
            store.setUnreadForTest(bot.id, count: command["count"] as? Int ?? 1)
            return ["state": store.pixelState(of: bot).state.rawValue]
        case "close":
            windows.values.forEach { $0.close() }
            windows = [:]
            return ["ok": true]
        default:
            return ["error": "Unknown action."]
        }
    }

    // MARK: Gallery

    private static func showGallery(look: String, theme: String?) -> Any {
        let crew: [String: CrewLook] = ["theo": .theo, "clicky": .clicky, "builder": .builder, "researcher": .researcher, "designer": .designer,
                                        "reviewer": .reviewer, "inbox": .inbox, "editor": .copyEditor, "release": .release, "manager": .manager, "accountant": .accountant]
        let chosen = crew[look] ?? .theo
        let view = PixelGalleryView(look: chosen, name: look.capitalized)
            .environment(\.colorScheme, theme == "light" ? .light : .dark)
        return show(id: "gallery", title: "Pixel gallery", size: NSSize(width: 1180, height: 760), view: view, theme: theme)
    }

    private static func showAlert() -> Any {
        guard let alert = BotAlerts.shared.recent.first else { return ["error": "No alert yet."] }
        let view = BotAlertView(alert: alert).padding(24).background(DS.Colors.background)
        return show(id: "alert", title: "Alert", size: NSSize(width: 420, height: 200), view: view, theme: nil)
    }

    private static func show<Content: View>(id: String, title: String, size: NSSize, view: Content, theme: String?) -> Any {
        windows[id]?.close()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
        window.contentView = NSHostingView(rootView: view)
        // Beside Theo's own window, on Theo's monitor.
        if let main = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("Theo") }) ?? NSApp.mainWindow {
            window.setFrameOrigin(NSPoint(x: main.frame.minX + 40, y: main.frame.maxY - size.height - 60))
        }
        window.orderFrontRegardless()
        windows[id] = window
        return ["window": window.windowNumber]
    }

    // MARK: Seeding the crew

    /// The crew from the design, each bot in a different state: needs you (a sign-in and a question), failed, working,
    /// thinking, done with an unread result, ready, asleep and off.
    private static func seed() -> Any {
        let store = BotsStore.shared
        func bot(_ name: String, _ role: String, provider: String = "claude") -> NativeBot {
            store.bots.first { $0.name == name } ?? store.addBot(name: name, description: role, instructions: "You are \(name).", provider: provider, model: "claude-haiku-5-5", groupID: nil)
        }
        let team: [(String, [(String, String)])] = [
            ("Engineering", [("Builder", "Builds what's asked"), ("Designer", "Draws screens"), ("Code Reviewer", "Reviews every change"), ("Release Mgr", "Ships releases")]),
            ("Growth", [("Researcher", "Reads and summarises"), ("Inbox Triage", "Sorts the mail"), ("Copy Editor", "Polishes the words")]),
            ("Planning", [("Manager", "Plans the week"), ("Accountant", "Keeps the books")]),
        ]
        var made: [String: NativeBot] = [:]
        for (section, members) in team {
            let id = store.layout.sections.first { $0.name == section }?.id ?? store.addSection(named: section)
            for (name, role) in members {
                var dressed = bot(name, role)
                dressed.look = .standard(id: dressed.id, name: name)
                dressed.lastFailure = nil
                dressed.enabled = true
                if name == "Researcher" { dressed.apps = ["notion", "drive", "chrome", "sheets"] }
                if name == "Inbox Triage" { dressed.apps = ["gmail"] }
                store.save(dressed)
                made[name] = dressed
                if let id { store.move("bot:\(dressed.id)", toSection: id) }
            }
        }
        let now = Date()
        func message(_ author: String, _ text: String, _ ago: TimeInterval) -> BotChatMessage {
            var item = BotChatMessage(author: author, text: text)
            item.at = now.addingTimeInterval(-ago)
            return item
        }
        // Needs you: a sign-in.
        if let researcher = made["Researcher"] {
            store.seedForTest(researcher.id, messages: [
                message("user", "Read the Q4 spec in Notion and list what changed since March.", 260),
                message(researcher.id, "On it. I'll read the spec and compare it with the March version. I can't access Notion right now: it needs you to sign in.", 240),
            ])
            ConnectorHealth.shared.setBlock(researcher.id, connectorID: "notion", room: researcher.id)
        }
        // Needs you: a question.
        if let inbox = made["Inbox Triage"] {
            store.seedForTest(inbox.id, messages: [
                message("user", "Go through this morning's mail.", 800),
                message(inbox.id, "3 emails want a reply from you. I drafted all three.\n\n[CHOOSE: Send the drafts? | Review drafts | Later]", 60),
            ])
        }
        // Failed.
        if let release = made["Release Mgr"] {
            store.seedForTest(release.id, messages: [
                message("user", "Ship fix-login to GitHub as a draft PR.", 900),
                message(release.id, "Couldn't reply: Your GitHub sign-in has expired. The changes are saved on this Mac and nothing was lost.", 540),
            ])
            store.recordFailure(of: release.id, reason: "Your GitHub sign-in has expired. The changes are saved on this Mac and nothing was lost.", step: "Push")
        }
        // Working: a live run.
        if let builder = made["Builder"] {
            var run = T3Run(id: "pixel-run-builder", title: "fix-login-test", folder: "/tmp/theo-demo", branch: "fix-login-test")
            run.phase = "running"
            run.stage = nil
            run.activity = "swift test ▸ 12 of 31 passed"
            run.startedAt = now.addingTimeInterval(-102)
            run.room = builder.id
            run.harness = "claude"
            run.model = "claude-haiku-5-5"
            store.injectRunForTest(run)
            store.seedForTest(builder.id, messages: [message("user", "Fix the failing login test.", 110)])
        }
        // Thinking: replying, nothing streamed yet.
        if let designer = made["Designer"] {
            store.seedForTest(designer.id, messages: [message("user", "Sketch the new settings screen.", 6)])
            store.setReplyingForTest(designer.id, text: "")
        }
        // Done, with an unread result.
        if let reviewer = made["Code Reviewer"] {
            store.seedForTest(reviewer.id, messages: [
                message("user", "Review PR #41.", 400),
                message(reviewer.id, "Approved PR #41. Two small notes left inline.", 100),
            ])
            store.setUnreadForTest(reviewer.id, count: 1)
        }
        // Asleep.
        for name in ["Copy Editor", "Manager"] {
            if let quiet = made[name] { store.seedForTest(quiet.id, messages: [message(quiet.id, "Nothing to do.", 7200)]) }
        }
        // Off.
        if var accountant = made["Accountant"] {
            accountant.enabled = false
            store.save(accountant)
        }
        return ["bots": made.mapValues { store.pixelState(of: $0).state.rawValue }]
    }
}

/// The notch as it draws a bot's line: the most urgent bot right now (from the store), Listening, and a bot that is done.
struct NotchPreview: View {
    var body: some View {
        let layout = NotchLayout.sample(hasPhysicalNotch: false)
        var actions = NotchActions.inert
        actions.botFace = { botID, state in
            guard let bot = BotsStore.shared.bot(botID) else { return AnyView(EmptyView()) }
            return AnyView(CrewAvatar(look: bot.crewLook, size: 28, pose: PixelState(rawValue: state) ?? .awake, interactive: false, name: bot.name, ring: .black))
        }
        let live = NotchPanelController.botLine(store: BotsStore.shared)
        let builder = BotsStore.shared.bots.first { $0.name == "Builder" }
        let examples: [NotchContent] = [
            NotchContent(statusText: live?.title ?? "", botLine: live),
            NotchContent(phase: .listening, statusText: "Listening…", captionText: "\u{201C}Hey Theo, what's Builder doing?\u{201D}"),
            NotchContent(botLine: builder.map { NotchBotLine(botID: $0.id, state: "done", title: "Builder is done", line: "Draft pull request is ready", button: "Open") }),
        ]
        return VStack(spacing: 14) {
            ForEach(Array(examples.enumerated()), id: \.offset) { _, content in
                NotchView(content: content, layout: layout, isExpanded: true, actions: actions, fixedAnimationDate: Date(timeIntervalSinceReferenceDate: 0))
                    .frame(height: NotchView.pillSize(content: content, layout: layout, isExpanded: true).height)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.16))
    }
}

/// The menu bar icon as it is drawn, on a dark and a light menu bar: calm, working, needs you, failed, and what it shows now.
struct MenuBarPreview: View {
    let current: MenuBarFace.Summary
    private let samples: [(String, PixelState, Int)] = [("Calm", .awake, 0), ("Working", .working, 2), ("Needs you", .needs, 2), ("Failed", .failed, 1)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([true, false], id: \.self) { dark in
                HStack(spacing: 34) {
                    ForEach(samples, id: \.0) { sample in item(sample.1, count: sample.2, dark: dark, label: sample.0) }
                }
                .padding(.horizontal, 18).frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 10).fill(dark ? Color(white: 0.12) : Color(white: 0.93)))
            }
            HStack(spacing: 10) {
                Text("Now:").font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                item(current.state, count: current.count, dark: true, label: current.count > 0 ? "\(current.count) \(current.state.label.lowercased())" : "Calm")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Colors.background)
    }

    private func item(_ state: PixelState, count: Int, dark: Bool, label: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 3) {
                Image(nsImage: MenuBarFace.image(for: state, darkMenuBar: dark)).frame(width: 18, height: 18)
                if count > 0 { Text("\(count)").font(.system(size: 13, weight: .medium)).foregroundColor(dark ? .white : .black) }
            }
            Text(label).font(.system(size: 10)).foregroundColor(dark ? Color(white: 0.6) : Color(white: 0.35))
        }
    }
}

/// Every state at 16, 28, 36 and 112 pt, the pills, and the crew, for checking against kit/svg.
struct PixelGalleryView: View {
    let look: CrewLook
    let name: String
    private let sizes: [CGFloat] = [16, 28, 36, 112]
    private let crew: [(String, CrewLook)] = [("Theo", .theo), ("Clicky", .clicky), ("Builder", .builder), ("Researcher", .researcher), ("Designer", .designer),
                                              ("Code Reviewer", .reviewer), ("Inbox Triage", .inbox), ("Copy Editor", .copyEditor), ("Release Mgr", .release),
                                              ("Manager", .manager), ("Accountant", .accountant)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(name) in all ten states at 16, 28, 36 and 112 pt").font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(PixelState.allCases, id: \.self) { state in
                        VStack(spacing: 10) {
                            ForEach(sizes, id: \.self) { size in
                                CrewAvatar(look: look, size: size, pose: state, interactive: false, name: name)
                                    .frame(width: max(size, 40), height: size)
                            }
                            StatusPill(state: state)
                        }
                        .frame(width: 104)
                    }
                }
                Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
                HStack(spacing: 18) {
                    ForEach(crew, id: \.0) { item in
                        VStack(spacing: 6) {
                            CrewAvatar(look: item.1, size: 64, pose: .awake, interactive: false, name: item.0)
                            Text(item.0).font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                        }
                    }
                }
                HStack(spacing: 8) {
                    StatusPill(text: "Connected", tone: .good)
                    StatusPill(text: "Needs sign-in", tone: .warn)
                    StatusPill(text: "Can't connect", tone: .bad)
                    StatusPill(text: "Not connected", tone: .neutral)
                    StatusPill(text: "Checking", tone: .checking)
                    StatusPill(text: "Skills", tone: .neutral)
                    StatusPill(text: "Asleep", tone: .asleep)
                }
            }
            .padding(24)
        }
        .background(DS.Colors.background)
    }
}
