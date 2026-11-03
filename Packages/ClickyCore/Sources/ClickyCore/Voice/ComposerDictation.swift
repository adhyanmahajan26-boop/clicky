//
//  ComposerDictation.swift
//  ClickyCore
//
//  The pure parts of dictating into the chat box: where the words land and what's left if it's cancelled, the steps it
//  goes through, when silence ends it, and what the keys mean. Words only ever land in the field. Nothing here sends.
//

import Foundation

/// The message being dictated into. The words go in at the cursor, between what was typed before and after it.
public struct ComposerDictationDraft: Equatable, Sendable {
    /// What the field said when dictation started. Cancelling puts this back.
    public let original: String
    /// Where the words go, in UTF-16 units as AppKit counts them.
    public let cursor: Int
    public private(set) var spoken = ""
    /// Words already heard, when the recognizer started over after a long pause.
    private var settled = ""
    private var latest = ""

    /// `selection` is the field's selected range as (location, length), or nil for the end of the text. A selection
    /// isn't replaced: the words go in after it.
    public init(text: String, selection: (location: Int, length: Int)? = nil) {
        original = text
        let units = (text as NSString).length
        let wanted = selection.map { $0.location + $0.length } ?? units
        cursor = Self.safeOffset(max(0, min(wanted, units)), in: text)
    }

    /// Never in the middle of an emoji or an accented letter.
    private static func safeOffset(_ offset: Int, in text: String) -> Int {
        let units = text as NSString
        guard offset > 0, offset < units.length else { return offset }
        let around = units.rangeOfComposedCharacterSequence(at: offset)
        return around.location == offset ? offset : NSMaxRange(around)
    }

    /// The recognizer's words so far. They replace the last guess, since it revises as it goes. If it starts over, what
    /// it had heard stays.
    public mutating func hear(_ words: String) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if Self.startedOver(from: latest, to: words) { settled = Self.joined(settled, latest) }
        latest = words
        spoken = Self.joined(settled, latest)
    }

    /// The final words, from the recognizer or the cloud. They replace everything heard so far.
    public mutating func settle(_ words: String) {
        settled = ""
        latest = words.trimmingCharacters(in: .whitespacesAndNewlines)
        spoken = latest
    }

    private static func joined(_ first: String, _ second: String) -> String {
        first.isEmpty ? second : first + " " + second
    }

    /// A revision shares its opening with the last guess. Much shorter and a different opening means a fresh start.
    private static func startedOver(from old: String, to new: String) -> Bool {
        guard old.count >= 12, new.count * 2 < old.count else { return false }
        let oldStart = old.prefix(4).lowercased(), newStart = new.prefix(4).lowercased()
        return !oldStart.hasPrefix(newStart) && !newStart.hasPrefix(oldStart)
    }

    private var before: String {
        String(utf16CodeUnits: Array(original.utf16.prefix(cursor)), count: cursor)
    }

    private var after: String {
        let tail = Array(original.utf16.dropFirst(cursor))
        return String(utf16CodeUnits: tail, count: tail.count)
    }

    /// The typed text before the words, with a space if they need one.
    public var leading: String {
        let text = before
        guard !spoken.isEmpty, let last = text.last, !last.isWhitespace, let first = spoken.first,
              !Self.closesUp.contains(first) else { return text }
        return text + " "
    }

    /// The typed text after the words, with a space if they need one.
    public var trailing: String {
        let text = after
        guard !spoken.isEmpty, let first = text.first, !first.isWhitespace, !Self.closesUp.contains(first) else { return text }
        return " " + text
    }

    private static let closesUp: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "'", "\u{2019}", "\u{0964}"]

    /// What the field says with the words in it.
    public var text: String { leading + spoken + trailing }

    /// Where the cursor goes when the words are kept: straight after them.
    public var cursorAfterWords: Int { ((leading + spoken) as NSString).length }
}

/// Why dictation isn't running or stopped short. The note in the composer says so.
public enum ComposerDictationProblem: Equatable, Sendable {
    case microphoneDenied, microphoneUndecided, speechDenied, speechUndecided
    case microphoneFailed, noRecognizer, nothingHeard, busy

    public var message: String {
        switch self {
        case .microphoneDenied, .microphoneUndecided: return "Theo needs the microphone to dictate."
        case .speechDenied, .speechUndecided: return "Theo needs Speech Recognition to dictate."
        case .microphoneFailed: return "The microphone didn't start."
        case .noRecognizer: return "This Mac has no recognizer for that language."
        case .nothingHeard: return "Didn't catch that."
        case .busy: return "The microphone is in use by a call or by Clicky."
        }
    }

    /// Whether the note offers a way to the permission.
    public var needsPermission: Bool {
        switch self {
        case .microphoneDenied, .microphoneUndecided, .speechDenied, .speechUndecided: return true
        default: return false
        }
    }

    /// True when macOS has never asked. System Settings doesn't list the app until it has.
    public var isUndecided: Bool { self == .microphoneUndecided || self == .speechUndecided }

    /// Goes away by itself after a moment. A missing permission stays until it's dealt with.
    public var isBrief: Bool { self == .nothingHeard || self == .busy || self == .microphoneFailed }
}

public enum ComposerDictationPermission: String, Sendable {
    case granted, denied, undecided
}

public enum ComposerDictationPermissions {
    /// What's missing, if anything. With a cloud service listening, Apple's recognizer is only a bonus.
    public static func problem(microphone: ComposerDictationPermission, speech: ComposerDictationPermission, hasCloudEars: Bool) -> ComposerDictationProblem? {
        switch microphone {
        case .denied: return .microphoneDenied
        case .undecided: return .microphoneUndecided
        case .granted: break
        }
        guard !hasCloudEars else { return nil }
        switch speech {
        case .denied: return .speechDenied
        case .undecided: return .speechUndecided
        case .granted: return nil
        }
    }
}

