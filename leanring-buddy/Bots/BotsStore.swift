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
import ClickyCore
import Foundation

struct NativeBot: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var description: String
    var instructions: String
    var hue: Double
    var accentHue: Double
    var primary: Bool
    /// "claude", "opencode" or "grok".
    var provider: String
    /// The engine's model id: "claude-sonnet-5-5", "opencode/beam-free", …
    var model: String
    /// Reasoning effort ("low", "medium", "high", …), when the model has one.
    var effort: String?
    /// Claude models: think before answering (nil keeps Claude Code's own setting).
    var thinking: Bool?
    /// Claude models: fast mode (nil keeps Claude Code's own setting).
    var fast: Bool?
    /// App integrations the bot may use; see BotConnectors.known.
    var apps: [String]
    /// "personal" (your own helpers) or "project" (Theo's project team). Older saves have none.
    var category: String?
    /// The avatar's shape: "orb" (default), "square", "sparkle", "clover", "flower", "heart" or "star".
    var shape: String?
    /// The SF Symbol on its tile (nil: its initials).
    var glyph: String?
    /// Which character it wears (a BotCharacter id). Theo keeps its own mark while this is nil.
    var avatar: String?
    /// Off: the bot doesn't answer, run routines or join group chats (nil = on).
    var enabled: Bool?
    /// "member" (default), "lead" (directs its group chats) or "ceo" (may direct any bot).
    var authority: String?
    /// Bots this one may message directly from its own chat (besides what its authority allows).
    var canMessage: [String]?
    /// "clicky": Clicky spawned this bot and gives it its jobs.
    var owner: String?
    /// Which job it does for its owner (a ClickyDuty's raw value).
    var duty: String?

    var isOn: Bool { enabled ?? true }
    var authorityLevel: String { authority ?? (primary ? "ceo" : "member") }

    var isProjectHandler: Bool { (category ?? BotImport.defaultCategory(id)) == "project" }

    var memoryPath: String { "~/.t3/bots/\(id)/memory.md" }

    var modelLabel: String { Self.label(for: model) }

    static func label(for model: String) -> String {
        var name = model.split(separator: "/").last.map(String.init) ?? model
        let free = name.hasSuffix("-free")
        if free { name = String(name.dropLast("-free".count)) }
        // "claude-sonnet-5-5" reads "Claude Sonnet 5.5".
        let versioned = name.replacingOccurrences(of: #"-(\d+)-(\d+)$"#, with: " $1.$2", options: .regularExpression)
        let brands = ["glm": "GLM", "deepseek": "DeepSeek", "gpt": "GPT", "mimo": "MiMo", "opencode": "OpenCode"]
        let words = versioned.split(separator: "-").flatMap { $0.split(separator: " ") }.map { word -> String in
            let lower = word.lowercased()
            if let brand = brands[lower] { return brand }
            if lower.range(of: #"^\d+b$"#, options: .regularExpression) != nil { return lower.uppercased() }
            if lower.first == "v", lower.dropFirst().first?.isNumber == true { return "V" + lower.dropFirst() }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.joined(separator: " ") + (free ? " · free" : "")
    }
}

struct BotChatMessage: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    /// "user" or a bot id.
    var author: String
    var text: String
    var at: Date = Date()
    /// A T3 Code run this message reports on (its result card shows under it).
    var runID: String?
    /// "settings": the bot's settings card shows under it. "delegation:<id>": this message is that job's card.
    var card: String?
}

/// A group of bots with a head who leads its group chat: the head hands the work out with @Name and
/// merges the answers. The project group's chat is the Project room (conversation "team").
struct BotGroup: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    /// The bot that leads the group chat; nil for a plain list of bots.
    var headID: String?
    /// The other bots, in order.
    var memberIDs: [String]

    static let projectID = "project"
    static let personalID = "personal"

    /// The group chat's conversation id.
    var roomID: String { id == Self.projectID ? BotsStore.teamID : "group-\(id)" }
    /// Head first, then the members.
    var allIDs: [String] { (headID.map { [$0] } ?? []) + memberIDs.filter { $0 != headID } }
}

/// One saved conversation and the engine sessions that hold its context.
struct BotConversationRecord: Codable {
    var messages: [BotChatMessage] = []
    /// Engine session per bot (a bot's own chat has one; the team chat one per bot).
    var sessions: [String: String] = [:]
    /// Team chat: how many messages each bot has already been shown.
    var seen: [String: Int] = [:]
    /// When it was last cleared, so a clear on one Mac sticks on the other.
    var clearedAt: Date?
}

@MainActor
final class BotsStore: ObservableObject {
    static let shared = BotsStore()

    @Published private(set) var bots: [NativeBot] = []
    @Published private(set) var conversations: [String: BotConversationRecord] = [:]
    /// Bots with a reply in progress, and the reply text so far ("" while thinking).
    @Published private(set) var replying: [String: String] = [:]
    @Published private(set) var groups: [BotGroup] = []
    /// Scheduled jobs, like Grok Bot's routines.
    @Published private(set) var routines: [BotRoutine] = []
    /// The sidebar: what's pinned, hidden, and in which section.
    @Published private(set) var layout = BotsLayout()
    /// New replies per conversation since it was last open.
    @Published private(set) var unread: [String: Int] = [:]
    /// Jobs Clicky handed its team, and Theo's orders to Clicky, newest last.
    @Published var delegations: [ClickyDelegation] = []
    /// Helpers from the brain's own [WORKER] lines running under Clicky's Researcher right now.
    var teamHelpersRunning = 0
    /// A call that's listening: Clicky's team reporting to the CEO after the call's order was already answered.
    var onCEOReport: ((String) -> Void)?
    /// A group chat talking an idea through: it plans, the others critique, the head merges, and the run starts.
    struct GroupRunBrief {
        enum Stage { case plan, critique, merge }
        var ownerWords: String?
        var harness: String?
        var model: String?
        var effort: String?
        var stage: Stage = .plan
        var reportsTo: ((String) -> Void)?
    }
    private var groupBriefs: [String: GroupRunBrief] = [:]
    /// Team work already passed on, so the same brief doesn't go with every message.
    var passedOnWork: Set<String> = []
    /// Research waiting for the one in progress to end, so one job doesn't kill another.
    var queuedResearch: [() -> Void] = []
    /// How many screen jobs in a row a bot has asked for since the owner last spoke to it.
    var screenTurns: [String: Int] = [:]
    /// Theo is waiting on the head of these group chats, by room.
    private var groupWaiters: [String: (String) -> Void] = [:]
    /// Theo Link: when things changed, and while the other Mac's copy is being applied.
    private var linkBotStamps = LinkMerge.Stamps()
    private var linkGroupStamps = LinkMerge.Stamps()
    private var linkLayoutChangedAt: Date?
    private var isApplyingLink = false
    private var linkSavedBots: [NativeBot] = []
    private var linkSavedGroups: [BotGroup] = []
    private var linkSavedLayout = BotsLayout()
    /// Messages from the other Mac this Mac's engine session hasn't seen, by chat.
    private var linkUnheard: [String: [BotChatMessage]] = [:]
    /// The conversation on screen, which collects no unread count.
    var viewing: String? { didSet { if let viewing { unread[viewing] = nil } } }
    private var routineTimer: Timer?
    private var runningRoutines: Set<String> = []

    static let teamID = "team"

    let folder: URL

