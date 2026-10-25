//
//  BoardNarration.swift
//  ClickyCore
//
//  Narrating a board step by step, as pure logic (the app owns the voice,
//  the panel and the clock; tests drive this with a mock clock):
//   - BoardNarrationScript turns each step's `say` into caption segments
//     (ResponseRouter for tags → NarrationSegmenter → CaptionParser, every
//     segment tagged with boardStep) and finds each cue word's offset.
//   - BoardNarrator is the state machine. Visuals never lead the voice: a
//     step is revealed when its FIRST segment starts playing, never before;
//     a lagging voice simply holds the board. A step with nothing to say
//     holds 1.2 s (later steps wait to be spoken until it's done). Elements
//     of a step appear spread over min(0.6 × the step's duration, 0.5 s ×
//     count); a cued element appears when its word is spoken (at the latest
//     when its segment ends). `point` asks the app to fly the companion.
//     next / back / replay / pause / resume steer it by hand.
//  The narrator only emits actions; the app performs them (speak a step's
//  segments, stop the voice, fly, end of speech).
//  P6.7 progressive boards: helper sections arrive while the board is being
//  narrated (mergeSection). A section still showing its placeholder is
//  decided when the voice gets there: one bridge line and it's skipped;
//  when it arrives later its steps go in just before the recap (in plan
//  order among themselves). Whatever still hasn't come when the voice
//  reaches the recap (or the end) is dropped with one short line. The
//  recap and a pending section are never handed to the voice early.
//

import Foundation

// MARK: - Script

public struct BoardCueAnchor: Equatable, Sendable {
    public let elementIdentifier: String
    public let segmentID: Int
    /// Spoken characters before the cue word (it appears once speech passes this).
    public let speechOffset: Int
}

public struct BoardScriptTag: Equatable, Sendable {
    /// Global tag index (the segments' placeholders use it).
    public let index: Int
    public let tag: ParsedTag
}

public struct BoardStepScript: Equatable, Sendable {
    /// Index into board.steps (0-based).
    public let stepIndex: Int
    public let stepNumber: Int
    public let segments: [CaptionSegment]
    public let tags: [BoardScriptTag]
    public let cueAnchors: [BoardCueAnchor]

    /// Nothing to speak: the step holds 1.2 s instead.
    public var isSilent: Bool { !segments.contains(where: \.hasSpeech) }
    public var spokenText: String { segments.map(\.speech).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A rough speaking time (15 characters a second), for spreading reveals.
    public var estimatedDuration: TimeInterval { max(0.6, Double(spokenText.count) / BoardNarrator.estimatedCharactersPerSecond) }

    /// The same script for a step that moved (a section was merged or dropped).
    func reindexed(stepIndex newStepIndex: Int, stepNumber newStepNumber: Int) -> BoardStepScript {
        let renumberedSegments = segments.map { segment -> CaptionSegment in
            var renumberedSegment = segment
            renumberedSegment.boardStep = newStepNumber
            return renumberedSegment
        }
        return BoardStepScript(stepIndex: newStepIndex, stepNumber: newStepNumber, segments: renumberedSegments, tags: tags, cueAnchors: cueAnchors)
    }
}

public enum BoardNarrationScript {
    /// Board tags are numbered from here, clear of the answer's own tags.
    public static let firstBoardTagIndex = 100_000

