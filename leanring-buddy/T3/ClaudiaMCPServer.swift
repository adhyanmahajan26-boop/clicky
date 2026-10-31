//
//  ClaudiaMCPServer.swift
//  leanring-buddy
//
//  `Claudia.app/Contents/MacOS/Clicky --mcp`: Claudia as an MCP server
//  (stdio, JSON-RPC 2.0), so any agent T3 Code runs (Claude Code, Codex,
//  OpenCode, Cursor) can use Claudia's eyes, voice, marks, whiteboards,
//  research agents and actions. This process has no UI: each tool call is
//  handed to the running Claudia through the control inbox (it opens
//  Claudia first when it isn't running) and the reply comes back as the
//  tool's result.
//

import AppKit
import ClickyCore
import Foundation

enum ClaudiaMCPServer {
    static let protocolVersion = "2025-06-18"

    struct Tool {
        let name: String
        let description: String
        let properties: [String: Any]
        let required: [String]
    }

    static let tools: [Tool] = [
        Tool(name: "claudia_ask",
             description: "Hand a request to Theo, the user's on-screen companion on this Mac. She looks at the user's screens and answers with her own brain: spoken out loud, with numbered marks on the real screen, a whiteboard for concepts, background research with Haiku agents, or actions (open apps and sites, search, click, type, highlight an article). Use it for anything to do with the user's screen or for explaining something visually. Returns her answer's words.",
             properties: ["text": ["type": "string", "description": "What to ask or tell Theo, in plain words (as the user would say it)."],
                          "speak": ["type": "boolean", "description": "Say the answer out loud (default true)."]],
             required: ["text"]),
        Tool(name: "claudia_see_screen",
             description: "Screenshots of the user's screens (screen1 has the pointer) plus, per screen, a numbered list of the on-screen elements (buttons, fields, links, text) with ids. Use the ids with claudia_show to point at things.",
             properties: [:], required: []),
        Tool(name: "claudia_show",
             description: """
             Play an answer you wrote through Theo: the words are spoken and her tags run on the user's screen (ids from the last claudia_see_screen). Tags: [POINT:<id>] flies the spark to an element; [MARK:<n>:<id>:<label>|<short note>] draws numbered step <n> on it; ids can also be "x,y:screen2" pixels of that screenshot. A <whiteboard>…</whiteboard> block draws a whiteboard (JSON lines: a header {"wb":1,"title":…,"dir":"TB","sections":[…]}, then elements {"el":"box"|"arrow"|"list"|"text"|"table"|"code"|"math"|"chart",…}, then steps {"step":1,"show":[ids],"say":"…"}). An <actions>{"goal":"…","steps":[{"do":"open_app","name":"…"},{"do":"search","query":"…","engine":"google"},{"do":"open_url","url":"…"},{"do":"click","id":12},{"do":"type","id":12,"text":"…","enter":true},{"do":"highlight","targets":["exact sentence"]}]}</actions> block does things on screen.
             """,
             properties: ["text": ["type": "string", "description": "Spoken words with tags and blocks."],
                          "speak": ["type": "boolean", "description": "Speak the words (default true)."]],
             required: ["text"]),
        Tool(name: "claudia_say",
             description: "Theo says one line out loud (it also shows as a caption).",
             properties: ["text": ["type": "string"]], required: ["text"]),
        Tool(name: "claudia_research",
             description: "Claudia's research agents: one Haiku agent reads each page, then a brief with [n] citations opens in her notes panel. Give urls, or just a question/topic to search for, or say e.g. 'the 3 links on my screen'. Waits for the brief (up to 5 minutes) and returns it.",
             properties: ["question": ["type": "string"], "urls": ["type": "array", "items": ["type": "string"]],
                          "speak": ["type": "boolean", "description": "Say 'your research is ready' when done (default false)."]],
             required: ["question"]),
        Tool(name: "claudia_whiteboard",
             description: "Control Theo's whiteboard: next, back, replay, pause, expand, close, export (PDF + PNG), or state.",
             properties: ["action": ["type": "string", "enum": ["state", "next", "back", "replay", "pause", "expand", "close", "export"]]],
             required: ["action"]),
        Tool(name: "claudia_attachments",
             description: "The notes and marked screenshots the user picked in Theo's Notes tab to use for coding (article notes, research briefs, whiteboards, screenshots with marks). Call this when the user says to use Theo's notes or screenshots for the code.",
             properties: [:], required: []),
        Tool(name: "claudia_stop",
             description: "Stop Theo talking and anything she's doing.",
             properties: [:], required: []),
        Tool(name: "claudia_app",
             description: "Use one of the user's signed-in apps through Theo's Claude account: gmail, notion, calendar (Notion Calendar), drive, docs or sheets. Describe what to look up (or, for gmail, a draft to write) in plain words; it reads and returns the answer. Reading and Gmail drafts only: nothing is sent, deleted or changed.",
             properties: ["app": ["type": "string", "enum": ConnectorBridge.apps.keys.sorted()],
                          "request": ["type": "string", "description": "What to find, read or draft, in plain words."]],
             required: ["app", "request"]),
        Tool(name: "claudia_status",
             description: "Theo's brain model, screens, voice and permissions.",
             properties: [:], required: [])
    ]

