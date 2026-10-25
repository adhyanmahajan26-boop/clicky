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
