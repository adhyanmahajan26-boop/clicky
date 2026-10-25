//
//  WakeDiagnostics.swift
//  ClickyCore
//
//  P8 wake word diagnosis, pure parts:
//  - WakeRecognizerErrorClassifier: which SFSpeechRecognizer errors are
//    benign (no speech in what the gate let through, a cancel, a "retry")
//    and which are real failures. Benign ones are counted by code but don't
//    count as recognizer errors and never trigger the retry backoff.
//  - WakeNearMissCounter: in memory only, how often an utterance started
//    with a greeting ("hey") but the name didn't match, keyed by the
//    normalized second word only ("cloud": 3). No transcripts, nothing on disk.
//  - WakeLocaleSelector: v2.wake.locale "auto" | "en-IN" | "en-US". In auto,
//    the locale whose recent requests came back empty or failed less often
//    wins; it switches at most once per 10 minutes.
//  - WakeInputGain: digital make-up gain for a quiet mic (a webcam across
//    the desk), only for the audio given to the recognizer.
//

import Foundation

// MARK: - Recognizer errors

public enum WakeRecognizerErrorClass: String, Equatable, Sendable {
    /// kAFAssistantErrorDomain 1110: the request heard no speech (noise opened the gate).
    case noSpeech
    /// The request was cancelled (216 / 301): Clicky dropped it.
    case cancelled
    /// 203 "Retry": the recognizer gave up on this request without a transcript; the next one is fine.
    case retry
    /// Anything else (assets missing, service down, 1107, 1101…).
    case failure

    /// Benign: not a recognizer error, no backoff.
    public var isBenign: Bool { self != .failure }
}

public enum WakeRecognizerErrorClassifier {
    public static let assistantErrorDomain = "kAFAssistantErrorDomain"
    public static let localSpeechErrorDomain = "kLSRErrorDomain"

    public static func classify(domain: String, code: Int) -> WakeRecognizerErrorClass {
        switch (domain, code) {
        case (assistantErrorDomain, 1110): return .noSpeech
        case (assistantErrorDomain, 216), (assistantErrorDomain, 209), (localSpeechErrorDomain, 301): return .cancelled
        case (assistantErrorDomain, 203): return .retry
        default: return .failure
        }
    }

    /// "kAFAssistantErrorDomain:1110" (the key in wakeStatus.errorsByCode).
    public static func key(domain: String, code: Int) -> String { "\(domain):\(code)" }
}

// MARK: - Near misses

/// "hey cloud" said, nothing woke: counts by the second word only.
public struct WakeNearMissCounter: Equatable, Sendable {
    public static let maximumDistinctWords = 40
    public static let maximumWordLength = 20

    public private(set) var countsBySecondWord: [String: Int] = [:]
    public private(set) var totalCount = 0

    public init() {}

    /// Looks at each utterance segment of a finished request that didn't wake.
    /// A segment whose first word is a greeting and whose second word isn't a
    /// configured name counts once, keyed by that second word (normalized).
    public mutating func recordUnmatchedRequest(words: [WakeTranscriptWord], matcher: WakeWordMatcher) {
        let normalizedTexts = words.map { WakeWordMatcher.normalizedWord($0.text) }
        for segmentStartIndex in WakeWordMatcher.segmentStartIndexes(in: words) {
            let spokenIndexes = (segmentStartIndex..<words.count).filter { !normalizedTexts[$0].isEmpty }
            guard spokenIndexes.count >= 2 else { continue }
            let firstWord = normalizedTexts[spokenIndexes[0]]
            guard WakeWordMatcher.isGreetingWord(firstWord) else { continue }
            let secondWord = normalizedTexts[spokenIndexes[1]]
            // A real wake that matched elsewhere isn't a near miss.
            if matcher.nameWords.contains(where: { matcher.isNameVariant(secondWord, ofName: $0) }) { continue }
            record(secondWord: secondWord)
        }
    }

    public mutating func record(secondWord: String) {
        let key = String(WakeWordMatcher.normalizedWord(secondWord).prefix(Self.maximumWordLength))
        guard !key.isEmpty else { return }
        totalCount += 1
        if countsBySecondWord[key] == nil && countsBySecondWord.count >= Self.maximumDistinctWords {
            countsBySecondWord["(other)", default: 0] += 1
            return
        }
        countsBySecondWord[key, default: 0] += 1
    }

    /// "hey <word>" → count, for wakeStatus.
    public var displayCounts: [String: Int] {
        Dictionary(uniqueKeysWithValues: countsBySecondWord.map { ("hey \($0.key)", $0.value) })
    }
}

// MARK: - Locale choice

public enum WakeLocaleSetting: Equatable, Sendable {
    case automatic
    case fixed(String)

    /// "auto" (default), "en-IN", "en-US" (also "en_IN"); anything else is auto.
    public static func parse(_ rawValue: String?) -> WakeLocaleSetting {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        switch trimmed.lowercased() {
        case "en-in": return .fixed("en-IN")
        case "en-us": return .fixed("en-US")
        default: return .automatic
        }
    }
}

