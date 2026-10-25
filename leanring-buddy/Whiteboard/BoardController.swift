//
//  BoardController.swift
//  leanring-buddy
//
//  Runs the whiteboard: opens the panel, lays the board out
//  (WhiteboardScene), and narrates it with ClickyCore's BoardNarrator so
//  visuals never lead the voice. The answer's own SpeechCoordinator speaks
//  the steps the first time (captions, EchoGuard and barge-in work as for
//  any answer); next / back / replay speak through a coordinator of the
//  board's own. Also: board POINTs (element rect → camera → panel →
//  screen → CG via ScreenTopology, then the companion flies there), the
//  board dims to 25 % and lets clicks through while a step points at the
//  real screen, keys, export (PNG at 2× + .clickyboard JSONL), the
//  workers' shell, the history's BOARD STATE and turn.json timing.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

@MainActor
final class BoardController: NSObject, ObservableObject, SpeechCoordinatorHost, NSWindowDelegate {
    @Published private(set) var scene: WhiteboardScene?
    @Published private(set) var renderState: WhiteboardRenderState?
    @Published private(set) var theme = WhiteboardTheme(settingValue: ClickySettings.whiteboardTheme)
    @Published private(set) var shellWorkerTitles: [String] = []
    @Published private(set) var placeholderText = "Drawing the board…"

    static let realScreenDimmedAlpha: CGFloat = 0.25
    static let zoomStep: CGFloat = 1.2

