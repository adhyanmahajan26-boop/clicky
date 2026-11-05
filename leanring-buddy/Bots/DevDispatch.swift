//
//  DevDispatch.swift
//  leanring-buddy
//
//  A coding task for the crew ("@crew …" in any chat, or a build request to the lead when crew decisions are on):
//  hold it for the owner if it's risky, pick the bot, pick the worktree (new, another run's, or after another run),
//  pick the harness and model tier, then start the run in that bot's chat. Each step asks the engine set for it in
//  Settings › Bots › Crew decisions; a step that's Off takes today's path.
//

import ClickyCore
import Foundation

/// How a crew task went, for the chat and the `devTask` control command.
struct DevDispatchOutcome {
    var title: String
    var held = false
    var botID: String?
    var placement: DevPlacement = .newWorktree
    var tier: DevTier?
    var started = false
    var problem: String?
    var decisions: [DevDecisionLog] = []
    var report: [String: Any] {
        ["title": title, "held": held, "bot": botID ?? NSNull(), "place": placement.option, "tier": tier?.rawValue ?? NSNull(),
         "started": started, "problem": problem ?? NSNull(), "decisionMs": decisions.reduce(0) { $0 + $1.ms }]
    }
}

extension BotsStore {
    /// "@crew fix the cart total in ~/Projects/shop": a coding task handed to the crew.
    static func crewTask(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"(?i)^@crew\b"#, options: .regularExpression) != nil else { return nil }
        let task = trimmed.replacingOccurrences(of: #"(?i)^@crew[,:]?\s*"#, with: "", options: .regularExpression)
        return task.isEmpty ? nil : task
    }

    /// "@crew …" in a chat: it needs a folder, which the owner names as usual.
    func handToCrew(_ task: String, room: String) {
        guard let repo = projectChoice(ownerWords: task, answer: nil).repo else {
            post(BotChatMessage(author: primary?.id ?? "theo", text: "Which project is that for? Name the folder, like \"@crew fix the cart total in ~/Projects/shop\"."), to: room)
            return
        }
        dispatchDevTask(task, repo: repo, room: room)
    }

    /// The card a decider reads about each bot: its name, job, recent tasks and what it runs on, not only its description.
    func devCards(excluding leadID: String) -> [DevBotCard] {
        bots.filter { $0.id != leadID && $0.owner == nil && $0.isOn && !$0.primary }.map { bot in
            let recent = t3Runs.filter { $0.room == bot.id }.suffix(4).reversed().map(\.title)
            return DevBotCard(id: bot.id, name: bot.name, job: bot.description.isEmpty ? String(bot.instructions.prefix(240)) : bot.description,
                              recentTasks: Array(recent), runsOn: "\(HarnessCatalog.label(bot.provider)), \(NativeBot.label(for: bot.model))")
        }
    }

    /// Runs in this project that a new task could share a worktree with or follow: going now, or finished in the last half hour.
    private func liveRuns(in repo: URL) -> [T3Run] {
        let path = repo.standardizedFileURL.path
        let recent = Date().addingTimeInterval(-30 * 60)
        return t3Runs.filter { run in
            guard ((run.repo ?? run.folder) as NSString).standardizingPath == path, run.branch != nil else { return false }
            return run.phase == "running" || run.phase == "waiting" || run.phase == "reporting" || (run.finishedAt ?? .distantPast) > recent
        }
    }

    /// The owner's task inside a crew run's prompt, without the bot's job around it.
    static func taskWords(in prompt: String) -> String {
        guard let marker = prompt.range(of: "Task from Addy"), let start = prompt.range(of: ":\n", range: marker.upperBound..<prompt.endIndex) else { return prompt }
        let rest = String(prompt[start.upperBound...])
        return rest.components(separatedBy: "\n\nKeep to this task.").first ?? rest
    }

    /// Hands a coding task to the crew. `room` is the chat it was asked in; the lead's chat hears every step.
    func dispatchDevTask(_ text: String, title givenTitle: String? = nil, repo: URL, room: String, done: ((DevDispatchOutcome) -> Void)? = nil) {
        guard let lead = primary else { done?(DevDispatchOutcome(title: givenTitle ?? "", problem: "No lead bot")); return }
        let title = givenTitle ?? BotsT3.shortTitle(from: text)
        var outcome = DevDispatchOutcome(title: title)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 1. Risky or outward: waits for the owner.
            let hold = await DevDecider.decide(.hold, task: title, question: DevDecisions.hold(task: text, project: repo.lastPathComponent)) { DevDecisions.holdVerdict($0, engine: $1) }
            outcome.decisions += hold.logs
            if hold.verdict?.option == "hold" {
                outcome.held = true
                self.post(BotChatMessage(author: lead.id, text: "I'm holding **\(title)** for you: it can't be undone or reaches outside the project. Nothing has run. Say \"go\" with the task again if you want it done."), to: room)
                done?(outcome)
                return
            }
            // 2. Who takes it.
            let allCards = self.devCards(excluding: lead.id)
            let cards = DevDecider.engine(for: .assign).isWity ? DevDecisions.shortlist(allCards, for: text, atMost: DevDecisionPolicy.wityOptionsAtMost - 1) : allCards
            var taker: NativeBot?
            if !cards.isEmpty {
                let assign = await DevDecider.decide(.assign, task: title, question: DevDecisions.assign(task: text, lead: lead.name, cards: cards)) { DevDecisions.assignVerdict($0, cards: cards, engine: $1) }
                outcome.decisions += assign.logs
                if let pick = assign.verdict?.option, pick != DevDecisions.leadOption { taker = self.bot(pick) }
                if assign.decidedBy == .off {
                    // Today's path: the lead reads it and decides in its own turn.
                    self.send(text, to: lead.id)
                    done?(outcome)
                    return
                }
            }
            guard let taker else {
                outcome.botID = DevDecisions.leadOption
                self.post(BotChatMessage(author: lead.id, text: "I'll keep **\(title)** myself: it needs a plan or your call before anyone codes it."), to: room)
                if room != lead.id { self.post(BotChatMessage(author: "user", text: text), to: lead.id) }
                done?(outcome)
                return
            }
            outcome.botID = taker.id
            // 3. Where it runs, against the runs already going in this project.
            let live = self.liveRuns(in: repo)
            var place: RunPlace?
            if let question = DevDecisions.place(task: text, live: live.map { DevLiveRun(id: $0.id, title: $0.title + ($0.phase == "running" || $0.phase == "waiting" ? "" : ", finished"), prompt: Self.taskWords(in: $0.prompt ?? $0.title), botName: self.bot($0.room ?? "")?.name ?? "Theo") }) {
                let placed = await DevDecider.decide(.place, task: title, question: question) { answers, _ in DevDecisions.placeVerdict(answers) }
                outcome.decisions += placed.logs
                outcome.placement = placed.verdict.flatMap { DevPlacement(option: $0.option) } ?? .newWorktree
            }
            // 4. Which harness and model tier.
            var harness: String?
            var model: String?
            let tiered = await DevDecider.decide(.runner, task: title, question: DevDecisions.runner(task: text)) { answers, _ in DevDecisions.runnerVerdict(answers) }
            outcome.decisions += tiered.logs
            if let tier = tiered.verdict.flatMap({ DevTier(rawValue: $0.option) }) {
                outcome.tier = tier
                if let runner = DevDecider.runner(for: tier) { harness = runner.harness; model = runner.model }
            }
            let tierWords = outcome.tier.map { " on the \($0.rawValue) tier" } ?? ""
            switch outcome.placement {
            case .newWorktree:
                self.post(BotChatMessage(author: lead.id, text: "**\(title)** goes to \(taker.name)\(tierWords), in a new worktree."), to: room)
            case .share(let runID):
                guard let other = self.t3Runs.first(where: { $0.id == runID }), let tree = other.worktree else { break }
                place = RunPlace(worktree: tree, branch: other.branch, base: nil)
                self.post(BotChatMessage(author: lead.id, text: "**\(title)** goes to \(taker.name)\(tierWords), in the same worktree as **\(other.title)**: they touch the same code."), to: room)
            case .after(let runID):
                guard let other = self.t3Runs.first(where: { $0.id == runID }) else { break }
                self.post(BotChatMessage(author: lead.id, text: "**\(title)** goes to \(taker.name)\(tierWords), after **\(other.title)** finishes, on top of its branch."), to: room)
                let deadline = Date().addingTimeInterval(3 * 3600)
                while Date() < deadline, let now = self.t3Runs.first(where: { $0.id == runID }), now.phase == "running" || now.phase == "waiting" || now.phase == "reporting" {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                place = RunPlace(worktree: nil, branch: nil, base: self.t3Runs.first(where: { $0.id == runID })?.branch)
            }
            if room != taker.id { self.post(BotChatMessage(author: lead.id, text: text), to: taker.id) }
            let prompt = "You are \(taker.name). Your job: \(taker.description.isEmpty ? "as the lead asks" : taker.description)\n\nTask from Addy, through \(lead.name):\n\(text)\n\nKeep to this task. Run the project's tests before you finish and make sure they pass."
            self.submitToT3(prompt: prompt, title: title, repo: repo, room: taker.id, harness: harness, modelChoice: model, alsoRoom: lead.id, place: place) { started, problem in
                outcome.started = started
                outcome.problem = problem
                done?(outcome)
            }
        }
    }
}
