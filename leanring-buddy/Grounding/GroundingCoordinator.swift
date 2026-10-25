//
//  GroundingCoordinator.swift
//  leanring-buddy
//
//  Builds what the model sees for one question: each screen's element list
//  (AX + OCR, numbered) and its badged screenshot, plus the registry the
//  answer's tags are resolved against.
//
//  Prewarm (key-down): capture every screen, read the window list, walk AX
//  and OCR everything in the background while the user is still talking.
//  Key-up, warm path: recapture only the cursor screen, diff it against the
//  prewarm in 64 px blocks, re-OCR just the changed strips (40 ms budget) and
//  re-walk the front app in parallel; other screens reuse the prewarm.
//  Key-up, cold path (no prewarm, or the cursor moved to another screen):
//  capture + AX now, OCR in the background — the list goes without OCR-only
//  lines and text lookups wait up to 500 ms for it when resolving.
//
//  P6.8 perf: an app whose windows haven't changed (AXObserver events,
//  AXWalkCache) reuses its last walk instead of walking again; OCR skips
//  tiles that trusted AX text already covers or that are blank
//  (OCRCoveragePlanner); listed Chromium/Electron apps get
//  AXEnhancedUserInterface while frontmost; and a warning (plus a turn.json
//  flag) fires when key-up p95 over 20 turns passes 150 ms warm / 300 ms cold.
//
//  Capture warm-up: right after launch (and after a display change or wake)
//  ScreenCaptureKit can return every other app's window solid black. Throwaway
//  captures run in the background until one passes the black check
//  (CaptureWarmUp); an ask waits up to 1 s for a warm-up still running, and
//  a black frame at ask time is still retaken (captureCheckingForBlackWindows).
//

import AppKit
import ClickyCore
import ScreenCaptureKit

private final class ResumeOnceBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }
    func resume(_ value: Value?) {
        lock.lock()
        let pendingContinuation = continuation
        continuation = nil
        lock.unlock()
        pendingContinuation?.resume(returning: value)
    }
}

/// Waits for a task's value up to a deadline; nil on timeout (the task keeps
/// running unless the caller cancels it). Unlike a task group, it really
/// returns at the deadline.
func awaitValue<Value: Sendable>(of task: Task<Value, Never>, timeoutNanoseconds: UInt64) async -> Value? {
    return await withCheckedContinuation { continuation in
        let onceBox = ResumeOnceBox<Value>(continuation)
        Task { onceBox.resume(await task.value) }
        Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            onceBox.resume(nil)
        }
    }
}

/// Everything about one question's screens.
struct GroundedTurn {
    var screenCaptures: [ScreenCapture]
    var registry: ElementRegistry
    let windowStack: WindowStack
    let cursorCG: CGPoint
    /// Per screen: the element-list text block and the badged JPEG, in order.
    let contentBlocks: [ClaudeContentBlock]
    let elementListTexts: [String]
    let isWarm: Bool
    let droppedAXApplications: [String]
    /// Milliseconds from key-up to the content being ready.
    let keyUpToReadyMilliseconds: Double
    let isBadged: Bool
    /// Background OCR still running on the cold path.
    let pendingOCRTask: Task<[OCRLine], Never>?
    /// Set when key-up p95 over the last 20 turns is over its limit.
    var latencyAlarmWarning: String?
    /// Set when a capture came back with every app window black and was retaken.
    var blackFrameRetry: TurnRecord.BlackFrameRetryEntry?

    var framesByScreenNumber: [Int: CaptureFrame] {
        Dictionary(uniqueKeysWithValues: screenCaptures.map { ($0.screenNumber, $0.frame) })
    }

    /// A text target wasn't found: OCR every screen again with bands shifted
    /// by half a band (text that sat on a seam, or a line Vision skipped) and
    /// merge the new lines in. Done at most once per turn.
    mutating func retryOCRWithShiftedBands() async {
        guard !hasRetriedOCR else { return }
        hasRetriedOCR = true
        let captures = screenCaptures
        let retryLines = await withTaskGroup(of: [OCRLine].self) { taskGroup in
            for screenCapture in captures {
                taskGroup.addTask { await OCREngine.recognizeLines(in: screenCapture.nativeImage, frame: screenCapture.frame, bandPhase: 0.5) }
            }
            var allLines: [OCRLine] = []
            for await lines in taskGroup { allLines += lines }
            return allLines
        }
        registry.allOCRLines = OCREngine.deduplicated(registry.allOCRLines + retryLines)
    }
    var hasRetriedOCR = false

    /// Text lookups need OCR: on the cold path wait (≤ 500 ms) for it.
    mutating func ensureOCRLines() async {
        guard let pendingOCRTask, registry.allOCRLines.isEmpty else { return }
        registry.allOCRLines = await awaitValue(of: pendingOCRTask, timeoutNanoseconds: 500_000_000) ?? []
    }
}

@MainActor
final class GroundingCoordinator {
    private struct Snapshot {
        var screenCaptures: [ScreenCapture]
        var axElements: [GroundingElement]
        var ocrLinesByDisplay: [CGDirectDisplayID: [OCRLine]]
        var grayImagesByDisplay: [CGDirectDisplayID: GrayImage]
        var windowStack: WindowStack
        var cursorDisplayID: CGDirectDisplayID
        var readyDate: Date
        var droppedAXApplications: [String] = []
        var blackFrameRetry: TurnRecord.BlackFrameRetryEntry?
    }

    /// One screen's OCR result in a full snapshot.
    private nonisolated struct ScreenAnalysis: Sendable {
        let displayID: CGDirectDisplayID
        let ocrLines: [OCRLine]
        let grayImage: GrayImage?
        let ocrMilliseconds: Double
        let coveragePlan: OCRCoveragePlanner.Plan
    }

    /// A walk to wait for, or the cache's copy of one (P6.8).
    private struct PlannedAXWalk {
        let request: AXEnumerationRequest
        let windowStack: WindowStack
        let liveWalk: AXAppWalk?
        let cachedElements: [GroundingElement]?
        let walkStartGeneration: Int

        func elements(waitingUntil deadline: DispatchTime) -> (elements: [GroundingElement], didFinish: Bool, error: Error?) {
            if let cachedElements { return (cachedElements, true, nil) }
            return liveWalk?.elements(waitingUntil: deadline) ?? ([], true, nil)
        }

        func cancel() { liveWalk?.cancel() }
    }