    private unowned let companionManager: CompanionManager
    private var panel: WhiteboardPanel?
    private(set) var narrator: BoardNarrator?
    private(set) var board: WBBoard?
    /// The answer that drew the board (its coordinator speaks the first narration).
    private weak var liveSession: AnswerSession?
    private weak var speakingCoordinator: SpeechCoordinator?
    private var ownCoordinator: SpeechCoordinator?
    private weak var shellSession: AnswerSession?
    /// The answer whose history gets the BOARD STATE.
    private weak var presentingSession: AnswerSession?
    private var turnRecord: TurnRecord?
    private var loggedNarrationEntryCount = 0
    private var cameraOverride: WBCameraTransform?
    private var dimmedStepIndex: Int?
    private var holdTimer: Timer?
    private var localKeyMonitor: Any?
    private var resizeWorkItem: DispatchWorkItem?
    private var segmenterOptions = NarrationSegmenter.Options()

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        // Esc closes the board first (P2 precedence: key panels consume it).
        companionManager.escapeKeyConsumers.append { [weak self] in
            guard let self, self.isOpen else { return false }
            self.close()
            return true
        }
    }

    var isOpen: Bool { panel?.isVisible == true }
    var hasBoard: Bool { board != nil }

    private var clockNow: TimeInterval { Date().timeIntervalSinceReferenceDate }

    // MARK: - Opening

    /// "Drawing the board…" while the block streams in (title once known).
    func showDrawingPlaceholder(title: String?, session: AnswerSession) {
        if let title, !title.isEmpty { placeholderText = "Drawing “\(title)”…" } else { placeholderText = "Drawing the board…" }
        clearOlderBoard(for: session)
        openPanel()
    }

    /// Helpers are researching a board: one frame per worker.
    func showShell(workerTitle: String, session: AnswerSession) {
        clearOlderBoard(for: session)
        shellSession = session
        shellWorkerTitles.append(workerTitle)
        openPanel()
    }

    /// A new board is on its way: an older one leaves the panel (it stays
    /// in `board` for "go deeper" until the new one replaces it).
    private func clearOlderBoard(for session: AnswerSession) {
        guard presentingSession !== session, scene != nil else { return }
        stopOwnSpeech()
        narrator?.stop()
        setDimmed(false)
        scene = nil
        renderState = nil
    }

    /// The incoming board couldn't be drawn: the placeholder goes away.
    func abandonIncomingBoard(session: AnswerSession) {
        guard presentingSession !== session else { return }
        shellWorkerTitles = []
        shellSession = nil
        if scene == nil { close() }
    }

    /// The answer ended without a board: the shell goes away.
    func closeShellIfNoBoard(session: AnswerSession) {
        guard shellSession === session else { return }
        shellSession = nil
        if liveSession !== session && !shellWorkerTitles.isEmpty {
            shellWorkerTitles = []
            if scene == nil { close() }
        }
    }

    /// The answer's board: lay it out, open the panel and narrate it with the
    /// answer's coordinator. Returns the next free segment id.
    @discardableResult
    func presentLive(board newBoard: WBBoard, session: AnswerSession, coordinator: SpeechCoordinator, turnRecord newTurnRecord: TurnRecord?,
                     firstSegmentID: Int, segmenterOptions newSegmenterOptions: NarrationSegmenter.Options) -> Int {
        stopOwnSpeech()
        let orderedBoard = WBLayoutAdapter.agendaFirstRecapLast(newBoard)
        board = orderedBoard
        segmenterOptions = newSegmenterOptions
        let scripts = BoardNarrationScript.make(board: orderedBoard, firstSegmentID: firstSegmentID, segmenterOptions: newSegmenterOptions)
        narrator = BoardNarrator(board: orderedBoard, scripts: scripts)
        liveSession = session
        presentingSession = session
        speakingCoordinator = coordinator
        ownCoordinator = nil
        turnRecord = newTurnRecord
        loggedNarrationEntryCount = 0
        cameraOverride = nil
        shellWorkerTitles = []
        shellSession = nil
        turnRecord?.boardTitle = orderedBoard.title
        openPanel()
        rebuildScene()
        let nextSegmentID = (scripts.last?.segments.last?.id ?? (firstSegmentID - 1)) + 1
        apply(narrator?.start(at: clockNow) ?? [])
        if scripts.isEmpty {
            // A board without steps is shown whole.
            narrator?.revealEverything()
            publishState()
        }
        return nextSegmentID
    }

    /// A board shown without the answer pipeline speaking it (tests, a
    /// failed narration): everything at once.
    func presentStatic(board newBoard: WBBoard) {
        stopOwnSpeech()
        let orderedBoard = WBLayoutAdapter.agendaFirstRecapLast(newBoard)
        board = orderedBoard
        narrator = BoardNarrator(board: orderedBoard, scripts: BoardNarrationScript.make(board: orderedBoard, segmenterOptions: segmenterOptions))
        narrator?.revealEverything()
        liveSession = nil
        openPanel()
        rebuildScene()
        publishState()
    }

    private func openPanel() {
        let panelFrame = WhiteboardPanel.frame(fullScreen: ClickySettings.isWhiteboardFullScreen)
        if panel == nil {
            let newPanel = WhiteboardPanel(contentRect: panelFrame)
            newPanel.delegate = self
            newPanel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
            let hostingView = NSHostingView(rootView: WhiteboardPanelRootView(boardController: self))
            // The panel's frame decides the size (the board is laid out for it), not the content.
            hostingView.sizingOptions = []
            newPanel.contentView = hostingView
            panel = newPanel
        }
        guard let panel, !panel.isVisible else { return }
        theme = WhiteboardTheme(settingValue: ClickySettings.whiteboardTheme)
        panel.setFrame(panelFrame, display: true)
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        companionManager.setWhiteboardPanelOpen(true)
        installKeyMonitor()
        startHoldTimer()
    }

    func close() {
        stopOwnSpeech()
        liveSession?.yieldVoiceToBoard()
        narrator?.stop()
        setDimmed(false)
        panel?.orderOut(nil)
        holdTimer?.invalidate()
        holdTimer = nil
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        localKeyMonitor = nil
        shellWorkerTitles = []
        companionManager.setWhiteboardPanelOpen(false)
        publishState()
    }

    // MARK: - Scene

    private var viewportSize: CGSize {
        let panelSize = panel?.contentView?.bounds.size ?? WhiteboardPanel.frame(fullScreen: ClickySettings.isWhiteboardFullScreen).size
        return WhiteboardScene.viewportSize(forPanelSize: panelSize)
    }

    private func rebuildScene() {
        guard let board else {
            scene = nil
            return
        }
        scene = WhiteboardScene(board: board, viewportSize: viewportSize)
        publishState()
    }

    func windowDidResize(_ notification: Notification) {
        resizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuildScene() }
        }
        resizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private var currentCamera: WBCameraTransform? {
        guard let scene else { return nil }
        return cameraOverride ?? scene.cameraTransform(forStep: narrator?.currentStepIndex)
    }

    private func publishState() {
        guard scene != nil, let narrator, let camera = currentCamera else {
            renderState = nil
            return
        }
        let stepLabel = narrator.stepCount == 0 ? "" : "\((narrator.currentStepIndex ?? -1) + 1) / \(narrator.stepCount)"
        renderState = WhiteboardRenderState(revealTimes: narrator.revealTimes, highlightedIdentifiers: narrator.highlightedIdentifiers,
                                            camera: camera, subtitle: narrator.currentSubtitle, stepLabel: stepLabel,
                                            isPaused: narrator.isPaused || (speakingCoordinator?.isPaused ?? false))
        logNarration()
    }

    // MARK: - Narration actions

    private func apply(_ actions: [BoardNarrationAction]) {
        for action in actions {
            switch action {
            case .stopSpeech:
                beginOwnSpeechRun()
            case .speak(let stepIndex):
                enqueueStep(stepIndex)
            case .endOfSpeech:
                if let ownCoordinator, speakingCoordinator === ownCoordinator {
                    ownCoordinator.streamDidFinish(spawnedWorkers: false)
                } else {
                    liveSession?.boardSpeechDidEnd()
                }
            case .revealStep:
                cameraOverride = nil
            case .point(let elementIdentifier):
                point(atElement: elementIdentifier)
            case .stepEnded(let stepIndex):
                if dimmedStepIndex == stepIndex { setDimmed(false) }
            case .finished:
                setDimmed(false)
                // Anything no step showed appears at the end of the narration.
                if narrator?.mode == .continuous, let narrator, narrator.revealTimes.count < narrator.board.elements.count {
                    self.narrator?.revealEverything()
                }
            }
        }
        publishState()
    }

    private func enqueueStep(_ stepIndex: Int) {
        guard let scripts = narrator?.scripts, scripts.indices.contains(stepIndex), let coordinator = speakingCoordinator else { return }
        let script = scripts[stepIndex]
        for scriptTag in script.tags {
            coordinator.registerTag(index: scriptTag.index, isPoint: scriptTag.tag.kind == .point)
            if speakingCoordinator !== ownCoordinator { liveSession?.prepareBoardTag(scriptTag.tag, index: scriptTag.index) }
        }
        for segment in script.segments {
            if speakingCoordinator !== ownCoordinator { turnRecord?.segmentTexts.append(segment.speech) }
            coordinator.enqueue(segment)
        }
    }

    /// next / back / replay speak with the board's own coordinator (whatever
    /// was speaking the board stops first).
    private func beginOwnSpeechRun() {
        let previousSession = liveSession
        liveSession = nil
        previousSession?.yieldVoiceToBoard()
        if let ownCoordinator, ownCoordinator.isSpeaking { ownCoordinator.bargeIn(.voiceCommand) }
        let coordinator = companionManager.speechOutputClient.makeCoordinator(host: self)
        coordinator.beginAnswer()
        ownCoordinator = coordinator
        speakingCoordinator = coordinator
        setDimmed(false)
    }

    private func stopOwnSpeech() {
        if let ownCoordinator, ownCoordinator.isSpeaking { ownCoordinator.bargeIn(.voiceCommand) }
        ownCoordinator = nil
    }

    // MARK: - Voice events (the answer's coordinator, via AnswerSession)

    func liveSegmentStarted(_ segment: CaptionSegment, session: AnswerSession) {
        guard session === liveSession else { return }
        segmentDidStart(segment)
    }

    func liveSegmentProgressed(_ segment: CaptionSegment, spokenCharacters: Int, session: AnswerSession) {
        guard session === liveSession else { return }
        segmentDidProgress(segment, spokenCharacters: spokenCharacters)
    }

    func liveSegmentEnded(_ segment: CaptionSegment, session: AnswerSession) {
        guard session === liveSession else { return }
        segmentDidEnd(segment)
    }

    /// The answer that narrates the board ended (played out or cut off).
    func liveSessionDidFinish(_ session: AnswerSession, wasInterrupted: Bool) {
        guard session === liveSession else { return }
        if wasInterrupted {
            narrator?.stop()
            setDimmed(false)
            publishState()
        }
        logNarration()
    }

    /// A tag of a board step resolved on the real screen fired: the board
    /// steps aside (25 %, clicks pass through) until the step ends.
    func realScreenTagFired() {
        guard isOpen else { return }
        dimmedStepIndex = narrator?.currentStepIndex
        setDimmed(true)
    }

    private func setDimmed(_ isDimmed: Bool) {
        if !isDimmed { dimmedStepIndex = nil }
        guard let panel else { return }
        panel.alphaValue = isDimmed ? Self.realScreenDimmedAlpha : 1
        panel.ignoresMouseEvents = isDimmed
    }

    // MARK: - SpeechCoordinatorHost (the board's own coordinator)

    func segmentDidStart(_ segment: CaptionSegment) {
        guard segment.boardStep != nil else { return }
        apply(narrator?.segmentStarted(segmentID: segment.id, at: clockNow) ?? [])
    }

    func segmentDidProgress(_ segment: CaptionSegment, spokenCharacters: Int) {
        guard segment.boardStep != nil else { return }
        let actions = narrator?.segmentProgress(segmentID: segment.id, spokenCharacters: spokenCharacters, at: clockNow) ?? []
        if actions.isEmpty {
            // Cues change only reveal times.
            publishState()
        } else {
            apply(actions)
        }
    }

    func segmentDidEnd(_ segment: CaptionSegment) {
        guard segment.boardStep != nil else { return }
        apply(narrator?.segmentEnded(segmentID: segment.id, at: clockNow) ?? [])
    }

    func cancelClaudeAndWorkers() {}

    func fireTag(index: Int) {
        // On replays only board POINTs act (real-screen targets went with the turn).
        guard let script = narrator?.scripts.first(where: { $0.tags.contains { $0.index == index } }),
              let scriptTag = script.tags.first(where: { $0.index == index }),
              let elementIdentifier = boardElementIdentifier(for: scriptTag.tag) else { return }
        point(atElement: elementIdentifier)
    }

    func dropUnfiredTags(_ tagIndexes: [Int]) {}

    func captionDidChange(_ caption: CaptionState) {}

    func answerDidFinish(historyText: String, wasInterrupted: Bool) {
        // The echo tail starts (what the mic hears next may still be Clicky).
        if let ownCoordinator { companionManager.speechOutputClient.recordFinished(ownCoordinator) }
    }

    func speakApology(_ text: String) {}

    func log(_ event: String) {
        print("🧑‍🏫 board voice: \(event)")
    }

    // MARK: - Hold timer (silent steps)

    private func startHoldTimer() {
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let actions = self.narrator?.tick(at: self.clockNow) ?? []
                if !actions.isEmpty { self.apply(actions) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    // MARK: - Commands

    func next() { apply(narrator?.next(at: clockNow) ?? []) }
    func back() { apply(narrator?.back(at: clockNow) ?? []) }
    func replay() { apply(narrator?.replay(at: clockNow) ?? []) }

    /// "repeat": the current step again.
    func repeatStep() {
        guard let currentStepIndex = narrator?.currentStepIndex else { return replay() }
        apply(narrator?.goTo(stepIndex: currentStepIndex, at: clockNow) ?? [])
    }

    func pause() {
        speakingCoordinator?.pause()
        narrator?.pause(at: clockNow)
        publishState()
    }

    func resume() {
        speakingCoordinator?.resume()
        apply(narrator?.resume(at: clockNow) ?? [])
    }

    func togglePause() {
        if narrator?.isPaused == true || speakingCoordinator?.isPaused == true { resume() } else { pause() }
    }

    func toggleFullScreen() {
        ClickySettings.isWhiteboardFullScreen.toggle()
        guard let panel else { return }
        panel.setFrame(WhiteboardPanel.frame(fullScreen: ClickySettings.isWhiteboardFullScreen), display: true, animate: false)
        rebuildScene()
    }

    func zoom(by factor: CGFloat) {
        guard let scene, let camera = currentCamera else { return }
        let viewportCenter = CGPoint(x: scene.viewportSize.width / 2, y: scene.viewportSize.height / 2)
        let newScale = min(3, max(0.2, camera.scale * factor))
        let ratio = newScale / camera.scale
        cameraOverride = WBCameraTransform(framedRect: camera.framedRect, scale: newScale,
                                           translation: CGVector(dx: viewportCenter.x - (viewportCenter.x - camera.translation.dx) * ratio,
                                                                 dy: viewportCenter.y - (viewportCenter.y - camera.translation.dy) * ratio))
        publishState()
    }

    func fitBoard() {
        cameraOverride = scene?.cameraPlan.boardTransform
        publishState()
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Esc close, ←/→ step, Space pause, r replay, e export, c copy, f full screen, 0 fit, +/− zoom.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 53: close(); return true
        case 123: back(); return true
        case 124: next(); return true
        case 49: togglePause(); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": replay()
        case "e": _ = exportBoard()
        case "c": copyBoardImage()
        case "f": toggleFullScreen()
        case "0": fitBoard()
        case "+", "=": zoom(by: Self.zoomStep)
        case "-", "_": zoom(by: 1 / Self.zoomStep)
        default: return false
        }
        return true
    }

    // MARK: - Pointing

    /// The board element a POINT tag means, if it names one ([POINT:hello:…], [POINT:"Web server"]).
    func boardElementIdentifier(for tag: ParsedTag) -> String? {
        guard let board, tag.kind == .point else { return nil }
        var candidates: [String] = []
        if case .text(let query, _, _) = tag.target { candidates.append(query) }
        if let name = tag.name { candidates.append(name) }
        for candidate in candidates {
            let lowered = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let element = board.elements.first(where: { $0.id.lowercased() == lowered }) { return element.id }
            if let element = board.elements.first(where: { element in
                if case .box(let box) = element.payload { return box.text.lowercased() == lowered }
                return false
            }) { return element.id }
        }
        return nil
    }

    /// The element's rect on screen (CG) as the panel shows it at the step's camera.
    func screenRectCG(ofElement elementIdentifier: String) -> CGRect? {
        guard let scene, let camera = currentCamera, let panel, let hostingView = panel.contentView,
              let boardRect = scene.adapted.boardRect(of: elementIdentifier, in: scene.layout) else { return nil }
        var viewRect = CGRect(x: boardRect.minX * camera.scale + camera.translation.dx,
                              y: boardRect.minY * camera.scale + camera.translation.dy + WhiteboardScene.headerHeight,
                              width: boardRect.width * camera.scale, height: boardRect.height * camera.scale)
        if !hostingView.isFlipped { viewRect.origin.y = hostingView.bounds.height - viewRect.maxY }
        let windowRect = hostingView.convert(viewRect, to: nil)
        let screenRectAppKit = panel.convertToScreen(windowRect)
        return ScreenTopology.cg(fromAppKit: screenRectAppKit, flipH: ScreenTopology.mainDisplayHeight)
    }

    func point(atElement elementIdentifier: String) {
        guard isOpen, let rectCG = screenRectCG(ofElement: elementIdentifier) else { return }
        companionManager.flyCompanion(toBoardRectCG: rectCG)
    }

    // MARK: - Export

    private var exportDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Clicky", isDirectory: true)
    }

    /// PNG (2×, whole board) in ~/Pictures/Clicky and on the pasteboard, plus
    /// a PDF of the same board and the board's JSONL as a .clickyboard file next to it.
    @discardableResult
    func exportBoard() -> URL? {
        guard let scene, let board, let image = WhiteboardExporter.exportImage(scene: scene, theme: theme),
              let pngData = WhiteboardExporter.pngData(image) else { return nil }
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        let baseName = "whiteboard-\(timestampFormatter.string(from: Date()))"
        do {
            try FileManager.default.createDirectory(at: exportDirectoryURL, withIntermediateDirectories: true)
            let pngURL = exportDirectoryURL.appendingPathComponent(baseName + ".png")
            try pngData.write(to: pngURL, options: .atomic)
            // The same picture as a vector PDF (text stays selectable); the PNG stays the one on the pasteboard.
            try WhiteboardExporter.exportPDF(scene: scene, theme: theme, to: exportDirectoryURL.appendingPathComponent(baseName + ".pdf"))
            try WBJSONLSerializer.serialize(board).write(to: exportDirectoryURL.appendingPathComponent(baseName + ".clickyboard"), atomically: true, encoding: .utf8)
            putOnPasteboard(pngData)
            print("🧑‍🏫 Board exported to \(pngURL.path) and \(baseName).pdf")
            return pngURL
        } catch {
            print("⚠️ Board export failed: \(error)")
            return nil
        }
    }

    func copyBoardImage() {
        guard let scene, let image = WhiteboardExporter.exportImage(scene: scene, theme: theme),
              let pngData = WhiteboardExporter.pngData(image) else { return }
        putOnPasteboard(pngData)
    }

    private func putOnPasteboard(_ pngData: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(pngData, forType: .png)
    }

    // MARK: - History and logs

    /// The BOARD STATE block for the answer that drew the board.
    func historyEntry(spokenHistory: String, session: AnswerSession) -> String? {
        guard let board, session === presentingSession else { return nil }
        let currentStepNumber = narrator?.currentStepIndex.map { board.steps[$0].number }
        return BoardHistory.historyEntry(spokenHistory: spokenHistory, board: board, currentStepNumber: currentStepNumber)
    }

    private func logNarration() {
        guard let narrator, let turnRecord, narrator.log.count > loggedNarrationEntryCount else { return }
        for entry in narrator.log[loggedNarrationEntryCount...] {
            turnRecord.boardEvents.append(TurnRecord.BoardEventEntry(kind: entry.kind.rawValue, step: entry.stepNumber, segment: entry.segmentID,
                                                                     t: Date(timeIntervalSinceReferenceDate: entry.time).timeIntervalSince1970))
        }
        loggedNarrationEntryCount = narrator.log.count
    }

    /// For the debug inbox's `boardCtl state`.
    func stateSummary() -> [String: Any] {
        var summary: [String: Any] = ["open": isOpen, "hasBoard": board != nil, "theme": theme.rawValue,
                                      "fullScreen": ClickySettings.isWhiteboardFullScreen]
        if let board {
            summary["title"] = board.title
            summary["sections"] = board.sections.map(\.id)
            summary["steps"] = board.steps.count
        }
        if let narrator {
            summary["currentStep"] = narrator.currentStepIndex.map { $0 + 1 } ?? 0
            summary["mode"] = narrator.mode.rawValue
            summary["paused"] = narrator.isPaused
            summary["finished"] = narrator.isFinished
            summary["revealed"] = narrator.revealTimes.count
        }
        summary["dimmed"] = (panel?.alphaValue ?? 1) < 1
        summary["shell"] = shellWorkerTitles
        return summary
    }
}
