//
//  SelfTests.swift
//  leanring-buddy
//
//  Measurements that prove the geometry and transport instead of assuming
//  them. Run via `Tools/clickyctl.sh '{"cmd":"selftest","name":"<name>"}'`;
//  the tier probe also runs in the background when the model changes.
//
//   calibration       magenta crosshairs drawn by Clicky, captured with
//                     Clicky's own windows included, must be found within
//                     1 native pixel of where CaptureFrame says they are.
//   overlayExclusion  magenta squares drawn by Clicky must NOT appear in
//                     the production capture (which excludes Clicky).
//   transportProbe    (a) an image's 6-digit code is read back, (b) the size
//                     the CLI stores matches what was sent, (c) whether the
//                     oversized_image transformation is honoured, (d) token
//                     baseline and whether ~/.claude/CLAUDE.md is injected.
//   tierProbe         the model reports dot positions in the image at the
//                     size we send; if it saw a smaller image, images get
//                     capped to the size it really sees.
//

import AppKit
import ClickyCore
import ImageIO
import ScreenCaptureKit

@MainActor
enum DiagnosticSelfTests {
    static func run(named selfTestName: String, companionManager: CompanionManager) async -> (Bool, [String: Any]) {
        switch selfTestName {
        case "calibration":
            return await runCalibration()
        case "overlayExclusion":
            return await runOverlayExclusion()
        case "transportProbe":
            return await runTransportProbe(model: companionManager.selectedModel)
        case "tierProbe":
            return await runTierProbe(model: companionManager.selectedModel)
        default:
            return (false, ["error": "unknown diagnostic \(selfTestName)"])
        }
    }

    // MARK: - Calibration

    private static let calibrationInsetInPoints: CGFloat = 40
    private static let crosshairArmLengthInPoints: CGFloat = 9
    private static let crosshairLineWidthInPoints: CGFloat = 3
    private static let calibrationSearchRadiusInPoints: CGFloat = 20

    private static func calibrationSpots(in displayBoundsCG: CGRect) -> [CGPoint] {
        let inset = calibrationInsetInPoints
        return [
            CGPoint(x: displayBoundsCG.minX + inset, y: displayBoundsCG.minY + inset),
            CGPoint(x: displayBoundsCG.maxX - inset, y: displayBoundsCG.minY + inset),
            CGPoint(x: displayBoundsCG.minX + inset, y: displayBoundsCG.maxY - inset),
            CGPoint(x: displayBoundsCG.maxX - inset, y: displayBoundsCG.maxY - inset),
            CGPoint(x: displayBoundsCG.midX, y: displayBoundsCG.midY)
        ]
    }

    static func runCalibration() async -> (Bool, [String: Any]) {
        let displays = ScreenTopology.current()
        let drawingWindows = displays.map { display in
            MagentaDrawingWindow(display: display, drawing: .crosshairs(
                spotsOverlayLocal: calibrationSpots(in: display.boundsCG).map {
                    ScreenTopology.overlayLocal(fromCG: $0, displayBoundsCG: display.boundsCG)
                },
                armLength: crosshairArmLengthInPoints,
                lineWidth: crosshairLineWidthInPoints
            ))
        }
        defer { drawingWindows.forEach { $0.orderOut(nil) } }
        try? await Task.sleep(nanoseconds: 400_000_000)

        var isPassing = true
        var perDisplayResults: [[String: Any]] = []
        for display in displays {
            do {
                let (nativeImage, regionCG) = try await ScreenCaptureService.captureNativeImage(of: display, includesOwnWindows: true)
                let frame = CaptureFrame(display: display, screenNumber: 0, regionCG: regionCG,
                                         native: PixelSize(width: nativeImage.width, height: nativeImage.height), model: nil)
                let pixelBuffer = SRGBPixelBuffer(image: nativeImage)
                var spotErrors: [Double] = []
                for spotCG in calibrationSpots(in: display.boundsCG) {
                    let expectedNativePixel = frame.nativePx(fromCG: spotCG)
                    let searchRadius = calibrationSearchRadiusInPoints * frame.nativePixelsPerPoint
                    guard let centroid = pixelBuffer.magentaCentroid(around: expectedNativePixel, radius: searchRadius) else {
                        spotErrors.append(-1)
                        isPassing = false
                        continue
                    }
                    let spotError = hypot(Double(centroid.x - expectedNativePixel.x), Double(centroid.y - expectedNativePixel.y))
                    spotErrors.append((spotError * 100).rounded() / 100)
                    if spotError > 1.0 { isPassing = false }
                }
                perDisplayResults.append([
                    "displayID": Int(display.displayID),
                    "name": display.localizedName,
                    "native": frame.native.description,
                    "pxPerPt": Double(frame.nativePixelsPerPoint),
                    "spotErrorsNativePx": spotErrors
                ])
            } catch {
                isPassing = false
                perDisplayResults.append(["displayID": Int(display.displayID), "error": String(describing: error)])
            }
        }
        return (isPassing, ["maxAllowedNativePx": 1, "displays": perDisplayResults])
    }

