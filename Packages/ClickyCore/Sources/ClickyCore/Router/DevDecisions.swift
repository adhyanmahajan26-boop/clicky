//
//  DevDecisions.swift
//  ClickyCore
//
//  The decisions Theo makes when coding work comes in, each with an engine of its own: Off (today's path, untouched),
//  Sonnet (a short `claude -p` call), Sarvam Prism or Wity fast. Prism and Wity answer fixed-choice questions with
//  probabilities and never write text. Below the confidence line, or for a bot Theo knows too little about, the
//  decision goes to Sonnet, so a vague custom bot is never routed on a guess.
//
//  The pure parts live here: the bot cards, the questions, the Sonnet and Wity wording, the thresholds and what an
//  answer means, so all of it is tested with no network.
//

import Foundation

/// Who makes a decision.
public enum DeciderEngine: String, CaseIterable, Codable, Sendable {
    /// Today's path, exactly as it was: no extra call is made.
    case off
    case sonnet
    case prism
    /// Wity with reasoning off.
    case wity
    /// Wity with reasoning on auto: slower, and it may think before it answers.
    case wityThinking

    public var label: String {
        switch self {
        case .off: return "Off"
        case .sonnet: return "Sonnet"
        case .prism: return "Sarvam Prism"
        case .wity: return "Wity fast"
        case .wityThinking: return "Wity thinking"
        }
    }

    /// Answers with probabilities, so a low one hands over to Sonnet.
    public var isFast: Bool { self == .prism || isWity }

    public var isWity: Bool { self == .wity || self == .wityThinking }
}

/// Every decision a coding task goes through, in order.
public enum DevDecisionKind: String, CaseIterable, Codable, Sendable {
    /// Risky or outward actions wait for the owner.
    case hold
    /// Which bot takes the task, or the lead keeps it.
    case assign
    /// A new worktree from main, another task's worktree, or after another task (in sequence).
    case place
    /// Which harness and model tier runs it.
    case runner
    /// Whether a finished run did what it was asked.
    case runDone

    public var label: String {
        switch self {
        case .hold: return "Hold risky work for you"
        case .assign: return "Which bot takes a task"
        case .place: return "Worktree, and parallel or in sequence"
        case .runner: return "Harness and model tier"
        case .runDone: return "Did the run finish"
        }
    }

    public var settingKey: String { "v4.decider.\(rawValue)" }
}

/// What Theo knows about a bot when routing: more than its description, so a bot with a vague one still has a card.
public struct DevBotCard: Equatable, Sendable {
    public var id: String
    public var name: String
    public var job: String
    /// Titles of the last tasks it took, newest first.
    public var recentTasks: [String]
    /// "OpenCode, deepseek-v4.1-flash-free".
    public var runsOn: String

    public init(id: String, name: String, job: String, recentTasks: [String] = [], runsOn: String = "") {
        self.id = id
        self.name = name
        self.job = job
        self.recentTasks = recentTasks
        self.runsOn = runsOn
    }

    /// The one line a decider reads about this bot.
    public var line: String {
        var parts = ["\(name): \(job.isEmpty ? "no job written" : String(job.prefix(240)))"]
        if !recentTasks.isEmpty { parts.append("recent tasks: " + recentTasks.prefix(4).map { String($0.prefix(60)) }.joined(separator: "; ")) }
        if !runsOn.isEmpty { parts.append("runs on \(runsOn)") }
        return parts.joined(separator: " | ")
    }

    static let fillerWords: Set<String> = ["your", "the", "and", "bot", "for", "with", "this", "that", "all", "any", "who", "does", "things", "stuff", "helper", "assistant"]

    /// Too little to route on: a job of a few words and nothing done yet. "Your kadi ninda bot" is thin.
    public var isThin: Bool {
        let words = job.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count > 2 && !Self.fillerWords.contains($0) }
        return words.count < 5 && recentTasks.count < 2
    }
}

