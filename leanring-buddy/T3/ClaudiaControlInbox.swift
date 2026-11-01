//
//  ClaudiaControlInbox.swift
//  leanring-buddy
//
//  Claudia inside T3 Code: the commands the `claudia` MCP server (this same
//  app, started with --mcp by an agent in T3 Code, Claude Code, Codex or
//  OpenCode) sends to the running Claudia. Same file protocol as the debug
//  inbox, but in every build and with a fixed, small command set:
//  ~/.clicky/control-inbox/<id>.json in, ~/.clicky/control-outbox/<id>.json
//  out, both 0700 and owned by this user. Nothing listens on the network.
//
//    status                        → brain, screens, voice, silent mode
//    see {}                        → screenshots (JPEG files) + the numbered element lists
//    ask {text, speak=true}        → Claudia answers with her own brain: boards, marks, research, actions…
//    show {text, speak=true}       → plays an answer written by the agent: spoken words plus Claudia's tags
//                                    ([POINT:…], [MARK:…], <whiteboard>, <actions>) against the last `see`
//    say {text}                    → speaks one line
//    research {question, urls=[]}  → Haiku agents read the pages (or search the topic); waits for the brief
//    board {action}                → next | back | replay | pause | export | close | state
//    stop                          → stops speaking and anything in flight
//

import AppKit
import ClickyCore
import Foundation

@MainActor
final class ClaudiaControlInbox {
    static let inboxDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/control-inbox", isDirectory: true)
    static let outboxDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/control-outbox", isDirectory: true)

    private let companionManager: CompanionManager
    private var watcher: DispatchSourceFileSystemObject?
    private var handledIdentifiers: Set<String> = []
    /// The grounded turn from the last `see`, so `show` resolves the element ids the agent saw.
    private var lastSeen: (turn: GroundedTurn, date: Date)?

    /// The running inbox, for Theo's own window (Ask tab).
    static weak var shared: ClaudiaControlInbox?

    init(companionManager: CompanionManager) {
        defer { Self.shared = self }
        self.companionManager = companionManager
    }

