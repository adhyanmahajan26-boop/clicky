//
//  SpeechCoordinator.swift
//  ClickyCore
//
//  Runs one spoken answer: segments go to the voice as they're cut, the
//  caption follows the voice, and each tag fires once its words are spoken
//  (a POINT at the start of the word before it, a beat early). An answer
//  can span several Claude streams in one epoch: a stream that spawns
//  workers doesn't end the answer (the bubble says "Give me a second…"),
//  and the follow-up stream's segments join the same answer.
//
//  Barge-in (push-to-talk, Esc while speaking, or a spoken "stop"/"wait"
//  that EchoGuard accepts), in this order: epoch++ → cancel claude and
//  workers → stop the voice → freeze the caption at what was spoken → drop
//  unfired tags → history gets the spoken text + " [interrupted]".
//
//  A primary failure that loses one segment (Qwen merely slow): Apple
//  speaks it, and the segments Qwen still had queued wait (with any new
//  ones) until Apple is done, so the two voices never overlap.
//

import Foundation

public struct CaptionState: Equatable, Sendable {
    public var previous: CaptionSegment?
    public var current: CaptionSegment?
    /// Characters of `current.display` revealed.
    public var revealedDisplayCharacters = 0
    /// Shown instead of text while workers run ("Give me a second…").
    public var statusText: String?
    public var isFrozen = false
    public var isVisible = false

    public init() {}
}

@MainActor
public protocol SpeechCoordinatorHost: AnyObject {
    func cancelClaudeAndWorkers()
    func fireTag(index: Int)
    func dropUnfiredTags(_ tagIndexes: [Int])
    func captionDidChange(_ caption: CaptionState)
    /// The answer ended: played out, or interrupted (text has " [interrupted]").
    func answerDidFinish(historyText: String, wasInterrupted: Bool)
    func speakApology(_ text: String)
    func log(_ event: String)
    /// A segment started playing (P4: a board step reveals here, never before).
    func segmentDidStart(_ segment: CaptionSegment)
    /// Characters of a segment spoken so far (P4: board cues).
    func segmentDidProgress(_ segment: CaptionSegment, spokenCharacters: Int)
    /// A segment finished playing (P4: a board step ends after its last one).
    func segmentDidEnd(_ segment: CaptionSegment)
}

public extension SpeechCoordinatorHost {
    func segmentDidStart(_ segment: CaptionSegment) {}
    func segmentDidProgress(_ segment: CaptionSegment, spokenCharacters: Int) {}
    func segmentDidEnd(_ segment: CaptionSegment) {}
}

@MainActor
public final class SpeechCoordinator {
    public static let workerStatusText = "Give me a second…"
    public static let apologyDelaySeconds: TimeInterval = 45
    public static let apologyText = "Sorry, this is taking longer than usual."

    public private(set) var epoch = 0
    public private(set) var caption = CaptionState()
    public private(set) var firedTagIndexes: [Int] = []
    public private(set) var bargeInOrder: [String] = []
    /// Answers spoken without a voice (debug asks): tags fire at once.
    public var isSilent = false
    /// The primary voice failed during this answer and the fallback spoke.
    public private(set) var didUseFallback = false
    public var primaryEngineName: String { primaryEngine.name }
    public var spokenEngineName: String { didUseFallback ? fallbackEngine.name : primaryEngine.name }
    public var echoGuard = EchoGuard()
    public var now: () -> Date = Date.init

    private let primaryEngine: SpeechEngine
    private let fallbackEngine: SpeechEngine
    private weak var host: SpeechCoordinatorHost?

    private var segmentsByID: [Int: CaptionSegment] = [:]
    private var segmentOrder: [Int] = []
    private var finishedSegmentIDs: Set<Int> = []
    private var spokenCharactersBySegment: [Int: Int] = [:]
    private var timeline: CaptionTimeline?
    private var pointTagIndexes: Set<Int> = []
    private var knownTagIndexes: Set<Int> = []
    private var isAnswerOpen = false
    private var hasEndedAnswer = false
    private var awaitingWorkers = false
    private var isPrimaryDisabledForAnswer = false
    private var fallbackSegmentIDs: Set<Int> = []
    private var heldForPrimary: [CaptionSegment] = []
    private var primarySegmentIDs: Set<Int> = []
    private var startedSegmentIDs: Set<Int> = []
    private var apologyTask: Task<Void, Never>?
    private var lastEchoGuardRefreshDate: Date?

    public init(primaryEngine: SpeechEngine, fallbackEngine: SpeechEngine, host: SpeechCoordinatorHost) {
        self.primaryEngine = primaryEngine
        self.fallbackEngine = fallbackEngine
        self.host = host
        primaryEngine.callbacks = makeCallbacks(isPrimary: true)
        fallbackEngine.callbacks = makeCallbacks(isPrimary: false)
    }