    // MARK: - Overlay exclusion

    private static let exclusionSquareSizeInPoints: CGFloat = 200

    static func runOverlayExclusion() async -> (Bool, [String: Any]) {
        let displays = ScreenTopology.current()
        let squareRectsCG = Dictionary(uniqueKeysWithValues: displays.map { display in
            (display.displayID, CGRect(
                x: display.boundsCG.midX - exclusionSquareSizeInPoints / 2,
                y: display.boundsCG.midY - exclusionSquareSizeInPoints / 2,
                width: exclusionSquareSizeInPoints,
                height: exclusionSquareSizeInPoints
            ))
        })
        let drawingWindows = displays.compactMap { display -> MagentaDrawingWindow? in
            guard let squareRectCG = squareRectsCG[display.displayID] else { return nil }
            let squareOrigin = ScreenTopology.overlayLocal(fromCG: squareRectCG.origin, displayBoundsCG: display.boundsCG)
            return MagentaDrawingWindow(display: display, drawing: .square(CGRect(origin: squareOrigin, size: squareRectCG.size)))
        }
        defer { drawingWindows.forEach { $0.orderOut(nil) } }
        try? await Task.sleep(nanoseconds: 400_000_000)

        var isPassing = true
        var perDisplayResults: [[String: Any]] = []
        for display in displays {
            guard let squareRectCG = squareRectsCG[display.displayID] else { continue }
            do {
                // The production path: Clicky excluded.
                let (nativeImage, regionCG) = try await ScreenCaptureService.captureNativeImage(of: display, includesOwnWindows: false)
                let frame = CaptureFrame(display: display, screenNumber: 0, regionCG: regionCG,
                                         native: PixelSize(width: nativeImage.width, height: nativeImage.height), model: nil)
                let squareRectNative = frame.modelPxRect(fromCG: squareRectCG)
                let magentaFraction = SRGBPixelBuffer(image: nativeImage).magentaFraction(in: squareRectNative)
                if magentaFraction >= 0.001 { isPassing = false }
                perDisplayResults.append([
                    "displayID": Int(display.displayID),
                    "magentaPercentInSquare": (magentaFraction * 100_000).rounded() / 1000
                ])
            } catch {
                isPassing = false
                perDisplayResults.append(["displayID": Int(display.displayID), "error": String(describing: error)])
            }
        }
        return (isPassing, ["maxAllowedPercent": 0.1, "displays": perDisplayResults])
    }

    // MARK: - Transport probe

