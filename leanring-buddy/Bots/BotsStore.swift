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
    /// Off: the bot doesn't answer, run routines or join group chats (nil = on).
    var enabled: Bool?
    /// "member" (default), "lead" (directs its group chats) or "ceo" (may direct any bot).
    var authority: String?
    /// Bots this one may message directly from its own chat (besides what its authority allows).
    var canMessage: [String]?

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
    /// The conversation on screen, which collects no unread count.
    var viewing: String? { didSet { if let viewing { unread[viewing] = nil } } }
    private var routineTimer: Timer?
    private var runningRoutines: Set<String> = []

    static let teamID = "team"

    private let folder: URL

    private init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Theo/Bots", isDirectory: true)
        Self.archiveForFreshStart(folder)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("chats"), withIntermediateDirectories: true)
        bots = loadBots()
        groups = loadGroups()
        writeGroups()
        for id in groups.filter { $0.headID != nil }.map(\.roomID) + bots.map(\.id) {
            conversations[id] = loadConversation(id)
        }
        if let data = try? Data(contentsOf: runsFile), let runs = try? Self.decoder.decode([T3Run].self, from: data) {
            t3Runs = runs
        }
        for run in t3Runs where run.phase == "running" || run.phase == "waiting" { track(run.id) }
        loadRoutinesAndLayout()
    }

    var primary: NativeBot? { bots.first(where: \.primary) ?? bots.first }

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
    }

    /// A new bot, added to a group (or to no group).
    @discardableResult
    func addBot(name: String, description: String, instructions: String, provider: String, model: String,
                groupID: String?) -> NativeBot {
        var id = BotsT3.slug(name)
        var suffix = 2
        while bot(id) != nil { id = "\(BotsT3.slug(name))-\(suffix)"; suffix += 1 }
        let hue = Double(abs(id.hashValue) % 330)
        let bot = NativeBot(id: id, name: name, description: description, instructions: instructions, hue: hue,
                            accentHue: hue + 30, primary: false, provider: provider, model: model, effort: nil,
                            apps: [], category: groupID == BotGroup.projectID ? "project" : "personal")
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
        guard let bot = bot(id), !bot.primary else { return }
        bots.removeAll { $0.id == id }
        for index in groups.indices {
            groups[index].memberIDs.removeAll { $0 == id }
            if groups[index].headID == id { groups[index].headID = nil }
        }
        for index in bots.indices { bots[index].canMessage?.removeAll { $0 == id } }
        BotProcesses.shared.stop(id)
        conversations[id] = nil
        try? FileManager.default.removeItem(at: chatFile(id))
        writeBots()
        writeGroups()
        forget(item: "bot:\(id)")
    }

    func bot(_ id: String) -> NativeBot? { bots.first { $0.id == id } }

    func conversation(_ id: String) -> BotConversationRecord { conversations[id] ?? BotConversationRecord() }

    func save(_ bot: NativeBot) {
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
        conversations[id] = BotConversationRecord()
        writeConversation(id)
    }

    // MARK: Talking

    /// Sends your message to a bot's own chat and streams its reply in.
    func send(_ text: String, to botID: String) {
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
        if bot.primary && text.lowercased().contains("@t3") {
            // Theo's own chat hands a change straight to the coding agent of its latest run.
            sendToCoder(text.replacingOccurrences(of: "@T3", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines), room: botID)
            return
        }
        let firstTurn = record.sessions[botID] == nil
        var prompt = firstTurn ? BotPrompts.firstMessage(bot: bot, team: bots, text: text) : text
        if !firstTurn && BotPrompts.asksForSchedule(text) { prompt += "\n\n(\(BotPrompts.routineHowTo))" }
        reply(bot: bot, in: botID, prompt: prompt, session: record.sessions[botID]) { [weak self] answer in
            if let answer { self?.relayMentions(from: bot, answer: answer, in: botID, hop: 0) }
        }
    }

    /// Posts to the Project room.
    func sendToTeam(_ text: String) {
        if group(BotGroup.projectID)?.headID != nil { sendToGroup(text, groupID: BotGroup.projectID) }
        else if let primary { send(text, to: primary.id) }
    }

    /// Posts to a group chat; tagged bots answer, or the head when nobody is tagged.
    func sendToGroup(_ text: String, groupID: String) {
        guard let group = group(groupID), let head = head(of: group) else { return }
        let room = group.roomID
        var record = conversation(room)
        record.messages.append(BotChatMessage(author: "user", text: text))
        conversations[room] = record
        writeConversation(room)
        if text.lowercased().contains("@t3") {
            // Straight to the coding agent of this room's latest run, the way the head hands off a change.
            sendToCoder(text.replacingOccurrences(of: "@T3", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines), room: room)
            return
        }
        let tagged = BotPrompts.mentioned(in: text, bots: members(of: group))
        askTeam(tagged.isEmpty ? [head] : tagged, chain: 0, group: group)
    }

    /// How many bot-to-bot hand-offs one message of yours can set off.
    private static let maxChain = 8

    private func askTeam(_ targets: [NativeBot], chain: Int, group: BotGroup) {
        let room = group.roomID
        let team = members(of: group)
        let headID = group.headID
        for bot in targets where replying[bot.id] == nil && bot.isOn {
            let record = conversation(room)
            let seen = record.seen[bot.id] ?? 0
            let newMessages = Array(record.messages.dropFirst(seen))
            let prompt = BotPrompts.teamMessage(bot: bot, team: team, group: group, firstTime: record.sessions[bot.id] == nil,
                                                newMessages: newMessages)
            var updated = record
            updated.seen[bot.id] = record.messages.count
            conversations[room] = updated
            reply(bot: bot, in: room, prompt: prompt, session: record.sessions[bot.id]) { [weak self] answer in
                guard let self, chain < Self.maxChain, let group = self.group(group.id), let head = self.head(of: group) else { return }
                let team = self.members(of: group)
                let isHead = bot.id == headID
                guard let answer else {
                    // A member that failed or timed out doesn't stall the room: the head merges what's there.
                    if !isHead, team.allSatisfy({ self.replying[$0.id] == nil }) { self.askTeam([head], chain: chain + 1, group: group) }
                    return
                }
                // Only the head (or a lead/CEO) hands out work; members tagging each other would chat on and on.
                let canDelegate = isHead || ["lead", "ceo"].contains(bot.authorityLevel)
                let next = canDelegate ? BotPrompts.mentioned(in: answer, bots: team).filter { $0.id != bot.id && $0.id != head.id } : []
                if isHead || !next.isEmpty {
                    // The head hands the work out, and a planner can hand out the parts.
                    if !next.isEmpty { self.askTeam(next, chain: chain + 1, group: group) }
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

    private func reply(bot: NativeBot, in conversationID: String, prompt: String, session: String?,
                       then: @escaping (String?) -> Void) {
        stopped.remove(bot.id)
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
            let streamed = self.replying[bot.id]
            self.replying[bot.id] = nil
            if self.stopped.remove(bot.id) != nil {
                // Keep what it had said so far, marked as stopped, and hand nothing on.
                let partial = (answer ?? streamed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.post(BotChatMessage(author: bot.id, text: partial.isEmpty ? "_(Stopped.)_" : partial + "\n\n_(Stopped.)_"), to: conversationID)
                return
            }
            var record = self.conversation(conversationID)
            if let newSession { record.sessions[bot.id] = newSession }
            if let answer, !answer.isEmpty {
                let message = BotChatMessage(author: bot.id, text: BotPrompts.withoutNameHeading(answer, bot: bot))
                self.noteUnread(message, in: conversationID)
                record.messages.append(message)
                if self.isRoom(conversationID) { record.seen[bot.id] = record.messages.count }
            } else if answer != nil {
                record.messages.append(BotChatMessage(author: bot.id, text: "(No answer this time. Send it again, or try another model.)"))
            }
            self.conversations[conversationID] = record
            self.writeConversation(conversationID)
            if let answer, self.group(forRoom: conversationID)?.headID == bot.id || (bot.primary && conversationID == bot.id) {
                self.submitIfFinal(answer, room: conversationID)
            }
            if let answer, let request = Self.routineRequest(in: answer) {
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
        guard let prompt = BotsT3.promptBlock(in: answer) else { return }
        let wantsBuild = pitch.text.range(of: #"\b(build|submit|send|make|code|t3|pr|pull request|fix|ship)\b"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil
        guard wantsBuild else { return }
        submittedPitches.insert(pitch.id)
        submitToT3(prompt: prompt, title: BotsT3.projectTitle(in: answer, prompt: prompt),
                   repo: BotsT3.targetRepo(answer: answer, pitch: pitch.text), room: room)
    }

    /// The bot that speaks for a room: its head, else Theo.
    private func speaker(for room: String) -> NativeBot? { group(forRoom: room).flatMap { head(of: $0) } ?? primary }

    /// The newest run started from a room (older runs have no room: the Project room's).
    func latestRun(in room: String) -> T3Run? { t3Runs.last { ($0.room ?? Self.teamID) == room } }

    /// Creates the T3 Code project (or a branch of `repo`), starts its thread, and follows it to the end.
    func submitToT3(prompt: String, title: String, repo: URL? = nil, room: String = BotsStore.teamID) {
        guard let theo = speaker(for: room), !submitting else { return }
        submitting = true
        Task { [weak self] in
            do {
                var run = try await BotsT3.submit(prompt: prompt, title: title, repo: repo)
                run.room = room
                guard let self else { return }
                self.submitting = false
                self.upsert(run)
                let place = run.branch.map { "branch `\($0)` of \(repo?.lastPathComponent ?? "the repo")" }
                    ?? "a new project in ~/Projects/\(URL(fileURLWithPath: run.folder).lastPathComponent)"
                self.post(BotChatMessage(author: theo.id, text: "Submitted to T3 Code: **\(title)**, \(place). " +
                    "\(BotsT3.modelName) is coding it at \(BotsT3.effort) effort. I'll post the result here when it's done."), to: room)
                self.track(run.id)
            } catch {
                self?.submitting = false
                self?.post(BotChatMessage(author: theo.id, text: "Couldn't submit to T3 Code: \(error.localizedDescription)"), to: room)
            }
        }
    }

    /// Passes a change to the latest run's coding agent and follows the run again.
    func sendToCoder(_ text: String, room: String = BotsStore.teamID) {
        guard let theo = speaker(for: room), var run = latestRun(in: room) else {
            if let theo = speaker(for: room) {
                post(BotChatMessage(author: theo.id, text: "There's no T3 Code run from this chat yet. Pitch an idea first."), to: room)
            }
            return
        }
        Task { [weak self] in
            do {
                let worktree = await BotsT3.state(of: run)?.worktree
                if let head = await BotsT3.currentHead(of: run, worktree: worktree) { run.baseCommit = head }
                try await BotsT3.sendFollowup(text, to: run)
                guard let self else { return }
                run.phase = "running"
                run.startedAt = Date()
                run.finishedAt = nil
                self.upsert(run)
                self.post(BotChatMessage(author: theo.id, text: "Passed to the coding agent on **\(run.title)**. I'll report back when it's done."), to: room)
                self.track(run.id)
            } catch {
                self?.post(BotChatMessage(author: theo.id, text: "Couldn't reach T3 Code: \(error.localizedDescription)"), to: room)
            }
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
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while let self, var run = self.t3Runs.first(where: { $0.id == runID }), run.phase == "running" || run.phase == "waiting" {
                guard let state = await BotsT3.state(of: run) else {
                    misses += 1
                    if misses >= 40 {
                        // T3 Code has been unreachable for ten minutes: stop and say so instead of spinning.
                        run.phase = "failed"
                        self.upsert(run)
                        self.postFromTheo("Lost track of **\(run.title)**: T3 Code isn't answering. Open T3 Code to see where it got to.", room: run.room)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    continue
                }
                misses = 0
                run.activity = state.lastMessage.map { String($0.split(separator: "\n").first ?? "").prefix(140) }.map(String.init)
                if state.waitingForAnswer, !state.busy || state.status == "waiting" {
                    run.phase = "waiting"
                    self.upsert(run)
                    if askedAbout != state.lastMessage {
                        askedAbout = state.lastMessage
                        self.postFromTheo("The coding agent on **\(run.title)** is waiting for an answer:\n\n" +
                                          "\(state.lastMessage ?? "(open T3 Code to see the question)")\n\nReply with @T3 and your answer.", room: run.room)
                    }
                } else if !state.busy && (BotsT3.endedStatuses.contains(state.status) || state.status == "idle") {
                    let report = await BotsT3.report(for: &run, state: state)
                    run.phase = ["failed", "interrupted", "cancelled", "rolled_back"].contains(state.status) ? "failed" : "done"
                    run.finishedAt = Date()
                    self.upsert(run)
                    self.postFromTheo(report, runID: run.id)
                    break
                } else {
                    run.phase = "running"
                    self.upsert(run)
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
            self?.trackedRuns.remove(runID)
        }
    }

    /// Posts about a run in the chat it came from, as that chat's head.
    private func postFromTheo(_ text: String, runID: String? = nil, room: String? = nil) {
        let room = room ?? runID.flatMap { id in t3Runs.first { $0.id == id }?.room } ?? Self.teamID
        guard let speaker = speaker(for: room) else { return }
        post(BotChatMessage(author: speaker.id, text: text, runID: runID), to: room)
    }

    private func upsert(_ run: T3Run) {
        if let index = t3Runs.firstIndex(where: { $0.id == run.id }) { t3Runs[index] = run } else { t3Runs.append(run) }
        if let data = try? Self.encoder.encode(t3Runs) { try? data.write(to: runsFile, options: .atomic) }
    }

    private func post(_ message: BotChatMessage, to conversationID: String) {
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
        let upgraded = BotImport.upgrade(base, offered: &offered)
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
        if let data = try? Self.encoder.encode(groups) { try? data.write(to: groupsFile, options: .atomic) }
    }

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

/// The bot a fresh setup starts with, and fixes for bots saved by older versions.
enum BotImport {
    static func defaultCategory(_ id: String) -> String {
        ["gmail-reader", "researcher"].contains(id) ? "personal" : "project"
    }

    /// Theo, the primary bot: Addy's own helper, the head of any group chat Addy makes him head of, and the
    /// one who hands builds to T3 Code.
    static let primaryInstructions =
        "You are Theo, Addy's primary bot. Help directly with anything Addy asks. When Addy asks to build, code " +
        "or fix something, plan it briefly, then write one final prompt for T3 Code's coding agent: a line " +
        "\"Project: <short name>\" and the prompt inside a ```prompt fenced block (add \"Repo: <path>\" when Addy " +
        "names an existing project folder, so it goes on a new branch with a pull request). T3 Code then builds it " +
        "and you post its report. For a change to something already built, put it in a ```followup fenced block. " +
        "In a group chat you lead, hand parts of the work to the others with @Name, then merge their answers."

    /// A fresh setup starts with Theo alone; Addy adds every other bot.
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
            let others = team.filter { $0.id != bot.id }
            if !others.isEmpty {
                parts.append("Your teammates: " + others.map { "\($0.name) (\($0.description))" }.joined(separator: "; ") +
                             ". Mention one with @Name in the team chat to bring them in.")
            }
        }
        parts.append(BotPrompts.routineHowTo)
        let reachable = BotsStore.shared.reachable(from: bot)
        if !reachable.isEmpty {
            parts.append("Your authority: \(bot.authorityLevel). You may message these bots by writing @Name in your reply; " +
                         "they answer you in the chat and you then carry on: " + reachable.map { "@\($0.name) (\($0.description))" }.joined(separator: ", ") + ".")
        }
        if bot.provider == "grok" {
            parts.append("Your memory is \(bot.memoryPath). Read it first if it exists.")
        } else {
            parts.append("Your memory is \(bot.memoryPath). Read it first if it exists, and add one short line when you " +
                         "learn a lasting preference or fact. Don't store secrets.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// How a bot sets up a routine. Theo does the scheduling, so no scheduling tool or skill is needed.
    static let routineHowTo =
        "Routines: when Addy asks for something on a schedule (\"every weekday at 8, …\"), don't use any scheduling, " +
        "cron or schedule tool or skill: Theo runs routines for you. Say what you'll do and when, then add a ```routine " +
        "block with JSON {\"name\": short name, \"when\": \"daily 08:00\" | \"weekdays 08:30\" | \"weekly mon 09:00\" | " +
        "\"hourly\" | \"every 30 minutes\", \"do\": the instruction you'll be given at each run}. Theo then runs it on " +
        "time, and Addy can pause, run or delete it."

    /// Words that ask for something on a schedule, so the routine how-to rides along even in an older chat.
    static func asksForSchedule(_ text: String) -> Bool {
        text.range(of: #"\b(every|each)\s+(day|morning|evening|night|weekday|week|monday|tuesday|wednesday|thursday|friday|saturday|sunday|hour|\d+\s*(min|minutes|hours?))\b|\b(daily|hourly|weekly|routine|schedule)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The first message of a bot's chat on engines without a system prompt option.
    static func firstMessage(bot: NativeBot, team: [NativeBot], text: String) -> String {
        bot.provider == "claude" ? text : "\(persona(bot: bot, team: team))\n\n---\n\n\(text)"
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
                         (bot.provider == "claude" ? bot.instructions : persona(bot: bot, team: team)))
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
    }

    func section(of item: String) -> Section? { sections.first { $0.items.contains(item) } }
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

    private func writeLayout() {
        if let data = try? Self.encoder.encode(layout) { try? data.write(to: layoutFile, options: .atomic) }
    }

    // MARK: Routines

    func routines(for target: String) -> [BotRoutine] { routines.filter { $0.target == target } }

    func targetName(_ target: String) -> String {
        if target.hasPrefix("group:") { return group(String(target.dropFirst(6)))?.name ?? "Group" }
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
        save(routine)
        post(BotChatMessage(author: author, text: "Routine set: **\(request.name)**, \(request.schedule.label.lowercased()). " +
                            "Pause, run or delete it from this bot's details or the Routines page."), to: conversationID)
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
        if hidden { layout.hidden.append(item); layout.pinned.removeAll { $0 == item } }
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

    func addSection(named name: String, parentID: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        layout.sections.append(BotsLayout.Section(name: trimmed, parentID: parentID))
        writeLayout()
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
    func reachable(from bot: NativeBot) -> [NativeBot] {
        let others = bots.filter { $0.id != bot.id && $0.isOn }
        switch bot.authorityLevel {
        case "ceo": return others
        case "lead":
            let led = Set(groupsLed(by: bot.id).flatMap(\.memberIDs)).union(bot.canMessage ?? [])
            return others.filter { led.contains($0.id) }
        default:
            let allowed = Set(bot.canMessage ?? [])
            return others.filter { allowed.contains($0.id) }
        }
    }

    /// After a bot answers in its own chat: any bot it @mentions (and may reach) answers there, then the
    /// first bot reads the answers and carries on. A few hops at most.
    func relayMentions(from bot: NativeBot, answer: String, in conversationID: String, hop: Int) {
        guard hop < 3 else { return }
        let targets = BotPrompts.mentioned(in: answer, bots: reachable(from: bot)).filter { replying[$0.id] == nil }
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
        guard let old = primary, old.id != botID, var new = bot(botID) else { return }
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
