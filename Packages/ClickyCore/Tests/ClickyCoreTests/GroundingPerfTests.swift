import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// P6.8 grounding perf: AX walk cache, OCR coverage tiles, enhanced-UI
// matching, latency alarm.

private let perfDisplay = DisplayInfo(displayID: 1, localizedName: "Main", boundsCG: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                      visibleCG: CGRect(x: 0, y: 25, width: 1600, height: 975),
                                      frameAppKit: CGRect(x: 0, y: 0, width: 1600, height: 1000), isMain: true)

private func window(_ windowID: CGWindowID, pid: pid_t, bounds: CGRect) -> WindowInfo {
    WindowInfo(windowID: windowID, processIdentifier: pid, layer: 0, boundsCG: bounds, alpha: 1, ownerName: "App\(pid)", title: "W\(windowID)")
}

private func stack(_ windows: [WindowInfo]) -> WindowStack {
    WindowStack(windows: windows, ownProcessIdentifier: 1, displays: [perfDisplay])
}

private func element(_ label: String, pid: pid_t, windowID: CGWindowID, frame: CGRect, role: GroundingRole = .button) -> GroundingElement {
    GroundingElement(role: role, label: label, frameCG: frame, processIdentifier: pid, windowID: windowID, displayID: 1,
                     isInteractive: role != .text, source: .accessibility)
}

// MARK: - AX cache

private let mailWindowA = window(10, pid: 42, bounds: CGRect(x: 100, y: 100, width: 600, height: 400))
private let mailWindowB = window(11, pid: 42, bounds: CGRect(x: 800, y: 100, width: 500, height: 400))

private func observedCacheWithMail(at date: Date) -> AXWalkCache {
    let cache = AXWalkCache(maximumAge: 15)
    cache.apply(.observerInstalled(42))
    cache.store(processIdentifier: 42, scope: .frontApplication,
                elements: [element("Send", pid: 42, windowID: 10, frame: CGRect(x: 120, y: 120, width: 60, height: 24)),
                           element("Reply", pid: 42, windowID: 11, frame: CGRect(x: 820, y: 120, width: 60, height: 24))],
                windowStack: stack([mailWindowA, mailWindowB]), walkStartGeneration: cache.generation(of: 42), at: date)
    return cache
}

@Test func axCacheHitsWhenCleanAndUnmoved() {
    let start = Date()
    let cache = observedCacheWithMail(at: start)
    let lookup = cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA, mailWindowB]),
                              at: start.addingTimeInterval(2))
    #expect(lookup.elements?.map(\.label) == ["Send", "Reply"])
}

@Test func axCacheRecomputesZOrderAndFrontWindowOnHit() {
    let start = Date()
    let cache = observedCacheWithMail(at: start)
    // Window B came forward (focus moves are separate events; here only z order changed).
    let lookup = cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowB, mailWindowA]), at: start)
    let elements = lookup.elements ?? []
    #expect(elements.first { $0.label == "Reply" }?.windowZIndex == 0)
    #expect(elements.first { $0.label == "Reply" }?.isInFrontWindow == true)
    #expect(elements.first { $0.label == "Send" }?.windowZIndex == 1)
    #expect(elements.first { $0.label == "Send" }?.isInFrontWindow == false)
}

@Test func axCacheMissesWhenNotObservedOrObserverFailed() {
    let start = Date()
    let unobservedCache = AXWalkCache()
    unobservedCache.store(processIdentifier: 42, scope: .frontApplication, elements: [], windowStack: stack([mailWindowA]), walkStartGeneration: unobservedCache.generation(of: 42), at: start)
    #expect(unobservedCache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA]), at: start) == .miss("not observed"))

    let failedCache = observedCacheWithMail(at: start)
    failedCache.apply(.observerFailed(42))
    #expect(failedCache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA, mailWindowB]), at: start) == .miss("not observed"))
    #expect(failedCache.hasObserverFailed(processIdentifier: 42))
}

@Test func axCacheEntriesStoredBeforeObserverAreDirty() {
    let start = Date()
    let cache = AXWalkCache()
    cache.apply(.observerInstalled(42))
    cache.store(processIdentifier: 42, scope: .frontApplication, elements: [], windowStack: stack([mailWindowA]), walkStartGeneration: cache.generation(of: 42), at: start)
    // A re-install (app relaunched observer) can't vouch for what came before.
    cache.apply(.observerInstalled(42))
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA]), at: start) == .miss("dirty"))
}