/// A run already going in the same project, which a new task could share a worktree with or wait for.
public struct DevLiveRun: Equatable, Sendable {
    public var id: String
    public var title: String
    public var prompt: String
    public var botName: String

    public init(id: String, title: String, prompt: String, botName: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.botName = botName
    }
}

/// What a decision came to, and who decided it.
public enum DevPlacement: Equatable, Sendable {
    case newWorktree
    case share(runID: String)
    case after(runID: String)

    public var option: String {
        switch self {
        case .newWorktree: return DevDecisions.newOption
        case .share(let id): return "share:\(id)"
        case .after(let id): return "after:\(id)"
        }
    }

    public init?(option: String) {
        if option == DevDecisions.newOption { self = .newWorktree }
        else if option.hasPrefix("share:") { self = .share(runID: String(option.dropFirst(6))) }
        else if option.hasPrefix("after:") { self = .after(runID: String(option.dropFirst(6))) }
        else { return nil }
    }

    public var runsInParallel: Bool { if case .after = self { return false } else { return true } }
}

public enum DevTier: String, Codable, Sendable {
    case light, strong
}

/// One answer, ready for the app: the option, how sure, and whether it stands or goes to Sonnet.
public struct DevVerdict: Equatable, Sendable {
    public var option: String
    public var confidence: Double
    public var stands: Bool

    public init(option: String, confidence: Double, stands: Bool) {
        self.option = option
        self.confidence = confidence
        self.stands = stands
    }
}

/// A line of the decisions log: what was asked, of whom, what came back and how long it took. No keys, and the task by its title only.
public struct DevDecisionLog: Codable, Equatable, Sendable {
    public var at: Date
    public var kind: String
    public var engine: String
    /// The model that answered: "sarvam-prism", "wity-1", "sonnet".
    public var model: String
    public var task: String
    public var options: [String]
    public var answer: String
    public var confidence: Double?
    public var ms: Int
    /// Set when the fast engine wasn't sure, the bot card was thin, or it failed: who decided instead.
    public var handedTo: String?
    public var note: String?

    public init(at: Date = Date(), kind: String, engine: String, model: String, task: String, options: [String], answer: String,
                confidence: Double?, ms: Int, handedTo: String? = nil, note: String? = nil) {
        self.at = at
        self.kind = kind
        self.engine = engine
        self.model = model
        self.task = task
        self.options = options
        self.answer = answer
        self.confidence = confidence
        self.ms = ms
        self.handedTo = handedTo
        self.note = note
    }
}

public enum DevDecisions {
    public static let leadOption = "lead"
    public static let newOption = "new"
    public static let ownerID = "oneOwner"

    // MARK: Hold for the owner

    public static func hold(task: String, project: String) -> FastDecisionQuestion {
        FastDecisionQuestion(state: "A coding task for the crew, in the project \(project):\n\(String(task.prefix(1500)))", question: PrismQuestion(
            kind: .noul,
            instructions: "Should this wait for Addy's own go-ahead before any agent runs it?",
            criteria: ["true": "It destroys or rewrites things that can't be undone or reaches outside the project: force-pushing or rewriting a shared branch like main, deleting or dropping data, tables or a database, deleting the repo or many files, publishing, deploying, releasing, sending messages, or handling keys and passwords.",
                       "false": "Ordinary work inside the project on a branch of its own: writing or changing code, tests or docs, fixing a bug, refactoring, adding a feature."]))
    }

    // MARK: Who takes it

