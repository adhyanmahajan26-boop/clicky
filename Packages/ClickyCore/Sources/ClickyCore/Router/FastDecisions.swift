//
//  FastDecisions.swift
//  ClickyCore
//
//  Quick fixed-choice decisions on Sarvam Prism (POST /v2/systemone), a model that answers with probabilities and
//  never writes text. It only ever decides which path a message takes: Claude still does the work, and anything Prism
//  isn't sure of goes down the path it would have gone anyway. The pure parts live here: the questions, the wire
//  format and the thresholds, so all of it can be tested with no network.
//

import Foundation

public struct PrismQuestion: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case noul, choice
    }
    public var kind: Kind
    public var instructions: String
    public var criteria: [String: String]

    public init(kind: Kind, instructions: String, criteria: [String: String]) {
        self.kind = kind
        self.instructions = instructions
        self.criteria = criteria
    }
}

public struct PrismAnswer: Equatable, Sendable {
    /// The option Prism picked. `noul` answers say "true" or "false".
    public var choice: String
    /// How likely that option is, from 0 to 1.
    public var probability: Double
    /// Every option's probability. A `noul` answer has "true" and "false".
    public var probabilities: [String: Double]

    public init(choice: String, probability: Double, probabilities: [String: Double]) {
        self.choice = choice
        self.probability = probability
        self.probabilities = probabilities
    }
}

public struct PrismFailure: Error, Equatable, LocalizedError, Sendable {
    public var status: Int
    public var message: String
    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
    public var errorDescription: String? { "Prism \(status): \(message)" }
}

public enum PrismWire {
    public static let model = "sarvam-prism"
    public static let path = "v2/systemone"

    public static func body(state: String, questions: [String: PrismQuestion]) -> Data {
        var encoded: [String: Any] = [:]
        for (id, question) in questions {
            encoded[id] = ["type": question.kind.rawValue, "instructions": question.instructions, "criteria": question.criteria]
        }
        let object: [String: Any] = ["model": model, "state": state, "questions": encoded]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The answers by question id. A `noul` comes back as one number, the chance of yes, and is turned into a pick here.
    public static func answers(from data: Data) -> [String: PrismAnswer]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: [String: Any]] else { return nil }
        var result: [String: PrismAnswer] = [:]
        for (id, answer) in answers {
            if let yes = (answer["noul"] as? NSNumber)?.doubleValue {
                let isYes = yes >= 0.5
                result[id] = PrismAnswer(choice: isYes ? "true" : "false", probability: isYes ? yes : 1 - yes, probabilities: ["true": yes, "false": 1 - yes])
            } else if let choice = answer["choice"] as? String, let numbers = answer["probabilities"] as? [String: NSNumber] {
                let probabilities = numbers.mapValues(\.doubleValue)
                result[id] = PrismAnswer(choice: choice, probability: probabilities[choice] ?? 0, probabilities: probabilities)
            }
        }
        return result.isEmpty ? nil : result
    }

    public static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? [String: Any],
           let message = error["message"] as? String { return String(message.prefix(200)) }
        return "No details"
    }
}

/// What a decision needs to be asked.
public struct FastDecisionQuestion: Equatable, Sendable {
    public var state: String
    public var question: PrismQuestion
    /// More questions about the same state. The state is billed once per request, however many are asked.
    public var alsoAsk: [String: PrismQuestion] = [:]
    public static let id = "decision"
    public var questions: [String: PrismQuestion] { alsoAsk.merging([Self.id: question]) { _, decision in decision } }

    public init(state: String, question: PrismQuestion, alsoAsk: [String: PrismQuestion] = [:]) {
        self.state = state
        self.question = question
        self.alsoAsk = alsoAsk
    }
}

/// One teammate or group a message could go to.
public struct FastDecisionTeammate: Equatable, Sendable {
    public var id: String
    public var name: String
    public var job: String
    public init(id: String, name: String, job: String) {
        self.id = id
        self.name = name
        self.job = job
    }
}