    public static func make(board: WBBoard, firstSegmentID: Int = 1, firstTagIndex: Int = firstBoardTagIndex,
                            segmenterOptions: NarrationSegmenter.Options = NarrationSegmenter.Options()) -> [BoardStepScript] {
        var nextSegmentID = firstSegmentID
        var nextTagIndex = firstTagIndex
        var scripts: [BoardStepScript] = []
        for (stepIndex, step) in board.steps.enumerated() {
            var router = ResponseRouter(blockConsumers: [])
            let outputs = router.feed(step.say) + router.finish()
            var narration = ""
            var tags: [BoardScriptTag] = []
            for output in outputs {
                switch output {
                case .narration(let text): narration += text
                case .tag(let index, let tag): tags.append(BoardScriptTag(index: nextTagIndex + index, tag: tag))
                default: break
                }
            }
            var segmenter = NarrationSegmenter(options: segmenterOptions)
            let rawSegments = mergingSpeechlessSegments(segmenter.feed(narration) + segmenter.finish())
            var segments: [CaptionSegment] = []
            var placeholdersSeen = 0
            for rawSegment in rawSegments {
                var segment = CaptionParser.parse(rawSegment, id: nextSegmentID, firstTagIndex: nextTagIndex + placeholdersSeen)
                placeholdersSeen += rawSegment.filter { $0 == ResponseRouter.placeholder }.count
                segment.boardStep = step.number
                nextSegmentID += 1
                segments.append(segment)
            }
            nextTagIndex += router.tags.count
            scripts.append(BoardStepScript(stepIndex: stepIndex, stepNumber: step.number, segments: segments, tags: tags,
                                           cueAnchors: cueAnchors(for: step, segments: segments)))
        }
        return scripts
    }

    /// A segment with nothing to say would "start" the moment it's queued
    /// (the voice skips it), revealing its step early: it joins its neighbour.
    static func mergingSpeechlessSegments(_ rawSegments: [String]) -> [String] {
        var merged: [String] = []
        var carried = ""
        for rawSegment in rawSegments {
            let hasWords = rawSegment.contains { $0.isLetter || $0.isNumber }
            if !hasWords {
                if merged.isEmpty { carried += rawSegment } else { merged[merged.count - 1] += rawSegment }
                continue
            }
            merged.append(carried + rawSegment)
            carried = ""
        }
        if !carried.isEmpty { merged.append(carried) }
        return merged
    }

    /// Each cue's word, first found (case-insensitive, at a word start) in the step's segments.
    static func cueAnchors(for step: WBStep, segments: [CaptionSegment]) -> [BoardCueAnchor] {
        step.cues.compactMap { cue -> BoardCueAnchor? in
            let cueWord = cue.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cueWord.isEmpty else { return nil }
            for segment in segments {
                let speech = segment.speech.lowercased()
                var searchStart = speech.startIndex
                while let range = speech.range(of: cueWord, range: searchStart..<speech.endIndex) {
                    let isWordStart = range.lowerBound == speech.startIndex || !speech[speech.index(before: range.lowerBound)].isLetter
                    if isWordStart {
                        return BoardCueAnchor(elementIdentifier: cue.elementIdentifier, segmentID: segment.id,
                                              speechOffset: speech.distance(from: speech.startIndex, to: range.lowerBound))
                    }
                    searchStart = range.upperBound
                }
            }
            return nil
        }
    }
}

// MARK: - Narrator

public enum BoardNarrationAction: Equatable, Sendable {
    /// Give the voice this step's segments.
    case speak(stepIndex: Int)
    /// No more segments in this run (the app ends the answer's stream).
    case endOfSpeech
    /// Silence what the voice is saying (a step was picked by hand).
    case stopSpeech
    case revealStep(stepIndex: Int)
    /// Fly the companion to this board element.
    case point(elementIdentifier: String)
    case stepEnded(stepIndex: Int)
    /// Every step of the run has been shown and spoken.
    case finished
    /// A helper section isn't there yet: say ProgressiveBoard.bridgeLine.
    case bridge(sectionIdentifier: String)
    /// Helper sections that never came: say ProgressiveBoard.droppedLine.
    case dropSections(sectionIdentifiers: [String])
    /// `board` changed (a section merged or dropped): lay it out again.
    case boardChanged
}

public struct BoardNarrationLogEntry: Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable { case segmentStart, reveal, stepEnd, hold }
    public let kind: Kind
    public let stepNumber: Int
    public let segmentID: Int?
    /// Clock seconds.
    public let time: TimeInterval
}

public struct BoardNarrator: Sendable {
    public static let silentStepHoldSeconds: TimeInterval = 1.2
    public static let revealWindowFraction = 0.6
    public static let revealSecondsPerElement: TimeInterval = 0.5
    public static let estimatedCharactersPerSecond = 15.0
    /// Reveal time for "already there" (instant, no animation).
    public static let instantRevealTime: TimeInterval = -1_000_000