    // MARK: - Loop

    /// Reads JSON-RPC messages from stdin (one per line) until it closes, then exits.
    static func runForever() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let method = message["method"] as? String ?? ""
            let identifier = message["id"]
            // Notifications (no id) get no answer.
            guard let identifier else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                send(identifier, result: [
                    "protocolVersion": (params["protocolVersion"] as? String) ?? protocolVersion,
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "theo", "version": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"],
                    "instructions": "Theo is the user's voice and screen companion on this Mac. Use her tools to see the screen, point things out, draw whiteboards, research links with Haiku agents, act on screen, and talk to the user."
                ])
            case "ping":
                send(identifier, result: [:])
            case "tools/list":
                send(identifier, result: ["tools": tools.map { tool in
                    ["name": tool.name, "description": tool.description,
                     "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required]] as [String: Any]
                }])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                send(identifier, result: callTool(name, arguments))
            default:
                send(identifier, error: ["code": -32601, "message": "unknown method \(method)"])
            }
        }
        exit(0)
    }

    private static func send(_ identifier: Any, result: Any? = nil, error: [String: Any]? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": identifier]
        if let error { message["error"] = error } else { message["result"] = result ?? [:] }
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }

    // MARK: - Tools

    static func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        func text(_ string: String, isError: Bool = false) -> [String: Any] {
            ["content": [["type": "text", "text": string]], "isError": isError]
        }
        let command: [String: Any]
        var timeout: TimeInterval = 120
        switch name {
        case "claudia_ask": command = ["cmd": "ask", "text": arguments["text"] ?? "", "speak": arguments["speak"] ?? true]; timeout = 300
        case "claudia_see_screen": command = ["cmd": "see"]; timeout = 30
        case "claudia_show": command = ["cmd": "show", "text": arguments["text"] ?? "", "speak": arguments["speak"] ?? true]; timeout = 300
        case "claudia_say": command = ["cmd": "say", "text": arguments["text"] ?? ""]; timeout = 120
        case "claudia_research": command = ["cmd": "research", "question": arguments["question"] ?? "", "urls": arguments["urls"] ?? [],
                                            "speak": arguments["speak"] ?? false]; timeout = 320
        case "claudia_whiteboard": command = ["cmd": "board", "action": arguments["action"] ?? "state"]
        case "claudia_stop": command = ["cmd": "stop"]
        case "claudia_attachments": command = ["cmd": "attachments"]
        case "claudia_status": command = ["cmd": "status"]
        case "claudia_app":
            let answer = ConnectorBridge.run(app: arguments["app"] as? String ?? "", request: arguments["request"] as? String ?? "")
            return text(answer.text, isError: !answer.ok)
        default: return text("Unknown tool \(name).", isError: true)
        }
        guard ensureClaudiaRunning() else { return text("Theo isn't running and couldn't be opened.", isError: true) }
        guard let reply = sendToClaudia(command, timeout: timeout) else { return text("Theo didn't answer in time.", isError: true) }
        let ok = reply["ok"] as? Bool ?? false
        let error = reply["error"] as? String
        let result = reply["result"]

        if name == "claudia_see_screen", ok, let result = result as? [String: Any] {
            var content: [[String: Any]] = []
            let elements = result["elements"] as? [String] ?? []
            for (index, path) in (result["images"] as? [String] ?? []).enumerated() {
                if let data = FileManager.default.contents(atPath: path) {
                    content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
                    try? FileManager.default.removeItem(atPath: path)
                }
                if index < elements.count { content.append(["type": "text", "text": "screen\(index + 1) elements:\n\(elements[index])"]) }
            }
            return ["content": content, "isError": false]
        }
        if name == "claudia_attachments", ok, let result = result as? [String: Any] {
            var content: [[String: Any]] = []
            for note in result["notes"] as? [[String: Any]] ?? [] {
                content.append(["type": "text", "text": "# \(note["title"] as? String ?? "Note")\n\n\(note["text"] as? String ?? "")"])
            }
            for image in result["images"] as? [[String: Any]] ?? [] {
                guard let path = image["path"] as? String, let data = FileManager.default.contents(atPath: path) else { continue }
                content.append(["type": "text", "text": "Screenshot: \(image["title"] as? String ?? "")"])
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"])
            }
            if content.isEmpty { content.append(["type": "text", "text": "Nothing is picked in Theo's Notes tab yet."]) }
            return ["content": content, "isError": false]
        }
        if name == "claudia_ask", let answer = (result as? [String: Any])?["answer"] as? String {
            return text(answer.isEmpty ? (ok ? "Theo answered on screen." : (error ?? "Theo couldn't answer.")) : answer, isError: !ok)
        }
        if name == "claudia_research", let status = result as? [String: Any] {
            let brief = status["brief"] as? String ?? ""
            let sources = (status["sources"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
            let body = brief.isEmpty ? "Research ended: \(status["state"] as? String ?? "unknown")." : brief + "\n\nSources:\n" + sources.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n")
            return text(body, isError: !ok)
        }
        if !ok { return text(error ?? "Theo couldn't do that.", isError: true) }
        let resultText = result.flatMap { value -> String? in
            guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        } ?? "done"
        return text(resultText)
    }

    // MARK: - Talking to the running Claudia

    private static var isClaudiaRunning: Bool {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.personal.clicky")
            .contains { $0.processIdentifier != ownProcessIdentifier && !$0.isTerminated }
    }

    private static func ensureClaudiaRunning() -> Bool {
        if isClaudiaRunning { return true }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-b", Bundle.main.bundleIdentifier ?? "com.personal.clicky"]
        try? opener.run()
        opener.waitUntilExit()
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.5)
            if isClaudiaRunning {
                Thread.sleep(forTimeInterval: 3)
                return true
            }
        }
        return false
    }

    private static func sendToClaudia(_ command: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        let identifier = "mcp-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let inbox = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/control-inbox", isDirectory: true)
        let outbox = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/control-outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard JSONSerialization.isValidJSONObject(command), let data = try? JSONSerialization.data(withJSONObject: command) else { return nil }
        let temporaryURL = inbox.appendingPathComponent("\(identifier).json.tmp")
        let requestURL = inbox.appendingPathComponent("\(identifier).json")
        guard (try? data.write(to: temporaryURL)) != nil, (try? FileManager.default.moveItem(at: temporaryURL, to: requestURL)) != nil else { return nil }
        let replyURL = outbox.appendingPathComponent("\(identifier).json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let replyData = FileManager.default.contents(atPath: replyURL.path),
               let reply = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] {
                try? FileManager.default.removeItem(at: replyURL)
                return reply
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? FileManager.default.removeItem(at: requestURL)
        return nil
    }
}