public struct FastPressOption: Equatable, Sendable {
    public var id: String
    public var role: String
    public var label: String
    public var app: String
    public init(id: String, role: String, label: String, app: String) {
        self.id = id
        self.role = role
        self.label = label
        self.app = app
    }
}

public enum FastDecisions {
    /// Prism's option for "whoever was asked keeps it". It's what happens with no answer too.
    public static let keepIt = "keep"

    // MARK: Who takes this

    /// Two questions, so each answer means what it says: is this one teammate's to do at all, and if so whose. With "keep" as
    /// just another option beside the teammates, the odds spread out and a right pick rarely gets near Sarvam's suggested 0.9.
    public static let teamsJobID = "teamsJob"

    public static func whoTakesIt(message: String, leader: String, team: [FastDecisionTeammate]) -> FastDecisionQuestion {
        var criteria: [String: String] = [:]
        for teammate in team { criteria[teammate.id] = "It's \(teammate.name)'s work: \(String(teammate.job.prefix(280)))" }
        // A choice needs two options.
        if criteria.count < 2 { criteria[keepIt] = "None of the teammates." }
        let roster = team.map { "- \($0.name): \(String($0.job.prefix(280)))" }.joined(separator: "\n")
        return FastDecisionQuestion(
            state: "Addy wrote to \(leader): \(String(message.prefix(1500)))\n\n\(leader)'s teammates:\n\(roster)",
            question: PrismQuestion(kind: .choice, instructions: "Which teammate's work is closest to this message?", criteria: criteria),
            alsoAsk: [teamsJobID: PrismQuestion(
                kind: .noul,
                instructions: "Is this a request that one teammate's job plainly covers, which they can carry out alone?",
                criteria: ["true": "Addy wants something done or looked up, and one teammate's job clearly covers it.",
                           "false": "It's for \(leader): chat, opinions, plans or decisions, anything about \(leader) or Addy's own setup, work across several teammates, a follow-up that needs the earlier conversation, or no one teammate clearly owns it."])])
    }

    // MARK: Clicky: answer now, or a research run

    public static func needsResearch(transcript: String) -> FastDecisionQuestion {
        FastDecisionQuestion(state: "Addy said to their voice assistant: \(String(transcript.prefix(800)))", question: PrismQuestion(
            kind: .noul,
            instructions: "Does this need a background research run that searches the web and reads several pages to write a brief?",
            criteria: ["true": "Addy wants something found out from many sources: comparing products or options, the latest news on a topic, or a survey of what's out there.",
                       "false": "A quick answer will do: a fact, an explanation, a definition, chat, a task on the computer, or a question about what's on the screen right now."]))
    }

    // MARK: A coding run's outcome

    public static func runSucceeded(status: String, filesChanged: Int, tests: String?, report: String) -> FastDecisionQuestion {
        var lines = ["The coding agent's run ended with status \(status).", "Files changed: \(filesChanged)."]
        if let tests, !tests.isEmpty { lines.append("Tests: \(String(tests.prefix(300)))") }
        lines.append("The agent's final report:\n\(String(report.suffix(2500)))")
        return FastDecisionQuestion(state: lines.joined(separator: "\n"), question: PrismQuestion(
            kind: .noul,
            instructions: "Did this run do what it was asked?",
            criteria: ["true": "The work is finished: the agent reports it done and nothing important was left out or failing.",
                       "false": "The work isn't finished: the agent gave up, got blocked, needs an answer, skipped part of it, or tests are failing."]))
    }

    // MARK: A scheduled bot

    public static func routineNeedsToAct(name: String, instruction: String, lastResult: String?, now: String) -> FastDecisionQuestion {
        FastDecisionQuestion(state: "It is \(now). Scheduled job \"\(name)\": \(String(instruction.prefix(800)))\nLast run: \(lastResult.map { String($0.prefix(500)) } ?? "none")", question: PrismQuestion(
            kind: .noul,
            instructions: "Does the bot need to run this job now?",
            criteria: ["true": "The job should run: it's unconditional, or its condition is met or can't be told from what's here.",
                       "false": "The job's own condition clearly says there's nothing to do this time."]))
    }

