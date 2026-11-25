import Foundation

// The Mac app's side of Theo's connector hub (`theo-connectors`, crossplatform/crates/theo-connectors). The hub owns the list
// of apps, their sign-ins and the rule for what a bot may do; the app only reads what the hub prints, writes a ticket for each
// bot turn and hands the brain the hub as an MCP server. Everything here is pure, so it is tested without the helper, a brain or
// a Mac UI. The command-line contract is crossplatform/docs/CONNECTORS.md.

// MARK: - Apps

/// One app in the hub, as `theo-connectors list` prints it.
public struct HubAppRecord: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// An MCP server at a URL (streamable HTTP), signed in with OAuth, a pasted token, or nothing.
        case remote
        /// An MCP server started as a command on this Mac.
        case local
        /// An app the owner connected on claude.ai, reached through Claude Code. What every connector was before the hub.
        case claudeAccount = "claude-account"
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var enabled: Bool
    /// connected, needsSignIn, failed, off or unknown.
    public var status: String
    /// Why it failed, in the hub's words, when `status` is failed.
    public var reason: String?
    public var lastWorked: Date?
    public var lastChecked: Date?
    public var toolCount: Int?
    /// A remote app with a sign-in stored (OAuth tokens or a pasted token).
    public var signedIn: Bool
    /// remote: its address. local: nil. claude-account: nil.
    public var url: String?
    /// remote: none, oauth or token.
    public var auth: String?
    /// local: the command it starts.
    public var command: String?
    /// claude-account: Claude Code's name for it ("claude.ai Gmail").
    public var server: String?
    /// claude-account: the tools that only read, and the ones that write, by their bare names.
    public var readTools: [String]
    public var writeTools: [String]
    /// The catalog entry it was added from.
    public var catalogID: String?
    /// Composio (one API key for many apps): Composio's name for the owner, nil for any other app.
    public var composioUserID: String?
    /// Composio: the apps connected there (toolkit slugs such as `gmail`), as the hub last saw them.
    public var composioConnectedApps: [String]

    public init(id: String, name: String, kind: Kind, enabled: Bool = true, status: String = "unknown", reason: String? = nil,
                lastWorked: Date? = nil, lastChecked: Date? = nil, toolCount: Int? = nil, signedIn: Bool = false, url: String? = nil,
                auth: String? = nil, command: String? = nil, server: String? = nil, readTools: [String] = [], writeTools: [String] = [],
                catalogID: String? = nil, composioUserID: String? = nil, composioConnectedApps: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.status = status
        self.reason = reason
        self.lastWorked = lastWorked
        self.lastChecked = lastChecked
        self.toolCount = toolCount
        self.signedIn = signedIn
        self.url = url
        self.auth = auth
        self.command = command
        self.server = server
        self.readTools = readTools
        self.writeTools = writeTools
        self.catalogID = catalogID
        self.composioUserID = composioUserID
        self.composioConnectedApps = composioConnectedApps
    }

    /// Reads one app from the hub's JSON. Nil for an entry without an id, a name or a kind this app knows.
    public init?(hubJSON entry: [String: Any]) {
        guard let id = entry["id"] as? String, !id.isEmpty,
              let name = entry["name"] as? String,
              let kindText = entry["kind"] as? String, let kind = Kind(rawValue: kindText) else { return nil }
        self.init(id: id, name: name, kind: kind,
                  enabled: entry["enabled"] as? Bool ?? true,
                  status: entry["status"] as? String ?? "unknown",
                  reason: entry["reason"] as? String,
                  lastWorked: HubDates.parse(entry["lastWorked"] as? String),
                  lastChecked: HubDates.parse(entry["lastChecked"] as? String),
                  toolCount: (entry["toolCount"] as? NSNumber)?.intValue,
                  signedIn: entry["signedIn"] as? Bool ?? false,
                  url: entry["url"] as? String,
                  auth: entry["auth"] as? String,
                  command: entry["command"] as? String,
                  server: entry["server"] as? String,
                  readTools: entry["readTools"] as? [String] ?? [],
                  writeTools: entry["writeTools"] as? [String] ?? [],
                  catalogID: entry["catalogId"] as? String,
                  composioUserID: (entry["composio"] as? [String: Any]).map { ($0["userId"] as? String) ?? ComposioWords.defaultUserID },
                  composioConnectedApps: entry["composioConnectedApps"] as? [String] ?? [])
    }

    /// The apps in a `list` answer (`{"ok":true,"apps":[…]}`), or nil when the answer isn't one.
    public static func list(fromHubAnswer answer: [String: Any]) -> [HubAppRecord]? {
        guard answer["ok"] as? Bool == true, let apps = answer["apps"] as? [[String: Any]] else { return nil }
        return apps.compactMap(HubAppRecord.init(hubJSON:))
    }

    /// The hub's status in the words the Connectors screen and cards already use. An app that is off reads as not connected.
    public var connectorState: ConnectorState {
        guard enabled else { return .missing }
        switch status {
        case "connected": return .connected
        case "needsSignIn": return .needsSignIn
        case "failed": return .failed(reason ?? "It didn't answer.")
        case "off": return .missing
        default: return .unknown
        }
    }

    public var isConnected: Bool { enabled && status == "connected" }
    public var needsSignIn: Bool { enabled && status == "needsSignIn" }
    public var isClaudeAccount: Bool { kind == .claudeAccount }
    /// Signing in happens inside Theo (the hub's browser sign-in) only for a remote OAuth app. A claude-account app is signed in
    /// on claude.ai, and a token app takes a pasted token.
    public var signsInWithBrowser: Bool { kind == .remote && auth == "oauth" }
    public var takesPastedToken: Bool { kind == .remote && auth == "token" }
    /// One Composio API key for many apps; its pasted token is that key.
    public var isComposio: Bool { kind == .remote && composioUserID != nil }
}

