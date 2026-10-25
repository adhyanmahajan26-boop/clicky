//
//  CLIStream.swift
//  ClickyCore
//
//  Reads Claude Code's stream-json events and decides what each one means
//  for a spoken answer: text deltas go to the router (the `assistant`
//  message's text is ignored, it repeats the deltas), `result` finishes the
//  answer, a second `message_start` resets the answer if nothing has been
//  spoken yet, and every way the stream can fail ends in something said out
//  loud instead of silence.
//

import Foundation

public enum CLIStreamEvent: Equatable, Sendable {
    case systemInit(model: String?)
    case messageStart(id: String)
    case textDelta(String)
    case result(text: String, isError: Bool, subtype: String?)
    case other

    public static func parse(_ lineData: Data) -> CLIStreamEvent? {
        guard let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let eventType = event["type"] as? String else { return nil }
        switch eventType {
        case "system":
            return (event["subtype"] as? String) == "init" ? .systemInit(model: event["model"] as? String) : .other
        case "stream_event":
            guard let streamEvent = event["event"] as? [String: Any], let streamEventType = streamEvent["type"] as? String else { return .other }
            if streamEventType == "message_start" {
                let message = streamEvent["message"] as? [String: Any]
                return .messageStart(id: message?["id"] as? String ?? "")
            }
            if streamEventType == "content_block_delta", let delta = streamEvent["delta"] as? [String: Any],
               (delta["type"] as? String) == "text_delta", let text = delta["text"] as? String {
                return .textDelta(text)
            }
            return .other
        case "result":
            return .result(text: event["result"] as? String ?? "", isError: event["is_error"] as? Bool ?? false,
                           subtype: event["subtype"] as? String)
        default:
            return .other
        }
    }
}

/// What a stream failure sounds like.
public enum CLIStreamFailure: Equatable, Sendable {
    case reportedError(String)
    case usageLimit(resetDescription: String?)
    case endedWithoutResult
    case stalled

    public static let stallSeconds: TimeInterval = 25

    /// The sentence Clicky says out loud.
    public var spokenMessage: String {
        switch self {
        case .reportedError(let message) where ["auth", "login", "401", "api key"].contains(where: { message.lowercased().contains($0) }):
            return "I'm signed out of Claude. Run claude auth login in Terminal, then try again."
        case .reportedError(let message):
            let shortMessage = message.split(separator: "\n").first.map(String.init) ?? ""
            return shortMessage.isEmpty ? "Claude ran into an error." : "Claude ran into an error: \(shortMessage.prefix(120))"
        case .usageLimit(let resetDescription):
            if let resetDescription { return "You've hit your Claude usage limit. It resets \(resetDescription)." }
            return "You've hit your Claude usage limit, so I can't answer right now."
        case .endedWithoutResult:
            return "Claude stopped unexpectedly."
        case .stalled:
            return "Claude went quiet for too long, so I stopped it."
        }
    }

    /// A result text that means "out of usage", with its reset time if given:
    /// "Claude AI usage limit reached|1761400800" or "...limit reached ∙ resets 3pm".
    public static func usageLimit(in resultText: String, timeZone: TimeZone = .current) -> CLIStreamFailure? {
        let lowercasedText = resultText.lowercased()
        guard lowercasedText.contains("usage limit") || lowercasedText.contains("limit reached") || lowercasedText.contains("out of extra usage") else {
            return nil
        }
        if let pipeIndex = resultText.lastIndex(of: "|"), let epochSeconds = TimeInterval(resultText[resultText.index(after: pipeIndex)...].trimmingCharacters(in: .whitespaces)) {
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a"
            return .usageLimit(resetDescription: "at \(formatter.string(from: Date(timeIntervalSince1970: epochSeconds)))")
        }
        if let resetRange = resultText.range(of: #"resets?\s+(at\s+)?[^.\n]+"#, options: [.regularExpression, .caseInsensitive]) {
            let phrase = resultText[resetRange].replacingOccurrences(of: #"^resets?\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            return .usageLimit(resetDescription: phrase.trimmingCharacters(in: .whitespaces))
        }
        return .usageLimit(resetDescription: nil)
    }
}

/// One answer's stream, as decisions. The caller tells it whether any of the
/// answer has been spoken yet (which decides what a new message_start does).
public struct CLIStreamSupervisor: Sendable {
    public enum Action: Equatable, Sendable {
        case feed(String)
        case finish(resultText: String)
        /// A new message started before anything was spoken: start the answer over.
        case reset
        /// A new message started after speech began: keep going, note it.
        case logMessageStart(id: String)
        case fail(CLIStreamFailure)
    }

    public private(set) var currentMessageID: String?
    public private(set) var hasFinished = false
    public private(set) var streamedText = ""

    public init() {}

    public mutating func handle(_ event: CLIStreamEvent, hasSpokenAnything: Bool) -> [Action] {
        guard !hasFinished else { return [] }
        switch event {
        case .messageStart(let id):
            defer { currentMessageID = id }
            guard let currentMessageID, currentMessageID != id else { return [] }
            if hasSpokenAnything { return [.logMessageStart(id: id)] }
            streamedText = ""
            return [.reset]
        case .textDelta(let text):
            streamedText += text
            return [.feed(text)]
        case .result(let text, let isError, _):
            hasFinished = true
            if let usageLimit = CLIStreamFailure.usageLimit(in: text) { return [.fail(usageLimit)] }
            if isError { return [.fail(.reportedError(text))] }
            return [.finish(resultText: text.isEmpty ? streamedText : text)]
        case .systemInit, .other:
            return []
        }
    }

    public mutating func endOfStream() -> [Action] {
        guard !hasFinished else { return [] }
        hasFinished = true
        return [.fail(.endedWithoutResult)]
    }

    public mutating func stalled() -> [Action] {
        guard !hasFinished else { return [] }
        hasFinished = true
        return [.fail(.stalled)]
    }
}