    let ax: AXQuerying = SystemAXQuerying()
    /// Last finished walk per (pid, window), kept clean by AX observers.
    private let axWalkCache = AXWalkCache()
    private lazy var axObserverHub = AXObserverHub(cache: axWalkCache)
    private lazy var enhancedUserInterfaceController = EnhancedUserInterfaceController(ax: ax)
    /// Apps whose AX frames agreed with OCR: their text may replace OCR.
    private var alignmentLedger = AXAlignmentLedger()
    private var latencyAlarm = GroundingLatencyAlarm()
    private var terminationObserver: NSObjectProtocol?
    private var shareableContentInvalidationObservers: [NSObjectProtocol] = []
    private var captureWarmUpObservers: [NSObjectProtocol] = []
    private var captureWarmUp = CaptureWarmUp()
    private var captureWarmUpTask: Task<Void, Never>?
    /// How the last capture warm-up went (diagnostics / turn log).
    private(set) var lastCaptureWarmUpDescription: String?
    /// Per display in the last OCR pass: tiles skipped / planned regions.
    private(set) var lastOCRCoverageStats: [String] = []
    /// The measured cap for the current model (tier probe), if any.
    var effectiveMaxEdgeProvider: () -> Int? = { nil }
    private var captureOptions: ScreenCaptureService.Options {
        ScreenCaptureService.Options(effectiveMaxEdge: effectiveMaxEdgeProvider())
    }
    private var prewarmTask: Task<Snapshot?, Never>?
    private(set) var prewarmStartDate: Date?
    private(set) var lastPrewarmReadyDate: Date?
    /// Where the last key-up's time went (diagnostics).
    var lastTurnStageMilliseconds: [String: Double] = [:]
    /// Per AX walk in the last snapshot: app, scope, elements, finished in time.
    private(set) var lastAXWalkStats: [String] = []
    /// OCR wall time per display in the last full snapshot (ms).
    private(set) var lastOCRMillisecondsByDisplay: [CGDirectDisplayID: Double] = [:]
    /// Shown in the panel when AX isn't available.
    var groundingLimitationReason: String? {
        AXIsProcessTrusted() ? nil : "Accessibility is off, so Clicky can only read the screen (OCR)."
    }