    static func runTransportProbe(model: String) async -> (Bool, [String: Any]) {
        var results: [String: Any] = ["model": model]
        let claudeCodeBridge = ClaudeCodeBridge(model: model)
        let probeSystemPrompt = "You are a careful image reader. Follow the reply format exactly."

        // (a) Read back a random code.
        let secretCode = String(format: "%06d", Int.random(in: 0...999_999))
        let codeImageSize = PixelSize(width: 1200, height: 400)
        var isPassing = false
        do {
            let codeImageJPEG = try renderJPEG(size: codeImageSize) { context in
                drawText(secretCode, in: context, at: CGPoint(x: 120, y: 130), fontSize: 160)
            }
            let codeTurn = try await claudeCodeBridge.runTurn(
                systemPromptFileName: "probe-prompt.md",
                systemPrompt: probeSystemPrompt,
                contentBlocks: [.text("Reply with only the 6-digit number shown in the image."), .jpegImage(codeImageJPEG)]
            )
            let digitsInReply = codeTurn.text.filter(\.isNumber)
            isPassing = digitsInReply == secretCode
            results["a_codeReadBack"] = ["sent": secretCode, "reply": codeTurn.text, "ok": isPassing, "resolvedModel": codeTurn.resolvedModelIdentifier ?? ""]
        } catch {
            results["a_codeReadBack"] = ["error": String(describing: error)]
        }

        // (b) What size does the CLI store? One persisted call under a known id.
        let probeSessionIdentifier = UUID().uuidString.lowercased()
        let persistedImageSize = PixelSize(width: 2576, height: 1078)
        do {
            let persistedImageJPEG = try renderJPEG(size: persistedImageSize) { context in
                drawText("size probe", in: context, at: CGPoint(x: 200, y: 400), fontSize: 120)
            }
            _ = try await claudeCodeBridge.runTurn(
                systemPromptFileName: "probe-prompt.md",
                systemPrompt: probeSystemPrompt,
                contentBlocks: [.text("Reply with only the word ok."), .jpegImage(persistedImageJPEG)],
                persistentSessionIdentifier: probeSessionIdentifier
            )
            results["b_storedImage"] = inspectAndDeleteTranscript(sessionIdentifier: probeSessionIdentifier, sentSize: persistedImageSize)
        } catch {
            results["b_storedImage"] = ["error": String(describing: error)]
            _ = inspectAndDeleteTranscript(sessionIdentifier: probeSessionIdentifier, sentSize: persistedImageSize)
        }

        // (c) oversized_image: "error" — honoured?
        var transformationResults: [String: Any] = [:]
        do {
            let correctSizeJPEG = try renderJPEG(size: PixelSize(width: 1568, height: 656)) { context in
                drawText("fits", in: context, at: CGPoint(x: 100, y: 200), fontSize: 120)
            }
            do {
                _ = try await claudeCodeBridge.runTurn(
                    systemPromptFileName: "probe-prompt.md", systemPrompt: probeSystemPrompt,
                    contentBlocks: [.text("Reply with only the word ok."), .jpegImage(correctSizeJPEG)],
                    oversizedImageErrorTransformationOverride: true
                )
                transformationResults["correctSizeSucceeded"] = true
            } catch {
                transformationResults["correctSizeSucceeded"] = false
                transformationResults["correctSizeError"] = String(describing: error)
            }
            let oversizedJPEG = try renderJPEG(size: PixelSize(width: 3200, height: 1340)) { context in
                drawText("too big", in: context, at: CGPoint(x: 200, y: 400), fontSize: 160)
            }
            do {
                _ = try await claudeCodeBridge.runTurn(
                    systemPromptFileName: "probe-prompt.md", systemPrompt: probeSystemPrompt,
                    contentBlocks: [.text("Reply with only the word ok."), .jpegImage(oversizedJPEG)],
                    oversizedImageErrorTransformationOverride: true
                )
                transformationResults["oversizedErrored"] = false
            } catch {
                transformationResults["oversizedErrored"] = true
                transformationResults["oversizedError"] = String(describing: error).prefix(300)
            }
        } catch {
            transformationResults["error"] = String(describing: error)
        }
        let keepsTransformation = (transformationResults["correctSizeSucceeded"] as? Bool ?? false)
            && (transformationResults["oversizedErrored"] as? Bool ?? false)
        ClaudeCodeBridge.sendsOversizedImageErrorTransformation = keepsTransformation
        transformationResults["decision"] = keepsTransformation ? "keep on every image block" : "drop"
        results["c_oversizedImageTransformation"] = transformationResults

        // (d) Text-only token baseline + is ~/.claude/CLAUDE.md injected?
        do {
            let baselineQuestion = "Does any instruction or context you were given mention the word 'graphify'? Reply only yes or no."
            let baselineTurn = try await claudeCodeBridge.runTurn(
                systemPromptFileName: "probe-prompt.md",
                systemPrompt: probeSystemPrompt,
                contentBlocks: [.text(baselineQuestion)]
            )
            let usage = baselineTurn.usage
            let totalInputTokens = (usage["input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
            let estimatedPromptTokens = (probeSystemPrompt.count + baselineQuestion.count) / 4
            let userClaudeMarkdownURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/CLAUDE.md")
            results["d_tokenBaseline"] = [
                "usageTotalInput": totalInputTokens,
                "usage": usage,
                "promptEstimate": estimatedPromptTokens,
                "overheadTokens": totalInputTokens - estimatedPromptTokens,
                "userClaudeMdExists": FileManager.default.fileExists(atPath: userClaudeMarkdownURL.path),
                "modelSaysGraphifyMentioned": baselineTurn.text.lowercased().contains("yes"),
                "reply": baselineTurn.text
            ]
        } catch {
            results["d_tokenBaseline"] = ["error": String(describing: error)]
        }

        return (isPassing, results)
    }

    /// Finds ~/.claude/projects/*/<id>.jsonl, decodes the size of the image it
    /// stored, then deletes ONLY that file.
    private static func inspectAndDeleteTranscript(sessionIdentifier: String, sentSize: PixelSize) -> [String: Any] {
        let projectsDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        let projectDirectoryURLs = (try? FileManager.default.contentsOfDirectory(at: projectsDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        guard let transcriptURL = projectDirectoryURLs
            .map({ $0.appendingPathComponent("\(sessionIdentifier).jsonl") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return ["error": "transcript \(sessionIdentifier).jsonl not found"]
        }
        defer { try? FileManager.default.removeItem(at: transcriptURL) }

        guard let transcriptText = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            return ["error": "couldn't read transcript", "deleted": transcriptURL.lastPathComponent]
        }
        var storedSize: PixelSize?
        for transcriptLine in transcriptText.split(separator: "\n") {
            guard let lineData = transcriptLine.data(using: .utf8),
                  let lineObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = lineObject["message"] as? [String: Any],
                  let messageContent = message["content"] as? [[String: Any]] else { continue }
            for contentBlock in messageContent where contentBlock["type"] as? String == "image" {
                guard let source = contentBlock["source"] as? [String: Any],
                      let base64Data = source["data"] as? String,
                      let imageData = Data(base64Encoded: base64Data),
                      let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
                      let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                      let pixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
                      let pixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int else { continue }
                storedSize = PixelSize(width: pixelWidth, height: pixelHeight)
            }
        }
        return [
            "sent": sentSize.description,
            "stored": storedSize?.description ?? "no image found",
            "matches": storedSize == sentSize,
            "deleted": transcriptURL.lastPathComponent
        ]
    }

    // MARK: - Tier probe

    private static var isTierProbeRunning = false

    /// Runs the tier probe once per new model id, in the background.
    static func probeInBackgroundIfNeeded(resolvedModelIdentifier: String, model: String) {
        guard ClickySettings.probeRecords[resolvedModelIdentifier] == nil, !isTierProbeRunning else { return }
        Task {
            print("🔬 Tier probe: new model \(resolvedModelIdentifier), probing in the background")
            _ = await runTierProbe(model: model)
        }
    }

    static func runTierProbe(model: String) async -> (Bool, [String: Any]) {
        guard !isTierProbeRunning else { return (false, ["error": "already running"]) }
        isTierProbeRunning = true
        defer { isTierProbeRunning = false }

        let claudeCodeBridge = ClaudeCodeBridge(model: model)
        // Each display's real cursor-tier size (identical displays collapse).
        var probeSizes: [PixelSize] = []
        for display in ScreenTopology.current() {
            let nativeEstimate = PixelSize(width: Int(display.boundsCG.width * 2), height: Int(display.boundsCG.height * 2))
            let cursorTierSize = ClaudeImageSizing.modelImageSize(
                regionInPoints: display.boundsCG.size,
                nativePixels: nativeEstimate,
                isCursorScreen: true,
                tierForCursorScreen: .high,
                effectiveMaxEdge: nil
            )
            if !probeSizes.contains(cursorTierSize) { probeSizes.append(cursorTierSize) }
        }

        var resolvedModelIdentifier: String?
        var sizeResults: [[String: Any]] = []
        var effectiveMaxEdge: Int?
        var worstPassingError = 0.0
        var isPassing = true

        for probeSize in probeSizes {
            var sizeResult: [String: Any] = ["size": probeSize.description]
            do {
                let firstAttempt = try await probeOnce(size: probeSize, claudeCodeBridge: claudeCodeBridge)
                resolvedModelIdentifier = resolvedModelIdentifier ?? firstAttempt.resolvedModelIdentifier
                sizeResult["r"] = firstAttempt.verdict.scaleRatio
                sizeResult["maxErrorPx"] = firstAttempt.verdict.maximumErrorInPixels
                sizeResult["passed"] = firstAttempt.verdict.passes

                if firstAttempt.verdict.passes {
                    worstPassingError = max(worstPassingError, firstAttempt.verdict.maximumErrorInPixels)
                } else if abs(firstAttempt.verdict.scaleRatio - 1) > TierProbeMath.ratioTolerance,
                          let suggestedEdge = firstAttempt.verdict.suggestedEffectiveMaxEdge {
                    // The model saw a smaller image: cap to what it sees and
                    // re-probe, which must pass.
                    let cappedSize = ClaudeImageSizing.capLongEdge(probeSize, cap: suggestedEdge)
                    let retry = try await probeOnce(size: cappedSize, claudeCodeBridge: claudeCodeBridge)
                    sizeResult["corrected"] = ["effectiveMaxEdge": suggestedEdge, "size": cappedSize.description,
                                               "r": retry.verdict.scaleRatio, "maxErrorPx": retry.verdict.maximumErrorInPixels,
                                               "passed": retry.verdict.passes]
                    if retry.verdict.passes {
                        effectiveMaxEdge = min(effectiveMaxEdge ?? suggestedEdge, suggestedEdge)
                        worstPassingError = max(worstPassingError, retry.verdict.maximumErrorInPixels)
                    } else {
                        isPassing = false
                    }
                } else {
                    // Right scale but imprecise: nothing to cap; report it.
                    isPassing = false
                }
            } catch {
                sizeResult["error"] = String(describing: error)
                isPassing = false
            }
            sizeResults.append(sizeResult)
        }

        if isPassing, let resolvedModelIdentifier {
            var probeRecords = ClickySettings.probeRecords
            // The CLI downsizes above 2000 px anyway; record that cap even when
            // the probe needed no correction.
            probeRecords[resolvedModelIdentifier] = ClickySettings.ProbeRecord(
                effectiveMaxEdge: min(effectiveMaxEdge ?? ClaudeImageSizing.claudeCodeCLIMaxLongEdge, ClaudeImageSizing.claudeCodeCLIMaxLongEdge),
                sizes: probeSizes.map(\.description),
                error: worstPassingError,
                date: Date(),
                reason: effectiveMaxEdge == nil ? "CLI downscale" : "measured"
            )
            ClickySettings.probeRecords = probeRecords
        }
        return (isPassing, [
            "model": model,
            "resolvedModel": resolvedModelIdentifier ?? "",
            "effectiveMaxEdge": effectiveMaxEdge.map { $0 as Any } ?? NSNull(),
            "sizes": sizeResults
        ])
    }

    private static func probeOnce(size probeSize: PixelSize, claudeCodeBridge: ClaudeCodeBridge) async throws -> (verdict: TierProbeMath.Verdict, resolvedModelIdentifier: String?) {
        var randomGenerator = SystemRandomNumberGenerator()
        let dotDiameter: CGFloat = 14
        let margin = 40
        // Three dots in different thirds, the last at x >= 0.9 w.
        let dotCentres: [CGPoint] = [
            CGPoint(x: Int.random(in: margin...(probeSize.width / 3), using: &randomGenerator),
                    y: Int.random(in: margin...(probeSize.height - margin), using: &randomGenerator)),
            CGPoint(x: Int.random(in: (probeSize.width / 3 + margin)...(probeSize.width * 2 / 3), using: &randomGenerator),
                    y: Int.random(in: margin...(probeSize.height - margin), using: &randomGenerator)),
            CGPoint(x: Int.random(in: (probeSize.width * 9 / 10)...(probeSize.width - margin), using: &randomGenerator),
                    y: Int.random(in: margin...(probeSize.height - margin), using: &randomGenerator))
        ]
        let probeImageJPEG = try renderJPEG(size: probeSize) { context in
            // 10 px grid
            context.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1))
            context.setLineWidth(1)
            for gridX in stride(from: 0, through: probeSize.width, by: 10) {
                context.move(to: CGPoint(x: CGFloat(gridX) + 0.5, y: 0))
                context.addLine(to: CGPoint(x: CGFloat(gridX) + 0.5, y: CGFloat(probeSize.height)))
            }
            for gridY in stride(from: 0, through: probeSize.height, by: 10) {
                context.move(to: CGPoint(x: 0, y: CGFloat(gridY) + 0.5))
                context.addLine(to: CGPoint(x: CGFloat(probeSize.width), y: CGFloat(gridY) + 0.5))
            }
            context.strokePath()
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            for dotCentre in dotCentres {
                context.fillEllipse(in: CGRect(x: dotCentre.x - dotDiameter / 2, y: dotCentre.y - dotDiameter / 2,
                                               width: dotDiameter, height: dotDiameter))
            }
        }
        let probeTurn = try await claudeCodeBridge.runTurn(
            systemPromptFileName: "probe-prompt.md",
            systemPrompt: "You are a precise image measurement tool. Follow the reply format exactly.",
            contentBlocks: [
                .text("Reply with only [[x,y],[x,y],[x,y]]: the red dots' centres in this image's pixel coordinates, left to right."),
                .jpegImage(probeImageJPEG)
            ]
        )
        guard let answeredPoints = TierProbeMath.parsePoints(fromReply: probeTurn.text), answeredPoints.count == dotCentres.count,
              let verdict = TierProbeMath.evaluate(answers: answeredPoints.sorted { $0.x < $1.x }, truths: dotCentres, sentLongEdge: probeSize.longEdge) else {
            throw ScreenCaptureError(message: "tier probe: unparseable reply \(probeTurn.text.prefix(200))")
        }
        return (verdict, probeTurn.resolvedModelIdentifier)
    }

    // MARK: - Drawing helpers

    /// Draws with a top-left origin (y down), like image pixel coordinates.
    private static func renderJPEG(size imageSize: PixelSize, draw: (CGContext) -> Void) throws -> Data {
        guard let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let drawingContext = CGContext(data: nil, width: imageSize.width, height: imageSize.height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScreenCaptureError(message: "couldn't create a drawing context")
        }
        drawingContext.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        drawingContext.fill(CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height))
        drawingContext.translateBy(x: 0, y: CGFloat(imageSize.height))
        drawingContext.scaleBy(x: 1, y: -1)
        draw(drawingContext)
        guard let renderedImage = drawingContext.makeImage() else {
            throw ScreenCaptureError(message: "couldn't render the probe image")
        }
        return try encodeModelJPEG(from: renderedImage, modelSize: imageSize, quality: ScreenCaptureService.modelJPEGQuality)
    }

    private static func drawText(_ text: String, in context: CGContext, at topLeft: CGPoint, fontSize: CGFloat) {
        let attributedText = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attributedText.draw(at: topLeft)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Magenta drawing windows

/// A click-through window over a whole display that draws pure sRGB magenta
/// marks at overlay-local positions (top-left origin), for the self-tests.
@MainActor
final class MagentaDrawingWindow: NSWindow {
    enum Drawing {
        case crosshairs(spotsOverlayLocal: [CGPoint], armLength: CGFloat, lineWidth: CGFloat)
        case square(CGRect)
    }

    init(display: DisplayInfo, drawing: Drawing) {
        super.init(contentRect: display.frameAppKit, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(display.frameAppKit, display: false)
        contentView = MagentaDrawingView(frame: CGRect(origin: .zero, size: display.frameAppKit.size), drawing: drawing)
        orderFrontRegardless()
        displayIfNeeded()
    }
}

private final class MagentaDrawingView: NSView {
    private let drawing: MagentaDrawingWindow.Drawing

    init(frame: CGRect, drawing: MagentaDrawingWindow.Drawing) {
        self.drawing = drawing
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        switch drawing {
        case .crosshairs(let spots, let armLength, let lineWidth):
            for spot in spots {
                context.fill(CGRect(x: spot.x - armLength / 2, y: spot.y - lineWidth / 2, width: armLength, height: lineWidth))
                context.fill(CGRect(x: spot.x - lineWidth / 2, y: spot.y - armLength / 2, width: lineWidth, height: armLength))
            }
        case .square(let squareRect):
            context.fill(squareRect)
        }
    }
}

// MARK: - Pixel analysis

/// RGBA8 copy of an image in sRGB, top-left origin.
private struct SRGBPixelBuffer {
    let width: Int
    let height: Int
    private let pixelBytes: [UInt8]

    init(image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB),
           let bitmapContext = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            bitmapContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        pixelBytes = bytes
    }

    /// Hue 300±15°, saturation ≥ 0.6, value ≥ 0.5.
    func isMagenta(x pixelX: Int, y pixelY: Int) -> Bool {
        let byteIndex = (pixelY * width + pixelX) * 4
        let red = Double(pixelBytes[byteIndex]) / 255
        let green = Double(pixelBytes[byteIndex + 1]) / 255
        let blue = Double(pixelBytes[byteIndex + 2]) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let chroma = maximum - minimum
        guard maximum >= 0.5, maximum > 0, chroma / maximum >= 0.6 else { return false }
        var hue: Double
        if maximum == red {
            hue = 60 * ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hue = 60 * ((blue - red) / chroma + 2)
        } else {
            hue = 60 * ((red - green) / chroma + 4)
        }
        if hue < 0 { hue += 360 }
        return abs(hue - 300) <= 15
    }

    /// Centroid (pixel-index coordinates) of magenta pixels within `radius`.
    func magentaCentroid(around centre: CGPoint, radius: CGFloat) -> CGPoint? {
        let minimumX = max(0, Int((centre.x - radius).rounded(.down)))
        let maximumX = min(width - 1, Int((centre.x + radius).rounded(.up)))
        let minimumY = max(0, Int((centre.y - radius).rounded(.down)))
        let maximumY = min(height - 1, Int((centre.y + radius).rounded(.up)))
        guard minimumX <= maximumX, minimumY <= maximumY else { return nil }
        var sumX = 0.0, sumY = 0.0, count = 0.0
        for pixelY in minimumY...maximumY {
            for pixelX in minimumX...maximumX where isMagenta(x: pixelX, y: pixelY) {
                sumX += Double(pixelX)
                sumY += Double(pixelY)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return CGPoint(x: sumX / count, y: sumY / count)
    }

    /// Fraction of magenta pixels inside a pixel rect.
    func magentaFraction(in pixelRect: CGRect) -> Double {
        let minimumX = max(0, Int(pixelRect.minX.rounded()))
        let maximumX = min(width - 1, Int(pixelRect.maxX.rounded()) - 1)
        let minimumY = max(0, Int(pixelRect.minY.rounded()))
        let maximumY = min(height - 1, Int(pixelRect.maxY.rounded()) - 1)
        guard minimumX <= maximumX, minimumY <= maximumY else { return 0 }
        var magentaCount = 0
        var totalCount = 0
        for pixelY in minimumY...maximumY {
            for pixelX in minimumX...maximumX {
                totalCount += 1
                if isMagenta(x: pixelX, y: pixelY) { magentaCount += 1 }
            }
        }
        return totalCount > 0 ? Double(magentaCount) / Double(totalCount) : 0
    }
}
