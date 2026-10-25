import CoreGraphics
import Testing
@testable import ClickyCore

private func makeDisplay(boundsCG: CGRect, isMain: Bool) -> DisplayInfo {
    DisplayInfo(
        displayID: isMain ? 1 : 2,
        localizedName: isMain ? "Main" : "Left",
        boundsCG: boundsCG,
        visibleCG: boundsCG,
        frameAppKit: boundsCG,
        isMain: isMain
    )
}

private let mainBounds = CGRect(x: 0, y: 0, width: 3440, height: 1440)
private let leftBounds = CGRect(x: -1920, y: 155, width: 1920, height: 1080)

/// A capture frame for one display, optionally cropped to `regionCG`.
private func makeFrame(
    bounds: CGRect,
    isMain: Bool,
    regionCG: CGRect? = nil,
    native: PixelSize,
    model: PixelSize?
) -> CaptureFrame {
    CaptureFrame(
        display: makeDisplay(boundsCG: bounds, isMain: isMain),
        screenNumber: 1,
        regionCG: regionCG,
        native: native,
        model: model
    )
}

private func assertNear(_ actual: CGPoint, _ expected: CGPoint, tolerance: CGFloat = 1e-6, _ comment: String = "") {
    #expect(abs(actual.x - expected.x) <= tolerance, "x: \(actual.x) vs \(expected.x) \(comment)")
    #expect(abs(actual.y - expected.y) <= tolerance, "y: \(actual.y) vs \(expected.y) \(comment)")
}

/// The frames the brief calls out: (name, frame) pairs covering 1x and 2x displays,
/// model sizes that are both smaller than native and absent.
private func representativeFrames() -> [(String, CaptureFrame)] {
    [
        ("main 2576x1078", makeFrame(bounds: mainBounds, isMain: true, native: PixelSize(width: 3440, height: 1440), model: PixelSize(width: 2576, height: 1078))),
        ("main 1568x656", makeFrame(bounds: mainBounds, isMain: true, native: PixelSize(width: 3440, height: 1440), model: PixelSize(width: 1568, height: 656))),
        ("left 1920x1080", makeFrame(bounds: leftBounds, isMain: false, native: PixelSize(width: 3840, height: 2160), model: PixelSize(width: 1920, height: 1080))),
        ("left 1456x819", makeFrame(bounds: leftBounds, isMain: false, native: PixelSize(width: 3840, height: 2160), model: PixelSize(width: 1456, height: 819))),
        ("left model nil", makeFrame(bounds: leftBounds, isMain: false, native: PixelSize(width: 3840, height: 2160), model: nil)),
    ]
}

@Test func modelPixelRoundTripsForPixelsInsideTheImage() {
    for (name, frame) in representativeFrames() {
        let size = frame.modelSize
        let stepX = max(1, size.width / 37)
        let stepY = max(1, size.height / 23)

        for x in stride(from: 0, to: size.width, by: stepX) {
            for y in stride(from: 0, to: size.height, by: stepY) {
                let pixel = CGPoint(x: CGFloat(x), y: CGFloat(y))
                assertNear(frame.modelPx(fromCG: frame.cg(fromModelPx: pixel)), pixel, name)

                let fractional = CGPoint(x: CGFloat(x) + 0.25, y: CGFloat(y) + 0.75)
                assertNear(frame.modelPx(fromCG: frame.cg(fromModelPx: fractional)), fractional, name)
            }
        }
    }
}

@Test func topLeftModelPixelMapsToTheCentreOfTheFirstCell() {
    for (name, frame) in representativeFrames() {
        let size = frame.modelSize
        let region = frame.regionCG
        let expected = CGPoint(
            x: region.minX + 0.5 * region.width / CGFloat(size.width),
            y: region.minY + 0.5 * region.height / CGFloat(size.height)
        )
        assertNear(frame.cg(fromModelPx: CGPoint(x: 0, y: 0)), expected, name)
    }
}

