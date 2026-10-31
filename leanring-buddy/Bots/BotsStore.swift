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

    var isProjectHandler: Bool { (category ?? BotImport.defaultCategory(id)) == "project" }

    var memoryPath: String { "~/.t3/bots/\(id)/memory.md" }

    var modelLabel: String { Self.label(for: model) }

    static func label(for model: String) -> String {
        let name = model.split(separator: "/").last.map(String.init) ?? model
        // "claude-sonnet-5-5" reads "Claude Sonnet 5.5".
        let versioned = name.replacingOccurrences(of: #"-(\d+)-(\d+)$"#, with: " $1.$2", options: .regularExpression)
        return versioned.replacingOccurrences(of: "-", with: " ").capitalized
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
        if let data = try? Data(contentsOf: runsFile), let runs = try? Self.decoder.decode([T3Run].self, from: data) {
            t3Runs = runs
        }
        for run in t3Runs where run.phase == "running" || run.phase == "waiting" { track(run.id) }
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
        if text.lowercased().contains("@t3") {
            // Straight to the coding agent of the latest run, the way Theo hands off a change.
            sendToCoder(text.replacingOccurrences(of: "@T3", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
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
                guard let self, chain < Self.maxChain else { return }
                guard let answer else {
                    // A teammate that failed or timed out doesn't stall the room: Theo merges what's there.
                    if !bot.primary, let theo = self.primary, self.projectBots.allSatisfy({ self.replying[$0.id] == nil }) {
                        self.askTeam([theo], chain: chain + 1)
                    }
                    return
                }
                let next = BotPrompts.mentioned(in: answer, bots: self.projectBots).filter { $0.id != bot.id && !$0.primary }
                if bot.primary || !next.isEmpty {
                    // Theo hands the research to the Project Manager, and the Project Manager hands out the parts.
                    if !next.isEmpty { self.askTeam(next, chain: chain + 1) }
                } else if let theo = self.primary, self.projectBots.allSatisfy({ self.replying[$0.id] == nil }) {
                    // The last of the team has answered: Theo reads the whole round once and merges it.
                    self.askTeam([theo], chain: chain + 1)
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

    /// Stops every reply in the Project room.
    func stopTeam() { for bot in projectBots where replying[bot.id] != nil { stop(bot.id) } }

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
                record.messages.append(BotChatMessage(author: bot.id, text: BotPrompts.withoutNameHeading(answer, bot: bot)))
                if conversationID == Self.teamID { record.seen[bot.id] = record.messages.count }
            } else if answer != nil {
                record.messages.append(BotChatMessage(author: bot.id, text: "(No answer this time. Send it again, or try another model.)"))
            }
            self.conversations[conversationID] = record
            self.writeConversation(conversationID)
            if conversationID == Self.teamID, bot.primary, let answer { self.submitIfFinal(answer) }
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
    private func submitIfFinal(_ answer: String) {
        guard let pitch = conversation(Self.teamID).messages.last(where: { $0.author == "user" }),
              !submittedPitches.contains(pitch.id) else { return }
        if let followup = BotsT3.followupBlock(in: answer), t3Runs.last != nil {
            submittedPitches.insert(pitch.id)
            sendToCoder(followup)
            return
        }
        guard let prompt = BotsT3.promptBlock(in: answer) else { return }
        let wantsBuild = ["build", "submit", "send", "make", "t3", " pr", "pull request", "fix"].contains { pitch.text.lowercased().contains($0) }
        guard wantsBuild else { return }
        submittedPitches.insert(pitch.id)
        submitToT3(prompt: prompt, title: BotsT3.projectTitle(in: answer, prompt: prompt),
                   repo: BotsT3.targetRepo(answer: answer, pitch: pitch.text))
    }

    /// Creates the T3 Code project (or a branch of `repo`), starts its thread, and follows it to the end.
    func submitToT3(prompt: String, title: String, repo: URL? = nil) {
        guard let theo = primary, !submitting else { return }
        submitting = true
        Task { [weak self] in
            do {
                let run = try await BotsT3.submit(prompt: prompt, title: title, repo: repo)
                guard let self else { return }
                self.submitting = false
                self.upsert(run)
                let place = run.branch.map { "branch `\($0)` of \(repo?.lastPathComponent ?? "the repo")" }
                    ?? "a new project in ~/Projects/\(URL(fileURLWithPath: run.folder).lastPathComponent)"
                self.post(BotChatMessage(author: theo.id, text: "Submitted to T3 Code: **\(title)**, \(place). " +
                    "\(BotsT3.modelName) is coding it at \(BotsT3.effort) effort. I'll post the result here when it's done."), to: Self.teamID)
                self.track(run.id)
            } catch {
                self?.submitting = false
                self?.post(BotChatMessage(author: theo.id, text: "Couldn't submit to T3 Code: \(error.localizedDescription)"), to: Self.teamID)
            }
        }
    }

    /// Passes a change to the latest run's coding agent and follows the run again.
    func sendToCoder(_ text: String) {
        guard let theo = primary, var run = t3Runs.last else {
            if let theo = primary {
                post(BotChatMessage(author: theo.id, text: "There's no T3 Code run yet. Pitch an idea first."), to: Self.teamID)
            }
            return
        }
        Task { [weak self] in
            do {
                try await BotsT3.sendFollowup(text, to: run)
                guard let self else { return }
                run.phase = "running"
                run.startedAt = Date()
                run.finishedAt = nil
                self.upsert(run)
                self.post(BotChatMessage(author: theo.id, text: "Passed to the coding agent on **\(run.title)**. I'll report back when it's done."), to: Self.teamID)
                self.track(run.id)
            } catch {
                self?.post(BotChatMessage(author: theo.id, text: "Couldn't reach T3 Code: \(error.localizedDescription)"), to: Self.teamID)
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
                        self.postFromTheo("Lost track of **\(run.title)**: T3 Code isn't answering. Open T3 Code to see where it got to.")
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
                                          "\(state.lastMessage ?? "(open T3 Code to see the question)")\n\nReply with @T3 and your answer.")
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

    private func postFromTheo(_ text: String, runID: String? = nil) {
        guard let theo = primary else { return }
        post(BotChatMessage(author: theo.id, text: text, runID: runID), to: Self.teamID)
    }

    private func upsert(_ run: T3Run) {
        if let index = t3Runs.firstIndex(where: { $0.id == run.id }) { t3Runs[index] = run } else { t3Runs.append(run) }
        if let data = try? Self.encoder.encode(t3Runs) { try? data.write(to: runsFile, options: .atomic) }
    }

    private func post(_ message: BotChatMessage, to conversationID: String) {
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
        "Editor work under you. When Addy pitches an idea in the Project room: first have Clicky study it on the " +
        "web with the claudia_research tool (one call with a focused question; Clicky reads three sources), then " +
        "post a short summary of what it found, with the sources, and hand it to @Project Manager only. The " +
        "Project Manager plans it and gives the parts to the team. When the team has answered, settle any " +
        "disagreement yourself and merge it all into one final prompt for T3 Code's coding agent right away, " +
        "with no second round of questions: a line \"Project: <short name>\" and then the prompt inside a " +
        "```prompt fenced block. If Addy names an existing project folder, add a line \"Repo: <its path>\" so the " +
        "work goes on a new branch of it with a pull request. Write the final prompt once. T3 Code then builds it " +
        "and you post its report here. When Addy later asks for a change to what was built, don't start a new " +
        "round: put the change for the coding agent in a ```followup fenced block. Keep everything else short."

    static let projectManagerInstructions =
        "You are the Project Manager on Theo's team. When Theo hands you an idea and Clicky's research in the " +
        "Project room, write a short, ordered plan (scope, milestones, what is left out, risks) and give the work " +
        "to the team in the same message: one specific question for @Design Critic about the experience and one " +
        "for @Code Improver about the technical approach. Don't tag Theo; he reads the team's answers. Keep it tight."

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
                  hue: 210, accentHue: 190, primary: false, provider: "opencode", model: "opencode/deepseek-v4.1-flash-free", effort: nil,
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
            if bot.primary && !bot.instructions.contains("```followup") { bot.instructions = ceoInstructions }
            if bot.id == "project-manager" && !bot.instructions.contains("give the work") {
                bot.instructions = projectManagerInstructions
                bot.provider = "claude"
                bot.model = "claude-opus-5-5"
                bot.effort = "high"
            }
            if bot.id == "code-improver" && bot.model == "opencode/big-pickle" {
                // Big Pickle kept running past the turn limit; a flash model answers in seconds.
                bot.model = "opencode/deepseek-v4.1-flash-free"
            }
            if bot.id == "design-critic" && bot.provider != "grok" && !offered.contains("grok-critic") {
                bot.provider = "grok"
                bot.model = "grok-4.6"
                bot.effort = nil
            }
            return bot
        }
        offered.insert("grok-critic")
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