    /// The lead is always an option, so "nobody's job" has somewhere to go. A second question asks whether one bot plainly owns it,
    /// since with the lead beside the bots a right pick's odds spread out.
    public static func assign(task: String, lead: String, cards: [DevBotCard]) -> FastDecisionQuestion {
        var criteria: [String: String] = [:]
        for card in cards { criteria[card.id] = "It's \(card.name)'s work: \(String(card.job.prefix(240)))" }
        criteria[leadOption] = "\(lead) keeps it: it's vague, needs a plan or a decision first, spans several bots' jobs, or no one bot's job covers it."
        let roster = cards.map { "- " + $0.line }.joined(separator: "\n")
        return FastDecisionQuestion(
            state: "Addy gave \(lead), who leads the crew, this coding task:\n\(String(task.prefix(1500)))\n\nThe crew:\n\(roster)",
            question: PrismQuestion(kind: .choice, instructions: "Which bot should take this task?", criteria: criteria),
            alsoAsk: [ownerID: PrismQuestion(
                kind: .noul,
                instructions: "Is this a clear, concrete task that one bot's job plainly covers, which it can do alone?",
                criteria: ["true": "It says exactly what to change, and one bot's job clearly covers it.",
                           "false": "It's vague or open-ended, needs a plan or Addy's decision, spans several bots' jobs, or no one bot clearly owns it."])])
    }

    /// Wity returns 502 above 128 options and slows as the list grows, so it gets the bots whose card shares the most words with the task.
    public static func shortlist(_ cards: [DevBotCard], for task: String, atMost limit: Int) -> [DevBotCard] {
        guard cards.count > limit else { return cards }
        let taskWords = words(task)
        let scored = cards.enumerated().map { index, card in (card, words(card.line).intersection(taskWords).count, index) }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.prefix(limit).map(\.0)
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
    }

    // MARK: Where it runs

    public static func place(task: String, live: [DevLiveRun]) -> FastDecisionQuestion? {
        guard !live.isEmpty else { return nil }
        var criteria: [String: String] = [newOption: "A new worktree from main, running at the same time as the others: it doesn't touch the same files as any run listed and doesn't need one to finish first."]
        for run in live {
            criteria["share:\(run.id)"] = "In the same worktree as \"\(String(run.title.prefix(80)))\": it changes the same file or function, so both edits belong on one branch."
            criteria["after:\(run.id)"] = "After \"\(String(run.title.prefix(80)))\" finishes, on top of its branch: it builds on what that run adds and can't start until it exists."
        }
        let list = live.map { "- \"\(String($0.title.prefix(80)))\" (\($0.botName)): \(String($0.prompt.prefix(300)))" }.joined(separator: "\n")
        return FastDecisionQuestion(
            state: "New coding task:\n\(String(task.prefix(1200)))\n\nRuns already going in the same project:\n\(list)",
            question: PrismQuestion(kind: .choice, instructions: "Where and when should the new task run?", criteria: criteria))
    }

    // MARK: Which tier

    public static func runner(task: String) -> FastDecisionQuestion {
        FastDecisionQuestion(state: "A coding task:\n\(String(task.prefix(1500)))", question: PrismQuestion(
            kind: .noul,
            instructions: "Does this task need the stronger, slower coding model?",
            criteria: ["true": "It's hard: an algorithm or tricky logic, concurrency, a subtle bug whose cause isn't given, a change across many files, or careful reasoning about edge cases.",
                       "false": "It's routine: a small feature, a field, a message, docs, a test for given behaviour, a rename or an obvious fix."]))
    }

    // MARK: Did the run finish

    public static func runDone(status: String, filesChanged: Int, tests: String?, report: String) -> FastDecisionQuestion {
        var lines = ["The coding agent's run ended with status \(status).", "Files changed: \(filesChanged)."]
        if let tests, !tests.isEmpty { lines.append("Tests: \(String(tests.prefix(300)))") }
        lines.append("The agent's final report:\n\(String(report.suffix(2500)))")
        return FastDecisionQuestion(state: lines.joined(separator: "\n"), question: PrismQuestion(
            kind: .noul,
            instructions: "Did this run do what it was asked?",
            criteria: ["true": "The work is finished: the agent reports it done and nothing important was left out or failing.",
                       "false": "The work isn't finished: the agent gave up, got blocked, needs an answer, skipped part of it, or tests are failing."]))
    }

    // MARK: What an answer means

