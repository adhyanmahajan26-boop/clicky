//
//  AnswerSession.swift
//  leanring-buddy
//
//  One spoken answer, from Claude's first streamed word to the end of the
//  voice. Text deltas go through the ResponseRouter (tags out, workers and
//  blocks aside; a <codetask> goes to the CodeModeController when Code mode
//  is on) and the NarrationSegmenter; each segment is parsed for the
//  caption, cleaned of leaked ids (SpeechSafetyNet) and handed to the
//  SpeechCoordinator, which speaks it and fires its tags on their words.
//
//  Tags are resolved the moment they're parsed (their OCR re-check starts
//  then too) and drawn when they fire. WORKER tags spawn helpers right away;
//  when the stream ends with helpers running, the answer stays open and a
//  follow-up stream with their results continues it (same snapshot, same
//  registry, same epoch).
//
//  With the Qwen voice the segmenter cuts the first segment early
//  (NarrationSegmenter.Options.qwen): its first WAV only arrives whole.
//
//  P4: a <whiteboard> block is streamed into WBStreamParser as it arrives
//  (the panel opens with "Drawing…"); when it closes the board goes to the
//  BoardController, whose narrator feeds the steps' `say` segments into
//  this answer's coordinator (so captions, EchoGuard and barge-in work).
//  The stream's end waits until the narrator has handed over its last
//  step. A board too broken to use gets one repair call; if that fails the
//  steps' words are spoken without a board.
//
//  P6.7 progressive boards: a [WORKER:s<k> title:task] line names a board
//  section. That helper is asked for CWB lines of its section only
//  (WhiteboardPromptSection.workerSectionSystemPrompt); its reply is
//  filtered (WBWorkerSectionFilter) and merged straight into the board
//  (BoardController.mergeWorkerSection, or into the board before it's
//  presented when it's that quick), with no follow-up stream. Other helpers
//  (and section helpers of an answer that drew no board) still get the
//  follow-up stream with their results.
//

import ClickyCore
import CoreGraphics
import Foundation

@MainActor
final class AnswerSession: SpeechCoordinatorHost {
    let transcript: String
    let turnRecord: TurnRecord?
    let coordinator: SpeechCoordinator
    private unowned let companionManager: CompanionManager
    private(set) var groundedTurn: GroundedTurn

    private var router: ResponseRouter
    private let segmenterOptions: NarrationSegmenter.Options
    private var segmenter: NarrationSegmenter
    private var supervisor = CLIStreamSupervisor()
    /// Global index of this stream's tag 0 (follow-up streams continue the numbering).
    private var tagIndexOffset = 0
    private var placeholdersSeen = 0
    /// The next free caption segment id (the board's scripts take theirs from here too).
    var nextSegmentID = 1
    private(set) var rawResponse = ""
    private(set) var speechLeakCount = 0
    private(set) var badgeMentionCount = 0
    private var isFirstStream = true

    private enum PreparedTag {
        case mark(LiveScreenMark)
        case point(ResolvedTarget, CaptureFrame)
        /// A POINT at an element of the board on screen.
        case boardPoint(String)
        case clear
        /// A [SNAP:…] screenshot, taken when its words are spoken.
        case snapshot(SnapshotRequest)
        case unusable
    }

    private var preparedTags: [Int: PreparedTag] = [:]
    /// Marks already sent to the P6.1 Haiku zoom check (once each).
    private var zoomCheckedMarkIDs: Set<UUID> = []
    private var recheckOutcomes: [Int: MarkRecheck.Outcome] = [:]
    private var shownMarkIDsByTag: [Int: UUID] = [:]
    private var pendingFires: Set<Int> = []
    private var droppedTags: Set<Int> = []
    private var preparationChain: Task<Void, Never>?

    /// A MODE: whiteboard turn (workers show the board's shell).
    var isWhiteboardTurn = false
    /// This answer drew a board (its history gets the BOARD STATE).
    private(set) var presentedBoard = false
    private var whiteboardStreamParser: WBStreamParser?
    private var whiteboardSearchStartUTF16 = 0
    private var whiteboardFedUTF16 = 0
    private var isWhiteboardStreamClosed = false
    /// A board is being narrated (or repaired): the stream's end waits.
    private var isBoardSpeechOpen = false
    private var deferredStreamFinish: Bool?
    /// Claude's stream (and any follow-up) has ended.
    private var hasStreamEnded = false
    /// The board took the voice over (next / back / close): stop speaking,
    /// but a finished turn isn't cancelled.
    private var isYieldingToBoard = false

    private(set) var workerRequests: [CompanionWorkerRequest] = []
    private var workerTasks: [Task<CompanionWorkerResult, Never>] = []
    /// Index into workerTasks → the board section that helper draws (P6.7).
    private var boardSectionByWorkerIndex: [Int: (sectionIdentifier: String, title: String)] = [:]
    /// Helper sections that came back before the board was presented.
    private var earlyBoardSections: [(sectionIdentifier: String, board: WBBoard)] = []
    /// Helper sections whose helper failed or drew nothing usable.
    private var failedBoardSections: [String] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var isFinished = false
    private(set) var wasInterrupted = false