/// The words for Composio's apps (toolkit slugs such as `googlecalendar`), and what the owner types to connect one.
public enum ComposioWords {
    public static let defaultUserID = "vello"
    /// Where a key is made.
    public static let keysAddress = "https://dashboard.composio.dev"
    /// Offered when connecting an app; any other slug Composio knows works too.
    public static let suggestedApps = ["gmail", "googlecalendar", "googledrive", "googlesheets", "googledocs", "slack", "github", "notion",
                                       "linear", "outlook", "hubspot", "jira", "discord", "trello", "asana", "airtable"]

    private static let knownNames = ["gmail": "Gmail", "googlecalendar": "Google Calendar", "googledrive": "Google Drive", "googledocs": "Google Docs",
                                     "googlesheets": "Google Sheets", "github": "GitHub", "slack": "Slack", "notion": "Notion", "linear": "Linear",
                                     "outlook": "Outlook", "hubspot": "HubSpot", "jira": "Jira", "discord": "Discord", "twitter": "X (Twitter)",
                                     "linkedin": "LinkedIn", "trello": "Trello", "asana": "Asana", "airtable": "Airtable", "dropbox": "Dropbox", "zoom": "Zoom"]

    /// `googlecalendar` → "Google Calendar"; an unknown slug gets a capital letter.
    public static func appName(_ slug: String) -> String {
        knownNames[slug] ?? (slug.prefix(1).uppercased() + slug.dropFirst())
    }