@Test func axCacheWindowEventDirtiesOnlyThatWindowButTheAppMisses() {
    let start = Date()
    let cache = observedCacheWithMail(at: start)
    cache.apply(.windowChanged(42, 11))
    #expect(cache.hasCleanEntries(processIdentifier: 42))
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA, mailWindowB]), at: start) == .miss("dirty"))
    // Window A alone on screen (B closed): A's entry is still clean.
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA]), at: start).elements?.map(\.label) == ["Send"])
}

@Test func axCacheApplicationEventDirtiesEveryWindow() {
    let start = Date()
    let cache = observedCacheWithMail(at: start)
    cache.apply(.applicationChanged(42))
    #expect(!cache.hasCleanEntries(processIdentifier: 42))
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA]), at: start) == .miss("dirty"))
    // A fresh walk cleans it again.
    cache.store(processIdentifier: 42, scope: .frontApplication, elements: [], windowStack: stack([mailWindowA]), walkStartGeneration: cache.generation(of: 42), at: start)
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA]), at: start) == .hit([]))
}

@Test func axCacheMissesOnMoveNewWindowScopeAndAge() {
    let start = Date()
    let cache = observedCacheWithMail(at: start)
    let movedWindowA = window(10, pid: 42, bounds: CGRect(x: 140, y: 100, width: 600, height: 400))
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([movedWindowA, mailWindowB]), at: start) == .miss("moved"))
    let newWindow = window(12, pid: 42, bounds: CGRect(x: 0, y: 600, width: 300, height: 300))
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([newWindow, mailWindowA, mailWindowB]), at: start) == .miss("new window"))
    #expect(cache.lookup(processIdentifier: 42, scope: .otherApplication, windowStack: stack([mailWindowA, mailWindowB]), at: start) == .miss("scope"))
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA, mailWindowB]),
                         at: start.addingTimeInterval(16)) == .miss("expired"))
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([]), at: start) == .miss("no windows"))
}

@Test func axCacheEvictsOnTerminate() {
    let start = Date()
    let cache = observedCacheWithMail(at: start)
    #expect(cache.entryCount == 2)
    cache.apply(.applicationTerminated(42))
    #expect(cache.entryCount == 0)
    #expect(!cache.isObserved(processIdentifier: 42))
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA, mailWindowB]), at: start) == .miss("not observed"))
}

@Test func axCacheDropsAWalkThatRacedAnEvent() {
    let start = Date()
    let cache = observedCacheWithMail(at: start)
    let generationAtWalkStart = cache.generation(of: 42)
    cache.apply(.windowChanged(42, 10)) // arrives while the walk runs
    cache.store(processIdentifier: 42, scope: .frontApplication, elements: [], windowStack: stack([mailWindowA]),
                walkStartGeneration: generationAtWalkStart, at: start)
    #expect(cache.entryCount == 0)
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA]), at: start) == .miss("new window"))
}

@Test func axCacheIgnoresMenuBarAndDockWalks() {
    let cache = AXWalkCache()
    cache.apply(.observerInstalled(42))
    cache.store(processIdentifier: 42, scope: .menuBar, elements: [], windowStack: stack([mailWindowA]), walkStartGeneration: cache.generation(of: 42), at: Date())
    #expect(cache.entryCount == 0)
}

/// Observers modelled as an event stream: only the last clean store counts.
@Test func axCacheReplaysAnObserverEventSequence() {
    let start = Date()
    let cache = AXWalkCache()
    let events: [AXWalkCache.Event] = [.observerInstalled(42), .observerInstalled(7)]
    events.forEach(cache.apply)
    cache.store(processIdentifier: 42, scope: .frontApplication, elements: [], windowStack: stack([mailWindowA]), walkStartGeneration: cache.generation(of: 42), at: start)
    let otherWindow = window(20, pid: 7, bounds: CGRect(x: 0, y: 600, width: 300, height: 300))
    cache.store(processIdentifier: 7, scope: .otherApplication, elements: [], windowStack: stack([otherWindow]), walkStartGeneration: cache.generation(of: 7), at: start)
    [.windowChanged(7, 20), .windowChanged(42, 999)].forEach(cache.apply)
    #expect(cache.lookup(processIdentifier: 42, scope: .frontApplication, windowStack: stack([mailWindowA]), at: start) == .hit([]))
    #expect(cache.lookup(processIdentifier: 7, scope: .otherApplication, windowStack: stack([otherWindow]), at: start) == .miss("dirty"))
}