/// Lets bots on OpenCode or Grok use the claude.ai connectors (Gmail, Notion, Google) that only Claude Code
/// can reach: a Haiku run with just that app's reading tools (and Gmail drafts) does the lookup.
enum ConnectorBridge {
    static let apps: [String: [String]] = [
        "gmail": ["search_threads", "get_thread", "get_message", "list_labels", "list_drafts", "get_draft", "create_draft"]
            .map { "mcp__claude_ai_Gmail__\($0)" },
        "notion": ["notion-search", "notion-fetch", "notion-query-data-sources", "notion-query-multiple-data-sources",
                   "notion-get-comments", "notion-get-users", "notion-get-self", "notion-list-recent-pages",
                   "notion-list-favorite-pages", "notion-list-private-pages", "notion-list-shared-pages",
                   "notion-query-meeting-notes"].map { "mcp__claude_ai_Notion__\($0)" },
        "calendar": ["notion-calendar-list-calendars", "notion-calendar-list-events", "notion-calendar-list-contacts",
                     "notion-calendar-list-calendar-resources"].map { "mcp__claude_ai_Notion__\($0)" },
        "drive": ["search_files", "list_recent_files", "read_file_content", "get_file_metadata"]
            .map { "mcp__claude_ai_Google_Drive__\($0)" },
        "docs": ["mcp__claude_ai_Google_Docs__read_doc", "mcp__claude_ai_Google_Drive__search_files"],
        "sheets": ["mcp__claude_ai_Google_Sheets__get_spreadsheet", "mcp__claude_ai_Google_Sheets__get_values",
                   "mcp__claude_ai_Google_Drive__search_files"],
    ]