    public enum Mode: String, Sendable {
        case idle
        /// Steps one after another (the answer's narration, replay).
        case continuous
        /// One step picked by hand (next / back), then stop.
        case single
    }

    public private(set) var board: WBBoard
    public private(set) var scripts: [BoardStepScript]
    /// Helper sections whose lines haven't arrived (placeholder on the board).
    public private(set) var pendingSectionIdentifiers: [String]
    /// Board element id → when it starts appearing (clock seconds).
    public private(set) var revealTimes: [String: TimeInterval] = [:]
    /// The step on the board now (the last one revealed).
    public private(set) var currentStepIndex: Int?
    public private(set) var highlightedIdentifiers: [String] = []
    public private(set) var mode: Mode = .idle
    public private(set) var isPaused = false
    public private(set) var isFinished = false
    public private(set) var log: [BoardNarrationLogEntry] = []

    private var plan: [Int] = []
    private var planPosition = 0
    private var hasSentEndOfSpeech = false
    private var revealedSteps: Set<Int> = []
    private var spokenUnendedSteps: [Int] = []
    private var holdingStepIndex: Int?
    private var holdUntil: TimeInterval?
    private var pausedHoldRemaining: TimeInterval?
    private var stepIndexBySegmentID: [Int: Int] = [:]
    private var pendingCues: [Int: [BoardCueAnchor]] = [:]
    /// Helpers that failed: their section is dropped when the voice gets there.
    private var failedSectionIdentifiers: Set<String> = []
    /// Pending sections the voice already passed (bridge line said).
    private var bridgedSectionIdentifiers: Set<String> = []
    /// Steps of late sections, planned just before the recap.
    private var deferredStepIndexes: Set<Int> = []
    private var nextTagIndex: Int

    public init(board: WBBoard, scripts: [BoardStepScript]) {
        self.board = board
        self.scripts = scripts
        pendingSectionIdentifiers = ProgressiveBoard.pendingSectionIdentifiers(in: board)
        nextTagIndex = (scripts.flatMap(\.tags).map(\.index).max() ?? (BoardNarrationScript.firstBoardTagIndex - 1)) + 1
        rebuildSegmentIndex()
    }

    private mutating func rebuildSegmentIndex() {
        stepIndexBySegmentID = [:]
        for script in scripts {
            for segment in script.segments { stepIndexBySegmentID[segment.id] = script.stepIndex }
        }
    }

    public var stepCount: Int { scripts.count }
    public var currentStep: WBStep? { currentStepIndex.map { board.steps[$0] } }
    /// What the subtitle shows: the current step's words.
    public var currentSubtitle: String { currentStepIndex.map { scripts[$0].spokenText } ?? "" }

    // MARK: Runs

    /// The answer's narration: every step in order.
    public mutating func start(at now: TimeInterval) -> [BoardNarrationAction] {
        beginRun(mode: .continuous, plan: Array(scripts.indices), at: now)
    }

    /// Everything off the board, then narrate from the first step again.
    public mutating func replay(at now: TimeInterval) -> [BoardNarrationAction] {
        revealTimes = [:]
        revealedSteps = []
        currentStepIndex = nil
        highlightedIdentifiers = []
        return [.stopSpeech] + beginRun(mode: .continuous, plan: Array(scripts.indices), at: now)
    }

    /// Show steps before `stepIndex` at once, hide later ones, and narrate `stepIndex`.
    public mutating func goTo(stepIndex: Int, at now: TimeInterval) -> [BoardNarrationAction] {
        guard scripts.indices.contains(stepIndex) else { return [] }
        revealTimes = [:]
        revealedSteps = []
        for earlierIndex in 0..<stepIndex {
            for elementIdentifier in identifiersShown(byStep: earlierIndex) { revealTimes[elementIdentifier] = Self.instantRevealTime }
            revealedSteps.insert(earlierIndex)
        }
        currentStepIndex = stepIndex > 0 ? stepIndex - 1 : nil
        highlightedIdentifiers = []
        return [.stopSpeech] + beginRun(mode: .single, plan: [stepIndex], at: now)
    }