@Test func axWalkPublishesWindowNodes() throws {
    let app = MockNode(role: "AXApplication", title: "Mail", pid: 42)
    let windowNode = MockNode(role: "AXWindow", title: "W10", frame: mailWindowA.boundsCG, children: [])
    app.add(windowNode)
    var windowNodes: [CGWindowID: AXNodeReference] = [:]
    try AXEnumerator.walk(request: AXEnumerationRequest(processIdentifier: 42, applicationName: "Mail", scope: .frontApplication,
                                                        maximumDepth: 4, allowsValues: true),
                          ax: MockAXQuerying(apps: [app]), windowStack: stack([mailWindowA]),
                          shouldStop: { false }, publish: { _ in },
                          publishWindow: { windowNodes[$0] = $1 })
    #expect(windowNodes[10]?.underlyingObject === windowNode)
}

// MARK: - OCR coverage tiles

private func whiteGray(widthPx: Int, heightPx: Int) -> [UInt8] {
    [UInt8](repeating: 255, count: (widthPx / 8) * (heightPx / 8))
}

/// Draws dark "text" into a grey image built at 8x downsampling.
private func drawInk(_ pixels: inout [UInt8], grayWidth: Int, nativeRect: CGRect) {
    for grayY in Int(nativeRect.minY) / 8..<Int(nativeRect.maxY) / 8 {
        for grayX in Int(nativeRect.minX) / 8..<Int(nativeRect.maxX) / 8 where (grayX + grayY) % 2 == 0 {
            pixels[grayY * grayWidth + grayX] = 20
        }
    }
}

@Test func coverageSkipsTilesUnderAXText() {
    // 1024 x 512 native: 4 x 2 tiles, ink everywhere, AX text over all of it.
    var pixels = whiteGray(widthPx: 1024, heightPx: 512)
    drawInk(&pixels, grayWidth: 128, nativeRect: CGRect(x: 0, y: 0, width: 1024, height: 512))
    let gray = GrayImage(width: 128, height: 64, pixels: pixels, nativePixelsPerPixel: 8)
    let plan = OCRCoveragePlanner.plan(imageWidthPx: 1024, imageHeightPx: 512, coveredRectsPx: [CGRect(x: 0, y: 0, width: 1024, height: 512)], grayImage: gray)
    #expect(plan.regionsPx.isEmpty)
    #expect(plan.skippedTileCount == 8)
}

@Test func coverageSkipsTileLessThanTenPercentUncovered() {
    var pixels = whiteGray(widthPx: 256, heightPx: 256)
    drawInk(&pixels, grayWidth: 32, nativeRect: CGRect(x: 0, y: 0, width: 256, height: 256))
    let gray = GrayImage(width: 32, height: 32, pixels: pixels, nativePixelsPerPixel: 8)
    // 240 of 256 rows covered → 6.25% uncovered (ink there too): skipped.
    let mostlyCovered = OCRCoveragePlanner.plan(imageWidthPx: 256, imageHeightPx: 256, coveredRectsPx: [CGRect(x: 0, y: 0, width: 256, height: 240)], grayImage: gray)
    #expect(mostlyCovered.regionsPx.isEmpty)
    // 200 rows covered → ~22% uncovered with ink: OCRed (the tile, padded).
    let partlyCovered = OCRCoveragePlanner.plan(imageWidthPx: 256, imageHeightPx: 256, coveredRectsPx: [CGRect(x: 0, y: 0, width: 256, height: 200)], grayImage: gray)
    #expect(partlyCovered.regionsPx == [CGRect(x: 0, y: 0, width: 256, height: 256)])
}