    func start() {
        for directoryURL in [Self.inboxDirectoryURL, Self.outboxDirectoryURL] {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        }
        let descriptor = open(Self.inboxDirectoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        scan()
    }

    private func scan() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Self.inboxDirectoryURL.path) else { return }
        for name in names where name.range(of: #"^[A-Za-z0-9_-]+\.json$"#, options: .regularExpression) != nil {
            let identifier = String(name.dropLast(".json".count))
            guard handledIdentifiers.insert(identifier).inserted else { continue }
            let url = Self.inboxDirectoryURL.appendingPathComponent(name)
            let data = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            guard let data, let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let commandName = command["cmd"] as? String else {
                reply(identifier, ok: false, result: nil, error: "expected a JSON object with \"cmd\"")
                continue
            }
            _ = commandName
            execute(command) { [weak self] ok, result, error in self?.reply(identifier, ok: ok, result: result, error: error) }
        }
    }

    private func reply(_ identifier: String, ok: Bool, result: Any?, error: String?) {
        let object: [String: Any] = ["ok": ok, "result": result ?? NSNull(), "error": error ?? NSNull()]
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let temporaryURL = Self.outboxDirectoryURL.appendingPathComponent("\(identifier).json.tmp")
        let finalURL = Self.outboxDirectoryURL.appendingPathComponent("\(identifier).json")
        try? data.write(to: temporaryURL)
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.moveItem(at: temporaryURL, to: finalURL)
    }

    // MARK: - Commands

    /// Runs one command (from the inbox or Claudia's UI page) and answers through `respond`.
    func execute(_ command: [String: Any], respond: @escaping @MainActor (Bool, Any?, String?) -> Void) {
        let commandName = command["cmd"] as? String ?? ""
        let identifier = "cmd-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        func reply(_ unused: String, ok: Bool, result: Any?, error: String?) { respond(ok, result, error) }
        if TheoUIDriver.handle(commandName, command, respond: respond) { return }
        switch commandName {
        case "botSay":
            // A message to a bot's chat ("team" for the Project room), as if typed in Theo.
            let botID = command["bot"] as? String ?? BotsStore.teamID
            let text = command["text"] as? String ?? ""
            guard !text.isEmpty else { reply(identifier, ok: false, result: nil, error: "No text."); return }
            if botID == BotsStore.teamID {
                BotsStore.shared.sendToTeam(text)
            } else if botID.hasPrefix("group:") {
                BotsStore.shared.sendToGroup(text, groupID: String(botID.dropFirst("group:".count)))
            } else {
                BotsStore.shared.send(text, to: botID)
            }
            reply(identifier, ok: true, result: ["sent": botID], error: nil)
        case "routines":
            // {action: list|pause|resume|run|delete, id}
            let store = BotsStore.shared
            let id = command["id"] as? String ?? ""
            switch command["action"] as? String ?? "list" {
            case "pause": store.setPaused(true, routineID: id)
            case "resume": store.setPaused(false, routineID: id)
            case "run": store.runRoutineNow(id)
            case "delete": store.deleteRoutine(id)
            default: break
            }
            let encoded = (try? JSONEncoder().encode(store.routines)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            reply(identifier, ok: true, result: encoded ?? [], error: nil)
        case "botCreate":
            // {name, description, instructions, provider, model, group, authority, canMessage, enabled}
            let store = BotsStore.shared
            guard let name = command["name"] as? String, !name.isEmpty else { reply(identifier, ok: false, result: nil, error: "Needs a name."); return }
            let provider = command["provider"] as? String ?? "opencode"
            var bot = store.addBot(name: name, description: command["description"] as? String ?? "",
                                   instructions: command["instructions"] as? String ?? "You are \(name).",
                                   provider: provider,
                                   model: command["model"] as? String ?? HarnessCenter.shared.resolvedModel(for: provider) ?? (provider == "claude" ? "claude-sonnet-5-5" : "opencode/deepseek-v4.1-flash-free"),
                                   groupID: command["group"] as? String)
            if let authority = command["authority"] as? String, ["member", "lead", "ceo"].contains(authority) { bot.authority = authority }
            if let canMessage = command["canMessage"] as? [String] { bot.canMessage = canMessage }
            if let enabled = command["enabled"] as? Bool { bot.enabled = enabled }
            if let apps = command["apps"] as? [String] { bot.apps = apps }
            if let effort = command["effort"] as? String { bot.effort = effort.isEmpty ? nil : effort }
            store.save(bot)
            reply(identifier, ok: true, result: ["id": bot.id], error: nil)
        case "botUpdate":
            // {id, enabled?, authority?, canMessage?, primary?: true}
            let store = BotsStore.shared
            guard let id = command["id"] as? String, var bot = store.bot(id) else { reply(identifier, ok: false, result: nil, error: "No such bot."); return }
            if command["primary"] as? Bool == true { store.makePrimary(id); bot = store.bot(id) ?? bot }
            if let enabled = command["enabled"] as? Bool { bot.enabled = enabled }
            if let authority = command["authority"] as? String, ["member", "lead", "ceo"].contains(authority) { bot.authority = authority }
            if let canMessage = command["canMessage"] as? [String] { bot.canMessage = canMessage }
            store.save(bot)
            reply(identifier, ok: true, result: ["id": id, "enabled": bot.isOn, "authority": bot.authorityLevel, "primary": bot.primary], error: nil)
        case "botDelete":
            guard let id = command["id"] as? String else { reply(identifier, ok: false, result: nil, error: "Needs id."); return }
            BotsStore.shared.deleteBot(id)
            reply(identifier, ok: true, result: ["deleted": id], error: nil)
        case "botChat":
            // The last messages of a chat: {id: bot id, "team" or "group-<id>", limit}
            let id = command["id"] as? String ?? BotsStore.teamID
            let limit = max(0, min(command["limit"] as? Int ?? 10, 200))
            let messages = BotsStore.shared.conversation(id).messages.suffix(limit).map { ["author": $0.author, "text": $0.text] }
            reply(identifier, ok: true, result: Array(messages), error: nil)
        case "groupDelete":
            guard let id = command["id"] as? String else { reply(identifier, ok: false, result: nil, error: "Needs id."); return }
            BotsStore.shared.deleteGroup(id)
            reply(identifier, ok: true, result: ["deleted": id], error: nil)
        case "harnessState":
            // The harnesses on this Mac, the defaults and where builds go (refreshes in the background first).
            let center = HarnessCenter.shared
            if command["refresh"] as? Bool == true { center.refresh(force: true) }
            let statuses = HarnessCatalog.all.map { info -> [String: Any] in
                let status = center.status(for: info.id)
                return ["id": info.id, "installed": status.installed, "loggedIn": status.loggedIn as Any? ?? NSNull(),
                        "account": status.account ?? NSNull(), "models": center.models(for: info.id).prefix(8).map(\.id)]
            }
            reply(identifier, ok: true, result: ["harnesses": statuses, "defaultHarness": center.defaultHarness,
                                                 "codingTarget": center.codingTarget, "codingModel": center.codingModel ?? NSNull(),
                                                 "terminals": TerminalSessions.shared.allIDs], error: nil)
        case "harnessSet":
            // {codingTarget, codingModel, codingEffort, defaultHarness}
            let center = HarnessCenter.shared
            if let target = command["codingTarget"] as? String { center.codingTarget = target }
            if let model = command["codingModel"] as? String { center.codingModel = model.isEmpty ? nil : model }
            if let effort = command["codingEffort"] as? String { center.codingEffort = effort.isEmpty ? nil : effort }
            if let harness = command["defaultHarness"] as? String { center.defaultHarness = harness }
            reply(identifier, ok: true, result: ["codingTarget": center.codingTarget, "defaultHarness": center.defaultHarness], error: nil)
        case "terminalText":
            // The visible text of a live terminal: {id}
            let id = command["id"] as? String ?? ""
            reply(identifier, ok: true, result: TerminalSessions.shared.session(for: id)?.screenText() ?? "", error: nil)
        case "groupSave":
            // Adds or updates a bot group: {id, name, head, members, symbol}.
            guard let id = command["id"] as? String, !id.isEmpty, let name = command["name"] as? String else {
                reply(identifier, ok: false, result: nil, error: "Needs id and name."); return
            }
            let group = BotGroup(id: id, name: name, symbol: command["symbol"] as? String ?? "person.2.fill",
                                 headID: command["head"] as? String, memberIDs: command["members"] as? [String] ?? [])
            BotsStore.shared.save(group)
            reply(identifier, ok: true, result: ["saved": id], error: nil)
        case "botsState":
            let store = BotsStore.shared
            let runs = store.t3Runs.map { ["id": $0.id, "title": $0.title, "phase": $0.phase, "folder": $0.folder,
                                           "branch": $0.branch ?? NSNull(), "pullRequest": $0.pullRequest ?? NSNull()] as [String: Any] }
            reply(identifier, ok: true, result: ["replying": Array(store.replying.keys), "runs": runs,
                                                 "bots": store.bots.map { ["id": $0.id, "provider": $0.provider, "model": $0.model] },
                                                 "groups": store.groups.map { ["id": $0.id, "name": $0.name, "head": $0.headID ?? NSNull(),
                                                                               "members": $0.memberIDs] as [String: Any] }],
                  error: nil)
        case "status":
            reply(identifier, ok: true, result: [
                "brain": companionManager.selectedModel,
                "helpers": ClickyModels.helper,
                "screens": NSScreen.screens.map(\.localizedName),
                "claudiaScreen": ClickySettings.claudiaScreenName,
                "silentMode": ClickySettings.isSilentModeEnabled,
                "accessibility": companionManager.hasAccessibilityPermission,
                "screenRecording": companionManager.hasScreenRecordingPermission
            ], error: nil)

        case "see":
            Task {
                do {
                    let groundedTurn = try await companionManager.groundingCoordinator.prepareTurn(keyUpDate: Date())
                    lastSeen = (groundedTurn, Date())
                    var paths: [String] = []
                    var imageIndex = 0
                    for block in groundedTurn.contentBlocks {
                        guard case .jpegImage(let data) = block else { continue }
                        imageIndex += 1
                        let url = Self.outboxDirectoryURL.appendingPathComponent("\(identifier)-screen\(imageIndex).jpg")
                        try data.write(to: url)
                        paths.append(url.path)
                    }
                    reply(identifier, ok: true, result: ["images": paths, "elements": groundedTurn.elementListTexts], error: nil)
                } catch {
                    reply(identifier, ok: false, result: nil, error: "couldn't see the screen: \(error.localizedDescription)")
                }
            }

        case "ask":
            guard let text = command["text"] as? String, !text.isEmpty else { return reply(identifier, ok: false, result: nil, error: "ask needs \"text\"") }
            let speaks = command["speak"] as? Bool ?? true
            companionManager.sendTranscriptToClaudeWithScreenshot(
                transcript: text,
                turnOptions: CompanionManager.TurnOptions(speaksResponse: speaks, keyUpDate: Date(), onTurnFinished: { [weak self] turnDirectoryURL, turnError in
                    Task { @MainActor in
                        let answer = turnDirectoryURL.flatMap { Self.spokenAnswer(inTurn: $0) } ?? ""
                        respond(turnError == nil, ["answer": answer, "board": self?.companionManager.boardController.stateSummary() ?? [:]],
                                turnError.map { String(describing: $0) })
                    }
                })
            )

        case "show":
            guard let text = command["text"] as? String, !text.isEmpty else { return reply(identifier, ok: false, result: nil, error: "show needs \"text\"") }
            let speaks = command["speak"] as? Bool ?? true
            let seenTurn = lastSeen.flatMap { Date().timeIntervalSince($0.date) < 120 ? $0.turn : nil }
            Task {
                let turnDirectoryURL = await companionManager.playAnswer(text, groundedTurn: seenTurn, speaks: speaks, transcript: "T3 Code: show")
                reply(identifier, ok: turnDirectoryURL != nil, result: ["board": companionManager.boardController.stateSummary(),
                                                                        "marks": companionManager.markController.marks.count],
                      error: turnDirectoryURL == nil ? "couldn't see the screen" : nil)
            }

        case "say":
            guard let text = command["text"] as? String, !text.isEmpty else { return reply(identifier, ok: false, result: nil, error: "say needs \"text\"") }
            Task {
                try? await companionManager.speechOutputClient.speakText(text)
                reply(identifier, ok: true, result: ["spoken": !ClickySettings.isSilentModeEnabled], error: nil)
            }

        case "research":
            let question = command["question"] as? String ?? "research these links"
            let urls = (command["urls"] as? [String] ?? []).compactMap(URL.init(string:)).filter { ResearchURLPolicy.isAllowed($0) }
            let request: ResearchRequest
            if !urls.isEmpty {
                request = ResearchRequest(source: .links(count: urls.count), question: question, namedURLs: urls)
            } else if let parsed = ResearchTrigger.parse(question) {
                request = parsed
            } else {
                request = ResearchRequest(source: .topic(question), question: question)
            }
            let researchController = companionManager.researchController
            researchController.start(request, speaks: command["speak"] as? Bool ?? false)
            let runNumber = researchController.runNumber
            Task {
                // Wait for the brief (helpers read in parallel; at most 5 minutes).
                let deadline = Date().addingTimeInterval(300)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                while Date() < deadline, researchController.isRunning, researchController.runNumber == runNumber {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard researchController.runNumber == runNumber else {
                    reply(identifier, ok: false, result: ["state": "cancelled"],
                          error: "A newer research request replaced this one before it finished.")
                    return
                }
                let status = researchController.lastStatus
                // Done only counts with a brief: a run that found no sources isn't a success.
                let hasBrief = !((status["brief"] as? String) ?? "").isEmpty
                reply(identifier, ok: (status["state"] as? String) == "done" && hasBrief, result: status, error: nil)
            }

        case "board":
            let boardController = companionManager.boardController
            switch command["action"] as? String ?? "state" {
            case "next": boardController.next()
            case "back": boardController.back()
            case "replay": boardController.replay()
            case "pause": boardController.togglePause()
            case "expand": boardController.expand()
            case "close": boardController.close()
            case "export":
                var summary = boardController.stateSummary()
                summary["exported"] = boardController.exportBoard()?.path ?? NSNull()
                return reply(identifier, ok: true, result: summary, error: nil)
            default: break
            }
            reply(identifier, ok: true, result: boardController.stateSummary(), error: nil)

        case "settings":
            // Claudia's UI page: read, and change any of the given keys.
            if let brain = command["brain"] as? String, !brain.isEmpty { companionManager.setSelectedModel(brain) }
            if let helper = command["helper"] as? String, !helper.isEmpty { ClickyModels.helper = helper }
            if let silent = command["silentMode"] as? Bool { companionManager.setSilentModeEnabled(silent) }
            if let sparkMode = (command["sparkMode"] as? String).flatMap(ClickySettings.SparkMode.init(rawValue:)) { ClickySettings.sparkMode = sparkMode }
            if let screenName = command["claudiaScreen"] as? String { ClickySettings.claudiaScreenName = screenName }
            if let style = (command["sparkStyle"] as? String).flatMap(CompanionIconStyle.init(rawValue:)) { ClickySettings.sparkStyle = style }
            if let theme = (command["theme"] as? String).flatMap(ClaudiaTheme.init(rawValue:)) { ClickySettings.uiTheme = theme }
            if let name = command["assistantName"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty { ClickySettings.assistantName = name }
            if let autoBoard = command["autoBoard"] as? Bool { UserDefaults.standard.set(autoBoard, forKey: ClickySettings.Keys.whiteboardAuto) }
            let catalog = BrainCatalog.shared
            catalog.load()
            reply(identifier, ok: true, result: [
                "brain": companionManager.selectedModel,
                "helper": ClickyModels.helper,
                "silentMode": ClickySettings.isSilentModeEnabled,
                "sparkMode": ClickySettings.sparkMode.rawValue,
                "sparkStyle": ClickySettings.sparkStyle.rawValue,
                "theme": ClickySettings.uiTheme.rawValue,
                "assistantName": ClickySettings.assistantName,
                "themes": ClaudiaTheme.allCases.map { ["id": $0.rawValue, "name": $0.displayName] },
                "palette": ClickySettings.uiTheme.palette.map { palette -> [String: String] in
                    ["bg": ClaudiaTheme.cssHex(palette.background), "panel": ClaudiaTheme.cssHex(palette.panel), "panel2": ClaudiaTheme.cssHex(palette.line),
                     "line": ClaudiaTheme.cssHex(palette.line), "text": ClaudiaTheme.cssHex(palette.text), "muted": ClaudiaTheme.cssHex(palette.secondary),
                     "accent": ClaudiaTheme.cssHex(palette.accent)]
                } ?? [:],
                "sparkStyles": CompanionIconStyle.allCases.map { ["id": $0.rawValue, "name": $0.displayName] },
                "claudiaScreen": ClickySettings.claudiaScreenName,
                "autoBoard": ClickySettings.isWhiteboardAutoEnabled,
                "screens": NSScreen.screens.map(\.localizedName),
                "models": Dictionary(uniqueKeysWithValues: BrainProvider.allCases.map { provider in
                    (provider.rawValue, (catalog.models[provider] ?? []).map { BrainModel(provider: provider, modelIdentifier: $0).setting })
                }),
                "providerNames": Dictionary(uniqueKeysWithValues: BrainProvider.allCases.map { ($0.rawValue, $0.displayName) }),
                "version": companionManager.updateController.currentVersionLabel
            ], error: nil)

        case "turns":
            // The conversation: newest turns first, words only.
            let limit = command["limit"] as? Int ?? 30
            let turnsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/turns", isDirectory: true)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: turnsDirectory.path)) ?? []).sorted(by: >)
            var turns: [[String: Any]] = []
            for name in names where turns.count < limit {
                let turnURL = turnsDirectory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: turnURL.appendingPathComponent("turn.json")),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let transcript = object["transcript"] as? String, !transcript.hasPrefix("debug ") else { continue }
                turns.append(["id": name, "you": transcript, "claudia": Self.spokenAnswer(inTurn: turnURL) ?? "",
                              "board": object["boardTitle"] as? String ?? NSNull()])
            }
            reply(identifier, ok: true, result: turns, error: nil)

        case "listen":
            // The page's Talk button: Claudia's own hands-free listening (her mic, on this Mac).
            if command["on"] as? Bool ?? true {
                if !companionManager.isHandsFreeSessionActive { companionManager.startHandsFreeSession() }
            } else if companionManager.isHandsFreeSessionActive {
                companionManager.endHandsFreeSession()
            }
            reply(identifier, ok: true, result: ["listening": companionManager.isHandsFreeSessionActive], error: nil)

        case "library":
            // The Notes tab: notes, research briefs, whiteboards and marked screenshots, with the "use in code" ticks.
            reply(identifier, ok: true, result: ClaudiaLibrary.items().map(\.dictionary), error: nil)

        case "librarySelect":
            guard let itemID = command["id"] as? String else { return reply(identifier, ok: false, result: nil, error: "librarySelect needs \"id\"") }
            var selected = ClaudiaLibrary.selectedIDs
            if command["selected"] as? Bool ?? true { selected.insert(itemID) } else { selected.remove(itemID) }
            ClaudiaLibrary.selectedIDs = selected
            reply(identifier, ok: true, result: ["selected": Array(selected)], error: nil)

        case "libraryText":
            guard let item = (command["id"] as? String).flatMap(ClaudiaLibrary.item(id:)), !item.isImage else {
                return reply(identifier, ok: false, result: nil, error: "no such note")
            }
            reply(identifier, ok: true, result: ["title": item.title, "text": (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""], error: nil)

        case "markScreen":
            // A screenshot of the screen with Claudia's marks on it, saved into the library.
            let request = SnapshotRequest(target: .screen, includesClickyOverlay: true)
            let markRectsCG = companionManager.markController.marks.map(\.rectCG)
            Task {
                do {
                    let result = try await SnapshotCapture.capture(request: request, markRectsCG: markRectsCG)
                    reply(identifier, ok: true, result: ["path": result.fileURL.path, "id": ClaudiaLibrary.id(for: result.fileURL)], error: nil)
                } catch {
                    reply(identifier, ok: false, result: nil, error: error.localizedDescription)
                }
            }

        case "projects":
            Task {
                let repositories = await companionManager.codeModeController.localRepositoriesForProjectLookup()
                reply(identifier, ok: true, result: repositories.map { ["path": $0.folderPath, "name": URL(fileURLWithPath: $0.folderPath).lastPathComponent] }, error: nil)
            }

        case "useInCode":
            // Starts a Claude Code task in the chosen project with the ticked notes and screenshots attached.
            guard let projectPath = command["project"] as? String, !projectPath.isEmpty,
                  let instructions = command["instructions"] as? String, !instructions.isEmpty else {
                return reply(identifier, ok: false, result: nil, error: "useInCode needs \"project\" and \"instructions\"")
            }
            var attachments = ClaudiaLibrary.selectedItems.filter(\.isImage).map(\.url)
            if let notesBundle = ClaudiaLibrary.writeSelectedNotesBundle() { attachments.append(notesBundle) }
            let fullInstructions = instructions + (attachments.isEmpty ? "" :
                "\n\nUse the notes and screenshots the owner attached in .clicky-attachments/ (read every file there first).")
            let displayName = URL(fileURLWithPath: projectPath).lastPathComponent
            companionManager.codeModeController.startNamedProjectTask(rootPath: projectPath, displayName: displayName, instructions: fullInstructions,
                                                                      transcript: "T3 Code: \(instructions)", launchOptions: CodeTaskLaunchOptions(attachmentFileURLs: attachments))
            reply(identifier, ok: true, result: ["project": displayName, "attachments": attachments.map(\.lastPathComponent)], error: nil)

        case "attachments":
            // For a T3 Code agent: the ticked notes as text and the ticked screenshots as image files.
            let items = ClaudiaLibrary.selectedItems
            reply(identifier, ok: true, result: [
                "notes": items.filter { !$0.isImage }.map { ["title": $0.title, "text": (try? String(contentsOf: $0.url, encoding: .utf8)) ?? ""] },
                "images": items.filter(\.isImage).map { ["title": $0.title, "path": $0.url.path] }
            ], error: nil)

        case "researchLatest":
            reply(identifier, ok: true, result: companionManager.researchController.lastStatus, error: nil)

        case "stop":
            companionManager.speechOutputClient.activeCoordinator?.bargeIn(.newQuestion)
            companionManager.speechOutputClient.stopPlayback()
            reply(identifier, ok: true, result: nil, error: nil)

        default:
            reply(identifier, ok: false, result: nil, error: "unknown command \(commandName)")
        }
    }

    /// The answer's words without tags or blocks (turn.json rawResponse).
    static func spokenAnswer(inTurn turnDirectoryURL: URL) -> String? {
        guard let data = try? Data(contentsOf: turnDirectoryURL.appendingPathComponent("turn.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["rawResponse"] as? String else { return nil }
        var words = ArticleSummarySpeech.narrationOutsideActionBlocks(raw)
        words = words.replacingOccurrences(of: #"(?s)<whiteboard>.*?(</whiteboard>|$)"#, with: "", options: .regularExpression)
        words = words.replacingOccurrences(of: #"\[(POINT|MARK|WORKER|SNAP|NOTES|CODEMODE|AGENTS):[^\]]*\]"#, with: "", options: .regularExpression)
        return words.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