    public mutating func next(at now: TimeInterval) -> [BoardNarrationAction] {
        let targetIndex = (currentStepIndex ?? -1) + 1
        return targetIndex < scripts.count ? goTo(stepIndex: targetIndex, at: now) : []
    }

    public mutating func back(at now: TimeInterval) -> [BoardNarrationAction] {
        let targetIndex = (currentStepIndex ?? 0) - 1
        return targetIndex >= 0 ? goTo(stepIndex: targetIndex, at: now) : []
    }

    /// Everything shown at once (no voice): exports, a board without narration.
    public mutating func revealEverything() {
        for index in scripts.indices {
            for elementIdentifier in identifiersShown(byStep: index) where revealTimes[elementIdentifier] == nil {
                revealTimes[elementIdentifier] = Self.instantRevealTime
            }
            revealedSteps.insert(index)
        }
        for element in board.elements where revealTimes[element.id] == nil { revealTimes[element.id] = Self.instantRevealTime }
        currentStepIndex = scripts.isEmpty ? nil : scripts.count - 1
        highlightedIdentifiers = []
    }

    public mutating func pause(at now: TimeInterval) {
        guard !isPaused else { return }
        isPaused = true
        if let holdUntil {
            pausedHoldRemaining = max(0, holdUntil - now)
            self.holdUntil = nil
        }
    }

    public mutating func resume(at now: TimeInterval) -> [BoardNarrationAction] {
        guard isPaused else { return [] }
        isPaused = false
        if let pausedHoldRemaining {
            holdUntil = now + pausedHoldRemaining
            self.pausedHoldRemaining = nil
        }
        return tick(at: now)
    }

    private mutating func beginRun(mode newMode: Mode, plan newPlan: [Int], at now: TimeInterval) -> [BoardNarrationAction] {
        mode = newMode
        plan = newPlan
        planPosition = 0
        hasSentEndOfSpeech = false
        spokenUnendedSteps = []
        holdingStepIndex = nil
        holdUntil = nil
        pausedHoldRemaining = nil
        isPaused = false
        isFinished = false
        pendingCues = [:]
        bridgedSectionIdentifiers = []
        deferredStepIndexes = []
        return advance(at: now)
    }

    /// Hands the voice every step up to the next silent one; a silent step
    /// is shown (and held) only once everything before it has been spoken.
    private mutating func advance(at now: TimeInterval) -> [BoardNarrationAction] {
        var actions: [BoardNarrationAction] = []
        // Back-to-back pending sections share one bridge line.
        var hasBridgedSinceLastStep = false
        while planPosition < plan.count, holdingStepIndex == nil {
            let stepIndex = plan[planPosition]
            if let pendingSectionIdentifier = pendingSection(placeholderStepIndex: stepIndex) {
                // Decided when the voice gets here: by then the helper may be done.
                guard spokenUnendedSteps.isEmpty else { break }
                planPosition += 1
                let passActions = passPendingSection(pendingSectionIdentifier, placeholderStepIndex: stepIndex,
                                                     saysBridge: !hasBridgedSinceLastStep, at: now)
                if passActions.contains(where: { if case .bridge = $0 { return true } else { return false } }) { hasBridgedSinceLastStep = true }
                actions += passActions
                continue
            }
            if mode == .continuous, !pendingSectionIdentifiers.isEmpty, isRecapStep(stepIndex) {
                // The recap waits for the voice; what hasn't come by then is dropped.
                guard spokenUnendedSteps.isEmpty else { break }
                actions += dropSections(pendingSectionIdentifiers)
                continue
            }
            if scripts[stepIndex].isSilent {
                guard spokenUnendedSteps.isEmpty else { break }
                actions += reveal(stepIndex: stepIndex, at: now)
                holdingStepIndex = stepIndex
                log.append(BoardNarrationLogEntry(kind: .hold, stepNumber: scripts[stepIndex].stepNumber, segmentID: nil, time: now))
                if isPaused {
                    pausedHoldRemaining = Self.silentStepHoldSeconds
                } else {
                    holdUntil = now + Self.silentStepHoldSeconds
                }
                break
            }
            spokenUnendedSteps.append(stepIndex)
            planPosition += 1
            hasBridgedSinceLastStep = false
            actions.append(.speak(stepIndex: stepIndex))
        }
        if planPosition >= plan.count, holdingStepIndex == nil, mode == .continuous, !pendingSectionIdentifiers.isEmpty {
            // No recap: the end is where late sections are given up.
            guard spokenUnendedSteps.isEmpty else { return actions }
            actions += dropSections(pendingSectionIdentifiers)
        }
        if planPosition >= plan.count, holdingStepIndex == nil {
            if !hasSentEndOfSpeech {
                hasSentEndOfSpeech = true
                actions.append(.endOfSpeech)
            }
            if spokenUnendedSteps.isEmpty, !isFinished, mode != .idle {
                isFinished = true
                actions.append(.finished)
            }
        }
        return actions
    }

