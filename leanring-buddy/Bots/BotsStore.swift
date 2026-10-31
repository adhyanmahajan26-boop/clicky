//
//  BotsStore.swift
//  leanring-buddy
//
//  Theo's bots, natively: each bot's role, model and apps, one ongoing chat
//  per bot, and the team chat, saved under Application Support/Theo/Bots.
//  The first run imports the bots already set up in T3 Code (their roles,
//  models and memory files stay the same); with none there it starts with
//  Theo and the three helpers.
//

import Combine
import Foundation

struct NativeBot: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var description: String
    var instructions: String
    var hue: Double
    var accentHue: Double
    var primary: Bool
    /// "claude" or "opencode".
    var provider: String
    /// The engine's model id: "claude-sonnet-5-5", "opencode/beam-free", …
    var model: String
    /// Reasoning effort ("low", "medium", "high", …), when the model has one.
    var effort: String?
    /// App integrations the bot may use; see BotConnectors.known.
    var apps: [String]
    /// "personal" (your own helpers) or "project" (Theo's project team). Older saves have none.
    var category: String?

    var isProjectHandler: Bool { (category ?? BotImport.defaultCategory(id)) == "project" }

    var memoryPath: String { "~/.t3/bots/\(id)/memory.md" }

    var modelLabel: String {
        let name = model.split(separator: "/").last.map(String.init) ?? model
        return name.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

struct BotChatMessage: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    /// "user" or a bot id.
    var author: String
    var text: String
    var at: Date = Date()
}

/// One saved conversation and the engine sessions that hold its context.
struct BotConversationRecord: Codable {
    var messages: [BotChatMessage] = []
    /// Engine session per bot (a bot's own chat has one; the team chat one per bot).
    var sessions: [String: String] = [:]
    /// Team chat: how many messages each bot has already been shown.
    var seen: [String: Int] = [:]
}

@MainActor
final class BotsStore: ObservableObject {
    static let shared = BotsStore()

    @Published private(set) var bots: [NativeBot] = []
    @Published private(set) var conversations: [String: BotConversationRecord] = [:]
    /// Bots with a reply in progress, and the reply text so far ("" while thinking).
    @Published private(set) var replying: [String: String] = [:]

    static let teamID = "team"

    private let folder: URL

