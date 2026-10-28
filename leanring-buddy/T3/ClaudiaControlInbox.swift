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

    init(companionManager: CompanionManager) {
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
            handle(commandName, command, identifier)
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

    private func handle(_ commandName: String, _ command: [String: Any], _ identifier: String) {
        switch commandName {
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
                        self?.reply(identifier, ok: turnError == nil, result: ["answer": answer, "board": self?.companionManager.boardController.stateSummary() ?? [:]],
                                    error: turnError.map { String(describing: $0) })
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
            Task {
                // Wait for the brief (helpers read in parallel; at most 5 minutes).
                let deadline = Date().addingTimeInterval(300)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                while Date() < deadline, researchController.isRunning {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                let status = researchController.lastStatus
                reply(identifier, ok: (status["state"] as? String) == "done", result: status, error: nil)
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