@Test func coverageSkipsBlankUncoveredTiles() {
    // Nothing covered, but only one tile has ink.
    var pixels = whiteGray(widthPx: 1024, heightPx: 512)
    drawInk(&pixels, grayWidth: 128, nativeRect: CGRect(x: 600, y: 300, width: 120, height: 40))
    let gray = GrayImage(width: 128, height: 64, pixels: pixels, nativePixelsPerPixel: 8)
    let plan = OCRCoveragePlanner.plan(imageWidthPx: 1024, imageHeightPx: 512, coveredRectsPx: [], grayImage: gray)
    #expect(plan.regionsPx == [CGRect(x: 512 - 24, y: 256 - 24, width: 256 + 48, height: 256 + 24)])
    #expect(plan.skippedTileCount == 7)
}

@Test func coverageKeepsCanvasTextNextToAXText() {
    // Fixture-like: AX text on the left half; a canvas with drawn text (no
    // AX) on the right half must still be OCRed.
    var pixels = whiteGray(widthPx: 1024, heightPx: 512)
    drawInk(&pixels, grayWidth: 128, nativeRect: CGRect(x: 40, y: 40, width: 400, height: 400))
    drawInk(&pixels, grayWidth: 128, nativeRect: CGRect(x: 560, y: 40, width: 300, height: 32))
    drawInk(&pixels, grayWidth: 128, nativeRect: CGRect(x: 560, y: 120, width: 200, height: 32))
    drawInk(&pixels, grayWidth: 128, nativeRect: CGRect(x: 560, y: 300, width: 150, height: 24))
    let gray = GrayImage(width: 128, height: 64, pixels: pixels, nativePixelsPerPixel: 8)
    let plan = OCRCoveragePlanner.plan(imageWidthPx: 1024, imageHeightPx: 512, coveredRectsPx: [CGRect(x: 0, y: 0, width: 512, height: 512)], grayImage: gray)
    #expect(!plan.isFullImage)
    #expect(plan.regionsPx.count == 1)
    let region = plan.regionsPx[0]
    for canvasLine in [CGRect(x: 560, y: 40, width: 300, height: 32), CGRect(x: 560, y: 120, width: 200, height: 32), CGRect(x: 560, y: 300, width: 150, height: 24)] {
        #expect(region.contains(canvasLine))
    }
    #expect(region.minX >= 512 - 24)
}

@Test func coverageWithoutGrayTreatsUncoveredAsInk() {
    let plan = OCRCoveragePlanner.plan(imageWidthPx: 1024, imageHeightPx: 512, coveredRectsPx: [CGRect(x: 0, y: 0, width: 768, height: 512)], grayImage: nil)
    #expect(plan.regionsPx == [CGRect(x: 768 - 24, y: 0, width: 256 + 24, height: 512)])
    // Nothing known at all: one full pass.
    let unknownPlan = OCRCoveragePlanner.plan(imageWidthPx: 1024, imageHeightPx: 512, coveredRectsPx: [], grayImage: nil)
    #expect(unknownPlan.isFullImage && unknownPlan.regionsPx == [CGRect(x: 0, y: 0, width: 1024, height: 512)])
}

@Test func coverageFallsBackToFullImageWhenMostNeedsReading() {
    let plan = OCRCoveragePlanner.plan(imageWidthPx: 1024, imageHeightPx: 512, coveredRectsPx: [CGRect(x: 0, y: 0, width: 200, height: 200)], grayImage: nil)
    #expect(plan.isFullImage)
    #expect(plan.regionsPx == [CGRect(x: 0, y: 0, width: 1024, height: 512)])
}

@Test func tileBoundingBoxesMergeConnectedAndOverlapping() {
    // 4 x 3 grid: an L-shape (connected) and a diagonal neighbour → one box;
    // a far tile → its own box.
    let needs: [Bool] = [
        true, false, false, false,
        true, true, false, false,
        false, false, true, false
    ]
    let boxes = OCRCoveragePlanner.mergedBoundingBoxes(of: needs, columns: 4, rows: 3)
    #expect(boxes == [CGRect(x: 0, y: 0, width: 3, height: 3)])

    let separate: [Bool] = [
        true, false, false, true,
        false, false, false, false,
        false, false, false, false
    ]
    #expect(Set(OCRCoveragePlanner.mergedBoundingBoxes(of: separate, columns: 4, rows: 3).map { "\($0)" })
            == Set([CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 3, y: 0, width: 1, height: 1)].map { "\($0)" }))
}

