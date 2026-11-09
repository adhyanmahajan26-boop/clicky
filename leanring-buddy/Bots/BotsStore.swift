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
    /// Its crew figure, from Make your bot. Nil: the standard look for its job.
    var look: CrewLook?

    var isOn: Bool { enabled ?? true }
    var crewLook: CrewLook { look ?? .standard(id: id, name: name, isPrimary: primary) }
    var authorityLevel: String { authority ?? (primary ? "ceo" : "member") }

    var isProjectHandler: Bool { (category ?? BotImport.defaultCategory(id)) == "project" }

    /// Its memory file. Theo's own folder, never T3 Code's (~/.t3 belongs to T3 Code).
    var memoryPath: String { BotMemory.file(botID: id).path }

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
    /// "dm:<exchange>:<bot>": a private exchange's card (BotDMCard).
    var card: String?
    /// In a private thread: the exchange this message belongs to.
    var exchangeID: String?
    /// Its time to the fraction of a second. `at` only keeps whole seconds once saved or sent, and the order of a chat can't depend on that.
    var exact: Double? = Date().timeIntervalSince1970

    /// When it was written, for putting chats from two Macs in order.
    var sortDate: Date {
        guard let exact, abs(exact - at.timeIntervalSince1970) < 2 else { return at }
        return Date(timeIntervalSince1970: exact)
    }
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
    /// The newest message each bot's engine session on this Mac has seen. What came after it gets told to the bot (it may
    /// have happened on the other Mac). Stays on this Mac, like the sessions.
    var heard: [String: String]?
    /// In a group chat: the answers each bot's engine session wrote itself since it was last shown the chat. Only these are left out of
    /// what it reads next. Anything else under its name (Theo's question, its words from the other Mac, a run's notice) is news to it.
    var ownAnswers: [String: [String]]?
}

@MainActor
final class BotsStore: ObservableObject {
    static let shared = BotsStore()

    @Published private(set) var bots: [NativeBot] = []
    @Published private(set) var conversations: [String: BotConversationRecord] = [:]
    /// Bots with a reply in progress, and the reply text so far ("" while thinking).
    @Published private(set) var replying: [String: String] = [:]
    /// The chat each reply in progress is being written in. A private message or a group chat never shows as typing in the bot's own chat.
    @Published private(set) var replyingIn: [String: String] = [:]
    /// Private exchanges going on right now, by exchange id.
    @Published var liveExchanges: [String: BotDMLive] = [:]
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
    /// How many private messages the bots have sent since the owner last spoke, by the chat the owner spoke in, so they can't go on forever.
    var directMessageBudgets: [String: BotDMBudget] = [:]
    /// Counts the owner's messages per chat, so an exchange belongs to one of them.
    var ownerTurns: [String: Int] = [:]
    /// Exchanges still open since the owner last spoke, by chat, sender and target, so another message back and forth continues the same card.
    var openExchanges: [String: BotDMExchange] = [:]
    /// Chats where the owner pressed Stop on the private messages going on.
    var stoppedExchangeRooms: Set<String> = []
    /// What the other Mac has: its folders, harnesses and screens.
    var peerDevice: DeviceSnapshot?
    /// Chats whose turn runs here while the owner types on the other Mac: where its coding goes, and why.
    var forwardedTurns: [String: ForwardedTurn] = [:]
    /// Bots whose turn is running on the other Mac right now.
    var turnsOnOtherMac: Set<String> = []
    /// The chat each private thread's newest exchange started from, for an answer that comes later.
    var exchangeRooms: [String: (senderID: String, room: String, context: BotDMContext)] = [:]
    /// Team work already passed on, so the same brief doesn't go with every message.
    var passedOnWork: Set<String> = []
    /// Research waiting for the one in progress to end, so one job doesn't kill another.
    var queuedResearch: [() -> Void] = []
    /// How many screen jobs in a row a bot has asked for since the owner last spoke to it.
    var screenTurns: [String: Int] = [:]
    /// Theo is waiting on the head of these group chats, by room.
    private var groupWaiters: [String: (String) -> Void] = [:]
    /// That folder's chats, for the head's next turn, when the owner asked to carry on earlier work.
    private var groupChatNotes: [String: String] = [:]
    /// Which message of the owner's has already started a chat's limits over.
    var ownerMessageMarks = OwnerMessageMark()
    /// The Mac the owner typed on when it isn't this one, by chat: Bots & coding is set to this Mac.
    var ownerMacs: [String: String] = [:]
    /// How many times Stop was pressed, by chat, so what's waiting from before it doesn't carry on after a new message.
    var stopCounts: [String: Int] = [:]
    /// Who speaks next in each group chat with a round going on.
    private var groupRounds: [String: GroupRound] = [:]
    /// Theo Link: when things changed, and while the other Mac's copy is being applied.
    private var linkBotStamps = LinkMerge.Stamps()
    private var linkGroupStamps = LinkMerge.Stamps()
    private var linkLayoutChangedAt: Date?
    private var isApplyingLink = false
    private var linkSavedBots: [NativeBot] = []
    private var linkSavedGroups: [BotGroup] = []
    private var linkRoutineStamps = LinkMerge.Stamps()
    /// Saves while Theo is starting up aren't edits: nothing has been compared yet, and everything would look new.
    private var hasLoadedLinkStamps = false
    private var linkSavedRoutines: [BotRoutine] = []
    private var linkSavedLayout = BotsLayout()
    /// The conversation on screen, which collects no unread count.
    var viewing: String? { didSet { if let viewing { unread[viewing] = nil } } }
    private var routineTimer: Timer?
    private var runningRoutines: Set<String> = []

    static let teamID = "team"

    let folder: URL