    init(transcript: String, groundedTurn: GroundedTurn, turnRecord: TurnRecord?, companionManager: CompanionManager, speaksResponse: Bool) {
        self.transcript = transcript
        self.groundedTurn = groundedTurn
        self.turnRecord = turnRecord
        self.companionManager = companionManager
        self.router = ResponseRouter(blockConsumers: AnswerSession.blockConsumers())
        self.segmenterOptions = companionManager.speechOutputClient.narrationSegmenterOptions
        self.segmenter = NarrationSegmenter(options: segmenterOptions)
        // A placeholder host is replaced by `self` right below (Swift needs
        // every property set before `self` can be passed).
        self.coordinator = companionManager.speechOutputClient.makeCoordinator(host: PlaceholderHost.shared)
        coordinator.replaceHost(self)
        coordinator.isSilent = !speaksResponse
        coordinator.beginAnswer()
        publishTextObstacles()
        // Estimated progress (Qwen, Apple without callbacks) is walked in at 60 Hz.
        let timer = Timer(timeInterval: 1.0 / CaptionTimeline.ticksPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.coordinator.needsCaptionTicks { self.coordinator.tickCaption() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        captionTickTimer = timer
    }

    private var captionTickTimer: Timer?
    /// Blocks this answer consumes (P4: the whiteboard).

    /// Waits until the answer has been fully spoken or interrupted.
    func waitUntilFinished() async {
        guard !hasSettled else { return }
        await withCheckedContinuation { continuation in finishContinuation = continuation }
    }

    // MARK: - Stream input

    func handle(_ event: CLIStreamEvent) {
        for action in supervisor.handle(event, hasSpokenAnything: coordinator.hasSpokenAnything) {
            perform(action)
        }
    }

    func streamEndedWithoutResult() {
        for action in supervisor.endOfStream() { perform(action) }
    }

    func streamFailed(_ failure: CLIStreamFailure) {
        perform(.fail(failure))
    }

    private func perform(_ action: CLIStreamSupervisor.Action) {
        switch action {
        case .feed(let text):
            rawResponse += text
            turnRecord?.markTiming("firstDelta")
            streamWhiteboardBody()
            route(router.feed(text))
        case .finish:
            route(router.finish())
            enqueue(segmenter.finish())
            let spawnedWorkers = isFirstStream && hasFollowUpWorkers
            finishStream(spawnedWorkers: spawnedWorkers)
        case .reset:
            // A new message before anything was spoken: start the answer over.
            turnRecord?.rawResponse += "\n--- message restarted ---\n"
            router = ResponseRouter(blockConsumers: Self.blockConsumers())
            segmenter = NarrationSegmenter(options: segmenterOptions)
            resetWhiteboardStream(searchFromUTF16: 0)
            tagIndexOffset = 0
            placeholdersSeen = 0
            preparedTags = [:]
            pendingFires = []
            rawResponse = ""
            coordinator.beginAnswer()
        case .logMessageStart(let id):
            print("🧠 New message \(id) after speech started; continuing")
        case .fail(let failure):
            print("⚠️ Claude stream failed: \(failure)")
            route(router.finish())
            enqueue(segmenter.finish())
            speakNow(failure.spokenMessage)
            finishStream(spawnedWorkers: false)
        }
    }

    /// The follow-up stream after workers: same answer, fresh router.
    /// The board takes the voice (BoardController): this answer stops speaking.
    func yieldVoiceToBoard() {
        guard coordinator.isSpeaking else { return }
        isYieldingToBoard = true
        coordinator.bargeIn(.voiceCommand)
        isYieldingToBoard = false
    }

    func beginFollowUpStream() {
        tagIndexOffset += router.tags.count
        placeholdersSeen = 0
        router = ResponseRouter(blockConsumers: Self.blockConsumers())
        segmenter = NarrationSegmenter(options: segmenterOptions)
        supervisor = CLIStreamSupervisor()
        isFirstStream = false
        rawResponse += "\n\n--- final answer after workers ---\n"
        resetWhiteboardStream(searchFromUTF16: rawResponse.utf16.count)
    }

    /// The stream ended; with a board still handing over steps, later.
    private func finishStream(spawnedWorkers: Bool) {
        hasStreamEnded = !spawnedWorkers
        if isBoardSpeechOpen {
            deferredStreamFinish = spawnedWorkers
        } else {
            coordinator.streamDidFinish(spawnedWorkers: spawnedWorkers)
        }
    }

    /// The board's narrator handed over its last step (BoardController).
    func boardSpeechDidEnd() {
        isBoardSpeechOpen = false
        if let deferredStreamFinish {
            self.deferredStreamFinish = nil
            coordinator.streamDidFinish(spawnedWorkers: deferredStreamFinish)
        }
    }

    // MARK: - Whiteboard

    private func resetWhiteboardStream(searchFromUTF16 searchStart: Int) {
        whiteboardStreamParser = nil
        whiteboardSearchStartUTF16 = searchStart
        whiteboardFedUTF16 = searchStart
        isWhiteboardStreamClosed = false
    }

    /// Feeds the <whiteboard> body to the parser as it streams (a possible
    /// half-arrived close tag is held back); opens the panel with "Drawing…".
    private func streamWhiteboardBody() {
        guard !isWhiteboardStreamClosed else { return }
        let openTag = "<whiteboard>", closeTag = "</whiteboard>"
        if whiteboardStreamParser == nil {
            let searchStart = String.Index(utf16Offset: min(whiteboardSearchStartUTF16, rawResponse.utf16.count), in: rawResponse)
            guard let openRange = rawResponse.range(of: openTag, options: .caseInsensitive, range: searchStart..<rawResponse.endIndex) else { return }
            whiteboardStreamParser = WBStreamParser()
            whiteboardFedUTF16 = openRange.upperBound.utf16Offset(in: rawResponse)
            turnRecord?.markTiming("boardOpen")
            companionManager.boardController.showDrawingPlaceholder(title: nil, session: self)
        }
        let fedIndex = String.Index(utf16Offset: whiteboardFedUTF16, in: rawResponse)
        var feedEnd: String.Index
        if let closeRange = rawResponse.range(of: closeTag, options: .caseInsensitive, range: fedIndex..<rawResponse.endIndex) {
            feedEnd = closeRange.lowerBound
            isWhiteboardStreamClosed = true
        } else {
            feedEnd = rawResponse.index(rawResponse.endIndex, offsetBy: -(closeTag.count - 1), limitedBy: fedIndex) ?? fedIndex
        }
        if feedEnd < fedIndex { feedEnd = fedIndex }
        whiteboardStreamParser?.feed(String(rawResponse[fedIndex..<feedEnd]))
        whiteboardFedUTF16 = feedEnd.utf16Offset(in: rawResponse)
        if let title = whiteboardStreamParser?.provisionalBoard.title, !title.isEmpty, !presentedBoard {
            companionManager.boardController.showDrawingPlaceholder(title: title, session: self)
        }
    }

    /// The block closed: parse (streamed, else the whole body), repair once
    /// if too broken, then narrate it.
    private func handleWhiteboardBlock(body: String) {
        // The words before the board are spoken first.
        enqueue(segmenter.finish())
        segmenter = NarrationSegmenter(options: segmenterOptions)
        isBoardSpeechOpen = true
        var outcome = whiteboardStreamParser?.finish()
        whiteboardStreamParser = nil
        isWhiteboardStreamClosed = true
        if outcome?.isUsable != true {
            let wholeBodyOutcome = WBStreamParser.parse(body)
            if wholeBodyOutcome.isUsable || outcome == nil { outcome = wholeBodyOutcome }
        }
        guard let outcome else {
            companionManager.boardController.abandonIncomingBoard(session: self)
            return boardSpeechDidEnd()
        }
        turnRecord?.boardStats = TurnRecord.BoardStatsEntry(elements: outcome.stats.elementCount, steps: outcome.stats.stepCount,
                                                            dropped: outcome.stats.droppedCount, usable: outcome.isUsable, repaired: false)
        if outcome.isUsable {
            presentBoard(outcome.board)
            return
        }
        print("🧑‍🏫 Board too broken (\(outcome.stats.droppedCount) dropped); one repair call")
        let brokenBoard = outcome.board
        Task { @MainActor [weak self] in
            guard let self else { return }
            let repaired = await WhiteboardRepairRunner.repair(brokenBoardText: body, model: self.companionManager.selectedModel)
            guard !self.isFinished else { return }
            if let repaired {
                self.turnRecord?.boardStats?.repaired = true
                self.turnRecord?.boardStats?.usable = true
                self.presentBoard(repaired.board)
            } else {
                // No board after all: the steps' words, spoken like any answer.
                self.companionManager.boardController.abandonIncomingBoard(session: self)
                for step in brokenBoard.steps where !step.say.isEmpty { self.enqueue(self.segmenter.feed(Self.spokenWords(of: step.say) + " ")) }
                self.enqueue(self.segmenter.finish())
                self.boardSpeechDidEnd()
            }
        }
    }

    private func presentBoard(_ board: WBBoard) {
        presentedBoard = true
        // Helper sections that were already back go straight into the board.
        var boardWithEarlySections = board
        for earlySection in earlyBoardSections {
            if let change = ProgressiveBoard.replacePlaceholder(ofSection: earlySection.sectionIdentifier, in: boardWithEarlySections, with: earlySection.board) {
                boardWithEarlySections = change.board
            }
        }
        earlyBoardSections = []
        nextSegmentID = companionManager.boardController.presentLive(board: boardWithEarlySections, session: self, coordinator: coordinator, turnRecord: turnRecord,
                                                                     firstSegmentID: nextSegmentID, segmenterOptions: segmenterOptions)
        for failedSection in failedBoardSections { companionManager.boardController.markWorkerSectionFailed(failedSection, session: self) }
        failedBoardSections = []
    }

    /// A step's `say` without its tags (spoken when the board couldn't be drawn).
    static func spokenWords(of say: String) -> String {
        var stepRouter = ResponseRouter()
        return (stepRouter.feed(say) + stepRouter.finish()).compactMap { output -> String? in
            if case .narration(let text) = output { return text.replacingOccurrences(of: String(ResponseRouter.placeholder), with: "") }
            return nil
        }.joined()
    }

    /// A tag inside a board step's `say` (BoardController registers it).
    func prepareBoardTag(_ tag: ParsedTag, index: Int) {
        prepare(tag, index: index)
    }

    /// Something to say that didn't come from Claude (errors, apologies).
    func speakNow(_ text: String) {
        let segment = CaptionParser.parse(text, id: nextSegmentID, firstTagIndex: 0)
        nextSegmentID += 1
        coordinator.enqueue(segment)
    }

    /// Blocks with a consumer this turn: <codetask> only while Code mode is
    /// on (otherwise the router says "I can't do that yet").
    /// Blocks with a consumer: boards always (P4), code tasks while Code mode is on (P5).
    /// P6.2: <type> always goes to the Type card. With v2.typeForMe.enabled
    /// off the card offers Copy only (harmless), and the prompt doesn't ask
    /// for <type> then anyway.
    static func blockConsumers() -> Set<String> {
        ClickySettings.isCodeEnabled ? ["whiteboard", "codetask", "type"] : ["whiteboard", "type"]
    }

    // MARK: - Routing

    private func route(_ outputs: [ResponseRouterOutput]) {
        for output in outputs {
            switch output {
            case .narration(let text):
                enqueue(segmenter.feed(text))
            case .tag(let index, let tag):
                let globalIndex = tagIndexOffset + index
                coordinator.registerTag(index: globalIndex, isPoint: tag.kind == .point)
                prepare(tag, index: globalIndex)
            case .worker(let title, let task):
                spawnWorker(CompanionWorkerRequest(workerTitle: title, workerTaskPrompt: task))
            case .block(let name, let body) where name == "codetask":
                if !companionManager.codeModeController.handleCodeTaskBlock(body, context: CodeTurnContext(transcript: transcript)) {
                    speakNow("I couldn't read that code task.")
                }
            case .block(let name, let body) where name == "whiteboard":
                handleWhiteboardBlock(body: body)
            case .block(let name, let body) where name == "type":
                companionManager.typeForMeController.present(blockBody: body)
            case .block(let name, _):
                print("🧱 Block <\(name)> has no consumer yet")
            case .unsupportedBlock(let name):
                print("🧱 Block <\(name)> isn't supported yet; said so")
            case .dropped(let reason, let raw):
                turnRecord?.grounding?.malformedTagCount += 1
                print("🏷️ Dropped tag (\(reason)): \(raw.prefix(80))")
            }
        }
    }

    private func enqueue(_ rawSegments: [String]) {
        let liveElementIDs = groundedTurn.registry.liveElementIDs
        for rawSegment in rawSegments {
            let placeholderCount = rawSegment.filter { $0 == ResponseRouter.placeholder }.count
            let firstTagIndex = tagIndexOffset + placeholdersSeen
            placeholdersSeen += placeholderCount
            badgeMentionCount += SpeechSafetyNet.countBadgeMentions(in: rawSegment, liveElementIDs: liveElementIDs)
            let cleaned = SpeechSafetyNet.clean(rawSegment, liveElementIDs: liveElementIDs)
            speechLeakCount += cleaned.leakCount
            let segment = CaptionParser.parse(cleaned.speechText + (rawSegment.last?.isWhitespace == true ? " " : ""), id: nextSegmentID, firstTagIndex: firstTagIndex)
            nextSegmentID += 1
            turnRecord?.markTiming("firstSegment")
            turnRecord?.segmentTexts.append(segment.speech)
            coordinator.enqueue(segment)
        }
        turnRecord?.grounding?.speechLeakCount = speechLeakCount
        turnRecord?.grounding?.badgeMentionsInNarration = badgeMentionCount
    }

    // MARK: - Tags

    /// Resolves a tag in parse order (OCR first if it needs text), then
    /// fires it if its words were already spoken.
    private func prepare(_ tag: ParsedTag, index: Int) {
        let previousPreparation = preparationChain
        preparationChain = Task { @MainActor [weak self] in
            await previousPreparation?.value
            guard let self else { return }
            let prepared = await self.resolve(tag)
            self.preparedTags[index] = prepared
            if case .mark = prepared { self.companionManager.markController.noteMarkPrepared() }
            if case .mark(let mark) = prepared, mark.source != .accessibility, let recheckName = mark.recheckName, !recheckName.isEmpty,
               let display = ScreenTopology.current().first(where: { $0.boundsCG.contains(mark.rectCG.center) }) {
                let targetRect = mark.rectCG
                Task { @MainActor [weak self] in
                    let outcome = await MarkRecheck.run(name: recheckName, target: targetRect, display: display)
                    self?.recheckFinished(outcome, tagIndex: index)
                }
            }
            if self.pendingFires.remove(index) != nil { self.fireNow(index) }
        }
    }

    private func resolve(_ tag: ParsedTag) async -> PreparedTag {
        if tag.kind == .clear { return .clear }
        // A snapshot needs no grounding: it's taken from the screen when it fires.
        if tag.kind == .snap, let snapshotRequest = tag.snapshot { return .snapshot(snapshotRequest) }
        if presentedBoard, let boardElementIdentifier = companionManager.boardController.boardElementIdentifier(for: tag) {
            return .boardPoint(boardElementIdentifier)
        }
        if case .text = tag.target {
            var workingTurn = groundedTurn
            await workingTurn.ensureOCRLines()
            groundedTurn = workingTurn
        }
        turnRecord?.grounding?.ocrLineCount = groundedTurn.registry.allOCRLines.count
        publishTextObstacles()
        let framesByScreenNumber = groundedTurn.framesByScreenNumber
        let ax = companionManager.groundingCoordinator.ax
        var maybeResolvedTarget = TargetResolver(registry: groundedTurn.registry, framesByScreenNumber: framesByScreenNumber,
                                                 cursorCG: groundedTurn.cursorCG, windowStack: groundedTurn.windowStack,
                                                 lookup: AXGroundingLiveLookup(ax: ax)).resolve(tag)
        if maybeResolvedTarget == nil, case .text = tag.target, !groundedTurn.hasRetriedOCR {
            var workingTurn = groundedTurn
            await workingTurn.retryOCRWithShiftedBands()
            groundedTurn = workingTurn
            publishTextObstacles()
            maybeResolvedTarget = TargetResolver(registry: groundedTurn.registry, framesByScreenNumber: framesByScreenNumber,
                                                 cursorCG: groundedTurn.cursorCG, windowStack: groundedTurn.windowStack,
                                                 lookup: AXGroundingLiveLookup(ax: ax)).resolve(tag)
        }
        guard var resolvedTarget = maybeResolvedTarget else { return .unusable }
        HitTestVerifier.verify(&resolvedTarget, ax: ax, ownProcessIdentifier: getpid(), windowStack: groundedTurn.windowStack)

        let screenNumber = framesByScreenNumber.first { $0.value.display.displayID == resolvedTarget.displayID }?.key ?? tag.effectiveScreenNumber
        let modelPixel = framesByScreenNumber[screenNumber]?.modelPx(fromCG: resolvedTarget.pointCG)
        let tagIndexInRecord = turnRecord?.recordResolvedTag(raw: tag.raw, kind: tag.kind == .point ? "point" : "mark",
                                                            screenNumber: screenNumber, modelPixel: modelPixel, target: resolvedTarget)
        // Never point through another app's window.
        if resolvedTarget.verified == false && resolvedTarget.occludedByPID != nil { return .unusable }

        if tag.kind == .point {
            guard let pointFrame = framesByScreenNumber.values.first(where: { $0.display.displayID == resolvedTarget.displayID }) else { return .unusable }
            return .point(resolvedTarget, pointFrame)
        }
        let source = LiveScreenMark.source(for: resolvedTarget)
        let context = MarkTracker.trackingContext(for: source == .accessibility ? resolvedTarget.axNode : nil, rectCG: resolvedTarget.frameCG, ax: ax)
        var recheckName: String?
        if case .text(let query, _, _) = tag.target { recheckName = query } else { recheckName = resolvedTarget.label }
        return .mark(LiveScreenMark(
            style: LiveScreenMark.style(for: tag.style),
            rectCG: resolvedTarget.frameCG,
            displayText: tag.displayText,
            source: source,
            ax: source == .accessibility ? resolvedTarget.axNode : nil,
            confidence: resolvedTarget.confidence,
            isTentative: resolvedTarget.confidence < LiveScreenMark.tentativeConfidence || resolvedTarget.occludedByPID != nil,
            createdAt: Date(),
            windowID: context.windowID,
            windowFrameCG: context.windowFrame,
            clipAX: context.clip,
            labelAX: context.label,
            originalLabel: context.originalLabel,
            recheckName: recheckName,
            order: preparedTags.count,
            tagIndex: tagIndexInRecord,
            targetRole: MarkTextObstacles.targetRole(for: resolvedTarget.elementID.flatMap { groundedTurn.registry[$0] },
                                                     isTextMatch: resolvedTarget.method == .textExact || resolvedTarget.method == .textFuzzy)
        ))
    }

    /// The registry's text bounds (AX text-ish elements and OCR lines) for
    /// this answer: marks underline dense rows and keep labels off them, and
    /// the caption bubble skips slots that cover them. Re-sent when OCR
    /// lines arrive; only sent when they changed.
    private func publishTextObstacles() {
        let registry = groundedTurn.registry
        let textBounds = MarkTextObstacles.collect(elements: registry.orderedIDs.compactMap { registry[$0] }, ocrLines: registry.allOCRLines)
        if companionManager.screenTextObstaclesCG != textBounds { companionManager.screenTextObstaclesCG = textBounds }
    }

    private func recheckFinished(_ outcome: MarkRecheck.Outcome, tagIndex: Int) {
        if let markID = shownMarkIDsByTag[tagIndex] {
            companionManager.markController.applyLateRecheck(outcome, markID: markID, turnRecord: turnRecord)
            // A drawn mark that just failed its re-check gets the zoom check too.
            if let mark = companionManager.markController.marks.first(where: { $0.id == markID }) { startZoomCheckIfNeeded(mark) }
        } else {
            recheckOutcomes[tagIndex] = outcome
        }
    }

    // MARK: - Zoom check (P6.1)

    /// A tentative mark, once drawn, gets one Haiku look at a zoomed crop
    /// (v2.grounding.verifyWithHaiku). Needs a name to ask about.
    private func startZoomCheckIfNeeded(_ mark: LiveScreenMark) {
        let zoomChecker = companionManager.zoomChecker
        guard zoomChecker.isEnabled, mark.isTentative, !zoomCheckedMarkIDs.contains(mark.id),
              let name = mark.recheckName ?? mark.displayText, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        zoomCheckedMarkIDs.insert(mark.id)
        let markID = mark.id
        let tagIndex = mark.tagIndex
        let questionNumber = zoomChecker.questionNumber
        let startDate = Date()
        let registry = groundedTurn.registry
        Task { @MainActor [weak self] in
            let outcome = await zoomChecker.check(name: name, currentRectCG: mark.rectCG, registry: registry) { [weak self] in
                // Keep a Haiku process waiting while this answer can still draw marks.
                guard let self else { return false }
                return !self.isFinished && !self.companionManager.markController.marks.isEmpty
            }
            self?.applyZoomCheck(outcome, markID: markID, tagIndex: tagIndex, name: name, questionNumber: questionNumber, startDate: startDate)
        }
    }

    private func applyZoomCheck(_ outcome: HaikuZoomChecker.Outcome, markID: UUID, tagIndex: Int?, name: String, questionNumber: Int, startDate: Date) {
        let markController = companionManager.markController
        var action = outcome.decision.action
        if case .ignore = outcome.decision {
            // Nothing to change.
        } else if !ZoomCheck.shouldApply(startedForQuestion: questionNumber, currentQuestion: companionManager.zoomChecker.questionNumber,
                                         isMarkStillLive: markController.isLive(markID)) {
            action = .skippedMovedOn
        } else {
            switch outcome.decision {
            case .confirm:
                markController.updateMark(markID, retracks: false) { mark in
                    mark.isTentative = false
                    mark.confidence = max(mark.confidence, ZoomCheck.checkedConfidence)
                }
            case .moveToElement(let candidate):
                let element = groundedTurn.registry[candidate.elementID]
                let ax = companionManager.groundingCoordinator.ax
                let refreshedFrame = element.flatMap { AXGroundingLiveLookup(ax: ax).refreshedFrame(of: $0) } ?? candidate.frameCG
                moveMark(markID, to: refreshedFrame, axNode: element?.axNode)
            case .moveToPoint(let pointCG):
                guard let frame = outcome.frame else { break }
                let ax = companionManager.groundingCoordinator.ax
                let snappedTarget = TargetResolver(registry: groundedTurn.registry, framesByScreenNumber: groundedTurn.framesByScreenNumber,
                                                   cursorCG: groundedTurn.cursorCG, windowStack: groundedTurn.windowStack,
                                                   lookup: AXGroundingLiveLookup(ax: ax)).snapPoint(pointCG, name: name, frame: frame)
                moveMark(markID, to: snappedTarget.frameCG, axNode: snappedTarget.method == .snapped ? snappedTarget.axNode : nil)
            case .ignore:
                break
            }
        }

        let milliseconds = (Date().timeIntervalSince(startDate) * 1000).rounded()
        guard let turnRecord, let tagIndex else { return }
        turnRecord.recordZoomCheck(tagIndex: tagIndex, entry: TurnRecord.ZoomCheckEntry(
            reply: outcome.replyText.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) },
            action: action.rawValue,
            ms: milliseconds
        ))
        // A check that finished after turn.json was written: write it again.
        if turnRecord.timings["end"] != nil { TurnLogger.finishTurn(turnRecord) }
    }