    /// Observers + enhanced-UI tracking (once, from the app's start).
    func startBackgroundServices() {
        guard terminationObserver == nil else { return }
        _ = axObserverHub
        // A page that showed up after the ask-time wait (Chrome takes ~2 s):
        // the next ask walks the app afresh instead of reusing the toolbar.
        enhancedUserInterfaceController.onWebContentReady = { [weak self] processIdentifier, _ in
            self?.axWalkCache.apply(.applicationChanged(processIdentifier))
        }
        enhancedUserInterfaceController.start()
        startCaptureWarmUp(reason: "launch")
        let restartWarmUp: @Sendable (Notification) -> Void = { [weak self] notification in
            let reason = notification.name.rawValue
            Task { @MainActor in self?.startCaptureWarmUp(reason: reason) }
        }
        captureWarmUpObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: restartWarmUp))
        for notificationName in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            captureWarmUpObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: notificationName, object: nil, queue: .main, using: restartWarmUp))
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let processIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.alignmentLedger.evict(processIdentifier) }
        }
        // The cached shareable-content list (≤ 3 s, warm path) describes the
        // apps and displays of when it was fetched: drop it when they change.
        let invalidateShareableContent: @Sendable (Notification) -> Void = { _ in
            Task { await ShareableContentCache.shared.invalidate() }
        }
        for notificationName in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            shareableContentInvalidationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: notificationName, object: nil, queue: .main, using: invalidateShareableContent))
        }
        shareableContentInvalidationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: invalidateShareableContent))
    }

    // MARK: - Prewarm

    /// Starts capturing and analysing every screen in the background
    /// (push-to-talk key-down / first words of a hands-free utterance).
    func prewarm() {
        guard prewarmTask == nil else { return }
        prewarmStartDate = Date()
        lastPrewarmReadyDate = nil
        prewarmTask = Task { [weak self] in
            guard let self else { return nil }
            do {
                let snapshot = try await self.makeFullSnapshot(awaitsOCR: true)
                self.lastPrewarmReadyDate = snapshot.readyDate
                return snapshot
            } catch {
                print("⚠️ Grounding prewarm failed: \(error)")
                return nil
            }
        }
    }

    func cancelPrewarm() {
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    // MARK: - Key-up

    /// Builds the grounded content for a question asked at `keyUpDate`.
    func prepareTurn(keyUpDate: Date) async throws -> GroundedTurn {
        var groundedTurn = try await prepareTurnContent(keyUpDate: keyUpDate)
        let latencyStatus = latencyAlarm.record(keyUpToReadyMilliseconds: groundedTurn.keyUpToReadyMilliseconds, isWarm: groundedTurn.isWarm)
        if let warningText = latencyStatus.warningText {
            print("⚠️ Grounding latency over limit (last \(GroundingLatencyAlarm.windowTurnCount) turns): \(warningText)")
            groundedTurn.latencyAlarmWarning = warningText
        }
        return groundedTurn
    }

    private func prepareTurnContent(keyUpDate: Date) async throws -> GroundedTurn {
        let preparationStart = Date()
        let cursorCG = ScreenTopology.cg(fromAppKit: NSEvent.mouseLocation, flipH: ScreenTopology.mainDisplayHeight)
        let currentDisplays = ScreenTopology.current()
        let cursorDisplay = currentDisplays.first { $0.boundsCG.contains(cursorCG) } ?? currentDisplays.first

        // Warm only if the prewarm finished and the cursor is still on the
        // same screen; never wait for an unfinished prewarm.
        var warmSnapshot: Snapshot?
        if let prewarmTask, lastPrewarmReadyDate != nil {
            warmSnapshot = await prewarmTask.value
        }
        cancelPrewarm()

        let isBadged = ClickySettings.areBadgesEnabled
        if let warmSnapshot, let cursorDisplay, warmSnapshot.cursorDisplayID == cursorDisplay.displayID {
            let updatedSnapshot = try await refreshCursorScreen(of: warmSnapshot, cursorDisplay: cursorDisplay, encodesJPEG: !isBadged)
            return await makeGroundedTurn(from: updatedSnapshot, cursorCG: cursorCG, isWarm: true, isBadged: isBadged,
                                          pendingOCRTask: nil, preparationStart: preparationStart, keyUpDate: keyUpDate)
        }

        // Cold path.
        var coldSnapshot = try await makeFullSnapshot(awaitsOCR: false)
        let capturesForOCR = coldSnapshot.screenCaptures
        let coveredRectsByDisplay = coveredRectsCGByDisplay(axElements: coldSnapshot.axElements, captures: capturesForOCR, windowStack: coldSnapshot.windowStack)
        let pendingOCRTask = Task<[OCRLine], Never> {
            await withTaskGroup(of: [OCRLine].self) { taskGroup in
                for screenCapture in capturesForOCR {
                    let coveredRectsCG = coveredRectsByDisplay[screenCapture.displayID] ?? []
                    taskGroup.addTask {
                        let grayImage = GrayImage(cgImage: screenCapture.nativeImage)
                        return await Self.recognizeUncoveredLines(in: screenCapture, coveredRectsCG: coveredRectsCG, grayImage: grayImage, level: .accurate).lines
                    }
                }
                var allLines: [OCRLine] = []
                for await lines in taskGroup { allLines += lines }
                return allLines
            }
        }
        coldSnapshot.ocrLinesByDisplay = [:]
        return await makeGroundedTurn(from: coldSnapshot, cursorCG: cursorCG, isWarm: false, isBadged: isBadged,
                                      pendingOCRTask: pendingOCRTask, preparationStart: preparationStart, keyUpDate: keyUpDate)
    }

    // MARK: - Snapshots

    private func makeFullSnapshot(awaitsOCR: Bool) async throws -> Snapshot {
        let displays = ScreenTopology.current()
        let windowStack = WindowListReader.read(displays: displays)
        let enhancedUINote = await prepareFrontmostApplicationForAsk()?.note
        let axWalks = startAXWalks(windowStack: windowStack)

        await waitForCaptureWarmUp()
        let (screenCaptures, blackFrameRetry) = try await captureCheckingForBlackWindows { options in
            try await ScreenCaptureService.captureAllScreens(options: options)
        }

        // OCR reads only what trusted AX text doesn't cover. With no trusted
        // app yet it starts right away (blank tiles still skipped) while the
        // AX walks run; otherwise once their elements are in.
        let trustedProcessIdentifiers = alignmentLedger.trustedProcessIdentifiers(at: Date())
        func startAnalysis(coveredRectsByDisplay: [CGDirectDisplayID: [CGRect]]) -> Task<[ScreenAnalysis], Never> {
            Task {
                await withTaskGroup(of: ScreenAnalysis.self) { taskGroup in
                    for screenCapture in screenCaptures {
                        let coveredRectsCG = coveredRectsByDisplay[screenCapture.displayID] ?? []
                        let displayID = screenCapture.displayID
                        // Accurate where the user is looking, fast elsewhere; a
                        // missed text target triggers a full retry pass later.
                        let ocrLevel: OCREngine.Level = screenCapture.isCursorScreen ? .accurate : .fast
                        taskGroup.addTask {
                            let ocrStart = Date()
                            let grayImage = GrayImage(cgImage: screenCapture.nativeImage)
                            let recognized = await Self.recognizeUncoveredLines(in: screenCapture, coveredRectsCG: coveredRectsCG, grayImage: grayImage, level: ocrLevel)
                            return ScreenAnalysis(displayID: displayID, ocrLines: recognized.lines, grayImage: grayImage,
                                                  ocrMilliseconds: Date().timeIntervalSince(ocrStart) * 1000, coveragePlan: recognized.plan)
                        }
                    }
                    var results: [ScreenAnalysis] = []
                    for await result in taskGroup { results.append(result) }
                    return results
                }
            }
        }
        var analysisTask: Task<[ScreenAnalysis], Never>? = awaitsOCR && trustedProcessIdentifiers.isEmpty ? startAnalysis(coveredRectsByDisplay: [:]) : nil
        let axElements = collectAXElements(from: axWalks)
        if let enhancedUINote { lastAXWalkStats.insert(enhancedUINote, at: 0) }
        if awaitsOCR && analysisTask == nil {
            analysisTask = startAnalysis(coveredRectsByDisplay: coveredRectsCGByDisplay(axElements: axElements, captures: screenCaptures,
                                                                                         windowStack: windowStack, trustedProcessIdentifiers: trustedProcessIdentifiers))
        }

        var ocrLinesByDisplay: [CGDirectDisplayID: [OCRLine]] = [:]
        var grayImagesByDisplay: [CGDirectDisplayID: GrayImage] = [:]
        if let analysisTask {
            var coverageStats: [String] = []
            for analysis in await analysisTask.value {
                ocrLinesByDisplay[analysis.displayID] = analysis.ocrLines
                grayImagesByDisplay[analysis.displayID] = analysis.grayImage
                lastOCRMillisecondsByDisplay[analysis.displayID] = analysis.ocrMilliseconds
                coverageStats.append(Self.coverageDescription(displayID: analysis.displayID, plan: analysis.coveragePlan, milliseconds: analysis.ocrMilliseconds))
            }
            lastOCRCoverageStats = coverageStats
        }

        let cursorDisplayID = screenCaptures.first(where: \.isCursorScreen)?.displayID ?? displays.first?.displayID ?? 0
        let dropped = Self.dropMisalignedAXApplications(axElements: axElements, ocrLines: ocrLinesByDisplay.values.flatMap { $0 })
        if awaitsOCR && !ocrLinesByDisplay.isEmpty {
            // Apps OCRed in full this time that weren't dropped now agree with OCR.
            let droppedProcessIdentifiers = Set(axElements.map(\.processIdentifier)).subtracting(dropped.keptElements.map(\.processIdentifier))
            droppedProcessIdentifiers.forEach { alignmentLedger.recordMisaligned($0) }
            alignmentLedger.recordVerified(Set(dropped.keptElements.map(\.processIdentifier)).subtracting(trustedProcessIdentifiers), at: Date())
        }
        return Snapshot(screenCaptures: screenCaptures, axElements: dropped.keptElements, ocrLinesByDisplay: ocrLinesByDisplay,
                        grayImagesByDisplay: grayImagesByDisplay, windowStack: windowStack, cursorDisplayID: cursorDisplayID,
                        readyDate: Date(), droppedAXApplications: dropped.droppedApplications, blackFrameRetry: blackFrameRetry)
    }

    /// Warm path: new capture of the cursor screen only; re-OCR changed strips
    /// (40 ms budget) and re-walk the front app in parallel.
    private func refreshCursorScreen(of snapshot: Snapshot, cursorDisplay: DisplayInfo, encodesJPEG: Bool) async throws -> Snapshot {
        var refreshedSnapshot = snapshot
        let windowStack = WindowListReader.read(displays: ScreenTopology.current())
        refreshedSnapshot.windowStack = windowStack
        let enhancedUIResult = await prepareFrontmostApplicationForAsk()
        if let enhancedUINote = enhancedUIResult?.note { lastAXWalkStats.insert(enhancedUINote, at: 0) }
        let frontApplicationWalks = startAXWalks(windowStack: windowStack, frontApplicationOnly: true)
        let walksStart = DispatchTime.now()
        // The page just appeared: the prewarm's copy is toolbar-only, so give
        // the fresh walk of the page time to finish.
        let frontWalkBudgetMilliseconds = enhancedUIResult?.pageBecameReady == true ? 300 : 60

        guard let previousCapture = snapshot.screenCaptures.first(where: { $0.displayID == cursorDisplay.displayID }) else { return snapshot }
        let mainBoundsCG = ScreenTopology.current().first(where: \.isMain)?.boundsCG ?? cursorDisplay.boundsCG
        await waitForCaptureWarmUp()
        let (newCaptures, blackFrameRetry) = try await captureCheckingForBlackWindows { options in
            [try await ScreenCaptureService.captureScreen(
                display: cursorDisplay,
                screenNumber: previousCapture.screenNumber,
                isCursorScreen: true,
                positionDescription: cursorDisplay.positionDescription(relativeTo: mainBoundsCG),
                options: options,
                encodesJPEG: encodesJPEG
            )]
        }
        guard let newCapture = newCaptures.first else { return snapshot }
        if let blackFrameRetry { refreshedSnapshot.blackFrameRetry = blackFrameRetry }
        refreshedSnapshot.screenCaptures = snapshot.screenCaptures.map { $0.displayID == cursorDisplay.displayID ? newCapture : $0 }
        lastTurnStageMilliseconds["capture"] = (Double(DispatchTime.now().uptimeNanoseconds - walksStart.uptimeNanoseconds) / 1e6).rounded()

        // Front app AX: fresh when its walk finishes within 60 ms of starting
        // (300 ms when the page just appeared; ran in parallel with the
        // capture); otherwise the prewarm's copy.
        var freshFrontElements: [GroundingElement] = []
        var refreshedProcessIdentifiers = Set<pid_t>()
        for walk in frontApplicationWalks {
            let walkResult = walk.elements(waitingUntil: walksStart + .milliseconds(frontWalkBudgetMilliseconds))
            if walkResult.didFinish {
                freshFrontElements += walkResult.elements
                refreshedProcessIdentifiers.insert(walk.request.processIdentifier)
                rememberFinishedWalk(walk, result: walkResult)
            } else {
                walk.cancel()
            }
        }
        lastTurnStageMilliseconds["frontAXCached"] = Double(frontApplicationWalks.filter { $0.cachedElements != nil && $0.request.scope == .frontApplication }.count)
        refreshedSnapshot.axElements = snapshot.axElements.filter { !refreshedProcessIdentifiers.contains($0.processIdentifier) } + freshFrontElements

        lastTurnStageMilliseconds["frontAX"] = (Double(DispatchTime.now().uptimeNanoseconds - walksStart.uptimeNanoseconds) / 1e6).rounded()
        // OCR: only strips over changed blocks (40 ms budget).
        if let previousGray = snapshot.grayImagesByDisplay[cursorDisplay.displayID], let newGray = GrayImage(cgImage: newCapture.nativeImage) {
            let blockDifferences = BlockDiff.compare(previousGray, newGray)
            lastTurnStageMilliseconds["diff"] = (Double(DispatchTime.now().uptimeNanoseconds - walksStart.uptimeNanoseconds) / 1e6).rounded()
            lastTurnStageMilliseconds["changedBlocks"] = Double(blockDifferences.changedBlockRects.count)
            refreshedSnapshot.grayImagesByDisplay[cursorDisplay.displayID] = newGray
            if blockDifferences.hasChanges {
                let changedStripsPx = blockDifferences.changedStrips(imageWidth: newGray.width, imageHeight: newGray.height)
                let changedStripsCG = changedStripsPx.map { newCapture.frame.cgRect(fromNativePxRect: $0) }
                let changedBlocksCG = blockDifferences.changedBlockRects.map { newCapture.frame.cgRect(fromNativePxRect: $0) }
                let previousLines = snapshot.ocrLinesByDisplay[cursorDisplay.displayID] ?? []
                // Changed strips, minus what trusted AX text covers or is blank.
                let coveredRectsCG = coveredRectsCGByDisplay(axElements: refreshedSnapshot.axElements, captures: [newCapture], windowStack: windowStack)[cursorDisplay.displayID] ?? []
                let reOCRTask = Task<[OCRLine], Never> {
                    await Self.recognizeUncoveredLines(in: newCapture, coveredRectsCG: coveredRectsCG, grayImage: newGray, level: .accurate,
                                                       limitedToRegionsPx: changedStripsPx).lines
                }
                let reOCRLines = await awaitValue(of: reOCRTask, timeoutNanoseconds: 40_000_000)
                if reOCRLines == nil { reOCRTask.cancel() }
                if let reOCRLines {
                    // Replace lines in the re-read strips.
                    let keptLines = previousLines.filter { line in !changedStripsCG.contains { $0.intersects(line.frameCG) } }
                    refreshedSnapshot.ocrLinesByDisplay[cursorDisplay.displayID] = OCREngine.deduplicated(keptLines + reOCRLines)
                } else {
                    // Not done in 40 ms: drop lines that sit on changed blocks.
                    refreshedSnapshot.ocrLinesByDisplay[cursorDisplay.displayID] = previousLines.filter { line in
                        !changedBlocksCG.contains { $0.intersects(line.frameCG) }
                    }
                }
            }
        }
        lastTurnStageMilliseconds["refreshTotal"] = (Double(DispatchTime.now().uptimeNanoseconds - walksStart.uptimeNanoseconds) / 1e6).rounded()
        return refreshedSnapshot
    }

    // MARK: - Black frames

    /// Runs `capture`; when any display's on-screen app windows came back
    /// near-uniform black (BlackFrameDetector: ≥ 60 % of their area, judged
    /// per display) drops the cached shareable content and captures again
    /// after 200 ms; if still black, once more with a fresh
    /// SCShareableContent and a window-based SCContentFilter. The window
    /// rects come from CGWindowListCopyWindowInfo read at judging time, not
    /// from SCShareableContent (which may not list other apps' windows in
    /// the very state that blacks them out). The retry is returned for
    /// turn.json (grounding.blackFrameRetry).
    private func captureCheckingForBlackWindows(
        capture: (ScreenCaptureService.Options) async throws -> [ScreenCapture]
    ) async throws -> (captures: [ScreenCapture], retry: TurnRecord.BlackFrameRetryEntry?) {
        let firstCaptures = try await capture(captureOptions)
        let firstVerdict = await Self.blackFrameVerdict(of: firstCaptures)
        guard firstVerdict.isBlackFrame else { return (firstCaptures, nil) }
        let firstSummary = firstVerdict.summary
        let firstFraction = (firstSummary.blackFraction * 100).rounded() / 100
        print("⚠️ Capture: \(firstVerdict.blackDisplayCount)/\(firstVerdict.displayVerdicts.count) displays with black app windows (\(firstSummary.blackWindowCount)/\(firstSummary.judgedWindowCount) windows, \(Int(firstFraction * 100))% of their area); recapturing")
        func entry(count: Int, result: String) -> TurnRecord.BlackFrameRetryEntry {
            TurnRecord.BlackFrameRetryEntry(count: count, result: result, firstBlackFraction: firstFraction,
                                            blackDisplays: firstVerdict.blackDisplayCount, source: "cgWindowList",
                                            warmUp: lastCaptureWarmUpDescription)
        }

        await ShareableContentCache.shared.invalidate()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let secondCaptures = try await capture(captureOptions)
        let secondVerdict = await Self.blackFrameVerdict(of: secondCaptures)
        if !secondVerdict.isBlackFrame {
            print("✅ Capture: black windows gone after 1 retry")
            return (secondCaptures, entry(count: 1, result: "recovered"))
        }

        var freshOptions = captureOptions
        freshOptions.forcesFreshContentAndWindowFilter = true
        await ShareableContentCache.shared.invalidate()
        let thirdCaptures = try await capture(freshOptions)
        let thirdVerdict = await Self.blackFrameVerdict(of: thirdCaptures)
        let result = thirdVerdict.isBlackFrame ? "stillBlack" : "recoveredFreshFilter"
        print("\(thirdVerdict.isBlackFrame ? "⚠️" : "✅") Capture: after a fresh SCShareableContent + filter: \(result)")
        if thirdVerdict.isBlackFrame { startCaptureWarmUp(reason: "stillBlack") }
        return (thirdCaptures, entry(count: 2, result: result))
    }

    /// Each capture's app windows judged on their own display (off the main
    /// actor), against the CG window list as it is now.
    nonisolated private static func blackFrameVerdict(of captures: [ScreenCapture]) async -> BlackFrameDetector.FrameVerdict {
        await blackFrameVerdict(of: captures.map { (image: $0.nativeImage, frame: $0.frame) })
    }

    nonisolated private static func blackFrameVerdict(of inputs: [(image: CGImage, frame: CaptureFrame)]) async -> BlackFrameDetector.FrameVerdict {
        await Task.detached(priority: .userInitiated) {
            let windowList = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
            let ownProcessIdentifier = getpid()
            return BlackFrameDetector.FrameVerdict(displayVerdicts: inputs.map { input in
                let windowRectsCG = BlackFrameDetector.windowRectsCG(fromWindowList: windowList, ownProcessIdentifier: ownProcessIdentifier,
                                                                     displayBoundsCG: input.frame.display.boundsCG)
                let windowRects = BlackFrameDetector.windowRectsNativePx(windowRectsCG: windowRectsCG, frame: input.frame)
                guard !windowRects.isEmpty, let gray = GrayImage(cgImage: input.image) else { return .empty }
                return BlackFrameDetector.analyze(gray: gray, windowRectsNativePx: windowRects)
            })
        }.value
    }

    // MARK: - Capture warm-up

    /// (Re)starts the background warm-up: throwaway captures every 1.5 s
    /// (first after 0.5 s) until one passes the black check or there are no
    /// app windows to judge, for at most 30 s.
    func startCaptureWarmUp(reason: String) {
        captureWarmUp.start(at: Date())
        captureWarmUpTask?.cancel()
        let startDate = Date()
        captureWarmUpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch self.captureWarmUp.nextStep(at: Date()) {
                case .done:
                    let description = "\(reason): \(self.captureWarmUp.description) in \(Int((Date().timeIntervalSince(startDate) * 1000).rounded())) ms"
                    self.lastCaptureWarmUpDescription = description
                    print("📸 Capture warm-up \(description)")
                    return
                case .wait(let seconds):
                    try? await Task.sleep(nanoseconds: UInt64(max(0.01, seconds) * 1e9))
                case .captureNow:
                    let outcome = await self.warmUpCaptureOutcome()
                    guard !Task.isCancelled else { return }
                    if outcome == .black { print("📸 Capture warm-up (\(reason)): app windows still black") }
                    self.captureWarmUp.record(outcome, at: Date())
                }
            }
        }
    }

    /// An ask while the warm-up is still running waits for it (≤ 1 s).
    private func waitForCaptureWarmUp() async {
        guard captureWarmUp.isRunning, let captureWarmUpTask else { return }
        let waitStart = Date()
        _ = await awaitValue(of: captureWarmUpTask, timeoutNanoseconds: UInt64(CaptureWarmUp.askWaitSeconds * 1e9))
        lastTurnStageMilliseconds["warmUpWait"] = (Date().timeIntervalSince(waitStart) * 1000).rounded()
    }

    /// One throwaway capture of every display (native pixels, nothing
    /// encoded or kept), judged like an ask's. A fresh SCShareableContent
    /// each time, and it isn't cached (it may describe the bad state).
    private func warmUpCaptureOutcome() async -> CaptureWarmUp.Outcome {
        guard CGPreflightScreenCaptureAccess() else { return .failed }
        let displays = ScreenTopology.current()
        guard !displays.isEmpty else { return .failed }
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var inputs: [(image: CGImage, frame: CaptureFrame)] = []
            for (displayIndex, display) in displays.enumerated() {
                let (image, regionCG) = try await ScreenCaptureService.captureNativeImage(of: display, includesOwnWindows: false,
                                                                                          shareableContent: shareableContent)
                let nativeSize = PixelSize(width: image.width, height: image.height)
                inputs.append((image, CaptureFrame(display: display, screenNumber: displayIndex + 1, regionCG: regionCG, native: nativeSize, model: nativeSize)))
            }
            let verdict = await Self.blackFrameVerdict(of: inputs)
            if verdict.isBlackFrame { return .black }
            return verdict.hasNoAppWindows ? .noAppWindows : .good
        } catch {
            return .failed
        }
    }

    // MARK: - AX

    /// P6.8 fix: the frontmost Chromium/Electron app's page must be in its
    /// tree on the first ask (EnhancedUserInterfaceController). When the
    /// flag was (re)set or the page was just seen for the first time, its
    /// cached walk (toolbar only) is dropped so the walk that follows reads
    /// the page. The result's note goes to turn.json.
    private func prepareFrontmostApplicationForAsk() async -> EnhancedUserInterfaceController.AskTimeResult? {
        guard ax.isProcessTrusted(), let result = await enhancedUserInterfaceController.prepareFrontmostApplicationForAsk() else { return nil }
        axWalkCache.apply(.applicationChanged(result.processIdentifier))
        print("🌐 \(result.note)")
        return result
    }

    private func startAXWalks(windowStack: WindowStack, frontApplicationOnly: Bool = false) -> [PlannedAXWalk] {
        guard ax.isProcessTrusted() else { return [] }
        let ownProcessIdentifier = getpid()
        let valueBlockedBundleIdentifiers = ClickySettings.valueBlockedBundleIDs
        var walks: [PlannedAXWalk] = []
        let now = Date()

        func request(for application: NSRunningApplication, scope: AXEnumerationRequest.Scope, maximumDepth: Int) -> AXEnumerationRequest {
            let bundleIdentifier = application.bundleIdentifier ?? ""
            return AXEnumerationRequest(processIdentifier: application.processIdentifier,
                                        applicationName: application.localizedName ?? bundleIdentifier,
                                        scope: scope, maximumDepth: maximumDepth,
                                        allowsValues: !valueBlockedBundleIdentifiers.contains(bundleIdentifier),
                                        isElectron: ElectronDetection.isElectron(application))
        }

        // A clean cache entry stands in for the walk (app windows only).
        func walk(_ request: AXEnumerationRequest) -> PlannedAXWalk {
            let walkStartGeneration = axWalkCache.generation(of: request.processIdentifier)
            if let cachedElements = axWalkCache.lookup(processIdentifier: request.processIdentifier, scope: request.scope,
                                                       windowStack: windowStack, at: now).elements {
                return PlannedAXWalk(request: request, windowStack: windowStack, liveWalk: nil, cachedElements: cachedElements,
                                     walkStartGeneration: walkStartGeneration)
            }
            return PlannedAXWalk(request: request, windowStack: windowStack, liveWalk: AXAppWalk(request: request, ax: ax, windowStack: windowStack),
                                 cachedElements: nil, walkStartGeneration: walkStartGeneration)
        }

        // "The app you're looking at": the frontmost app, plus the owner of the
        // topmost window on the cursor's screen when that's a different app
        // (on multi-display setups the frontmost app can be on another screen).
        var frontProcessIdentifiers: [pid_t] = []
        if let frontApplication = NSWorkspace.shared.frontmostApplication, frontApplication.processIdentifier != ownProcessIdentifier {
            frontProcessIdentifiers.append(frontApplication.processIdentifier)
        }
        let cursorCG = ScreenTopology.cg(fromAppKit: NSEvent.mouseLocation, flipH: ScreenTopology.mainDisplayHeight)
        if let cursorDisplay = windowStack.displays.first(where: { $0.boundsCG.contains(cursorCG) }),
           let topWindowOnCursorScreen = windowStack.windows.first(where: { $0.isApplicationWindowLayer && cursorDisplay.boundsCG.intersects($0.boundsCG) }),
           !frontProcessIdentifiers.contains(topWindowOnCursorScreen.processIdentifier) {
            frontProcessIdentifiers.append(topWindowOnCursorScreen.processIdentifier)
        }
        for frontProcessIdentifier in frontProcessIdentifiers {
            guard let frontApplication = NSRunningApplication(processIdentifier: frontProcessIdentifier) else { continue }
            walks.append(walk(request(for: frontApplication, scope: .frontApplication, maximumDepth: 40)))
        }
        // The menu bar belongs to the frontmost app.
        if let frontApplication = NSWorkspace.shared.frontmostApplication, frontApplication.processIdentifier != ownProcessIdentifier {
            walks.append(walk(request(for: frontApplication, scope: .menuBar, maximumDepth: 1)))
        }
        guard !frontApplicationOnly else { return walks }

        let otherProcessIdentifiers = Set(windowStack.windows.filter { $0.isApplicationWindowLayer }.map(\.processIdentifier))
            .subtracting(Set(frontProcessIdentifiers + [ownProcessIdentifier]))
        for otherProcessIdentifier in otherProcessIdentifiers {
            guard let otherApplication = NSRunningApplication(processIdentifier: otherProcessIdentifier) else { continue }
            walks.append(walk(request(for: otherApplication, scope: .otherApplication, maximumDepth: 6)))
        }
        if let dockApplication = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            walks.append(walk(request(for: dockApplication, scope: .dock, maximumDepth: 3)))
        }
        return walks
    }

    /// Front app walks get 120 ms, everything else 40 ms (from when they
    /// started); whatever each found by then is used.
    private func collectAXElements(from walks: [PlannedAXWalk]) -> [GroundingElement] {
        let startTime = DispatchTime.now()
        var elements: [GroundingElement] = []
        var walkStats: [String] = []
        for walk in walks {
            let budgetMilliseconds = walk.request.scope == .frontApplication ? 120 : 40
            let deadline = startTime + .milliseconds(budgetMilliseconds)
            let walkResult = walk.elements(waitingUntil: deadline)
            elements += walkResult.elements
            rememberFinishedWalk(walk, result: walkResult)
            let cachedNote = walk.cachedElements != nil ? " (cached)" : ""
            walkStats.append("\(walk.request.applicationName) \(walk.request.scope) \(walkResult.elements.count)\(cachedNote)\(walkResult.didFinish ? "" : " (deadline)")\(walkResult.error.map { " error \($0)" } ?? "")")
        }
        lastAXWalkStats = walkStats
        return elements
    }

    /// A finished live walk of app windows goes into the cache, and its app
    /// gets an observer (so the next turn can reuse it).
    private func rememberFinishedWalk(_ walk: PlannedAXWalk, result: (elements: [GroundingElement], didFinish: Bool, error: Error?)) {
        guard let liveWalk = walk.liveWalk, walk.request.scope == .frontApplication || walk.request.scope == .otherApplication else { return }
        let processIdentifier = walk.request.processIdentifier
        axObserverHub.track(processIdentifier: processIdentifier, windowNodes: liveWalk.windowNodesByWindowID)
        guard result.didFinish, result.error == nil else { return }
        axWalkCache.store(processIdentifier: processIdentifier, scope: walk.request.scope, elements: result.elements,
                          windowStack: walk.windowStack, walkStartGeneration: walk.walkStartGeneration, at: Date())
    }

    // MARK: - OCR coverage

    /// Trusted AX text frames per display (CG), for OCRCoveragePlanner.
    private func coveredRectsCGByDisplay(axElements: [GroundingElement], captures: [ScreenCapture], windowStack: WindowStack,
                                         trustedProcessIdentifiers: Set<pid_t>? = nil) -> [CGDirectDisplayID: [CGRect]] {
        let trusted = trustedProcessIdentifiers ?? alignmentLedger.trustedProcessIdentifiers(at: Date())
        guard !trusted.isEmpty else { return [:] }
        var coveredRectsByDisplay: [CGDirectDisplayID: [CGRect]] = [:]
        for capture in captures {
            coveredRectsByDisplay[capture.displayID] = OCRCoveragePlanner.coveringFramesCG(axElements: axElements, displayID: capture.displayID,
                                                                                         windowStack: windowStack, trustedProcessIdentifiers: trusted)
        }
        return coveredRectsByDisplay
    }

    /// Plans (tiles off AX coverage + blank) and runs OCR for one capture;
    /// `limitedToRegionsPx` clips the plan (warm path: changed strips).
    nonisolated private static func recognizeUncoveredLines(in capture: ScreenCapture, coveredRectsCG: [CGRect], grayImage: GrayImage?,
                                                            level: OCREngine.Level, limitedToRegionsPx: [CGRect]? = nil) async -> (lines: [OCRLine], plan: OCRCoveragePlanner.Plan) {
        let frame = capture.frame
        let coveredRectsPx = coveredRectsCG.map { OCRCoveragePlanner.nativePxRect(fromCG: $0, frame: frame) }
        let plan = OCRCoveragePlanner.plan(imageWidthPx: capture.nativeImage.width, imageHeightPx: capture.nativeImage.height,
                                           coveredRectsPx: coveredRectsPx, grayImage: grayImage)
        var regionsPx = plan.regionsPx
        if let limitedToRegionsPx {
            regionsPx = limitedToRegionsPx.flatMap { limit in
                regionsPx.map { $0.intersection(limit) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
            }
        }
        guard !regionsPx.isEmpty else { return ([], plan) }
        let lines = await OCREngine.recognizeLines(in: capture.nativeImage, frame: frame, regionsPx: regionsPx, level: level)
        return (lines, plan)
    }

    private static func coverageDescription(displayID: CGDirectDisplayID, plan: OCRCoveragePlanner.Plan, milliseconds: Double) -> String {
        let skippedPercent = Int((plan.skippedFraction * 100).rounded())
        let shape = plan.isFullImage ? "full" : "\(plan.regionsPx.count) regions"
        return "display \(displayID): \(skippedPercent)% tiles skipped, \(shape), \(Int(milliseconds.rounded())) ms"
    }

    /// AX frames that disagree with what OCR sees (median offset > 3 pt over
    /// up to 10 matching texts) can't be trusted: that app's AX is dropped.
    static func dropMisalignedAXApplications(axElements: [GroundingElement], ocrLines: [OCRLine]) -> (keptElements: [GroundingElement], droppedApplications: [String]) {
        guard !ocrLines.isEmpty else { return (axElements, []) }
        var droppedProcessIdentifiers = Set<pid_t>()
        var droppedApplications: [String] = []
        for (processIdentifier, appElements) in Dictionary(grouping: axElements, by: \.processIdentifier) {
            var offsets: [CGFloat] = []
            for staticText in appElements where staticText.role == .text && staticText.source == .accessibility {
                guard offsets.count < 10, let label = staticText.label, label.count >= 4 else { continue }
                let axCenter = staticText.visibleFrameCG.center
                if let matchingLine = ocrLines.first(where: { line in
                    hypot(line.frameCG.midX - axCenter.x, line.frameCG.midY - axCenter.y) < 60
                        && LabelSimilarity.similarity(line.text, label) >= 0.8
                }) {
                    offsets.append(hypot(matchingLine.frameCG.midX - axCenter.x, matchingLine.frameCG.midY - axCenter.y))
                }
            }
            guard offsets.count >= 3 else { continue }
            let medianOffset = offsets.sorted()[offsets.count / 2]
            if medianOffset > 3 {
                droppedProcessIdentifiers.insert(processIdentifier)
                droppedApplications.append("\(appElements.first?.applicationName ?? "pid \(processIdentifier)") (median \(String(format: "%.1f", medianOffset)) pt)")
            }
        }
        return (axElements.filter { !droppedProcessIdentifiers.contains($0.processIdentifier) }, droppedApplications)
    }

    // MARK: - Content

    private func makeGroundedTurn(from snapshot: Snapshot, cursorCG: CGPoint, isWarm: Bool, isBadged: Bool,
                                  pendingOCRTask: Task<[OCRLine], Never>?, preparationStart: Date, keyUpDate: Date) async -> GroundedTurn {
        let screenInputs = snapshot.screenCaptures.map { screenCapture in
            ScreenGroundingInput(
                frame: screenCapture.frame,
                isCursorScreen: screenCapture.isCursorScreen,
                axElements: snapshot.axElements.filter { $0.displayID == screenCapture.displayID },
                ocrLines: snapshot.ocrLinesByDisplay[screenCapture.displayID] ?? []
            )
        }
        let fusionStart = Date()
        var registry = GroundingFusion.buildRegistry(screens: screenInputs, cursorCG: cursorCG, windowStack: snapshot.windowStack)
        lastTurnStageMilliseconds["fusion"] = (Date().timeIntervalSince(fusionStart) * 1000).rounded()

        // Badges are drawn on the final model-size image, then JPEG-encoded
        // (all screens at once).
        let stageStart = Date()
        var badgedCaptures = snapshot.screenCaptures
        var renderJobs: [(captureIndex: Int, modelImage: CGImage, placements: [BadgeLayout.Placement], outlinedRects: [Int: CGRect], cursorPx: CGPoint?)] = []
        for (captureIndex, screenCapture) in snapshot.screenCaptures.enumerated() where isBadged {
            let frame = screenCapture.frame
            let screenEntryIDs = registry.orderedIDs.filter { registry[$0]?.displayID == screenCapture.displayID }
            let badgeCandidates = screenEntryIDs.compactMap { elementID -> BadgeLayout.Candidate? in
                guard let element = registry[elementID], !element.isBehind, element.isInteractive || element.isOCROnly else { return nil }
                return BadgeLayout.Candidate(elementID: elementID, rectPx: frame.modelPxRect(fromCG: element.visibleFrameCG))
            }
            let badgeLimit = screenCapture.isCursorScreen ? 80 : 30
            let allElementRectsPx = screenEntryIDs.compactMap { registry[$0].map { frame.modelPxRect(fromCG: $0.visibleFrameCG) } }
            let placements = BadgeLayout.place(candidates: Array(badgeCandidates.prefix(badgeLimit)), allElementRectsPx: allElementRectsPx,
                                               imageSize: frame.modelSize.cgSize)
            for placement in placements { registry.setBadged(placement.elementID, true) }
            let outlinedRects = Dictionary(uniqueKeysWithValues: placements.compactMap { placement in
                registry[placement.elementID].map { (placement.elementID, frame.modelPxRect(fromCG: $0.visibleFrameCG)) }
            })
            let cursorPx: CGPoint? = screenCapture.isCursorScreen ? frame.modelPx(fromCG: cursorCG) : nil
            renderJobs.append((captureIndex, screenCapture.modelImage, placements, outlinedRects, cursorPx))
        }
        let layoutMilliseconds = Date().timeIntervalSince(stageStart) * 1000
        let badgedJPEGs = await withTaskGroup(of: (Int, Data?).self) { taskGroup in
            for renderJob in renderJobs {
                taskGroup.addTask(priority: .userInitiated) {
                    guard let badgedImage = BadgeRenderer.render(onto: renderJob.modelImage, placements: renderJob.placements,
                                                                 outlinedRectsPx: renderJob.outlinedRects, cursorPx: renderJob.cursorPx) else { return (renderJob.captureIndex, nil) }
                    return (renderJob.captureIndex, try? encodeJPEG(badgedImage, quality: ScreenCaptureService.modelJPEGQuality))
                }
            }
            var results: [Int: Data] = [:]
            for await (captureIndex, jpegData) in taskGroup { if let jpegData { results[captureIndex] = jpegData } }
            return results
        }
        for (captureIndex, jpegData) in badgedJPEGs { badgedCaptures[captureIndex].modelJPEGData = jpegData }
        // A capture taken without its JPEG (warm refresh) whose badge render failed.
        for captureIndex in badgedCaptures.indices where badgedCaptures[captureIndex].modelJPEGData.isEmpty {
            if let plainJPEG = try? encodeJPEG(badgedCaptures[captureIndex].modelImage, quality: ScreenCaptureService.modelJPEGQuality) {
                badgedCaptures[captureIndex].modelJPEGData = plainJPEG
            }
        }
        lastTurnStageMilliseconds["badgeLayout"] = layoutMilliseconds.rounded()
        lastTurnStageMilliseconds["badgeRender"] = (Date().timeIntervalSince(stageStart) * 1000 - layoutMilliseconds).rounded()

        var contentBlocks: [ClaudeContentBlock] = []
        var elementListTexts: [String] = []
        for (captureIndex, screenCapture) in snapshot.screenCaptures.enumerated() {
            let listText = ElementListWriter.lines(header: screenCapture.header, frame: screenCapture.frame, registry: registry,
                                                   cursorCG: cursorCG, isCursorScreen: screenCapture.isCursorScreen).joined(separator: "\n")
            elementListTexts.append(listText)
            contentBlocks.append(.text(listText))
            contentBlocks.append(.jpegImage(badgedCaptures[captureIndex].modelJPEGData))
        }

        let droppedApplications = snapshot.droppedAXApplications
        return GroundedTurn(
            screenCaptures: badgedCaptures,
            registry: registry,
            windowStack: snapshot.windowStack,
            cursorCG: cursorCG,
            contentBlocks: contentBlocks,
            elementListTexts: elementListTexts,
            isWarm: isWarm,
            droppedAXApplications: droppedApplications,
            keyUpToReadyMilliseconds: Date().timeIntervalSince(keyUpDate) * 1000,
            isBadged: isBadged,
            pendingOCRTask: pendingOCRTask,
            blackFrameRetry: snapshot.blackFrameRetry
        )
    }
}