    // MARK: Dictation: does it need the model's clean-up?

    public static func dictationNeedsCleanup(text: String) -> FastDecisionQuestion {
        FastDecisionQuestion(state: "Dictated text: \(String(text.prefix(1200)))", question: PrismQuestion(
            kind: .noul,
            instructions: "Does this dictated text need an editor to tidy it before it's typed in?",
            criteria: ["true": "It has false starts, self-corrections, repeated phrases, spoken filler like 'you know' or 'matlab', or wrong punctuation that changes how it reads.",
                       "false": "It already reads as written text and can go in as it is."]))
    }

    // MARK: Clicky: "press this and that"

    public static let namesOneID = "namesOne"

    /// The steps in a request to press things, or nil when it isn't one. A question about pressing isn't a request to press.
    public static func pressRequest(_ transcript: String) -> [String]? {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        text = text.replacingOccurrences(of: #"^(hey |hi |ok |okay )?(clicky|theo|claudia)[,:]?\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(please |can you |could you |just |now |go ahead and )+"#, with: "", options: .regularExpression)
        guard text.split(whereSeparator: \.isWhitespace).count <= 24 else { return nil }
        let verb = #"(press|click|tap|hit|select)"#
        let hindi = #"(dabao|daba do|dabana|click karo|click kar do|press karo|press kar do|select karo)"#
        guard text.range(of: "^\(verb)\\b", options: .regularExpression) != nil || text.range(of: "\\b\(hindi)[.!]*$", options: .regularExpression) != nil else { return nil }
        let marked = text.replacingOccurrences(of: #"\s*(,?\s*and then|,\s*then|\bthen\b|\bafter that\b|\buske baad\b|\bphir\b|,\s*and)\s+"#, with: "\u{1}", options: .regularExpression)
        var parts = marked.components(separatedBy: "\u{1}")
        // "press this and that": the plain "and" only splits once the whole phrase didn't name one thing, which the caller finds out.
        parts = parts.flatMap { $0.components(separatedBy: " and ") + [] }
        parts = parts.map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)) }.filter { !$0.isEmpty }
        guard (1...4).contains(parts.count) else { return nil }
        return parts
    }

    public static func whichToPress(words: String, options: [FastPressOption], pointerOn: String?) -> FastDecisionQuestion? {
        guard options.count >= 2 else { return nil }
        let shown = Array(options.prefix(FastDecisionPolicy.pressOptionsAtMost))
        var criteria: [String: String] = [:]
        for option in shown { criteria[option.id] = "Addy means the \(option.role) \"\(String(option.label.prefix(120)))\" in \(option.app)." }
        let list = shown.map { "- \($0.role) \"\(String($0.label.prefix(120)))\" in \($0.app)" }.joined(separator: "\n")
        return FastDecisionQuestion(
            state: "Addy told their assistant: \(String(words.prefix(300)))\nThe pointer is on: \(pointerOn ?? "nothing in particular")\nWhat can be pressed on screen:\n\(list)",
            question: PrismQuestion(kind: .choice, instructions: "Which item does Addy mean?", criteria: criteria),
            alsoAsk: [namesOneID: PrismQuestion(
                kind: .noul,
                instructions: "Did Addy clearly name one thing to press that's in this list?",
                criteria: ["true": "What they said matches one listed item by its name or meaning, or they said 'this' and the pointer is on it.",
                           "false": "Nothing listed matches, several match equally, they named more than one thing, or they aren't asking for something to be pressed."])])
    }

    /// The option to press, or nil when it isn't clear. A label two items share is never clear.
    public static func pressPick(from answers: [String: PrismAnswer]?, options: [FastPressOption]) -> FastPressOption? {
        // The top option's own odds fall as a screen gets busier, so what counts is how far it's ahead of the next one.
        guard let pick = answers?[FastDecisionQuestion.id],
              pick.probability >= FastDecisionPolicy.pressLeadOverNext * (pick.probabilities.filter { $0.key != pick.choice }.values.max() ?? 0),
              (answers?[namesOneID]?.probabilities["true"] ?? 0) >= FastDecisionPolicy.pressNamesOneAtLeast,
              let option = options.first(where: { $0.id == pick.choice }) else { return nil }
        let sameLabel = options.filter { $0.role == option.role && $0.label.lowercased() == option.label.lowercased() && $0.app == option.app }
        return sameLabel.count == 1 ? option : nil
    }

    // MARK: What the answer means

    public enum Routing: Equatable, Sendable {
        case teammate(String)
        case keep
    }

    /// `.keep` also means "not sure": the message takes the path it always did.
    public static func routing(from answers: [String: PrismAnswer]?) -> Routing {
        guard let pick = answers?[FastDecisionQuestion.id], pick.choice != keepIt, pick.probability >= FastDecisionPolicy.teammateAtLeast,
              (answers?[teamsJobID]?.probabilities["true"] ?? 0) >= FastDecisionPolicy.teamsJobAtLeast else { return .keep }
        return .teammate(pick.choice)
    }

    public static func startsResearch(_ answer: PrismAnswer?) -> Bool {
        (answer?.probabilities["true"] ?? 0) >= FastDecisionPolicy.researchAtLeast
    }

    public static func skipsCleanup(_ answer: PrismAnswer?) -> Bool {
        guard let yes = answer?.probabilities["true"] else { return false }
        return yes <= FastDecisionPolicy.cleanupSkipAtMost
    }

    public static func skipsRoutine(_ answer: PrismAnswer?) -> Bool {
        guard let yes = answer?.probabilities["true"] else { return false }
        return yes <= FastDecisionPolicy.routineSkipAtMost
    }

    public enum RunVerdict: Equatable, Sendable {
        case finished, notFinished, unsure
    }

    public static func runVerdict(_ answer: PrismAnswer?) -> RunVerdict {
        guard let yes = answer?.probabilities["true"] else { return .unsure }
        if yes >= FastDecisionPolicy.runFinishedAtLeast { return .finished }
        if yes <= FastDecisionPolicy.runUnfinishedAtMost { return .notFinished }
        return .unsure
    }

    /// Only a routine that states a condition can be skipped. One that says "send the reminders" always runs, with no question asked.
    public static func routineHasCondition(_ instruction: String) -> Bool {
        instruction.range(of: #"(?i)\b(only|if|unless|when|except|agar|sirf|jab)\b"#, options: .regularExpression) != nil
    }

    /// Clicky's gate is for real questions: a word or two is a command or a reply.
    public static func worthAskingAboutResearch(_ transcript: String) -> Bool {
        transcript.split(whereSeparator: \.isWhitespace).count >= 4
    }

    /// Only romanised text was tested for clean-up, so Devanagari keeps going to the model.
    public static func worthAskingAboutCleanup(_ text: String) -> Bool {
        !text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }
}

/// How sure Prism has to be. Chosen on half of the labelled cases and checked on the other half. A wrong pick costs more than a slower right one.
public enum FastDecisionPolicy {
    public static let teammateAtLeast = 0.8
    public static let teamsJobAtLeast = 0.7
    public static let researchAtLeast = 0.9
    public static let pressLeadOverNext = 5.0
    public static let pressNamesOneAtLeast = 0.85
    public static let pressOptionsAtMost = 200
    public static let cleanupSkipAtMost = 0.2
    public static let routineSkipAtMost = 0.1
    public static let runFinishedAtLeast = 0.75
    public static let runUnfinishedAtMost = 0.25
}