    /// Moves a mark onto the element / point the zoom check found; it's solid now.
    private func moveMark(_ markID: UUID, to rectCG: CGRect, axNode: AXNodeReference?) {
        let ax = companionManager.groundingCoordinator.ax
        let context = MarkTracker.trackingContext(for: axNode, rectCG: rectCG, ax: ax)
        companionManager.markController.updateMark(markID, retracks: true) { mark in
            mark.rectCG = rectCG
            mark.ax = axNode
            mark.source = axNode != nil ? .accessibility : .snapped
            mark.windowID = context.windowID
            mark.windowFrameCG = context.windowFrame
            mark.clipAX = context.clip
            mark.labelAX = context.label
            mark.originalLabel = context.originalLabel
            mark.isTentative = false
            mark.confidence = ZoomCheck.checkedConfidence
        }
    }

    // MARK: - SpeechCoordinatorHost

    func fireTag(index: Int) {
        guard !droppedTags.contains(index) else { return }
        guard preparedTags[index] != nil else {
            // Spoken before it finished resolving: fire as soon as it does.
            pendingFires.insert(index)
            return
        }
        fireNow(index)
    }

    private func fireNow(_ index: Int) {
        turnRecord?.firedTagIndexes.append(index)
        switch preparedTags[index] {
        case .mark(var mark)?:
            if let outcome = recheckOutcomes.removeValue(forKey: index) {
                MarkController.apply(outcome, to: &mark)
                companionManager.markController.recordRecheck(outcome, mark: mark, turnRecord: turnRecord)
            }
            shownMarkIDsByTag[index] = mark.id
            companionManager.markController.add(mark)
            startZoomCheckIfNeeded(mark)
        case .point(let target, let frame)?:
            companionManager.flyCompanion(to: target, frame: frame)
        case .boardPoint(let elementIdentifier)?:
            companionManager.boardController.point(atElement: elementIdentifier)
        case .clear?:
            companionManager.markController.clear()
        case .snapshot(let snapshotRequest)?:
            fireSnapshot(snapshotRequest)
        case .unusable?, nil:
            break
        }
        // A board step pointing at the real screen: the board steps aside.
        if index >= BoardNarrationScript.firstBoardTagIndex, let prepared = preparedTags[index] {
            switch prepared {
            case .mark, .point: companionManager.boardController.realScreenTagFired()
            default: break
            }
        }
    }