@Test func regionMergeCapsTheRegionCount() {
    let rects = (0..<9).map { CGRect(x: $0 * 300, y: 0, width: 100, height: 100) }
    let merged = OCRCoveragePlanner.mergeDownTo(6, rects)
    #expect(merged.count == 6)
    #expect(merged.allSatisfy { $0.height == 100 })
    for rect in rects { #expect(merged.contains { $0.contains(rect) }) }
}

@Test func coveringFramesUseOnlyTrustedTextRoles() {
    let windowStack = stack([window(10, pid: 42, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))])
    let elements = [
        element("Hello", pid: 42, windowID: 10, frame: CGRect(x: 10, y: 10, width: 100, height: 20), role: .text),
        element("Save", pid: 42, windowID: 10, frame: CGRect(x: 10, y: 40, width: 60, height: 24), role: .button),
        element("Other", pid: 99, windowID: 10, frame: CGRect(x: 10, y: 70, width: 100, height: 20), role: .text),
        GroundingElement(role: .textArea, label: nil, frameCG: CGRect(x: 200, y: 10, width: 300, height: 300), processIdentifier: 42,
                         windowID: 10, displayID: 1, isInteractive: true, source: .accessibility)
    ]
    let frames = OCRCoveragePlanner.coveringFramesCG(axElements: elements, displayID: 1, windowStack: windowStack, trustedProcessIdentifiers: [42])
    #expect(frames == [CGRect(x: 10, y: 10, width: 100, height: 20), CGRect(x: 200, y: 10, width: 300, height: 300)])
}

@Test func regionBandsKeepTheRegionXRange() {
    let bands = OCRBandPlanner.regionBands(regionPx: CGRect(x: 488, y: 232, width: 304, height: 280))
    #expect(bands.count == 1)
    #expect(bands[0].minX == 488 && bands[0].width == 304)
    #expect(bands[0].minY == 232 && bands[0].maxY == 512)
}

@Test func alignmentLedgerTrustsOnlyRecentVerifiedApps() {
    let start = Date()
    var ledger = AXAlignmentLedger(maximumAge: 600)
    ledger.recordVerified([42, 7], at: start)
    ledger.recordMisaligned(7)
    #expect(ledger.trustedProcessIdentifiers(at: start.addingTimeInterval(10)) == [42])
    #expect(ledger.trustedProcessIdentifiers(at: start.addingTimeInterval(601)).isEmpty)
}

// MARK: - Enhanced UI

@Test func enhancedUIMatchesListedBundlesAndElectron() {
    let configured = Set(EnhancedUserInterfacePolicy.defaultBundleIdentifiers)
    #expect(EnhancedUserInterfacePolicy.matches(bundleIdentifier: "com.google.Chrome", isElectron: false, configuredBundleIdentifiers: configured))
    #expect(EnhancedUserInterfacePolicy.matches(bundleIdentifier: "company.thebrowser.Browser", isElectron: false, configuredBundleIdentifiers: configured))
    // Spotify (Chromium, not Electron) has to be listed by name for its playlists to be seen.
    #expect(EnhancedUserInterfacePolicy.matches(bundleIdentifier: "com.spotify.client", isElectron: false, configuredBundleIdentifiers: configured))
    #expect(!EnhancedUserInterfacePolicy.matches(bundleIdentifier: "com.apple.Safari", isElectron: false, configuredBundleIdentifiers: configured))
    #expect(!EnhancedUserInterfacePolicy.matches(bundleIdentifier: nil, isElectron: false, configuredBundleIdentifiers: configured))
    #expect(EnhancedUserInterfacePolicy.matches(bundleIdentifier: "com.hnc.Discord", isElectron: true, configuredBundleIdentifiers: configured))
    // A custom list without the token: Electron apps aren't matched.
    #expect(!EnhancedUserInterfacePolicy.matches(bundleIdentifier: "com.hnc.Discord", isElectron: true, configuredBundleIdentifiers: ["com.google.Chrome"]))
}