@Test func lastModelPixelMapsInsideTheRegion() {
    for (name, frame) in representativeFrames() {
        let size = frame.modelSize
        let point = frame.cg(fromModelPx: CGPoint(x: CGFloat(size.width - 1), y: CGFloat(size.height - 1)))
        #expect(frame.regionCG.contains(point), "\(name) last pixel \(point) escaped the region")
    }
}

@Test func outOfRangePixelsClampToTheFirstAndLastPixelCentres() {
    for (name, frame) in representativeFrames() {
        let size = frame.modelSize
        let first = frame.cg(fromModelPx: CGPoint(x: 0, y: 0))
        let last = frame.cg(fromModelPx: CGPoint(x: CGFloat(size.width - 1), y: CGFloat(size.height - 1)))

        assertNear(frame.cg(fromModelPx: CGPoint(x: -50, y: -50)), first, name)
        assertNear(frame.cg(fromModelPx: CGPoint(x: CGFloat(size.width + 100), y: CGFloat(size.height + 100))), last, name)
    }
}

@Test func centreOfTheMainScreenMapsNearTheExpectedPoint() {
    let frame = makeFrame(bounds: mainBounds, isMain: true, native: PixelSize(width: 3440, height: 1440), model: PixelSize(width: 2576, height: 1078))
    let point = frame.cg(fromModelPx: CGPoint(x: 1288, y: 539))

    #expect(abs(point.x - 1720) < 1)
    #expect(abs(point.y - 720) < 1)
}

@Test func leftHalfOfADisplayMapsInsideThatHalf() {
    let leftHalf = CGRect(x: -1920, y: 155, width: 960, height: 1080)
    let frame = makeFrame(bounds: leftBounds, isMain: false, regionCG: leftHalf, native: PixelSize(width: 1920, height: 1080), model: nil)

    for x in stride(from: 0, to: 1920, by: 97) {
        for y in stride(from: 0, to: 1080, by: 83) {
            let point = frame.cg(fromModelPx: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            #expect(leftHalf.contains(point), "pixel (\(x),\(y)) mapped to \(point), outside the left half")
        }
    }

    let centre = frame.cg(fromModelPx: CGPoint(x: 959.5, y: 539.5))
    #expect(abs(centre.x - leftHalf.midX) <= 1)
    #expect(abs(centre.y - leftHalf.midY) <= 1)
}

@Test func rightHalfOfADisplayMapsInsideThatHalf() {
    let rightHalf = CGRect(x: -960, y: 155, width: 960, height: 1080)
    let frame = makeFrame(bounds: leftBounds, isMain: false, regionCG: rightHalf, native: PixelSize(width: 1920, height: 1080), model: nil)

    for x in stride(from: 0, to: 1920, by: 97) {
        for y in stride(from: 0, to: 1080, by: 83) {
            let point = frame.cg(fromModelPx: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            #expect(rightHalf.contains(point), "pixel (\(x),\(y)) mapped to \(point), outside the right half")
        }
    }
}

@Test func topHalfOfADisplayMapsInsideThatHalf() {
    let topHalf = CGRect(x: 0, y: 0, width: 3440, height: 720)
    let frame = makeFrame(bounds: mainBounds, isMain: true, regionCG: topHalf, native: PixelSize(width: 3440, height: 720), model: nil)

    for x in stride(from: 0, to: 3440, by: 211) {
        for y in stride(from: 0, to: 720, by: 67) {
            let point = frame.cg(fromModelPx: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            #expect(topHalf.contains(point), "pixel (\(x),\(y)) mapped to \(point), outside the top half")
        }
    }

    let centre = frame.cg(fromModelPx: CGPoint(x: 1719.5, y: 359.5))
    #expect(abs(centre.x - topHalf.midX) <= 1)
    #expect(abs(centre.y - topHalf.midY) <= 1)
}
