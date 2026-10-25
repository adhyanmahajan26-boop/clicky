//
//  GroundingSelfTests.swift
//  leanring-buddy
//
//  P1b grounding self-tests against the GroundingFixture app
//  (Tools/GroundingFixture), run via clickyctl:
//
//   fixtureResolve   every fixture item resolved through the real resolver:
//                    ax centre ≤ 1 pt and size ≤ 2 pt; AXBoundsForRange ≤ 1 pt;
//                    web ≥ 95% within 2 pt; canvas (OCR) ≥ 98% within 3 pt.
//   verifyHitTest    mode "cover": Share is under the fixture's cover window →
//                    verified=false, occludedByPID == the helper's pid.
//                    mode "park": the companion is parked over Run → Run is
//                    still verified.
//   groundingLatency 20 cold and 20 warm key-ups; prewarm readiness for 1 s holds.
//

import AppKit
import ClickyCore

@MainActor
enum GroundingSelfTests {
    static func run(named selfTestName: String, mode: String?, companionManager: CompanionManager) async -> (Bool, [String: Any]) {
        switch selfTestName {
        case "fixtureResolve": return await runFixtureResolve(companionManager: companionManager)
        case "verifyHitTest": return await runVerifyHitTest(mode: mode ?? "cover", companionManager: companionManager)
        case "groundingLatency": return await runGroundingLatency(companionManager: companionManager)
        default: return (false, ["error": "unknown grounding self-test \(selfTestName)"])
        }
    }

    // MARK: - Fixture

    struct FixtureGroundTruth {
        let processIdentifier: pid_t
        let helperProcessIdentifier: pid_t?
        let displayID: CGDirectDisplayID
        let items: [(key: String, kind: String, frameCG: CGRect, isVisible: Bool)]
    }

    static func readFixtureGroundTruth() -> FixtureGroundTruth? {
        let groundTruthURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/fixture/groundtruth.json")
        guard let groundTruthData = try? Data(contentsOf: groundTruthURL),
              let groundTruth = try? JSONSerialization.jsonObject(with: groundTruthData) as? [String: Any],
              groundTruth["ready"] as? Bool == true,
              let processIdentifier = groundTruth["pid"] as? Int,
              let rawItems = groundTruth["items"] as? [[String: Any]] else { return nil }
        let items = rawItems.compactMap { rawItem -> (String, String, CGRect, Bool)? in
            guard let key = rawItem["key"] as? String, let kind = rawItem["kind"] as? String,
                  let frameValues = rawItem["frameCG"] as? [Double], frameValues.count == 4 else { return nil }
            return (key, kind, CGRect(x: frameValues[0], y: frameValues[1], width: frameValues[2], height: frameValues[3]),
                    rawItem["visible"] as? Bool ?? true)
        }
        return FixtureGroundTruth(processIdentifier: pid_t(processIdentifier),
                                  helperProcessIdentifier: (groundTruth["helperPid"] as? Int).map { pid_t($0) },
                                  displayID: CGDirectDisplayID(groundTruth["displayID"] as? Int ?? 0),
                                  items: items.map { (key: $0.0, kind: $0.1, frameCG: $0.2, isVisible: $0.3) })
    }

    static let fixtureButtonTitles = ["back": "Back", "share": "Share", "export_pdf": "Export as PDF…", "build_settings": "Build Settings",
                                      "run": "Run", "archive": "Archive", "icon_gear": "Gear", "icon_trash": "Trash", "icon_star": "Star",
                                      "icon_bell": "Bell", "icon_lock": "Lock", "icon_info": "Info"]
    static let fixtureWebLabels = ["web_subscribe": "Subscribe", "web_read_more": "Read more", "web_sign_in": "Sign in",
                                   "web_pricing": "Pricing", "web_docs": "Docs"]
    static let fixtureCanvasTexts = ["canvas_rate_limit": "rate limit exceeded (429)", "canvas_total": "Total: 1,284", "canvas_x42": "x = 42",
                                     "canvas_deploy_failed": "Deploy failed", "canvas_size_10": "Build 10pt", "canvas_size_11": "Retry 11pt",
                                     "canvas_size_13": "Queued 13pt"]