@Test func enhancedUITransitionsFollowTheFrontmostApp() {
    let configured: Set<String> = ["com.google.Chrome", EnhancedUserInterfacePolicy.electronToken]
    let chrome = EnhancedUserInterfacePolicy.ActivatedApplication(processIdentifier: 500, bundleIdentifier: "com.google.Chrome", isElectron: false)
    let finder = EnhancedUserInterfacePolicy.ActivatedApplication(processIdentifier: 600, bundleIdentifier: "com.apple.finder", isElectron: false)
    let slack = EnhancedUserInterfacePolicy.ActivatedApplication(processIdentifier: 700, bundleIdentifier: "com.tinyspeck.slackmacgap", isElectron: true)
    let clicky = EnhancedUserInterfacePolicy.ActivatedApplication(processIdentifier: 1, bundleIdentifier: "com.clicky", isElectron: false)

    func step(_ current: pid_t?, _ activated: EnhancedUserInterfacePolicy.ActivatedApplication) -> EnhancedUserInterfacePolicy.Transition {
        EnhancedUserInterfacePolicy.transition(currentlyEnhancedProcessIdentifier: current, activated: activated, ownProcessIdentifier: 1,
                                               configuredBundleIdentifiers: configured)
    }
    #expect(step(nil, chrome) == .init(disableProcessIdentifier: nil, enableProcessIdentifier: 500, enhancedProcessIdentifierAfter: 500))
    #expect(step(500, clicky) == .init(disableProcessIdentifier: nil, enableProcessIdentifier: nil, enhancedProcessIdentifierAfter: 500))
    #expect(step(500, chrome) == .init(disableProcessIdentifier: nil, enableProcessIdentifier: nil, enhancedProcessIdentifierAfter: 500))
    #expect(step(500, finder) == .init(disableProcessIdentifier: 500, enableProcessIdentifier: nil, enhancedProcessIdentifierAfter: nil))
    #expect(step(500, slack) == .init(disableProcessIdentifier: 500, enableProcessIdentifier: 700, enhancedProcessIdentifierAfter: 700))
    #expect(step(nil, finder) == .init(disableProcessIdentifier: nil, enableProcessIdentifier: nil, enhancedProcessIdentifierAfter: nil))
}

// MARK: - Latency alarm

@Test func latencyPercentileIsNearestRank() {
    let samples = (1...20).map(Double.init)
    #expect(GroundingLatencyAlarm.percentile(95, of: samples) == 19)
    #expect(GroundingLatencyAlarm.percentile(50, of: samples) == 10)
    #expect(GroundingLatencyAlarm.percentile(95, of: [7]) == 7)
    #expect(GroundingLatencyAlarm.percentile(95, of: []) == nil)
}

@Test func latencyAlarmFiresOnWarmAndColdLimits() {
    var alarm = GroundingLatencyAlarm()
    for _ in 0..<19 { alarm.record(keyUpToReadyMilliseconds: 110, isWarm: true) }
    #expect(!alarm.status.isAlarming)
    // One slow warm turn of 20 is the p95 (rank 19 of 20 is still 110).
    alarm.record(keyUpToReadyMilliseconds: 400, isWarm: true)
    #expect(alarm.status.warmP95Milliseconds == 110)
    #expect(!alarm.status.isAlarming)
    // Two slow ones are.
    let status = alarm.record(keyUpToReadyMilliseconds: 400, isWarm: true)
    #expect(status.isWarmOverLimit)
    #expect(status.warningText == "warm p95 400 ms > 150")

    var coldAlarm = GroundingLatencyAlarm()
    for _ in 0..<4 { coldAlarm.record(keyUpToReadyMilliseconds: 500, isWarm: false) }
    #expect(coldAlarm.status.coldP95Milliseconds == nil) // too few samples
    let coldStatus = coldAlarm.record(keyUpToReadyMilliseconds: 250, isWarm: false)
    #expect(coldStatus.isColdOverLimit && !coldStatus.isWarmOverLimit)
}

@Test func latencyAlarmOnlyLooksAtTheLastTwentyTurns() {
    var alarm = GroundingLatencyAlarm()
    for _ in 0..<10 { alarm.record(keyUpToReadyMilliseconds: 900, isWarm: true) }
    for _ in 0..<20 { alarm.record(keyUpToReadyMilliseconds: 100, isWarm: true) }
    #expect(alarm.status.warmP95Milliseconds == 100)
    #expect(!alarm.status.isAlarming)
}
