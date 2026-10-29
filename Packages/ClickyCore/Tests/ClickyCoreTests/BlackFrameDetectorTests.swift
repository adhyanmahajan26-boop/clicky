import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// Turns 20261025-161115-e20dbed3 / -161147-ebba28af: wallpaper and widgets
// captured fine, every app window solid black.

/// A 8x-downsampled grey image (native 1600x800 → 200x100) with a
/// textured "wallpaper" and the given native rects painted.
private func grayImage(paint: [(rect: CGRect, fill: (Int, Int) -> UInt8)]) -> GrayImage {
    let width = 200, height = 100
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width { pixels[y * width + x] = UInt8(60 + (x * 7 + y * 13) % 120) }
    }
    for (rect, fill) in paint {
        for y in Int(rect.minY / 8)..<Int(rect.maxY / 8) {
            for x in Int(rect.minX / 8)..<Int(rect.maxX / 8) { pixels[y * width + x] = fill(x, y) }
        }
    }
    return GrayImage(width: width, height: height, pixels: pixels, nativePixelsPerPixel: 8)
}

private let black: (Int, Int) -> UInt8 = { x, y in UInt8((x + y) % 3 == 0 ? 2 : 1) }
private let page: (Int, Int) -> UInt8 = { x, y in y % 4 == 0 ? 40 : 245 }
private let darkTerminal: (Int, Int) -> UInt8 = { x, y in (y % 3 == 0 && x % 2 == 0) ? 200 : 20 }

private let browserWindow = CGRect(x: 160, y: 80, width: 960, height: 640)
private let editorWindow = CGRect(x: 800, y: 160, width: 720, height: 560)

@Test func everyWindowBlackOverAFineWallpaperIsABlackFrame() {
    let image = grayImage(paint: [(editorWindow, black), (browserWindow, black)])

    let verdict = BlackFrameDetector.analyze(gray: image, windowRectsNativePx: [browserWindow, editorWindow])

    #expect(verdict.judgedWindowCount == 2)
    #expect(verdict.blackWindowCount == 2)
    #expect(verdict.isBlackFrame)
}

@Test func normalWindowsAreNotABlackFrame() {
    let image = grayImage(paint: [(editorWindow, page), (browserWindow, page)])

    let verdict = BlackFrameDetector.analyze(gray: image, windowRectsNativePx: [browserWindow, editorWindow])

    #expect(verdict.blackWindowCount == 0)
    #expect(!verdict.isBlackFrame)
}

@Test func aDarkTerminalWithTextIsNotBlack() {
    let image = grayImage(paint: [(browserWindow, darkTerminal)])

    #expect(!BlackFrameDetector.analyze(gray: image, windowRectsNativePx: [browserWindow]).isBlackFrame)
}

@Test func oneSmallBlackWindowAmongNormalOnesIsNotABlackFrame() {
    let smallVideo = CGRect(x: 1200, y: 40, width: 240, height: 160)
    let image = grayImage(paint: [(browserWindow, page), (smallVideo, black)])

    let verdict = BlackFrameDetector.analyze(gray: image, windowRectsNativePx: [smallVideo, browserWindow])

    #expect(verdict.blackWindowCount == 1)
    #expect(verdict.blackFraction < 0.6)
    #expect(!verdict.isBlackFrame)
}

@Test func aCoveredWindowIsJudgedOnlyOnItsVisiblePart() {
    // The browser (front) is black; the editor behind shows a normal strip
    // to the right of it. Most of the visible window area is black.
    let image = grayImage(paint: [(editorWindow, page), (browserWindow, black)])

    let verdict = BlackFrameDetector.analyze(gray: image, windowRectsNativePx: [browserWindow, editorWindow])

    #expect(verdict.blackWindowCount == 1)
    #expect(verdict.blackFraction > 0.6)
    #expect(verdict.isBlackFrame)
}

@Test func noWindowsMeansNoVerdict() {
    let image = grayImage(paint: [])

    #expect(!BlackFrameDetector.analyze(gray: image, windowRectsNativePx: []).isBlackFrame)
    #expect(!BlackFrameDetector.analyze(gray: image, windowRectsNativePx: [CGRect(x: 0, y: 0, width: 16, height: 16)]).isBlackFrame)
}

@Test func verdictsAddUpAcrossScreens() {
    let blackScreen = BlackFrameDetector.analyze(gray: grayImage(paint: [(browserWindow, black)]), windowRectsNativePx: [browserWindow])
    let normalScreen = BlackFrameDetector.analyze(gray: grayImage(paint: [(editorWindow, page)]), windowRectsNativePx: [editorWindow])

    let combined = blackScreen + normalScreen

    #expect(combined.judgedWindowCount == 2)
    #expect(combined.blackWindowCount == 1)
    #expect(combined.isBlackFrame == (combined.blackFraction >= 0.6))
}

