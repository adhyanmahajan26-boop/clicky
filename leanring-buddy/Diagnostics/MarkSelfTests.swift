//
//  MarkSelfTests.swift
//  leanring-buddy
//
//  P1c live self-tests (debug inbox `selftest`). They draw on screen, so
//  they only run when nobody is using the Mac:
//   - recheckExclusion: a Clicky label "Zebra 4821" over an empty part of
//     the fixture's canvas must NOT be found by the OCR re-check (Clicky's
//     windows are excluded from the capture); a real canvas string must be
//     found within 6 pt.
//   - markRoundTrip: a ring on every display, captured with Clicky's own
//     windows included; the orange within ±20 pt of each ring must centre on
//     the ring's planned centre within 2 native px. The companion is parked
//     away first (it's the same orange).
//

import AppKit
import ClickyCore
import SwiftUI

@MainActor
enum MarkSelfTests {
    static func run(named selfTestName: String, companionManager: CompanionManager) async -> (Bool, [String: Any]) {
        switch selfTestName {
        case "recheckExclusion": return await runRecheckExclusion()
        case "markRoundTrip": return await runMarkRoundTrip(companionManager: companionManager)
        default: return (false, ["error": "unknown mark self-test \(selfTestName)"])
        }
    }

    // MARK: - recheckExclusion

    static func runRecheckExclusion() async -> (Bool, [String: Any]) {
        guard let groundTruth = GroundingSelfTests.readFixtureGroundTruth(),
              let display = ScreenTopology.current().first(where: { $0.displayID == groundTruth.displayID }),
              let canvasTotal = groundTruth.items.first(where: { $0.key == "canvas_total" })?.frameCG else {
            return (false, ["error": "needs a ready fixture (canvas_total)"])
        }
        // Empty canvas below the canvas strings.
        let decoyRect = CGRect(x: canvasTotal.minX, y: canvasTotal.minY + 360, width: 170, height: 30)
        let decoyWindow = LabelDecoyWindow(text: "Zebra 4821", rectCG: decoyRect)
        decoyWindow.orderFrontRegardless()
        defer { decoyWindow.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 400_000_000)

        let decoyOutcome = await MarkRecheck.run(name: "Zebra 4821", target: decoyRect, display: display)
        let realOutcome = await MarkRecheck.run(name: "Total: 1,284", target: canvasTotal, display: display)
        let realOffset = realOutcome.foundFrameCG.map { hypot($0.midX - canvasTotal.midX, $0.midY - canvasTotal.midY) }
        let isPassing = !decoyOutcome.isPassing && realOutcome.isPassing && (realOffset ?? .infinity) <= 6
        return (isPassing, [
            "decoyFound": decoyOutcome.isPassing,
            "decoyMs": decoyOutcome.milliseconds.rounded(),
            "realFound": realOutcome.isPassing,
            "realOffsetPt": realOffset.map { (Double($0) * 10).rounded() / 10 } as Any,
            "realMs": realOutcome.milliseconds.rounded()
        ])
    }

    // MARK: - markRoundTrip

