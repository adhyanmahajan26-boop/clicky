//
//  WakeFollowUp.swift
//  ClickyCore
//
//  P8 follow-up window: after a wake turn is answered (Clicky finished
//  speaking), the wake listener keeps taking commands for 10 s without the
//  wake word. "that's all" / "thanks, that's it" or 10 s of nothing ends
//  it; Escape, push-to-talk and hands-free cancel it. Wake turns only (a
//  push-to-talk turn never opens it). Every command heard restarts the
//  cycle: its answer finishes, then 10 s more.
//
//  EchoGuard: an utterance made mostly of words Clicky itself just said is
//  its own voice coming back through the speakers, not a command.
//
//  Pure: the clock is passed in.
//

import Foundation

public enum WakeFollowUpEndReason: String, Equatable, Sendable {
    /// "that's all", "thanks that's it".
    case thatsAll
    /// The window ran out with nothing said.
    case silence
    /// Escape, push-to-talk, hands-free, the wake word turned off.
    case cancelled
}

public struct WakeFollowUpWindow: Equatable, Sendable {
    public static let defaultListenSeconds: TimeInterval = 10

    public enum Phase: Equatable, Sendable {
        case idle
        /// A wake (or follow-up) turn went to Clicky; waiting for its answer to finish.
        case awaitingAnswer
        /// Taking a command without the wake word until `deadline`.
        case listening(deadline: Date)
        /// Words started inside the window: the command is being heard (no deadline while it lasts).
        case hearingCommand
    }

    public enum CommandDecision: Equatable, Sendable {
        /// Send it on as a turn (the window waits for its answer, then opens again).
        case command(String)
        /// "that's all": the window closed.
        case ended(WakeFollowUpEndReason)
        /// Clicky's own voice, or nothing usable: keep listening until the same deadline.
        case ignored(reason: String)
    }

    public private(set) var phase: Phase = .idle
    public var listenSeconds: TimeInterval
    /// Kept while hearing a command so an ignored utterance resumes the same window.
    private var lastDeadline: Date?
    public private(set) var lastEndReason: WakeFollowUpEndReason?

    public init(listenSeconds: TimeInterval = WakeFollowUpWindow.defaultListenSeconds) {
        self.listenSeconds = listenSeconds
    }

    /// Listening or hearing a command: the mic takes words without the wake word.
    public var isOpen: Bool {
        switch phase {
        case .listening, .hearingCommand: return true
        case .idle, .awaitingAnswer: return false
        }
    }

    /// The notch's "listening…" (also while the turn after a wake is waiting to be answered? no: only when open).
    public var showsListening: Bool { isOpen }

    /// A wake turn (or a follow-up command) was sent.
    public mutating func turnSent() {
        phase = .awaitingAnswer
        lastEndReason = nil
    }

    /// Clicky finished answering: listen for `listenSeconds`.
    public mutating func answerFinished(at date: Date) {
        guard phase == .awaitingAnswer else { return }
        let deadline = date.addingTimeInterval(listenSeconds)
        lastDeadline = deadline
        phase = .listening(deadline: deadline)
    }

    /// Words started within the window. False when the window isn't open (the words aren't a follow-up).
    @discardableResult
    public mutating func commandSpeechStarted(at date: Date) -> Bool {
        guard case .listening(let deadline) = phase, date < deadline else { return false }
        phase = .hearingCommand
        return true
    }

    /// The command finished. `recentClickySpokenWords`: what Clicky said in the EchoGuard window.
    public mutating func commandHeard(_ text: String, at date: Date, recentClickySpokenWords: Set<String>) -> CommandDecision {
        guard isOpen else { return .ignored(reason: "window closed") }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty {
            resumeListening(at: date)
            return .ignored(reason: "nothing heard")
        }
        if WakeFollowUpEndPhrase.isEndPhrase(trimmedText) {
            end(.thatsAll)
            return .ended(.thatsAll)
        }
        if FollowUpEchoGuard.isLikelyEcho(trimmedText, recentClickySpokenWords: recentClickySpokenWords) {
            resumeListening(at: date)
            return .ignored(reason: "echo")
        }
        phase = .awaitingAnswer
        return .command(trimmedText)
    }

