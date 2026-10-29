//
//  ReadingPaceSpeechEngine.swift
//  ClickyCore
//
//  Silent mode's "voice": plays nothing, but walks through each segment at
//  reading speed, so captions reveal, marks fire on their words and board
//  steps appear in the same order and rhythm as a spoken answer.
//

import Foundation

@MainActor
public final class ReadingPaceSpeechEngine: SpeechEngine {
    public let name = "silent"
    public var callbacks = SpeechEngineCallbacks()

    /// Characters read per second, and the shortest time a segment stays up.
    public static let charactersPerSecond: Double = 18
    public static let minimumSegmentSeconds: Double = 1.2
    static let tickSeconds: Double = 0.1

    private var queue: [CaptionSegment] = []
    private var isAnswerEnded = false
    private var isPaused = false
    private var playingTask: Task<Void, Never>?
    private var epoch = 0

    public init() {}

    public static func readingSeconds(for segment: CaptionSegment) -> Double {
        max(minimumSegmentSeconds, Double(segment.speechLength) / charactersPerSecond)
    }

    public func begin(epoch: Int) {
        stopNow()
        self.epoch = epoch
        isAnswerEnded = false
    }

    public func enqueue(_ segment: CaptionSegment) {
        queue.append(segment)
        playNextIfIdle()
    }

    public func endOfAnswer() {
        isAnswerEnded = true
        if playingTask == nil, queue.isEmpty { callbacks.onAllPlayed() }
    }

    public func stopNow() {
        playingTask?.cancel()
        playingTask = nil
        queue.removeAll()
    }

    public func pause() { isPaused = true }
    public func resume() { isPaused = false }

    private func playNextIfIdle() {
        guard playingTask == nil, !queue.isEmpty else { return }
        let segment = queue.removeFirst()
        let playingEpoch = epoch
        playingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.callbacks.onSegmentStart(segment.id)
            let totalSeconds = Self.readingSeconds(for: segment)
            var elapsedSeconds = 0.0
            while elapsedSeconds < totalSeconds {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickSeconds * 1_000_000_000))
                if Task.isCancelled || self.epoch != playingEpoch { return }
                if self.isPaused { continue }
                elapsedSeconds += Self.tickSeconds
                let spoken = min(segment.speechLength, Int(Double(segment.speechLength) * elapsedSeconds / totalSeconds))
                self.callbacks.onProgress(segment.id, spoken, min(segment.speechLength, spoken + 4), false)
            }
            self.callbacks.onSegmentEnd(segment.id)
            self.playingTask = nil
            if self.queue.isEmpty {
                if self.isAnswerEnded { self.callbacks.onAllPlayed() }
            } else {
                self.playNextIfIdle()
            }
        }
    }
}