    static func runMarkRoundTrip(companionManager: CompanionManager) async -> (Bool, [String: Any]) {
        let displays = ScreenTopology.current()
        let targetsByDisplay = Dictionary(uniqueKeysWithValues: displays.map { display in
            (display.displayID, CGRect(x: display.boundsCG.midX - 40, y: display.boundsCG.midY - 15, width: 80, height: 30))
        })
        // Park the companion in a far corner of the main display's visible area.
        if let mainDisplay = displays.first(where: \.isMain) {
            let parkingSpot = CGPoint(x: mainDisplay.visibleCG.minX + 30, y: mainDisplay.visibleCG.maxY - 30)
            companionManager.detectedElementScreenLocation = ScreenTopology.appKit(fromCG: parkingSpot, flipH: ScreenTopology.mainDisplayHeight)
            companionManager.detectedElementDisplayFrame = mainDisplay.frameAppKit
        }
        defer {
            companionManager.clearLiveScreenMarks()
            companionManager.clearDetectedElementLocation()
        }
        let marks = displays.enumerated().compactMap { index, display -> LiveScreenMark? in
            guard let target = targetsByDisplay[display.displayID] else { return nil }
            return LiveScreenMark(style: .circle, rectCG: target, displayText: nil, source: .raw, ax: nil, confidence: 1, isTentative: false,
                                  createdAt: Date(), windowID: nil, windowFrameCG: nil, clipAX: nil, labelAX: nil, originalLabel: nil,
                                  recheckName: nil, order: index, tagIndex: nil)
        }
        companionManager.markController.show(marks, turnRecord: nil)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        var isPassing = true
        var perDisplayResults: [[String: Any]] = []
        for display in displays {
            guard let target = targetsByDisplay[display.displayID] else { continue }
            let ring = MarkLayout.ring(target: target, display: display.boundsCG)
            do {
                let (nativeImage, regionCG) = try await ScreenCaptureService.captureNativeImage(of: display, includesOwnWindows: true)
                let frame = CaptureFrame(display: display, screenNumber: 0, regionCG: regionCG,
                                         native: PixelSize(width: nativeImage.width, height: nativeImage.height), model: nil)
                let searchRectCG = ring.rect.insetBy(dx: -20, dy: -20)
                let searchTopLeft = frame.nativePx(fromCG: searchRectCG.origin)
                let searchBottomRight = frame.nativePx(fromCG: CGPoint(x: searchRectCG.maxX, y: searchRectCG.maxY))
                let searchRect = CGRect(x: searchTopLeft.x, y: searchTopLeft.y,
                                        width: searchBottomRight.x - searchTopLeft.x, height: searchBottomRight.y - searchTopLeft.y)
                guard let centroid = orangeCentroid(in: nativeImage, within: searchRect) else {
                    isPassing = false
                    perDisplayResults.append(["displayID": Int(display.displayID), "error": "no orange near the ring"])
                    continue
                }
                let expected = frame.nativePx(fromCG: ring.rect.center)
                let errorPx = hypot(Double(centroid.x - expected.x), Double(centroid.y - expected.y))
                if errorPx > 2 { isPassing = false }
                perDisplayResults.append(["displayID": Int(display.displayID), "ringKind": ring.kind.rawValue,
                                          "centroidErrorNativePx": (errorPx * 100).rounded() / 100])
            } catch {
                isPassing = false
                perDisplayResults.append(["displayID": Int(display.displayID), "error": String(describing: error)])
            }
        }
        return (isPassing, ["maxAllowedNativePx": 2, "displays": perDisplayResults])
    }

    /// Centroid of mark-orange pixels (0.85, 0.47, 0.34 ± tolerance) in a native-pixel rect.
    static func orangeCentroid(in image: CGImage, within rectPx: CGRect) -> CGPoint? {
        let clippedRect = rectPx.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clippedRect.isNull, clippedRect.width > 0, clippedRect.height > 0, let croppedImage = image.cropping(to: clippedRect) else { return nil }
        let width = croppedImage.width
        let height = croppedImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sumX = 0.0, sumY = 0.0, count = 0.0
        for pixelY in 0..<height {
            for pixelX in 0..<width {
                let offset = (pixelY * width + pixelX) * 4
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                if abs(red - 217) < 28 && abs(green - 120) < 28 && abs(blue - 87) < 28 {
                    sumX += Double(pixelX) + 0.5
                    sumY += Double(pixelY) + 0.5
                    count += 1
                }
            }
        }
        guard count > 20 else { return nil }
        return CGPoint(x: clippedRect.minX + sumX / count, y: clippedRect.minY + sumY / count)
    }
}

/// A Clicky-owned window that looks like a mark label (orange pill, white text).
private final class LabelDecoyWindow: NSWindow {
    init(text: String, rectCG: CGRect) {
        let frameAppKit = ScreenTopology.appKit(fromCG: rectCG, flipH: ScreenTopology.mainDisplayHeight)
        super.init(contentRect: frameAppKit, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView:
            Text(text)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: rectCG.width, height: rectCG.height)
                .background(RoundedRectangle(cornerRadius: 8).fill(MarkPalette.orange))
        )
    }
}
