//
//  ConnectorHub.swift
//  leanring-buddy
//
//  Theo's own connectors. A thin wrapper around the connector hub, the `theo-connectors` helper in
//  Theo.app/Contents/Helpers (built by Tools/build-connectors-helper.sh from crossplatform/crates/theo-connectors; its command
//  line is crossplatform/docs/CONNECTORS.md). It runs the helper, reads the one JSON object each command prints, writes and
//  deletes the ticket for each bot turn, and says how a brain starts the hub as an MCP server for that turn. The pure rules
//  (levels, which route an app takes, each brain's settings, the move from the old fixed list) are ClickyCore
//  `Team/ConnectorHubRules.swift`.
//
//  Without the helper (Rust wasn't installed when this Theo was built) `isAvailable` is false, the Connectors screen says
//  "connector helper missing", and connectors work as they did before the hub: through Claude Code.
//

import ClickyCore
import Foundation

struct ConnectorHubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One tool of an app, as `theo-connectors tools <id>` prints it.
struct HubTool: Equatable {
    let name: String
    /// `<app id>__<tool>`, the name brains see.
    let exposedName: String
    let title: String?
    let description: String?
    /// The JSON Schema of its arguments, as JSON.
    let inputSchemaJSON: Data
    /// read, change or irreversible.
    let effect: String
    let readOnly: Bool
}

/// One tool call's answer (`theo-connectors call`).
struct HubCallResult {
    /// The MCP CallToolResult as JSON.
    let resultJSON: Data
    /// The tool ran but said it failed.
    let isError: Bool
    /// Its text parts joined, for a brain that only takes text.
    let text: String
}

/// What the starter catalog offers (`theo-connectors catalog`).
struct HubCatalogEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let description: String
    /// How it is reached, in words ("Your Claude account (needs Claude Code)").
    let via: String
}

enum ConnectorHub {
    // MARK: Where things are

    /// Test profile only: a stand-in helper (a debug build of theo-connectors), instead of the one in Theo.app.
    static let testHelperKey = "test.connectors.helper"

