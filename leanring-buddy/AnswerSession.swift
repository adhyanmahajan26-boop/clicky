//
//  AnswerSession.swift
//  leanring-buddy
//
//  One spoken answer, from Claude's first streamed word to the end of the
//  voice. Text deltas go through the ResponseRouter (tags out, workers and
//  blocks aside) and the NarrationSegmenter; each segment is parsed for the
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
    private var nextSegmentID = 1
    private(set) var rawResponse = ""
    private(set) var speechLeakCount = 0
    private(set) var badgeMentionCount = 0
    private var isFirstStream = true

    private enum PreparedTag {
        case mark(LiveScreenMark)
        case point(ResolvedTarget, CaptureFrame)
        case clear
        case unusable
    }

    private var preparedTags: [Int: PreparedTag] = [:]
    private var recheckOutcomes: [Int: MarkRecheck.Outcome] = [:]
    private var shownMarkIDsByTag: [Int: UUID] = [:]
    private var pendingFires: Set<Int> = []
    private var droppedTags: Set<Int> = []
    private var preparationChain: Task<Void, Never>?

    private(set) var workerRequests: [CompanionWorkerRequest] = []
    private var workerTasks: [Task<CompanionWorkerResult, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var isFinished = false
    private(set) var wasInterrupted = false

    init(transcript: String, groundedTurn: GroundedTurn, turnRecord: TurnRecord?, companionManager: CompanionManager, speaksResponse: Bool) {
        self.transcript = transcript
        self.groundedTurn = groundedTurn
        self.turnRecord = turnRecord
        self.companionManager = companionManager
        self.router = ResponseRouter(blockConsumers: [])
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
            route(router.feed(text))
        case .finish:
            route(router.finish())
            enqueue(segmenter.finish())
            let spawnedWorkers = isFirstStream && !workerTasks.isEmpty
            coordinator.streamDidFinish(spawnedWorkers: spawnedWorkers)
        case .reset:
            // A new message before anything was spoken: start the answer over.
            turnRecord?.rawResponse += "\n--- message restarted ---\n"
            router = ResponseRouter(blockConsumers: [])
            segmenter = NarrationSegmenter(options: segmenterOptions)
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
            coordinator.streamDidFinish(spawnedWorkers: false)
        }
    }

    /// The follow-up stream after workers: same answer, fresh router.
    func beginFollowUpStream() {
        tagIndexOffset += router.tags.count
        placeholdersSeen = 0
        router = ResponseRouter(blockConsumers: [])
        segmenter = NarrationSegmenter(options: segmenterOptions)
        supervisor = CLIStreamSupervisor()
        isFirstStream = false
        rawResponse += "\n\n--- final answer after workers ---\n"
    }

    /// Something to say that didn't come from Claude (errors, apologies).
    func speakNow(_ text: String) {
        let segment = CaptionParser.parse(text, id: nextSegmentID, firstTagIndex: 0)
        nextSegmentID += 1
        coordinator.enqueue(segment)
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
        } else {
            recheckOutcomes[tagIndex] = outcome
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
        case .point(let target, let frame)?:
            companionManager.flyCompanion(to: target, frame: frame)
        case .clear?:
            companionManager.markController.clear()
        case .unusable?, nil:
            break
        }
    }

    func dropUnfiredTags(_ tagIndexes: [Int]) {
        droppedTags.formUnion(tagIndexes)
        pendingFires.subtract(tagIndexes)
    }

    func cancelClaudeAndWorkers() {
        for workerTask in workerTasks { workerTask.cancel() }
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
        companionManager.upcomingTargetRectsCG = []
        self.wasInterrupted = wasInterrupted
        companionManager.speechOutputClient.recordFinished(coordinator)
        let history = wasInterrupted ? historyText : HistoryTagRewriter.wordsForHistory(rawResponse)
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

    func speakApology(_ text: String) {
        speakNow(text)
    }

    func log(_ event: String) {
        print("🗣️ \(event)")
    }

    // MARK: - Workers

    private func spawnWorker(_ request: CompanionWorkerRequest) {
        workerRequests.append(request)
        let screenBlocks = groundedTurn.contentBlocks
        let workerTask = companionManager.companionWorkerRunner.spawnWorker(request) { workerRequest in
            let workerTurn = try await CompanionWorkerRunner.makeWorkerClaudeCodeBridge().runTurn(
                systemPromptFileName: "worker-prompt.md",
                systemPrompt: CompanionManager.companionWorkerSystemPrompt,
                contentBlocks: [.text(workerRequest.workerTaskPrompt)] + screenBlocks
            )
            return workerTurn.text
        }
        workerTasks.append(workerTask)
    }

    var hasWorkers: Bool { !workerTasks.isEmpty }

    func workerResults() async -> [CompanionWorkerResult] {
        var results: [CompanionWorkerResult] = []
        for workerTask in workerTasks { results.append(await workerTask.value) }
        return results
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