    /// The registry id of a fixture item (only elements of the fixture app).
    static func registryID(forFixtureKey fixtureKey: String, registry: ElementRegistry, fixtureProcessIdentifier: pid_t) -> Int? {
        let fixtureEntries = registry.orderedIDs.compactMap { elementID -> (Int, GroundingElement)? in
            guard let element = registry[elementID], element.processIdentifier == fixtureProcessIdentifier,
                  element.source == .accessibility else { return nil }
            return (elementID, element)
        }
        func labelled(_ wantedLabel: String) -> [(Int, GroundingElement)] {
            fixtureEntries.filter { $0.1.label == wantedLabel }
        }
        if let buttonTitle = fixtureButtonTitles[fixtureKey] ?? fixtureWebLabels[fixtureKey] {
            return labelled(buttonTitle).first?.0
        }
        if fixtureKey == "cancel_1" || fixtureKey == "cancel_2" {
            let cancelButtons = labelled("Cancel").sorted { $0.1.visibleFrameCG.minX < $1.1.visibleFrameCG.minX }
            let cancelIndex = fixtureKey == "cancel_1" ? 0 : 1
            return cancelIndex < cancelButtons.count ? cancelButtons[cancelIndex].0 : nil
        }
        if fixtureKey == "field_search" {
            return fixtureEntries.first { $0.1.role == .textField && $0.1.label == "Search" }?.0
        }
        if fixtureKey == "field_address" {
            return fixtureEntries.first { $0.1.role == .textField && ($0.1.value?.contains("github.com/addy/clicky/pull/12") ?? false) }?.0
        }
        if fixtureKey.hasPrefix("row_"), let rowNumber = Int(fixtureKey.dropFirst(4)) {
            return fixtureEntries.first { $0.1.role == .row && $0.1.label == "Row \(rowNumber)" }?.0
        }
        return nil
    }

    // MARK: - fixtureResolve