    /// An answer is in progress (streaming or still being spoken).
    public var isSpeaking: Bool { isAnswerOpen }
    /// Paused by the user (board Space / "pause"); the voice holds its place.
    public private(set) var isPaused = false
    public var hasSpokenAnything: Bool { spokenCharactersBySegment.values.contains { $0 > 0 } || !finishedSegmentIDs.isEmpty }

    /// The host can be set after creation (it may need the coordinator first).
    public func replaceHost(_ newHost: SpeechCoordinatorHost) {
        host = newHost
    }

    // MARK: - Answer lifecycle

    /// A new answer; returns its epoch.
    @discardableResult
    public func beginAnswer() -> Int {
        epoch += 1
        segmentsByID = [:]
        segmentOrder = []
        finishedSegmentIDs = []
        spokenCharactersBySegment = [:]
        timeline = nil
        pointTagIndexes = []
        knownTagIndexes = []
        firedTagIndexes = []
        isAnswerOpen = true
        isPaused = false
        hasEndedAnswer = false
        awaitingWorkers = false
        isPrimaryDisabledForAnswer = false
        didUseFallback = false
        fallbackSegmentIDs = []
        heldForPrimary = []
        primarySegmentIDs = []
        startedSegmentIDs = []
        apologyTask?.cancel()
        caption = CaptionState()
        primaryEngine.begin(epoch: epoch)
        fallbackEngine.begin(epoch: epoch)
        return epoch
    }

    /// A tag was parsed (resolve now, fire on its words).
    public func registerTag(index: Int, isPoint: Bool) {
        knownTagIndexes.insert(index)
        if isPoint { pointTagIndexes.insert(index) }
    }

    public func enqueue(_ segment: CaptionSegment) {
        guard isAnswerOpen else { return }
        segmentsByID[segment.id] = segment
        segmentOrder.append(segment.id)
        clearStatus()
        if isSilent || !segment.hasSpeech {
            // Nothing to wait for: show it and fire its tags now.
            startSegment(segment.id)
            finishSegment(segment.id)
            return
        }
        if isPrimaryDisabledForAnswer || !fallbackSegmentIDs.subtracting(finishedSegmentIDs).isEmpty {
            if isPrimaryDisabledForAnswer {
                fallbackSegmentIDs.insert(segment.id)
                fallbackEngine.enqueue(segment)
            } else {
                heldForPrimary.append(segment)
            }
            return
        }
        primarySegmentIDs.insert(segment.id)
        primaryEngine.enqueue(segment)
    }

    /// The current Claude stream ended. With workers spawned the answer
    /// stays open (a follow-up stream continues it).
    public func streamDidFinish(spawnedWorkers: Bool) {
        guard isAnswerOpen else { return }
        if spawnedWorkers {
            awaitingWorkers = true
            caption.statusText = Self.workerStatusText
            caption.isVisible = true
            publishCaption()
            scheduleApology()
            return
        }
        awaitingWorkers = false
        hasEndedAnswer = true
        apologyTask?.cancel()
        primaryEngine.endOfAnswer()
        fallbackEngine.endOfAnswer()
        finishAnswerIfPlayedOut()
    }

    // MARK: - Pause

    /// Holds the voice where it is (both engines; the fallback may be speaking).
    public func pause() {
        guard isAnswerOpen, !isPaused else { return }
        isPaused = true
        primaryEngine.pause()
        fallbackEngine.pause()
        host?.log("paused")
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        primaryEngine.resume()
        fallbackEngine.resume()
        host?.log("resumed")
    }

    // MARK: - Barge-in

    public enum BargeInTrigger: String, Sendable {
        case pushToTalk, escape, voiceCommand, newQuestion
    }

    /// Stops everything, in the documented order.
    public func bargeIn(_ trigger: BargeInTrigger) {
        guard isAnswerOpen else { return }
        bargeInOrder = []
        epoch += 1
        bargeInOrder.append("epoch")
        host?.cancelClaudeAndWorkers()
        bargeInOrder.append("cancelClaude")
        primaryEngine.stopNow()
        fallbackEngine.stopNow()
        bargeInOrder.append("stopVoice")
        caption.isFrozen = true
        // Esc hides the bubble; other triggers leave the cut-off text up briefly.
        if trigger == .escape { caption.isVisible = false }
        if let currentID = caption.current?.id, let segment = segmentsByID[currentID] {
            caption.revealedDisplayCharacters = segment.displayRevealCount(spokenCharacters: spokenCharactersBySegment[currentID] ?? 0)
        }
        publishCaption()
        bargeInOrder.append("freezeCaption")
        let unfiredTags = knownTagIndexes.subtracting(firedTagIndexes).sorted()
        host?.dropUnfiredTags(unfiredTags)
        bargeInOrder.append("dropTags")
        apologyTask?.cancel()
        isAnswerOpen = false
        host?.answerDidFinish(historyText: spokenText + " [interrupted]", wasInterrupted: true)
        bargeInOrder.append("history")
        host?.log("barge-in by \(trigger.rawValue)")
    }

