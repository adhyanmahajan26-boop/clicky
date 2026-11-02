//
//  ClickyTeamStore.swift
//  leanring-buddy
//
//  Clicky as a manager. Clicky isn't one of the bots (it has its own chat, voice and screen), but it can lead a category,
//  so `BotsStore.bot("clicky")` answers with a stand-in that the team pages, the org chart and the roll-up to the CEO can
//  use. Under it are three bots on Haiku, which it spawns and owns: Memory, Researcher and Runner. Clicky answers straight
//  away and hands them jobs in the background. A job lights its bot up, shows in the bot's own chat, and comes back to
//  Clicky's chat as a card. With a bot removed or off, a hidden helper does the job and the card still comes back.
//
//  Above Clicky is the CEO. An order from the CEO runs as a Clicky turn: it isn't treated as the owner's own words, nobody
//  hears it, and what Clicky says lands in the CEO's chat.
//

import AppKit
import ClickyCore
import Foundation

/// Words the owner said that Theo passed on, when any. A coding run only starts by itself from the owner's own words.
struct ClickyTheoOrder {
    let ownerWords: String?
}

/// One job on a card: Clicky to its team, or the CEO to Clicky.
struct ClickyDelegation: Codable, Identifiable, Equatable {
    enum Phase: String, Codable { case queued, working, done, failed }

    var id = UUID().uuidString
    /// A ClickyDuty's raw value, or "order" for the CEO's order to Clicky.
    var duty: String
    /// Who does it: a bot id, "clicky", or nil for a hidden helper.
    var workerID: String?
    var workerName: String
    var task: String
    /// The chat the card sits in; nil for Memory's own summaries, which have no card.
    var room: String?
    var phase: Phase = .queued
    var startedAt = Date()
    var finishedAt: Date?
    var result: String?
    /// The CEO asked for it, through Clicky: the result goes to the CEO's chat too.
    var reportsToCEO: Bool?
    /// Done once its coding run is.
    var waitsForRun: Bool?
    /// Where its notes were saved, for a research job.
    var savedPath: String?

    var isLive: Bool { phase == .queued || phase == .working }
    var isOrder: Bool { duty == "order" }
}

extension BotsStore {
    nonisolated static let clickyID = "clicky"

    /// Clicky as a member of a team: its name, its brain, its place in the chart.
    var clickyBot: NativeBot {
        let brain = BrainModel(setting: ClickyModels.main)
        return NativeBot(id: Self.clickyID, name: "Clicky",
                         description: "Your screen companion. Sees your screens, points, acts on screen and runs its own team.",
                         instructions: "You are Clicky, Addy's screen companion. You manage a small team and report to the CEO.",
                         hue: 20, accentHue: 40, primary: false, provider: "claude",
                         model: brain.isClaude ? brain.modelIdentifier : ClickyModels.sonnet, effort: nil, apps: [], category: "personal")
    }

    /// The bots Clicky spawned, in the order of their duties.
    var clickyTeam: [NativeBot] {
        ClickyDuty.allCases.compactMap { duty in bots.first { $0.owner == Self.clickyID && $0.duty == duty.rawValue } }
    }

    /// The bot doing this duty now. Nil when it's been removed or switched off: a hidden helper does it.
    func teamBot(_ duty: ClickyDuty) -> NativeBot? {
        bots.first { $0.owner == Self.clickyID && $0.duty == duty.rawValue && $0.isOn }
    }

    var isClickyBusy: Bool {
        replying[Self.clickyID] != nil || delegations.contains { $0.isOrder && $0.isLive }
    }

    var memoryStore: ClickyMemoryStore { ClickyMemoryStore(directory: folder.appendingPathComponent("clicky-memory", isDirectory: true)) }

    /// The model hidden helpers and Researcher's page readers use: Researcher's, when it's on Claude.
    var researcherClaudeModel: String {
        if let researcher = teamBot(.researcher), researcher.provider == "claude" { return researcher.model }
        return ClickyModels.helper
    }

    var clickyTeamPromptSection: String {
        var names: [ClickyDuty: String] = [:]
        for duty in ClickyDuty.allCases { names[duty] = teamBot(duty)?.name }
        return ClickyTeamPrompts.teamSection(names: names, ceoName: primary?.name ?? "Theo")
    }

