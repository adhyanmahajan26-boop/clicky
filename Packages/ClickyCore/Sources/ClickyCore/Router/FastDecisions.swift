//
//  FastDecisions.swift
//  ClickyCore
//
//  Quick fixed-choice decisions on Sarvam Prism (POST /v2/systemone), a model that answers with probabilities and
//  never writes text. Clicky uses it to pick what "press this" means and dictation to skip Haiku on clean words. Anything
//  Prism isn't sure of goes down the path it would have gone anyway. The pure parts live here: the questions, the wire
//  format and the thresholds, so all of it can be tested with no network.
//  It's deliberately not on Theo's bots: custom bots with vague descriptions can't be routed from a list.
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
        // "press this and that": the second step is a press too.
        let first = parts[0].split(separator: " ").first.map(String.init) ?? "press"
        let lead = first.range(of: "^\(verb)$", options: .regularExpression) != nil ? first : "press"
        return parts.enumerated().map { index, part in
            let isOwnStep = index == 0 || part.range(of: "^\(verb)\\b", options: .regularExpression) != nil || part.range(of: "\\b\(hindi)[.!]*$", options: .regularExpression) != nil
            return isOwnStep ? part : "\(lead) \(part)"
        }
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

    public static func skipsCleanup(_ answer: PrismAnswer?) -> Bool {
        guard let yes = answer?.probabilities["true"] else { return false }
        return yes <= FastDecisionPolicy.cleanupSkipAtMost
    }

    /// Only romanised text was tested for clean-up, so Devanagari keeps going to the model.
    public static func worthAskingAboutCleanup(_ text: String) -> Bool {
        !text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }
}

/// How sure Prism has to be. Chosen on half of the labelled cases and checked on the other half. A wrong pick costs more than a slower right one.
public enum FastDecisionPolicy {
    public static let pressLeadOverNext = 5.0
    public static let pressNamesOneAtLeast = 0.85
    public static let pressOptionsAtMost = 200
    public static let cleanupSkipAtMost = 0.2
}