    /// Takes the [SNAP:…] shot now (the marks on screen are the ones up at this moment),
    /// then says where it went. Runs in its own task: the capture can take a moment and
    /// the speech queue must not wait on it.
    private func fireSnapshot(_ snapshotRequest: SnapshotRequest) {
        let markRectsCG = companionManager.markController.marks.map(\.rectCG)
        let turnRecordForSnapshot = turnRecord
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshotResult = try await SnapshotCapture.capture(request: snapshotRequest, markRectsCG: markRectsCG)
                turnRecordForSnapshot?.recordSnapshot(snapshotResult)
                // A shot that finished after turn.json was written: write it again.
                if let turnRecordForSnapshot, turnRecordForSnapshot.timings["end"] != nil { TurnLogger.finishTurn(turnRecordForSnapshot) }
                let savedLine = "saved to Clicky Screenshots on your Desktop"
                if self.isFinished {
                    self.companionManager.speakCodeModeLine(savedLine)
                } else {
                    self.speakNow(savedLine)
                }
            } catch {
                print("📸 SnapshotCapture failed: \(error.localizedDescription)")
                if self.isFinished {
                    self.companionManager.speakCodeModeLine("I couldn't take that screenshot.")
                } else {
                    self.speakNow("I couldn't take that screenshot.")
                }
            }
        }
    }

    func dropUnfiredTags(_ tagIndexes: [Int]) {
        droppedTags.formUnion(tagIndexes)
        pendingFires.subtract(tagIndexes)
    }

    func cancelClaudeAndWorkers() {
        for workerTask in workerTasks { workerTask.cancel() }
        // Handing the voice to the board after Claude finished isn't a cancel.
        if isYieldingToBoard && hasStreamEnded { return }
        companionManager.cancelResponseRequest()
    }

    func captionDidChange(_ caption: CaptionState) {
        companionManager.showCaption(caption)
        if caption.current != nil { turnRecord?.markTiming("firstAudio") }
        // The bubble keeps clear of this segment's targets that haven't fired yet.
        let firedTags = Set(coordinator.firedTagIndexes)
        companionManager.upcomingTargetRectsCG = (caption.current?.anchors ?? []).compactMap { anchor -> CGRect? in
            guard !firedTags.contains(anchor.tagIndex) else { return nil }
            switch preparedTags[anchor.tagIndex] {
            case .mark(let mark)?: return MarkLayout.padded(mark.rectCG)
            case .point(let target, _)?: return target.frameCG
            default: return nil
            }
        }
    }

    func answerDidFinish(historyText: String, wasInterrupted: Bool) {
        guard !isFinished else { return }
        isFinished = true
        captionTickTimer?.invalidate()
        captionTickTimer = nil
        // Section helpers still drawing can't make it into this board any more.
        for workerIndex in boardSectionByWorkerIndex.keys where workerTasks.indices.contains(workerIndex) { workerTasks[workerIndex].cancel() }
        companionManager.upcomingTargetRectsCG = []
        self.wasInterrupted = wasInterrupted
        companionManager.speechOutputClient.recordFinished(coordinator)
        var history = wasInterrupted ? historyText : HistoryTagRewriter.wordsForHistory(Self.removingWhiteboardBlocks(rawResponse))
        if presentedBoard, let boardHistory = companionManager.boardController.historyEntry(spokenHistory: history, session: self) {
            history = boardHistory
        }
        companionManager.boardController.liveSessionDidFinish(self, wasInterrupted: wasInterrupted)
        companionManager.boardController.closeShellIfNoBoard(session: self)
        companionManager.recordAnswer(transcript: transcript, history: history, spokenText: coordinator.spokenText, wasInterrupted: wasInterrupted)
        // Report the end only once every tag has been resolved (and logged).
        let pendingPreparation = preparationChain
        Task { @MainActor [weak self] in
            await pendingPreparation?.value
            guard let self else { return }
            self.hasSettled = true
            self.finishContinuation?.resume()
            self.finishContinuation = nil
        }
    }

    private var hasSettled = false

    /// The answer's words without its <whiteboard> blocks (the history keeps a BOARD STATE instead).
    static func removingWhiteboardBlocks(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?is)<whiteboard>.*?(</whiteboard>|$)"#, with: " ", options: .regularExpression)
    }

    // MARK: - Board segments (SpeechCoordinatorHost)

    func segmentDidStart(_ segment: CaptionSegment) {
        if segment.boardStep != nil { companionManager.boardController.liveSegmentStarted(segment, session: self) }
    }

    func segmentDidProgress(_ segment: CaptionSegment, spokenCharacters: Int) {
        if segment.boardStep != nil { companionManager.boardController.liveSegmentProgressed(segment, spokenCharacters: spokenCharacters, session: self) }
    }

    func segmentDidEnd(_ segment: CaptionSegment) {
        if segment.boardStep != nil { companionManager.boardController.liveSegmentEnded(segment, session: self) }
    }

    func speakApology(_ text: String) {
        speakNow(text)
    }

    func log(_ event: String) {
        print("🗣️ \(event)")
    }

    // MARK: - Workers

    private func spawnWorker(_ request: CompanionWorkerRequest) {
        workerRequests.append(request)
        // "s2 The handshake": a helper that draws board section s2 (P6.7).
        let boardSection = ProgressiveBoard.workerSection(fromWorkerTitle: request.workerTitle)
        if isWhiteboardTurn { companionManager.boardController.showShell(workerTitle: boardSection?.title ?? request.workerTitle, session: self) }
        let screenBlocks = groundedTurn.contentBlocks
        let systemPromptFileName = boardSection.map { "worker-board-\($0.sectionIdentifier)-prompt.md" } ?? "worker-prompt.md"
        let systemPrompt = boardSection.map {
            WhiteboardPromptSection.workerSectionSystemPrompt(sectionIdentifier: $0.sectionIdentifier, sectionTitle: $0.title)
        } ?? CompanionManager.companionWorkerSystemPrompt
        let workerTask = companionManager.companionWorkerRunner.spawnWorker(request) { workerRequest in
            let workerTurn = try await CompanionWorkerRunner.makeWorkerClaudeCodeBridge().runTurn(
                systemPromptFileName: systemPromptFileName,
                systemPrompt: systemPrompt,
                contentBlocks: [.text(workerRequest.workerTaskPrompt)] + screenBlocks
            )
            return workerTurn.text
        }
        if let boardSection {
            boardSectionByWorkerIndex[workerTasks.count] = boardSection
            Task { @MainActor [weak self] in
                let result = await workerTask.value
                self?.boardSectionWorkerFinished(result, sectionIdentifier: boardSection.sectionIdentifier, title: boardSection.title)
            }
        }
        workerTasks.append(workerTask)
    }

    /// Section helpers feed the board directly, unless this answer drew no board.
    private var drawsBoardFromHelpers: Bool {
        WBBlockExtractor.containsWhiteboardBlock(rawResponse)
    }

    /// Indexes of the helpers whose results go to a follow-up stream.
    private var followUpWorkerIndexes: [Int] {
        workerTasks.indices.filter { boardSectionByWorkerIndex[$0] == nil || !drawsBoardFromHelpers }
    }

    var hasFollowUpWorkers: Bool { !followUpWorkerIndexes.isEmpty }

    func followUpWorkerResults() async -> [CompanionWorkerResult] {
        var results: [CompanionWorkerResult] = []
        for workerIndex in followUpWorkerIndexes { results.append(await workerTasks[workerIndex].value) }
        return results
    }

    /// A section helper is back: its lines (filtered to its section) go into
    /// the board, or wait for it; a failure lets the narrator drop the section.
    private func boardSectionWorkerFinished(_ result: CompanionWorkerResult, sectionIdentifier: String, title: String) {
        guard !isFinished, drawsBoardFromHelpers || !hasStreamEnded else { return }
        let outcome = result.didWorkerSucceed
            ? WBWorkerSectionFilter.filter(workerText: result.workerResultText, sectionIdentifier: sectionIdentifier, sectionTitle: title)
            : nil
        if let outcome, !outcome.rejectedReasons.isEmpty {
            print("🧑‍🏫 Helper \(sectionIdentifier): \(outcome.rejectedReasons.count) line(s) rejected: \(outcome.rejectedReasons.prefix(6).joined(separator: "; "))")
        }
        guard let outcome, outcome.isUsable else {
            print("🧑‍🏫 Helper \(sectionIdentifier) drew nothing usable; its section will be dropped")
            if presentedBoard {
                companionManager.boardController.markWorkerSectionFailed(sectionIdentifier, session: self)
            } else {
                failedBoardSections.append(sectionIdentifier)
            }
            return
        }
        print("🧑‍🏫 Helper \(sectionIdentifier) drew \(outcome.board.elements.count) elements, \(outcome.board.steps.count) steps")
        if presentedBoard {
            companionManager.boardController.mergeWorkerSection(sectionIdentifier, workerBoard: outcome.board, session: self)
        } else {
            earlyBoardSections.append((sectionIdentifier, outcome.board))
        }
    }
}

/// Stands in for the session during init (never called).
@MainActor
private final class PlaceholderHost: SpeechCoordinatorHost {
    static let shared = PlaceholderHost()
    func cancelClaudeAndWorkers() {}
    func fireTag(index: Int) {}
    func dropUnfiredTags(_ tagIndexes: [Int]) {}
    func captionDidChange(_ caption: CaptionState) {}
    func answerDidFinish(historyText: String, wasInterrupted: Bool) {}
    func speakApology(_ text: String) {}
    func log(_ event: String) {}
}