    static func runFixtureResolve(companionManager: CompanionManager) async -> (Bool, [String: Any]) {
        guard let groundTruth = readFixtureGroundTruth() else { return (false, ["error": "no ready fixture groundtruth"]) }
        let coordinator = companionManager.groundingCoordinator
        // Like a real 1 s push-to-talk hold: prewarm, then key-up (warm path).
        coordinator.prewarm()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        while coordinator.lastPrewarmReadyDate == nil, let prewarmStartDate = coordinator.prewarmStartDate, Date().timeIntervalSince(prewarmStartDate) < 6 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard var groundedTurn = try? await coordinator.prepareTurn(keyUpDate: Date()) else { return (false, ["error": "prepareTurn failed"]) }
        await groundedTurn.ensureOCRLines()
        // Cold path OCR may still be running past 500 ms: wait for it fully here.
        if groundedTurn.registry.allOCRLines.isEmpty, let pendingOCRTask = groundedTurn.pendingOCRTask {
            groundedTurn.registry.allOCRLines = await pendingOCRTask.value
        }
        let resolver = TargetResolver(registry: groundedTurn.registry, framesByScreenNumber: groundedTurn.framesByScreenNumber,
                                      cursorCG: groundedTurn.cursorCG, windowStack: groundedTurn.windowStack,
                                      lookup: AXGroundingLiveLookup(ax: coordinator.ax))

        var perKindCounts: [String: (hits: Int, total: Int)] = [:]
        var misses: [[String: Any]] = []
        var worstErrors: [String: Double] = [:]
        var canvasHeightGaps: [Double] = []

        for item in groundTruth.items where item.isVisible && item.kind != "dot" {
            var tagText: String?
            var centreTolerance: CGFloat = 1
            var sizeTolerance: CGFloat = 2
            switch item.kind {
            case "ax", "web":
                if let elementID = registryID(forFixtureKey: item.key, registry: groundedTurn.registry, fixtureProcessIdentifier: groundTruth.processIdentifier) {
                    tagText = "[MARK:box:#\(elementID)]"
                }
                if item.kind == "web" { centreTolerance = 2; sizeTolerance = 2 }
            case "canvas":
                if let canvasText = fixtureCanvasTexts[item.key] {
                    tagText = "[MARK:box:\"\(canvasText)\"]"
                }
                centreTolerance = 3
                sizeTolerance = 3
            case "axtext":
                let textViewID = groundedTurn.registry.orderedIDs.first { elementID in
                    guard let element = groundedTurn.registry[elementID] else { return false }
                    return element.processIdentifier == groundTruth.processIdentifier && element.role == .textArea
                }
                tagText = textViewID.map { "[MARK:box:\"rate limit\" in #\($0)]" } ?? "[MARK:box:\"rate limit\"]"
            default:
                continue
            }

            var counts = perKindCounts[item.kind] ?? (0, 0)
            counts.total += 1
            var maybeResolvedTarget = tagText.flatMap { MarkTagParser.parse($0) }.flatMap { resolver.resolve($0) }
            if maybeResolvedTarget == nil, item.kind == "canvas", let tagText, let parsedTag = MarkTagParser.parse(tagText) {
                // Same one-off retry the answer path does for missing text.
                await groundedTurn.retryOCRWithShiftedBands()
                maybeResolvedTarget = TargetResolver(registry: groundedTurn.registry, framesByScreenNumber: groundedTurn.framesByScreenNumber,
                                                     cursorCG: groundedTurn.cursorCG, windowStack: groundedTurn.windowStack,
                                                     lookup: AXGroundingLiveLookup(ax: coordinator.ax)).resolve(parsedTag)
            }
            guard tagText != nil, let resolvedTarget = maybeResolvedTarget else {
                let nearbyOCRTexts = groundedTurn.registry.allOCRLines
                    .filter { hypot($0.frameCG.midX - item.frameCG.midX, $0.frameCG.midY - item.frameCG.midY) < 60 }
                    .map(\.text)
                misses.append(["key": item.key, "reason": tagText == nil ? "not in registry" : "unresolved", "nearbyOCR": nearbyOCRTexts])
                perKindCounts[item.kind] = counts
                continue
            }
            let centreError = hypot(resolvedTarget.frameCG.midX - item.frameCG.midX, resolvedTarget.frameCG.midY - item.frameCG.midY)
            let sizeError = item.kind == "canvas"
                ? abs(resolvedTarget.frameCG.height - item.frameCG.height)
                : max(abs(resolvedTarget.frameCG.width - item.frameCG.width), abs(resolvedTarget.frameCG.height - item.frameCG.height))
            worstErrors[item.kind] = max(worstErrors[item.kind] ?? 0, Double(item.kind == "canvas" ? centreError : max(centreError, sizeError)))
            // OCR boxes hug the ink while the fixture's canvas truth is the
            // typographic line box (taller by ascender/descender room), so
            // canvas text is scored on its centre; the size gap is reported.
            let isWithinTolerance = item.kind == "canvas"
                ? centreError <= centreTolerance
                : centreError <= centreTolerance && sizeError <= sizeTolerance
            if item.kind == "canvas" {
                canvasHeightGaps.append(Double((sizeError * 10).rounded() / 10))
            }
            if isWithinTolerance {
                counts.hits += 1
            } else {
                let nearbyOCRLines = groundedTurn.registry.allOCRLines
                    .filter { hypot($0.frameCG.midX - item.frameCG.midX, $0.frameCG.midY - item.frameCG.midY) < 40 }
                    .map { "\($0.text) @\(Int($0.frameCG.minX)),\(Int($0.frameCG.minY)),\(Int($0.frameCG.width)),\(Int($0.frameCG.height)) c=\(String(format: "%.2f", $0.confidence))" }
                misses.append(["key": item.key, "method": resolvedTarget.method.rawValue, "nearbyOCR": nearbyOCRLines,
                               "truth": "\(Int(item.frameCG.minX)),\(Int(item.frameCG.minY)),\(Int(item.frameCG.width)),\(Int(item.frameCG.height))",
                               "centreErrorPt": Double((centreError * 10).rounded() / 10), "sizeErrorPt": Double((sizeError * 10).rounded() / 10)])
            }
            perKindCounts[item.kind] = counts
        }

        func rate(_ kind: String) -> Double {
            guard let counts = perKindCounts[kind], counts.total > 0 else { return 1 }
            return Double(counts.hits) / Double(counts.total)
        }
        let isPassing = rate("ax") == 1 && rate("axtext") == 1 && rate("web") >= 0.95 && rate("canvas") >= 0.98
        return (isPassing, [
            "displayID": Int(groundTruth.displayID),
            "warm": groundedTurn.isWarm,
            "counts": perKindCounts.mapValues { ["hits": $0.hits, "total": $0.total] },
            "worstErrorPt": worstErrors.mapValues { ($0 * 10).rounded() / 10 },
            "misses": misses,
            "canvasInkVsLineBoxHeightGapPt": canvasHeightGaps,
            "registryCount": groundedTurn.registry.orderedIDs.count,
            "ocrLines": groundedTurn.registry.allOCRLines.count
        ])
    }