    /// The helper in Theo.app, or the test profile's stand-in. Nil when this build has none.
    static var helperURL: URL? {
        if TheoProfile.isTest, let path = UserDefaults.standard.string(forKey: testHelperKey), !path.isEmpty {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/theo-connectors")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    static var isAvailable: Bool { helperURL != nil }

    /// The words every screen uses when the helper isn't in this build.
    static let helperMissingWords = "Connector helper missing: this build of Theo was made without it, so apps work only through Claude Code, as before."

    /// A test instance's tools process (`Clicky --mcp` started by a test bot) is told the test home this way.
    private static var controlHome: URL? {
        ProcessInfo.processInfo.environment["THEO_CONTROL_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Theo's data folder, passed as `--data`; the hub keeps everything in its `Connectors` folder. A test profile has its own home,
    /// so its own folder.
    static var dataFolder: URL {
        (controlHome ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Library/Application Support/Theo", isDirectory: true)
    }

    static var ticketFolder: URL { dataFolder.appendingPathComponent("Connectors/tickets", isDirectory: true) }

    /// Tests never touch the real Keychain: the vault key lives in a file in the test profile's own folder.
    static var keepsVaultKeyInFile: Bool { TheoProfile.isTest || controlHome != nil }

    private static var commonArguments: [String] {
        ["--data", dataFolder.path] + (keepsVaultKeyInFile ? ["--key-store", "file"] : [])
    }

    /// Where Claude Code is, for claude-account apps (a Mac app's PATH doesn't reach ~/.local/bin), found once.
    private static var claudeCodeLocation: String?? = nil
    private static func claudeCodePath() -> String? {
        if let known = claudeCodeLocation { return known }
        let found = TheoProfile.isTest ? BotRunner.executable(for: .claude)?.path : BrainCLIRunner.locateExecutable(for: .claude)?.path
        claudeCodeLocation = .some(found)
        return found
    }

    /// What the helper needs from its surroundings: where Claude Code is, and a PATH that finds `npx`, `uvx` and the like for
    /// local apps. Never a key or token.
    static var helperEnvironmentAdditions: [String: String] {
        var additions: [String: String] = [:]
        if let claude = claudeCodePath() { additions["THEO_CONNECTORS_CLAUDE"] = claude }
        additions["PATH"] = HarnessCatalog.childEnvironment()["PATH"] ?? "/usr/bin:/bin"
        return additions
    }

    // MARK: Running the helper

    /// Runs one command and returns the JSON object it printed. Throws the hub's own sentence when it says `ok: false`.
    @discardableResult
    static func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 90) async throws -> [String: Any] {
        guard let helper = helperURL else { throw ConnectorHubError(message: helperMissingWords) }
        let fullArguments = commonArguments + arguments
        let environment = HarnessCatalog.childEnvironment(extra: helperEnvironmentAdditions)
        let logFile = logURL
        let output = await Task.detached {
            runHelperBlocking(executable: helper, arguments: fullArguments, environment: environment, input: input, timeout: timeout, logFile: logFile)
        }.value
        return try answer(from: output.standardOutput, exitStatus: output.exitStatus)
    }

    /// The same, synchronously, for `Clicky --mcp` (a process with no run loop to wait on).
    @discardableResult
    static func runNow(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 90) throws -> [String: Any] {
        guard let helper = helperURL else { throw ConnectorHubError(message: helperMissingWords) }
        let output = runHelperBlocking(executable: helper, arguments: commonArguments + arguments,
                                       environment: HarnessCatalog.childEnvironment(extra: helperEnvironmentAdditions),
                                       input: input, timeout: timeout, logFile: logURL)
        return try answer(from: output.standardOutput, exitStatus: output.exitStatus)
    }

    /// The helper's diagnostics (never a token: the hub doesn't print one).
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/connectors.log")
    }

    private static func answer(from standardOutput: Data, exitStatus: Int32) throws -> [String: Any] {
        // The last line that is a JSON object is the answer (`signin` prints two; the others one).
        let lines = String(decoding: standardOutput, as: UTF8.self).split(whereSeparator: \.isNewline).reversed()
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["ok"] as? Bool == false {
                throw ConnectorHubError(message: object["error"] as? String ?? "The connector helper couldn't do that.")
            }
            return object
        }
        throw ConnectorHubError(message: "The connector helper didn't answer (exit \(exitStatus)). Details are in ~/Library/Logs/Clicky/connectors.log.")
    }

    private nonisolated struct HelperOutput: Sendable {
        let standardOutput: Data
        let exitStatus: Int32
    }

    /// Starts the helper, gives it `input` on standard input (a pasted token: never on the command line, where any process
    /// list would show it), and waits at most `timeout` seconds. Standard error goes to the log.
    nonisolated private static func runHelperBlocking(executable: URL, arguments: [String], environment: [String: String], input: Data?,
                                                      timeout: TimeInterval, logFile: URL) -> HelperOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) { FileManager.default.createFile(atPath: logFile.path, contents: nil) }
        let logHandle = try? FileHandle(forWritingTo: logFile)
        logHandle?.seekToEndOfFile()
        process.standardError = logHandle ?? FileHandle.nullDevice
        let standardInput = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : standardInput
        do {
            try process.run()
        } catch {
            try? logHandle?.close()
            return HelperOutput(standardOutput: Data(), exitStatus: -1)
        }
        if let input {
            standardInput.fileHandleForWriting.write(input)
            try? standardInput.fileHandleForWriting.close()
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        try? logHandle?.close()
        return HelperOutput(standardOutput: data, exitStatus: process.terminationStatus)
    }

    // MARK: The list of apps

    /// The apps as last read, for code that can't wait (the bot settings' lists). Every turn reads them again.
    private(set) static var cachedApps: [HubAppRecord] = []

    /// Every app with its status. `check`: reconnect each one first (slow: it reaches every app; claude-account apps share one
    /// `claude mcp list`). Without it nothing is contacted.
    static func list(check: Bool = false) async throws -> [HubAppRecord] {
        let answer = try await run(check ? ["list", "--check"] : ["list"], timeout: check ? 180 : 30)
        guard let apps = HubAppRecord.list(fromHubAnswer: answer) else { throw ConnectorHubError(message: "The connector helper's list couldn't be read.") }
        cachedApps = apps
        return apps
    }

    /// The same, synchronously, for `Clicky --mcp`.
    static func listNow() throws -> [HubAppRecord] {
        let answer = try runNow(["list"], timeout: 30)
        guard let apps = HubAppRecord.list(fromHubAnswer: answer) else { throw ConnectorHubError(message: "The connector helper's list couldn't be read.") }
        cachedApps = apps
        return apps
    }

    static func catalog() async throws -> [HubCatalogEntry] {
        let answer = try await run(["catalog"], timeout: 20)
        let apps = (answer["catalog"] as? [String: Any])?["apps"] as? [[String: Any]] ?? []
        return apps.compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
            return HubCatalogEntry(id: id, name: name, kind: entry["kind"] as? String ?? "", description: entry["description"] as? String ?? "",
                                   via: entry["via"] as? String ?? "")
        }
    }

    /// Adds an app from the starter catalog, and checks it.
    static func addFromCatalog(_ catalogID: String, check: Bool = true) async throws {
        try await run(["add", "--catalog", catalogID] + (check ? [] : ["--no-check"]), timeout: check ? 120 : 30)
    }