    /// "Google Calendar" → `googlecalendar`, the way the hub names it (`composio::toolkit_slug`).
    public static func slug(fromTyped typed: String) -> String {
        String(typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" })
    }

    /// What the Connectors page says is connected.
    public static func connectedLine(_ slugs: [String], hasKey: Bool) -> String {
        if !hasKey { return "Paste your key first" }
        return slugs.isEmpty ? "None yet. Connect one below, or ask a bot to." : slugs.map(appName).joined(separator: ", ")
    }
}

/// Apps that reach a bot through a Claude account (Gmail, Google Drive, Docs, Sheets, Notion) need Claude Code signed in to a
/// Claude plan. When the same app is connected on the owner's Composio, every bot that isn't on Claude reaches it there instead,
/// with no Claude or ChatGPT plan at all: its ticket names Composio limited to that one app (`composioToolkits`), so a bot given
/// Gmail never gets Slack. A Claude bot keeps Claude Code's own route, which is faster and exactly as before.
public enum ComposioRoute {
    /// The claude-account apps of the starter catalog, by id, and Composio's name for the same app. Notion Calendar isn't
    /// Notion's workspace and has no Composio twin.
    public static let toolkitForCatalogID: [String: String] = [
        "gmail": "gmail", "drive": "googledrive", "docs": "googledocs", "sheets": "googlesheets", "notion": "notion",
    ]

    /// claude.ai's server names for apps the owner added from Claude Code's list, and Composio's name for each.
    public static let toolkitForClaudeServer: [String: String] = [
        "claude.ai Gmail": "gmail", "claude.ai Google Drive": "googledrive", "claude.ai Google Docs": "googledocs",
        "claude.ai Google Sheets": "googlesheets", "claude.ai Google Calendar": "googlecalendar", "claude.ai Slack": "slack",
        "claude.ai Linear": "linear", "claude.ai Asana": "asana", "claude.ai HubSpot": "hubspot", "claude.ai Atlassian": "jira",
        "claude.ai GitHub": "github", "claude.ai Airtable": "airtable",
    ]

    /// Composio's name for a claude-account app, or nil when it has none (or the app isn't a claude-account one).
    public static func toolkit(for app: HubAppRecord) -> String? {
        guard app.isClaudeAccount else { return nil }
        let catalogID = app.catalogID ?? app.id
        if catalogID == "calendar" { return nil }
        if let toolkit = toolkitForCatalogID[catalogID] { return toolkit }
        return app.server.flatMap { toolkitForClaudeServer[$0] }
    }

    /// The owner's Composio, when it can be used: added, on, and with a key saved.
    public static func composio(in hubApps: [HubAppRecord]) -> HubAppRecord? {
        hubApps.first { $0.isComposio && $0.enabled && $0.signedIn }
    }

    /// The Composio app and toolkit that reach this claude-account app without a Claude plan, when the app is connected there.
    public static func route(for app: HubAppRecord, hubApps: [HubAppRecord]) -> (composio: HubAppRecord, toolkit: String)? {
        guard app.enabled, let toolkit = toolkit(for: app), let composio = composio(in: hubApps),
              composio.composioConnectedApps.contains(toolkit) else { return nil }
        return (composio, toolkit)
    }

    /// Whether a bot on this engine takes the Composio route for this app: every engine but Claude, which reaches claude.ai's
    /// apps itself.
    public static func routes(_ app: HubAppRecord, engine: String, hubApps: [HubAppRecord]) -> Bool {
        engine != "claude" && route(for: app, hubApps: hubApps) != nil
    }
}

/// The hub's times are RFC 3339 in whole seconds ("2026-11-13T21:40:33Z").
public enum HubDates {
    public static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    public static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - What a bot may do

/// The most a bot may do with one app. Saved on the bot per app (`NativeBot.appLevels`); missing means `readAndDraft`, which is
/// what bots could do before the hub (look things up, write drafts and pages, never send, delete or share).
public enum HubAccessLevel: String, CaseIterable, Sendable {
    case read
    case readAndDraft
    case full

    public static let standard = HubAccessLevel.readAndDraft

    /// The more allowing of two levels (read < read and draft < everything).
    public static func higher(_ first: HubAccessLevel, _ second: HubAccessLevel) -> HubAccessLevel {
        let order: [HubAccessLevel] = [.read, .readAndDraft, .full]
        return (order.firstIndex(of: first) ?? 0) >= (order.firstIndex(of: second) ?? 0) ? first : second
    }