/// Live AX reads for the resolver.
struct AXGroundingLiveLookup: GroundingLiveLookup {
    let ax: AXQuerying

    func refreshedFrame(of element: GroundingElement) -> CGRect? {
        guard let axNode = element.axNode else { return element.visibleFrameCG }
        guard let currentFrame = ax.attributes(of: axNode)?.frameCG, currentFrame.width > 0, currentFrame.height > 0 else { return nil }
        // Keep the visible (clipped) part: the element may extend under a scroll edge.
        let clipped = currentFrame.intersection(element.visibleFrameCG.insetBy(dx: -40, dy: -40))
        return clipped.isNull || clipped.isEmpty ? currentFrame : clipped
    }

    func textRanges(of query: String, in element: GroundingElement) -> [(frameCG: CGRect, isFuzzy: Bool)] {
        guard let axNode = element.axNode, let fullText = searchableText(of: element) else { return [] }
        return textHits(of: query, in: fullText, axNode: axNode, element: element).map { ($0.frameCG, $0.isFuzzy) }
    }

    /// The hits classified against the live string they were found in, so
    /// "submit" inside "127.0.0.1:8793/submit_form.html" ranks as a hit
    /// inside a longer token, below a real "Submit" label.
    func textMatches(of query: String, in element: GroundingElement) -> [TextRangeMatch] {
        guard let axNode = element.axNode, let fullText = searchableText(of: element) else { return [] }
        let occurrences = TextMatchClassifier.occurrences(of: query, in: fullText)
        let worstQuality = occurrences.map(\.quality).max() ?? .token
        return textHits(of: query, in: fullText, axNode: axNode, element: element).map { hit in
            let occurrence = hit.occurrenceIndex < occurrences.count ? occurrences[hit.occurrenceIndex] : nil
            return TextRangeMatch(frameCG: hit.frameCG, isFuzzy: hit.isFuzzy, quality: occurrence?.quality ?? worstQuality,
                                  isCaseExact: occurrence?.isCaseExact ?? false)
        }
    }

