//
//  HaikuZoomChecker.swift
//  leanring-buddy
//
//  P6.1 (v2.grounding.verifyWithHaiku, default off): asks Haiku whether a
//  tentative mark is on the right thing. Crops 3× the mark's padded target
//  (ZoomCheck.cropRect) at native scale with Clicky excluded (the production
//  capture filter), downsizes it to what the model sees, badges the
//  registry elements inside it, rings the target in orange and sends that
//  one PNG with one question to `claude -p --model haiku --max-turns 1`.
//  What the reply may change is decided by ZoomCheck.decide; AnswerSession
//  applies it if the user hasn't moved on.
//
//  P6.3: with the setting on, a Haiku process is pre-spawned at key-down
//  and respawned after each check while the answer runs, so a check only
//  pays for the request; the standby is reaped at the end of the turn.
//

import ClickyCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class HaikuZoomChecker {
    private let bridge = ClaudeCodeBridge(model: "haiku")
    /// Bumped for every new question; a check for an older one applies nothing.
    private(set) var questionNumber = 0

    struct Outcome {
        let replyText: String?
        let decision: ZoomCheck.Decision
        /// The crop as an image of the screen (x,y replies map through it).
        let frame: CaptureFrame?
    }

    var isEnabled: Bool { ClickySettings.isVerifyWithHaikuEnabled }

    func beginQuestion() {
        questionNumber += 1
    }

    /// Key-down / hands-free speech start, and after each check while marks are live.
    func prespawnStandbyIfEnabled() {
        guard isEnabled else { return }
        if bridge.standbySlot.currentProcess?.isHealthy == true { return }
        bridge.prespawnStandbyProcess(systemPromptFileName: ZoomCheck.systemPromptFileName, systemPrompt: ZoomCheck.systemPrompt,
                                      effortLevel: nil, maximumTurns: 1)
    }

    /// End of the turn (and the setting turned off).
    func reapStandby() {
        bridge.reapStandbyProcess()
    }

    /// One check: capture, render, ask, decide. `name` is what the mark is
    /// supposed to be on; `currentRectCG` where it is now.
    func check(name: String, currentRectCG: CGRect, registry: ElementRegistry, respawnsStandbyAfterwards: @escaping () -> Bool) async -> Outcome {
        let displays = ScreenTopology.current()
        guard let display = displays.first(where: { $0.boundsCG.contains(currentRectCG.center) }) else {
            return Outcome(replyText: nil, decision: .ignore(.failed), frame: nil)
        }
        let cropRect = ZoomCheck.cropRect(target: currentRectCG, displayBounds: display.boundsCG)
        guard let (nativeImage, regionCG) = try? await ScreenCaptureService.captureNativeImage(of: display, regionCG: cropRect, includesOwnWindows: false) else {
            print("🔍 Zoom check: crop capture failed")
            return Outcome(replyText: nil, decision: .ignore(.failed), frame: nil)
        }
        let nativeSize = PixelSize(width: nativeImage.width, height: nativeImage.height)
        let modelSize = ZoomCheck.modelImageSize(nativeSize: nativeSize)
        let frame = ZoomCheck.cropFrame(display: display, cropRegionCG: regionCG, nativeSize: nativeSize, modelSize: modelSize)
        let candidates = ZoomCheck.candidates(in: registry, cropCG: regionCG, displayID: display.displayID)

        let candidateRectsPx = Dictionary(uniqueKeysWithValues: candidates.map { ($0.elementID, frame.modelPxRect(fromCG: $0.frameCG)) })
        let ringRectPx = frame.modelPxRect(fromCG: ZoomCheck.paddedTarget(currentRectCG))
        let pngData: Data
        do {
            pngData = try await Task.detached(priority: .userInitiated) {
                let modelImage = try resizeToModelSize(nativeImage, modelSize: modelSize)
                let placements = BadgeLayout.place(
                    candidates: candidates.map { BadgeLayout.Candidate(elementID: $0.elementID, rectPx: candidateRectsPx[$0.elementID] ?? .zero) },
                    allElementRectsPx: Array(candidateRectsPx.values),
                    imageSize: modelSize.cgSize
                )
                guard let renderedImage = ZoomCheckRenderer.render(onto: modelImage, ringRectPx: ringRectPx, placements: placements,
                                                                   outlinedRectsPx: candidateRectsPx) else {
                    throw ScreenCaptureError(message: "Couldn't draw the zoom-check crop")
                }
                return try encodePNG(renderedImage)
            }.value
        } catch {
            print("🔍 Zoom check: render failed: \(error)")
            return Outcome(replyText: nil, decision: .ignore(.failed), frame: frame)
        }

        let replyText: String
        do {
            let haikuTurn = try await bridge.runTurn(
                systemPromptFileName: ZoomCheck.systemPromptFileName,
                systemPrompt: ZoomCheck.systemPrompt,
                contentBlocks: [.pngImage(pngData), .text(ZoomCheck.prompt(label: name))],
                maximumTurns: 1,
                allowsStandbyProcess: true
            )
            replyText = haikuTurn.text
        } catch {
            print("🔍 Zoom check: Haiku failed: \(error)")
            if respawnsStandbyAfterwards() { prespawnStandbyIfEnabled() }
            return Outcome(replyText: nil, decision: .ignore(.failed), frame: frame)
        }
        if respawnsStandbyAfterwards() { prespawnStandbyIfEnabled() }

        let decision = ZoomCheck.decide(replyText: replyText, markName: name, candidates: candidates, currentTargetCG: currentRectCG, frame: frame)
        print("🔍 Zoom check \"\(name)\": \(replyText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) → \(decision.action.rawValue)")
        return Outcome(replyText: replyText, decision: decision, frame: frame)
    }
}

/// PNG-encodes an image (lossless: the badges' digits stay sharp).
nonisolated func encodePNG(_ image: CGImage) throws -> Data {
    let pngData = NSMutableData()
    guard let imageDestination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else {
        throw ScreenCaptureError(message: "Couldn't create a PNG encoder")
    }
    CGImageDestinationAddImage(imageDestination, image, nil)
    guard CGImageDestinationFinalize(imageDestination) else {
        throw ScreenCaptureError(message: "PNG encoding failed")
    }
    return pngData as Data
}