    /// The level the bot's settings saved, or the standard one.
    public init(saved: String?) {
        self = saved.flatMap(HubAccessLevel.init(rawValue:)) ?? .standard
    }

    /// A turn that didn't come from the owner's own words (a routine, another bot, the local API) never does more than read and
    /// draft, which is what such turns could do before the hub: a routine still writes its draft or its page. Sending, sharing
    /// and deleting (`full`) take the owner's own words.
    public func effective(ownerAsked: Bool) -> HubAccessLevel {
        if ownerAsked { return self }
        return self == .full ? .readAndDraft : self
    }

    public var label: String {
        switch self {
        case .read: return "Read only"
        case .readAndDraft: return "Read and draft"
        case .full: return "Everything"
        }
    }

    public var explanation: String {
        switch self {
        case .read: return "Looks things up. Changes nothing."
        case .readAndDraft: return "Looks things up and writes drafts and pages. Never sends, deletes or shares."
        case .full: return "Everything the app offers, sending and deleting too, when you asked for it yourself."
        }
    }
}

/// What a tool does, from its name, the way the hub decides it (crates/theo-connectors/src/safety.rs) for the words the Mac app
/// needs: Claude bots reach claude-account apps directly through Claude Code, so the app denies those tools itself.
public enum HubToolEffect: String, Sendable {
    case read, change, irreversible

    /// Any of these words in a tool's name makes it irreversible, whatever the server claims. The hub's own list
    /// (`IRREVERSIBLE_WORDS` in crates/theo-connectors/src/safety.rs), so both sides decide the same way.
    static let irreversibleWords: Set<String> = [
        "send", "reply", "forward", "trash", "delete", "remove", "destroy", "purge", "spam", "share", "unshare", "cancel", "clear",
        "publish", "post", "invite", "pay", "charge", "refund", "transfer", "merge", "revoke", "archive", "wipe", "drop", "kill",
        "terminate", "execute", "run", "deploy", "submit", "approve", "reject", "close",
    ]

    /// `notion-calendar-list-events`, `search_threads` or `getFileMetadata` as lowercase words, the way the hub splits them.
    static func words(inToolName toolName: String) -> [String] {
        var words: [String] = []
        var currentWord = ""
        var previousCharacterWasLowercase = false
        for character in toolName {
            guard character.isASCII, character.isLetter || character.isNumber else {
                if !currentWord.isEmpty { words.append(currentWord) }
                currentWord = ""
                previousCharacterWasLowercase = false
                continue
            }
            if character.isUppercase && previousCharacterWasLowercase && !currentWord.isEmpty {
                words.append(currentWord)
                currentWord = ""
            }
            previousCharacterWasLowercase = character.isLowercase || character.isNumber
            currentWord.append(Character(character.lowercased()))
        }
        if !currentWord.isEmpty { words.append(currentWord) }
        return words
    }

    /// `listedAsWriting`: the app lists it among its writing tools (a claude-account app's `writeTools`).
    public static func of(toolName: String, listedAsWriting: Bool) -> HubToolEffect {
        if words(inToolName: toolName).contains(where: irreversibleWords.contains) { return .irreversible }
        return listedAsWriting ? .change : .read
    }

