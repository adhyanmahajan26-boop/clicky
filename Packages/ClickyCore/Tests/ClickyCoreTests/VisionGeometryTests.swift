import CoreGraphics
import Testing
@testable import ClickyCore

private func makeFrame(bounds: CGRect, isMain: Bool, native: PixelSize) -> CaptureFrame {
    CaptureFrame(
        display: DisplayInfo(
            displayID: isMain ? 1 : 2,
            localizedName: isMain ? "Main" : "Left",
            boundsCG: bounds,
            visibleCG: bounds,
            frameAppKit: bounds,
            isMain: isMain
        ),
        screenNumber: 1,
        native: native,
        model: nil
    )
}

private func assertRectNear(_ actual: CGRect, _ expected: CGRect, tolerance: CGFloat = 1e-6, _ comment: String = "") {
    #expect(abs(actual.minX - expected.minX) <= tolerance, "minX \(actual) vs \(expected) \(comment)")
    #expect(abs(actual.minY - expected.minY) <= tolerance, "minY \(actual) vs \(expected) \(comment)")
    #expect(abs(actual.width - expected.width) <= tolerance, "width \(actual) vs \(expected) \(comment)")
    #expect(abs(actual.height - expected.height) <= tolerance, "height \(actual) vs \(expected) \(comment)")
}

@Test func visionBoxInsideACropMapsToCGWithBottomLeftFlipped() {
    let frame = makeFrame(
        bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440),
        isMain: true,
        native: PixelSize(width: 3440, height: 1440)
    )
    let crop = CGRect(x: 1000, y: 200, width: 400, height: 300)
    let box = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)

    // Native x: 1000 + 0.25 * 400 = 1100. Native y: 200 + (1 - 0.75) * 300 = 275.
    assertRectNear(frame.cgRect(visionBox: box, cropPx: crop), CGRect(x: 1100, y: 275, width: 200, height: 75))
}

@Test func fullVisionBoxMapsToTheWholeCrop() {
    let frame = makeFrame(
        bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440),
        isMain: true,
        native: PixelSize(width: 3440, height: 1440)
    )
    let crop = CGRect(x: 1000, y: 200, width: 400, height: 300)

    assertRectNear(frame.cgRect(visionBox: CGRect(x: 0, y: 0, width: 1, height: 1), cropPx: crop), crop)
}

@Test func fullVisionBoxOnA2xDisplayMapsToTheDisplayBounds() {
    let bounds = CGRect(x: -1920, y: 155, width: 1920, height: 1080)
    let frame = makeFrame(bounds: bounds, isMain: false, native: PixelSize(width: 3840, height: 2160))
    let crop = CGRect(x: 0, y: 0, width: 3840, height: 2160)

    assertRectNear(frame.cgRect(visionBox: CGRect(x: 0, y: 0, width: 1, height: 1), cropPx: crop), bounds)
}