    /// Words started but nothing usable came of them (abandoned capture).
    public mutating func commandAbandoned(at date: Date) {
        guard phase == .hearingCommand else { return }
        resumeListening(at: date)
    }

    /// Call on a timer. Returns the end reason when the window just ran out.
    public mutating func tick(now: Date) -> WakeFollowUpEndReason? {
        guard case .listening(let deadline) = phase, now >= deadline else { return nil }
        end(.silence)
        return .silence
    }

    public mutating func cancel() {
        guard phase != .idle else { return }
        end(.cancelled)
    }

    /// Keeps the window open longer (dictation mode keeps it open while he dictates).
    public mutating func extend(until deadline: Date) {
        if case .listening(let currentDeadline) = phase, deadline > currentDeadline {
            lastDeadline = deadline
            phase = .listening(deadline: deadline)
        }
    }

    private mutating func resumeListening(at date: Date) {
        // Never shorter than a couple of seconds, so a cough right at the end doesn't close it at once.
        let deadline = max(lastDeadline ?? date.addingTimeInterval(listenSeconds), date.addingTimeInterval(2))
        lastDeadline = deadline
        phase = .listening(deadline: deadline)
    }

    private mutating func end(_ reason: WakeFollowUpEndReason) {
        phase = .idle
        lastDeadline = nil
        lastEndReason = reason
    }
}

/// "that's all", "thanks, that's it", "no thanks", "never mind", "nothing else".
public enum WakeFollowUpEndPhrase {
    static let phrases: Set<String> = [
        "thats all", "that is all", "thats it", "that is it", "thats all thanks", "thats it thanks", "thanks thats it", "thanks thats all",
        "thank you thats all", "thank you thats it", "ok thats all", "okay thats all", "ok thats it", "okay thats it", "no thanks", "no thank you",
        "nothing", "nothing else", "nothing more", "never mind", "nevermind", "im done", "i am done", "were done", "done", "all done", "thanks",
        "thank you", "thanks a lot", "thank you so much", "ok thanks", "okay thanks", "ok thank you", "okay thank you", "bye", "goodbye", "bye bye",
        "thats all for now", "thats it for now", "no thats all", "no thats it", "no more", "great thanks", "perfect thanks", "cool thanks"
    ]
    static let fillerWords: Set<String> = ["hey", "claudia", "clicky", "um", "uh", "so", "alright", "all right", "well", "yeah", "yes"]

    public static func isEndPhrase(_ text: String) -> Bool {
        let words = WakeWordMatcher.normalizedWords(in: text)
        guard !words.isEmpty, words.count <= 7 else { return false }
        if phrases.contains(words.joined(separator: " ")) { return true }
        let withoutFiller = words.filter { !fillerWords.contains($0) }
        guard !withoutFiller.isEmpty else { return false }
        return phrases.contains(withoutFiller.joined(separator: " "))
    }
}

/// Clicky's own voice through the speakers, heard as a "command".
public enum FollowUpEchoGuard {
    /// Share of the utterance's words that Clicky just said, at or above which it is echo.
    public static let echoWordShare = 0.6

    public static func isLikelyEcho(_ text: String, recentClickySpokenWords: Set<String>) -> Bool {
        guard !recentClickySpokenWords.isEmpty else { return false }
        let spokenWords = Set(recentClickySpokenWords.map { WakeWordMatcher.normalizedWord($0) }.filter { !$0.isEmpty })
        let heardWords = WakeWordMatcher.normalizedWords(in: text)
        // One or two words ("next", "volume up") are too short to judge by overlap: real commands.
        guard heardWords.count >= 3 else { return false }
        let overlapCount = heardWords.filter { spokenWords.contains($0) }.count
        return Double(overlapCount) / Double(heardWords.count) >= echoWordShare
    }
}