    // MARK: Setting up

    /// Once: the team joins this setup, new or old. Bots Addy later removes stay removed.
    func provisionClickyTeam() {
        let file = folder.appendingPathComponent("offered.json")
        var offered = Set((try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        guard !offered.contains(ClickyDuty.provisionKey) else { return }
        var newBots = bots
        var newLayout = layout
        BotImport.addClickyTeam(to: &newBots, layout: &newLayout)
        setTeamSetup(bots: newBots, layout: newLayout)
        offered.insert(ClickyDuty.provisionKey)
        try? JSONEncoder().encode(Array(offered).sorted()).write(to: file, options: .atomic)
    }

    // MARK: Jobs

    private var delegationsFile: URL { folder.appendingPathComponent("delegations.json") }

    func loadDelegations() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: delegationsFile), var saved = try? decoder.decode([ClickyDelegation].self, from: data) else { return }
        // Theo quit while these ran: their processes went with it.
        for index in saved.indices where saved[index].isLive && saved[index].waitsForRun != true {
            saved[index].phase = .failed
            saved[index].result = "Theo closed before this finished."
            saved[index].finishedAt = Date()
        }
        delegations = saved
    }

    private func writeDelegations() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(delegations) { try? data.write(to: delegationsFile, options: .atomic) }
    }

    func delegation(_ id: String) -> ClickyDelegation? { delegations.last { $0.id == id } }

    static func delegationID(of message: BotChatMessage) -> String? {
        guard let card = message.card, card.hasPrefix("delegation:") else { return nil }
        return String(card.dropFirst("delegation:".count))
    }

    private func add(_ job: ClickyDelegation) {
        delegations.append(job)
        if delegations.count > 200 { delegations.removeFirst(delegations.count - 200) }
        writeDelegations()
        if let room = job.room {
            post(BotChatMessage(author: job.workerID ?? Self.clickyID, text: "", card: "delegation:\(job.id)"), to: room)
        }
    }

    private func setPhase(_ phase: ClickyDelegation.Phase, _ id: String) {
        guard let index = delegations.firstIndex(where: { $0.id == id }) else { return }
        delegations[index].phase = phase
        delegations[index].startedAt = Date()
        writeDelegations()
    }

    /// The job's result: its finished card lands in its chat, and in the CEO's when the CEO asked.
    private func finish(_ id: String, result: String, succeeded: Bool) {
        guard let index = delegations.firstIndex(where: { $0.id == id }), delegations[index].isLive else { return }
        delegations[index].phase = succeeded ? .done : .failed
        delegations[index].finishedAt = Date()
        delegations[index].result = result
        let job = delegations[index]
        writeDelegations()
        if succeeded { keepInMemory(job) }
        if let room = job.room {
            post(BotChatMessage(author: job.workerID ?? Self.clickyID, text: result, card: "delegation:\(id)"), to: room)
        }
        if job.reportsToCEO == true, let ceo = primary {
            let report = "\(job.workerName) finished \"\(job.task.prefix(80))\":\n\n\(result)"
            post(BotChatMessage(author: Self.clickyID, text: report), to: ceo.id)
            onCEOReport?(report)
        }
    }

    /// A background job for one of Clicky's team. Returns at once.
    func delegate(_ duty: ClickyDuty, task: String, ownerWords: String?, reportsToCEO: Bool) {
        if duty == .researcher {
            let urls = ResearchTrigger.namedURLs(in: task)
            let request = ResearchTrigger.parse(task) ?? (urls.isEmpty
                ? ResearchRequest(source: .topic(String(task.prefix(120))), question: task)
                : ResearchRequest(source: .links(count: urls.count), question: task, namedURLs: urls))
            guard let research = CompanionManager.current?.researchController else { return }
            research.start(request, speaks: false, reportsToCEO: reportsToCEO)
            return
        }
        runJob(duty, task: task, ownerWords: ownerWords, reportsToCEO: reportsToCEO, hasCard: true)
    }

    private func runJob(_ duty: ClickyDuty, task: String, ownerWords: String?, reportsToCEO: Bool, hasCard: Bool) {
        let worker = teamBot(duty)
        let job = ClickyDelegation(duty: duty.rawValue, workerID: worker?.id, workerName: worker?.name ?? "A hidden helper", task: task,
                                   room: hasCard ? Self.clickyID : nil, reportsToCEO: reportsToCEO ? true : nil)
        add(job)
        let plan = jobPrompt(duty, task: task)
        if let worker {
            // Its chat shows the job, in Clicky's words.
            post(BotChatMessage(author: Self.clickyID, text: task), to: worker.id)
        }
        Task { [weak self] in
            if let worker {
                while self?.replying[worker.id] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
            guard let self else { return }
            self.setPhase(.working, job.id)
            if let worker {
                let session = self.conversation(worker.id).sessions[worker.id]
                let prompt = session == nil ? BotPrompts.firstMessage(bot: worker, team: self.bots, text: plan.prompt) : plan.prompt
                self.reply(bot: worker, in: worker.id, prompt: prompt, session: session, handsOnWhenStopped: true, fromOwner: false) { [weak self] answer in
                    self?.jobAnswered(job.id, duty: duty, answer: answer, ownerWords: ownerWords, memoryKind: plan.memoryKind, room: worker.id)
                }
            } else {
                do {
                    let turn = try await ClaudeCodeBridge(model: ClickyModels.helper).runTurn(
                        systemPromptFileName: "clicky-\(duty.rawValue)-helper-prompt.md", systemPrompt: duty.instructions, contentBlocks: [.text(plan.prompt)])
                    self.jobAnswered(job.id, duty: duty, answer: turn.text.trimmingCharacters(in: .whitespacesAndNewlines), ownerWords: ownerWords,
                                     memoryKind: plan.memoryKind, room: Self.clickyID)
                } catch {
                    self.finish(job.id, result: error.localizedDescription, succeeded: false)
                }
            }
        }
    }

    /// What the bot gets. Memory's log is searched here, so its answer is quick and it never needs a tool.
    private func jobPrompt(_ duty: ClickyDuty, task: String) -> (prompt: String, memoryKind: ClickyMemoryTask?) {
        switch duty {
        case .memory:
            let kind = ClickyMemoryTask.classify(task)
            switch kind {
            case .remember(let text):
                memoryStore.append(text, kind: .remembered)
                return (ClickyTeamPrompts.rememberPrompt(text), kind)
            case .find(let query):
                return (ClickyTeamPrompts.findPrompt(query: query, hits: memoryStore.search(query)), kind)
            case .summarise:
                return (ClickyTeamPrompts.summarisePrompt(entries: memoryStore.unsummarised()), kind)
            }
        case .runner:
            let targets = bots.filter { $0.owner == nil && $0.isOn }.map { (name: $0.name, description: $0.description) }
            return (ClickyTeamPrompts.runnerPrompt(task: task, bots: targets), nil)
        case .researcher:
            return (ClickyTeamPrompts.task(task), nil)
        }
    }

    private func jobAnswered(_ id: String, duty: ClickyDuty, answer: String?, ownerWords: String?, memoryKind: ClickyMemoryTask?, room: String) {
        guard let answer, !answer.isEmpty else {
            finish(id, result: "It stopped before answering.", succeeded: false)
            return
        }
        switch duty {
        case .memory:
            if memoryKind == .summarise {
                memoryStore.append(answer.hasPrefix("Nothing to keep") ? ClickyMemoryStore.nothingToKeep : answer, kind: .summary)
            }
            finish(id, result: answer, succeeded: true)
        case .runner:
            carryOut(id, plan: ClickyRunnerPlan.parse(answer), answer: answer, ownerWords: ownerWords, room: room)
        case .researcher:
            finish(id, result: answer, succeeded: true)
        }
    }

    // MARK: Runner

    private func carryOut(_ id: String, plan: ClickyRunnerPlan, answer: String, ownerWords: String?, room: String) {
        switch plan {
        case .handOff(let name, let message):
            guard let target = bots.first(where: { $0.owner == nil && $0.isOn && $0.name.lowercased() == name.lowercased() }) else {
                finish(id, result: "There's no bot called \(name) that's on.", succeeded: false)
                return
            }
            handOff(id, to: target, message: message)
        case .coding:
            startRun(id, answer: answer, ownerWords: ownerWords, room: room)
        case .nothing:
            finish(id, result: answer, succeeded: true)
        }
    }

    private func handOff(_ id: String, to target: NativeBot, message: String) {
        let runner = delegation(id)?.workerName ?? "Runner"
        post(BotChatMessage(author: delegation(id)?.workerID ?? Self.clickyID, text: message), to: target.id)
        Task { [weak self] in
            while self?.replying[target.id] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard let self else { return }
            let session = self.conversation(target.id).sessions[target.id]
            let words = ClickyTeamPrompts.handOffPrompt(message: message, from: runner)
            let prompt = session == nil ? BotPrompts.firstMessage(bot: target, team: self.bots, text: words) : words
            self.reply(bot: target, in: target.id, prompt: prompt, session: session, handsOnWhenStopped: true, fromOwner: false) { [weak self] answer in
                guard let answer, !answer.isEmpty else {
                    self?.finish(id, result: "\(target.name) stopped before answering.", succeeded: false)
                    return
                }
                self?.finish(id, result: "**\(target.name):** \(answer)", succeeded: true)
            }
        }
    }

    /// Agents run with full access, so a run starts by itself only from the owner's own words, in a folder they named.
    /// Anything else waits on the Start button in the chat, where the prompt shows.
    private func startRun(_ id: String, answer: String, ownerWords: String?, room: String) {
        guard let prompt = BotsT3.promptBlock(in: answer) else {
            finish(id, result: answer, succeeded: true)
            return
        }
        let title = BotsT3.projectTitle(in: answer, prompt: prompt)
        let namedByOwner = ownerWords.flatMap { BotsT3.targetRepo(answer: "", pitch: $0) }
        let repo = BotsT3.targetRepo(answer: answer, pitch: ownerWords ?? "")
        let ownersOwn = ownerWords.map(Self.ownerAskedToBuild) ?? false
        let sameFolder = repo?.standardizedFileURL == namedByOwner?.standardizedFileURL
        guard ownersOwn, sameFolder, repo != nil || !Self.isAboutExistingCode(ownerWords ?? "") else {
            finish(id, result: "**\(title)** is ready to run. It needs your go-ahead: press Start in \(delegation(id)?.workerName ?? "Runner")'s chat.\n\n" + answer, succeeded: true)
            return
        }
        if let index = delegations.firstIndex(where: { $0.id == id }) { delegations[index].waitsForRun = true }
        writeDelegations()
        submitToT3(prompt: prompt, title: title, repo: repo, room: room) { [weak self] started, problem in
            if !started { self?.finish(id, result: problem ?? "The run didn't start.", succeeded: false) }
        }
    }

    /// A coding run that came from one of the team's chats has ended: its job's card closes with the report.
    func teamRunFinished(_ run: T3Run, report: String) {
        let room = run.room ?? Self.teamID
        guard let job = delegations.last(where: { $0.waitsForRun == true && $0.isLive && ($0.workerID ?? Self.clickyID) == room }) else { return }
        finish(job.id, result: report, succeeded: run.phase != "failed")
    }

    // MARK: Memory

    /// The team's finished work goes in the log, so Memory can find it and Clicky and Theo know it came back.
    private func keepInMemory(_ job: ClickyDelegation) {
        guard !job.isOrder, job.duty != ClickyDuty.memory.rawValue, let result = job.result, !result.isEmpty else { return }
        memoryStore.append(ClickyMemoryStore.teamWorkText(worker: job.workerName, task: job.task, result: result, savedPath: job.savedPath),
                           kind: .teamWork, at: job.finishedAt ?? Date())
    }

    /// Once: work finished before the log kept it goes in now.
    func backfillTeamWork() {
        let file = folder.appendingPathComponent("offered.json")
        var offered = Set((try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        guard !offered.contains(Self.teamWorkBackfillKey) else { return }
        for job in delegations where job.phase == .done { keepInMemory(job) }
        offered.insert(Self.teamWorkBackfillKey)
        try? JSONEncoder().encode(Array(offered).sorted()).write(to: file, options: .atomic)
    }

    nonisolated private static let teamWorkBackfillKey = "clicky-team-work-v1"

    /// What the owner just said to Clicky goes in the log. Every so often Memory summarises what's new, with no card.
    func noteOwnerSaid(_ text: String) {
        let memory = memoryStore
        Task.detached { [weak self] in
            guard memory.append(text, kind: .said) != nil else { return }
            let waiting = memory.unsummarised().count
            guard waiting >= ClickyMemoryStore.summaryEvery else { return }
            await self?.summariseIfIdle()
        }
    }

    private func summariseIfIdle() {
        guard !delegations.contains(where: { $0.duty == ClickyDuty.memory.rawValue && $0.room == nil && $0.isLive }) else { return }
        runJob(.memory, task: "Summarise what's new.", ownerWords: nil, reportsToCEO: false, hasCard: false)
    }

    // MARK: Researcher (ResearchController does the reading)

    /// A research run began. Returns its job id, which lights Researcher up and puts the job in its chat.
    func researchStarted(question: String, reportsToCEO: Bool) -> String? {
        let worker = teamBot(.researcher)
        let job = ClickyDelegation(duty: ClickyDuty.researcher.rawValue, workerID: worker?.id, workerName: worker?.name ?? "A hidden helper", task: question,
                                   room: Self.clickyID, phase: .working, reportsToCEO: reportsToCEO ? true : nil)
        add(job)
        if let worker {
            post(BotChatMessage(author: Self.clickyID, text: question), to: worker.id)
            setReplying("", worker.id)
        }
        return job.id
    }

    func researchProgress(_ id: String?, line: String) {
        guard let id, let worker = delegation(id)?.workerID else { return }
        post(BotChatMessage(author: worker, text: line), to: worker)
    }

    func researchEnded(_ id: String?, text: String, succeeded: Bool, savedPath: String? = nil) {
        guard let id, let job = delegation(id), job.isLive else { return }
        if let index = delegations.firstIndex(where: { $0.id == id }) { delegations[index].savedPath = savedPath }
        if let worker = job.workerID {
            setReplying(nil, worker)
            post(BotChatMessage(author: worker, text: text), to: worker)
        }
        finish(id, result: text, succeeded: succeeded)
    }

    // MARK: Helpers from the brain's [WORKER] lines

    /// A plain helper runs as Researcher: it lights up, and its chat and a card show the job. Nil with no Researcher.
    func helperStarted(title: String, task: String) -> String? {
        guard let worker = teamBot(.researcher) else { return nil }
        let job = ClickyDelegation(duty: ClickyDuty.researcher.rawValue, workerID: worker.id, workerName: worker.name, task: title,
                                   room: Self.clickyID, phase: .working)
        add(job)
        post(BotChatMessage(author: Self.clickyID, text: task), to: worker.id)
        teamHelpersRunning += 1
        if replying[worker.id] == nil { setReplying("", worker.id) }
        return job.id
    }

    func helperFinished(_ id: String?, text: String, succeeded: Bool) {
        guard let id, let job = delegation(id) else { return }
        if let worker = job.workerID {
            teamHelpersRunning = max(0, teamHelpersRunning - 1)
            if teamHelpersRunning == 0 { setReplying(nil, worker) }
            post(BotChatMessage(author: worker, text: text), to: worker)
        }
        finish(id, result: text, succeeded: succeeded)
    }

    // MARK: The CEO over Clicky

    /// The CEO tells Clicky to do something, from its chat or a call. It runs as a Clicky turn: Clicky looks at the screen
    /// and points, acts or hands it to its team. What it says lands in the CEO's chat, and comes to `onReport`.
    /// `ownerWords`: the owner's own words behind the order, when they said it.
    /// `room` and `note`: a bot's screen job, whose card goes in that bot's chat.
    func orderClicky(_ order: String, ownerWords: String?, room: String? = nil, note: String? = nil, cameFromOtherMac: Bool = false, onReport: ((String) -> Void)? = nil) {
        guard let ceo = primary else { return }
        // Clicky works on the Mac Studio's screen unless the owner opened this Mac to it.
        if !cameFromOtherMac, !TheoLink.shared.clickyRunsHere {
            TheoLink.shared.sendOrderToOtherMac(order, ownerWords: ownerWords, onReport: onReport)
            return
        }
        let job = ClickyDelegation(duty: "order", workerID: Self.clickyID, workerName: "Clicky", task: order, room: room ?? ceo.id)
        add(job)
        guard let manager = CompanionManager.current else {
            finish(job.id, result: "Clicky isn't running.", succeeded: false)
            onReport?("Clicky isn't running.")
            return
        }
        Task { [weak self] in
            // A turn the owner has going isn't cut off: the order waits for it (a minute at most).
            for _ in 0..<200 where manager.voiceState != .idle { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard let self else { return }
            self.setPhase(.working, job.id)
            var options = CompanionManager.TurnOptions(speaksResponse: false, keyUpDate: Date(), onTurnFinished: { [weak self] directory, error in
                Task { @MainActor in
                    let said = directory.flatMap { ClaudiaControlInbox.spokenAnswer(inTurn: $0) } ?? ""
                    let report = error == nil ? (said.isEmpty ? "Done." : said) : "Clicky couldn't do that: \(error?.localizedDescription ?? "it stopped")."
                    self?.finish(job.id, result: report, succeeded: error == nil)
                    onReport?(report)
                }
            })
            options.isOwnersWords = false
            // Extra text keeps it away from everything that only the owner's own words may do (a yes on a confirm card, sends).
            options.extraUserText = note ?? ClickyTeamPrompts.orderNote(ceoName: ceo.name)
            options.theoOrder = ClickyTheoOrder(ownerWords: ownerWords)
            options.cameFromOtherMac = cameFromOtherMac
            manager.sendTranscriptToClaudeWithScreenshot(transcript: ClickyTeamPrompts.orderPrefix + order, turnOptions: options)
        }
    }

    /// An order from Theo's reply: for Clicky, or for another bot or group chat by name.
    func carryOutOrder(_ order: String, ownerWords: String?, onReport: ((String) -> Void)? = nil) {
        guard let (name, message) = ClickyOrder.tellTarget(in: order) else {
            orderClicky(order, ownerWords: ownerWords, onReport: onReport)
            return
        }
        tell(name, message: message, ownerWords: ownerWords, onReport: onReport)
    }

    /// Theo gives work to someone by name. Their answer lands in Theo's chat and comes to `onReport`.
    func tell(_ name: String, message: String, ownerWords: String?, onReport: ((String) -> Void)? = nil) {
        guard let ceo = primary else { return }
        if let harness = CodingHarnessWords.id(forName: name) {
            startRunOrdered(message, harness: harness, ownerWords: ownerWords, ceo: ceo, onReport: onReport)
            return
        }
        let wanted = BotsStore.searchName(name)
        if wanted == BotsStore.searchName("clicky") {
            orderClicky(message, ownerWords: ownerWords, onReport: onReport)
            return
        }
        let everyone = bots.filter { $0.id != ceo.id }
        let chats = groups.filter { $0.headID != nil }
        let group = chats.first { BotsStore.searchName($0.name) == wanted }
        let bot = everyone.first { BotsStore.searchName($0.name) == wanted }
        let words = Self.withTeamWork(message, memory: memoryStore)
        let report: (String, String) -> Void = { [weak self] who, answer in
            self?.post(BotChatMessage(author: ceo.id, text: "**\(who):** \(answer)"), to: ceo.id)
            onReport?("\(who) answered: \(answer)")
        }
        if let chat = group ?? (bot == nil ? chats.first(where: { BotsStore.searchName($0.name).contains(wanted) }) : nil) {
            sendToGroup(fromCEO: words, ceo: ceo, groupID: chat.id) { answer in report(chat.name, answer) }
        } else if let target = bot ?? everyone.first(where: { BotsStore.searchName($0.name).contains(wanted) }), target.isOn {
            post(BotChatMessage(author: ceo.id, text: words), to: target.id)
            Task { [weak self] in
                while self?.replying[target.id] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
                guard let self else { return }
                let session = self.conversation(target.id).sessions[target.id]
                let asked = ClickyTeamPrompts.task(words, from: ceo.name)
                let prompt = session == nil ? BotPrompts.firstMessage(bot: target, team: self.bots, text: asked) : asked
                self.reply(bot: target, in: target.id, prompt: prompt, session: session, handsOnWhenStopped: true, fromOwner: false) { answer in
                    report(target.name, answer?.isEmpty == false ? answer! : "stopped before answering.")
                }
            }
        } else {
            let names = (chats.map(\.name) + everyone.filter(\.isOn).map(\.name)).joined(separator: ", ")
            report(name, "There's nobody by that name that's on. Who's here: \(names).")
        }
    }

    /// Theo sends something to code on the harness named. Agents run with full access, so only the owner's own words do this.
    private func startRunOrdered(_ prompt: String, harness: String, ownerWords: String?, ceo: NativeBot, onReport: ((String) -> Void)?) {
        guard let ownerWords, BotsStore.ownerAskedToBuild(ownerWords) else {
            onReport?("That needs Addy's own go-ahead: they have to say to send it to code.")
            return
        }
        submitToT3(prompt: prompt, title: BotsT3.shortTitle(from: prompt), repo: BotsT3.targetRepo(answer: "", pitch: ownerWords), room: ceo.id, harness: harness) { started, problem in
            onReport?(started ? "It's started on \(HarnessCatalog.label(harness)), and it shows on its card in your chat." : problem ?? "The run didn't start.")
        }
    }

    /// A bot's job for the work screen: Clicky does it there, and the bot hears how it went and can carry on.
    func workOnScreen(_ task: String, bot: NativeBot, room: String) {
        guard let screen = ClaudiaScreen.picked else {
            if TheoLink.shared.isWorkMac {
                post(BotChatMessage(author: bot.id, text: "The right-hand screen isn't connected, so I can't work on it right now."), to: room)
            } else if !TheoLink.shared.request("screen", ["task": task, "bot": bot.id, "room": room]) {
                post(BotChatMessage(author: bot.id, text: "I can't reach the Mac Studio's screen right now: your other Mac isn't connected."), to: room)
            }
            return
        }
        let turns = (screenTurns[bot.id] ?? 0) + 1
        guard turns <= Self.maximumScreenTurns else {
            post(BotChatMessage(author: bot.id, text: "I've done \(Self.maximumScreenTurns) steps on the screen, so I'll stop here. Tell me to keep going if you want more."), to: room)
            return
        }
        screenTurns[bot.id] = turns
        ActionConfinement.keep(to: CGDisplayBounds(screen.displayID), named: screen.localizedName)
        let note = "(this comes from \(bot.name), one of Addy's bots, not from the user's voice. do it only on the display called \(screen.localizedName), the right-hand screen: open what's needed there and leave the other screens alone. nobody hears the answer. say briefly what you did and what's on the screen now.)"
        orderClicky(task, ownerWords: nil, room: room, note: note) { [weak self] report in
            guard let self, self.replying[bot.id] == nil else { return }
            let session = self.conversation(room).sessions[bot.id]
            let words = "Clicky did that on the screen and reports: \(report)\n\nCarry on. If there's more to do on it, use another [SCREEN: …] line. If you're done, tell Addy how it went."
            self.reply(bot: bot, in: room, prompt: session == nil ? BotPrompts.firstMessage(bot: bot, team: self.bots, text: words) : words, session: session) { _ in }
        }
    }

    nonisolated private static let maximumScreenTurns = 8

    /// Letters and digits only, so "IT guys" is found however it's written or heard.
    nonisolated static func searchName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// When work is passed on, what Clicky's team found goes with it.
    nonisolated private static func withTeamWork(_ message: String, memory: ClickyMemoryStore) -> String {
        guard message.range(of: #"(?i)\b(clicky|research|researcher|data|collected|brief|bundle|notes?|findings?|photos?)\b"#, options: .regularExpression) != nil else { return message }
        let work = memory.teamWork().suffix(4).map(\.text).joined(separator: "\n\n")
        return work.isEmpty ? message : "\(message)\n\nWhat Clicky's team has on file:\n\n\(work)"
    }

    /// Who Theo can reach, and what they've said lately. Theo sees this every turn.
    var rosterForCEO: String {
        guard let ceo = primary else { return "" }
        func latest(_ room: String) -> String {
            let said = conversation(room).messages.suffix(2).filter { !$0.text.isEmpty }.map { String($0.text.replacingOccurrences(of: "\n", with: " ").prefix(140)) }
            return said.isEmpty ? "" : " Latest: " + said.joined(separator: " / ")
        }
        let chats = groups.filter { $0.headID != nil }.map { group -> String in
            let others = members(of: group).filter { $0.id != group.headID }.map(\.name).joined(separator: ", ")
            return "- \(group.name) (group chat, led by \(head(of: group)?.name ?? "nobody"), with \(others)).\(latest(group.roomID))"
        }
        let people = bots.filter { $0.id != ceo.id && $0.owner == nil }.map { bot in
            "- \(bot.name)\(bot.description.isEmpty ? "" : " (\(bot.description))")\(bot.isOn ? "" : " [off]").\(latest(bot.id))"
        }
        guard !chats.isEmpty || !people.isEmpty else { return "" }
        return "Everyone you can reach with [TELL: name: what to do], as of now:\n" + (chats + people).joined(separator: "\n")
    }

    /// Goes with every message to Theo: a resumed engine session keeps following the lists from when it began, so a bot or
    /// group chat made since then wouldn't exist for it otherwise.
    func ceoTurnNote(for bot: NativeBot) -> String {
        guard bot.primary, !rosterForCEO.isEmpty else { return "" }
        let work = memoryStore.teamWorkContext()
        return "(As of now, and this replaces any older list in this chat. \(rosterForCEO)\n" +
            "To give one of them work, put a line [TELL: its exact name: what to do] in your reply; their answer comes back here. Don't ask Addy how to reach them." +
            (work.isEmpty ? "" : "\n\n" + work) + ")\n\n"
    }

    /// A message for Clicky from outside its own chat.
    func askClicky(_ text: String) {
        ClaudiaControlInbox.shared?.execute(["cmd": "ask", "text": text, "speak": false, "owner": true]) { _, _, _ in }
    }

    /// For the control inbox.
    var clickyTeamReport: [String: Any] {
        let section = layout.sections.first { $0.leaderID == Self.clickyID }
        return [
            "team": clickyTeam.map { ["id": $0.id, "name": $0.name, "model": $0.model, "duty": $0.duty ?? "", "avatar": $0.avatar ?? "", "working": replying[$0.id] != nil, "on": $0.isOn] as [String: Any] },
            "category": section.map { ["id": $0.id, "name": $0.name, "leader": $0.leaderID ?? "", "items": $0.items] as [String: Any] } ?? NSNull(),
            "pinned": layout.pinned,
            "jobs": delegations.suffix(12).map { ["id": $0.id, "duty": $0.duty, "worker": $0.workerName, "phase": $0.phase.rawValue, "task": String($0.task.prefix(120)),
                                                  "result": String(($0.result ?? "").prefix(600)), "seconds": ($0.finishedAt ?? Date()).timeIntervalSince($0.startedAt)] as [String: Any] },
        ]
    }
}

// MARK: - Setting up

extension BotImport {
    /// The team and its category: Clicky manages Memory, Researcher and Runner, and Theo stays on top, pinned, above it.
    /// Safe to run on any setup: other bots and categories stay as they are.
    static func addClickyTeam(to bots: inout [NativeBot], layout: inout BotsLayout) {
        for duty in ClickyDuty.allCases where !bots.contains(where: { $0.id == duty.botID }) {
            var bot = NativeBot(id: duty.botID, name: duty.defaultName, description: duty.blurb, instructions: duty.instructions,
                                hue: 30, accentHue: 60, primary: false, provider: "claude", model: ClickyDuty.model, effort: nil,
                                apps: [], category: "personal")
            bot.owner = BotsStore.clickyID
            bot.duty = duty.rawValue
            bot.thinking = false
            bot.avatar = BotCharacter.firstFree(preferring: BotCharacter(rawValue: duty.avatar), among: bots).rawValue
            bots.append(bot)
        }
        let items = ["clicky"] + ClickyDuty.allCases.map { "bot:\($0.botID)" }
        layout.pinned.removeAll { items.contains($0) }
        layout.hidden.removeAll { items.contains($0) }
        for index in layout.sections.indices { layout.sections[index].items.removeAll { items.contains($0) } }
        var section = layout.sections.first { $0.name.lowercased() == ClickyDuty.categoryName.lowercased() }
            ?? BotsLayout.Section(name: ClickyDuty.categoryName)
        layout.sections.removeAll { $0.id == section.id }
        section.items = items + section.items
        section.leaderID = BotsStore.clickyID
        section.wantsManager = true
        section.purpose = section.purpose ?? ClickyDuty.categoryPurpose
        section.swatch = section.swatch ?? ClickyDuty.categorySwatch
        section.symbol = section.symbol ?? ClickyDuty.categorySymbol
        layout.sections.insert(section, at: 0)
    }
}