    private func searchableText(of element: GroundingElement) -> String? {
        guard let axNode = element.axNode, [.text, .textArea, .textField, .cell].contains(element.role),
              let fullText = ax.stringAttribute(kAXValueAttribute, of: axNode) ?? element.label, !fullText.isEmpty else { return nil }
        return fullText
    }

    /// Hits in order; `occurrenceIndex` is the hit's position among the
    /// exact occurrences (left to right), 0 for the fuzzy one.
    private func textHits(of query: String, in fullText: String, axNode: AXNodeReference,
                          element: GroundingElement) -> [(frameCG: CGRect, isFuzzy: Bool, occurrenceIndex: Int)] {
        var results: [(frameCG: CGRect, isFuzzy: Bool, occurrenceIndex: Int)] = []
        // Exact (case-insensitive) on the real string, so UTF-16 ranges are right.
        var searchRange = fullText.startIndex..<fullText.endIndex
        var occurrenceIndex = 0
        while results.count < 20, let foundRange = fullText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let utf16Range = NSRange(foundRange, in: fullText)
            if let bounds = ax.boundsForRange(utf16Range, of: axNode) {
                results.append((bounds, false, occurrenceIndex))
            } else if LabelSimilarity.similarity(fullText, query) >= 0.99 {
                results.append((element.visibleFrameCG, false, occurrenceIndex))
            }
            occurrenceIndex += 1
            searchRange = foundRange.upperBound..<fullText.endIndex
        }
        if results.isEmpty, let fuzzyMatch = LabelSimilarity.findOccurrences(of: query, in: fullText).first(where: \.isFuzzy),
           LabelSimilarity.normalize(fullText).count == fullText.count {
            let utf16Range = NSRange(location: fuzzyMatch.range.lowerBound, length: fuzzyMatch.range.count)
            if let bounds = ax.boundsForRange(utf16Range, of: axNode) {
                results.append((bounds, true, 0))
            }
        }
        return results
    }
}

/// CGWindowList → WindowStack (front to back), once per question.
enum WindowListReader {
    static func read(displays: [DisplayInfo]) -> WindowStack {
        let windowInfos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let windows = windowInfos.compactMap { windowInfo -> WindowInfo? in
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let processIdentifier = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let boundsCG = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
            return WindowInfo(windowID: windowID, processIdentifier: processIdentifier, layer: layer, boundsCG: boundsCG,
                              alpha: windowInfo[kCGWindowAlpha as String] as? Double ?? 1,
                              ownerName: windowInfo[kCGWindowOwnerName as String] as? String ?? "",
                              title: windowInfo[kCGWindowName as String] as? String)
        }
        return WindowStack(windows: windows, ownProcessIdentifier: getpid(), displays: displays)
    }
}