    // MARK: Voice events

    public mutating func segmentStarted(segmentID: Int, at now: TimeInterval) -> [BoardNarrationAction] {
        guard let stepIndex = stepIndexBySegmentID[segmentID], spokenUnendedSteps.contains(stepIndex) else { return [] }
        log.append(BoardNarrationLogEntry(kind: .segmentStart, stepNumber: scripts[stepIndex].stepNumber, segmentID: segmentID, time: now))
        guard !revealedSteps.contains(stepIndex) else { return [] }
        var actions: [BoardNarrationAction] = []
        // Steps are shown in order: one whose voice was skipped comes first.
        for earlierIndex in spokenUnendedSteps.prefix(while: { $0 != stepIndex }) where !revealedSteps.contains(earlierIndex) {
            actions += reveal(stepIndex: earlierIndex, at: now)
        }
        actions += reveal(stepIndex: stepIndex, at: now)
        actions += revealReachedCues(segmentID: segmentID, spokenCharacters: 0, at: now)
        return actions
    }

    public mutating func segmentProgress(segmentID: Int, spokenCharacters: Int, at now: TimeInterval) -> [BoardNarrationAction] {
        revealReachedCues(segmentID: segmentID, spokenCharacters: spokenCharacters, at: now)
    }

    public mutating func segmentEnded(segmentID: Int, at now: TimeInterval) -> [BoardNarrationAction] {
        guard let stepIndex = stepIndexBySegmentID[segmentID], spokenUnendedSteps.contains(stepIndex) else { return [] }
        var actions: [BoardNarrationAction] = []
        if !revealedSteps.contains(stepIndex) { actions += segmentStarted(segmentID: segmentID, at: now) }
        actions += revealReachedCues(segmentID: segmentID, spokenCharacters: .max, at: now)
        guard scripts[stepIndex].segments.last?.id == segmentID else { return actions }
        spokenUnendedSteps.removeAll { $0 == stepIndex }
        log.append(BoardNarrationLogEntry(kind: .stepEnd, stepNumber: scripts[stepIndex].stepNumber, segmentID: segmentID, time: now))
        actions.append(.stepEnded(stepIndex: stepIndex))
        return actions + advance(at: now)
    }

    /// Ends a silent step's hold once its 1.2 s are up (not while paused).
    public mutating func tick(at now: TimeInterval) -> [BoardNarrationAction] {
        guard !isPaused, let holdingStepIndex, let holdUntil, now >= holdUntil else { return [] }
        self.holdingStepIndex = nil
        self.holdUntil = nil
        planPosition += 1
        log.append(BoardNarrationLogEntry(kind: .stepEnd, stepNumber: scripts[holdingStepIndex].stepNumber, segmentID: nil, time: now))
        return [.stepEnded(stepIndex: holdingStepIndex)] + advance(at: now)
    }

