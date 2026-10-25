//
//  SpeechEngine.swift
//  ClickyCore
//
//  The contract every voice (Apple, Qwen) implements. The coordinator feeds
//  it caption segments one by one as the answer streams in; the engine
//  reports which segment is playing and how far it has got, so captions
//  can follow the voice and tags can fire on their words.
//
//  There's no engine-level "resume after fallback": when Qwen fails it
//  hands back the segments it didn't speak (onFailure), the coordinator
//  gives them to Apple, and sends later segments to Qwen again once Apple
//  is done (unless Qwen said the rest of the answer is lost too).
//

import Foundation

public struct SpeechEngineCallbacks {
    public var onSegmentStart: (_ segmentID: Int) -> Void
    /// `spoken`: characters spoken so far. `leadSpoken`: the same a beat
    /// ahead (Qwen +250 ms, Apple = its callback), for POINT flights.
    /// `isExact`: true for real callbacks (Apple ranges), false for estimates.
    public var onProgress: (_ segmentID: Int, _ spoken: Int, _ leadSpoken: Int, _ isExact: Bool) -> Void
    public var onSegmentEnd: (_ segmentID: Int) -> Void
    public var onAllPlayed: () -> Void
    public var onFailure: (_ unspoken: [CaptionSegment], _ restOfAnswer: Bool) -> Void

    public init(onSegmentStart: @escaping (Int) -> Void = { _ in },
                onProgress: @escaping (Int, Int, Int, Bool) -> Void = { _, _, _, _ in },
                onSegmentEnd: @escaping (Int) -> Void = { _ in },
                onAllPlayed: @escaping () -> Void = {},
                onFailure: @escaping ([CaptionSegment], Bool) -> Void = { _, _ in }) {
        self.onSegmentStart = onSegmentStart
        self.onProgress = onProgress
        self.onSegmentEnd = onSegmentEnd
        self.onAllPlayed = onAllPlayed
        self.onFailure = onFailure
    }
}

@MainActor
public protocol SpeechEngine: AnyObject {
    var name: String { get }
    var callbacks: SpeechEngineCallbacks { get set }
    /// A new answer (or a new batch): forget anything queued for an older epoch.
    func begin(epoch: Int)
    func enqueue(_ segment: CaptionSegment)
    /// No more segments for this answer; onAllPlayed follows the last one.
    func endOfAnswer()
    /// Silence now; no further callbacks for what was queued.
    func stopNow()
    func pause()
    func resume()
}

/// Ignores barge-in words the user only heard from Clicky itself: "stop",
/// "wait" or "clicky stop" count only if that word was not in what Clicky
/// said during the last 4 seconds.
public struct EchoGuard: Sendable {
    public static let windowSeconds: TimeInterval = 4
    public static let commandWords: Set<String> = ["stop", "wait"]

    private var spokenEntries: [(words: Set<String>, date: Date)] = []

    public init() {}

    /// What the voice is saying (call at segment start and end).
    public mutating func recordSpoken(_ text: String, at date: Date) {
        spokenEntries.removeAll { date.timeIntervalSince($0.date) > Self.windowSeconds }
        spokenEntries.append((Self.words(in: text), date))
    }

    /// Whether `heardText` is a real barge-in command at `date`.
    public func accepts(_ heardText: String, at date: Date) -> Bool {
        let heardWords = Self.words(in: heardText)
        let commandWordsHeard = heardWords.intersection(Self.commandWords)
        guard !commandWordsHeard.isEmpty else { return false }
        let recentWords = spokenEntries
            .filter { date.timeIntervalSince($0.date) <= Self.windowSeconds }
            .reduce(into: Set<String>()) { $0.formUnion($1.words) }
        return commandWordsHeard.isDisjoint(with: recentWords)
    }

    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }
}