    public func allowed(at level: HubAccessLevel) -> Bool {
        switch (self, level) {
        case (.read, _): return true
        case (.change, .readAndDraft), (.change, .full): return true
        case (.irreversible, .full): return true
        default: return false
        }
    }
}

// MARK: - One bot turn

/// Which of a bot's apps it reaches through the hub (in the ticket) and which a Claude bot reaches directly (Claude Code's own
/// claude.ai connectors, faster and exactly as before the hub).
public struct ConnectorHubTurnPlan: Equatable, Sendable {
    /// App id → level, for the ticket. Empty: the hub isn't started for this turn.
    public var ticketApps: [String: HubAccessLevel]
    /// claude-account apps a Claude bot uses directly, with the level this turn has for each.
    public var directClaudeApps: [DirectClaudeApp]
    /// A Composio app in `ticketApps` that the bot has only for some apps: its id → the toolkits it may use there (the ticket's
    /// `composioToolkits`). Missing: the bot was given Composio itself and may use every app connected on it.
    public var composioToolkits: [String: [String]] = [:]
    /// claude-account apps this turn reaches through Composio instead of a Claude account: app id → Composio's toolkit.
    public var throughComposio: [String: String] = [:]

    public struct DirectClaudeApp: Equatable, Sendable {
        public var app: HubAppRecord
        public var level: HubAccessLevel
    }

    public init(ticketApps: [String: HubAccessLevel], directClaudeApps: [DirectClaudeApp], composioToolkits: [String: [String]] = [:],
                throughComposio: [String: String] = [:]) {
        self.ticketApps = ticketApps
        self.directClaudeApps = directClaudeApps
        self.composioToolkits = composioToolkits
        self.throughComposio = throughComposio
    }

    /// No apps this turn (no helper, or a bot without apps).
    public static let nothing = ConnectorHubTurnPlan(ticketApps: [:], directClaudeApps: [])

    public var usesHub: Bool { !ticketApps.isEmpty }

    /// `botApps`: the bot's app ids. `savedLevels`: its per-app levels. `engine`: the bot's provider ("claude", "codex", …).
    /// Apps the hub doesn't have (Theo's own screen tools, Chrome, skills) and apps that are switched off are left out.
    public static func make(botApps: [String], savedLevels: [String: String], hubApps: [HubAppRecord], engine: String,
                            ownerAsked: Bool) -> ConnectorHubTurnPlan {
        var ticketApps: [String: HubAccessLevel] = [:]
        var direct: [DirectClaudeApp] = []
        var throughComposio: [String: String] = [:]
        // Composio for apps that would otherwise need a Claude plan: its id → the level and the toolkits.
        var composioForApps: [String: (level: HubAccessLevel, toolkits: [String])] = [:]
        for appID in botApps {
            guard let app = hubApps.first(where: { $0.id == appID }), app.enabled else { continue }
            let level = HubAccessLevel(saved: savedLevels[appID]).effective(ownerAsked: ownerAsked)
            if engine == "claude", app.isClaudeAccount, app.server != nil {
                direct.append(DirectClaudeApp(app: app, level: level))
            } else if engine != "claude", let route = ComposioRoute.route(for: app, hubApps: hubApps) {
                throughComposio[appID] = route.toolkit
                let earlier = composioForApps[route.composio.id]
                composioForApps[route.composio.id] = (earlier.map { HubAccessLevel.higher($0.level, level) } ?? level,
                                                      ((earlier?.toolkits ?? []) + [route.toolkit]))
            } else {
                ticketApps[appID] = level
            }
        }
        var composioToolkits: [String: [String]] = [:]
        for (composioID, routed) in composioForApps {
            if let givenItself = ticketApps[composioID] {
                // The bot was given Composio itself: every app on it, at the higher of the two levels.
                ticketApps[composioID] = HubAccessLevel.higher(givenItself, routed.level)
            } else {
                ticketApps[composioID] = routed.level
                composioToolkits[composioID] = Array(Set(routed.toolkits)).sorted()
            }
        }
        return ConnectorHubTurnPlan(ticketApps: ticketApps, directClaudeApps: direct, composioToolkits: composioToolkits,
                                    throughComposio: throughComposio)
    }
}

/// Claude Code's own route to a claude.ai app, for Claude bots.
public enum ClaudeDirectRoute {
    /// Claude Code names a server's tools `mcp__<server>__<tool>`, with every character but letters, digits, `_` and `-` as `_`:
    /// "claude.ai Gmail" → mcp__claude_ai_Gmail, "content-studio" → mcp__content-studio.
    public static func toolPrefix(forServer server: String) -> String {
        let cleaned = String(server.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-") ? character : "_"
        })
        return "mcp__" + cleaned
    }