/// Picks the wake recognizer's locale. A "failed" request is one that ended
/// with an error or with no words at all although the gate let sound through.
public struct WakeLocaleSelector: Sendable {
    public static let windowSize = 12
    public static let minimumSecondsBetweenSwitches: TimeInterval = 600
    /// Switch away when this share of the current locale's recent requests failed…
    public static let switchAwayFailureRate = 0.5
    /// …and the other one (if measured) was at least this much better.
    public static let requiredImprovement = 0.15

    public let setting: WakeLocaleSetting
    /// Locales that run on-device, most preferred first (the system locale first).
    public let candidates: [String]
    public private(set) var currentLocale: String?
    public private(set) var lastSwitchDate: Date?
    public private(set) var outcomesByLocale: [String: [Bool]] = [:]
    public private(set) var switchLog: [String] = []

    public init(setting: WakeLocaleSetting, candidates: [String]) {
        self.setting = setting
        self.candidates = candidates
        switch setting {
        case .fixed(let identifier):
            currentLocale = candidates.first { Self.sameLocale($0, identifier) }
        case .automatic:
            currentLocale = candidates.first
        }
    }

    public static func sameLocale(_ first: String, _ second: String) -> Bool {
        first.replacingOccurrences(of: "_", with: "-").lowercased() == second.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    public func failureRate(of locale: String) -> Double? {
        guard let outcomes = outcomesByLocale[locale], outcomes.count >= Self.windowSize else { return nil }
        return Double(outcomes.filter { $0 }.count) / Double(outcomes.count)
    }

    /// One finished request. Returns the locale to switch to, if any.
    public mutating func record(locale: String, failed: Bool, at date: Date) -> String? {
        var outcomes = outcomesByLocale[locale] ?? []
        outcomes.append(failed)
        if outcomes.count > Self.windowSize { outcomes.removeFirst(outcomes.count - Self.windowSize) }
        outcomesByLocale[locale] = outcomes

        guard setting == .automatic, let currentLocale, Self.sameLocale(currentLocale, locale), candidates.count > 1 else { return nil }
        guard let currentRate = failureRate(of: currentLocale), currentRate >= Self.switchAwayFailureRate else { return nil }
        if let lastSwitchDate, date.timeIntervalSince(lastSwitchDate) < Self.minimumSecondsBetweenSwitches { return nil }
        let alternatives = candidates.filter { !Self.sameLocale($0, currentLocale) }
        // An unmeasured locale gets a try; a measured one must be clearly better.
        guard let alternative = alternatives.first(where: { candidate in
            guard let candidateRate = failureRate(of: candidate) else { return true }
            return candidateRate <= currentRate - Self.requiredImprovement
        }) else { return nil }
        self.currentLocale = alternative
        lastSwitchDate = date
        // The new locale starts from a clean window (the old one keeps its history).
        outcomesByLocale[alternative] = []
        switchLog.append("\(currentLocale) → \(alternative) (failed \(Int((currentRate * 100).rounded()))% of the last \(Self.windowSize))")
        return alternative
    }
}

// MARK: - Make-up gain for a quiet mic

/// The recognizer copes far better with speech near -26 dBFS than with a
/// webcam's -50. Tracks the speech level while the gate is open (a slow
/// peak follower) and gives back the gain that brings it to the target,
/// never more than `maximumGainDecibels` and never attenuating.
public struct WakeInputGain: Sendable {
    public static let targetSpeechDecibels: Double = -26
    public static let maximumGainDecibels: Double = 20
    /// The speech level falls back this fast between loud words (dB per second).
    public static let speechLevelDecayDecibelsPerSecond: Double = 1.5

    public private(set) var speechLevelDecibels: Double?

    public init() {}

    /// One buffer's level while the gate is open.
    public mutating func observeSpeech(levelDecibels: Double, durationSeconds: TimeInterval) {
        guard levelDecibels.isFinite, levelDecibels > -100 else { return }
        guard let current = speechLevelDecibels else {
            speechLevelDecibels = levelDecibels
            return
        }
        speechLevelDecibels = max(levelDecibels, current - Self.speechLevelDecayDecibelsPerSecond * durationSeconds)
    }

    public var gainDecibels: Double {
        guard let speechLevelDecibels else { return 0 }
        return min(Self.maximumGainDecibels, max(0, Self.targetSpeechDecibels - speechLevelDecibels))
    }

    public var linearGain: Float { Float(pow(10, gainDecibels / 20)) }

    /// Multiplies in place, clamping to ±1 so loud words don't wrap.
    public static func apply(linearGain: Float, to samples: UnsafeMutableBufferPointer<Float>) {
        guard linearGain > 1.001 else { return }
        for index in samples.indices {
            samples[index] = min(1, max(-1, samples[index] * linearGain))
        }
    }
}