public enum ComposerDictationPhase: Equatable, Sendable {
    case idle
    case listening
    /// The mic is shut and the last words are coming in.
    case finishing
    case problem(ComposerDictationProblem)
}

public enum ComposerDictationEvent: Equatable, Sendable {
    /// The owner asked to start and nothing stands in the way.
    case start
    case refused(ComposerDictationProblem)
    /// Keep the words: the Stop button, the shortcut, or silence.
    case stop
    /// Throw the words away: the Cancel button, Esc, or leaving the chat.
    case cancel
    /// The final words are in the field.
    case wordsLanded
    case failed(ComposerDictationProblem)
    case dismiss
}

/// idle → listening → finishing → idle. Anything else that arrives is ignored, so a late callback can't reopen it.
public struct ComposerDictationMachine: Equatable, Sendable {
    public private(set) var phase: ComposerDictationPhase = .idle
    public init() {}

    /// True if this event did something.
    @discardableResult
    public mutating func handle(_ event: ComposerDictationEvent) -> Bool {
        switch (phase, event) {
        case (.idle, .start), (.problem, .start):
            phase = .listening
        case (.idle, .refused(let problem)), (.problem, .refused(let problem)):
            phase = .problem(problem)
        case (.listening, .stop):
            phase = .finishing
        case (.listening, .cancel), (.finishing, .cancel), (.finishing, .wordsLanded), (.problem, .dismiss):
            phase = .idle
        case (.listening, .failed(let problem)), (.finishing, .failed(let problem)):
            phase = .problem(problem)
        default:
            return false
        }
        return true
    }

    public var isActive: Bool { phase == .listening || phase == .finishing }
}

/// When silence ends it. Words arriving or a clearly raised voice both count as speech, so a noisy room can't end it
/// and can't be mistaken for words either: the recognizer only reports words it heard.
public struct ComposerSilenceRule: Equatable, Sendable {
    /// About −35 dB on the waveform's scale: speech is above it, a quiet room well below.
    public static let speechLevel = 0.45
    public static let defaultSeconds = 3.0
    /// Dictation can't be left open forever by accident.
    public static let longestSeconds = 600.0

    /// Nil when auto-stop is off.
    public let seconds: Double?
    private let startedAt: Double
    private var lastSpeech: Double?

    public init(seconds: Double?, startedAt: Double) {
        self.seconds = seconds
        self.startedAt = startedAt
    }

    /// Someone needs a moment to start talking.
    public var secondsBeforeSpeech: Double { max((seconds ?? Self.defaultSeconds) * 3, 8) }

    public mutating func note(level: Double, at time: Double) {
        if level >= Self.speechLevel { lastSpeech = time }
    }

    public mutating func noteWords(at time: Double) {
        lastSpeech = time
    }

    public func shouldStop(at time: Double) -> Bool {
        if time - startedAt >= Self.longestSeconds { return true }
        guard let seconds else { return false }
        if let lastSpeech { return time - lastSpeech >= seconds }
        return time - startedAt >= secondsBeforeSpeech
    }
}

public enum ComposerDictationShortcut: String, CaseIterable, Identifiable, Sendable {
    case optionSpace, commandShiftD, micButtonOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .optionSpace: return "⌥ Space and ⌘⇧D"
        case .commandShiftD: return "⌘⇧D"
        case .micButtonOnly: return "Mic button only"
        }
    }
}

/// What a key means to the composer. ⌥Space can be tapped (stays on until stopped) or held (stops on release).
public struct ComposerDictationKeyboard: Sendable {
    public enum Key: Equatable, Sendable {
        case optionSpace, commandShiftD, escape, enter
        /// The space bar came up, with or without Option still down.
        case spaceUp
        /// Key repeat while ⌥Space is held.
        case optionSpaceRepeat
    }

    public enum Action: Equatable, Sendable {
        /// Not for us: the key carries on as usual.
        case pass
        /// For us, and nothing more to do.
        case swallow
        case start, keep, cancel, dismiss
    }

    /// A press longer than this was a hold, so letting go stops it.
    public static let holdSeconds = 0.4
    private var heldSince: Double?

    public init() {}

    public mutating func handle(_ key: Key, phase: ComposerDictationPhase, composerFocused: Bool,
                                shortcut: ComposerDictationShortcut, at time: Double) -> Action {
        let isListening = phase == .listening
        let isActive = isListening || phase == .finishing
        switch key {
        case .optionSpace:
            guard shortcut == .optionSpace else { return .pass }
            if isListening { heldSince = nil; return .keep }
            if isActive { return .swallow }
            guard composerFocused else { return .pass }
            heldSince = time
            return .start
        case .optionSpaceRepeat:
            return heldSince != nil || isActive ? .swallow : .pass
        case .spaceUp:
            guard let since = heldSince else { return .pass }
            heldSince = nil
            return isListening && time - since >= Self.holdSeconds ? .keep : .swallow
        case .commandShiftD:
            guard shortcut != .micButtonOnly else { return .pass }
            if isListening { return .keep }
            return isActive ? .swallow : .start
        case .escape:
            if isActive { return .cancel }
            if case .problem = phase { return .dismiss }
            return .pass
        case .enter:
            if isListening { return .keep }
            return isActive ? .swallow : .pass
        }
    }
}

public enum ComposerDictationTimer {
    /// "0:07", "12:03".
    public static func text(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