    /// The app's tools this turn may not run, as Claude Code tool names: at `read` every writing tool, at `readAndDraft` the ones
    /// that send, delete or share, at `full` none.
    public static func deniedTools(for app: HubAppRecord, level: HubAccessLevel) -> [String] {
        guard let server = app.server else { return [] }
        let prefix = toolPrefix(forServer: server)
        return app.writeTools
            .filter { !HubToolEffect.of(toolName: $0, listedAsWriting: true).allowed(at: level) }
            .map { "\(prefix)__\($0)" }
    }
}

// MARK: - Tickets

public enum ConnectorHubTicket {
    /// The ticket file's contents, in the shape the hub reads (crossplatform/docs/CONNECTORS.md, "Bot turns: tickets").
    /// `composioToolkits`: a Composio app the bot has only for some apps → those apps' toolkits (left out when empty, so the
    /// ticket reads exactly as before).
    public static func json(botID: String, apps: [String: HubAccessLevel], ownerAsked: Bool, expiresAt: Date,
                            composioToolkits: [String: [String]] = [:]) -> Data {
        var object: [String: Any] = [
            "botId": botID,
            "apps": apps.mapValues(\.rawValue),
            "ownerAsked": ownerAsked,
            "expiresAt": HubDates.format(expiresAt),
        ]
        let limited = composioToolkits.filter { apps[$0.key] != nil && !$0.value.isEmpty }
        if !limited.isEmpty { object["composioToolkits"] = limited }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// A ticket's file name: the bot's id made safe, then something unique, so two turns never share one.
    public static func fileName(botID: String, unique: String) -> String {
        let safe = String(botID.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "_" }.prefix(40))
        return "\(safe)-\(unique).json"
    }
}

// MARK: - Handing the hub to a brain for one turn

/// How a brain starts the hub: the helper, its arguments (`--data <folder> serve --ticket <file>`) and the settings it needs.
public struct HubServerLaunch: Equatable, Sendable {
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(command: String, arguments: [String], environment: [String: String] = [:]) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }
}

public enum ConnectorHubWiring {
    /// The MCP server's name in every brain. Not "theo": that is already Theo's own screen-and-voice server (`Clicky --mcp`) in the
    /// owner's Codex, Grok and OpenCode configs, and one turn's override must never replace it.
    public static let serverName = "theo_apps"

    /// Claude Code's allow rule for every tool of the hub's server (the hub itself refuses what the ticket doesn't allow).
    public static var claudeAllowRule: String { "mcp__\(serverName)" }

    /// `--mcp-config` for one Claude Code turn. Added to the owner's own servers, never instead of them.
    public static func claudeMCPConfig(_ launch: HubServerLaunch) -> String {
        jsonText(["mcpServers": [serverName: stdioServer(launch)]])
    }

    /// Codex takes config overrides per run (`-c key=value`, the value parsed as TOML). Tool calls are approved up front: nobody is
    /// there to approve them, and the hub decides what the bot may run.
    public static func codexArguments(_ launch: HubServerLaunch) -> [String] {
        var overrides = [
            "mcp_servers.\(serverName).command=\(tomlString(launch.command))",
            "mcp_servers.\(serverName).args=[\(launch.arguments.map(tomlString).joined(separator: ","))]",
            "mcp_servers.\(serverName).default_tools_approval_mode=\"approve\"",
        ]
        if !launch.environment.isEmpty {
            let pairs = launch.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(tomlString($0.value))" }
            overrides.append("mcp_servers.\(serverName).env={\(pairs.joined(separator: ","))}")
        }
        return overrides.flatMap { ["-c", $0] }
    }

