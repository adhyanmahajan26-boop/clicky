//
//  BotStatusSources.swift
//  leanring-buddy
//
//  Where the Pixel states come from beyond a bot's own chat: failures in plain words, the health of each connector (with
//  when it last worked), which bot is stuck on which connector, and the alerts raised for an ask or a failure.
//

import AppKit
import ClickyCore
import Combine
import Foundation

// MARK: - Failures in plain words

enum BotFailureWords {
    /// An engine error as one plain sentence. The raw text stays in the chat's "Couldn't reply" line.
    static func plain(_ error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("isn't signed in") || lower.contains("not signed in") || lower.contains("signed out") || lower.contains("log in") || lower.contains("login") {
            return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        }
        if lower.contains("usage limit") || lower.contains("rate limit") { return "It hit its usage limit. " + text }
        if text.isEmpty { return "It stopped before it could answer." }
        return text
    }

    /// Why a coding run failed, from where it got to.
    static func run(_ run: T3Run) -> String {
        let engine = run.harness.map(HarnessCatalog.label) ?? "T3 Code"
        switch step(of: run) {
        case "Push": return "Couldn't push \(run.title) to GitHub. The changes are saved on this Mac and nothing was lost."
        case "PR": return "Couldn't open the pull request for \(run.title). The branch is pushed and nothing was lost."
        case "Tests": return "The tests didn't pass on \(run.title). The changes are saved on this Mac."
        default: return "\(engine) stopped before \(run.title) was finished. What it did so far is saved."
        }
    }

    /// The run step that failed, by the run card's step names.
    static func step(of run: T3Run) -> String? {
        switch run.stage {
        case "push": return "Push"
        case "pr": return "PR"
        case "tests": return "Tests"
        default: return run.harness == nil && run.stage == nil ? nil : "Code"
        }
    }

    /// The sign-in message a coding agent's failure carries, if that's what it was ("Grok isn't signed in").
    static func signedOutHarness(in reason: String) -> HarnessInfo? {
        let lower = reason.lowercased()
        guard lower.contains("signed in") || lower.contains("signed out") || lower.contains("log in") || lower.contains("login") || lower.contains("authenticat") else { return nil }
        return HarnessCatalog.all.first { lower.contains($0.label.lowercased()) || lower.contains($0.id) }
    }
}

// MARK: - Opening things outside Theo

/// Every link and outside sign-in Theo opens goes through here. The test profile records them instead, so a test can press
/// a card's button and check what it would have opened, without a browser tab ever appearing on the owner's screen.
@MainActor
enum TheoOpen {
    private(set) static var recorded: [String] = []