    /// Every connector tool that sends, deletes or changes something, denied even if a setting would allow it.
    static let writeTools: [String] = ["send_message", "reply", "forward", "trash_message", "trash_thread", "delete_draft",
                                       "delete_label", "create_label", "update_label", "label_message", "label_thread",
                                       "unlabel_message", "unlabel_thread", "update_message_labels", "mark_message_spam",
                                       "mark_thread_spam", "update_draft", "apply_sensitive_message_label",
                                       "apply_sensitive_thread_label"].map { "mcp__claude_ai_Gmail__\($0)" }
        + ["notion-create-pages", "notion-update-page", "notion-delete-pages", "notion-move-pages", "notion-create-database",
           "notion-delete-databases", "notion-update-data-source", "notion-create-comment", "notion-delete-comment",
           "notion-duplicate-page", "notion-calendar-create-events", "notion-calendar-update-events",
           "notion-calendar-cancel-events"].map { "mcp__claude_ai_Notion__\($0)" }
        + ["create_file", "update_file", "trash_file", "share_file", "copy_file"].map { "mcp__claude_ai_Google_Drive__\($0)" }
        + ["mcp__claude_ai_Google_Docs__update_doc"]
        + ["append_values", "batch_clear_values", "update_values", "update_formulas", "update_spreadsheet", "insert_dimension",
           "copy_sheet_to_another_spreadsheet"].map { "mcp__claude_ai_Google_Sheets__\($0)" }

    static func run(app: String, request: String) -> (ok: Bool, text: String) {
        guard let tools = apps[app.lowercased()] else { return (false, "Unknown app \(app). Use one of: \(apps.keys.sorted().joined(separator: ", ")).") }
        guard !request.isEmpty else { return (false, "Say what to look up.") }
        guard let claude = BrainCLIRunner.locateExecutable(for: .claude) else { return (false, "Claude Code isn't installed on this Mac.") }
        let process = Process()
        process.executableURL = claude
        // dontAsk refuses every tool that isn't pre-allowed (the user's own "auto" mode would otherwise be able
        // to approve sending or deleting), no built-in tools, and the write tools denied outright on top.
        process.arguments = ["-p", "--model", ClickyModels.haiku, "--output-format", "json",
                             "--permission-mode", "dontAsk", "--tools", "",
                             "--disallowedTools"] + writeTools + ["--allowedTools"] + tools + [
            "--append-system-prompt",
            "You fetch information from the user's \(app) for another assistant. Use only your \(app) tools, answer " +
            "with the facts found (names, dates, links, short quotes) and nothing else. Never send, delete or change anything.",
            "--", request]
        let home = FileManager.default.homeDirectoryForCurrentUser
        process.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment
        environment["PWD"] = home.path
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (false, "Couldn't start Claude Code.") }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 240, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? String else {
            return (false, "\(app) lookup didn't finish: \(String(decoding: data.suffix(200), as: UTF8.self))")
        }
        return (object["is_error"] as? Bool != true, result)
    }
}