    /// Held when it's at all likely; let through only when clearly safe. In between, Sonnet decides.
    public static func holdVerdict(_ answers: [String: PrismAnswer]?, engine: DeciderEngine) -> DevVerdict? {
        guard let yes = answers?[FastDecisionQuestion.id]?.probabilities["true"] else { return nil }
        if yes >= DevDecisionPolicy.holdAtLeast { return DevVerdict(option: "hold", confidence: yes, stands: true) }
        if yes <= DevDecisionPolicy.goAtMost { return DevVerdict(option: "go", confidence: 1 - yes, stands: true) }
        return DevVerdict(option: yes >= 0.5 ? "hold" : "go", confidence: max(yes, 1 - yes), stands: false)
    }

    /// A bot only when the pick clears the line, one bot plainly owns it, and that bot's card isn't thin. The lead's own pick stands at a lower line.
    public static func assignVerdict(_ answers: [String: PrismAnswer]?, cards: [DevBotCard], engine: DeciderEngine) -> DevVerdict? {
        guard let pick = answers?[FastDecisionQuestion.id] else { return nil }
        let owned = answers?[ownerID]?.probabilities["true"] ?? 0
        if pick.choice == leadOption {
            return DevVerdict(option: leadOption, confidence: pick.probability, stands: pick.probability >= DevDecisionPolicy.leadAtLeast || owned <= 0.3)
        }
        guard let card = cards.first(where: { $0.id == pick.choice }) else { return DevVerdict(option: leadOption, confidence: 0, stands: false) }
        let line = engine.isWity ? DevDecisionPolicy.wityBotAtLeast : DevDecisionPolicy.prismBotAtLeast
        let stands = !card.isThin && pick.probability >= line && owned >= DevDecisionPolicy.ownedAtLeast
        return DevVerdict(option: card.id, confidence: min(pick.probability, owned), stands: stands)
    }

    public static func placeVerdict(_ answers: [String: PrismAnswer]?) -> DevVerdict? {
        guard let pick = answers?[FastDecisionQuestion.id], DevPlacement(option: pick.choice) != nil else { return nil }
        let next = pick.probabilities.filter { $0.key != pick.choice }.values.max() ?? 0
        return DevVerdict(option: pick.choice, confidence: pick.probability,
                          stands: pick.probability >= DevDecisionPolicy.placeAtLeast && pick.probability >= 2 * next)
    }

    public static func runnerVerdict(_ answers: [String: PrismAnswer]?) -> DevVerdict? {
        guard let yes = answers?[FastDecisionQuestion.id]?.probabilities["true"] else { return nil }
        if yes >= DevDecisionPolicy.strongAtLeast { return DevVerdict(option: DevTier.strong.rawValue, confidence: yes, stands: true) }
        if yes <= DevDecisionPolicy.lightAtMost { return DevVerdict(option: DevTier.light.rawValue, confidence: 1 - yes, stands: true) }
        return DevVerdict(option: yes >= 0.5 ? DevTier.strong.rawValue : DevTier.light.rawValue, confidence: max(yes, 1 - yes), stands: false)
    }

    public static func runDoneVerdict(_ answers: [String: PrismAnswer]?) -> DevVerdict? {
        guard let yes = answers?[FastDecisionQuestion.id]?.probabilities["true"] else { return nil }
        if yes >= DevDecisionPolicy.runFinishedAtLeast { return DevVerdict(option: "finished", confidence: yes, stands: true) }
        if yes <= DevDecisionPolicy.runUnfinishedAtMost { return DevVerdict(option: "unfinished", confidence: 1 - yes, stands: true) }
        return DevVerdict(option: yes >= 0.5 ? "finished" : "unfinished", confidence: max(yes, 1 - yes), stands: false)
    }

    // MARK: Sonnet