    /// OpenCode merges `OPENCODE_CONFIG_CONTENT` into its config for that run only.
    public static func openCodeConfigContent(_ launch: HubServerLaunch) -> String {
        var server: [String: Any] = ["type": "local", "command": [launch.command] + launch.arguments, "enabled": true]
        if !launch.environment.isEmpty { server["environment"] = launch.environment }
        return jsonText(["mcp": [serverName: server]])
    }

    /// Gemini CLI's `.gemini/settings.json` in the folder it works in (Theo's own bots folder), read with that folder trusted for the
    /// run (`GEMINI_CLI_TRUST_WORKSPACE=true`; an untrusted folder gets no MCP servers at all). Its MCP servers are merged with the
    /// owner's by name. A settings file named by `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` doesn't work: Gemini only reads one owned by root.
    /// `trust` lets the hub's tools run in a headless turn (the hub decides what may run).
    public static func geminiSettings(_ launch: HubServerLaunch) -> String {
        var server = stdioServer(launch)
        server["trust"] = true
        return jsonText(["mcpServers": [serverName: server]])
    }

    /// Cursor Agent reads `.cursor/mcp.json` in the folder it works in (Theo's own bots folder, never the owner's projects).
    public static func cursorMCPFile(_ launch: HubServerLaunch) -> String {
        jsonText(["mcpServers": [serverName: stdioServer(launch)]])
    }

    /// Grok only takes MCP servers from its own config file, so the hub is added there once, with a ticket file of fixed name that
    /// only exists while a Grok bot's turn runs.
    public static func grokConfigBlock(_ launch: HubServerLaunch) -> String {
        var block = "\n[mcp_servers.\(serverName)]\ncommand = \(tomlString(launch.command))\n" +
            "args = [\(launch.arguments.map(tomlString).joined(separator: ", "))]\nenabled = true\n"
        if !launch.environment.isEmpty {
            block += "[mcp_servers.\(serverName).env]\n"
            for (key, value) in launch.environment.sorted(by: { $0.key < $1.key }) { block += "\(key) = \(tomlString(value))\n" }
        }
        return block
    }