    private init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Theo/Bots", isDirectory: true)
        Self.archiveForFreshStart(folder)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("chats"), withIntermediateDirectories: true)
        bots = loadBots()
        groups = loadGroups()
        writeGroups()
        for id in groups.filter { $0.headID != nil }.map(\.roomID) + bots.map(\.id) + [Self.clickyID] {
            conversations[id] = loadConversation(id)
        }
        if let data = try? Data(contentsOf: runsFile), let runs = try? Self.decoder.decode([T3Run].self, from: data) {
            t3Runs = runs
        }
        // A run that was wrapping up when Theo quit goes through its report again; pushing twice is harmless.
        for index in t3Runs.indices where t3Runs[index].phase == "reporting" { t3Runs[index].phase = "running" }
        for run in t3Runs where !run.isRemote && (run.phase == "running" || run.phase == "waiting") { track(run.id) }
        loadRoutinesAndLayout()
        provisionClickyTeam()
        loadDelegations()
        backfillTeamWork()
        loadLinkStamps()
    }

    var primary: NativeBot? { bots.first(where: \.primary) ?? bots.first }

    /// A whole new bots list and sidebar at once, for setting up Clicky's team.
    func setTeamSetup(bots newBots: [NativeBot], layout newLayout: BotsLayout) {
        bots = newBots
        layout = newLayout
        for bot in newBots where conversations[bot.id] == nil { conversations[bot.id] = BotConversationRecord() }
        writeBots()
        writeLayout()
    }

    /// Lights a team bot up, or down, for work that doesn't run through a reply of its own.
    func setReplying(_ text: String?, _ botID: String) { replying[botID] = text }

    /// Once, on the first launch of this version: the old bots, chats and groups move to
    /// Bots-archive-<date> and Theo starts fresh with only Theo and Clicky, for Addy to set up.
    private static func archiveForFreshStart(_ folder: URL) {
        let key = "v3.bots.freshStart"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("bots.json").path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let archive = folder.deletingLastPathComponent().appendingPathComponent("Bots-archive-\(stamp)")
        try? FileManager.default.moveItem(at: folder, to: archive)
    }

    func group(_ id: String) -> BotGroup? { groups.first { $0.id == id } }
    /// The group whose chat this conversation is.
    func group(forRoom roomID: String) -> BotGroup? { groups.first { $0.headID != nil && $0.roomID == roomID } }
    func isRoom(_ conversationID: String) -> Bool { group(forRoom: conversationID) != nil }
    /// A group's bots, head first.
    func members(of group: BotGroup) -> [NativeBot] { group.allIDs.compactMap { bot($0) } }
    func head(of group: BotGroup) -> NativeBot? { group.headID.flatMap { bot($0) } }
    /// The groups a bot leads.
    func groupsLed(by botID: String) -> [BotGroup] { groups.filter { $0.headID == botID } }

    /// Adds or updates a group (its head joins it if it wasn't a member).
    func save(_ group: BotGroup) {
        var group = group
        group.memberIDs.removeAll { $0 == group.headID }
        if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index] = group } else { groups.append(group) }
        if group.headID != nil, conversations[group.roomID] == nil { conversations[group.roomID] = loadConversation(group.roomID) }
        writeGroups()
    }

    /// Removes a group; its bots stay. The project group (the Project room) can't be removed.
    func deleteGroup(_ id: String) {
        if let group = group(id) {
            conversations[group.roomID] = nil
            try? FileManager.default.removeItem(at: chatFile(group.roomID))
        }
        groups.removeAll { $0.id == id }
        writeGroups()
        forget(item: "group:\(id)")
        // Its chat may be what's on screen.
        if BotsSelection.shared.pane == .group(id) { BotsSelection.shared.pane = .home }
    }

    /// A new bot, added to a group (or to no group).
    @discardableResult
    func addBot(name: String, description: String, instructions: String, provider: String, model: String,
                groupID: String?) -> NativeBot {
        var id = BotsT3.slug(name)
        var suffix = 2
        while bot(id) != nil { id = "\(BotsT3.slug(name))-\(suffix)"; suffix += 1 }
        let hue = Double(abs(id.hashValue) % 330)
        var bot = NativeBot(id: id, name: name, description: description, instructions: instructions, hue: hue,
                            accentHue: hue + 30, primary: false, provider: provider, model: model, effort: nil,
                            apps: [], category: groupID == BotGroup.projectID ? "project" : "personal")
        bot.avatar = BotCharacter.firstFree(preferring: BotCharacter.fromSeed(id), among: bots).rawValue
        bots.append(bot)
        writeBots()
        conversations[id] = BotConversationRecord()
        if let groupID, var group = group(groupID) {
            group.memberIDs.append(id)
            save(group)
        }
        return bot
    }

    /// Removes a bot from Theo (its chat file stays on disk). Theo, the CEO, stays.
    func deleteBot(_ id: String) {
        guard id != Self.clickyID, let bot = bot(id), !bot.primary else { return }
        bots.removeAll { $0.id == id }
        for index in groups.indices {
            groups[index].memberIDs.removeAll { $0 == id }
            if groups[index].headID == id { groups[index].headID = nil }
        }
        for index in bots.indices { bots[index].canMessage?.removeAll { $0 == id } }
        BotProcesses.shared.stop(id)
        conversations[id]?.sessions.values.forEach(APIChat.History.forget)
        conversations[id] = nil
        try? FileManager.default.removeItem(at: chatFile(id))
        writeBots()
        writeGroups()
        forget(item: "bot:\(id)")
    }

    func bot(_ id: String) -> NativeBot? { id == Self.clickyID ? clickyBot : bots.first { $0.id == id } }

    func conversation(_ id: String) -> BotConversationRecord { conversations[id] ?? BotConversationRecord() }

    func save(_ bot: NativeBot) {
        // Clicky's own settings live in Settings › Clicky.
        guard bot.id != Self.clickyID else { return }
        let old = self.bot(bot.id)
        if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot } else { bots.append(bot) }
        writeBots()
        if let old, old.provider != bot.provider {
            // A session belongs to one engine: the new engine starts the conversation fresh (the messages stay).
            for id in [bot.id] + groups.map(\.roomID) {
                var record = conversation(id)
                guard record.sessions.removeValue(forKey: bot.id) != nil else { continue }
                conversations[id] = record
                writeConversation(id)
            }
        }
    }

    /// Starts a fresh chat with a bot (its engine session starts over too).
    func clearConversation(_ id: String) {
        conversations[id]?.sessions.values.forEach(APIChat.History.forget)
        conversations[id] = BotConversationRecord(clearedAt: Date())
        writeConversation(id)
    }

    // MARK: Talking

    /// Sends your message to a bot's own chat and streams its reply in.
    /// `command`: what the owner typed, without attachments, which decides whether this is "@code …". A word in an
    /// attached file doesn't start an agent.
    func send(_ text: String, command: String? = nil, to botID: String) {
        if botID == Self.clickyID { return askClicky(text) }
        guard let bot = bot(botID), replying[botID] == nil else { return }
        guard bot.isOn else {
            post(BotChatMessage(author: "user", text: text), to: botID)
            post(BotChatMessage(author: bot.id, text: "_(\(bot.name) is turned off. Turn it on in its settings to chat.)_"), to: botID)
            return
        }
        var record = conversation(botID)
        record.messages.append(BotChatMessage(author: "user", text: text))
        conversations[botID] = record
        writeConversation(botID)
        if BotsStore.isCodingCommand(command ?? text) {
            // "@code …" goes straight to a coding agent, in any chat: a change for this chat's latest run,
            // or a new run when there's none or the message names a folder.
            runCommand(text, room: botID)
            return
        }
        // "Cancel that run": stopped right away, whatever else the message goes on to say.
        if CodingIntent.asksToCancelRun(command ?? text), let live = t3Runs.last(where: { $0.phase == "running" || $0.phase == "waiting" }) { stopRun(live.id) }
        // "Clicky, research X" to the CEO: straight to Clicky, who reports back here.
        if bot.primary, let order = ClickyOrder.parse(command ?? text) {
            orderClicky(order, ownerWords: text)
            return
        }
        if let intent = BotSettingsIntent.parse(command ?? text) {
            answerWithSettings(intent, bot: bot)
            return
        }
        let firstTurn = record.sessions[botID] == nil
        var prompt = firstTurn ? BotPrompts.firstMessage(bot: bot, team: bots, text: text) : text
        if !firstTurn && BotPrompts.asksForSchedule(text) { prompt += "\n\n(\(BotPrompts.routineHowTo))" }
        if !firstTurn && BotsStore.isAboutExistingCode(text) { prompt += "\n\n(\(BotPrompts.codingHowTo))" }
        prompt = takeWaitingReports(for: bot) + ceoTurnNote(for: bot) + linkCatchUp(botID) + prompt
        if bot.owner == nil { prompt = "(\(BotPrompts.screenHowTo))\n\n" + prompt }
        if !bot.primary, !runsStatus.isEmpty { prompt = "(\(runsStatus))\n\n" + prompt }
        if CodingHarnessWords.asksToSendToCode(command ?? text) { prompt += "\n\n(\(BotPrompts.codingHowTo))" }
        screenTurns[botID] = 0
        reply(bot: bot, in: botID, prompt: prompt, session: record.sessions[botID]) { [weak self] answer in
            if let answer { self?.relayMentions(from: bot, answer: answer, in: botID, hop: 0) }
        }
    }

    /// "Switch to haiku", "what model are you on": no reply to read, a card to use. Applies what the message names first.
    private func answerWithSettings(_ intent: BotSettingsIntent, bot original: NativeBot) {
        var bot = original
        var said = "Here's how I'm set up. Change anything right here, and it applies from my next reply."
        if let engine = intent.engine {
            let status = HarnessCenter.shared.status(for: engine)
            let label = HarnessCatalog.label(engine)
            if !status.installed {
                said = "\(label) isn't installed on this Mac yet. You can install it from Settings, Harnesses, or pick another engine here."
            } else if status.loggedIn == false {
                said = "\(label) isn't signed in yet. You can sign in from Settings, Harnesses, or pick another engine here."
            } else {
                bot.provider = engine
                bot.model = BotModels.startingModel(for: engine)
                bot.effort = HarnessPrefs.defaultEffort(engine)
                said = "Done. I'm on **\(label)** now, from my next reply."
            }
        } else if let model = intent.model {
            if let id = BotModels.list(for: bot).first(where: { $0.lowercased().contains(model) }) {
                bot.model = id
                said = "Done. I'm on **\(BotModels.label(id, on: bot.provider))** now, from my next reply."
            } else {
                said = "\(HarnessCatalog.label(bot.provider)) doesn't have \(model.capitalized). Pick another model or engine here."
            }
        } else if let effort = intent.effort {
            bot.effort = effort
            said = "Done. My effort is **\(effort)** now, from my next reply."
        } else if let thinking = intent.thinking {
            bot.thinking = thinking
            said = "Done. Thinking is **\(thinking ? "on" : "off")**, from my next reply."
        } else if let fast = intent.fast {
            bot.fast = fast
            said = "Done. Fast mode is **\(fast ? "on" : "off")**, from my next reply."
        }
        if bot != original { save(bot) }
        post(BotChatMessage(author: bot.id, text: said, card: "settings"), to: bot.id)
    }

    /// A change typed into a run's card: in the chat as the owner's own message, then to the run's agent.
    func sendFollowup(_ text: String, on run: T3Run) {
        let room = run.room ?? Self.teamID
        post(BotChatMessage(author: "user", text: text), to: room)
        sendToCoder(text, room: room)
    }

    /// Posts to the Project room.
    func sendToTeam(_ text: String) {
        if group(BotGroup.projectID)?.headID != nil { sendToGroup(text, groupID: BotGroup.projectID) }
        else if let primary { send(text, to: primary.id) }
    }

    /// Posts to a group chat; tagged bots answer, or the head when nobody is tagged.
    func sendToGroup(_ text: String, command: String? = nil, groupID: String) {
        guard let group = group(groupID), let head = head(of: group) else { return }
        let room = group.roomID
        var record = conversation(room)
        record.messages.append(BotChatMessage(author: "user", text: text))
        conversations[room] = record
        writeConversation(room)
        if BotsStore.isCodingCommand(command ?? text) {
            runCommand(text, room: room)
            return
        }
        if CodingIntent.asksToCancelRun(command ?? text), let live = t3Runs.last(where: { $0.phase == "running" || $0.phase == "waiting" }) { stopRun(live.id) }
        let tagged = BotPrompts.mentioned(in: text, bots: members(of: group))
        if tagged.isEmpty, CodingIntent.wantsDiscussion(command ?? text), groupBriefs[room] == nil {
            groupBriefs[room] = groupRunBrief(ownerWords: text, message: text, reportsTo: nil)
            askTeam([head], chain: 0, group: group, note: BotPrompts.planNote(hasOthers: !otherMembers(of: group).isEmpty))
            return
        }
        askTeam(tagged.isEmpty ? [head] : tagged, chain: 0, group: group)
    }

    private func otherMembers(of group: BotGroup) -> [NativeBot] { members(of: group).filter { $0.id != group.headID && $0.isOn } }

    private func groupRunBrief(ownerWords: String?, message: String, reportsTo: ((String) -> Void)?) -> GroupRunBrief {
        let choices = codingChoices(from: [ownerWords ?? "", message].joined(separator: "\n"))
        return GroupRunBrief(ownerWords: ownerWords, harness: choices.harness, model: choices.model, effort: choices.effort, reportsTo: reportsTo)
    }

    /// The harness, model and effort in someone's words. A model that harness doesn't have is left out, and said so.
    func codingChoices(from words: String) -> (harness: String?, model: String?, effort: String?, problem: String?) {
        let harness = CodingHarnessWords.named(in: words)
        let target = harness ?? HarnessPrefs.codingTarget
        let effort = CodingIntent.effort(in: words)
        guard let hint = CodingIntent.modelHint(in: words) else { return (harness, nil, effort, nil) }
        if ["t3", "claude"].contains(target), let id = CodingIntent.claudeModelID(forHint: hint) { return (harness, id, effort, nil) }
        let tokens = hint.split(whereSeparator: { " -".contains($0) }).map(String.init)
        let listed = HarnessCenter.shared.models(for: target).first { model in
            let name = (model.id + " " + model.label).lowercased()
            return tokens.allSatisfy { name.contains($0) }
        }
        if let listed { return (harness, listed.id, effort, nil) }
        return (harness, nil, effort, "\(HarnessCatalog.label(target)) doesn't have a model called \(hint), so it's on its usual one.")
    }

    /// What the owner said in a chat in the last while, newest first, for what they asked of a run.
    func recentOwnerWords(in room: String) -> String? {
        let since = Date().addingTimeInterval(-20 * 60)
        let said = conversation(room).messages.filter { $0.author == "user" && $0.at >= since }.suffix(3).reversed().map(\.text)
        return said.isEmpty ? nil : said.joined(separator: "\n")
    }

    /// A team is talking something through: its own final prompt starts the run, so nothing else starts one meanwhile.
    var isTeamDiscussing: Bool { !groupBriefs.isEmpty }

    /// Theo posts to a group chat. The head's final answer comes to `then`.
    func sendToGroup(fromCEO text: String, ceo: NativeBot, groupID: String, ownerWords: String?, then: @escaping (String) -> Void) {
        guard let group = group(groupID), let head = head(of: group) else { return }
        let room = group.roomID
        post(BotChatMessage(author: ceo.id, text: text), to: room)
        // They're already talking it through: this joins the discussion rather than starting another.
        if groupBriefs[room] != nil {
            then("That's added to what they're already discussing.")
            return
        }
        var note: String?
        if CodingIntent.wantsDiscussion(text) || CodingIntent.wantsDiscussion(ownerWords ?? "") {
            groupBriefs[room] = groupRunBrief(ownerWords: ownerWords, message: text, reportsTo: then)
            note = BotPrompts.planNote(hasOthers: !otherMembers(of: group).isEmpty)
        } else {
            groupWaiters[room] = then
        }
        Task { [weak self] in
            while self?.replying[head.id] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            self?.askTeam([head], chain: 0, group: group, note: note)
        }
    }

    /// Where a group's discussion goes next, once one of them has answered. True when it was part of one.
    private func advanceBrief(_ room: String, group: BotGroup, head: NativeBot, isHead: Bool, answer: String?, chain: Int) -> Bool {
        guard var brief = groupBriefs[room] else { return false }
        let others = otherMembers(of: group)
        if isHead {
            guard let answer else {
                groupBriefs[room] = nil
                finishBrief(brief, group: group, head: head, answer: "\(head.name) stopped before answering.", hasFailed: true)
                return true
            }
            if brief.stage == .merge || others.isEmpty {
                groupBriefs[room] = nil
                finishBrief(brief, group: group, head: head, answer: answer, hasFailed: false)
            } else {
                brief.stage = .critique
                groupBriefs[room] = brief
                askTeam(others, chain: chain + 1, group: group, note: BotPrompts.critiqueNote)
            }
        } else if others.allSatisfy({ replying[$0.id] == nil }) {
            brief.stage = .merge
            groupBriefs[room] = brief
            askTeam([head], chain: chain + 1, group: group, note: BotPrompts.mergeNote)
        }
        return true
    }

    /// The discussion is over: its outcome goes to Theo's chat, and a final prompt the owner asked for starts its run.
    private func finishBrief(_ brief: GroupRunBrief, group: BotGroup, head: NativeBot, answer: String, hasFailed: Bool) {
        guard let ceo = primary else { return }
        let prompt = hasFailed ? nil : BotsT3.promptBlock(in: answer)
        let owner = brief.ownerWords ?? ""
        let repo = BotsT3.targetRepo(answer: "", pitch: owner)
        let mayStart = prompt != nil && BotsStore.ownerAskedToBuild(owner) && (repo != nil || !BotsStore.isAboutExistingCode(owner))
        if let reportsTo = brief.reportsTo {
            reportsTo(answer)
        } else {
            post(BotChatMessage(author: ceo.id, text: "**\(group.name):** \(answer)"), to: ceo.id)
        }
        guard mayStart, let prompt else { return }
        let title = BotsT3.projectTitle(in: answer, prompt: prompt)
        submitToT3(prompt: prompt, title: title, repo: repo, room: ceo.id, harness: brief.harness, modelChoice: brief.model, effortChoice: brief.effort, alsoRoom: group.roomID) { [weak self] started, problem in
            let line = started ? "Started **\(title)**. You can follow it in \(ceo.name)'s chat." : "**\(title)** didn't start: \(problem ?? "no reason given")."
            self?.post(BotChatMessage(author: head.id, text: line), to: group.roomID)
            self?.onCEOReport?(started ? "\(title) has started coding." : line)
        }
    }

    private func groupAnswered(_ room: String, answer: String) {
        groupWaiters.removeValue(forKey: room)?(answer)
    }

    /// How many bot-to-bot hand-offs one message of yours can set off.
    private static let maxChain = 8

    private func askTeam(_ targets: [NativeBot], chain: Int, group: BotGroup, note: String? = nil) {
        let room = group.roomID
        let team = members(of: group)
        let headID = group.headID
        for bot in targets where replying[bot.id] == nil && bot.isOn {
            let record = conversation(room)
            let seen = record.seen[bot.id] ?? 0
            let newMessages = Array(record.messages.dropFirst(seen))
            var prompt = BotPrompts.teamMessage(bot: bot, team: team, group: group, firstTime: record.sessions[bot.id] == nil,
                                                newMessages: newMessages)
            if !runsStatus.isEmpty { prompt = "(\(runsStatus))\n\n" + prompt }
            if let note { prompt += "\n\n(\(note))" }
            var updated = record
            updated.seen[bot.id] = record.messages.count
            conversations[room] = updated
            reply(bot: bot, in: room, prompt: prompt, session: record.sessions[bot.id]) { [weak self] answer in
                guard let self, chain < Self.maxChain, let group = self.group(group.id), let head = self.head(of: group) else { return }
                let team = self.members(of: group)
                let isHead = bot.id == headID
                if self.advanceBrief(room, group: group, head: head, isHead: isHead, answer: answer, chain: chain) { return }
                guard let answer else {
                    // A member that failed or timed out doesn't stall the room: the head merges what's there.
                    if !isHead, team.allSatisfy({ self.replying[$0.id] == nil }) { self.askTeam([head], chain: chain + 1, group: group) }
                    if isHead { self.groupAnswered(room, answer: "\(head.name) stopped before answering.") }
                    return
                }
                // Only the head (or a lead/CEO) hands out work; members tagging each other would chat on and on.
                let canDelegate = isHead || ["lead", "ceo"].contains(bot.authorityLevel)
                let next = canDelegate ? BotPrompts.mentioned(in: answer, bots: team).filter { $0.id != bot.id && $0.id != head.id } : []
                if isHead || !next.isEmpty {
                    // The head hands the work out, and a planner can hand out the parts.
                    if !next.isEmpty { self.askTeam(next, chain: chain + 1, group: group) }
                    else { self.groupAnswered(room, answer: answer) }
                } else if team.allSatisfy({ self.replying[$0.id] == nil }) {
                    // The last member has answered: the head reads the whole round once and merges it.
                    self.askTeam([head], chain: chain + 1, group: group)
                }
            }
        }
    }

    /// Bots whose reply you stopped; their turn ends without handing on.
    private var stopped: Set<String> = []

    /// Stops a bot's reply in progress (and, in the Project room, the hand-offs it would set off).
    func stop(_ botID: String) {
        guard replying[botID] != nil else { return }
        stopped.insert(botID)
        BotProcesses.shared.stop(botID)
    }

    /// Stops every reply in a group chat.
    func stopGroup(_ groupID: String) {
        guard let group = group(groupID) else { return }
        for bot in members(of: group) where replying[bot.id] != nil { stop(bot.id) }
    }

    /// `handsOnWhenStopped`: a stopped turn still calls `then`, for a roll-up that is waiting on it.
    /// `fromOwner`: false when Clicky's team set this off: its answer can't start a coding run or a routine by itself.
    func reply(bot: NativeBot, in conversationID: String, prompt: String, session: String?, handsOnWhenStopped: Bool = false, fromOwner: Bool = true,
               then: @escaping (String?) -> Void) {
        stopped.remove(bot.id)
        replying[bot.id] = ""
        Task { [weak self] in
            var answer: String?
            var newSession = session
            do {
                let team = self?.bots ?? []
                let result = try await BotRunner.run(bot: bot, prompt: prompt, session: session, team: team) { text in
                    let shown = bot.primary ? ClickyOrder.withoutTags(streaming: text) : text
                    self?.replying[bot.id] = BotScreenOrder.withoutTags(streaming: shown)
                }
                answer = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                newSession = result.session ?? session
            } catch {
                answer = nil
                if self?.stopped.contains(bot.id) != true {
                    self?.post(BotChatMessage(author: bot.id, text: "Couldn't reply: \(error.localizedDescription)"), to: conversationID)
                    if self?.isRoom(conversationID) == true, var record = self?.conversation(conversationID) {
                        // Its own error isn't news to the bot next time.
                        record.seen[bot.id] = record.messages.count
                        self?.conversations[conversationID] = record
                    }
                }
            }
            guard let self else { return }
            // The CEO's orders to Clicky don't show in the chat: they turn into Clicky's cards.
            var orders: [String] = []
            if bot.primary, let said = answer {
                let taken = ClickyOrder.extract(from: said)
                answer = taken.text
                orders = taken.orders
            }
            // A turn the owner set off can ask for the work screen; one set off by a page or another bot's job can't.
            var screenOrders: [String] = []
            if bot.owner == nil, fromOwner, let said = answer {
                let taken = BotScreenOrder.extract(from: said)
                answer = taken.text
                screenOrders = taken.orders
            }
            let streamed = self.replying[bot.id]
            self.replying[bot.id] = nil
            if self.stopped.remove(bot.id) != nil {
                // Keep what it had said so far, marked as stopped, and hand nothing on.
                let partial = (answer ?? streamed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.post(BotChatMessage(author: bot.id, text: partial.isEmpty ? "_(Stopped.)_" : partial + "\n\n_(Stopped.)_"), to: conversationID)
                if handsOnWhenStopped { then(nil) }
                return
            }
            var record = self.conversation(conversationID)
            if let newSession { record.sessions[bot.id] = newSession }
            if let answer, !answer.isEmpty {
                let message = BotChatMessage(author: bot.id, text: BotPrompts.withoutNameHeading(answer, bot: bot))
                self.noteUnread(message, in: conversationID)
                record.messages.append(message)
                if self.isRoom(conversationID) { record.seen[bot.id] = record.messages.count }
            } else if answer != nil && orders.isEmpty && screenOrders.isEmpty {
                record.messages.append(BotChatMessage(author: bot.id, text: "(No answer this time. Send it again, or try another model.)"))
            }
            self.conversations[conversationID] = record
            self.writeConversation(conversationID)
            let ownerSaid = fromOwner ? self.recentOwnerWords(in: conversationID) : nil
            for order in orders { self.carryOutOrder(order, ownerWords: ClickyOrder.tellTarget(in: order) == nil ? nil : ownerSaid) }
            for order in screenOrders { self.workOnScreen(order, bot: bot, room: conversationID) }
            // Any bot in its own chat can start a run, and a group chat's head in that chat.
            if fromOwner, let answer, self.group(forRoom: conversationID)?.headID == bot.id || conversationID == bot.id {
                self.submitIfFinal(answer, room: conversationID)
            }
            if fromOwner, let answer, let request = Self.routineRequest(in: answer) {
                let target = self.group(forRoom: conversationID).map { "group:\($0.id)" } ?? bot.id
                self.addRoutineFromChat(request, target: target, conversationID: conversationID, author: bot.id)
            }
            then(answer)
        }
    }

    /// Pitches whose final prompt already went to T3 Code (by the pitch's message id).
    private var submittedPitches: Set<String> = []
    @Published private(set) var submitting = false
    /// Coding runs Theo started in T3 Code, newest last.
    @Published private(set) var t3Runs: [T3Run] = []
    private var trackedRuns: Set<String> = []

    /// When Theo writes the final prompt for a pitch that asked to build it, it goes to T3 Code by itself.
    /// Once per pitch. A ```followup block goes to the latest run's agent instead.
    private func submitIfFinal(_ answer: String, room: String) {
        guard let pitch = conversation(room).messages.last(where: { $0.author == "user" }),
              !submittedPitches.contains(pitch.id) else { return }
        if let followup = BotsT3.followupBlock(in: answer), latestRun(in: room) != nil {
            submittedPitches.insert(pitch.id)
            sendToCoder(followup, room: room)
            return
        }
        guard let prompt = BotsT3.promptBlock(in: answer), !isTeamDiscussing else { return }
        // Agents run with full access, so only the owner's own words start one by themselves. Anything else gets the card
        // in the chat, whose Start button asks first.
        guard BotsStore.ownerAskedToBuild(pitch.text) else { return }
        let repo = BotsT3.targetRepo(answer: answer, pitch: pitch.text)
        // A folder the owner didn't name could have come from a page the bot read.
        if let repo, repo.standardizedFileURL != BotsT3.targetRepo(answer: "", pitch: pitch.text)?.standardizedFileURL { return }
        // "Fix the login bug" with no folder: the card in the chat asks which one, rather than making a new project.
        if repo == nil && BotsStore.isAboutExistingCode(pitch.text) { return }
        submittedPitches.insert(pitch.id)
        let choices = codingChoices(from: recentOwnerWords(in: room) ?? pitch.text)
        if let problem = choices.problem { post(BotChatMessage(author: speaker(for: room)?.id ?? "theo", text: problem), to: room) }
        submitToT3(prompt: prompt, title: BotsT3.projectTitle(in: answer, prompt: prompt), repo: repo, room: room,
                   harness: choices.harness, modelChoice: choices.model, effortChoice: choices.effort)
    }

    /// "@code …", "@t3 …" or "/run …": straight to a coding agent, no bot in between. As whole words, so @codemirror or
    /// dev@code.org don't count.
    static func isCodingCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.hasPrefix("/run ") || lower.range(of: codingMention, options: .regularExpression) != nil
    }

    private static let codingMention = #"(?i)(^|\s)@(code|t3)(?=$|[\s,:;.!?])"#

    /// Asked in so many words to build or change something, as opposed to "make me a prompt" or "update me on this".
    static func ownerAskedToBuild(_ text: String) -> Bool {
        if CodingHarnessWords.asksToSendToCode(text) { return true }
        let text = CodingIntent.normalized(text)
        if text.range(of: #"(?i)\bprompt\b"#, options: .regularExpression) != nil { return false }
        let direct = #"(?i)\b(build|ship|refactor|fix|pull request|pr)\b"#
        let makeThing = #"(?i)\b(make|create|write|add|change|update|want|need)\b(?!\s+me\s+(on|about|with)\b).*\b(app|site|website|page|game|tool|project|script|cli|api|dashboard|feature|function|test|tests|code|repo)\b"#
        return text.range(of: direct, options: .regularExpression) != nil || text.range(of: makeThing, options: .regularExpression) != nil
    }

    /// Asks to change something that already exists, rather than make something new.
    static func isAboutExistingCode(_ text: String) -> Bool {
        text.range(of: #"\b(fix|change|update|refactor|bug|failing|broken|existing|our|my repo|the repo)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Runs an "@code …" message: a follow-up on this chat's latest run, or a new run when it names a folder or there
    /// is no run yet.
    private func runCommand(_ text: String, room: String) {
        let words = text.replacingOccurrences(of: BotsStore.codingMention, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*/run\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            if let theo = speaker(for: room) {
                post(BotChatMessage(author: theo.id, text: "Say what to do after @code, like \"@code fix the failing test in ~/Projects/foo\"."), to: room)
            }
            return
        }
        let repo = BotsT3.targetRepo(answer: "", pitch: words)
        if repo == nil, latestRun(in: room) != nil {
            sendToCoder(words, room: room)
        } else {
            let choices = codingChoices(from: words)
            submitToT3(prompt: words, title: BotsT3.shortTitle(from: words), repo: repo, room: room, harness: choices.harness, modelChoice: choices.model, effortChoice: choices.effort)
        }
    }

    /// Stops a run in progress. T3 Code has no stop command, so a T3 run is only no longer followed from here.
    func stopRun(_ runID: String) {
        guard var run = t3Runs.first(where: { $0.id == runID }), run.phase == "running" || run.phase == "waiting" else { return }
        if run.isRemote {
            _ = TheoLink.shared.request("stopRun", ["id": runID])
            return
        }
        run.stoppedByOwner = true
        run.phase = "reporting"
        upsert(run)
        HarnessCoding.stop(run)
        if run.harness == nil { Task { await BotsT3.stopThread(run) } }
        if run.harness == CursorCloud.harnessID { Task { await CursorCloud.stop(run) } }
        Task { [weak self] in
            let state = BotsT3.ThreadState(status: "cancelled", busy: false, waitingForAnswer: false, lastMessage: nil, worktree: run.worktree, pullRequest: nil)
            let report = await BotsT3.report(for: &run, state: state) { [weak self] in self?.setStage($0, runID: runID) }
            run.phase = "failed"
            run.finishedAt = Date()
            self?.upsert(run)
            self?.postFromTheo(report, runID: run.id)
        }
    }

    /// The bot that speaks for a room: the bot whose chat it is, a group's head, else Theo.
    private func speaker(for room: String) -> NativeBot? { bot(room) ?? group(forRoom: room).flatMap { head(of: $0) } ?? primary }

    /// The newest run started from a room (older runs have no room: the Project room's).
    func latestRun(in room: String) -> T3Run? { t3Runs.last { ($0.room ?? Self.teamID) == room } }

    /// Creates the T3 Code project (or a branch of `repo`), starts its thread, and follows it to the end.
    /// `started`: told once whether the run got going, for a job waiting on it.
    func submitToT3(prompt: String, title: String, repo: URL? = nil, room: String = BotsStore.teamID, harness: String? = nil,
                    modelChoice: String? = nil, effortChoice: String? = nil, alsoRoom: String? = nil, started: ((Bool, String?) -> Void)? = nil) {
        guard let theo = speaker(for: room) else { return }
        let target = harness ?? HarnessPrefs.codingTarget
        // Coding runs on the Mac with the work screen. From the other Mac it goes there, and shows here as it runs.
        if TheoLink.shared.isPaired, !TheoLink.shared.isWorkMac {
            let fields = ["prompt": prompt, "title": title, "repo": repo?.path ?? "", "room": room, "harness": harness ?? "", "model": modelChoice ?? "", "effort": effortChoice ?? "", "alsoRoom": alsoRoom ?? ""]
            // It never runs here instead: if the Studio's away it goes as soon as it's back.
            let sentNow = TheoLink.shared.requestWhenConnected("run", fields)
            post(BotChatMessage(author: theo.id, text: sentNow ? "Sent **\(title)** to \(TheoLink.shared.peerName ?? "your Mac Studio"). You can watch it here."
                                : "**\(title)** is waiting for your Mac Studio, which isn't connected right now. It starts as soon as it's back."), to: room)
            started?(true, nil)
            return
        }
        Task { [weak self] in
            // One at a time: starting takes up to half a minute while the agent's screen settles.
            while self?.submitting == true { try? await Task.sleep(nanoseconds: 500_000_000) }
            self?.submitting = true
            do {
                var run = try await BotsT3.submit(prompt: prompt, title: title, repo: repo, harness: target, modelChoice: modelChoice, effortChoice: effortChoice)
                run.room = room
                run.alsoRoom = alsoRoom
                guard let self else { return }
                self.submitting = false
                self.upsert(run)
                let place = run.branch.map { "branch `\($0)` of \(repo?.lastPathComponent ?? "the repo")" }
                    ?? (repo.map { "your folder \($0.lastPathComponent)" } ?? "a new project in ~/Projects/\(URL(fileURLWithPath: run.folder).lastPathComponent)")
                self.post(BotChatMessage(author: theo.id, text: "On it. **\(title)** is with \(run.harness.map(HarnessCatalog.label) ?? "T3 Code"), \(place). " +
                    "It's coding on \(run.model.map(NativeBot.label(for:)) ?? BotsT3.modelName)" +
                    (run.effort.flatMap { $0 == "default" ? nil : " at \($0) effort" } ?? "") + ". You can follow along here, and I'll post the result when it's done."), to: room)
                self.track(run.id)
                started?(true, nil)
            } catch {
                self?.submitting = false
                self?.post(BotChatMessage(author: theo.id, text: "Couldn't start the run on \(HarnessCatalog.label(target)): \(error.localizedDescription)"), to: room)
                started?(false, error.localizedDescription)
            }
        }
    }

    /// Passes a change to the latest run's coding agent and follows the run again.
    func sendToCoder(_ text: String, room: String = BotsStore.teamID) {
        if latestRun(in: room)?.isRemote == true {
            if !TheoLink.shared.request("followup", ["room": room, "text": text]), let theo = speaker(for: room) {
                post(BotChatMessage(author: theo.id, text: "Your other Mac isn't connected, so that didn't reach the coding agent."), to: room)
            }
            return
        }
        guard let theo = speaker(for: room), var run = latestRun(in: room) else {
            if let theo = speaker(for: room) {
                post(BotChatMessage(author: theo.id, text: "There's no coding run from this chat yet. Say what to do and where, like \"@code fix the failing test in ~/Projects/foo\"."), to: room)
            }
            return
        }
        guard run.phase != "reporting" else {
            post(BotChatMessage(author: theo.id, text: "**\(run.title)** is wrapping up: tests, commit and push. Send that again in a moment."), to: room)
            return
        }
        Task { [weak self] in
            do {
                let worktree = await BotsT3.state(of: run)?.worktree
                // A plain folder has no base to move: the agent works outside git there.
                if run.baseCommit != nil, let head = await BotsT3.currentHead(of: run, worktree: worktree) { run.baseCommit = head }
                let cloudRun = try await BotsT3.sendFollowup(text, to: run)
                guard let self else { return }
                run.cloudRunID = cloudRun ?? run.cloudRunID
                run.stoppedByOwner = nil
                run.phase = "running"
                run.startedAt = Date()
                run.finishedAt = nil
                self.upsert(run)
                self.post(BotChatMessage(author: theo.id, text: "Passed to \(run.harness.map(HarnessCatalog.label) ?? "T3 Code") on **\(run.title)**. I'll report back when it's done."), to: room)
                self.track(run.id)
            } catch {
                self?.post(BotChatMessage(author: theo.id, text: "Couldn't reach the coding agent: \(error.localizedDescription)"), to: room)
            }
        }
    }

    /// A finished run's agent keeps running in its terminal, ready for a follow-up. Only the newest few stay: a later
    /// follow-up on an older one starts a new terminal that continues the conversation.
    private func releaseOldTerminals() {
        let finished = t3Runs.filter { $0.phase == "done" || $0.phase == "failed" }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        for run in finished.dropFirst(3) where run.id.hasPrefix("term:") && TerminalSessions.shared.session(for: run.id) != nil {
            TerminalSessions.shared.close(run.id)
        }
    }

    /// Checks a run every 15 seconds until it ends, then reports it in the Project room.
    private func track(_ runID: String) {
        guard !trackedRuns.contains(runID) else { return }
        trackedRuns.insert(runID)
        Task { [weak self] in
            var misses = 0
            var askedAbout: String?
            // A run that hasn't started its agent yet reads as idle, so give it a moment first.
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            while let self, var run = self.t3Runs.first(where: { $0.id == runID }), run.phase == "running" || run.phase == "waiting" {
                if run.stoppedByOwner == true { break }
                guard let state = await BotsT3.state(of: run) else {
                    misses += 1
                    if misses >= 40 {
                        // T3 Code has been unreachable for ten minutes: stop and say so instead of spinning.
                        run.phase = "failed"
                        self.upsert(run)
                        let engine = run.harness.map(HarnessCatalog.label) ?? "T3 Code"
                        self.postFromTheo("Lost track of **\(run.title)**: \(engine) isn't answering. Open \(engine) to see where it got to.", room: run.room)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    continue
                }
                misses = 0
                // Stop or a follow-up may have landed while that was being asked.
                guard let current = self.t3Runs.first(where: { $0.id == runID }), current.stoppedByOwner != true else { break }
                run = current
                run.paneTail = Self.paneTail(runID)
                run.activity = state.lastMessage.map { String($0.split(separator: "\n").first ?? "").prefix(140) }.map(String.init)
                if state.waitingForAnswer, !state.busy || state.status == "waiting" {
                    run.phase = "waiting"
                    self.upsert(run)
                    if askedAbout != state.lastMessage {
                        askedAbout = state.lastMessage
                        self.postFromTheo("The coding agent on **\(run.title)** is waiting for an answer:\n\n" +
                                          "\(state.lastMessage ?? "(open T3 Code to see the question)")\n\nAnswer on its card.", room: run.room)
                    }
                } else if !state.busy && (BotsT3.endedStatuses.contains(state.status) || state.status == "idle") {
                    // Tests and the push can take minutes: the card says so and Stop goes away meanwhile.
                    run.phase = "reporting"
                    self.upsert(run)
                    let report = await BotsT3.report(for: &run, state: state) { [weak self] in self?.setStage($0, runID: runID) }
                    run.phase = ["failed", "interrupted", "cancelled", "rolled_back"].contains(state.status) ? "failed" : "done"
                    run.finishedAt = Date()
                    self.upsert(run)
                    if run.stoppedByOwner != true { self.postFromTheo(report, runID: run.id) }
                    self.teamRunFinished(run, report: report)
                    self.releaseOldTerminals()
                    break
                } else {
                    run.phase = "running"
                    self.upsert(run)
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            self?.trackedRuns.remove(runID)
        }
    }

    /// Posts about a run in the chat it came from, as that chat's head.
    private func postFromTheo(_ text: String, runID: String? = nil, room: String? = nil) {
        let room = room ?? runID.flatMap { id in t3Runs.first { $0.id == id }?.room } ?? Self.teamID
        guard let speaker = speaker(for: room) else { return }
        post(BotChatMessage(author: speaker.id, text: text, runID: runID), to: room)
        if let alsoRoom = runID.flatMap({ id in t3Runs.first { $0.id == id }?.alsoRoom }), let head = self.speaker(for: alsoRoom) {
            post(BotChatMessage(author: head.id, text: text, runID: runID), to: alsoRoom)
        }
    }

    /// How far along the wrap-up is, for the run's card.
    private func setStage(_ stage: String, runID: String) {
        guard let index = t3Runs.firstIndex(where: { $0.id == runID }) else { return }
        t3Runs[index].stage = stage
    }

    private static func paneTail(_ runID: String) -> String? {
        TerminalSessions.shared.session(for: runID).map { String($0.screenText().suffix(6000)) }
    }

    private func upsert(_ run: T3Run) {
        var run = run
        if run.origin == nil { run.origin = TheoLink.localName }
        if let index = t3Runs.firstIndex(where: { $0.id == run.id }) { t3Runs[index] = run } else { t3Runs.append(run) }
        if let data = try? Self.encoder.encode(t3Runs) { try? data.write(to: runsFile, options: .atomic) }
    }

    func post(_ message: BotChatMessage, to conversationID: String) {
        noteUnread(message, in: conversationID)
        var record = conversation(conversationID)
        record.messages.append(message)
        conversations[conversationID] = record
        writeConversation(conversationID)
    }

    // MARK: Files

    private var botsFile: URL { folder.appendingPathComponent("bots.json") }
    private var runsFile: URL { folder.appendingPathComponent("t3runs.json") }
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
        let base = (saved?.isEmpty == false ? saved : nil) ?? []
        let offeredFile = folder.appendingPathComponent("offered.json")
        var offered = Set((try? Data(contentsOf: offeredFile)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        var upgraded = BotImport.upgrade(base, offered: &offered)
        // Every bot from before the characters gets its own, no twins. Theo keeps its mark.
        for index in upgraded.indices where upgraded[index].avatar == nil && upgraded[index].id != "theo" {
            upgraded[index].avatar = BotCharacter.firstFree(preferring: BotCharacter.fromSeed(upgraded[index].id), among: upgraded).rawValue
        }
        try? JSONEncoder().encode(Array(offered).sorted()).write(to: offeredFile, options: .atomic)
        bots = upgraded
        writeBots()
        return upgraded
    }


    private var groupsFile: URL { folder.appendingPathComponent("groups.json") }

    /// Saved group chats; a fresh setup has none until Addy makes them.
    private func loadGroups() -> [BotGroup] {
        guard let data = try? Data(contentsOf: groupsFile), let saved = try? Self.decoder.decode([BotGroup].self, from: data) else { return [] }
        return saved.filter { $0.headID == nil || bot($0.headID!) != nil }
    }

    private func writeGroups() {
        noteLinkChanges()
        if let data = try? Self.encoder.encode(groups) { try? data.write(to: groupsFile, options: .atomic) }
    }

    private func writeBots() {
        noteLinkChanges()
        guard let data = try? Self.encoder.encode(bots) else { return }
        try? data.write(to: botsFile, options: .atomic)
    }

    private func loadConversation(_ id: String) -> BotConversationRecord {
        guard let data = try? Data(contentsOf: chatFile(id)) else { return BotConversationRecord() }
        return (try? Self.decoder.decode(BotConversationRecord.self, from: data)) ?? BotConversationRecord()
    }

    func writeConversation(_ id: String) {
        guard let data = try? Self.encoder.encode(conversation(id)) else { return }
        try? data.write(to: chatFile(id), options: .atomic)
    }
}

/// The bot a fresh setup starts with, and fixes for bots saved by older versions.
enum BotImport {
    static func defaultCategory(_ id: String) -> String {
        ["gmail-reader", "researcher"].contains(id) ? "personal" : "project"
    }

    /// Theo, the primary bot: Addy's own helper, the head of any group chat Addy makes him head of, and the
    /// one who hands builds to T3 Code.
    static let primaryInstructions =
        "You are Theo, Addy's primary bot. Help directly with anything Addy asks. " +
        "In a group chat you lead, hand parts of the work to the others with @Name, then merge their answers."

    /// A fresh setup starts with Theo and the Clicky team (BotImport.addClickyTeam); Addy adds every other bot.
    static let starters: [NativeBot] = [
        NativeBot(id: "theo", name: "Theo", description: "Your primary bot. Helps with anything and hands builds to T3 Code.",
                  instructions: primaryInstructions,
                  hue: 268, accentHue: 300, primary: true, provider: "claude", model: "claude-sonnet-5-5", effort: nil,
                  apps: ["theo"], category: "project"),
    ]

    /// Makes sure Theo is there (and primary) and moves an older Code Improver off Big Pickle. Bots Addy
    /// removed stay removed.
    static func upgrade(_ bots: [NativeBot], offered: inout Set<String>) -> [NativeBot] {
        var result = bots.map { bot -> NativeBot in
            var bot = bot
            if bot.category == nil { bot.category = defaultCategory(bot.id) }
            if bot.primary && bot.instructions.contains("Project Manager only") { bot.instructions = primaryInstructions }
            // Only the old sentence goes: anything the owner added stays.
            if bot.primary, let old = bot.instructions.range(of: #"[^.\n]*write one final prompt for T3 Code's coding agent[^.\n]*\.?"#, options: .regularExpression) {
                bot.instructions.replaceSubrange(old, with: "Hand coding work to a harness as described under Coding.")
            }
            if bot.model == "opencode/big-pickle" {
                // Big Pickle kept running past the turn limit; a flash model answers in seconds.
                bot.model = "opencode/deepseek-v4.1-flash-free"
            }
            return bot
        }
        if !result.contains(where: \.primary), let theo = starters.first {
            result.removeAll { $0.id == theo.id }
            result.insert(theo, at: 0)
        }
        offered.insert("fresh-v3")
        return result
    }
}

/// What each bot is told.
enum BotPrompts {
    static let chatStyle =
        "Reply like a chat message: talk directly to the user, keep it short unless they ask for depth, " +
        "and don't start with your name or a heading."

    /// Who a bot reports to, in its instructions. The CEO also gets the whole picture of its teams.
    @MainActor
    static func reportingLines(for bot: NativeBot, store: BotsStore) -> [String] {
        let ceo = store.primary?.name ?? "the CEO"
        var lines = store.categories(of: bot.id).map { team -> String in
            let mates = store.members(of: team).filter { $0.id != bot.id }.map(\.name)
            var line = "Your team: \(team.name)" + (team.purpose.map { " (\($0))" } ?? "") +
                (mates.isEmpty ? "" : ", with \(mates.joined(separator: ", "))") + ". "
            if team.leaderID == bot.id {
                line += "You are its manager: they send you their reports and messages. Hand work to them with @Name, roll their reports up, and report to @\(ceo), the CEO."
            } else if let manager = team.leaderID.flatMap({ store.bot($0) }) {
                line += "\(manager.name) is your manager: send your reports and messages to @\(manager.name), not to \(ceo). \(manager.name) passes on what matters."
            } else {
                line += "It has no manager, so you report straight to @\(ceo), the CEO, when something is worth knowing."
            }
            return line
        }
        if bot.primary {
            let teams = store.rootSections.filter { !store.members(of: $0).isEmpty }.map { team -> String in
                let members = store.members(of: team).filter { $0.id != bot.id }.map(\.name).joined(separator: ", ")
                if let manager = team.leaderID.flatMap({ store.bot($0) }) {
                    return "\(team.name): \(manager.name) manages \(members) and reports to you"
                }
                return "\(team.name): no manager, \(members) report to you directly"
            }
            if !teams.isEmpty {
                lines.append("Your teams: " + teams.joined(separator: "; ") + ". To reach a managed team, go through its manager.")
            }
        }
        return lines
    }

    static func persona(bot: NativeBot, team: [NativeBot]) -> String {
        var parts = [bot.instructions, chatStyle]
        let apps = BotConnectors.known.filter { bot.apps.contains($0.id) }
        if !apps.isEmpty {
            parts.append("Apps you can use: \(apps.map(\.name).joined(separator: ", ")). If one isn't available, " +
                         "say it needs connecting in Theo's Connectors page. Never send messages or emails or make " +
                         "outward changes without the user's go-ahead.")
            let bridged = apps.filter { BotConnectors.bridged($0) }
            if bot.provider != "claude" && !bridged.isEmpty {
                parts.append("On your engine, reach \(bridged.map(\.name).joined(separator: ", ")) with Theo's claudia_app tool " +
                             "(app: \(bridged.map(\.id).joined(separator: ", "))): describe what to look up or draft and it " +
                             "returns what it found. Don't say an app needs connecting before you've tried it.")
            }
        }
        if bot.primary {
            let others = team.filter { $0.id != bot.id && $0.owner == nil }
            if !others.isEmpty {
                parts.append("Your teammates: " + others.map { "\($0.name) (\($0.description))" }.joined(separator: "; ") +
                             ". Mention one with @Name in the team chat to bring them in.")
            }
            parts.append(ClickyTeamPrompts.theoHowTo(team: team.filter { $0.owner == BotsStore.clickyID }.map(\.name)))
            let roster = BotsStore.shared.rosterForCEO
            if !roster.isEmpty { parts.append(roster) }
            let work = BotsStore.shared.memoryStore.teamWorkContext()
            if !work.isEmpty { parts.append(work) }
        }
        if bot.owner == nil {
            parts.append(BotPrompts.routineHowTo)
            parts.append(BotPrompts.codingHowTo)
        }
        parts += BotPrompts.reportingLines(for: bot, store: BotsStore.shared)
        let reachable = BotsStore.shared.reachable(from: bot)
        if !reachable.isEmpty {
            parts.append("Your authority: \(bot.authorityLevel). You may message these bots by writing @Name in your reply; " +
                         "they answer you in the chat and you then carry on: " + reachable.map { "@\($0.name) (\($0.description))" }.joined(separator: ", ") + ".")
        }
        if bot.provider.hasPrefix("api:") {
            // No file tools on this engine: Theo reads the memory file in for it.
            parts.append("You run directly on a model API, with no tools: you can't read files, run commands or change code yourself. To change code, end with a line \"Project: <short name>\", a \"Repo: <path>\" line when the owner named a folder, and the prompt in a ```prompt fenced block, and Theo runs it on a coding harness.")
        } else if bot.owner != nil {
            // Clicky's team gets what it needs in each job.
        } else if bot.provider == "grok" {
            parts.append("Your memory is \(bot.memoryPath). Read it first if it exists.")
        } else {
            parts.append("Your memory is \(bot.memoryPath). Read it first if it exists, and add one short line when you " +
                         "learn a lasting preference or fact. Don't store secrets.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// A group chat's discussion, step by step.
    static func planNote(hasOthers: Bool) -> String {
        hasOthers
            ? "Lay out your plan for the group in a few lines, so they can pick it apart. No ```prompt block yet, and don't say anything has been sent or started."
            : mergeNote
    }

    static let critiqueNote = "Give a real critique of the plan above from your own role: what's missing, what's likely to go wrong, what you'd change. Be specific and disagree where you do. Don't write the final prompt."

    static let mergeNote = "Now write the outcome. Say briefly what each person raised and what changed because of it, then a line \"Project: <short name>\" and the complete final instructions in a ```prompt block. You don't start or send anything yourself: Theo starts the run on the harness and model Addy chose as soon as you've written it, and you'll see it in the list of runs."

    /// Bots work on the far right screen of Addy's Mac Studio, through Clicky.
    static let screenHowTo =
        "You can work on Addy's Mac Studio's right screen, which is set aside for you. For anything on it (opening an app or " +
        "site, clicking, reading what's there) put a line [SCREEN: what to do, in plain words] in your reply. Clicky does it there and " +
        "tells you what happened. Writing or changing code doesn't go through this: use a ```prompt block."

    /// How a bot sets up a routine. Theo does the scheduling, so no scheduling tool or skill is needed.
    static let routineHowTo =
        "Routines: when Addy asks for something on a schedule (\"every weekday at 8, …\"), don't use any scheduling, " +
        "cron or schedule tool or skill: Theo runs routines for you. Say what you'll do and when, then add a ```routine " +
        "block with JSON {\"name\": short name, \"when\": \"daily 08:00\" | \"weekdays 08:30\" | \"weekly mon 09:00\" | " +
        "\"hourly\" | \"every 30 minutes\", \"do\": the instruction you'll be given at each run}. Theo then runs it on " +
        "time, and Addy can pause, run or delete it."

    /// How any bot starts a coding run. Bots don't edit code themselves: a harness does it in its own branch.
    static var codingHowTo: String {
        "Coding: when the owner asks to build, fix or change code, don't edit files yourself. Plan it in a sentence or two, then write: a line " +
        "\"Project: <short name>\", a line \"Repo: <path>\" when they named an existing folder, and the full instructions for the coding agent " +
        "in a ```prompt fenced block. Theo then runs it on \(HarnessCatalog.label(HarnessPrefs.codingTarget)): an existing git repo gets its own branch and " +
        "worktree, and the result comes back with the changes, tests and a draft pull request. For a change to the run you already started, " +
        "put it in a ```followup fenced block instead."
    }

    /// Words that ask for something on a schedule, so the routine how-to rides along even in an older chat.
    static func asksForSchedule(_ text: String) -> Bool {
        text.range(of: #"\b(every|each)\s+(day|morning|evening|night|weekday|week|monday|tuesday|wednesday|thursday|friday|saturday|sunday|hour|\d+\s*(min|minutes|hours?))\b|\b(daily|hourly|weekly|routine|schedule)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The first message of a bot's chat on engines without a system prompt option.
    static func firstMessage(bot: NativeBot, team: [NativeBot], text: String) -> String {
        // Claude Code and the API engines take the persona as a system prompt; the others get it in the first message.
        bot.provider == "claude" || bot.provider.hasPrefix("api:") ? text : "\(persona(bot: bot, team: team))\n\n---\n\n\(text)"
    }

    static func teamMessage(bot: NativeBot, team: [NativeBot], group: BotGroup, firstTime: Bool,
                            newMessages: [BotChatMessage]) -> String {
        let nameOf: (String) -> String = { author in
            author == "user" ? "Addy" : (team.first { $0.id == author }?.name ?? author)
        }
        let transcript = newMessages.map { "\(nameOf($0.author)): \($0.text)" }.joined(separator: "\n")
        var parts: [String] = []
        if firstTime {
            // Claude has the persona as its system prompt already; other engines get it here.
            parts.append("You are \(bot.name) in Addy's \"\(group.name)\" group chat. " +
                         (bot.provider == "claude" || bot.provider.hasPrefix("api:") ? bot.instructions : persona(bot: bot, team: team)))
            if group.headID == bot.id && !bot.primary {
                // Theo's CEO instructions already say this; any other head gets it here.
                parts.append("You lead this group. Hand the parts of Addy's request to the others with @Name, then, once " +
                             "they've answered, merge it into one final answer. When Addy asks to build something, end " +
                             "with a line \"Project: <short name>\" and the prompt for T3 Code's coding agent in a " +
                             "```prompt fenced block.")
            }
            parts.append("The others here: " + team.filter { $0.id != bot.id }.map { "@\($0.name) (\($0.description))" }.joined(separator: ", ") + ".")
            parts.append("Reply with only your chat message, in your own voice and role, usually 1-4 sentences, without " +
                         "your name at the start. Tag someone with @Name only when you need them. In the Project " +
                         "room, answer the question you're given once, in your role; Theo collects the round and merges it.")
        }
        if bot.owner == nil { parts.append(screenHowTo) }
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


// MARK: - Sidebar layout

/// What the sidebar shows where, like Grok Bot's: pinned items on top, your own sections, hidden bots.
/// Items are "bot:<id>", "group:<id>" or "clicky".
struct BotsLayout: Codable, Equatable {
    var pinned: [String] = ["bot:theo", "clicky"]
    var hidden: [String] = []
    var sections: [Section] = []

    struct Section: Codable, Identifiable, Equatable {
        var id: String = UUID().uuidString
        var name: String
        var items: [String] = []
        /// A sub-category sits inside another section.
        var parentID: String?
        var collapsed: Bool?
        /// The category's manager: members send it their reports and DMs, it rolls them up for the CEO. With none,
        /// every member reports to the CEO directly. (Saved as leaderID since categories first had leaders.)
        var leaderID: String?
        /// "Has a manager" was switched on before a bot was picked for the job.
        var wantsManager: Bool?
        /// What this team is for, in a line ("Inbox and calendar", "Ship the website").
        var purpose: String?
        /// The tile colour (a BotPalette swatch id) and SF Symbol of the category.
        var swatch: String?
        var symbol: String?
        /// The last reports this team sent the CEO, newest last.
        var reports: [Report]?

        var hasManager: Bool { leaderID != nil || wantsManager == true }
    }

    struct Report: Codable, Equatable, Identifiable {
        var id: String = UUID().uuidString
        var at: Date = Date()
        var author: String
        var text: String
    }

    func section(of item: String) -> Section? { sections.first { $0.items.contains(item) } }

    /// A bot's item in the sidebar: Clicky has its own.
    static func item(forBot botID: String) -> String { botID == BotsStore.clickyID ? "clicky" : "bot:\(botID)" }

    /// The bot an item stands for; nil for a group chat.
    static func botID(ofItem item: String) -> String? {
        if item == "clicky" { return BotsStore.clickyID }
        return item.hasPrefix("bot:") ? String(item.dropFirst(4)) : nil
    }
}

// MARK: - Routines, layout and unread

extension BotsStore {
    private var routinesFile: URL { folder.appendingPathComponent("routines.json") }
    private var layoutFile: URL { folder.appendingPathComponent("layout.json") }

    fileprivate func loadRoutinesAndLayout() {
        if let data = try? Data(contentsOf: routinesFile), let saved = try? Self.decoder.decode([BotRoutine].self, from: data) {
            routines = saved
        }
        if let data = try? Data(contentsOf: layoutFile), let saved = try? Self.decoder.decode(BotsLayout.self, from: data) {
            layout = saved
        } else {
            // First run: a group without a head (the old "Personal" list) becomes a sidebar section.
            for group in groups where group.headID == nil {
                layout.sections.append(BotsLayout.Section(name: group.name, items: group.memberIDs.map { "bot:\($0)" }))
            }
            groups.removeAll { $0.headID == nil }
            writeGroups()
            writeLayout()
        }
        // A routine whose time passed while Theo was closed runs once now (a catch-up), then keeps its schedule.
        let now = Date()
        for index in routines.indices where routines[index].nextRunAt == nil {
            routines[index].nextRunAt = routines[index].schedule.next(after: now)
        }
        writeRoutines()
        routineTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runDueRoutines() }
        }
        Task { @MainActor in self.runDueRoutines() }
    }

    private func writeRoutines() {
        if let data = try? Self.encoder.encode(routines) { try? data.write(to: routinesFile, options: .atomic) }
    }

    func writeLayout() {
        noteLinkChanges()
        if let data = try? Self.encoder.encode(layout) { try? data.write(to: layoutFile, options: .atomic) }
    }

    // MARK: Routines

    func routines(for target: String) -> [BotRoutine] { routines.filter { $0.target == target } }

    func targetName(_ target: String) -> String {
        if target.hasPrefix("group:") { return group(String(target.dropFirst(6)))?.name ?? "Group" }
        if target.hasPrefix("report:") { return (category(String(target.dropFirst(7)))?.name ?? "Team") + " report" }
        return bot(target)?.name ?? target
    }

    func save(_ routine: BotRoutine) {
        var routine = routine
        if routine.nextRunAt == nil || !routines.contains(where: { $0.id == routine.id && $0.schedule == routine.schedule }) {
            routine.nextRunAt = routine.schedule.next(after: Date())
        }
        if let index = routines.firstIndex(where: { $0.id == routine.id }) { routines[index] = routine } else { routines.append(routine) }
        writeRoutines()
    }

    func setPaused(_ paused: Bool, routineID: String) {
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[index].paused = paused
        // Resuming picks up at the next slot, not every slot missed while paused.
        if !paused { routines[index].nextRunAt = routines[index].schedule.next(after: Date()) }
        writeRoutines()
    }

    func deleteRoutine(_ routineID: String) {
        routines.removeAll { $0.id == routineID }
        writeRoutines()
    }

    /// "Run now" (Grok's Test): a real run, out of schedule; the next scheduled run stays.
    func runRoutineNow(_ routineID: String) {
        guard let routine = routines.first(where: { $0.id == routineID }) else { return }
        start(routine, scheduled: false)
    }

    private func runDueRoutines() {
        let now = Date()
        for routine in routines where !routine.paused && (routine.nextRunAt ?? .distantFuture) <= now {
            if let index = routines.firstIndex(where: { $0.id == routine.id }) {
                routines[index].nextRunAt = routine.schedule.next(after: now)
            }
            start(routine, scheduled: true)
        }
        writeRoutines()
    }

    private func start(_ routine: BotRoutine, scheduled: Bool) {
        guard !runningRoutines.contains(routine.id) else { return }
        let text = "⏰ Routine \"\(routine.name)\": \(routine.instruction)"
        if routine.target.hasPrefix("report:") {
            let sectionID = String(routine.target.dropFirst(7))
            guard layout.sections.contains(where: { $0.id == sectionID }) else {
                return record(routine.id, .init(startedAt: Date(), finishedAt: Date(), status: "failed", summary: "The category is gone."))
            }
            reportToCEO(sectionID)
            return record(routine.id, .init(startedAt: Date(), finishedAt: Date(), status: "done", summary: "Report sent to the CEO."))
        }
        if routine.target.hasPrefix("group:") {
            let groupID = String(routine.target.dropFirst(6))
            guard group(groupID) != nil else { return record(routine.id, .init(startedAt: Date(), finishedAt: Date(), status: "failed", summary: "The group is gone.")) }
            sendToGroup(text, groupID: groupID)
            return record(routine.id, .init(startedAt: Date(), finishedAt: Date(), status: "done", summary: "Posted to the group chat."))
        }
        guard let bot = bot(routine.target) else {
            return record(routine.id, .init(startedAt: Date(), finishedAt: Date(), status: "failed", summary: "The bot is gone."))
        }
        guard bot.isOn else {
            return record(routine.id, .init(startedAt: Date(), finishedAt: Date(), status: "skipped", summary: "\(bot.name) is turned off."))
        }
        guard replying[bot.id] == nil else {
            // Busy right now: a scheduled run waits a minute instead of being lost.
            if scheduled, let index = routines.firstIndex(where: { $0.id == routine.id }) {
                routines[index].nextRunAt = Date().addingTimeInterval(60)
                writeRoutines()
            }
            return
        }
        runningRoutines.insert(routine.id)
        let run = BotRoutine.Run(startedAt: Date(), status: "running")
        record(routine.id, run)
        var conversationRecord = conversation(bot.id)
        conversationRecord.messages.append(BotChatMessage(author: "routine", text: text))
        conversations[bot.id] = conversationRecord
        writeConversation(bot.id)
        let firstTurn = conversationRecord.sessions[bot.id] == nil
        let prompt = (firstTurn ? BotPrompts.firstMessage(bot: bot, team: bots, text: text) : text) +
            "\n\n(This is a scheduled run of a routine Addy set up; do the job now and report briefly.)"
        reply(bot: bot, in: bot.id, prompt: prompt, session: conversationRecord.sessions[bot.id]) { [weak self] answer in
            guard let self else { return }
            self.runningRoutines.remove(routine.id)
            var finished = run
            finished.finishedAt = Date()
            finished.status = answer == nil ? "failed" : "done"
            finished.summary = answer.map { String($0.prefix(140)) }
            self.record(routine.id, finished)
        }
    }

    /// Adds or updates a run in the routine's history (the last 20 are kept).
    private func record(_ routineID: String, _ run: BotRoutine.Run) {
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        if let existing = routines[index].runs.firstIndex(where: { $0.id == run.id }) {
            routines[index].runs[existing] = run
        } else {
            routines[index].runs.append(run)
            if routines[index].runs.count > 20 { routines[index].runs.removeFirst(routines[index].runs.count - 20) }
        }
        writeRoutines()
    }

    fileprivate func addRoutineFromChat(_ request: (name: String, schedule: BotRoutine.Schedule, instruction: String),
                                        target: String, conversationID: String, author: String) {
        // The same routine asked twice (a repeated reply) isn't added twice.
        guard !routines.contains(where: { $0.target == target && $0.instruction == request.instruction && $0.schedule == request.schedule }) else { return }
        let routine = BotRoutine(name: request.name, target: target, instruction: request.instruction, schedule: request.schedule)
        // The reply's own card shows it, with Pause and Run now.
        save(routine)
    }

    // MARK: Sidebar

    func isPinned(_ item: String) -> Bool { layout.pinned.contains(item) }
    func isHidden(_ item: String) -> Bool { layout.hidden.contains(item) }

    func setPinned(_ pinned: Bool, _ item: String) {
        layout.pinned.removeAll { $0 == item }
        if pinned { layout.pinned.append(item); layout.hidden.removeAll { $0 == item } }
        writeLayout()
    }

    /// Grok's "Hide from sidebar": the bot keeps working and its routines keep running.
    func setHidden(_ hidden: Bool, _ item: String) {
        layout.hidden.removeAll { $0 == item }
        // A hidden bot stays pinned underneath, so showing it again puts it back where it was.
        if hidden { layout.hidden.append(item) }
        writeLayout()
    }

    /// Moves an item into a section (nil: back to the default lists); a new name makes a new section.
    func move(_ item: String, toSection sectionID: String?, newSectionName: String? = nil) {
        for index in layout.sections.indices { layout.sections[index].items.removeAll { $0 == item } }
        if let newSectionName, !newSectionName.trimmingCharacters(in: .whitespaces).isEmpty {
            layout.sections.append(BotsLayout.Section(name: newSectionName.trimmingCharacters(in: .whitespaces), items: item.isEmpty ? [] : [item]))
        } else if let sectionID, let index = layout.sections.firstIndex(where: { $0.id == sectionID }) {
            layout.sections[index].items.append(item)
        }
        writeLayout()
    }

    func renameSection(_ sectionID: String, to name: String) {
        guard let index = layout.sections.firstIndex(where: { $0.id == sectionID }), !name.isEmpty else { return }
        layout.sections[index].name = name
        writeLayout()
    }

    /// Removes a section; its items go back to the default lists.
    func deleteSection(_ sectionID: String) {
        layout.sections.removeAll { $0.id == sectionID }
        writeLayout()
    }

    /// Deleting a bot also takes its routines and its place in the sidebar, as in Grok Bot.
    func forget(item: String) {
        layout.pinned.removeAll { $0 == item }
        layout.hidden.removeAll { $0 == item }
        for index in layout.sections.indices { layout.sections[index].items.removeAll { $0 == item } }
        writeLayout()
        let target = item.hasPrefix("bot:") ? String(item.dropFirst(4)) : item
        routines.removeAll { $0.target == target }
        writeRoutines()
    }

    // MARK: Unread

    fileprivate func noteUnread(_ message: BotChatMessage, in conversationID: String) {
        guard message.author != "user", conversationID != viewing else { return }
        unread[conversationID, default: 0] += 1
    }
}

// MARK: - Categories, on/off and bots messaging each other

extension BotsStore {
    /// Top-level categories, then each one's sub-categories.
    var rootSections: [BotsLayout.Section] { layout.sections.filter { $0.parentID == nil } }
    func subsections(of sectionID: String) -> [BotsLayout.Section] { layout.sections.filter { $0.parentID == sectionID } }

    @discardableResult
    func addSection(named name: String, parentID: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let section = BotsLayout.Section(name: trimmed, parentID: parentID)
        layout.sections.append(section)
        writeLayout()
        return section.id
    }

    func toggleCollapsed(_ sectionID: String) {
        guard let index = layout.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        layout.sections[index].collapsed = !(layout.sections[index].collapsed ?? false)
        writeLayout()
    }

    func setEnabled(_ on: Bool, botID: String) {
        guard var bot = bot(botID) else { return }
        bot.enabled = on
        save(bot)
    }

    /// Whom a bot may message: a CEO anyone, a lead the bots of the group chats it heads, plus anyone you allowed.
    /// A category's manager also reaches its team and the CEO; a member its manager (or, with no manager, its
    /// teammates and the CEO).
    func reachable(from bot: NativeBot) -> [NativeBot] {
        // Clicky's team gets its jobs from Clicky.
        let others = bots.filter { $0.id != bot.id && $0.isOn && ($0.owner == nil || bot.id == Self.clickyID) }
        var allowed = Set(bot.canMessage ?? [])
        switch bot.authorityLevel {
        case "ceo": return others
        case "lead": allowed.formUnion(groupsLed(by: bot.id).flatMap(\.memberIDs))
        default: break
        }
        for team in categories(of: bot.id) {
            let members = memberIDs(of: team)
            if team.leaderID == bot.id {
                allowed.formUnion(members)
                if let ceo = primary { allowed.insert(ceo.id) }
            } else if let leader = team.leaderID {
                allowed.insert(leader)
            } else {
                allowed.formUnion(members)
                if let ceo = primary { allowed.insert(ceo.id) }
            }
        }
        return others.filter { allowed.contains($0.id) }
    }

    /// After a bot answers in its own chat: any bot it @mentions (and may reach) answers there, then the
    /// first bot reads the answers and carries on. A few hops at most.
    func relayMentions(from bot: NativeBot, answer: String, in conversationID: String, hop: Int) {
        guard hop < 3 else { return }
        var named = BotPrompts.mentioned(in: answer, bots: reachable(from: bot))
        // A member of a managed team who names anyone else reaches its manager instead.
        if named.isEmpty, let manager = manager(of: bot), !BotPrompts.mentioned(in: answer, bots: bots.filter { $0.id != bot.id }).isEmpty {
            named = [manager]
        }
        // Clicky isn't a bot turn: it has a screen and a voice of its own, so it's reached through its orders.
        let targets = named.filter { replying[$0.id] == nil && $0.id != Self.clickyID }
        guard !targets.isEmpty else { return }
        var answers: [String] = []
        var remaining = targets.count
        for target in targets {
            let prompt = BotPrompts.persona(bot: target, team: bots) + "\n\n---\n\n\(bot.name) (\(bot.authorityLevel)) asks you, in " +
                "Addy's chat with \(bot.name):\n\n\(answer)\n\nAnswer \(bot.name) directly and briefly."
            relayTurn(target, prompt: prompt, in: conversationID) { [weak self] reply in
                guard let self else { return }
                if let reply { answers.append("\(target.name): \(reply)") }
                remaining -= 1
                guard remaining == 0, !answers.isEmpty, self.replying[bot.id] == nil else { return }
                // The asking bot reads what came back and finishes the job.
                let followUp = "Replies from the bots you asked:\n\n" + answers.joined(separator: "\n\n") +
                    "\n\nCarry on for Addy with this."
                let session = self.conversation(conversationID).sessions[bot.id]
                self.relayTurn(bot, prompt: followUp, in: conversationID, session: session) { [weak self] final in
                    if let final, let self { self.relayMentions(from: bot, answer: final, in: conversationID, hop: hop + 1) }
                }
            }
        }
    }
}

extension BotsStore {
    /// One turn of a bot in someone else's chat (a bot it was messaged by), shown there under its own name.
    fileprivate func relayTurn(_ bot: NativeBot, prompt: String, in conversationID: String, session: String? = nil,
                               then: @escaping (String?) -> Void) {
        let session = session ?? conversation(conversationID).sessions[bot.id]
        reply(bot: bot, in: conversationID, prompt: prompt, session: session, then: then)
    }
}

extension BotsStore {
    /// Makes a bot the primary one (the star): it leads by default, gets the T3 hand-off in its own chat
    /// and takes the old primary's pinned spot.
    func makePrimary(_ botID: String) {
        guard botID != Self.clickyID, let old = primary, old.id != botID, var new = bot(botID) else { return }
        var demoted = old
        demoted.primary = false
        if demoted.authority == nil || demoted.authority == "ceo" { demoted.authority = "lead" }
        // The primary's added duties leave with the role (Theo's own instructions are the duties themselves).
        demoted.instructions = demoted.instructions.replacingOccurrences(of: "\n\n" + BotImport.primaryInstructions, with: "")
        new.primary = true
        new.enabled = true
        new.authority = "ceo"
        if !new.instructions.contains("```prompt") { new.instructions += "\n\n" + BotImport.primaryInstructions }
        save(demoted)
        save(new)
        // The new primary takes the old one's pinned spot (or the top).
        let oldIndex = layout.pinned.firstIndex(of: "bot:\(old.id)") ?? 0
        layout.pinned.removeAll { $0 == "bot:\(new.id)" || $0 == "bot:\(old.id)" }
        layout.pinned.insert("bot:\(new.id)", at: min(oldIndex, layout.pinned.count))
        for other in bots where other.primary && other.id != new.id {
            var demotedToo = other
            demotedToo.primary = false
            save(demotedToo)
        }
        writeLayout()
    }
}

// MARK: - Teams: categories with a manager who reports to the CEO

extension BotsStore {
    func category(_ id: String) -> BotsLayout.Section? { layout.sections.first { $0.id == id } }

    /// The bot ids filed in a category (its sub-categories have their own teams).
    func memberIDs(of section: BotsLayout.Section) -> [String] {
        section.items.compactMap(BotsLayout.botID(ofItem:)).filter { bot($0) != nil }
    }

    func members(of section: BotsLayout.Section) -> [NativeBot] { memberIDs(of: section).compactMap { bot($0) } }

    func categories(of botID: String) -> [BotsLayout.Section] { layout.sections.filter { $0.items.contains(BotsLayout.item(forBot: botID)) } }

    func updateCategory(_ id: String, _ change: (inout BotsLayout.Section) -> Void) {
        guard let index = layout.sections.firstIndex(where: { $0.id == id }) else { return }
        change(&layout.sections[index])
        // A leader always sits in its own team.
        if let leader = layout.sections[index].leaderID, !layout.sections[index].items.contains(BotsLayout.item(forBot: leader)) {
            if bot(leader) == nil { layout.sections[index].leaderID = nil } else { layout.sections[index].items.append(BotsLayout.item(forBot: leader)) }
        }
        writeLayout()
    }

    func setLeader(_ botID: String?, of sectionID: String) {
        updateCategory(sectionID) {
            $0.leaderID = botID
            $0.wantsManager = botID == nil ? nil : true
        }
    }

    /// The "Has a manager" switch. On, the first non-CEO member takes the job until another is picked; off, everyone
    /// reports to the CEO directly.
    func setHasManager(_ on: Bool, of sectionID: String) {
        updateCategory(sectionID) { section in
            guard on else {
                section.leaderID = nil
                section.wantsManager = nil
                return
            }
            section.wantsManager = true
            if section.leaderID == nil {
                section.leaderID = section.items.compactMap(BotsLayout.botID(ofItem:)).compactMap { self.bot($0) }.first { !$0.primary }?.id
            }
        }
    }

    /// Adds a bot to a team; a bot can sit in more than one.
    func addMember(_ botID: String, to sectionID: String) {
        updateCategory(sectionID) { if !$0.items.contains(BotsLayout.item(forBot: botID)) { $0.items.append(BotsLayout.item(forBot: botID)) } }
    }

    func removeMember(_ botID: String, from sectionID: String) {
        updateCategory(sectionID) {
            $0.items.removeAll { $0 == BotsLayout.item(forBot: botID) }
            if $0.leaderID == botID { $0.leaderID = nil }
        }
    }

    /// The "report:<id>" routine that sends this team's report to the CEO on a schedule, if there is one.
    func reportRoutine(of sectionID: String) -> BotRoutine? { routines.first { $0.target == "report:\(sectionID)" } }

    func setReportSchedule(_ schedule: BotRoutine.Schedule?, for sectionID: String) {
        if let existing = reportRoutine(of: sectionID) { routines.removeAll { $0.id == existing.id } }
        if let schedule, let section = category(sectionID) {
            save(BotRoutine(name: "\(section.name) report", target: "report:\(sectionID)", instruction: "Report to the CEO", schedule: schedule))
        } else {
            writeRoutines()
        }
    }

    /// What a bot did lately: its last few exchanges and routine runs, for a report.
    private func recentWork(of bot: NativeBot) -> String {
        let messages = conversation(bot.id).messages.filter { !$0.text.isEmpty }.suffix(8)
        var lines = messages.map { message -> String in
            let who = message.author == "user" ? "Addy" : message.author == "routine" ? "Routine" : self.bot(message.author)?.name ?? bot.name
            return "- \(who): " + String(message.text.replacingOccurrences(of: "\n", with: " ").prefix(280))
        }
        for routine in routines where routine.target == bot.id {
            for run in routine.runs.suffix(2) { lines.append("- Routine \"\(routine.name)\" \(run.status): \(run.summary ?? "")") }
        }
        return lines.isEmpty ? "- Nothing yet." : lines.joined(separator: "\n")
    }

    /// The manager of the team this bot is a plain member of, if it has one.
    func manager(of bot: NativeBot) -> NativeBot? {
        for team in categories(of: bot.id) {
            if let id = team.leaderID, id != bot.id, let manager = self.bot(id), manager.isOn { return manager }
        }
        return nil
    }

    /// Everyone reports. With a manager: each member sends its report to the manager's chat, then the manager rolls
    /// them up and reports to the CEO. Without one: each member reports to the CEO's chat directly. The CEO reads
    /// what came in at the start of its next turn (`takeWaitingReports`).
    func reportToCEO(_ sectionID: String) {
        guard let section = category(sectionID), let ceo = primary else { return }
        let team = members(of: section).filter(\.isOn)
        guard !team.isEmpty else { return }
        if let manager = section.leaderID.flatMap({ bot($0) }), manager.isOn, manager.id != ceo.id {
            reportThroughManager(section, manager: manager, ceo: ceo, team: team)
            return
        }
        for reporter in team where reporter.id != ceo.id && replying[reporter.id] == nil {
            let prompt = reportPrompt(reporter, to: ceo, role: "You're on the \(section.name) team (it has no manager, so you report yourself)", section: section,
                                      activity: "\(reporter.name) (\(reporter.description)):\n" + recentWork(of: reporter))
            post(BotChatMessage(author: "routine", text: "📋 \(reporter.name) is reporting to \(ceo.name) for \(section.name)."), to: ceo.id)
            reply(bot: reporter, in: ceo.id, prompt: prompt, session: nil) { [weak self] answer in
                guard let self, let answer, !answer.isEmpty else { return }
                self.recordReport(answer, by: reporter, in: sectionID)
            }
        }
    }

    private func reportPrompt(_ reporter: NativeBot, to reader: NativeBot, role: String, section: BotsLayout.Section, activity: String) -> String {
        BotPrompts.persona(bot: reporter, team: bots) + "\n\n---\n\n\(role)" +
            (section.purpose.map { ", whose job is: \($0)" } ?? "") + ". Write \(reader.name) a short report: " +
            "what got done, what's in progress, anything blocked or needing Addy. Plain sentences or a few bullets, no preamble.\n\n" +
            "Recent activity:\n\n\(activity)"
    }

    private func recordReport(_ text: String, by reporter: NativeBot, in sectionID: String) {
        updateCategory(sectionID) {
            var reports = $0.reports ?? []
            reports.append(BotsLayout.Report(author: reporter.id, text: text))
            $0.reports = Array(reports.suffix(10))
        }
    }

    private func reportThroughManager(_ section: BotsLayout.Section, manager: NativeBot, ceo: NativeBot, team: [NativeBot]) {
        let reporters = team.filter { $0.id != manager.id && $0.id != ceo.id && replying[$0.id] == nil }
        if !reporters.isEmpty {
            post(BotChatMessage(author: "routine", text: "📋 \(section.name) is reporting: " + reporters.map(\.name).joined(separator: ", ") + " to \(manager.name)."), to: manager.id)
        }
        var received: [(name: String, text: String)] = []
        var waiting = reporters.count
        let rollUp = { [weak self] in
            self?.rollUp(section.id, manager: manager, ceo: ceo, received: received, team: team)
        }
        if reporters.isEmpty { rollUp(); return }
        for reporter in reporters {
            let prompt = reportPrompt(reporter, to: manager, role: "You're on the \(section.name) team and \(manager.name) is your manager, so your report goes to \(manager.name)", section: section,
                                      activity: recentWork(of: reporter))
            reply(bot: reporter, in: manager.id, prompt: prompt, session: nil, handsOnWhenStopped: true) { answer in
                if let answer, !answer.isEmpty { received.append((reporter.name, answer)) }
                waiting -= 1
                if waiting == 0 { rollUp() }
            }
        }
    }

    /// The manager reads what came in and reports to the CEO, once it isn't busy with something else.
    private func rollUp(_ sectionID: String, manager: NativeBot, ceo: NativeBot, received: [(name: String, text: String)], team: [NativeBot], attempt: Int = 0) {
        guard let section = category(sectionID) else { return }
        guard replying[manager.id] == nil else {
            guard attempt < 90 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.rollUp(sectionID, manager: manager, ceo: ceo, received: received, team: team, attempt: attempt + 1)
            }
            return
        }
        let reports = received.map { "\($0.name) reports:\n\($0.text)" }.joined(separator: "\n\n")
        let silent = team.filter { bot in bot.id != manager.id && bot.id != ceo.id && !received.contains { $0.name == bot.name } }
        let activity = (reports.isEmpty ? "No reports came in." : reports) +
            (silent.isEmpty ? "" : "\n\nNo report from: " + silent.map(\.name).joined(separator: ", ") + ".") +
            "\n\nYour own recent work:\n" + recentWork(of: manager)
        let prompt = reportPrompt(manager, to: ceo, role: "You manage the \(section.name) team. Roll your team's reports up into one for \(ceo.name), the CEO", section: section, activity: activity)
        post(BotChatMessage(author: "routine", text: "📋 \(manager.name) is reporting to \(ceo.name) for \(section.name)."), to: ceo.id)
        reply(bot: manager, in: ceo.id, prompt: prompt, session: nil) { [weak self] answer in
            guard let self, let answer, !answer.isEmpty else { return }
            self.recordReport(answer, by: manager, in: sectionID)
        }
    }

    /// A finished voice call goes into the primary bot's chat, whole, so the chat knows what was said.
    func recordCall(_ lines: [(isOwner: Bool, text: String)], startedAt: Date) {
        guard let ceo = primary, !lines.isEmpty else { return }
        let minutes = max(1, Int(Date().timeIntervalSince(startedAt) / 60 + 0.5))
        let transcript = lines.map { "**\($0.isOwner ? "Addy" : ceo.name):** \($0.text)" }.joined(separator: "\n\n")
        post(BotChatMessage(author: "routine", text: "\(Self.callMark) Call with \(ceo.name), \(minutes) min\n\n\(transcript)"), to: ceo.id)
    }

    fileprivate static let callMark = "📞"

    /// Reports that landed in the primary bot's chat since it last spoke, for the top of its next turn; other bots
    /// get nothing. Marked as read here, so each is read once.
    fileprivate func takeWaitingReports(for bot: NativeBot) -> String {
        guard bot.primary else { return "" }
        var record = conversation(bot.id)
        let seen = record.seen[bot.id] ?? 0
        let waiting = record.messages.dropFirst(min(seen, record.messages.count)).filter { message in
            !message.text.isEmpty && message.author != "user" && message.author != bot.id && (message.author != "routine" || message.text.hasPrefix(Self.callMark))
        }.suffix(6)
        record.seen[bot.id] = record.messages.count
        conversations[bot.id] = record
        guard !waiting.isEmpty else { return "" }
        let lines = waiting.map { $0.author == "routine" ? $0.text : "\(self.bot($0.author)?.name ?? $0.author): \($0.text)" }.joined(separator: "\n\n")
        return "(What came in since you last spoke, reports from your teams and any voice call with Addy:\n\n\(lines)\n\nUse it if it matters; don't recite it.)\n\n"
    }
}

// MARK: - Theo Link

/// What goes over the link for one chat. Engine sessions stay with their own Mac.
struct LinkChatItem: Codable {
    var messages: [BotChatMessage]
    var clearedAt: Date?
}

struct LinkListItem<T: Codable>: Codable {
    var items: [T]
    var stamps: LinkMerge.Stamps
}

struct LinkLayoutItem: Codable {
    var layout: BotsLayout
    var changedAt: Date?
}

extension BotsStore {
    private var linkStampsFile: URL { folder.appendingPathComponent("link-stamps.json") }

    private struct SavedStamps: Codable {
        var bots = LinkMerge.Stamps()
        var groups = LinkMerge.Stamps()
        var layout: Date?
    }

    fileprivate func loadLinkStamps() {
        let saved = (try? Data(contentsOf: linkStampsFile)).flatMap { try? LinkCoding.decoder.decode(SavedStamps.self, from: $0) } ?? SavedStamps()
        linkBotStamps = saved.bots
        linkGroupStamps = saved.groups
        linkLayoutChangedAt = saved.layout
        linkSavedBots = bots
        linkSavedGroups = groups
        linkSavedLayout = layout
    }

    /// Runs on every save: what the owner changed here wins over older changes on the other Mac.
    fileprivate func noteLinkChanges() {
        guard !isApplyingLink else { return }
        LinkMerge.noteChanges(from: linkSavedBots, to: bots, id: \.id, stamps: &linkBotStamps)
        LinkMerge.noteChanges(from: linkSavedGroups, to: groups, id: \.id, stamps: &linkGroupStamps)
        if LinkCoding.digest(linkSavedLayout) != LinkCoding.digest(layout) { linkLayoutChangedAt = Date() }
        linkSavedBots = bots
        linkSavedGroups = groups
        linkSavedLayout = layout
        writeLinkStamps()
    }

    private func writeLinkStamps() {
        let saved = SavedStamps(bots: linkBotStamps, groups: linkGroupStamps, layout: linkLayoutChangedAt)
        if let data = try? LinkCoding.encoder.encode(saved) { try? data.write(to: linkStampsFile, options: .atomic) }
    }

    /// The chats both Macs should hold: every bot's and group chat's, and Clicky's.
    private var linkChatIDs: Set<String> {
        Set(bots.map(\.id) + groups.filter { $0.headID != nil }.map(\.roomID) + [Self.clickyID])
    }

    private func linkItem(forChat id: String) -> LinkChatItem {
        let record = conversation(id)
        return LinkChatItem(messages: record.messages, clearedAt: record.clearedAt)
    }

    /// One fingerprint per thing the Macs share. Memory's is worked out by the caller, off the main thread.
    var linkDigests: [String: String] {
        var digests = [
            "bots": LinkCoding.digest(LinkListItem(items: bots, stamps: linkBotStamps)),
            "groups": LinkCoding.digest(LinkListItem(items: groups, stamps: linkGroupStamps)),
            "layout": LinkCoding.digest(layout),
            "delegations": LinkCoding.digest(delegations.map(\.id) + delegations.map { $0.finishedAt?.description ?? "" }),
            "runs": LinkCoding.digest(linkRuns),
        ]
        for id in linkChatIDs {
            let item = linkItem(forChat: id)
            digests["chat/" + id] = LinkCoding.digest(item.messages.map(\.id).sorted() + [item.clearedAt?.description ?? ""])
        }
        return digests
    }

    func wantsLinkItem(_ key: String) -> Bool {
        guard key.hasPrefix("chat/") else { return true }
        return linkChatIDs.contains(String(key.dropFirst("chat/".count)))
    }

    func linkPayload(_ key: String) -> Data? {
        let encoder = LinkCoding.encoder
        switch key {
        case "bots": return try? encoder.encode(LinkListItem(items: bots, stamps: linkBotStamps))
        case "groups": return try? encoder.encode(LinkListItem(items: groups, stamps: linkGroupStamps))
        case "layout": return try? encoder.encode(LinkLayoutItem(layout: layout, changedAt: linkLayoutChangedAt))
        case "delegations": return try? encoder.encode(delegations)
        case "runs": return try? encoder.encode(linkRuns)
        case "memory": return try? encoder.encode(memoryStore.everything())
        default:
            guard key.hasPrefix("chat/") else { return nil }
            return try? encoder.encode(linkItem(forChat: String(key.dropFirst("chat/".count))))
        }
    }

    func applyLinkPayload(_ key: String, _ data: Data) {
        let decoder = LinkCoding.decoder
        isApplyingLink = true
        defer { isApplyingLink = false }
        switch key {
        case "bots":
            guard let theirs = try? decoder.decode(LinkListItem<NativeBot>.self, from: data) else { return }
            let merged = LinkMerge.byID(local: bots, localStamps: linkBotStamps, remote: theirs.items, remoteStamps: theirs.stamps, id: \.id)
            linkBotStamps = merged.stamps
            bots = merged.items
            linkSavedBots = bots
            for bot in bots where conversations[bot.id] == nil { conversations[bot.id] = BotConversationRecord() }
            writeBots()
            writeLinkStamps()
        case "groups":
            guard let theirs = try? decoder.decode(LinkListItem<BotGroup>.self, from: data) else { return }
            let merged = LinkMerge.byID(local: groups, localStamps: linkGroupStamps, remote: theirs.items, remoteStamps: theirs.stamps, id: \.id)
            linkGroupStamps = merged.stamps
            groups = merged.items
            linkSavedGroups = groups
            for group in groups where group.headID != nil && conversations[group.roomID] == nil { conversations[group.roomID] = BotConversationRecord() }
            writeGroups()
            writeLinkStamps()
        case "layout":
            guard let theirs = try? decoder.decode(LinkLayoutItem.self, from: data) else { return }
            let mineAt = linkLayoutChangedAt ?? .distantPast
            let theirsAt = theirs.changedAt ?? .distantPast
            let mineCount = layout.sections.reduce(0) { $0 + $1.items.count }
            let theirCount = theirs.layout.sections.reduce(0) { $0 + $1.items.count }
            // Never arranged on either Mac: the fuller sidebar wins, with a stable tie-break so both choose the same.
            let takesTheirs = theirsAt != mineAt ? theirsAt > mineAt
                : theirCount != mineCount ? theirCount > mineCount
                : LinkCoding.digest(theirs.layout) < LinkCoding.digest(layout)
            guard takesTheirs else { return }
            layout = theirs.layout
            linkLayoutChangedAt = theirs.changedAt
            linkSavedLayout = layout
            writeLayout()
            writeLinkStamps()
        case "delegations":
            guard let theirs = try? decoder.decode([ClickyDelegation].self, from: data) else { return }
            delegations = Array(LinkMerge.union(local: delegations, remote: theirs, id: \.id, at: \.startedAt) { first, second in
                (first.finishedAt ?? .distantPast) >= (second.finishedAt ?? .distantPast) ? first : second
            }.suffix(200))
            if let saved = try? LinkCoding.encoder.encode(delegations) { try? saved.write(to: folder.appendingPathComponent("delegations.json"), options: .atomic) }
        case "runs":
            guard let theirs = try? decoder.decode([T3Run].self, from: data) else { return }
            // Each Mac is the only one writing its own runs.
            for run in theirs where run.isRemote {
                if let index = t3Runs.firstIndex(where: { $0.id == run.id }) { t3Runs[index] = run } else { t3Runs.append(run) }
            }
            t3Runs.sort { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.id < $1.id }
            if let saved = try? Self.encoder.encode(t3Runs) { try? saved.write(to: runsFile, options: .atomic) }
        case "memory":
            guard let theirs = try? decoder.decode([ClickyMemoryEntry].self, from: data) else { return }
            memoryStore.merge(theirs)
        default:
            let id = String(key.dropFirst("chat/".count))
            guard key.hasPrefix("chat/"), linkChatIDs.contains(id), let theirs = try? decoder.decode(LinkChatItem.self, from: data) else { return }
            var record = conversation(id)
            let known = Set(record.messages.map(\.id))
            let clearedAt = [record.clearedAt, theirs.clearedAt].compactMap { $0 }.max()
            let merged = LinkMerge.union(local: record.messages, remote: theirs.messages, id: \.id, at: \.at, clearedAt: clearedAt)
            let arrived = merged.filter { !known.contains($0.id) }
            record.messages = merged
            record.clearedAt = clearedAt
            conversations[id] = record
            writeConversation(id)
            for message in arrived where !message.text.isEmpty {
                noteUnread(message, in: id)
                linkUnheard[id, default: []].append(message)
            }
            if let count = linkUnheard[id]?.count, count > 20 { linkUnheard[id]?.removeFirst(count - 20) }
        }
    }

    /// The runs both Macs show, the same way round on both. Older ones stay on their own Mac.
    private var linkRuns: [T3Run] {
        let stamped = t3Runs.map { run -> T3Run in
            var run = run
            if run.origin == nil { run.origin = TheoLink.localName }
            return run
        }
        return Array(stamped.sorted { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.id < $1.id }.suffix(30))
    }

    /// The other Mac asks this one to do something it can't do itself.
    func handleLinkRequest(_ action: String, _ fields: [String: String]) {
        switch action {
        case "run":
            guard let prompt = fields["prompt"], let title = fields["title"], let room = fields["room"] else { return }
            let repo = fields["repo"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            func field(_ key: String) -> String? { fields[key].flatMap { $0.isEmpty ? nil : $0 } }
            submitToT3(prompt: prompt, title: title, repo: repo, room: room, harness: field("harness"), modelChoice: field("model"), effortChoice: field("effort"), alsoRoom: field("alsoRoom"))
        case "followup":
            guard let room = fields["room"], let text = fields["text"] else { return }
            sendToCoder(text, room: room)
        case "stopRun":
            if let id = fields["id"] { stopRun(id) }
        case "clicky":
            guard let text = fields["text"], !text.isEmpty else { return }
            // It's done here, silently. The answer goes back and the Mac that was asked says it.
            var options = CompanionManager.TurnOptions()
            options.cameFromOtherMac = true
            options.speaksResponse = false
            let speaks = fields["speaks"] ?? "yes"
            options.onTurnFinished = { directory, error in
                Task { @MainActor in
                    let said = directory.flatMap { ClaudiaControlInbox.spokenAnswer(inTurn: $0) } ?? ""
                    let answer = error.map { "Clicky couldn't do that: \($0.localizedDescription)" } ?? said
                    if !answer.isEmpty { _ = TheoLink.shared.request("clickyAnswer", ["text": answer, "speaks": speaks]) }
                }
            }
            CompanionManager.current?.sendTranscriptToClaudeWithScreenshot(transcript: text, turnOptions: options)
        case "clickyAnswer":
            guard let text = fields["text"] else { return }
            post(BotChatMessage(author: Self.clickyID, text: text), to: Self.clickyID)
            if fields["speaks"] != "no" { CompanionManager.current?.speakCodeModeLine(text) }
        case "order":
            guard let order = fields["order"], let id = fields["id"] else { return }
            orderClicky(order, ownerWords: fields["ownerWords"].flatMap { $0.isEmpty ? nil : $0 }, cameFromOtherMac: true) { report in
                _ = TheoLink.shared.request("orderReport", ["id": id, "report": report])
            }
        case "orderReport":
            if let id = fields["id"], let report = fields["report"] { TheoLink.shared.orderReported(id, report: report) }
        case "screen":
            guard let task = fields["task"], let room = fields["room"], let bot = fields["bot"].flatMap({ self.bot($0) }) else { return }
            workOnScreen(task, bot: bot, room: room)
        default:
            break
        }
    }

    /// What happened in this chat on the other Mac, for the bot's next turn here: its engine session only knows this Mac.
    fileprivate func linkCatchUp(_ id: String) -> String {
        guard let heard = linkUnheard.removeValue(forKey: id), !heard.isEmpty else { return "" }
        let lines = heard.map { message -> String in
            let who = message.author == "user" ? "Addy" : (bot(message.author)?.name ?? message.author)
            return "\(who): \(message.text.prefix(600))"
        }.joined(separator: "\n")
        return "(This chat also went on from Addy's other Mac:\n\n\(lines)\n\nUse this as context.)\n\n"
    }
}