    // MARK: - verifyHitTest

    static func runVerifyHitTest(mode: String, companionManager: CompanionManager) async -> (Bool, [String: Any]) {
        guard let groundTruth = readFixtureGroundTruth() else { return (false, ["error": "no ready fixture groundtruth"]) }
        let coordinator = companionManager.groundingCoordinator
        // "park" / "cover", optionally "+marks": live marks drawn on the target
        // first (they must not change the verdict; Clicky's overlay is excluded).
        let isParkMode = mode.hasPrefix("park")
        let targetKey = isParkMode ? "run" : "share"
        if mode.hasSuffix("+marks"), let targetFrame = groundTruth.items.first(where: { $0.key == targetKey })?.frameCG {
            companionManager.markController.show([LiveScreenMark(
                style: .circle, rectCG: targetFrame, displayText: "Here", source: .raw, ax: nil, confidence: 1, isTentative: false,
                createdAt: Date(), windowID: nil, windowFrameCG: nil, clipAX: nil, labelAX: nil, originalLabel: nil,
                recheckName: nil, order: 0, tagIndex: nil
            )], turnRecord: nil)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        defer { if mode.hasSuffix("+marks") { companionManager.clearLiveScreenMarks() } }

        if isParkMode, let runFrame = groundTruth.items.first(where: { $0.key == "run" })?.frameCG {
            // Park the companion right on top of Run.
            companionManager.detectedElementScreenLocation = ScreenTopology.appKit(fromCG: runFrame.center, flipH: ScreenTopology.mainDisplayHeight)
            companionManager.detectedElementDisplayFrame = ScreenTopology.current().first { $0.boundsCG.contains(runFrame.center) }?.frameAppKit
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        guard let groundedTurn = try? await coordinator.prepareTurn(keyUpDate: Date()),
              let elementID = registryID(forFixtureKey: targetKey, registry: groundedTurn.registry, fixtureProcessIdentifier: groundTruth.processIdentifier) else {
            return (false, ["error": "\(targetKey) not in registry"])
        }
        let resolver = TargetResolver(registry: groundedTurn.registry, framesByScreenNumber: groundedTurn.framesByScreenNumber,
                                      cursorCG: groundedTurn.cursorCG, windowStack: groundedTurn.windowStack,
                                      lookup: AXGroundingLiveLookup(ax: coordinator.ax))
        guard let parsedTag = MarkTagParser.parse("[POINT:#\(elementID)]"), var resolvedTarget = resolver.resolve(parsedTag) else {
            return (false, ["error": "couldn't resolve"])
        }
        let verificationStart = Date()
        HitTestVerifier.verify(&resolvedTarget, ax: coordinator.ax, ownProcessIdentifier: getpid(), windowStack: groundedTurn.windowStack)
        let verificationMilliseconds = Date().timeIntervalSince(verificationStart) * 1000
        companionManager.clearDetectedElementLocation()

        let isPassing: Bool
        if isParkMode {
            isPassing = resolvedTarget.verified == true
        } else {
            isPassing = resolvedTarget.verified == false && resolvedTarget.occludedByPID != nil
                && resolvedTarget.occludedByPID == groundTruth.helperProcessIdentifier
        }
        return (isPassing, [
            "mode": mode,
            "verified": resolvedTarget.verified.map { $0 as Any } ?? NSNull(),
            "occludedByPID": resolvedTarget.occludedByPID.map { Int($0) as Any } ?? NSNull(),
            "helperPid": groundTruth.helperProcessIdentifier.map { Int($0) as Any } ?? NSNull(),
            "verifyMs": (verificationMilliseconds * 100).rounded() / 100
        ])
    }

    // MARK: - groundingLatency

    static func runGroundingLatency(companionManager: CompanionManager) async -> (Bool, [String: Any]) {
        let coordinator = companionManager.groundingCoordinator
        var coldMilliseconds: [Double] = []
        var warmMilliseconds: [Double] = []
        var prewarmReadyCount = 0
        var prewarmDurations: [Double] = []
        var warmStageSamples: [[String: Double]] = []
        let runCount = 20

        for _ in 0..<runCount {
            if let coldTurn = try? await coordinator.prepareTurn(keyUpDate: Date()) {
                coldMilliseconds.append(coldTurn.keyUpToReadyMilliseconds)
                // A real turn consumes its OCR; here it would only pile up.
                coldTurn.pendingOCRTask?.cancel()
                _ = await coldTurn.pendingOCRTask?.value
            }
        }
        for _ in 0..<runCount {
            coordinator.prewarm()
            let holdStart = Date()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // a 1 s hold
            let keyUpDate = Date()
            if let readyDate = coordinator.lastPrewarmReadyDate, readyDate <= keyUpDate {
                prewarmReadyCount += 1
                prewarmDurations.append(readyDate.timeIntervalSince(holdStart) * 1000)
            }
            if let warmTurn = try? await coordinator.prepareTurn(keyUpDate: keyUpDate) {
                if warmTurn.isWarm {
                    warmMilliseconds.append(warmTurn.keyUpToReadyMilliseconds)
                    warmStageSamples.append(coordinator.lastTurnStageMilliseconds)
                }
                warmTurn.pendingOCRTask?.cancel()
                _ = await warmTurn.pendingOCRTask?.value
            }
        }

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sortedValues = values.sorted()
            guard !sortedValues.isEmpty else { return .nan }
            return sortedValues[min(sortedValues.count - 1, Int((fraction * Double(sortedValues.count - 1)).rounded()))]
        }
        let ocrMilliseconds = coordinator.lastOCRMillisecondsByDisplay.map { ["displayID": Int($0.key), "ms": ($0.value).rounded()] }
        let isPassing = percentile(warmMilliseconds, 0.95) <= 150 && percentile(coldMilliseconds, 0.95) <= 300
            && Double(prewarmReadyCount) / Double(runCount) >= 0.95
        return (isPassing, [
            "coldMs": ["p50": percentile(coldMilliseconds, 0.5).rounded(), "p95": percentile(coldMilliseconds, 0.95).rounded(), "n": coldMilliseconds.count],
            "warmMs": ["p50": percentile(warmMilliseconds, 0.5).rounded(), "p95": percentile(warmMilliseconds, 0.95).rounded(), "n": warmMilliseconds.count],
            "prewarmReadyWithin1s": "\(prewarmReadyCount)/\(runCount)",
            "prewarmMs": ["p50": percentile(prewarmDurations, 0.5).rounded(), "p95": percentile(prewarmDurations, 0.95).rounded()],
            "ocrMsByDisplay": ocrMilliseconds,
            "warmStageP50Ms": Dictionary(uniqueKeysWithValues: Set(warmStageSamples.flatMap(\.keys)).map { stage in
                (stage, percentile(warmStageSamples.compactMap { $0[stage] }, 0.5))
            })
        ])
    }
}