    /// A TOML basic string: quotes and backslashes escaped, control characters as escapes.
    public static func tomlString(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    private static func stdioServer(_ launch: HubServerLaunch) -> [String: Any] {
        var server: [String: Any] = ["command": launch.command, "args": launch.arguments]
        if !launch.environment.isEmpty { server["env"] = launch.environment }
        return server
    }

    private static func jsonText(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Moving what bots had before the hub

/// Before the hub, the Mac app had a fixed list of eleven apps, all reached through Claude Code. On the first launch with the
/// helper, the ones the owner used become hub apps, under the same ids, so every bot keeps what it was given.
public enum ConnectorHubMigration {
    /// Mac app ids that are starter-catalog entries with the same id (all claude-account apps).
    public static let catalogIDs = ["gmail", "notion", "calendar", "drive", "docs", "sheets"]

    /// Claude Code's server name for each catalog id.
    public static let catalogServers: [String: String] = [
        "gmail": "claude.ai Gmail", "notion": "claude.ai Notion", "calendar": "claude.ai Notion",
        "drive": "claude.ai Google Drive", "docs": "claude.ai Google Docs", "sheets": "claude.ai Google Sheets",
    ]

    /// Apps that used to be built in for the owner and are now entries the owner added (crossplatform/docs/CONNECTORS.md,
    /// "Migrating what bots have today"). HyperFrames is a skill set, not a connector, and isn't moved.
    public static let formerlyBuiltIn: [(id: String, name: String, server: String)] = [
        ("hostinger", "Hostinger", "claude.ai Hostinger Connector"),
        ("studio", "Content Studio", "content-studio"),
    ]

    public struct Plan: Equatable, Sendable {
        /// `add --catalog <id>` for each.
        public var catalogIDs: [String]
        /// `add --json` for each (claude-account entries).
        public var ownApps: [[String: String]]

        public var isEmpty: Bool { catalogIDs.isEmpty && ownApps.isEmpty }
    }

    /// `botApps`: every app id any bot has. `claudeServers`: the servers Claude Code lists on this Mac (empty without Claude Code).
    /// `hubIDs`: the apps the hub has already. An app moves when a bot uses it or Claude Code has it, and the hub doesn't yet.
    /// Notion Calendar shares Notion's server, so it only moves when a bot uses it.
    public static func plan(botApps: Set<String>, claudeServers: Set<String>, hubIDs: Set<String>) -> Plan {
        var catalog: [String] = []
        for id in catalogIDs where !hubIDs.contains(id) {
            let fromClaude = id != "calendar" && catalogServers[id].map(claudeServers.contains) == true
            if botApps.contains(id) || fromClaude { catalog.append(id) }
        }
        var own: [[String: String]] = []
        for app in formerlyBuiltIn where !hubIDs.contains(app.id) {
            if botApps.contains(app.id) || claudeServers.contains(app.server) {
                own.append(["id": app.id, "name": app.name, "kind": "claude-account", "server": app.server])
            }
        }
        return Plan(catalogIDs: catalog, ownApps: own)
    }
}

// MARK: - Adding an app by hand

/// "Add your own": what the owner typed, as the app entry the hub's `add --json` takes. The secret part (a token, a key in a
/// command's settings) never goes in the entry; it goes in afterwards with `set-secret`.
public enum ConnectorHubNewApp {
    /// An id from a name: lowercase letters, digits and dashes, at most 40, never empty.
    public static func id(fromName name: String, taken: Set<String>) -> String {
        var base = ""
        for character in name.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                base.append(character)
            } else if !base.isEmpty && base.last != "-" {
                base.append("-")
            }
        }
        while base.hasSuffix("-") { base.removeLast() }
        base = String(base.prefix(32))
        if base.isEmpty { base = "app" }
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    /// A server Claude Code already has ("claude.ai Runway"), kept as an app Theo reaches through the owner's Claude account.
    /// Its name drops the "claude.ai " Claude Code puts in front.
    public static func claudeAccount(id: String, server: String) -> [String: Any] {
        let name = server.hasPrefix("claude.ai ") ? String(server.dropFirst("claude.ai ".count)) : server
        return ["id": id, "name": name, "kind": "claude-account", "server": server]
    }

    /// A remote app at `address`, signed in with `signIn` ("oauth", "token" or "none"). Nil when the address isn't one the hub
    /// takes: https, or plain http only on this Mac.
    public static func remote(id: String, name: String, address: String, signIn: String) -> [String: Any]? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return nil }
        let local = host == "127.0.0.1" || host == "localhost"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        let auth = ["oauth", "token", "none"].contains(signIn) ? signIn : "none"
        return ["id": id, "name": name, "kind": "remote", "url": trimmed, "auth": auth]
    }

    /// A local app from a command line ("npx -y @modelcontextprotocol/server-filesystem ~/Notes"). Words in quotes stay together;
    /// a leading ~/ in a word is the owner's home. Nil for an empty command.
    public static func local(id: String, name: String, commandLine: String, home: String) -> [String: Any]? {
        let words = splitCommandLine(commandLine).map { word in word.hasPrefix("~/") ? home + word.dropFirst(1) : word }
        guard let command = words.first, !command.isEmpty else { return nil }
        var entry: [String: Any] = ["id": id, "name": name, "kind": "local", "command": command]
        if words.count > 1 { entry["args"] = Array(words.dropFirst()) }
        return entry
    }

    /// Splits a command line into words the way a shell would for plain cases: spaces separate, and "…" or '…' keep spaces in.
    public static func splitCommandLine(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" || character == "\n" {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(character)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