    static func url(_ url: URL) {
        if TheoProfile.isTest {
            recorded.append(url.absoluteString)
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func record(_ action: String) { recorded.append(action) }
}

// MARK: - Connector health

/// The status of every connector, one shared copy for the Connectors screen, the bot pages and the cards, plus when each
/// last worked and which bot is waiting on which app.
@MainActor
final class ConnectorHealth: ObservableObject {
    static let shared = ConnectorHealth()

    @Published private(set) var claude: [String: ConnectorState] = [:]
    @Published private(set) var openCode: [String: ConnectorState] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    /// When each connector was last seen connected, by connector id.
    @Published private(set) var lastConnected: [String: Date] = [:]
    /// Bots stuck on an app, by bot id.
    @Published private(set) var blocks: [String: Block] = [:]

    struct Block: Codable, Equatable {
        var connectorID: String
        var at: Date
        /// The chat it happened in.
        var room: String?
    }

    /// What a connector's row says, from both engines' listings.
    enum RowState: Equatable {
        case connected, claudeOnly, othersOnly, needsSignIn, failed(String), missing, checking, skills

        var pill: (tone: PixelTone, text: String) {
            switch self {
            case .connected: return (.ok, "Connected")
            case .claudeOnly: return (.ok, "Claude bots only")
            case .othersOnly: return (.ok, "OpenCode and Grok only")
            case .needsSignIn: return (.needs, "Needs sign-in")
            case .failed: return (.failed, "Can't connect")
            case .missing: return (.quiet, "Not connected")
            case .checking: return (.checking, "Checking")
            case .skills: return (.quiet, "Skills")
            }
        }

        /// Needs sign-in first, then failed, then connected, then the rest.
        var sortOrder: Int {
            switch self {
            case .needsSignIn: return 0
            case .failed: return 1
            case .connected, .claudeOnly, .othersOnly: return 2
            case .checking: return 3
            case .missing: return 4
            case .skills: return 5
            }
        }
    }

    private static let lastConnectedKey = "theo.connectors.lastConnected"
    private static let blocksKey = "theo.connectors.blocks"
    /// Test profile only: `{connectorID: "connected" | "needsSignIn" | "failed:<reason>" | "missing"}`, standing in for
    /// what `claude mcp list` says, so a test can put an app in any state without touching a real account.
    static let testStatusKey = "test.connectors.status"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.lastConnectedKey), let saved = try? JSONDecoder().decode([String: Date].self, from: data) { lastConnected = saved }
        if let data = defaults.data(forKey: Self.blocksKey), let saved = try? JSONDecoder().decode([String: Block].self, from: data) { blocks = saved }
    }

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        async let claudeListing = BotConnectors.listing(.claude)
        async let openCodeListing = BotConnectors.listing(.opencode)
        let (claudeText, openCodeText) = await (claudeListing, openCodeListing)
        claude = ConnectorListing.parseClaude(claudeText)
        openCode = ConnectorListing.parseOpenCode(openCodeText)
        isChecking = false
        lastChecked = Date()
        for connector in BotConnectors.known where state(of: connector) == .connected || state(of: connector) == .claudeOnly || state(of: connector) == .othersOnly {
            lastConnected[connector.id] = Date()
        }
        save()
        // An app that works again lets go of the bots that were waiting on it.
        for (botID, block) in blocks {
            guard let connector = BotConnectors.known.first(where: { $0.id == block.connectorID }) else { continue }
            if [.connected, .claudeOnly, .othersOnly].contains(state(of: connector)) { clearBlock(of: botID) }
        }
    }

    func refreshIfStale() {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 120 { return }
        Task { await refresh() }
    }

    /// A test override for this connector, in the test profile only.
    private func testStatus(_ connector: BotConnector) -> ConnectorState? {
        guard TheoProfile.isTest, let map = UserDefaults.standard.dictionary(forKey: Self.testStatusKey) as? [String: String], let value = map[connector.id] else { return nil }
        if value.hasPrefix("failed") { return .failed(String(value.dropFirst("failed:".count))) }
        return ["connected": .connected, "needsSignIn": .needsSignIn, "missing": .missing][value] ?? .unknown
    }

    func onClaude(_ connector: BotConnector) -> ConnectorState {
        if let test = testStatus(connector) { return test }
        guard let name = connector.claudeServer else { return .missing }
        if claude.isEmpty, isChecking || lastChecked == nil { return .unknown }
        return claude[name] ?? .missing
    }

    func onOpenCode(_ connector: BotConnector) -> ConnectorState {
        if testStatus(connector) != nil { return .missing }
        guard let name = connector.openCodeServer else { return .missing }
        if openCode.isEmpty, isChecking || lastChecked == nil { return .unknown }
        return openCode[name] ?? .missing
    }

    func state(of connector: BotConnector) -> RowState {
        if connector.isSkill { return .skills }
        let claudeSide = onClaude(connector)
        let openCodeSide = onOpenCode(connector)
        if claudeSide == .unknown { return .checking }
        let othersReach = openCodeSide == .connected || (BotConnectors.bridged(connector) && claudeSide == .connected)
        if claudeSide == .connected { return othersReach ? .connected : .claudeOnly }
        if othersReach { return .othersOnly }
        if claudeSide == .needsSignIn || openCodeSide == .needsSignIn { return .needsSignIn }
        if let reason = claudeSide.failureReason ?? openCodeSide.failureReason { return .failed(reason) }
        return .missing
    }

    /// Whether the app works for a bot on this engine: Claude bots use claude.ai; OpenCode and Grok bots reach the bridged
    /// apps through Claude, and the rest through OpenCode's own servers.
    func state(for connector: BotConnector, provider: String) -> ConnectorState {
        if connector.isSkill { return .connected }
        let claudeSide = onClaude(connector)
        if provider == "claude" || BotConnectors.bridged(connector) { return claudeSide }
        return onOpenCode(connector)
    }

    func label(for connector: BotConnector, provider: String) -> String {
        let state = state(for: connector, provider: provider)
        if state == .connected, provider != "claude", BotConnectors.bridged(connector) { return "Via Claude" }
        return state.label
    }

    // MARK: Bots stuck on an app

    func block(of botID: String) -> Block? { blocks[botID] }

    /// The app this bot is waiting on, while that app still needs a sign-in.
    func blockingConnector(of botID: String) -> BotConnector? {
        guard let block = blocks[botID], let connector = BotConnectors.known.first(where: { $0.id == block.connectorID }) else { return nil }
        switch state(of: connector) {
        case .connected, .claudeOnly, .othersOnly: return nil
        default: return connector
        }
    }

    /// Bots waiting on this connector, for its row ("Researcher is waiting on this").
    func botsWaiting(on connectorID: String) -> [String] {
        blocks.filter { $0.value.connectorID == connectorID }.map(\.key).sorted()
    }

    func setBlock(_ botID: String, connectorID: String, room: String?) {
        blocks[botID] = Block(connectorID: connectorID, at: Date(), room: room)
        save()
        BotsStore.shared.objectWillChange.send()
        if let bot = BotsStore.shared.bot(botID), let connector = BotConnectors.known.first(where: { $0.id == connectorID }) {
            BotAlerts.shared.needs(bot: bot, line: "Sign in to \(connector.name)")
        }
    }

    func clearBlock(of botID: String) {
        guard blocks[botID] != nil else { return }
        blocks[botID] = nil
        save()
        BotsStore.shared.objectWillChange.send()
    }

    /// Words a reply uses when an app it reached for wasn't there for it.
    private static let stuckWords = ["sign in", "sign-in", "signed in", "log in", "logged in", "authenticat", "authoriz", "not connected", "isn't connected",
                                     "reconnect", "can't access", "cannot access", "couldn't access", "unable to access", "don't have access", "no access",
                                     "couldn't reach", "can't reach", "isn't answering", "not responding"]

    /// After a bot's turn: if it reached for one of its apps and that app needs a sign-in, the bot waits on it (yellow);
    /// if the app isn't answering, the run failed because of it (red). A bot that merely has the app stays as it was.
    func noteTurn(bot: NativeBot, answer: String, room: String) {
        let lower = answer.lowercased()
        guard Self.stuckWords.contains(where: lower.contains) else { return }
        let apps = Set(bot.apps + (bot.apps.contains("calendar") ? ["notion"] : []))
        for connector in BotConnectors.known where apps.contains(connector.id) && !connector.isSkill {
            let names = [connector.name.lowercased(), connector.id] + (connector.id == "drive" ? ["drive"] : [])
            guard names.contains(where: lower.contains) else { continue }
            switch state(of: connector) {
            case .needsSignIn, .missing, .checking:
                setBlock(bot.id, connectorID: connector.id, room: room)
            case .failed(let reason):
                BotsStore.shared.recordFailure(of: bot.id, reason: "Can't reach \(connector.name). " + ConnectorListing.plainReason(reason, app: connector.name))
            default:
                continue
            }
            return
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(lastConnected), forKey: Self.lastConnectedKey)
        defaults.set(try? JSONEncoder().encode(blocks), forKey: Self.blocksKey)
    }

    /// Sign in to an app for the bots that use it: claude.ai connectors are signed in on the web; an OpenCode server signs
    /// in through OpenCode itself. In the test profile the action is recorded instead (no browser tab on the owner's screen).
    func signIn(_ connector: BotConnector, forBot bot: NativeBot?) async -> String {
        let onOpenCode = bot.map { $0.provider == "opencode" } ?? false
        if onOpenCode, connector.openCodeURL != nil {
            if TheoProfile.isTest {
                TheoOpen.record("opencode mcp auth \(connector.openCodeServer ?? connector.id)")
                return "Signing in to \(connector.name) in OpenCode. Finish in your browser."
            }
            return await BotConnectors.addToOpenCode(connector)
        }
        BotConnectors.openClaudeConnectors()
        return "claude.ai's connector page is open. Sign in to \(connector.name) there; Theo checks again when you come back."
    }
}