    /// Adds an app the owner typed in ("Add your own"), and checks it. `entry` never holds a secret: the hub refuses one.
    static func add(entry: [String: Any], check: Bool = true) async throws {
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            throw ConnectorHubError(message: "That app couldn't be written down.")
        }
        try await run(["add", "--json", String(decoding: data, as: UTF8.self)] + (check ? [] : ["--no-check"]), timeout: check ? 120 : 30)
    }

    static func remove(_ appID: String) async throws { try await run(["remove", appID]) }

    static func setEnabled(_ appID: String, _ enabled: Bool) async throws { try await run([enabled ? "enable" : "disable", appID]) }

    /// A pasted token for a token app (empty removes it). It goes on standard input, never on the command line.
    static func savePastedToken(_ appID: String, token: String) async throws {
        try await run(["set-secret", appID], input: Data(token.utf8))
    }

    /// Reconnects one app, or all, and records what it found.
    static func check(_ appID: String? = nil) async throws {
        try await run(["check"] + (appID.map { [$0] } ?? []), timeout: 180)
    }

    static func signOut(_ appID: String) async throws { try await run(["signout", appID]) }

    /// Signs in to an OAuth app: the hub prints the address to open (opened in the owner's browser by `open`), then waits for
    /// the browser to come back. Returns the app's status afterwards.
    static func signIn(_ appID: String, timeout: TimeInterval = 300, open: @escaping @MainActor (URL) -> Void) async throws -> String {
        guard let helper = helperURL else { throw ConnectorHubError(message: helperMissingWords) }
        let process = Process()
        process.executableURL = helper
        process.arguments = commonArguments + ["signin", appID, "--timeout", String(Int(timeout))]
        process.environment = HarnessCatalog.childEnvironment(extra: helperEnvironmentAdditions)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 15, execute: deadline)
        defer { deadline.cancel() }
        var finalAnswer: [String: Any]?
        for await line in BotRunner.lines(of: output.fileHandleForReading) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["event"] as? String == "open", let address = object["url"] as? String, let url = URL(string: address) {
                open(url)
            } else if object["ok"] != nil {
                finalAnswer = object
            }
        }
        process.waitUntilExit()
        guard let finalAnswer else { throw ConnectorHubError(message: "Signing in didn't finish.") }
        if finalAnswer["ok"] as? Bool == false {
            throw ConnectorHubError(message: finalAnswer["error"] as? String ?? "Signing in didn't finish.")
        }
        return finalAnswer["status"] as? String ?? "unknown"
    }

    /// The app's tools, each with what it does to the world.
    static func tools(appID: String) async throws -> [HubTool] {
        let answer = try await run(["tools", appID], timeout: 120)
        return (answer["tools"] as? [[String: Any]] ?? []).compactMap(tool(from:))
    }

    static func toolsNow(appID: String) throws -> [HubTool] {
        let answer = try runNow(["tools", appID], timeout: 120)
        return (answer["tools"] as? [[String: Any]] ?? []).compactMap(tool(from:))
    }

    private static func tool(from entry: [String: Any]) -> HubTool? {
        guard let name = entry["name"] as? String else { return nil }
        let schema = entry["inputSchema"] ?? ["type": "object"]
        let schemaData = JSONSerialization.isValidJSONObject(schema) ? ((try? JSONSerialization.data(withJSONObject: schema)) ?? Data("{}".utf8)) : Data("{}".utf8)
        return HubTool(name: name, exposedName: entry["exposedName"] as? String ?? name, title: entry["title"] as? String,
                       description: entry["description"] as? String, inputSchemaJSON: schemaData,
                       effect: entry["effect"] as? String ?? "change", readOnly: entry["readOnly"] as? Bool ?? false)
    }

    /// Runs one tool for a bot turn, under that turn's ticket (API-key bots, and `claudia_app`).
    static func call(appID: String, tool: String, argumentsJSON: Data, ticket: URL) async throws -> HubCallResult {
        let answer = try await run(["call", appID, tool, "--args", String(decoding: argumentsJSON, as: UTF8.self), "--ticket", ticket.path], timeout: 240)
        return callResult(from: answer)
    }

    static func callNow(appID: String, tool: String, argumentsJSON: Data, ticket: URL) throws -> HubCallResult {
        let answer = try runNow(["call", appID, tool, "--args", String(decoding: argumentsJSON, as: UTF8.self), "--ticket", ticket.path], timeout: 240)
        return callResult(from: answer)
    }

    private static func callResult(from answer: [String: Any]) -> HubCallResult {
        let result = answer["result"] as? [String: Any] ?? [:]
        let resultData = JSONSerialization.isValidJSONObject(result) ? ((try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)) : Data("{}".utf8)
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        return HubCallResult(resultJSON: resultData, isError: result["isError"] as? Bool ?? false, text: text)
    }

    /// The servers Claude Code has on this Mac (empty without Claude Code).
    static func claudeCodeServers() async -> [String] {
        guard let answer = try? await run(["discover-claude"], timeout: 120) else { return [] }
        return (answer["servers"] as? [[String: Any]] ?? []).compactMap { $0["server"] as? String }
    }

    // MARK: One bot turn

    /// Which of the bot's apps go through the hub this turn and which a Claude bot reaches directly. Reads the list fresh (it
    /// contacts nothing), so an app added a moment ago counts. Without the helper, nothing goes through the hub.
    static func turnPlan(for bot: NativeBot, ownerAsked: Bool) async -> ConnectorHubTurnPlan {
        guard isAvailable, !bot.apps.isEmpty else { return .nothing }
        let apps = (try? await list()) ?? cachedApps
        return ConnectorHubTurnPlan.make(botApps: bot.apps, savedLevels: bot.appLevels ?? [:], hubApps: apps, engine: bot.provider, ownerAsked: ownerAsked)
    }

    /// Writes a ticket for one turn into the hub's ticket folder (only this user can read it) and returns it. `fileName`: a fixed
    /// name, for Grok, whose config names the ticket file ahead of time.
    static func issueTicket(botID: String, apps: [String: HubAccessLevel], ownerAsked: Bool, expiresIn: TimeInterval,
                            fileName: String? = nil) throws -> URL {
        let folder = ticketFolder
        let fileManager = FileManager.default
        for privateFolder in [folder.deletingLastPathComponent(), folder] {
            try fileManager.createDirectory(at: privateFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateFolder.path)
        }
        let name = fileName ?? ConnectorHubTicket.fileName(botID: botID, unique: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let ticket = folder.appendingPathComponent(name)
        let data = ConnectorHubTicket.json(botID: botID, apps: apps, ownerAsked: ownerAsked, expiresAt: Date().addingTimeInterval(expiresIn))
        // Written beside, made private, then moved in place: the hub never reads half a ticket, and nobody else can read it at all.
        let temporary = folder.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ConnectorHubError(message: "Couldn't write the ticket for this turn.")
        }
        if fileManager.fileExists(atPath: ticket.path) { try? fileManager.removeItem(at: ticket) }
        try fileManager.moveItem(at: temporary, to: ticket)
        return ticket
    }

    /// A ticket for the bot's apps that go through the hub this turn; nil when there are none.
    static func issueTicket(for bot: NativeBot, plan: ConnectorHubTurnPlan, ownerAsked: Bool, expiresIn: TimeInterval) -> URL? {
        guard plan.usesHub else { return nil }
        return try? issueTicket(botID: bot.id, apps: plan.ticketApps, ownerAsked: ownerAsked, expiresIn: expiresIn)
    }

    /// Ends a turn's apps at once: the hub reads the ticket on every call.
    static func revokeTicket(_ ticket: URL?) {
        guard let ticket, ticket.deletingLastPathComponent().standardizedFileURL.path == ticketFolder.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: ticket)
    }

    /// How a brain starts the hub for a turn with this ticket.
    static func serverLaunch(ticket: URL) -> HubServerLaunch? {
        guard let helper = helperURL else { return nil }
        return HubServerLaunch(command: helper.path, arguments: commonArguments + ["serve", "--ticket", ticket.path],
                               environment: helperEnvironmentAdditions)
    }

    // MARK: Moving the old fixed list into the hub

    static let movedOldConnectorsKey = "v4.connectors.movedIntoHub"

    /// Once, on the first launch with the helper: every app a bot uses, and every app Claude Code has that used to be on the
    /// fixed list, becomes a hub app with the same id (Hostinger and Content Studio as entries of the owner's own), so no bot
    /// loses an app. Tried again on the next launch if anything failed.
    static func moveOldConnectorsOnce(botApps: Set<String>) async {
        guard isAvailable, !UserDefaults.standard.bool(forKey: movedOldConnectorsKey) else { return }
        guard let current = try? await list() else { return }
        let plan = ConnectorHubMigration.plan(botApps: botApps, claudeServers: Set(await claudeCodeServers()), hubIDs: Set(current.map(\.id)))
        var everythingMoved = true
        for catalogID in plan.catalogIDs {
            do { try await addFromCatalog(catalogID, check: false) } catch { everythingMoved = false }
        }
        for entry in plan.ownApps {
            do { try await add(entry: entry, check: false) } catch { everythingMoved = false }
        }
        if everythingMoved { UserDefaults.standard.set(true, forKey: movedOldConnectorsKey) }
        _ = try? await list()
    }
}