    private init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Theo/Bots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("chats"), withIntermediateDirectories: true)
        bots = loadBots()
        for id in [Self.teamID] + bots.map(\.id) {
            conversations[id] = loadConversation(id)
        }
    }

    var primary: NativeBot? { bots.first(where: \.primary) ?? bots.first }

    func bot(_ id: String) -> NativeBot? { bots.first { $0.id == id } }

    func conversation(_ id: String) -> BotConversationRecord { conversations[id] ?? BotConversationRecord() }

    func save(_ bot: NativeBot) {
        if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot } else { bots.append(bot) }
        writeBots()
    }

    /// Starts a fresh chat with a bot (its engine session starts over too).
    func clearConversation(_ id: String) {
        conversations[id] = BotConversationRecord()
        writeConversation(id)
    }

    // MARK: Talking

    /// Sends your message to a bot's own chat and streams its reply in.
    func send(_ text: String, to botID: String) {
        guard let bot = bot(botID), replying[botID] == nil else { return }
        var record = conversation(botID)
        record.messages.append(BotChatMessage(author: "user", text: text))
        conversations[botID] = record
        writeConversation(botID)
        let firstTurn = record.sessions[botID] == nil
        let prompt = firstTurn ? BotPrompts.firstMessage(bot: bot, team: bots, text: text) : text
        reply(bot: bot, in: botID, prompt: prompt, session: record.sessions[botID]) { _ in }
    }

    /// Posts to the team chat; tagged bots answer, or Theo when nobody is tagged.
    func sendToTeam(_ text: String) {
        var record = conversation(Self.teamID)
        record.messages.append(BotChatMessage(author: "user", text: text))
        conversations[Self.teamID] = record
        writeConversation(Self.teamID)
        let tagged = BotPrompts.mentioned(in: text, bots: projectBots)
        askTeam(tagged.isEmpty ? [primary].compactMap { $0 } : tagged, chain: 0)
    }

    /// How many bot-to-bot hand-offs one message of yours can set off.
    private static let maxChain = 8

    private func askTeam(_ targets: [NativeBot], chain: Int) {
        for bot in targets where replying[bot.id] == nil {
            let record = conversation(Self.teamID)
            let seen = record.seen[bot.id] ?? 0
            let newMessages = Array(record.messages.dropFirst(seen))
            let prompt = BotPrompts.teamMessage(bot: bot, team: projectBots, firstTime: record.sessions[bot.id] == nil,
                                                newMessages: newMessages)
            var updated = record
            updated.seen[bot.id] = record.messages.count
            conversations[Self.teamID] = updated
            reply(bot: bot, in: Self.teamID, prompt: prompt, session: record.sessions[bot.id]) { [weak self] answer in
                guard let self, chain < Self.maxChain, let answer else { return }
                let next = BotPrompts.mentioned(in: answer, bots: self.projectBots).filter { $0.id != bot.id }
                if !next.isEmpty { self.askTeam(next, chain: chain + 1) }
            }
        }
    }

    private func reply(bot: NativeBot, in conversationID: String, prompt: String, session: String?,
                       then: @escaping (String?) -> Void) {
        replying[bot.id] = ""
        Task { [weak self] in
            var answer: String?
            var newSession = session
            do {
                let team = self?.bots ?? []
                let result = try await BotRunner.run(bot: bot, prompt: prompt, session: session, team: team) { text in
                    self?.replying[bot.id] = text
                }
                answer = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                newSession = result.session ?? session
            } catch {
                answer = nil
                self?.post(BotChatMessage(author: bot.id, text: "Couldn't reply: \(error.localizedDescription)"), to: conversationID)
            }
            guard let self else { return }
            self.replying[bot.id] = nil
            var record = self.conversation(conversationID)
            if let newSession { record.sessions[bot.id] = newSession }
            if let answer, !answer.isEmpty {
                record.messages.append(BotChatMessage(author: bot.id, text: BotPrompts.withoutNameHeading(answer, bot: bot)))
                if conversationID == Self.teamID { record.seen[bot.id] = record.messages.count }
            } else if answer != nil {
                record.messages.append(BotChatMessage(author: bot.id, text: "(No answer this time. Send it again, or try another model.)"))
            }
            self.conversations[conversationID] = record
            self.writeConversation(conversationID)
            then(answer)
        }
    }

    private func post(_ message: BotChatMessage, to conversationID: String) {
        var record = conversation(conversationID)
        record.messages.append(message)
        conversations[conversationID] = record
        writeConversation(conversationID)
    }

    // MARK: Files

    private var botsFile: URL { folder.appendingPathComponent("bots.json") }
    private func chatFile(_ id: String) -> URL { folder.appendingPathComponent("chats/\(id).json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func loadBots() -> [NativeBot] {
        let saved = (try? Data(contentsOf: botsFile)).flatMap { try? Self.decoder.decode([NativeBot].self, from: $0) }
        let base = (saved?.isEmpty == false ? saved : nil) ?? BotImport.fromT3() ?? []
        let offeredFile = folder.appendingPathComponent("offered.json")
        var offered = Set((try? Data(contentsOf: offeredFile)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        let upgraded = BotImport.upgrade(base, offered: &offered)
        try? JSONEncoder().encode(Array(offered).sorted()).write(to: offeredFile, options: .atomic)
        bots = upgraded
        writeBots()
        return upgraded
    }

    var personalBots: [NativeBot] { bots.filter { !$0.isProjectHandler } }
    var projectBots: [NativeBot] { bots.filter(\.isProjectHandler) }

    private func writeBots() {
        guard let data = try? Self.encoder.encode(bots) else { return }
        try? data.write(to: botsFile, options: .atomic)
    }

    private func loadConversation(_ id: String) -> BotConversationRecord {
        guard let data = try? Data(contentsOf: chatFile(id)) else { return BotConversationRecord() }
        return (try? Self.decoder.decode(BotConversationRecord.self, from: data)) ?? BotConversationRecord()
    }

    private func writeConversation(_ id: String) {
        guard let data = try? Self.encoder.encode(conversation(id)) else { return }
        try? data.write(to: chatFile(id), options: .atomic)
    }
}

/// Bringing over the bots set up in T3 Code (the Cursor Assistant build keeps them in its state folder).
enum BotImport {
    static func fromT3() -> [NativeBot]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [".t3-claudia/userdata/bots-state.json", ".t3/userdata/bots-state.json"].map { home.appendingPathComponent($0) }
        for file in candidates {
            guard let data = try? Data(contentsOf: file),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = state["t3code:bots:v1"] as? String,
                  let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { continue }
            let bots = list.compactMap(bot(from:))
            if !bots.isEmpty { return bots }
        }
        return nil
    }

    static func bot(from raw: [String: Any]) -> NativeBot? {
        // Clicky's chat is Theo itself here, not a bot.
        if raw["companion"] as? Bool == true || raw["tracksAssistant"] as? Bool == true { return nil }
        guard let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
        let driver = (raw["driver"] as? String) ?? (raw["instanceId"] as? String) ?? ""
        let provider = driver.lowercased().contains("claude") ? "claude" : "opencode"
        let starter = starters.first { $0.id == id }
        let model = (raw["model"] as? String) ?? starter?.model ?? "opencode/beam-free"
        let options = raw["modelOptions"] as? [[String: Any]] ?? []
        let effort = options.first { ($0["id"] as? String) == "reasoningEffort" }?["value"] as? String
        let look = raw["look"] as? [String: Any]
        let hue = (raw["hue"] as? Double) ?? Double(raw["hue"] as? Int ?? 260)
        return NativeBot(
            id: id, name: name,
            description: raw["description"] as? String ?? "",
            instructions: raw["instructions"] as? String ?? "",
            hue: hue,
            accentHue: (look?["accentHue"] as? Double) ?? Double(look?["accentHue"] as? Int ?? Int(hue + 40)),
            primary: raw["primary"] as? Bool ?? false,
            provider: model.hasPrefix("claude") ? "claude" : provider,
            model: model, effort: effort,
            apps: raw["apps"] as? [String] ?? starter?.apps ?? [])
    }

    static func defaultCategory(_ id: String) -> String {
        ["gmail-reader", "researcher"].contains(id) ? "personal" : "project"
    }

    static let ceoInstructions =
        "You are Theo, the CEO of Addy's project team: Project Manager, Design Critic, Code Improver and Reel " +
        "Editor work under you. In the Project room, take Addy's idea, ask @Project Manager for the plan, " +
        "@Design Critic for the experience and @Code Improver for the technical approach, then merge what they " +
        "say into one final prompt for T3 Code's coding agent, inside a ```prompt fenced block, ready to send. " +
        "Keep everything else short."

    /// The bots everyone starts with: Theo on Claude Sonnet, the rest on free OpenCode models.
    static let starters: [NativeBot] = [
        NativeBot(id: "theo", name: "Theo", description: "CEO of your project team. Leads, delegates and writes the final prompt.",
                  instructions: ceoInstructions,
                  hue: 268, accentHue: 300, primary: true, provider: "claude", model: "claude-sonnet-5-5", effort: nil,
                  apps: ["theo"], category: "project"),
        NativeBot(id: "project-manager", name: "Project Manager", description: "Turns an idea into a clear, ordered plan with scope and risks.",
                  instructions: "You are the Project Manager on Theo's team. Break the idea into a short, ordered plan: scope, milestones, " +
                    "what to build first, risks and open questions. Push back on scope creep. End by tagging @Theo with the plan in a few lines.",
                  hue: 150, accentHue: 120, primary: false, provider: "opencode", model: "opencode/glm-5.3-flash-free", effort: nil,
                  apps: ["notion"], category: "project"),
        NativeBot(id: "design-critic", name: "Design Critic", description: "Critiques the experience and UI before anything gets built.",
                  instructions: "You are the Design Critic on Theo's team. Critique the user experience and interface honestly: what's " +
                    "confusing, what's missing, what would make it feel great. Give the three changes that matter most. End by tagging @Theo.",
                  hue: 320, accentHue: 280, primary: false, provider: "opencode", model: "opencode/deepseek-v4.1-flash-free", effort: nil,
                  apps: ["chrome"], category: "project"),
        NativeBot(id: "code-improver", name: "Code Improver", description: "Makes the technical approach and the code better.",
                  instructions: "You are the Code Improver on Theo's team. Tighten the technical approach: stack, structure, data model, " +
                    "edge cases and tests, and how to keep the code simple. Name concrete improvements. End by tagging @Theo.",
                  hue: 210, accentHue: 190, primary: false, provider: "opencode", model: "opencode/big-pickle", effort: nil,
                  apps: [], category: "project"),
        NativeBot(id: "reel-editor", name: "Reel Editor", description: "Turns footage and ideas into finished reels.",
                  instructions: "You are Reel Editor. Make and edit reels with the HyperFrames skills and the Content Studio tools. Ask before long GPU runs.",
                  hue: 330, accentHue: 300, primary: false, provider: "opencode", model: "opencode/glm-5.3-flash-free", effort: nil,
                  apps: ["studio", "hyperframes", "drive"], category: "project"),
        NativeBot(id: "gmail-reader", name: "Gmail Reader", description: "Reads your inbox, sorts what matters and drafts replies.",
                  instructions: "You are Gmail Reader. Read the inbox with the Gmail tools, group mail into needs-a-reply, FYI and ignore, and draft replies when asked. Never send, delete or label mail without the user's go-ahead.",
                  hue: 0, accentHue: 12, primary: false, provider: "opencode", model: "opencode/flint-40b-free", effort: nil,
                  apps: ["gmail", "calendar", "notion"], category: "personal"),
        NativeBot(id: "researcher", name: "Researcher", description: "Digs into a question and comes back with sources.",
                  instructions: "You are Researcher. Investigate the question, read primary sources, and answer with a short brief that cites them.",
                  hue: 205, accentHue: 180, primary: false, provider: "opencode", model: "opencode/deepseek-v4.1-flash-free", effort: nil,
                  apps: ["chrome", "notion", "theo"], category: "personal"),
    ]

    /// Brings saved bots up to the current team: categories, Theo as CEO, and the
    /// project roles added once (a role you remove later stays removed).
    static func upgrade(_ bots: [NativeBot], offered: inout Set<String>) -> [NativeBot] {
        var result = bots.map { bot -> NativeBot in
            var bot = bot
            if bot.category == nil { bot.category = defaultCategory(bot.id) }
            if bot.primary && !bot.instructions.contains("CEO") { bot.instructions = ceoInstructions }
            return bot
        }
        for starter in starters where !offered.contains(starter.id) {
            if !result.contains(where: { $0.id == starter.id }) { result.append(starter) }
            offered.insert(starter.id)
        }
        return result
    }
}

/// What each bot is told.
enum BotPrompts {
    static let chatStyle =
        "Reply like a chat message: talk directly to the user, keep it short unless they ask for depth, " +
        "and don't start with your name or a heading."

    static func persona(bot: NativeBot, team: [NativeBot]) -> String {
        var parts = [bot.instructions, chatStyle]
        let apps = BotConnectors.known.filter { bot.apps.contains($0.id) }
        if !apps.isEmpty {
            parts.append("Apps you can use: \(apps.map(\.name).joined(separator: ", ")). If one isn't available, " +
                         "say it needs connecting in Theo's Connectors page. Never send messages or emails or make " +
                         "outward changes without the user's go-ahead.")
        }
        if bot.primary {
            let others = team.filter { $0.id != bot.id }
            if !others.isEmpty {
                parts.append("Your teammates: " + others.map { "\($0.name) (\($0.description))" }.joined(separator: "; ") +
                             ". Mention one with @Name in the team chat to bring them in.")
            }
        }
        parts.append("Your memory is \(bot.memoryPath). Read it first if it exists, and add one short line when you " +
                     "learn a lasting preference or fact. Don't store secrets.")
        return parts.joined(separator: "\n\n")
    }

    /// The first message of a bot's chat on engines without a system prompt option.
    static func firstMessage(bot: NativeBot, team: [NativeBot], text: String) -> String {
        bot.provider == "claude" ? text : "\(persona(bot: bot, team: team))\n\n---\n\n\(text)"
    }

    static func teamMessage(bot: NativeBot, team: [NativeBot], firstTime: Bool, newMessages: [BotChatMessage]) -> String {
        let nameOf: (String) -> String = { author in
            author == "user" ? "Addy" : (team.first { $0.id == author }?.name ?? author)
        }
        let transcript = newMessages.map { "\(nameOf($0.author)): \($0.text)" }.joined(separator: "\n")
        var parts: [String] = []
        if firstTime {
            parts.append("You are \(bot.name) in Addy's bots group chat. \(bot.instructions)")
            parts.append("The others here: " + team.filter { $0.id != bot.id }.map { "@\($0.name) (\($0.description))" }.joined(separator: ", ") + ".")
            parts.append("Reply with only your chat message, in your own voice and role, usually 1-4 sentences, without " +
                         "your name at the start. Tag someone with @Name only when you need them.")
        }
        parts.append("New in the group chat:\n\(transcript)")
        parts.append("Reply as \(bot.name).")
        return parts.joined(separator: "\n\n")
    }

    static func mentioned(in text: String, bots: [NativeBot]) -> [NativeBot] {
        let lower = text.lowercased()
        return bots.filter { lower.contains("@\($0.name.lowercased())") }
    }

    /// Drops a "**Name:**" or "Name here." opener a bot adds to its own message.
    static func withoutNameHeading(_ text: String, bot: NativeBot) -> String {
        let name = NSRegularExpression.escapedPattern(for: bot.name)
        guard let regex = try? NSRegularExpression(pattern: "^\\s*\\*{0,2}\(name)( here)?[:.]?\\*{0,2}[:.]?\\s*", options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