// MARK: - Alerts

/// One alert per ask or failure: the face, "<Bot> needs you" or "<Bot> failed", one sentence and the card's buttons. They
/// collect here for the menu bar panel and Home; outside the test profile a small panel also shows at the top right.
@MainActor
final class BotAlerts: ObservableObject {
    static let shared = BotAlerts()

    struct Alert: Identifiable, Equatable {
        let id = UUID()
        let botID: String
        let state: PixelState
        let title: String
        let line: String
        let at = Date()
    }

    @Published private(set) var recent: [Alert] = []
    /// Settings: alerts on or off (on by default).
    static let enabledKey = "theo.alerts.enabled"

    func failed(bot: NativeBot, reason: String) {
        raise(Alert(botID: bot.id, state: .failed, title: "\(bot.name) failed", line: BotFailureRecord(reason: reason).firstSentence + "."))
    }

    func needs(bot: NativeBot, line: String) {
        raise(Alert(botID: bot.id, state: .needs, title: "\(bot.name) needs you", line: line))
    }

    func dismiss(_ alert: Alert) {
        recent.removeAll { $0.id == alert.id }
        BotAlertPanel.shared.update()
    }

    private func raise(_ alert: Alert) {
        // One per bot and kind: a newer one replaces the older.
        recent.removeAll { $0.botID == alert.botID && $0.state == alert.state }
        recent.insert(alert, at: 0)
        recent = Array(recent.prefix(6))
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else { return }
        BotAlertPanel.shared.update()
    }
}