@Test func windowRectsComeFromLayerZeroWindowsOnTheCapture() {
    let display = DisplayInfo(displayID: 1, localizedName: "Main", boundsCG: CGRect(x: 0, y: 0, width: 800, height: 400),
                              visibleCG: CGRect(x: 0, y: 0, width: 800, height: 400), frameAppKit: CGRect(x: 0, y: 0, width: 800, height: 400), isMain: true)
    let frame = CaptureFrame(display: display, screenNumber: 1, native: PixelSize(width: 1600, height: 800), model: PixelSize(width: 1600, height: 800))
    let windows = [
        WindowInfo(windowID: 1, processIdentifier: 10, layer: 0, boundsCG: CGRect(x: 80, y: 40, width: 480, height: 320), alpha: 1, ownerName: "Chrome", title: nil),
        WindowInfo(windowID: 2, processIdentifier: 11, layer: 25, boundsCG: CGRect(x: 0, y: 0, width: 800, height: 24), alpha: 1, ownerName: "Menubar", title: nil),
        WindowInfo(windowID: 3, processIdentifier: 99, layer: 0, boundsCG: CGRect(x: 0, y: 0, width: 300, height: 300), alpha: 1, ownerName: "Clicky", title: nil),
        WindowInfo(windowID: 4, processIdentifier: 12, layer: 0, boundsCG: CGRect(x: 900, y: 0, width: 300, height: 300), alpha: 1, ownerName: "Other screen", title: nil),
    ]
    let stack = WindowStack(windows: windows, ownProcessIdentifier: 99, displays: [display])

    let rects = BlackFrameDetector.windowRectsNativePx(windowStack: stack, frame: frame)

    #expect(rects == [CGRect(x: 160, y: 80, width: 960, height: 640)])
}

// MARK: - Per display (turn 20261025-165737-d8803941)

@Test func oneBlackDisplayAmongFineOnesIsABlackFrame() {
    // Main display: every window black. Two side displays (more native
    // pixels each) fine. Summed, under 60 % of the window area is black,
    // which is why no retry fired; per display it is a black frame.
    let blackMain = BlackFrameDetector.analyze(gray: grayImage(paint: [(browserWindow, black)]), windowRectsNativePx: [browserWindow])
    let fineLeft = BlackFrameDetector.analyze(gray: grayImage(paint: [(CGRect(x: 0, y: 0, width: 1600, height: 800), page)]),
                                              windowRectsNativePx: [CGRect(x: 0, y: 0, width: 1600, height: 800)])
    let fineRight = BlackFrameDetector.analyze(gray: grayImage(paint: [(CGRect(x: 0, y: 0, width: 1600, height: 800), page)]),
                                               windowRectsNativePx: [CGRect(x: 0, y: 0, width: 1600, height: 800)])
    #expect(!(blackMain + fineLeft + fineRight).isBlackFrame)

    let frameVerdict = BlackFrameDetector.FrameVerdict(displayVerdicts: [blackMain, fineLeft, fineRight])

    #expect(frameVerdict.isBlackFrame)
    #expect(frameVerdict.blackDisplayCount == 1)
    #expect(frameVerdict.summary == blackMain)
    #expect(!frameVerdict.hasNoAppWindows)
}

@Test func frameVerdictWithoutWindowsOrBlackIsFine() {
    let fine = BlackFrameDetector.analyze(gray: grayImage(paint: [(browserWindow, page)]), windowRectsNativePx: [browserWindow])
    #expect(!BlackFrameDetector.FrameVerdict(displayVerdicts: [fine, .empty]).isBlackFrame)
    #expect(BlackFrameDetector.FrameVerdict(displayVerdicts: [.empty, .empty]).hasNoAppWindows)
    #expect(!BlackFrameDetector.FrameVerdict(displayVerdicts: [fine]).hasNoAppWindows)
}

private func cgWindow(pid: Int32, layer: Int, bounds: CGRect, alpha: Double = 1) -> [String: Any] {
    [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer),
     kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary, kCGWindowAlpha as String: NSNumber(value: alpha),
     kCGWindowOwnerName as String: "App \(pid)"]
}