    /// A word heard on the open mic; barge in if it's a real "stop"/"wait".
    @discardableResult
    public func heardWhileSpeaking(_ heardText: String) -> Bool {
        guard isAnswerOpen, echoGuard.accepts(heardText, at: now()) else { return false }
        bargeIn(.voiceCommand)
        return true
    }

    /// "aec" mode (P6.4): while playing only "stop" / "wait" / "clicky stop"
    /// (the whole partial) barge in, and only if Clicky didn't just say it.
    @discardableResult
    public func heardWhileSpeakingWithEchoCancellation(_ heardText: String) -> Bool {
        guard isAnswerOpen, echoGuard.acceptsWhilePlaying(heardText, at: now()) else { return false }
        bargeIn(.voiceCommand)
        return true
    }

    /// The mic most likely heard Clicky: the partial's last 4 words are
    /// ≥ 60 % words it said in the last 4 seconds.
    public func isLikelyEcho(_ heardText: String) -> Bool {
        echoGuard.isLikelyEcho(heardText, at: now())
    }

    /// Everything spoken so far, in order (whole segments + the current one's spoken part).
    public var spokenText: String {
        var text = ""
        for segmentID in segmentOrder {
            guard let segment = segmentsByID[segmentID] else { continue }
            let spokenCount = finishedSegmentIDs.contains(segmentID) ? segment.speechLength : (spokenCharactersBySegment[segmentID] ?? 0)
            guard spokenCount > 0 else { continue }
            text += String(segment.speech.prefix(spokenCount))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Caption ticks (60 Hz, from the app)

    @discardableResult
    public func tickCaption() -> Bool {
        guard var currentTimeline = timeline, !caption.isFrozen, let currentID = caption.current?.id,
              let segment = segmentsByID[currentID] else { return false }
        guard currentTimeline.tick() else { return false }
        timeline = currentTimeline
        caption.revealedDisplayCharacters = segment.displayRevealCount(spokenCharacters: currentTimeline.revealed)
        publishCaption()
        return true
    }

    public var needsCaptionTicks: Bool { !(timeline?.isCaughtUp ?? true) }

    // MARK: - Engine callbacks

    private func makeCallbacks(isPrimary: Bool) -> SpeechEngineCallbacks {
        SpeechEngineCallbacks(
            onSegmentStart: { [weak self] segmentID in self?.startSegment(segmentID) },
            onProgress: { [weak self] segmentID, spoken, leadSpoken, isExact in
                self?.progress(segmentID: segmentID, spoken: spoken, leadSpoken: leadSpoken, isExact: isExact)
            },
            onSegmentEnd: { [weak self] segmentID in self?.finishSegment(segmentID) },
            onAllPlayed: { [weak self] in self?.engineDidPlayEverything(isPrimary: isPrimary) },
            onFailure: { [weak self] unspoken, restOfAnswer in
                guard isPrimary else { return }
                self?.primaryFailed(unspoken: unspoken, restOfAnswer: restOfAnswer)
            }
        )
    }

    private func startSegment(_ segmentID: Int) {
        guard let segment = segmentsByID[segmentID], !caption.isFrozen else { return }
        startedSegmentIDs.insert(segmentID)
        if caption.current?.id != segmentID {
            caption.previous = caption.current
            caption.current = segment
            caption.revealedDisplayCharacters = 0
            timeline = CaptionTimeline(totalCharacters: segment.speechLength)
        }
        caption.isVisible = true
        echoGuard.recordSpoken(segment.speech, at: now())
        publishCaption()
        host?.segmentDidStart(segment)
        progress(segmentID: segmentID, spoken: 0, leadSpoken: 0, isExact: true)
    }

    private func progress(segmentID: Int, spoken: Int, leadSpoken: Int, isExact: Bool) {
        guard let segment = segmentsByID[segmentID], !caption.isFrozen else { return }
        spokenCharactersBySegment[segmentID] = max(spokenCharactersBySegment[segmentID] ?? 0, spoken)
        refreshEchoGuardWhilePlaying(segment)
        if caption.current?.id == segmentID, var currentTimeline = timeline {
            if isExact { currentTimeline.applyExact(spoken) } else { currentTimeline.applyEstimate(spoken) }
            timeline = currentTimeline
            caption.revealedDisplayCharacters = segment.displayRevealCount(spokenCharacters: currentTimeline.revealed)
            publishCaption()
        }
        host?.segmentDidProgress(segment, spokenCharacters: spoken)
        for anchor in segment.anchors {
            let isPoint = pointTagIndexes.contains(anchor.tagIndex)
            let isReached = isPoint ? leadSpoken > anchor.prevWordStart || leadSpoken >= segment.speechLength || anchor.speechOffset == 0
                                    : spoken >= anchor.speechOffset
            if isReached { fire(anchor.tagIndex) }
        }
    }

    private func finishSegment(_ segmentID: Int) {
        guard let segment = segmentsByID[segmentID], !finishedSegmentIDs.contains(segmentID) else { return }
        if caption.current?.id != segmentID { startSegment(segmentID) }
        guard !caption.isFrozen else { return }
        // Tags past the end of the speech fire at the segment's end.
        for anchor in segment.anchors { fire(anchor.tagIndex) }
        finishedSegmentIDs.insert(segmentID)
        spokenCharactersBySegment[segmentID] = segment.speechLength
        if caption.current?.id == segmentID {
            timeline?.complete()
            caption.revealedDisplayCharacters = segment.display.count
            publishCaption()
        }
        echoGuard.recordSpoken(segment.speech, at: now())
        host?.segmentDidEnd(segment)
        if fallbackSegmentIDs.contains(segmentID), fallbackSegmentIDs.isSubset(of: finishedSegmentIDs), !isPrimaryDisabledForAnswer {
            // Apple finished Qwen's leftovers: later segments go back to Qwen.
            let held = heldForPrimary
            heldForPrimary = []
            for heldSegment in held {
                primarySegmentIDs.insert(heldSegment.id)
                primaryEngine.enqueue(heldSegment)
            }
            if hasEndedAnswer { primaryEngine.endOfAnswer() }
        }
        finishAnswerIfPlayedOut()
    }

    /// A long segment keeps counting as "just said" while it plays
    /// (at most twice a second).
    private func refreshEchoGuardWhilePlaying(_ segment: CaptionSegment) {
        let currentDate = now()
        if let lastEchoGuardRefreshDate, currentDate.timeIntervalSince(lastEchoGuardRefreshDate) < 0.5 { return }
        lastEchoGuardRefreshDate = currentDate
        echoGuard.recordSpoken(segment.speech, at: currentDate)
    }

    private func fire(_ tagIndex: Int) {
        guard !firedTagIndexes.contains(tagIndex), !caption.isFrozen else { return }
        firedTagIndexes.append(tagIndex)
        host?.fireTag(index: tagIndex)
    }

    private func engineDidPlayEverything(isPrimary: Bool) {
        finishAnswerIfPlayedOut()
    }

    private func primaryFailed(unspoken: [CaptionSegment], restOfAnswer: Bool) {
        host?.log("primary voice failed (\(unspoken.count) unspoken, rest=\(restOfAnswer))")
        didUseFallback = true
        if restOfAnswer { isPrimaryDisabledForAnswer = true }
        let unspokenIDs = Set(unspoken.map(\.id))
        let waitingOnPrimary = segmentOrder.filter { segmentID in
            primarySegmentIDs.contains(segmentID) && !startedSegmentIDs.contains(segmentID)
                && !finishedSegmentIDs.contains(segmentID) && !unspokenIDs.contains(segmentID)
        }
        if !restOfAnswer, !unspoken.isEmpty, !waitingOnPrimary.isEmpty {
            // Take them back from the primary; they return once the fallback is done.
            primaryEngine.stopNow()
            heldForPrimary = waitingOnPrimary.compactMap { segmentsByID[$0] } + heldForPrimary
        }
        for segment in unspoken where segmentsByID[segment.id] != nil && !finishedSegmentIDs.contains(segment.id) {
            fallbackSegmentIDs.insert(segment.id)
            fallbackEngine.enqueue(segment)
        }
        if hasEndedAnswer { fallbackEngine.endOfAnswer() }
    }

    private func finishAnswerIfPlayedOut() {
        guard isAnswerOpen, hasEndedAnswer, !awaitingWorkers, heldForPrimary.isEmpty,
              segmentOrder.allSatisfy({ finishedSegmentIDs.contains($0) }) else { return }
        isAnswerOpen = false
        apologyTask?.cancel()
        // Anything still unfired (its segment never reached it) fires now.
        for tagIndex in knownTagIndexes.subtracting(firedTagIndexes).sorted() { fire(tagIndex) }
        host?.answerDidFinish(historyText: spokenText, wasInterrupted: false)
    }

    private func clearStatus() {
        guard caption.statusText != nil else { return }
        caption.statusText = nil
        awaitingWorkers = false
        apologyTask?.cancel()
        publishCaption()
    }

    private func scheduleApology() {
        apologyTask?.cancel()
        let answerEpoch = epoch
        apologyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.apologyDelaySeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.epoch == answerEpoch, self.awaitingWorkers else { return }
            self.host?.speakApology(Self.apologyText)
        }
    }

    private func publishCaption() {
        host?.captionDidChange(caption)
    }
}