    /// The voice was cut off (barge-in): stop where we are.
    public mutating func stop() {
        mode = .idle
        plan = []
        planPosition = 0
        spokenUnendedSteps = []
        holdingStepIndex = nil
        holdUntil = nil
        pausedHoldRemaining = nil
        pendingCues = [:]
        isPaused = false
    }

    // MARK: Progressive sections (P6.7)

    /// A helper's section arrived: it replaces the placeholder (in place when
    /// the voice hasn't got there yet, else just before the recap). New
    /// segments are numbered from `firstSegmentID`; returns the next free id.
    public mutating func mergeSection(_ sectionIdentifier: String, workerBoard: WBBoard, firstSegmentID: Int,
                                      segmenterOptions: NarrationSegmenter.Options = NarrationSegmenter.Options(),
                                      at now: TimeInterval) -> (actions: [BoardNarrationAction], nextSegmentID: Int) {
        guard pendingSectionIdentifiers.contains(sectionIdentifier),
              let change = ProgressiveBoard.replacePlaceholder(ofSection: sectionIdentifier, in: board, with: workerBoard) else {
            return ([], firstSegmentID)
        }
        var insertedBoard = change.board
        insertedBoard.steps = change.insertedStepIndexes.map { change.board.steps[$0] }
        let insertedScripts = BoardNarrationScript.make(board: insertedBoard, firstSegmentID: firstSegmentID, firstTagIndex: nextTagIndex,
                                                        segmenterOptions: segmenterOptions)
        let nextSegmentID = (insertedScripts.flatMap(\.segments).map(\.id).max() ?? (firstSegmentID - 1)) + 1
        let wasBridged = bridgedSectionIdentifiers.contains(sectionIdentifier)
        pendingSectionIdentifiers.removeAll { $0 == sectionIdentifier }
        bridgedSectionIdentifiers.remove(sectionIdentifier)
        failedSectionIdentifiers.remove(sectionIdentifier)
        apply(change, insertedScripts: insertedScripts, placesLate: wasBridged)
        var actions: [BoardNarrationAction] = [.boardChanged]
        if mode != .idle, !isFinished { actions += advance(at: now) }
        return (actions, nextSegmentID)
    }

    /// A helper failed: its section is dropped when the voice gets there.
    public mutating func markSectionFailed(_ sectionIdentifier: String) {
        guard pendingSectionIdentifiers.contains(sectionIdentifier) else { return }
        failedSectionIdentifiers.insert(sectionIdentifier)
    }

    /// The pending section a step only shows the placeholder of (its placeholder step).
    private func pendingSection(placeholderStepIndex stepIndex: Int) -> String? {
        guard !pendingSectionIdentifiers.isEmpty else { return nil }
        let step = board.steps[stepIndex]
        let shownIdentifiers = step.shownIdentifiers + step.highlightedIdentifiers
        guard !shownIdentifiers.isEmpty else { return nil }
        let placeholdersBySection = Dictionary(uniqueKeysWithValues: pendingSectionIdentifiers.map {
            (ProgressiveBoard.placeholderIdentifier(forSection: $0), $0)
        })
        guard shownIdentifiers.allSatisfy({ placeholdersBySection[$0] != nil }) else { return nil }
        return placeholdersBySection[shownIdentifiers[0]]
    }

    /// The voice reached a pending section: bridge (placeholder shown) or, for a failed helper, drop.
    private mutating func passPendingSection(_ sectionIdentifier: String, placeholderStepIndex: Int, saysBridge: Bool,
                                             at now: TimeInterval) -> [BoardNarrationAction] {
        if failedSectionIdentifiers.contains(sectionIdentifier) { return dropSections([sectionIdentifier]) }
        var actions = reveal(stepIndex: placeholderStepIndex, at: now)
        if !bridgedSectionIdentifiers.contains(sectionIdentifier) {
            bridgedSectionIdentifiers.insert(sectionIdentifier)
            if saysBridge { actions.append(.bridge(sectionIdentifier: sectionIdentifier)) }
        }
        return actions
    }

    private func isRecapStep(_ stepIndex: Int) -> Bool {
        isRecapStep(stepIndex, in: board)
    }

