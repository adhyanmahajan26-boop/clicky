//
//  APIChatTools.swift
//  leanring-buddy
//
//  The tools a bot on an API key may call in one turn: reading and writing its own memory folder, and the connector hub apps it
//  was given, at the level it was given (a turn not from the owner's own words reads and drafts at most). The loop that runs them and the wire
//  format for each API are in ClickyCore `Team/APIChatToolCalling.swift`; `APIChat.stream` sends the requests.
//

import ClickyCore
import Foundation

/// One hub app tool, as `tools <id>` lists it (`crossplatform/docs/CONNECTORS.md`).
struct APIChatHubTool: Equatable, Sendable {
    var appID: String
    var appName: String
    /// The tool's own name, which `call` takes.
    var toolName: String
    /// `<app id>__<tool>`, the name the model calls it by.
    var exposedName: String
    var description: String
    var inputSchemaJSON: String
    /// `read`, `change` or `irreversible`.
    var effect: String
}

/// What the toolbox needs from Theo's connector hub. `HubConnectorSource` is the real one; tests use a stand-in.
protocol APIChatConnectorSource: Sendable {
    /// The hub apps this bot was given, each with its level (`read`, `readAndDraft` or `full`).
    func appLevels(for bot: NativeBot) async -> [String: String]
    func tools(appID: String) async throws -> [APIChatHubTool]
    /// A ticket for this turn: the hub runs nothing for a bot without one.
    func issueTicket(botID: String, appLevels: [String: String], ownerAsked: Bool, expiresAt: Date) async throws -> URL
    func revokeTicket(_ ticket: URL) async
    /// Runs one tool. A tool that ran and failed is `isError`; a call the hub refused (or that never ran) throws.
    func call(appID: String, toolName: String, argumentsJSON: String, ticket: URL) async throws -> (text: String, isError: Bool)
}

final class APIChatToolbox: @unchecked Sendable {
    static let memoryListToolName = "memory_list"
    static let memoryReadToolName = "memory_read"
    static let memoryWriteToolName = "memory_write"
    static let maximumMemoryReadCharacters = 100_000
    static let maximumMemoryWriteCharacters = 200_000
    static let maximumMemoryFilesListed = 200

    /// What the model is offered.
    let definitions: [APIChatToolDefinition]
    /// Added to the system prompt: what the tools reach, and which apps aren't there this turn.
    let promptSection: String
    private let memoryFolder: URL
    private let hubToolsByExposedName: [String: APIChatHubTool]
    private let connectorSource: APIChatConnectorSource?
    private let ticket: URL?

    init(memoryFolder: URL, hubTools: [APIChatHubTool], appLevels: [String: String], ownerAsked: Bool,
         connectorSource: APIChatConnectorSource?, ticket: URL?, appsNotReachable: [String]) {
        self.memoryFolder = memoryFolder
        self.connectorSource = connectorSource
        self.ticket = ticket
        var toolsByExposedName: [String: APIChatHubTool] = [:]
        for hubTool in hubTools where toolsByExposedName[hubTool.exposedName] == nil { toolsByExposedName[hubTool.exposedName] = hubTool }
        hubToolsByExposedName = toolsByExposedName
        let hubDefinitions = hubTools.filter { toolsByExposedName[$0.exposedName] == $0 }.map { hubTool in
            APIChatToolDefinition(name: hubTool.exposedName, description: hubTool.description, inputSchemaJSON: hubTool.inputSchemaJSON)
        }
        definitions = APIChatToolbox.memoryToolDefinitions + hubDefinitions
        promptSection = APIChatToolbox.promptSection(hubTools: hubTools, appLevels: appLevels, ownerAsked: ownerAsked, appsNotReachable: appsNotReachable)
    }