@Test func windowRectsComeFromTheCGWindowList() {
    let mainDisplay = CGRect(x: 0, y: 0, width: 3440, height: 1440)
    let list: [[String: Any]] = [
        cgWindow(pid: 10, layer: 0, bounds: CGRect(x: 100, y: 50, width: 1200, height: 800)),
        cgWindow(pid: 11, layer: 25, bounds: CGRect(x: 0, y: 0, width: 3440, height: 24)),      // menu bar
        cgWindow(pid: 99, layer: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 400)),       // Clicky
        cgWindow(pid: 12, layer: 0, bounds: CGRect(x: 200, y: 200, width: 600, height: 400), alpha: 0),
        cgWindow(pid: 13, layer: 0, bounds: CGRect(x: 3300, y: 100, width: 600, height: 400)),  // straddles: clipped
        cgWindow(pid: 14, layer: 0, bounds: CGRect(x: -1920, y: 155, width: 1920, height: 1080)), // other display
        cgWindow(pid: 15, layer: 0, bounds: CGRect(x: 10, y: 10, width: 30, height: 30)),       // too small
        [kCGWindowLayer as String: NSNumber(value: 0)],                                          // malformed
    ]

    let rects = BlackFrameDetector.windowRectsCG(fromWindowList: list, ownProcessIdentifier: 99, displayBoundsCG: mainDisplay)

    #expect(rects == [CGRect(x: 100, y: 50, width: 1200, height: 800), CGRect(x: 3300, y: 100, width: 140, height: 400)])
}

@Test func cgWindowRectsMapToTheCapturesNativePixels() {
    let display = DisplayInfo(displayID: 1, localizedName: "Main", boundsCG: CGRect(x: 0, y: 0, width: 800, height: 400),
                              visibleCG: CGRect(x: 0, y: 0, width: 800, height: 400), frameAppKit: CGRect(x: 0, y: 0, width: 800, height: 400), isMain: true)
    let frame = CaptureFrame(display: display, screenNumber: 1, native: PixelSize(width: 1600, height: 800), model: PixelSize(width: 1600, height: 800))

    let rects = BlackFrameDetector.windowRectsNativePx(windowRectsCG: [CGRect(x: 80, y: 40, width: 480, height: 320),
                                                                      CGRect(x: 900, y: 0, width: 100, height: 100)], frame: frame)

    #expect(rects == [CGRect(x: 160, y: 80, width: 960, height: 640)])
}

// MARK: - Capture warm-up

private let warmUpStart = Date(timeIntervalSince1970: 5_000)

@Test func warmUpCapturesUntilAFrameIsGood() {
    var warmUp = CaptureWarmUp()
    #expect(warmUp.nextStep(at: warmUpStart) == .done)
    warmUp.start(at: warmUpStart)
    #expect(warmUp.isRunning)
    #expect(warmUp.nextStep(at: warmUpStart) == .wait(seconds: CaptureWarmUp.initialDelay))
    let first = warmUpStart.addingTimeInterval(CaptureWarmUp.initialDelay)
    #expect(warmUp.nextStep(at: first) == .captureNow)
    warmUp.record(.black, at: first)
    #expect(warmUp.nextStep(at: first.addingTimeInterval(1)) == .wait(seconds: CaptureWarmUp.attemptInterval - 1))
    let second = first.addingTimeInterval(CaptureWarmUp.attemptInterval)
    #expect(warmUp.nextStep(at: second) == .captureNow)
    warmUp.record(.good, at: second)
    #expect(!warmUp.isRunning)
    #expect(warmUp.phase == .finished(.good(attempts: 2)))
    #expect(warmUp.nextStep(at: second) == .done)
    #expect(warmUp.description == "good after 2 attempts")
}

@Test func warmUpStopsWhenThereIsNothingToJudge() {
    var warmUp = CaptureWarmUp()
    warmUp.start(at: warmUpStart)
    warmUp.record(.noAppWindows, at: warmUpStart.addingTimeInterval(0.5))
    #expect(warmUp.phase == .finished(.noAppWindows(attempts: 1)))
}

@Test func warmUpGivesUpAfterThirtySeconds() {
    var warmUp = CaptureWarmUp()
    warmUp.start(at: warmUpStart)
    var clock = warmUpStart
    var attempts = 0
    while case .running = warmUp.phase, attempts < 100 {
        if case .wait(let seconds) = warmUp.nextStep(at: clock) { clock = clock.addingTimeInterval(seconds) }
        #expect(warmUp.nextStep(at: clock) == .captureNow)
        warmUp.record(attempts % 2 == 0 ? .black : .failed, at: clock)
        attempts += 1
    }
    #expect(clock.timeIntervalSince(warmUpStart) <= CaptureWarmUp.maximumDuration)
    #expect(warmUp.phase == .finished(.gaveUp(attempts: attempts)))
    #expect(attempts == 20) // 0.5 s, then every 1.5 s up to 29 s
}

@Test func warmUpRestartsOnADisplayChange() {
    var warmUp = CaptureWarmUp()
    warmUp.start(at: warmUpStart)
    warmUp.record(.good, at: warmUpStart.addingTimeInterval(0.5))
    let later = warmUpStart.addingTimeInterval(600)
    warmUp.start(at: later)
    #expect(warmUp.isRunning)
    #expect(warmUp.nextStep(at: later) == .wait(seconds: CaptureWarmUp.initialDelay))
    // Recording when not running is ignored.
    var idle = CaptureWarmUp()
    idle.record(.good, at: later)
    #expect(idle.phase == .idle)
}