    private mutating func dropSections(_ sectionIdentifiers: [String]) -> [BoardNarrationAction] {
        var droppedIdentifiers: [String] = []
        for sectionIdentifier in sectionIdentifiers {
            pendingSectionIdentifiers.removeAll { $0 == sectionIdentifier }
            bridgedSectionIdentifiers.remove(sectionIdentifier)
            failedSectionIdentifiers.remove(sectionIdentifier)
            guard let change = ProgressiveBoard.replacePlaceholder(ofSection: sectionIdentifier, in: board, with: nil) else { continue }
            apply(change, insertedScripts: [], placesLate: false)
            droppedIdentifiers.append(sectionIdentifier)
        }
        guard !droppedIdentifiers.isEmpty else { return [] }
        return [.dropSections(sectionIdentifiers: droppedIdentifiers), .boardChanged]
    }

    /// Moves every step index through the change and plans the inserted steps.
    private mutating func apply(_ change: ProgressiveBoard.SectionChange, insertedScripts: [BoardStepScript], placesLate: Bool) {
        let mapping = change.stepIndexMapping
        var newScripts = [BoardStepScript?](repeating: nil, count: change.board.steps.count)
        for script in scripts {
            guard let newIndex = mapping[script.stepIndex] else { continue }
            newScripts[newIndex] = script.reindexed(stepIndex: newIndex, stepNumber: change.board.steps[newIndex].number)
        }
        for (offset, insertedIndex) in change.insertedStepIndexes.enumerated() where offset < insertedScripts.count {
            newScripts[insertedIndex] = insertedScripts[offset].reindexed(stepIndex: insertedIndex, stepNumber: change.board.steps[insertedIndex].number)
        }
        nextTagIndex = max(nextTagIndex, (insertedScripts.flatMap(\.tags).map(\.index).max() ?? (nextTagIndex - 1)) + 1)

        // The plan: remapped; a removed step not yet reached marks the in-place spot.
        var newPlan: [Int] = []
        var newPlanPosition = 0
        var inPlacePosition: Int?
        for (position, stepIndex) in plan.enumerated() {
            guard let newIndex = mapping[stepIndex] else {
                if position >= planPosition, inPlacePosition == nil { inPlacePosition = newPlan.count }
                continue
            }
            if position < planPosition { newPlanPosition += 1 }
            newPlan.append(newIndex)
        }
        let remappedDeferred = Set(deferredStepIndexes.compactMap { mapping[$0] })
        let insertedIndexes = change.insertedStepIndexes
        if mode != .idle, let lastInsertedIndex = insertedIndexes.last {
            var insertionPosition: Int
            if let inPlacePosition {
                insertionPosition = inPlacePosition
            } else {
                insertionPosition = newPlan.count
                for position in newPlanPosition..<newPlan.count {
                    let plannedIndex = newPlan[position]
                    let isRecap = isRecapStep(plannedIndex, in: change.board)
                    let isLaterDeferred = remappedDeferred.contains(plannedIndex) && plannedIndex > lastInsertedIndex
                    let isLaterInPlan = !placesLate && plannedIndex > lastInsertedIndex
                    if isRecap || isLaterDeferred || isLaterInPlan {
                        insertionPosition = position
                        break
                    }
                }
            }
            insertionPosition = max(insertionPosition, newPlanPosition)
            if mode == .continuous || inPlacePosition != nil { newPlan.insert(contentsOf: insertedIndexes, at: insertionPosition) }
        }

        func nearestSurvivingIndex(_ oldIndex: Int) -> Int? {
            for candidate in stride(from: oldIndex, through: 0, by: -1) {
                if let newIndex = mapping[candidate] { return newIndex }
            }
            return nil
        }
        board = change.board
        scripts = newScripts.enumerated().map { index, script in
            script ?? BoardStepScript(stepIndex: index, stepNumber: change.board.steps[index].number, segments: [], tags: [], cueAnchors: [])
        }
        plan = newPlan
        planPosition = newPlanPosition
        deferredStepIndexes = remappedDeferred.union(placesLate ? Set(insertedIndexes) : [])
        revealedSteps = Set(revealedSteps.compactMap { mapping[$0] })
        spokenUnendedSteps = spokenUnendedSteps.compactMap { mapping[$0] }
        holdingStepIndex = holdingStepIndex.flatMap { mapping[$0] }
        currentStepIndex = currentStepIndex.flatMap(nearestSurvivingIndex)
        let elementIdentifiers = Set(board.elements.map(\.id))
        revealTimes = revealTimes.filter { elementIdentifiers.contains($0.key) || isFlowInnerIdentifier($0.key) }
        highlightedIdentifiers = highlightedIdentifiers.filter { elementIdentifiers.contains($0) }
        rebuildSegmentIndex()
    }