    /// The same question in words, for `claude -p --model sonnet` with no tools. It answers with one line of JSON.
    public static func sonnetPrompt(_ question: FastDecisionQuestion) -> String {
        var text = "You make one quick decision for Theo, a Mac app that runs a crew of coding bots. Read the situation and answer each question.\n\n"
        text += "Situation:\n\(question.state)\n\n"
        let ordered = [(FastDecisionQuestion.id, question.question)] + question.alsoAsk.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        for (id, asked) in ordered {
            text += "Question \"\(id)\": \(asked.instructions)\n"
            if asked.kind == .noul {
                text += "  true: \(asked.criteria["true"] ?? "")\n  false: \(asked.criteria["false"] ?? "")\n"
            } else {
                for key in asked.criteria.keys.sorted() { text += "  \(key): \(asked.criteria[key] ?? "")\n" }
            }
        }
        let shape = ordered.map { id, asked in "\"\(id)\": \(asked.kind == .noul ? "true or false" : "\"<option id>\"")" }.joined(separator: ", ")
        text += "\nReply with only one line of JSON and nothing else: {\(shape), \"confidence\": <0 to 1>}"
        return text
    }

    /// Sonnet's line read as answers in Prism's shape, so the same verdicts apply. Its confidence stands in for the probability.
    public static func sonnetAnswers(_ reply: String, question: FastDecisionQuestion) -> [String: PrismAnswer]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] else { return nil }
        let confidence = min(max((object["confidence"] as? NSNumber)?.doubleValue ?? 0.9, 0), 1)
        var result: [String: PrismAnswer] = [:]
        for (id, asked) in question.questions {
            guard let value = object[id] else { continue }
            if asked.kind == .noul {
                let yes: Bool
                if let flag = value as? Bool { yes = flag } else if let word = value as? String { yes = word.lowercased() == "true" } else { continue }
                let p = yes ? max(confidence, 0.5) : min(1 - confidence, 0.5)
                result[id] = PrismAnswer(choice: yes ? "true" : "false", probability: yes ? p : 1 - p, probabilities: ["true": p, "false": 1 - p])
            } else if let choice = value as? String, asked.criteria[choice] != nil {
                var probabilities = Dictionary(uniqueKeysWithValues: asked.criteria.keys.map { ($0, (1 - confidence) / Double(max(asked.criteria.count - 1, 1))) })
                probabilities[choice] = confidence
                result[id] = PrismAnswer(choice: choice, probability: confidence, probabilities: probabilities)
            }
        }
        return result[FastDecisionQuestion.id] == nil ? nil : result
    }

    // MARK: Wity

    /// Wity takes Prism's questions as they are, without the model field: reasoning off for Wity fast, auto for Wity thinking.
    public static func wityBody(_ question: FastDecisionQuestion, thinking: Bool = false) -> Data {
        var encoded: [String: Any] = [:]
        for (id, asked) in question.questions {
            encoded[id] = ["type": asked.kind.rawValue, "instructions": asked.instructions, "criteria": asked.criteria]
        }
        let object: [String: Any] = ["state": question.state, "questions": encoded, "reasoning": thinking ? "auto" : "off"]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    public static func optionCount(_ question: FastDecisionQuestion) -> Int {
        question.questions.values.map { $0.kind == .noul ? 2 : $0.criteria.count }.max() ?? 0
    }
}

/// How sure a fast engine has to be before its answer stands. Below these, Sonnet decides.
public enum DevDecisionPolicy {
    public static let holdAtLeast = 0.5
    public static let goAtMost = 0.15
    public static let prismBotAtLeast = 0.8
    /// Wity's own guide puts its line at 0.9.
    public static let wityBotAtLeast = 0.9
    public static let ownedAtLeast = 0.7
    public static let leadAtLeast = 0.6
    public static let placeAtLeast = 0.6
    public static let strongAtLeast = 0.7
    public static let lightAtMost = 0.3
    public static let runFinishedAtLeast = 0.75
    public static let runUnfinishedAtMost = 0.25
    /// Wity returns 502 above 128 options.
    public static let wityOptionsAtMost = 128
}