    private init() {
        // Unit tests host the app with the owner's real home and preferences: they get a folder of their own, and no migrations.
        let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        folder = isHostingTests
            ? FileManager.default.temporaryDirectory.appendingPathComponent("theo-unit-tests-\(ProcessInfo.processInfo.processIdentifier)/Bots", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Theo/Bots", isDirectory: true)
        if !isHostingTests { Self.archiveForFreshStart(folder) }
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("chats"), withIntermediateDirectories: true)
        if !isHostingTests {
            BotMemory.migrateOnce()
            DeviceRoles.migrateOnce()
        }
        bots = loadBots()
        groups = loadGroups()
        writeGroups()
        for id in groups.filter { $0.headID != nil }.map(\.roomID) + bots.map(\.id) + [Self.clickyID] {
            conversations[id] = loadConversation(id)
        }
        // Private threads between bots: each one is a chat file of its own.
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("chats").path)) ?? [] where file.hasSuffix(".json") {
            if let thread = BotDMThread.thread(fromFileName: String(file.dropLast(".json".count))) { conversations[thread] = loadConversation(thread) }
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
        if !isHostingTests { stampRoutinesOnce() }
        // Which engines can run on this Mac, for the bots' prompts and for the other Mac.
        Task { @MainActor in HarnessCenter.shared.refresh() }
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

    /// A turn elsewhere has ended: nobody here is writing any more.
    func endTurnHere(_ botID: String) {
        replying[botID] = nil
        replyingIn[botID] = nil
    }

    /// Lights a team bot up, or down, for work that doesn't run through a reply of its own.
    func setReplying(_ text: String?, _ botID: String) {
        replying[botID] = text
        replyingIn[botID] = text == nil ? nil : botID
    }

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
        stopGroup(id)
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
        // A random tasteful figure of its own, until someone dresses it.
        bot.look = .shuffled()
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
        // Its private threads go with it.
        for thread in privateThreads(of: id) {
            conversations[thread.id]?.sessions.values.forEach(APIChat.History.forget)
            conversations[thread.id] = nil
            try? FileManager.default.removeItem(at: chatFile(thread.id))
        }
        writeBots()
        writeGroups()
        forget(item: "bot:\(id)")
    }

    func bot(_ id: String) -> NativeBot? { id == Self.clickyID ? clickyBot : bots.first { $0.id == id } }

    func conversation(_ id: String) -> BotConversationRecord { conversations[id] ?? BotConversationRecord() }

    /// Test profile only (CrewTestCommands).
    func setConversationForTest(_ id: String, _ record: BotConversationRecord) {
        guard TheoProfile.isTest else { return }
        conversations[id] = record
    }

    /// Test profile only: a run on a card, with nothing behind it.
    func injectRunForTest(_ run: T3Run) {
        guard TheoProfile.isTest else { return }
        t3Runs.removeAll { $0.id == run.id }
        t3Runs.append(run)
    }

    func save(_ bot: NativeBot) {
        // Clicky's own settings live in Settings › Clicky.
        guard bot.id != Self.clickyID else { return }
        let old = self.bot(bot.id)
        if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot } else { bots.append(bot) }
        writeBots()
        if let old, old.provider != bot.provider { clearEngineSessions(of: bot.id) }
    }

    /// A session belongs to one engine: the new engine starts the conversation fresh (the messages stay).
    private func clearEngineSessions(of botID: String) {
        for id in [botID] + groups.map(\.roomID) + privateThreads(of: botID).map(\.id) {
            var record = conversation(id)
            guard record.sessions.removeValue(forKey: botID) != nil else { continue }
            conversations[id] = record
            writeConversation(id)
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
    func send(_ text: String, command: String? = nil, to botID: String, messageID: String? = nil, writtenAt: Date? = nil) {
        if botID == Self.clickyID { return askClicky(text) }
        if messageID == nil { ownerMacs[botID] = nil }
        if messageID == nil, forwardToBotsMac("botSay", room: botID, target: botID, text: text, command: command, engine: bot(botID)?.provider) { return }
        guard let bot = bot(botID) else { return }
        // It may be answering another bot in private, which doesn't show here. Nothing the owner says gets lost: it shows now and goes in when it's free.
        if replying[botID] != nil {
            let id = messageID ?? UUID().uuidString
            if !conversation(botID).messages.contains(where: { $0.id == id }) { post(ownerMessage(id: id, text: text, writtenAt: writtenAt), to: botID) }
            Task { [weak self] in
                while self?.replying[botID] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
                self?.send(text, command: command, to: botID, messageID: id)
            }
            return
        }
        guard bot.isOn else {
            post(BotChatMessage(author: "user", text: text), to: botID)
            post(BotChatMessage(author: bot.id, text: "_(\(bot.name) is turned off. Turn it on in its settings to chat.)_"), to: botID)
            return
        }
        var record = conversation(botID)
        let ownerMessageID = messageID ?? UUID().uuidString
        if !record.messages.contains(where: { $0.id == ownerMessageID }) {
            record.messages.append(ownerMessage(id: ownerMessageID, text: text, writtenAt: writtenAt))
        }
        conversations[botID] = record
        writeConversation(botID)
        HarnessCenter.shared.refresh(maximumAge: 600)
        if BotsStore.isCodingCommand(command ?? text) {
            // "@code …" goes straight to a coding agent, in any chat: a change for this chat's latest run,
            // or a new run when there's none or the message names a folder.
            runCommand(text, room: botID)
            return
        }
        // "Make a new folder called X" and nothing more: done, with no bot in between.
        if ProjectWords.asksOnlyForFolder(command ?? text), let name = ProjectWords.newFolderName(in: command ?? text) {
            makeProjectFolder(name, room: botID)
            return
        }
        // "Cancel that run": stopped right away, whatever else the message goes on to say. The bot's told, so it doesn't go looking.
        var cancelNote: String?
        if CodingIntent.asksToCancelRun(command ?? text) {
            if let live = t3Runs.last(where: { $0.phase == "running" || $0.phase == "waiting" }) {
                stopRun(live.id)
                cancelNote = "Theo has already stopped \"\(live.title)\" as Addy asked, and it's really stopped. Just confirm it."
            } else {
                cancelNote = "Addy asked to cancel a run, but no coding run is going on right now, so there's nothing to stop. Say so plainly."
            }
        }
        // "Clicky, research X" to the CEO: straight to Clicky, who reports back here.
        if bot.primary, let order = ClickyOrder.parse(command ?? text) {
            orderClicky(order, ownerWords: text)
            return
        }
        if let intent = BotSettingsIntent.parse(command ?? text) {
            answerWithSettings(intent, bot: bot)
            return
        }
        // Carrying on earlier work: the bot gets that folder's chats to choose from, which takes a moment to list.
        if bot.owner == nil, CodingIntent.asksToContinueChat(command ?? text), latestRun(in: botID) != nil || CodingIntent.mentionsCodeWork(command ?? text) {
            replying[botID] = ""
            replyingIn[botID] = botID
            Task { [weak self] in
                let chats = await self?.recentChatsNote(for: command ?? text, room: botID)
                self?.replying[botID] = nil
                self?.replyingIn[botID] = nil
                self?.startOwnTurn(bot, text: text, command: command, ownerMessageID: ownerMessageID, cancelNote: cancelNote, chatsNote: chats)
            }
            return
        }
        startOwnTurn(bot, text: text, command: command, ownerMessageID: ownerMessageID, cancelNote: cancelNote, chatsNote: nil)
    }

    /// A bot's turn in its own chat: everything it needs to know goes on top of the owner's words.
    private func startOwnTurn(_ bot: NativeBot, text: String, command: String?, ownerMessageID: String, cancelNote: String?, chatsNote: String?) {
        let botID = bot.id
        let record = conversation(botID)
        let firstTurn = record.sessions[botID] == nil
        var prompt = firstTurn ? BotPrompts.firstMessage(bot: bot, team: bots, text: text) : text
        if !firstTurn && BotPrompts.asksForSchedule(text) { prompt += "\n\n(\(BotPrompts.routineHowTo))" }
        if !firstTurn && BotsStore.isAboutExistingCode(text) { prompt += "\n\n(\(BotPrompts.codingHowTo))" }
        if CodingHarnessWords.asksToSendToCode(command ?? text) { prompt += "\n\n(\(BotPrompts.codingHowTo))" }
        if let chatsNote { prompt += "\n\n(\(chatsNote))" }
        // The owner tagged a bot: in this chat that only means "bring them in", which this bot does itself.
        let tagged = BotPrompts.mentioned(in: command ?? text, bots: reachable(from: bot))
        if !tagged.isEmpty { prompt += "\n\n(Addy tagged \(tagged.map(\.name).joined(separator: " and ")): message them with a [TELL:] line.)" }
        prompt = takeWaitingReports(for: bot) + ceoTurnNote(for: bot) + catchUp(botID, bot: bot, before: ownerMessageID) + prompt
        if bot.owner == nil { prompt = "(\(BotPrompts.screenHowTo))\n\n" + prompt }
        if let cancelled = cancelNote { prompt = "(\(cancelled))\n\n" + prompt }
        if !bot.primary, !runsStatus.isEmpty { prompt = "(\(runsStatus))\n\n" + prompt }
        if bot.owner == nil, !bot.primary { prompt = "(\(BotPrompts.reachNote(for: bot)))\n\n" + prompt }
        if bot.owner == nil { prompt = BotPrompts.awarenessNote(for: bot, room: botID) + prompt }
        ownerSpoke(in: botID)
        screenTurns[botID] = 0
        reply(bot: bot, in: botID, prompt: prompt, session: record.sessions[botID]) { _ in }
    }

    /// The owner's message. `writtenAt`: when they wrote it on the other Mac, so it holds its place in the chat on both.
    private func ownerMessage(id: String, text: String, writtenAt: Date?) -> BotChatMessage {
        guard let writtenAt else { return BotChatMessage(id: id, author: "user", text: text) }
        return BotChatMessage(id: id, author: "user", text: text, at: writtenAt, exact: writtenAt.timeIntervalSince1970)
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
        sendToCoder(text, room: room, runID: run.id)
    }

    /// Posts to the Project room.
    func sendToTeam(_ text: String) {
        if group(BotGroup.projectID)?.headID != nil { sendToGroup(text, groupID: BotGroup.projectID) }
        else if let primary { send(text, to: primary.id) }
    }

    /// Settings › Devices can put bots on one Mac by hand. Then what's typed on the other goes there: it shows here right away and the
    /// answer comes back through the chat. If that Mac can't be reached the chat says so at once, and offers this Mac when it can. By default a
    /// message is answered on the Mac it was typed on, and this does nothing.
    private func forwardToBotsMac(_ action: String, room: String, target: String, text: String, command: String?, engine: String?) -> Bool {
        let message = BotChatMessage(author: "user", text: text)
        // It keeps its time when it goes over, so it sits in the same place in the chat on both Macs.
        let fields = ["target": target, "text": text, "command": command ?? "", "id": message.id, "at": String(message.sortDate.timeIntervalSince1970), "fromMac": TheoLink.localName]
        let problem = engine.flatMap { EngineReadiness.problem(with: $0) }
        switch DeviceRouting.botTurn(choice: DeviceRoles.choice(.bots), thisMac: DeviceRoles.thisMac, paired: TheoLink.shared.isPaired, otherMacOnline: TheoLink.shared.isConnected, engineHere: problem == nil, engineThere: true) {
        case .runHere, .engineOnOtherMac, .tryHere:
            return false
        case .sendAcross:
            guard TheoLink.shared.request(action, fields) else { return false }
            post(message, to: room)
        case .waitForOtherMac(let canRunHere):
            post(message, to: room)
            waitForOtherMac(action, fields, room: room, label: "your message", canRunHere: canRunHere, problem: problem)
        }
        return true
    }

    /// Something set to the other Mac can't reach it: it waits for that Mac, and the chat says so with a way to run it here instead. Never a silent queue.
    func waitForOtherMac(_ action: String, _ fields: [String: String], room: String, label: String, canRunHere: Bool, problem: String?) {
        let other = TheoLink.shortName(TheoLink.shared.peerName ?? TheoLink.shared.knownPeerName ?? "other Mac")
        let id = TheoLink.shared.queueForOtherMac(action, fields, room: room, label: label, canRunHere: canRunHere)
        post(BotChatMessage(author: Self.noteAuthor, text: DeviceRouting.unreachableLine(otherMac: other, thisMac: TheoLink.shortName(TheoLink.localName), engineProblem: problem), card: BotWaitingCard.card(id: id)), to: room)
    }

    /// "Run it here instead", from the card of something waiting for the other Mac.
    func runWaitingHere(_ id: String) {
        guard let waiting = TheoLink.shared.takeWaiting(id) else { return }
        func field(_ key: String) -> String? { waiting.fields[key].flatMap { $0.isEmpty ? nil : $0 } }
        if waiting.isStale {
            if let room = waiting.room, let label = waiting.label {
                post(BotChatMessage(author: Self.noteAuthor, text: "\(label) waited over a day, so it won't go now. Send it again if you still want it."), to: room)
            }
            return
        }
        switch waiting.action {
        case "botSay":
            if let target = field("target"), let text = field("text") {
                ownerMacs[target] = nil
                send(text, command: field("command"), to: target, messageID: field("id"))
            }
        case "groupSay":
            if let target = field("target"), let text = field("text") {
                if let room = group(target)?.roomID { ownerMacs[room] = nil }
                sendToGroup(text, command: field("command"), groupID: target, messageID: field("id"))
            }
        case "run":
            guard let prompt = field("prompt"), let title = field("title"), let room = field("room") else { return }
            let continued = field("chatID").map { HarnessChatChoice(idOrTitle: $0, title: field("chatTitle")) }
            submitToT3(prompt: prompt, title: title, repo: field("repo").map { URL(fileURLWithPath: $0, isDirectory: true) }, room: room, harness: field("harness"), modelChoice: field("model"), effortChoice: field("effort"),
                       alsoRoom: field("alsoRoom"), newFolder: field("newFolder"), macName: TheoLink.localName, continuing: continued)
        default:
            break
        }
    }

    /// Posts to a group chat. The head reads it first, or the bots tagged when someone is; then they take turns (`startRound`).
    func sendToGroup(_ text: String, command: String? = nil, groupID: String, messageID: String? = nil, writtenAt: Date? = nil) {
        guard let group = group(groupID), let head = head(of: group) else { return }
        let room = group.roomID
        if messageID == nil { ownerMacs[room] = nil }
        if messageID == nil, forwardToBotsMac("groupSay", room: room, target: groupID, text: text, command: command, engine: head.provider) { return }
        var record = conversation(room)
        let ownerMessageID = messageID ?? UUID().uuidString
        if !record.messages.contains(where: { $0.id == ownerMessageID }) {
            record.messages.append(ownerMessage(id: ownerMessageID, text: text, writtenAt: writtenAt))
        }
        conversations[room] = record
        writeConversation(room)
        HarnessCenter.shared.refresh(maximumAge: 600)
        if BotsStore.isCodingCommand(command ?? text) {
            runCommand(text, room: room)
            return
        }
        if ProjectWords.asksOnlyForFolder(command ?? text), let name = ProjectWords.newFolderName(in: command ?? text) {
            makeProjectFolder(name, room: room)
            return
        }
        if CodingIntent.asksToCancelRun(command ?? text), let live = t3Runs.last(where: { $0.phase == "running" || $0.phase == "waiting" }) { stopRun(live.id) }
        ownerSpoke(in: room)
        let tagged = BotMentions.ordered(in: text, bots: members(of: group).map { ($0.id, $0.name) })
        var note: String?
        if groupBriefs[room] != nil {
            // More from the owner in the middle of a discussion: the head takes it in and plans again.
            let earlierWords = groupBriefs[room]?.ownerWords ?? ""
            groupBriefs[room]?.stage = .plan
            groupBriefs[room]?.ownerWords = [text, earlierWords].joined(separator: "\n")
            note = BotPrompts.planNote(hasOthers: !otherMembers(of: group).isEmpty)
        } else if tagged.isEmpty, CodingIntent.wantsDiscussion(command ?? text) {
            groupBriefs[room] = groupRunBrief(ownerWords: text, message: text, reportsTo: nil)
            note = BotPrompts.planNote(hasOthers: !otherMembers(of: group).isEmpty)
        }
        let first = groupBriefs[room] != nil ? [head.id] : (tagged.isEmpty ? [head.id] : tagged)
        startGroupTurns(in: group, first: first, note: note, words: command ?? text)
    }

    /// Carrying on earlier work: the head gets that folder's chats to choose from, as a bot in its own chat does, which takes a moment to list.
    private func startGroupTurns(in group: BotGroup, first: [String], note: String?, words: String) {
        let room = group.roomID
        guard CodingIntent.asksToContinueChat(words), latestRun(in: room) != nil || CodingIntent.mentionsCodeWork(words) else {
            startRound(in: group, first: first, openingNote: note)
            return
        }
        Task { [weak self] in
            self?.groupChatNotes[room] = await self?.recentChatsNote(for: words, room: room)
            self?.startRound(in: group, first: first, openingNote: note)
        }
    }

    /// Whoever's waiting on this group chat hears it won't answer: a waiting turn would otherwise wait for good.
    private func endGroupWaits(_ room: String, saying line: String) {
        groupWaiters.removeValue(forKey: room)?(line)
        groupBriefs.removeValue(forKey: room)?.reportsTo?(line)
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

    /// Which folder a run goes in, from the owner's words first and then what a bot wrote when they asked about a project.
    /// `macName`: the Mac the run will go on (this one by default). A folder only counts if it's on that Mac.
    func projectChoice(ownerWords: String?, answer: String?, macName: String? = nil) -> (repo: URL?, newFolder: String?) {
        let owner = ownerWords ?? ""
        let isHere = macName == nil || macName == TheoLink.localName
        let known = isHere ? BotsT3.projectNames() : (peerDevice?.projects.map(\.name) ?? [])
        let projectsRoot = isHere ? BotsT3.projectsFolder : (peerDevice.map { URL(fileURLWithPath: $0.projectsFolder, isDirectory: true) } ?? BotsT3.projectsFolder)
        func project(_ name: String) -> URL { projectsRoot.appendingPathComponent(name, isDirectory: true) }
        // Their newest words first: a folder made a moment ago doesn't outrank the project they've just named.
        for said in owner.components(separatedBy: "\n") {
            // A path they typed is checked on the Mac that has it.
            if let path = BotsT3.targetRepo(answer: "", pitch: said, mustExist: isHere) { return (path, nil) }
            if let name = ProjectWords.namedProject(in: said, among: known) { return (project(name), nil) }
            if let name = ProjectWords.newFolderName(in: said) {
                // Already made: "build it in there", not another one beside it.
                return known.contains(BotsT3.slug(name)) ? (project(BotsT3.slug(name)), nil) : (nil, name)
            }
        }
        // The owner spoke of a folder or project but in words only a bot could match, like a Hindi spelling.
        guard let answer, CodingIntent.normalized(owner).range(of: #"(?i)\b(folder|project|repo)\b"#, options: .regularExpression) != nil else { return (nil, nil) }
        if let line = ProjectWords.labeled("Repo", in: answer) {
            let name = URL(fileURLWithPath: (line as NSString).expandingTildeInPath).lastPathComponent
            if known.contains(name) { return (project(name), nil) }
        }
        if let name = ProjectWords.labeled("New folder", in: answer) { return (nil, name) }
        return (nil, nil)
    }

    /// The project folders this chat's coding goes to: on this Mac, or the other when this turn runs here for it.
    var knownProjects: [String] { BotsT3.projectNames() }

    /// For a bot's turn: which folders there are and how to choose one.
    var projectsNote: String {
        let names = knownProjects.prefix(40).joined(separator: ", ")
        return "Addy's project folders in \(BotsT3.projectsWords) on this Mac: \(names). If they name one, however it's spelled, write \"Repo: \(BotsT3.projectsWords)/<that exact name>\" next to the prompt, and the run works in it. If they ask for a new folder with a name, write \"New folder: <name>\". Otherwise a new folder is made from the project's name."
    }

    /// Makes a folder the owner asked for, as a project of its own, on the Mac they typed it on.
    func makeProjectFolder(_ name: String, room: String) {
        Task { [weak self] in
            guard let self, let speaker = self.speaker(for: room) else { return }
            switch await BotsT3.makeProject(named: name) {
            case .made(let folder):
                self.post(BotChatMessage(author: speaker.id, text: "Made `\(BotsT3.projectsWords)/\(folder.lastPathComponent)` on this \(TheoLink.shortName(TheoLink.localName)). Tell me what to build in it."), to: room)
            case .alreadyThere(let folder):
                self.post(BotChatMessage(author: speaker.id, text: "You already have that folder on this \(TheoLink.shortName(TheoLink.localName)): `\(BotsT3.projectsWords)/\(folder.lastPathComponent)`. Tell me what to change in it."), to: room)
            case .failed(let problem):
                self.post(BotChatMessage(author: speaker.id, text: "Couldn't make that folder: \(problem)"), to: room)
            }
        }
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
    /// `rootRoom`: the chat the owner spoke in. Nil: Theo's own.
    func sendToGroup(fromCEO text: String, ceo: NativeBot, groupID: String, ownerWords: String?, rootRoom: String? = nil, then: @escaping (String) -> Void) {
        guard let group = self.group(groupID), let head = head(of: group) else {
            then("\(self.group(groupID)?.name ?? "That group chat") has nobody to answer.")
            return
        }
        let room = group.roomID
        post(BotChatMessage(author: ceo.id, text: text), to: room)
        // A new message of the owner's starts the group's limits over, once. Theo asking again on the same message doesn't.
        let asker = rootRoom ?? ceo.id
        if ownerMessageMarks.isNew(room: room, message: "\(asker)#\(ownerTurns[asker] ?? 0)") { ownerSpoke(in: room) }
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
            groupWaiters.removeValue(forKey: room)?("\(group.name) was asked something else before it answered this.")
            groupWaiters[room] = then
        }
        startGroupTurns(in: group, first: [head.id], note: note, words: ownerWords ?? text)
    }

    /// The discussion is over: its outcome goes to Theo's chat, and a final prompt the owner asked for starts its run.
    private func finishBrief(_ brief: GroupRunBrief, group: BotGroup, head: NativeBot, answer: String, hasFailed: Bool) {
        guard let ceo = primary else { return }
        let prompt = hasFailed ? nil : BotsT3.promptBlock(in: answer)
        let owner = brief.ownerWords ?? ""
        // The owner's own last message decides, not an older one still in the window: `owner` holds what they said to the group, newest first.
        let room = brief.reportsTo == nil ? group.roomID : ceo.id
        let namedMac = CodingDeviceWords.named(in: owner) ?? ProjectWords.labeled("Mac", in: answer)
        var mac = runMac(named: namedMac, room: room)
        var folder = projectChoice(ownerWords: owner, answer: answer, macName: mac)
        let continued = ProjectWords.chatToContinue(in: answer).map { HarnessChatChoice(idOrTitle: $0) }
        if continued != nil, folder.repo == nil {
            let place = continuedPlace(answer: answer, room: room, namedMac: namedMac, mac: mac)
            folder = (place.repo, nil)
            mac = place.mac
        }
        let mayStart = prompt != nil && BotsStore.ownerAskedToBuild(owner) && (folder.repo != nil || folder.newFolder != nil || !BotsStore.isAboutExistingCode(owner))
        // This message of the owner's has its run now, so a prompt in Theo's words after hearing back doesn't start a second one.
        if mayStart, let pitch = conversation(room).messages.last(where: { $0.author == "user" }) { submittedPitches.insert(pitch.id) }
        // The owner talking to the group reads its outcome right there, so it isn't copied to Theo's chat. Theo asking gets the answer back.
        brief.reportsTo?(answer)
        guard mayStart, let prompt else { return }
        let title = BotsT3.projectTitle(in: answer, prompt: prompt)
        // The run shows where it was asked for, and Theo hears how it went.
        let alsoRoom = brief.reportsTo == nil ? ceo.id : group.roomID
        submitToT3(prompt: prompt, title: title, repo: folder.repo, room: room, harness: brief.harness, modelChoice: brief.model, effortChoice: brief.effort, alsoRoom: alsoRoom, newFolder: folder.newFolder, macName: mac, continuing: continued) { [weak self] started, problem in
            guard let self else { return }
            if brief.reportsTo != nil {
                let line = started ? "Started **\(title)**. You can follow it in \(ceo.name)'s chat." : "**\(title)** didn't start: \(problem ?? "no reason given")."
                self.post(BotChatMessage(author: head.id, text: line), to: group.roomID)
            }
            self.onCEOReport?(started ? "\(title) has started coding." : "\(title) didn't start: \(problem ?? "no reason given").")
        }
    }

    private func groupAnswered(_ room: String, answer: String) {
        groupWaiters.removeValue(forKey: room)?(answer)
    }

    // MARK: Group rounds

    /// One group chat's round: who speaks next, and what the speakers are told. Members answer one at a time and each reads everything
    /// said so far; then the head writes one wrap-up and it stops.
    private struct GroupRound {
        var id = UUID()
        var groupID: String
        var plan: GroupTurnPlan
        var openingNote: String?
        /// The owner spoke again: once the bot writing now has finished, these go first, in a new round.
        var nextFirst: [String]?
        var nextNote: String?
    }

    /// A short beat between turns, so one message lands before the next bot starts writing.
    private static let groupTurnBeatNanoseconds: UInt64 = 1_000_000_000
    /// A member busy elsewhere for this long sits the round out. The head is waited for.
    private static let memberWaitSeconds: TimeInterval = 180

    /// Starts a round in a group chat. One already going stops after whoever's writing now, and this one takes over.
    private func startRound(in group: BotGroup, first: [String], openingNote: String?) {
        let room = group.roomID
        if groupRounds[room] != nil {
            groupRounds[room]?.plan.finish()
            groupRounds[room]?.nextFirst = first
            groupRounds[room]?.nextNote = openingNote
            return
        }
        guard let headID = group.headID else { return }
        stoppedExchangeRooms.remove(room)
        var plan = GroupTurnPlan(headID: headID, first: first)
        let step = plan.start()
        let round = GroupRound(groupID: group.id, plan: plan, openingNote: openingNote)
        groupRounds[room] = round
        take(step, room: room, roundID: round.id)
    }

    /// The next step of a round. Everything that decides who speaks is `GroupTurnPlan`; this only carries it out.
    private func take(_ step: GroupTurnPlan.Step, room: String, roundID: UUID) {
        guard let round = groupRounds[room], round.id == roundID else { return }
        guard let group = group(round.groupID) else {
            // The group chat was deleted while they were talking.
            groupRounds[room] = nil
            endGroupWaits(room, saying: "That group chat was deleted before it answered.")
            return
        }
        // Decided before the owner spoke again, or finished since: nobody takes this turn, and the head reads the new message first.
        guard case .speak(let botID, let isWrapUp) = step, !round.plan.isFinished else {
            let next = round.nextFirst
            let nextNote = round.nextNote
            groupRounds[room] = nil
            if let next {
                startRound(in: group, first: next, openingNote: nextNote)
            } else if let brief = groupBriefs.removeValue(forKey: room), let head = head(of: group) {
                // It ended without the head's outcome, so nothing starts, and whoever's waiting hears so.
                finishBrief(brief, group: group, head: head, answer: "\(group.name) didn't finish talking it through, so nothing has started.", hasFailed: true)
            }
            return
        }
        guard let speaker = bot(botID), speaker.isOn else {
            // Off or gone: it can't take its turn, so the next one does, and the chat says why.
            post(BotChatMessage(author: Self.noteAuthor, text: "\(bot(botID)?.name ?? "That bot") is turned off, so it didn't answer."), to: room)
            turnEnded(by: botID, group: group, answer: nil, roundID: roundID, canHandOut: false)
            return
        }
        Task { [weak self] in
            // Busy in another chat or a private message: its turn waits, so two never write here at once.
            let isHead = botID == group.headID
            let deadline = Date().addingTimeInterval(isHead ? BotRunner.turnLimitSeconds + 60 : Self.memberWaitSeconds)
            while self?.replying[botID] != nil, Date() < deadline { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard let self, let current = self.groupRounds[room], current.id == roundID else { return }
            // The owner spoke while it waited.
            if current.plan.isFinished {
                self.take(.finished, room: room, roundID: roundID)
                return
            }
            if self.replying[botID] != nil {
                self.post(BotChatMessage(author: Self.noteAuthor, text: BotProtocol.busyMemberLine(name: speaker.name)), to: room)
                self.turnEnded(by: botID, group: group, answer: nil, roundID: roundID, canHandOut: false)
                return
            }
            self.groupTurn(speaker, group: group, isWrapUp: isWrapUp, roundID: roundID)
        }
    }

    /// One bot's turn in a round.
    private func groupTurn(_ speaker: NativeBot, group: BotGroup, isWrapUp: Bool, roundID: UUID) {
        let room = group.roomID
        let team = members(of: group)
        let head = head(of: group)
        let isHead = speaker.id == group.headID
        let brief = groupBriefs[room]
        let record = conversation(room)
        let newMessages = BotPrompts.transcriptMessages(in: record, for: speaker)
        // What this turn is. A build discussion has its own steps; otherwise the head opens, members answer and the head wraps up.
        var turnNote: String
        if let brief {
            switch brief.stage {
            case .plan where isHead:
                turnNote = groupRounds[room]?.openingNote ?? BotPrompts.planNote(hasOthers: !otherMembers(of: group).isEmpty)
            case .merge where isHead:
                turnNote = BotPrompts.mergeNote
            default:
                turnNote = isHead ? BotPrompts.mergeNote : BotPrompts.critiqueNote + " " + BotProtocol.memberTurnNote(name: speaker.name, headName: head?.name ?? "the head")
            }
            turnNote += " (\(projectsNote))"
        } else if isWrapUp {
            turnNote = BotProtocol.wrapUpNote(owner: BotPrompts.ownerName)
        } else if isHead {
            turnNote = BotProtocol.headOpensNote(owner: BotPrompts.ownerName)
        } else {
            turnNote = BotProtocol.memberTurnNote(name: speaker.name, headName: head?.name ?? "the head")
        }
        if isHead, let chats = groupChatNotes.removeValue(forKey: room) { turnNote += "\n\n" + chats }
        var prompt = BotPrompts.teamMessage(bot: speaker, team: team, group: group, firstTime: record.sessions[speaker.id] == nil, newMessages: newMessages, turnNote: turnNote)
        if !runsStatus.isEmpty { prompt = "(\(runsStatus))\n\n" + prompt }
        if speaker.owner == nil, !speaker.primary { prompt = "(\(BotPrompts.reachNote(for: speaker)))\n\n" + prompt }
        if speaker.owner == nil { prompt = BotPrompts.awarenessNote(for: speaker, room: room) + prompt }
        var updated = record
        updated.seen[speaker.id] = record.messages.count
        updated.ownAnswers?[speaker.id] = nil
        conversations[room] = updated
        reply(bot: speaker, in: room, prompt: prompt, session: record.sessions[speaker.id], handsOnWhenStopped: true) { [weak self] answer in
            guard let self else { return }
            self.turnEnded(by: speaker.id, group: group, answer: answer, roundID: roundID, canHandOut: !isWrapUp)
        }
    }

    /// A turn is over, spoken or skipped. In a build discussion the steps decide who's next. Otherwise anyone can hand something on with @Name, except the wrap-up, which ends it.
    private func turnEnded(by botID: String, group: BotGroup, answer: String?, roundID: UUID, canHandOut: Bool) {
        if groupBriefs[group.roomID] != nil {
            advanceDiscussion(speakerID: botID, group: group, answer: answer, roundID: roundID)
        } else {
            advance(from: botID, answer: answer, room: group.roomID, roundID: roundID, canHandOut: canHandOut)
        }
    }

    /// A normal round: the plan says who's next, after a short beat.
    private func advance(from botID: String, answer: String?, room: String, roundID: UUID, canHandOut: Bool) {
        guard var round = groupRounds[room], round.id == roundID, let group = group(round.groupID) else { return }
        let others = otherMembers(of: group).map(\.id)
        // The head handing out turns often names members in words ("Backend first, then Frontend") and tags only the first, so
        // its names count with or without the @. A member's only count with it, so mentioning someone in passing hands nothing on.
        let team = members(of: group).map { ($0.id, $0.name) }
        let mentions = answer.map { botID == group.headID ? BotMentions.named(in: $0, bots: team) : BotMentions.ordered(in: $0, bots: team) } ?? []
        // A member that failed or timed out doesn't stall the room: the plan just moves on.
        let step = round.plan.turnEnded(by: botID, mentions: mentions, canHandOut: canHandOut, others: others)
        groupRounds[room] = round
        // That was the last word of this round: Theo may be waiting on it.
        if case .finished = step, round.nextFirst == nil {
            groupAnswered(room, answer: answer ?? "\(self.bot(botID)?.name ?? "The head") stopped before answering.")
        }
        Task { [weak self] in
            if case .speak = step { try? await Task.sleep(nanoseconds: Self.groupTurnBeatNanoseconds) }
            self?.take(step, room: room, roundID: roundID)
        }
    }

    /// A build discussion: the head plans, the others critique one at a time, the head merges, and the prompt it writes starts the run.
    private func advanceDiscussion(speakerID: String, group: BotGroup, answer: String?, roundID: UUID) {
        let room = group.roomID
        guard var round = groupRounds[room], round.id == roundID, var brief = groupBriefs[room] else { return }
        guard let head = head(of: group) else {
            // The group lost its head in the middle of it.
            groupRounds[room] = nil
            endGroupWaits(room, saying: "\(group.name) has no head any more, so nothing has started.")
            post(BotChatMessage(author: Self.noteAuthor, text: "\(group.name) has no head any more, so the discussion stopped and nothing started."), to: room)
            return
        }
        let others = otherMembers(of: group)
        let isHead = speakerID == group.headID
        // The owner spoke again: the head plans again in the round that's queued. This one only ends.
        if round.nextFirst != nil {
            _ = round.plan.turnEnded(by: speakerID, mentions: [], canHandOut: false, others: [])
            groupRounds[room] = round
            take(.finished, room: room, roundID: roundID)
            return
        }
        if isHead, answer == nil {
            groupBriefs[room] = nil
            finishBrief(brief, group: group, head: head, answer: "\(head.name) stopped before answering.", hasFailed: true)
            round.plan.finish()
            groupRounds[room] = round
            take(.finished, room: room, roundID: roundID)
            return
        }
        if isHead, brief.stage == .merge || others.isEmpty {
            groupBriefs[room] = nil
            finishBrief(brief, group: group, head: head, answer: answer ?? "", hasFailed: false)
            round.plan.finish()
            groupRounds[room] = round
            take(.finished, room: room, roundID: roundID)
            return
        }
        // The head's plan brings in everyone; a critique brings in nobody. The last one, spoken or skipped, sends it back to the head to merge.
        let step = round.plan.turnEnded(by: speakerID, mentions: isHead ? others.map(\.id) : [], canHandOut: isHead, others: others.map(\.id))
        brief.stage = round.plan.isWrappingUp ? .merge : .critique
        groupBriefs[room] = brief
        groupRounds[room] = round
        Task { [weak self] in
            if case .speak = step { try? await Task.sleep(nanoseconds: Self.groupTurnBeatNanoseconds) }
            self?.take(step, room: room, roundID: roundID)
        }
    }

    /// A group chat is talking a build through, so a prompt written there or by Theo doesn't start a second run.
    func isDiscussing(_ room: String) -> Bool { groupBriefs[room] != nil || (room == primary?.id && isTeamDiscussing) }

    /// Bots whose reply you stopped; their turn ends without handing on.
    var stopped: Set<String> = []

    /// Stops a bot's reply in progress (and, in the Project room, the hand-offs it would set off).
    func stop(_ botID: String) {
        guard replying[botID] != nil else { return }
        stopped.insert(botID)
        BotProcesses.shared.stop(botID)
        // Its turn may be on the other Mac.
        if turnsOnOtherMac.contains(botID) { _ = TheoLink.shared.request("botTurnStop", ["bot": botID]) }
    }

    /// Stops all of a group chat at once: whoever's writing, whoever's waiting their turn, and the discussion.
    func stopGroup(_ groupID: String) {
        guard let group = group(groupID) else { return }
        let room = group.roomID
        groupRounds[room] = nil
        endGroupWaits(room, saying: "\(group.name) was stopped before it answered.")
        stopPrivateMessages(in: room)
        for bot in members(of: group) where replying[bot.id] != nil && replyingIn[bot.id] == room { stop(bot.id) }
    }

    /// A group chat with a round going on, or a chat with private messages going on: what Stop stops.
    func isBusy(_ conversationID: String) -> Bool {
        groupRounds[conversationID] != nil || liveExchanges.values.contains { $0.room == conversationID }
    }

    /// `handsOnWhenStopped`: a stopped turn still calls `then`, for a roll-up that is waiting on it.
    /// `fromOwner`: false when Clicky's team set this off: its answer can't start a coding run or a routine by itself.
    /// `privately`: this turn answers a private message: what it's part of, and who asked.
    /// `then`: once the turn is over. If it messaged other bots, that's after they've answered and it has carried on, with its last words.
    func reply(bot: NativeBot, in conversationID: String, prompt: String, session: String?, handsOnWhenStopped: Bool = false, fromOwner: Bool = true, mayUseScreen: Bool = false,
               privately: BotDMTurn? = nil, then: @escaping (String?) -> Void) {
        stopped.remove(bot.id)
        // A new turn, not a carry-on from before: an earlier Stop in this chat isn't about it.
        if privately == nil { stoppedExchangeRooms.remove(conversationID) }
        replying[bot.id] = ""
        replyingIn[bot.id] = conversationID
        // Its engine can't run on this Mac and the other one can: this one turn goes across, and the chat says so. Never silently.
        if let across = turnGoesAcross(bot) {
            runTurnOnOtherMac(bot, across: across, in: conversationID, prompt: prompt, privately: privately, fromOwner: fromOwner, then: then)
            return
        }
        Task { [weak self] in
            var answer: String?
            var newSession = session
            do {
                let team = self?.bots ?? []
                let onText: @MainActor (String) -> Void = { text in
                    let shown = bot.owner == nil ? ClickyOrder.withoutTags(streaming: text) : text
                    self?.replying[bot.id] = BotTagWords.withoutTags(streaming: BotScreenOrder.withoutTags(streaming: shown))
                }
                let result: (text: String, session: String?)
                do {
                    result = try await BotRunner.run(bot: bot, prompt: prompt, session: session, team: team, onText: onText)
                } catch BotRunnerError.lostSession where session != nil {
                    // The engine has lost this chat (it's on the other Mac, or was cleaned up). It starts again with what the chat says so far.
                    let fresh = self?.startOverPrompt(bot: bot, in: conversationID, prompt: prompt) ?? prompt
                    result = try await BotRunner.run(bot: bot, prompt: fresh, session: nil, team: team, onText: onText)
                }
                answer = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                newSession = result.session
            } catch {
                answer = nil
                if self?.stopped.contains(bot.id) != true {
                    self?.post(BotChatMessage(author: bot.id, text: "Couldn't reply: \(error.localizedDescription)", exchangeID: privately?.exchangeID), to: conversationID)
                }
            }
            guard let self else { return }
            // Orders in the reply don't show in the chat. The CEO's to Clicky, a group chat or a harness turn into their own cards;
            // anyone's [TELL:] to another bot becomes a private exchange.
            var orders: [String] = []
            var directMessages: [(name: String, message: String)] = []
            if bot.owner == nil, let said = answer {
                let taken = ClickyOrder.extract(from: said)
                answer = taken.text
                for order in taken.orders {
                    guard let tell = ClickyOrder.tellTarget(in: order) else {
                        if bot.primary { orders.append(order) }
                        continue
                    }
                    // A group chat is asked along with the bots, so everything one turn asks comes back to one carry-on.
                    if bot.primary, self.isOrderRatherThanMessage(tell.name), self.groupTarget(named: tell.name) == nil { orders.append(order) } else { directMessages.append(tell) }
                }
                // Their answer goes back by itself, so a line back to whoever asked is just more of the answer: no messaging each other in circles.
                if let partner = privately?.askerID.flatMap({ self.bot($0) }) {
                    let toPartner = directMessages.filter { BotsStore.searchName($0.name) == BotsStore.searchName(partner.name) }
                    directMessages.removeAll { BotsStore.searchName($0.name) == BotsStore.searchName(partner.name) }
                    answer = ([answer ?? ""] + toPartner.map(\.message)).filter { !$0.isEmpty }.joined(separator: "\n\n")
                }
                // Told to stop messaging for now, after its last messages reached nobody.
                if privately?.mayMessage == false { directMessages = [] }
            }
            // A turn the owner set off can ask for the work screen, and so can a bot Theo asked on the owner's behalf. One set
            // off by a page or another bot's job can't, and says so: the tag never just sits in the chat looking like it ran.
            var screenOrders: [String] = []
            var researchOrders: [String] = []
            var screenGifts: [(bot: String, screen: String)] = []
            if bot.owner == nil, let said = answer {
                let taken = BotScreenOrder.extract(from: said)
                let research = BotResearchOrder.extract(from: taken.text)
                let gifts = BotScreenGift.extract(from: research.text)
                answer = gifts.text
                if fromOwner || mayUseScreen {
                    screenOrders = taken.orders
                    researchOrders = research.questions
                } else if !taken.orders.isEmpty || !research.questions.isEmpty {
                    answer = gifts.text + "\n\n_(I can't use the screen or research on this turn, because Addy didn't ask for it. Nothing was done.)_"
                }
                if fromOwner { screenGifts = gifts.gifts }
            }
            let streamed = self.replying[bot.id]
            self.replying[bot.id] = nil
            self.replyingIn[bot.id] = nil
            if self.stopped.remove(bot.id) != nil {
                // Keep what it had said so far, marked as stopped, and hand nothing on.
                let partial = (answer ?? streamed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.post(BotChatMessage(author: bot.id, text: partial.isEmpty ? "_(Stopped.)_" : partial + "\n\n_(Stopped.)_", exchangeID: privately?.exchangeID), to: conversationID)
                if handsOnWhenStopped { then(nil) }
                return
            }
            var record = self.conversation(conversationID)
            if let newSession { record.sessions[bot.id] = newSession }
            if let answer, !answer.isEmpty {
                let message = BotChatMessage(author: bot.id, text: BotPrompts.withoutNameHeading(answer, bot: bot), exchangeID: privately?.exchangeID)
                self.noteUnread(message, in: conversationID)
                record.messages.append(message)
                if self.isRoom(conversationID) { record.ownAnswers = (record.ownAnswers ?? [:]).merging([bot.id: (record.ownAnswers?[bot.id] ?? []) + [message.id]]) { _, new in new } }
            } else if answer != nil && orders.isEmpty && screenOrders.isEmpty && directMessages.isEmpty {
                record.messages.append(BotChatMessage(author: bot.id, text: "(No answer this time. Send it again, or try another model.)", exchangeID: privately?.exchangeID))
            }
            // Its engine session has now seen everything in this chat, on this Mac.
            var heard = record.heard ?? [:]
            heard[bot.id] = record.messages.last?.id
            record.heard = heard
            self.conversations[conversationID] = record
            self.writeConversation(conversationID)
            let ownerSaid = fromOwner ? self.recentOwnerWords(in: conversationID) : nil
            for order in orders { self.carryOutOrder(order, ownerWords: ClickyOrder.tellTarget(in: order) == nil ? nil : ownerSaid) }
            for order in screenOrders { self.workOnScreen(order, bot: bot, room: conversationID) }
            for question in researchOrders { self.researchForBot(question, bot: bot, room: conversationID) }
            for gift in screenGifts { self.proposeScreen(gift, from: bot, room: conversationID) }
            // Any bot in its own chat can start a run, and a group chat's head in that chat.
            if fromOwner, let answer, self.group(forRoom: conversationID)?.headID == bot.id || conversationID == bot.id {
                self.submitIfFinal(answer, room: conversationID)
            }
            if fromOwner, let answer, let request = Self.routineRequest(in: answer) {
                let target = self.group(forRoom: conversationID).map { "group:\($0.id)" } ?? bot.id
                self.addRoutineFromChat(request, target: target, conversationID: conversationID, author: bot.id)
            }
            // The answers come back before this turn counts as over, so a group's next bot doesn't start writing on top of it.
            if !directMessages.isEmpty {
                let context = privately?.context ?? BotDMContext(rootRoom: conversationID, ownerWords: ownerSaid, fromOwner: fromOwner)
                self.runPrivateMessages(directMessages, from: bot, room: conversationID, context: context, askerID: privately?.askerID, exchangeID: privately?.exchangeID) { final in
                    // Both what it wrote first and what it said after hearing back: a group's @Names can be in either.
                    let words = [answer, final].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    then(words.isEmpty ? nil : words)
                }
                return
            }
            then(answer)
        }
    }

    /// What a bot is told when its engine lost the chat: the same prompt, with the chat so far.
    private func startOverPrompt(bot: NativeBot, in conversationID: String, prompt: String) -> String {
        let lines = conversation(conversationID).messages.filter { !$0.text.isEmpty && $0.author != Self.noteAuthor }.suffix(8).map { message -> String in
            "\(message.author == "user" ? BotPrompts.ownerName : (self.bot(message.author)?.name ?? message.author)): \(message.text.prefix(1500))"
        }
        let history = lines.isEmpty ? "" : "(Your earlier session of this chat is gone, so here's the chat so far:\n\n\(lines.joined(separator: "\n"))\n\nUse it as context.)\n\n"
        return BotPrompts.firstMessage(bot: bot, team: bots, text: history + prompt)
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
        guard let prompt = BotsT3.promptBlock(in: answer), !isDiscussing(room) else { return }
        _ = startFinalPrompt(prompt, answer: answer, pitch: pitch, room: room)
    }

    /// A final prompt in another bot's private answer, for work the owner just asked for. Its run shows in the chat the owner asked in, once per message of theirs.
    /// Returns its title when it started.
    func startRunFromPrivateAnswer(_ answer: String, room: String) -> String? {
        guard let pitch = conversation(room).messages.last(where: { $0.author == "user" }), !submittedPitches.contains(pitch.id),
              let prompt = BotsT3.promptBlock(in: answer), !isDiscussing(room) else { return nil }
        return startFinalPrompt(prompt, answer: answer, pitch: pitch, room: room)
    }

    /// The owner's own words decide whether a prompt starts by itself, and which folder, Mac and chat it goes to. Returns its title when it started.
    private func startFinalPrompt(_ prompt: String, answer: String, pitch: BotChatMessage, room: String) -> String? {
        // Agents run with full access, so only the owner's own words start one by themselves. Anything else gets the card
        // in the chat, whose Start button asks first.
        guard BotsStore.ownerAskedToBuild(pitch.text) || (ProjectWords.chatToContinue(in: answer) != nil && CodingIntent.asksToContinueChat(pitch.text)) else { return nil }
        let ownerWords = recentOwnerWords(in: room) ?? pitch.text
        // The Mac the owner or the bot named, else the one this chat's coding goes on.
        let namedMac = CodingDeviceWords.named(in: ownerWords) ?? ProjectWords.labeled("Mac", in: answer)
        var mac = runMac(named: namedMac, room: room)
        // Only a folder the owner spoke of: one a page the bot read mentions doesn't count. Carrying on a chat, it's the folder that chat is in.
        let continued = ProjectWords.chatToContinue(in: answer).map { HarnessChatChoice(idOrTitle: $0) }
        var folder = projectChoice(ownerWords: ownerWords, answer: answer, macName: mac)
        if continued != nil, folder.repo == nil {
            let place = continuedPlace(answer: answer, room: room, namedMac: namedMac, mac: mac)
            folder = (place.repo, nil)
            mac = place.mac
        }
        // "Fix the login bug" with no folder: the card in the chat asks which one, rather than making a new project.
        if folder.repo == nil && folder.newFolder == nil && BotsStore.isAboutExistingCode(pitch.text) { return nil }
        submittedPitches.insert(pitch.id)
        let choices = codingChoices(from: ownerWords)
        if let problem = choices.problem { post(BotChatMessage(author: speaker(for: room)?.id ?? "theo", text: problem), to: room) }
        let title = BotsT3.projectTitle(in: answer, prompt: prompt)
        submitToT3(prompt: prompt, title: title, repo: folder.repo, room: room, harness: continued == nil ? choices.harness : continuingHarness(words: ownerWords, room: room), modelChoice: choices.model, effortChoice: choices.effort,
                   newFolder: folder.newFolder, macName: mac, continuing: continued)
        return title
    }

    /// Where a chat is carried on when the owner named no folder: the folder the bot wrote, else this chat's latest run, on the Mac that ran it.
    private func continuedPlace(answer: String, room: String, namedMac: String?, mac: String) -> (repo: URL?, mac: String) {
        if let named = ProjectWords.labeled("Repo", in: answer) { return (URL(fileURLWithPath: (named as NSString).expandingTildeInPath, isDirectory: true), mac) }
        guard let latest = latestRun(in: room) else { return (nil, mac) }
        return (URL(fileURLWithPath: latest.folder, isDirectory: true), namedMac == nil ? (latest.origin ?? mac) : mac)
    }

    /// The harness a chat is carried on in: the one named, else the one this chat's latest run was on, else the usual one.
    func continuingHarness(words: String, room: String) -> String {
        CodingHarnessWords.named(in: words) ?? latestRun(in: room).map { $0.harness ?? "t3" } ?? HarnessPrefs.codingTarget
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
        if ProjectWords.asksToWork(text), ProjectWords.namedProject(in: text, among: BotsStore.shared.knownProjects) != nil { return true }
        let text = CodingIntent.normalized(text)
        if text.range(of: #"(?i)\bprompt\b"#, options: .regularExpression) != nil { return false }
        let direct = #"(?i)\b(build|ship|refactor|fix|pull request|pr)\b"#
        let makeThing = #"(?i)\b(make|create|write|add|change|update|want|need)\b(?!\s+me\s+(on|about|with)\b).*\b(app|site|website|page|game|tool|project|script|cli|api|dashboard|feature|function|test|tests|code|repo|folder)\b"#
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
        let mac = runMac(named: CodingDeviceWords.named(in: words), room: room)
        let folder = projectChoice(ownerWords: words, answer: nil, macName: mac)
        if folder.repo == nil, folder.newFolder == nil, latestRun(in: room) != nil {
            sendToCoder(words, room: room)
        } else {
            let choices = codingChoices(from: words)
            submitToT3(prompt: words, title: BotsT3.shortTitle(from: words), repo: folder.repo, room: room, harness: choices.harness, modelChoice: choices.model, effortChoice: choices.effort, newFolder: folder.newFolder, macName: mac)
        }
    }

    /// Stops a run in progress, in T3 Code or on a harness, and reports what it left.
    func stopRun(_ runID: String) {
        guard var run = t3Runs.first(where: { $0.id == runID }), run.phase == "running" || run.phase == "waiting" else { return }
        if run.isRemote {
            if !TheoLink.shared.request("stopRun", ["id": runID]), let speaker = speaker(for: run.room ?? Self.teamID) {
                post(BotChatMessage(author: speaker.id, text: "Your \(TheoLink.shortName(run.origin ?? "other Mac")) isn't reachable, so **\(run.title)** is still going there."), to: run.room ?? Self.teamID)
            }
            return
        }
        run.stoppedByOwner = true
        run.phase = "reporting"
        upsert(run)
        HarnessCoding.stop(run)
        if run.harness == CursorCloud.harnessID { Task { await CursorCloud.stop(run) } }
        Task { [weak self] in
            // Stock T3 Code has no stop command: the thread keeps going there, and the chat says so rather than claiming it stopped.
            let reallyStopped = run.harness == nil ? await BotsT3.stopThread(run) : true
            let state = BotsT3.ThreadState(status: "cancelled", busy: false, waitingForAnswer: false, lastMessage: nil, worktree: run.worktree, pullRequest: nil)
            var report = await BotsT3.report(for: &run, state: state) { [weak self] in self?.setStage($0, runID: runID) }
            if !reallyStopped { report += "\n\nThis T3 Code can't stop a thread from outside, so its agent may still be working in T3 Code. Theo has stopped following it. Stop it in T3 Code if you need to." }
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

    /// Which Mac a run goes on: the one named, else where this chat's coding goes (normally this Mac; the Mac the owner typed on, when
    /// this turn only runs here because the bot's engine couldn't run there).
    func runMac(named word: String?, room: String) -> String {
        if let word, TheoLink.shared.isPaired, let peer = TheoLink.shared.knownPeerName {
            let wanted = word.lowercased().replacingOccurrences(of: " ", with: "")
            if peer.lowercased().replacingOccurrences(of: " ", with: "").contains(wanted) { return peer }
            if TheoLink.localName.lowercased().replacingOccurrences(of: " ", with: "").contains(wanted) { return TheoLink.localName }
        }
        if let forwarded = forwardedTurns[room] { return forwarded.fromMacFullName }
        // Bots & coding is set to the other Mac: that's whose folders the bot was given.
        switch DeviceRoles.route(.bots) {
        case .sendAcross, .waitForOtherMac: return TheoLink.shared.peerName ?? TheoLink.shared.knownPeerName ?? TheoLink.localName
        case .runHere, .notHere: return TheoLink.localName
        }
    }

    /// Creates the T3 Code project (or a branch of `repo`), starts its thread, and follows it to the end.
    /// `started`: told once whether the run got going, for a job waiting on it.
    /// `macName`: the Mac it runs on, and the folder, new folder and chat all belong to that Mac. Nil: this chat's usual one.
    /// `continuing`: carry on an existing chat of that harness in that folder, instead of a new one.
    func submitToT3(prompt: String, title: String, repo: URL? = nil, room: String = BotsStore.teamID, harness: String? = nil,
                    modelChoice: String? = nil, effortChoice: String? = nil, alsoRoom: String? = nil, newFolder: String? = nil, macName: String? = nil, continuing: HarnessChatChoice? = nil,
                    started: ((Bool, String?) -> Void)? = nil) {
        guard let theo = speaker(for: room) else {
            started?(false, "There's nobody in that chat to start it.")
            return
        }
        let target = harness ?? HarnessPrefs.codingTarget
        let mac = macName ?? runMac(named: nil, room: room)
        // It runs on the Mac chosen. Asked for from the other one, it goes over the link with its Mac named, and shows here as it runs.
        if mac != TheoLink.localName {
            let shortName = TheoLink.shortName(mac)
            var fields = ["prompt": prompt, "title": title, "repo": repo?.path ?? "", "room": room, "harness": harness ?? "", "model": modelChoice ?? "", "effort": effortChoice ?? "", "alsoRoom": alsoRoom ?? "", "newFolder": newFolder ?? "", "mac": mac]
            if let continuing {
                fields["chatID"] = continuing.idOrTitle
                fields["chatTitle"] = continuing.title ?? ""
            }
            guard TheoLink.shared.isConnected else {
                // That Mac's away: it doesn't start anywhere yet, and the chat says so plainly. It can run here if this Mac has what it needs.
                let harnessReady = target == CursorCloud.harnessID || HarnessCenter.shared.statuses[target]?.ready != false
                let folderIsHere = repo.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
                // A chat lives on the Mac it was made on, even when a folder of the same name is here.
                let problem = continuing != nil ? "that chat is on your \(shortName)" : !harnessReady ? "\(HarnessCatalog.label(target)) isn't ready here" : !folderIsHere ? "that folder isn't on this Mac" : nil
                waitForOtherMac("run", fields, room: room, label: "**\(title)**", canRunHere: problem == nil, problem: problem)
                started?(false, "Your \(shortName) isn't reachable right now.")
                return
            }
            post(BotChatMessage(author: theo.id, text: "Sent **\(title)** to your \(shortName)."), to: room)
            // That Mac checks the folder, harness and chat, so only its answer says whether it started.
            Task {
                let answer = await TheoLink.shared.ask("run", fields, timeoutSeconds: Self.remoteRunAnswerSeconds)
                guard let answer else {
                    started?(false, "Your \(shortName) didn't say whether **\(title)** started.")
                    return
                }
                started?(answer["started"] == "1", answer["problem"].flatMap { $0.isEmpty ? nil : $0 })
            }
            return
        }
        let here = TheoLink.shortName(TheoLink.localName)
        Task { [weak self] in
            if let repo, !FileManager.default.fileExists(atPath: repo.path) {
                self?.post(BotChatMessage(author: theo.id, text: "There's no folder at `\(repo.path)` on this \(here), so **\(title)** didn't start. Tell me which folder you meant."), to: room)
                started?(false, "There's no folder at \(repo.path) on this \(here).")
                return
            }
            // One at a time: starting takes up to half a minute while the agent's screen settles.
            while self?.submitting == true { try? await Task.sleep(nanoseconds: 500_000_000) }
            self?.submitting = true
            do {
                var run = try await BotsT3.submit(prompt: prompt, title: title, repo: repo, harness: target, modelChoice: modelChoice, effortChoice: effortChoice, newFolder: newFolder, continuing: continuing) { [weak self] in
                    self?.post(BotChatMessage(author: Self.noteAuthor, text: "Another \(HarnessCatalog.label(target)) run in this folder is still starting, so **\(title)** goes right after it. That keeps each run in its own chat."), to: room)
                }
                run.room = room
                run.alsoRoom = alsoRoom
                guard let self else { return }
                self.submitting = false
                self.upsert(run)
                let engine = run.harness.map(HarnessCatalog.label) ?? "T3 Code"
                if let chatTitle = run.continuedChat {
                    self.post(BotChatMessage(author: theo.id, text: "On it. **\(title)** is continuing \"\(chatTitle)\" in \(engine), in your folder \(URL(fileURLWithPath: run.folder).lastPathComponent) on this \(here). You can follow along here, and I'll post the result when it's done."), to: room)
                } else {
                    let place = run.branch.map { "branch `\($0)` of \(repo?.lastPathComponent ?? "the repo")" }
                        ?? (repo.map { "your folder \($0.lastPathComponent)" } ?? "a new project in \(BotsT3.projectsWords)/\(URL(fileURLWithPath: run.folder).lastPathComponent)")
                    self.post(BotChatMessage(author: theo.id, text: "On it. **\(title)** is with \(engine), \(place), on this \(here). " +
                        "It's coding on \(run.model.map(NativeBot.label(for:)) ?? BotsT3.modelName)" +
                        (run.effort.flatMap { $0 == "default" ? nil : " at \($0) effort" } ?? "") + ". You can follow along here, and I'll post the result when it's done."), to: room)
                }
                self.track(run.id)
                started?(true, nil)
            } catch BotsT3Error.alreadyARun(let runID) {
                // A thread Theo already follows: this goes on as a follow-up to that run, with its branch, pull request and report.
                self?.submitting = false
                self?.sendToCoder(prompt, room: room, runID: runID)
                started?(true, nil)
            } catch {
                self?.submitting = false
                self?.post(BotChatMessage(author: theo.id, text: "Couldn't start the run on \(HarnessCatalog.label(target)) on this \(here): \(error.localizedDescription)"), to: room)
                started?(false, error.localizedDescription)
            }
        }
    }

    /// Passes a change to a run's coding agent and follows the run again: the run named, or the chat's latest. Always that exact
    /// thread or session, on the Mac it runs on.
    func sendToCoder(_ text: String, room: String = BotsStore.teamID, runID: String? = nil) {
        let named = runID.flatMap { id in t3Runs.first { $0.id == id } } ?? latestRun(in: room)
        if let named, named.isRemote {
            if !TheoLink.shared.request("followup", ["room": room, "text": text, "runID": named.id]), let theo = speaker(for: room) {
                post(BotChatMessage(author: theo.id, text: "Your \(TheoLink.shortName(named.origin ?? "other Mac")) isn't connected, so that didn't reach the coding agent."), to: room)
            }
            return
        }
        guard let theo = speaker(for: room), var run = named else {
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
        if let index = t3Runs.firstIndex(where: { $0.id == run.id }) {
            // What's been found out about its chat meanwhile stays: the copy being saved can be from before.
            if run.sessionID == nil { run.sessionID = t3Runs[index].sessionID }
            if run.chatUnknown == nil { run.chatUnknown = t3Runs[index].chatUnknown }
            t3Runs[index] = run
        } else {
            t3Runs.append(run)
        }
        if let data = try? Self.encoder.encode(t3Runs) { try? data.write(to: runsFile, options: .atomic) }
    }

    /// Which chat a new run made, for a harness that doesn't say. A run can still be on its way to the list.
    func noteChat(of runID: String, _ found: HarnessNewChat) async {
        for _ in 0..<30 where !t3Runs.contains(where: { $0.id == runID }) { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        guard var run = t3Runs.first(where: { $0.id == runID }) else { return }
        if case .found(let id) = found { run.sessionID = id } else { run.chatUnknown = true }
        upsert(run)
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
    private func chatFile(_ id: String) -> URL { folder.appendingPathComponent("chats/\(BotDMThread.fileName(forThread: id)).json") }

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
        // Every bot from before the crew gets a figure that fits its job, saved, so it can be changed and stays put.
        // An older build ignores this field, so going back is safe.
        for index in upgraded.indices where upgraded[index].look == nil {
            let bot = upgraded[index]
            upgraded[index].look = .standard(id: bot.id, name: bot.name, isPrimary: bot.primary, role: bot.description)
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
        TheoLink.shared.syncSoon()
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
    static var askingStyle: String { BotProtocol.askingStyle }

    /// Who the bots work for.
    static let ownerName = "Addy"

    static var chatStyle: String { BotProtocol.houseStyle(owner: ownerName) }

    /// The one way to reach another bot, in the same words wherever it's said.
    @MainActor
    static func reachNote(for bot: NativeBot) -> String {
        BotProtocol.reachHowTo(reachable: BotsStore.shared.reachable(from: bot).map { ($0.name, $0.description) }, owner: ownerName)
    }

    /// A bot's place on the team, in a few words, for whoever it's messaging.
    @MainActor
    static func roleLine(for bot: NativeBot) -> String? {
        if bot.primary { return "the CEO" }
        if let team = BotsStore.shared.categories(of: bot.id).first {
            return team.leaderID == bot.id ? "manager of \(team.name)" : "on \(team.name)"
        }
        return bot.description.isEmpty ? nil : String(bot.description.prefix(70))
    }

    /// "Where you are" and "who you are", on every turn: a resumed engine session keeps following what it was told when it began.
    @MainActor
    static func awarenessNote(for bot: NativeBot, room: String) -> String {
        let store = BotsStore.shared
        return "(\(BotAwareness.whereYouAre(store.placeFacts(room: room, bot: bot))))\n\n(\(BotAwareness.whoYouAre(store.identityFacts(of: bot))))\n\n"
    }

    /// Who a bot reports to, in its instructions. The CEO also gets the whole picture of its teams.
    @MainActor
    static func reportingLines(for bot: NativeBot, store: BotsStore) -> [String] {
        let ceo = store.primary?.name ?? "the CEO"
        var lines = store.categories(of: bot.id).map { team -> String in
            let mates = store.members(of: team).filter { $0.id != bot.id }.map(\.name)
            let manager = team.leaderID == bot.id ? nil : team.leaderID.flatMap { store.bot($0) }?.name
            return BotProtocol.reportingLine(.init(name: team.name, purpose: team.purpose, mates: mates, isManager: team.leaderID == bot.id, managerName: manager), ceoName: ceo)
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
        var parts = [bot.instructions, chatStyle, askingStyle]
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
                parts.append("Your teammates: " + others.map { "\($0.name) (\($0.description))" }.joined(separator: "; ") + ".")
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
        if bot.owner == nil { parts.append(reachNote(for: bot)) }
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
    static func planNote(hasOthers: Bool) -> String { BotProtocol.planNote(hasOthers: hasOthers) }
    static var critiqueNote: String { BotProtocol.critiqueNote }
    static var mergeNote: String { BotProtocol.mergeNote }
    static var screenHowTo: String { BotProtocol.screenHowTo }
    static var routineHowTo: String { BotProtocol.routineHowTo }
    static var codingHowTo: String { BotProtocol.codingHowTo(harnessLabel: HarnessCatalog.label(HarnessPrefs.codingTarget)) }

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

    /// What a bot hasn't read of a group chat yet, by how far it got. A bot new to the chat gets its recent history, not all of it.
    static func transcriptMessages(in record: BotConversationRecord, for bot: NativeBot) -> [BotChatMessage] {
        // A session has the answers it wrote itself. With no session it gets those too, or it wouldn't know what it said.
        let own = record.sessions[bot.id] == nil ? [] : Set(record.ownAnswers?[bot.id] ?? [])
        let spoken = record.messages.dropFirst(min(record.seen[bot.id] ?? 0, record.messages.count))
            .filter { !$0.text.isEmpty && $0.author != BotsStore.noteAuthor && !own.contains($0.id) }
        return BotProtocol.trimmedTranscript(Array(spoken), isOwner: { $0.author == "user" }, length: { $0.text.count })
    }

    static func teamMessage(bot: NativeBot, team: [NativeBot], group: BotGroup, firstTime: Bool,
                            newMessages: [BotChatMessage], turnNote: String) -> String {
        var intro: [String] = []
        if firstTime {
            // Claude has the persona as its system prompt already; other engines get it here.
            intro.append("You are \(bot.name) in \(ownerName)'s \"\(group.name)\" group chat. " +
                         (bot.provider == "claude" || bot.provider.hasPrefix("api:") ? bot.instructions : persona(bot: bot, team: team)))
            if group.headID == bot.id && !bot.primary {
                // Theo's CEO instructions already say this; any other head gets it here.
                intro.append("You lead this group. When \(ownerName) asks to build something, end your final answer with a line \"Project: <short name>\" and the prompt for the coding agent in a ```prompt fenced block.")
            }
        }
        let transcript = newMessages.map { message -> (speaker: String, text: String) in
            (message.author == "user" ? ownerName : (team.first { $0.id == message.author }?.name ?? message.author), message.text)
        }
        return BotProtocol.groupTurnPrompt(botName: bot.name, groupName: group.name, owner: ownerName, others: team.filter { $0.id != bot.id }.map { ($0.name, $0.description) },
                                           firstTimeIntro: intro, transcript: transcript, includesScreenHowTo: bot.owner == nil, turnNote: turnNote)
    }

    static func mentioned(in text: String, bots: [NativeBot]) -> [NativeBot] {
        BotMentions.ordered(in: text, bots: bots.map { ($0.id, $0.name) }).compactMap { id in bots.first { $0.id == id } }
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
        noteLinkChanges()
        if let data = try? Self.encoder.encode(routines) { try? data.write(to: routinesFile, options: .atomic) }
        if hasLoadedLinkStamps { TheoLink.shared.syncSoon() }
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

    /// How long the Mac asking waits to hear whether a run started on the other one. It can be behind another run that's starting.
    nonisolated static let remoteRunAnswerSeconds: Double = 240

    func deleteRoutine(_ routineID: String) {
        routines.removeAll { $0.id == routineID }
        writeRoutines()
    }

    /// "Run now" (Grok's Test): a real run, out of schedule; the next scheduled run stays.
    func runRoutineNow(_ routineID: String) {
        guard let routine = routines.first(where: { $0.id == routineID }) else { return }
        start(routine, scheduled: false)
    }

    /// On the Mac that doesn't fire routines: where they do. The list is the same on both Macs. Nil when they fire here.
    var routinesElsewhereNote: String? {
        let mac = TheoLink.shortName(TheoLink.shared.peerName ?? TheoLink.shared.knownPeerName ?? "other Mac")
        switch DeviceRoles.route(.routines) {
        case .sendAcross: return "These fire on your \(mac). What you change here reaches it straight away, and Run now runs on this Mac."
        case .waitForOtherMac: return "These fire on your \(mac), which isn't reachable right now. What you change here reaches it when it's back, and Run now runs on this Mac."
        case .runHere, .notHere: return nil
        }
    }

    private func runDueRoutines() {
        // A test profile can hold a copy of real bots, signed in as the owner: their schedules must never fire there.
        if TheoProfile.isTest, !UserDefaults.standard.bool(forKey: "test.routines.run") { return }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Each routine fires once, on the Mac Settings › Devices says.
        guard DeviceRoles.runsHere(.routines) else { return }
        // Each Mac has its own setting. If both say themselves and they're linked, the Mac Studio does it.
        if TheoLink.shared.isConnected, peerDevice?.firesRoutines == true, DeviceRoles.thisMac != .macStudio { return }
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
        let prompt = (bot.owner == nil ? BotPrompts.awarenessNote(for: bot, room: bot.id) : "") +
            (firstTurn ? BotPrompts.firstMessage(bot: bot, team: bots, text: text) : text) +
            "\n\n(This is a scheduled run of a routine Addy set up; do the job now and report briefly.)" +
            (bot.owner == nil && !bot.primary ? "\n\n(\(BotPrompts.reachNote(for: bot)))" : "")
        ownerSpoke(in: bot.id)
        reply(bot: bot, in: bot.id, prompt: prompt, session: conversationRecord.sessions[bot.id], handsOnWhenStopped: true) { [weak self] answer in
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

    fileprivate func addRoutineFromChat(_ request: (name: String, when: String, schedule: BotRoutine.Schedule, instruction: String),
                                        target: String, conversationID: String, author: String) {
        // The same routine asked twice (a repeated reply) isn't added twice.
        guard !routines.contains(where: { $0.target == target && $0.instruction == request.instruction && $0.schedule == request.schedule }) else { return }
        let routine = BotRoutine(name: request.name, target: target, instruction: request.instruction, schedule: request.schedule)
        // The reply's own card shows it, with Pause and Run now.
        save(routine)
        // Routines fire on one Mac (Settings › Devices), and the list is the same on both.
        let routinesMac = TheoLink.shortName(TheoLink.shared.peerName ?? TheoLink.shared.knownPeerName ?? "other Mac")
        switch DeviceRoles.route(.routines) {
        case .sendAcross:
            post(BotChatMessage(author: Self.noteAuthor, text: "\(request.name) is set up. It fires on your \(routinesMac), where routines fire."), to: conversationID)
        case .waitForOtherMac:
            post(BotChatMessage(author: Self.noteAuthor, text: "\(request.name) is set up, but routines fire on your \(routinesMac), which isn't reachable right now. It won't fire until that Mac is back."), to: conversationID)
        case .runHere, .notHere:
            break
        }
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
        // Private messages between bots aren't the owner's mail: neither the threads nor their cards raise a badge.
        guard message.author != "user", conversationID != viewing, !BotDMThread.isThread(conversationID), BotDMThread.parseCard(message.card) == nil else { return }
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
        layout.sections[index].collapsed = !(layout.sections[index].collapsed ?? true)
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
        // Anyone can message anyone, unless Addy has picked who this one may reach.
        guard bot.canMessage != nil else { return others }
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
            !message.text.isEmpty && message.author != "user" && message.author != bot.id && message.author != Self.noteAuthor && (message.author != "routine" || message.text.hasPrefix(Self.callMark))
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
        var routines: LinkMerge.Stamps?
    }

    fileprivate func loadLinkStamps() {
        let saved = (try? Data(contentsOf: linkStampsFile)).flatMap { try? LinkCoding.decoder.decode(SavedStamps.self, from: $0) } ?? SavedStamps()
        linkBotStamps = saved.bots
        linkGroupStamps = saved.groups
        linkLayoutChangedAt = saved.layout
        linkRoutineStamps = saved.routines ?? LinkMerge.Stamps()
        linkSavedRoutines = routines
        linkSavedBots = bots
        linkSavedGroups = groups
        linkSavedLayout = layout
        hasLoadedLinkStamps = true
    }

    /// Runs on every save: what the owner changed here wins over older changes on the other Mac.
    fileprivate func noteLinkChanges() {
        guard hasLoadedLinkStamps, !isApplyingLink else { return }
        LinkMerge.noteChanges(from: linkSavedBots, to: bots, id: \.id, stamps: &linkBotStamps)
        LinkMerge.noteChanges(from: linkSavedGroups, to: groups, id: \.id, stamps: &linkGroupStamps)
        // Only what the owner decides counts as a change: a run or the next due time isn't one.
        LinkMerge.noteChanges(from: BotRoutineSync.edits(of: linkSavedRoutines), to: BotRoutineSync.edits(of: routines), id: \.id, stamps: &linkRoutineStamps)
        linkSavedRoutines = routines
        if LinkCoding.digest(linkSavedLayout) != LinkCoding.digest(layout) { linkLayoutChangedAt = Date() }
        linkSavedBots = bots
        linkSavedGroups = groups
        linkSavedLayout = layout
        writeLinkStamps()
    }

    private func writeLinkStamps() {
        let saved = SavedStamps(bots: linkBotStamps, groups: linkGroupStamps, layout: linkLayoutChangedAt, routines: linkRoutineStamps)
        if let data = try? LinkCoding.encoder.encode(saved) { try? data.write(to: linkStampsFile, options: .atomic) }
    }

    /// Once: routines start syncing. A routine on both Macs with no edit on record: the copy on the Mac that fires it is the one that's been running.
    fileprivate func stampRoutinesOnce() {
        let flag = "v3.routines.syncStamped"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        guard DeviceRouting.route(.routines, choice: DeviceRoles.choice(.routines), thisMac: DeviceRoles.thisMac, paired: true, otherMacOnline: true) == .runHere else { return }
        let now = Date()
        for routine in routines { linkRoutineStamps.changed[routine.id] = now }
        writeLinkStamps()
    }

    /// The chats both Macs should hold: every bot's and group chat's, Clicky's, and the private threads between bots.
    private var linkChatIDs: Set<String> {
        Set(bots.map(\.id) + groups.filter { $0.headID != nil }.map(\.roomID) + [Self.clickyID] + conversations.keys.filter(BotDMThread.isThread))
    }

    /// A private thread from the other Mac is wanted when both its bots are known here.
    private func isWantedChat(_ id: String) -> Bool {
        if linkChatIDs.contains(id) { return true }
        guard let pair = BotDMThread.members(of: id) else { return false }
        return bot(pair.first) != nil && bot(pair.second) != nil
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
            // By id: each Mac keeps its own order.
            "routines": LinkCoding.digest(LinkListItem(items: routines.sorted { $0.id < $1.id }, stamps: linkRoutineStamps)),
            "layout": LinkCoding.digest(layout),
            "delegations": LinkCoding.digest(delegations.map(\.id) + delegations.map { $0.finishedAt?.description ?? "" }),
            "runs": LinkCoding.digest(linkRuns),
            "device": LinkCoding.digest(DeviceSnapshotBuilder.current()),
            "clickyMac": LinkCoding.digest(TheoLink.shared.clickyMacItem),
        ]
        for id in linkChatIDs {
            let item = linkItem(forChat: id)
            digests["chat/" + id] = LinkCoding.digest(item.messages.map(\.id).sorted() + [item.clearedAt?.description ?? ""])
        }
        return digests
    }

    func wantsLinkItem(_ key: String) -> Bool {
        if key.hasPrefix("botMemory/") { return bot(String(key.dropFirst("botMemory/".count))) != nil }
        // An older build's name for what "device" says now.
        if key == "projects" { return false }
        guard key.hasPrefix("chat/") else { return true }
        return isWantedChat(String(key.dropFirst("chat/".count)))
    }

    func linkPayload(_ key: String) -> Data? {
        let encoder = LinkCoding.encoder
        switch key {
        case "bots": return try? encoder.encode(LinkListItem(items: bots, stamps: linkBotStamps))
        case "groups": return try? encoder.encode(LinkListItem(items: groups, stamps: linkGroupStamps))
        case "routines": return try? encoder.encode(LinkListItem(items: routines, stamps: linkRoutineStamps))
        case "layout": return try? encoder.encode(LinkLayoutItem(layout: layout, changedAt: linkLayoutChangedAt))
        case "delegations": return try? encoder.encode(delegations)
        case "runs": return try? encoder.encode(linkRuns)
        case "device": return try? encoder.encode(DeviceSnapshotBuilder.current())
        case "clickyMac": return try? encoder.encode(TheoLink.shared.clickyMacItem)
        case "memory": return try? encoder.encode(memoryStore.everything())
        default:
            if key.hasPrefix("botMemory/") { return try? encoder.encode(BotMemory.read(botID: String(key.dropFirst("botMemory/".count)))) }
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
            // An engine changed on the other Mac: this Mac's sessions are for the old one.
            let enginesBefore = Dictionary(bots.map { ($0.id, $0.provider) }, uniquingKeysWith: { first, _ in first })
            bots = merged.items
            for bot in bots where enginesBefore[bot.id].map({ $0 != bot.provider }) == true { clearEngineSessions(of: bot.id) }
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
        case "routines":
            guard let theirs = try? decoder.decode(LinkListItem<BotRoutine>.self, from: data) else { return }
            let merged = BotRoutineSync.merged(local: routines, localStamps: linkRoutineStamps, remote: theirs.items, remoteStamps: theirs.stamps)
            linkRoutineStamps = merged.stamps
            routines = merged.items
            linkSavedRoutines = routines
            if let saved = try? Self.encoder.encode(routines) { try? saved.write(to: routinesFile, options: .atomic) }
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
        case "clickyMac":
            if let theirs = try? decoder.decode(ClickyMacItem.self, from: data) { TheoLink.shared.applyClickyMac(theirs) }
        case "device":
            if let theirs = try? decoder.decode(DeviceSnapshot.self, from: data) { peerDevice = theirs }
        case "runs":
            guard let theirs = try? decoder.decode([T3Run].self, from: data) else { return }
            // Each Mac is the only one writing its own runs.
            t3Runs = LinkMerge.ownedRuns(local: t3Runs, remote: theirs, isTheirs: \.isRemote, id: \.id, at: \.startedAt)
            if let saved = try? Self.encoder.encode(t3Runs) { try? saved.write(to: runsFile, options: .atomic) }
        case "memory":
            guard let theirs = try? decoder.decode([ClickyMemoryEntry].self, from: data) else { return }
            memoryStore.merge(theirs)
        default:
            if key.hasPrefix("botMemory/") {
                let botID = String(key.dropFirst("botMemory/".count))
                if bot(botID) != nil, let theirs = try? decoder.decode(String.self, from: data) { BotMemory.merge(theirs, botID: botID) }
                return
            }
            let id = String(key.dropFirst("chat/".count))
            guard key.hasPrefix("chat/"), isWantedChat(id), let theirs = try? decoder.decode(LinkChatItem.self, from: data) else { return }
            var record = conversation(id)
            let known = Set(record.messages.map(\.id))
            let clearedAt = [record.clearedAt, theirs.clearedAt].compactMap { $0 }.max()
            // If each Mac holds a copy of one message, the earlier time is the one it was written.
            let merged = LinkMerge.union(local: record.messages, remote: theirs.messages, id: \.id, at: \.sortDate, clearedAt: clearedAt) { first, second in
                first.sortDate <= second.sortDate ? first : second
            }
            let arrived = merged.filter { !known.contains($0.id) }
            record.messages = merged
            record.clearedAt = clearedAt
            // What came in may sit in the middle of what's here, written while the Macs were apart. Nobody's session has seen it yet.
            if !arrived.isEmpty {
                let ids = merged.map(\.id)
                let arrivedIDs = Set(arrived.map(\.id))
                record.heard = record.heard?.mapValues { BotCatchUp.heardAfterMerge(heard: $0, merged: ids, arrived: arrivedIDs) ?? $0 }
                record.seen = record.seen.mapValues { BotCatchUp.seenAfterMerge(seen: $0, merged: ids, arrived: arrivedIDs) }
            }
            conversations[id] = record
            writeConversation(id)
            for message in arrived where !message.text.isEmpty { noteUnread(message, in: id) }
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
        case "studioView":
            if let view = fields["view"] { StudioController.shared.receiveRemoteView(view) }
        case "research":
            // The other Mac asked: it runs here, on the screens. Its answer reaches that Mac through the chats, or straight back to a bot that's waiting for it.
            guard let question = fields["question"], let research = CompanionManager.current?.researchController else { return }
            let urls = (fields["urls"] ?? "").split(separator: "\n").compactMap { URL(string: String($0)) }.filter { ResearchURLPolicy.isAllowed($0) }
            let request = urls.isEmpty ? (ResearchTrigger.parse(question) ?? ResearchRequest(source: .topic(question), question: question))
                : ResearchRequest(source: .links(count: urls.count), question: question, namedURLs: urls)
            guard let replyID = fields["replyID"] else {
                research.start(request, speaks: false, reportsToCEO: fields["ceo"] == "1", askedByOtherMac: true)
                return
            }
            guard !research.isRunning else {
                _ = TheoLink.shared.request("reply", ["replyID": replyID, "message": "Clicky's agents on your \(TheoLink.shortName(TheoLink.localName)) are already researching something, so I didn't start this: \(question)"])
                return
            }
            research.start(request, speaks: false, askedByOtherMac: true)
            let run = research.runNumber
            Task {
                let brief = await Self.brief(of: research, run: run)
                _ = TheoLink.shared.request("reply", ["replyID": replyID, "answer": brief ?? ""])
            }
        case "updateWhenIdle":
            // Only ever the normal update, with its checksum and signature checks.
            CompanionManager.current?.updateController.installWhenIdle()
        case "run":
            guard let prompt = fields["prompt"], let title = fields["title"], let room = fields["room"] else { return }
            let repo = fields["repo"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            func field(_ key: String) -> String? { fields[key].flatMap { $0.isEmpty ? nil : $0 } }
            let continued = field("chatID").map { HarnessChatChoice(idOrTitle: $0, title: field("chatTitle")) }
            // Its Mac was named on the other side. This Mac checks the folder is here before anything starts (submitToT3), and says how it went.
            submitToT3(prompt: prompt, title: title, repo: repo, room: room, harness: field("harness"), modelChoice: field("model"), effortChoice: field("effort"), alsoRoom: field("alsoRoom"), newFolder: field("newFolder"),
                       macName: TheoLink.localName, continuing: continued) { started, problem in
                if let replyID = fields["replyID"] { _ = TheoLink.shared.request("reply", ["replyID": replyID, "started": started ? "1" : "0", "problem": problem ?? ""]) }
            }
        case "mkdir":
            // A new folder picked from the other Mac's menu: the answer says where it landed, so that menu can select it.
            guard let name = fields["name"], let replyID = fields["replyID"] else { return }
            Task {
                let result = await BotsT3.makeProject(named: name)
                var answer = ["replyID": replyID]
                switch result {
                case .made(let folder): answer["path"] = folder.path
                case .alreadyThere(let folder): answer["exists"] = folder.lastPathComponent
                case .failed(let problem): answer["problem"] = problem
                }
                _ = TheoLink.shared.request("reply", answer)
            }
        case "listChats":
            guard let harness = fields["harness"], let folder = fields["folder"], let replyID = fields["replyID"] else { return }
            Task {
                let chats = await HarnessChats.list(harness: harness, folder: folder)
                let json = (try? LinkCoding.encoder.encode(chats)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                _ = TheoLink.shared.request("reply", ["replyID": replyID, "chats": json])
            }
        case "reply":
            if let replyID = fields["replyID"] { TheoLink.shared.replyArrived(replyID, fields: fields) }
        case "routineAdd":
            guard let name = fields["name"], let target = fields["target"], let when = fields["when"], let instruction = fields["do"], let schedule = BotRoutine.Schedule.parse(when) else { return }
            guard !routines.contains(where: { $0.target == target && $0.instruction == instruction && $0.schedule == schedule }) else { return }
            save(BotRoutine(name: name, target: target, instruction: instruction, schedule: schedule))
        case "followup":
            guard let room = fields["room"], let text = fields["text"] else { return }
            sendToCoder(text, room: room, runID: fields["runID"])
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
        case "botSay", "groupSay":
            guard let target = fields["target"], let text = fields["text"], let id = fields["id"] else { return }
            let command = fields["command"].flatMap { $0.isEmpty ? nil : $0 }
            let writtenAt = fields["at"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            if action == "botSay" {
                ownerMacs[target] = fields["fromMac"]
                send(text, command: command, to: target, messageID: id, writtenAt: writtenAt)
            } else {
                if let room = group(target)?.roomID { ownerMacs[room] = fields["fromMac"] }
                sendToGroup(text, command: command, groupID: target, messageID: id, writtenAt: writtenAt)
            }
        case "botTurn":
            handleTurnFromOtherMac(fields)
        case "botTurnStop":
            if let botID = fields["bot"] { stop(botID) }
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
            // The bot carries on from the Mac it's talking on, where its session is.
            workOnScreen(task, bot: bot, room: room) { report in
                _ = TheoLink.shared.request("screenReport", ["bot": bot.id, "room": room, "report": report])
            }
        case "screenReport":
            guard let room = fields["room"], let report = fields["report"], let bot = fields["bot"].flatMap({ self.bot($0) }) else { return }
            continueAfterScreen(bot: bot, room: room, report: report)
        default:
            break
        }
    }

    /// What this bot's engine session hasn't seen of this chat: what happened on the other Mac, or anything since it last spoke on this one.
    /// Each Mac has its own session, so with no session here it gets the chat's latest to go on. `before`: the message this turn answers.
    func catchUp(_ id: String, bot: NativeBot, before messageID: String) -> String {
        catchUp(in: conversation(id), bot: bot, before: messageID)
    }

    func catchUp(in record: BotConversationRecord, bot: NativeBot, before messageID: String) -> String {
        // All of them: what it heard last can be a card or a note.
        let earlier = Array(record.messages.prefix { $0.id != messageID })
        let unheard = BotCatchUp.unheard(messages: earlier, id: \.id, heard: record.heard?[bot.id], hasSession: record.sessions[bot.id] != nil, isLinked: TheoLink.shared.isPaired,
                                         counts: { !$0.text.isEmpty && $0.author != Self.noteAuthor })
        guard !unheard.isEmpty else { return "" }
        let lines = BotCatchUp.lines(unheard.map { message in
            (message.author == "user" ? BotPrompts.ownerName : (self.bot(message.author)?.name ?? message.author), message.text)
        }).joined(separator: "\n")
        return "(This chat also went on while you weren't here, some of it maybe from Addy's other Mac:\n\n\(lines)\n\nUse this as context.)\n\n"
    }
}