    private func isRecapStep(_ stepIndex: Int, in someBoard: WBBoard) -> Bool {
        guard let recapSectionIdentifier = someBoard.sections.first(where: { $0.id.lowercased() == "recap" || $0.title.lowercased() == "recap" })?.id else { return false }
        return ProgressiveBoard.sectionIdentifier(of: someBoard.steps[stepIndex], in: someBoard) == recapSectionIdentifier
    }

    private func isFlowInnerIdentifier(_ identifier: String) -> Bool {
        identifier.contains(".")
    }

    // MARK: Reveal

    private mutating func reveal(stepIndex: Int, at now: TimeInterval) -> [BoardNarrationAction] {
        guard !revealedSteps.contains(stepIndex) else { return [] }
        revealedSteps.insert(stepIndex)
        let step = board.steps[stepIndex]
        let script = scripts[stepIndex]
        currentStepIndex = stepIndex
        highlightedIdentifiers = step.highlightedIdentifiers
        log.append(BoardNarrationLogEntry(kind: .reveal, stepNumber: script.stepNumber, segmentID: nil, time: now))

        let cuedIdentifiers = Set(script.cueAnchors.map(\.elementIdentifier))
        let newIdentifiers = identifiers(of: step).filter { revealTimes[$0] == nil && !cuedIdentifiers.contains($0) }
        let revealWindow = newIdentifiers.count > 1
            ? min(Self.revealWindowFraction * script.estimatedDuration, Self.revealSecondsPerElement * Double(newIdentifiers.count))
            : 0
        for (offsetIndex, elementIdentifier) in newIdentifiers.enumerated() {
            revealTimes[elementIdentifier] = now + revealWindow * Double(offsetIndex) / Double(max(1, newIdentifiers.count))
        }
        for cueAnchor in script.cueAnchors where revealTimes[cueAnchor.elementIdentifier] == nil {
            pendingCues[cueAnchor.segmentID, default: []].append(cueAnchor)
        }
        var actions: [BoardNarrationAction] = [.revealStep(stepIndex: stepIndex)]
        if let pointIdentifier = step.pointIdentifier { actions.append(.point(elementIdentifier: pointIdentifier)) }
        return actions
    }

    private mutating func revealReachedCues(segmentID: Int, spokenCharacters: Int, at now: TimeInterval) -> [BoardNarrationAction] {
        guard let cues = pendingCues[segmentID] else { return [] }
        var stillPending: [BoardCueAnchor] = []
        for cue in cues {
            if cue.speechOffset <= spokenCharacters {
                if revealTimes[cue.elementIdentifier] == nil { revealTimes[cue.elementIdentifier] = now }
            } else {
                stillPending.append(cue)
            }
        }
        pendingCues[segmentID] = stillPending.isEmpty ? nil : stillPending
        return []
    }

    /// Ids a step brings in: shown, then highlighted, then cued (each once).
    private func identifiers(of step: WBStep) -> [String] {
        var identifiers: [String] = []
        for identifier in step.shownIdentifiers + step.highlightedIdentifiers + step.cues.map(\.elementIdentifier) where !identifiers.contains(identifier) {
            identifiers.append(identifier)
        }
        return identifiers
    }

    private func identifiersShown(byStep stepIndex: Int) -> [String] {
        identifiers(of: board.steps[stepIndex])
    }
}