    /// The toolbox for one turn of `bot`. Lists its apps' tools (all at once), keeps the ones its level allows, and issues the
    /// turn's ticket. Without the hub, or when nothing can be reached, it still has the memory tools.
    /// `memoryFolder`: the bot's own folder in Theo's data; tests pass a scratch folder.
    static func make(for bot: NativeBot, ownerAsked: Bool, turnLimitSeconds: Double,
                     connectorSource: APIChatConnectorSource? = HubConnectorSource.ifInstalled(),
                     memoryFolder givenMemoryFolder: URL? = nil) async -> APIChatToolbox {
        let memoryFolder = givenMemoryFolder ?? BotMemory.file(botID: bot.id).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: memoryFolder, withIntermediateDirectories: true)
        guard let connectorSource else {
            return APIChatToolbox(memoryFolder: memoryFolder, hubTools: [], appLevels: [:], ownerAsked: ownerAsked,
                                  connectorSource: nil, ticket: nil, appsNotReachable: [])
        }
        let appLevels = await connectorSource.appLevels(for: bot)
        var offeredTools: [APIChatHubTool] = []
        var appsNotReachable: [String] = []
        await withTaskGroup(of: (String, Result<[APIChatHubTool], Error>).self) { group in
            for appID in appLevels.keys {
                group.addTask {
                    do { return (appID, .success(try await connectorSource.tools(appID: appID))) } catch { return (appID, .failure(error)) }
                }
            }
            for await (appID, listing) in group {
                switch listing {
                case .success(let tools):
                    let level = appLevels[appID]
                    // A tool the level doesn't allow is never offered (the hub refuses it too, if asked by name anyway).
                    let effectiveLevel = HubAccessLevel(saved: level).effective(ownerAsked: ownerAsked)
                    offeredTools += tools.filter { hubTool in
                        // An effect this build doesn't know is never offered.
                        let allowed = HubToolEffect(rawValue: hubTool.effect)?.allowed(at: effectiveLevel) ?? false
                        return allowed && APIChatToolWire.isUsableToolName(hubTool.exposedName)
                    }
                case .failure(let error):
                    appsNotReachable.append("\(appID) (\(error.localizedDescription.prefix(120)))")
                }
            }
        }
        offeredTools.sort { $0.exposedName < $1.exposedName }
        var ticket: URL?
        if !offeredTools.isEmpty {
            do {
                ticket = try await connectorSource.issueTicket(botID: bot.id, appLevels: appLevels, ownerAsked: ownerAsked,
                                                               expiresAt: Date().addingTimeInterval(turnLimitSeconds + 120))
            } catch {
                appsNotReachable = appLevels.keys.sorted().map { "\($0) (\(error.localizedDescription.prefix(120)))" }
                offeredTools = []
            }
        }
        return APIChatToolbox(memoryFolder: memoryFolder, hubTools: offeredTools, appLevels: appLevels, ownerAsked: ownerAsked,
                              connectorSource: connectorSource, ticket: ticket, appsNotReachable: appsNotReachable.sorted())
    }

    /// Ends the turn's access: the ticket is revoked, so nothing more runs on it.
    func finish() async {
        guard let ticket, let connectorSource else { return }
        await connectorSource.revokeTicket(ticket)
    }

    /// Runs one call. Never throws: anything that goes wrong is an error result the model can read and work around.
    func run(_ call: APIChatToolCall) async -> APIChatToolResult {
        let arguments = APIChatToolWire.argumentsObject(call.argumentsJSON)
        switch call.toolName {
        case Self.memoryListToolName:
            return listMemory(callID: call.callID)
        case Self.memoryReadToolName:
            return readMemory(callID: call.callID, path: arguments["path"] as? String ?? "")
        case Self.memoryWriteToolName:
            return writeMemory(callID: call.callID, path: arguments["path"] as? String ?? "", content: arguments["content"] as? String,
                               append: arguments["append"] as? Bool ?? false)
        default:
            // Only a tool this bot was offered: a name it made up, or another bot's app, never reaches the hub.
            guard let hubTool = hubToolsByExposedName[call.toolName], let connectorSource, let ticket else {
                return APIChatToolResult(callID: call.callID, text: "There is no tool called \(call.toolName) for you. Use only the tools you were given.", isError: true)
            }
            let argumentsJSON = call.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : call.argumentsJSON
            do {
                let result = try await connectorSource.call(appID: hubTool.appID, toolName: hubTool.toolName, argumentsJSON: argumentsJSON, ticket: ticket)
                return APIChatToolResult(callID: call.callID, text: result.text.isEmpty ? "(The tool returned nothing.)" : result.text, isError: result.isError)
            } catch {
                return APIChatToolResult(callID: call.callID, text: "\(hubTool.appName) didn't run that: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: Its own memory folder

    static let memoryToolDefinitions: [APIChatToolDefinition] = [
        APIChatToolDefinition(name: memoryListToolName,
                              description: "List the files in your own memory folder (memory.md is what you remember; skills are skills/<name>/SKILL.md).",
                              inputSchemaJSON: #"{"type":"object","properties":{}}"#),
        APIChatToolDefinition(name: memoryReadToolName,
                              description: "Read a file in your own memory folder.",
                              inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Path inside your memory folder, for example memory.md"}},"required":["path"]}"#),
        APIChatToolDefinition(name: memoryWriteToolName,
                              description: "Write a file in your own memory folder: replace it, or add to its end with append. Keep memory.md short and current.",
                              inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Path inside your memory folder, for example memory.md"},"content":{"type":"string"},"append":{"type":"boolean","description":"Add to the end instead of replacing"}},"required":["path","content"]}"#)
    ]

    private func listMemory(callID: String) -> APIChatToolResult {
        let root = memoryFolder.standardizedFileURL.resolvingSymlinksInPath()
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                        options: [.skipsHiddenFiles])
        var lines: [String] = []
        while let fileURL = enumerator?.nextObject() as? URL, lines.count < Self.maximumMemoryFilesListed {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            let relativePath = filePath.hasPrefix(root.path + "/") ? String(filePath.dropFirst(root.path.count + 1)) : fileURL.lastPathComponent
            lines.append("\(relativePath) (\(values?.fileSize ?? 0) bytes)")
        }
        return APIChatToolResult(callID: callID, text: lines.isEmpty ? "Your memory folder is empty." : lines.sorted().joined(separator: "\n"), isError: false)
    }

    private func readMemory(callID: String, path: String) -> APIChatToolResult {
        guard let fileURL = BotMemoryFolderPath.resolve(path, inside: memoryFolder) else {
            return APIChatToolResult(callID: callID, text: "\(path) isn't in your memory folder. Use a path inside it, like memory.md.", isError: true)
        }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return APIChatToolResult(callID: callID, text: "There's no readable text file at \(path) in your memory folder.", isError: true)
        }
        guard text.count > Self.maximumMemoryReadCharacters else { return APIChatToolResult(callID: callID, text: text, isError: false) }
        return APIChatToolResult(callID: callID, text: String(text.prefix(Self.maximumMemoryReadCharacters)) + "\n…(cut: the file is \(text.count) characters long)", isError: false)
    }

    private func writeMemory(callID: String, path: String, content: String?, append: Bool) -> APIChatToolResult {
        guard let fileURL = BotMemoryFolderPath.resolve(path, inside: memoryFolder) else {
            return APIChatToolResult(callID: callID, text: "\(path) isn't in your memory folder. Use a path inside it, like memory.md.", isError: true)
        }
        guard let content else { return APIChatToolResult(callID: callID, text: "Nothing to write: give content.", isError: true) }
        guard content.count <= Self.maximumMemoryWriteCharacters else {
            return APIChatToolResult(callID: callID, text: "That's too long to keep (over \(Self.maximumMemoryWriteCharacters) characters). Keep memory short.", isError: true)
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var newText = content
            if append, let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
                newText = existing.isEmpty || existing.hasSuffix("\n") ? existing + content : existing + "\n" + content
            }
            try newText.write(to: fileURL, atomically: true, encoding: .utf8)
            return APIChatToolResult(callID: callID, text: append ? "Added to \(path)." : "Saved \(path).", isError: false)
        } catch {
            return APIChatToolResult(callID: callID, text: "Couldn't write \(path): \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: What the bot is told

    static func promptSection(hubTools: [APIChatHubTool], appLevels: [String: String], ownerAsked: Bool, appsNotReachable: [String]) -> String {
        var lines = ["Your tools: \(memoryListToolName), \(memoryReadToolName) and \(memoryWriteToolName) reach your own memory folder and nothing else. " +
                     "Save what you'll need next time to memory.md there, short and current."]
        var appNamesByID: [String: String] = [:]
        for hubTool in hubTools { appNamesByID[hubTool.appID] = hubTool.appName }
        let appsWithTools = appNamesByID.keys.sorted()
        if !appsWithTools.isEmpty {
            let described = appsWithTools.map { appID in
                "\(appNamesByID[appID] ?? appID) (\(levelWords(appLevels[appID] ?? HubAccessLevel.standard.rawValue, ownerAsked: ownerAsked)))"
            }
            lines.append("Your apps, as tools named <app>__<tool>: " + described.joined(separator: ", ") + ". " +
                         "Use them when the request needs them, and only say something was done when the tool's answer shows it was.")
        }
        if !appsNotReachable.isEmpty {
            lines.append("These apps of yours can't be reached this turn: " + appsNotReachable.joined(separator: "; ") +
                         ". If the request needs one, say so plainly rather than guessing.")
        }
        return lines.joined(separator: "\n")
    }

    private static func levelWords(_ level: String, ownerAsked: Bool) -> String {
        // The level that holds for this turn: a turn not from the owner's own words is never `full`.
        switch HubAccessLevel(saved: level).effective(ownerAsked: ownerAsked) {
        case .full: return "everything its tools do"
        case .readAndDraft:
            let words = "look things up and draft or change, never send, share or delete"
            return ownerAsked ? words : words + ": this turn didn't come from the owner's own words"
        case .read: return "look things up only"
        }
    }
}

/// The real hub, through package 3's `ConnectorHub` (the `theo-connectors` helper in Theo.app, `crossplatform/docs/CONNECTORS.md`).
struct HubConnectorSource: APIChatConnectorSource {
    /// Nil when this build has no helper (Rust wasn't there when it was built): the bot then has its memory tools only.
    static func ifInstalled() -> HubConnectorSource? { ConnectorHub.isAvailable ? HubConnectorSource() : nil }

    /// The bot's hub apps with its saved level on each (the owner's-words rule is applied by the toolbox and the ticket). An
    /// API-key bot reaches every app through the hub, claude-account ones too.
    func appLevels(for bot: NativeBot) async -> [String: String] {
        let plan = await ConnectorHub.turnPlan(for: bot, ownerAsked: true)
        return plan.ticketApps.mapValues { level in level.rawValue }
    }

    func tools(appID: String) async throws -> [APIChatHubTool] {
        let appName = ConnectorHub.cachedApps.first { app in app.id == appID }?.name ?? appID
        return try await ConnectorHub.tools(appID: appID).map { hubTool in
            let words = hubTool.description ?? hubTool.title ?? ""
            return APIChatHubTool(appID: appID, appName: appName, toolName: hubTool.name, exposedName: hubTool.exposedName,
                                  description: words.hasPrefix("[") ? words : "[\(appName)] \(words)",
                                  inputSchemaJSON: String(decoding: hubTool.inputSchemaJSON, as: UTF8.self), effect: hubTool.effect)
        }
    }

    func issueTicket(botID: String, appLevels: [String: String], ownerAsked: Bool, expiresAt: Date) async throws -> URL {
        try ConnectorHub.issueTicket(botID: botID, apps: appLevels.mapValues { level in HubAccessLevel(saved: level) },
                                     ownerAsked: ownerAsked, expiresIn: max(60, expiresAt.timeIntervalSinceNow))
    }

    func revokeTicket(_ ticket: URL) async {
        ConnectorHub.revokeTicket(ticket)
    }

    func call(appID: String, toolName: String, argumentsJSON: String, ticket: URL) async throws -> (text: String, isError: Bool) {
        let result = try await ConnectorHub.call(appID: appID, tool: toolName, argumentsJSON: Data(argumentsJSON.utf8), ticket: ticket)
        let resultObject = (try? JSONSerialization.jsonObject(with: result.resultJSON) as? [String: Any]) ?? [:]
        let words = Self.text(ofToolResult: resultObject)
        return (words.isEmpty ? result.text : words, result.isError)
    }

    /// An MCP CallToolResult as words: its text parts, a note for anything else (an image, a file), else its structured content.
    static func text(ofToolResult result: [String: Any]) -> String {
        let parts: [String] = (result["content"] as? [[String: Any]] ?? []).map { part -> String in
            switch part["type"] as? String {
            case "text": return part["text"] as? String ?? ""
            case "resource": return ((part["resource"] as? [String: Any])?["text"] as? String) ?? "[a file]"
            case let other?: return "[\(other)]"
            case nil: return ""
            }
        }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: "\n") }
        if let structured = result["structuredContent"], JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: .sortedKeys) {
            return String(decoding: data, as: UTF8.self)
        }
        return ""
    }
}
