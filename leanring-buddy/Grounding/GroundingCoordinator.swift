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
    }

    let ax: AXQuerying = SystemAXQuerying()
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
        let pendingOCRTask = Task<[OCRLine], Never> {
            await withTaskGroup(of: [OCRLine].self) { taskGroup in
                for screenCapture in capturesForOCR {
                    taskGroup.addTask { await OCREngine.recognizeLines(in: screenCapture.nativeImage, frame: screenCapture.frame) }
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
        let axWalks = startAXWalks(windowStack: windowStack)

        let screenCaptures = try await ScreenCaptureService.captureAllScreens(options: captureOptions)

        // OCR + grey images start right away; the AX walks run meanwhile.
        let analysisTask: Task<[(CGDirectDisplayID, [OCRLine], GrayImage?, Double)], Never>? = awaitsOCR ? Task {
            await withTaskGroup(of: (CGDirectDisplayID, [OCRLine], GrayImage?, Double).self) { taskGroup in
                for screenCapture in screenCaptures {
                    let isCursorScreen = screenCapture.isCursorScreen
                    let displayID = screenCapture.displayID
                    taskGroup.addTask {
                        let ocrStart = Date()
                        // Accurate where the user is looking, fast elsewhere; a
                        // missed text target triggers a retry pass later.
                        let ocrLevel: OCREngine.Level = isCursorScreen ? .accurate : .fast
                        let ocrLines = await OCREngine.recognizeLines(in: screenCapture.nativeImage, frame: screenCapture.frame, level: ocrLevel)
                        let ocrMilliseconds = Date().timeIntervalSince(ocrStart) * 1000
                        return (displayID, ocrLines, GrayImage(cgImage: screenCapture.nativeImage), ocrMilliseconds)
                    }
                }
                var results: [(CGDirectDisplayID, [OCRLine], GrayImage?, Double)] = []
                for await result in taskGroup { results.append(result) }
                return results
            }
        } : nil
        let axElements = collectAXElements(from: axWalks)

        var ocrLinesByDisplay: [CGDirectDisplayID: [OCRLine]] = [:]
        var grayImagesByDisplay: [CGDirectDisplayID: GrayImage] = [:]
        if let analysisTask {
            for (displayID, ocrLines, grayImage, ocrMilliseconds) in await analysisTask.value {
                ocrLinesByDisplay[displayID] = ocrLines
                grayImagesByDisplay[displayID] = grayImage
                lastOCRMillisecondsByDisplay[displayID] = ocrMilliseconds
            }
        }

        let cursorDisplayID = screenCaptures.first(where: \.isCursorScreen)?.displayID ?? displays.first?.displayID ?? 0
        let dropped = Self.dropMisalignedAXApplications(axElements: axElements, ocrLines: ocrLinesByDisplay.values.flatMap { $0 })
        return Snapshot(screenCaptures: screenCaptures, axElements: dropped.keptElements, ocrLinesByDisplay: ocrLinesByDisplay,
                        grayImagesByDisplay: grayImagesByDisplay, windowStack: windowStack, cursorDisplayID: cursorDisplayID,
                        readyDate: Date(), droppedAXApplications: dropped.droppedApplications)
    }

    /// Warm path: new capture of the cursor screen only; re-OCR changed strips
    /// (40 ms budget) and re-walk the front app in parallel.
    private func refreshCursorScreen(of snapshot: Snapshot, cursorDisplay: DisplayInfo, encodesJPEG: Bool) async throws -> Snapshot {
        var refreshedSnapshot = snapshot
        let windowStack = WindowListReader.read(displays: ScreenTopology.current())
        refreshedSnapshot.windowStack = windowStack
        let frontApplicationWalks = startAXWalks(windowStack: windowStack, frontApplicationOnly: true)
        let walksStart = DispatchTime.now()

        guard let previousCapture = snapshot.screenCaptures.first(where: { $0.displayID == cursorDisplay.displayID }) else { return snapshot }
        let mainBoundsCG = ScreenTopology.current().first(where: \.isMain)?.boundsCG ?? cursorDisplay.boundsCG
        let newCapture = try await ScreenCaptureService.captureScreen(
            display: cursorDisplay,
            screenNumber: previousCapture.screenNumber,
            isCursorScreen: true,
            positionDescription: cursorDisplay.positionDescription(relativeTo: mainBoundsCG),
            options: captureOptions,
            encodesJPEG: encodesJPEG
        )
        refreshedSnapshot.screenCaptures = snapshot.screenCaptures.map { $0.displayID == cursorDisplay.displayID ? newCapture : $0 }
        lastTurnStageMilliseconds["capture"] = (Double(DispatchTime.now().uptimeNanoseconds - walksStart.uptimeNanoseconds) / 1e6).rounded()

        // Front app AX: fresh when its walk finishes within 60 ms of starting
        // (ran in parallel with the capture); otherwise the prewarm's copy.
        var freshFrontElements: [GroundingElement] = []
        var refreshedProcessIdentifiers = Set<pid_t>()
        for walk in frontApplicationWalks {
            let walkResult = walk.elements(waitingUntil: walksStart + .milliseconds(60))
            if walkResult.didFinish {
                freshFrontElements += walkResult.elements
                refreshedProcessIdentifiers.insert(walk.request.processIdentifier)
            } else {
                walk.cancel()
            }
        }
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
                let reOCRTask = Task<[OCRLine], Never> {
                    var newLines: [OCRLine] = []
                    for stripPx in changedStripsPx {
                        newLines += await OCREngine.recognizeLines(in: newCapture.nativeImage, frame: newCapture.frame, regionPx: stripPx)
                    }
                    return newLines
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

    // MARK: - AX

    private func startAXWalks(windowStack: WindowStack, frontApplicationOnly: Bool = false) -> [AXAppWalk] {
        guard ax.isProcessTrusted() else { return [] }
        let ownProcessIdentifier = getpid()
        let valueBlockedBundleIdentifiers = ClickySettings.valueBlockedBundleIDs
        var walks: [AXAppWalk] = []

        func request(for application: NSRunningApplication, scope: AXEnumerationRequest.Scope, maximumDepth: Int) -> AXEnumerationRequest {
            let bundleIdentifier = application.bundleIdentifier ?? ""
            let isElectron = application.bundleURL.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
            } ?? false
            return AXEnumerationRequest(processIdentifier: application.processIdentifier,
                                        applicationName: application.localizedName ?? bundleIdentifier,
                                        scope: scope, maximumDepth: maximumDepth,
                                        allowsValues: !valueBlockedBundleIdentifiers.contains(bundleIdentifier),
                                        isElectron: isElectron)
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
            walks.append(AXAppWalk(request: request(for: frontApplication, scope: .frontApplication, maximumDepth: 40), ax: ax, windowStack: windowStack))
        }
        // The menu bar belongs to the frontmost app.
        if let frontApplication = NSWorkspace.shared.frontmostApplication, frontApplication.processIdentifier != ownProcessIdentifier {
            walks.append(AXAppWalk(request: request(for: frontApplication, scope: .menuBar, maximumDepth: 1), ax: ax, windowStack: windowStack))
        }
        guard !frontApplicationOnly else { return walks }

        let otherProcessIdentifiers = Set(windowStack.windows.filter { $0.isApplicationWindowLayer }.map(\.processIdentifier))
            .subtracting(Set(frontProcessIdentifiers + [ownProcessIdentifier]))
        for otherProcessIdentifier in otherProcessIdentifiers {
            guard let otherApplication = NSRunningApplication(processIdentifier: otherProcessIdentifier) else { continue }
            walks.append(AXAppWalk(request: request(for: otherApplication, scope: .otherApplication, maximumDepth: 6), ax: ax, windowStack: windowStack))
        }
        if let dockApplication = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            walks.append(AXAppWalk(request: request(for: dockApplication, scope: .dock, maximumDepth: 3), ax: ax, windowStack: windowStack))
        }
        return walks
    }

    /// Front app walks get 120 ms, everything else 40 ms (from when they
    /// started); whatever each found by then is used.
    private func collectAXElements(from walks: [AXAppWalk]) -> [GroundingElement] {
        let startTime = DispatchTime.now()
        var elements: [GroundingElement] = []
        var walkStats: [String] = []
        for walk in walks {
            let budgetMilliseconds = walk.request.scope == .frontApplication ? 120 : 40
            let deadline = startTime + .milliseconds(budgetMilliseconds)
            let walkResult = walk.elements(waitingUntil: deadline)
            elements += walkResult.elements
            walkStats.append("\(walk.request.applicationName) \(walk.request.scope) \(walkResult.elements.count)\(walkResult.didFinish ? "" : " (deadline)")\(walkResult.error.map { " error \($0)" } ?? "")")
        }
        lastAXWalkStats = walkStats
        return elements
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
            pendingOCRTask: pendingOCRTask
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
        guard let axNode = element.axNode, [.text, .textArea, .textField, .cell].contains(element.role),
              let fullText = ax.stringAttribute(kAXValueAttribute, of: axNode) ?? element.label, !fullText.isEmpty else { return [] }
        var results: [(CGRect, Bool)] = []
        // Exact (case-insensitive) on the real string, so UTF-16 ranges are right.
        var searchRange = fullText.startIndex..<fullText.endIndex
        while results.count < 20, let foundRange = fullText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let utf16Range = NSRange(foundRange, in: fullText)
            if let bounds = ax.boundsForRange(utf16Range, of: axNode) {
                results.append((bounds, false))
            } else if LabelSimilarity.similarity(fullText, query) >= 0.99 {
                results.append((element.visibleFrameCG, false))
            }
            searchRange = foundRange.upperBound..<fullText.endIndex
        }
        if results.isEmpty, let fuzzyMatch = LabelSimilarity.findOccurrences(of: query, in: fullText).first(where: \.isFuzzy),
           LabelSimilarity.normalize(fullText).count == fullText.count {
            let utf16Range = NSRange(location: fuzzyMatch.range.lowerBound, length: fuzzyMatch.range.count)
            if let bounds = ax.boundsForRange(utf16Range, of: axNode) {
                results.append((bounds, true))
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
