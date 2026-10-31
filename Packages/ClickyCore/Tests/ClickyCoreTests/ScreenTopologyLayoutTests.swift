import CoreGraphics
import Testing
@testable import ClickyCore

/// Deterministic linear congruential generator so randomised layouts are repeatable.
private struct LayoutGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int((state >> 33) % span)
    }

    mutating func nextCGFloat(in range: ClosedRange<Int>) -> CGFloat {
        CGFloat(nextInt(in: range))
    }

    mutating func nextRect() -> CGRect {
        CGRect(
            x: nextCGFloat(in: -8000...8000),
            y: nextCGFloat(in: -4000...4000),
            width: nextCGFloat(in: 300...6000),
            height: nextCGFloat(in: 300...6000)
        )
    }
}

private func makeDisplay(id: CGDirectDisplayID, boundsCG: CGRect, frameAppKit: CGRect, isMain: Bool = false) -> DisplayInfo {
    DisplayInfo(
        displayID: id,
        localizedName: "Display \(id)",
        boundsCG: boundsCG,
        visibleCG: boundsCG,
        frameAppKit: frameAppKit,
        isMain: isMain
    )
}

/// Addy's real layout: a 3440x1440 main display, a 4K display to the left
/// and a 4K display to the right, both sitting at different vertical offsets.
private enum AddyLayout {
    static let flipH: CGFloat = 1440
    static let main = makeDisplay(
        id: 1,
        boundsCG: CGRect(x: 0, y: 0, width: 3440, height: 1440),
        frameAppKit: CGRect(x: 0, y: 0, width: 3440, height: 1440),
        isMain: true
    )
    static let left = makeDisplay(
        id: 2,
        boundsCG: CGRect(x: -1920, y: 155, width: 1920, height: 1080),
        frameAppKit: CGRect(x: -1920, y: 205, width: 1920, height: 1080)
    )
    static let right = makeDisplay(
        id: 3,
        boundsCG: CGRect(x: 3440, y: 198, width: 1920, height: 1080),
        frameAppKit: CGRect(x: 3440, y: 162, width: 1920, height: 1080)
    )
}

// MARK: - Point and rect conversions

@Test func pointConversionFlipsYAroundTheMainDisplayHeight() {
    let appKit = CGPoint(x: 100, y: 200)
    let cg = ScreenTopology.cg(fromAppKit: appKit, flipH: 1440)

    #expect(cg == CGPoint(x: 100, y: 1240))
    #expect(ScreenTopology.appKit(fromCG: cg, flipH: 1440) == appKit)
}

@Test func rectConversionUsesTheTopEdgeOfTheAppKitRect() {
    // AppKit top edge is maxY = 420, so the CG top edge is 1000 - 420 = 580.
    let appKit = CGRect(x: 10, y: 20, width: 300, height: 400)
    let cg = ScreenTopology.cg(fromAppKit: appKit, flipH: 1000)

    #expect(cg == CGRect(x: 10, y: 580, width: 300, height: 400))
    #expect(ScreenTopology.appKit(fromCG: cg, flipH: 1000) == appKit)
}

@Test func overlayLocalPointIsRelativeToTheDisplayOrigin() {
    let local = ScreenTopology.overlayLocal(
        fromCG: CGPoint(x: 1720, y: 720),
        displayBoundsCG: CGRect(x: -1920, y: 155, width: 1920, height: 1080)
    )
    #expect(local == CGPoint(x: 3640, y: 565))
}

@Test func randomLayoutsRoundTripPointsAndRectsExactly() {
    var generator = LayoutGenerator(seed: 7)

    for _ in 0..<1000 {
        let flipH = generator.nextCGFloat(in: 600...3000)
        let point = CGPoint(x: generator.nextCGFloat(in: -8000...8000), y: generator.nextCGFloat(in: -4000...4000))
        let roundTripPoint = ScreenTopology.appKit(
            fromCG: ScreenTopology.cg(fromAppKit: point, flipH: flipH),
            flipH: flipH
        )
        #expect(abs(roundTripPoint.x - point.x) <= 0.5)
        #expect(abs(roundTripPoint.y - point.y) <= 0.5)

        let rect = generator.nextRect()
        let roundTripRect = ScreenTopology.appKit(
            fromCG: ScreenTopology.cg(fromAppKit: rect, flipH: flipH),
            flipH: flipH
        )
        #expect(abs(roundTripRect.minX - rect.minX) <= 0.5)
        #expect(abs(roundTripRect.minY - rect.minY) <= 0.5)
        #expect(abs(roundTripRect.width - rect.width) <= 0.5)
        #expect(abs(roundTripRect.height - rect.height) <= 0.5)
    }
}

// MARK: - Display layout

@Test func addysConsistentLayoutHasNoFlipDisagreements() {
    let displays = [AddyLayout.main, AddyLayout.left, AddyLayout.right]
    #expect(ScreenTopology.flipDisagreements(displays: displays, flipH: AddyLayout.flipH).isEmpty)
}

@Test func flipDisagreementsReportsADisplayOffByOnePoint() {
    let offByOne = makeDisplay(
        id: 3,
        boundsCG: CGRect(x: 3440, y: 198, width: 1920, height: 1080),
        frameAppKit: CGRect(x: 3440, y: 163, width: 1920, height: 1080)
    )
    let displays = [AddyLayout.main, AddyLayout.left, offByOne]

    #expect(ScreenTopology.flipDisagreements(displays: displays, flipH: AddyLayout.flipH) == [3])
}

@Test func randomConsistentDisplayLayoutsHaveNoFlipDisagreements() {
    var generator = LayoutGenerator(seed: 1234)

    for _ in 0..<1000 {
        let flipH = generator.nextCGFloat(in: 600...3000)
        let displayCount = generator.nextInt(in: 1...3)
        let displays = (0..<displayCount).map { index in
            let bounds = generator.nextRect()
            return makeDisplay(
                id: CGDirectDisplayID(index + 1),
                boundsCG: bounds,
                frameAppKit: ScreenTopology.appKit(fromCG: bounds, flipH: flipH),
                isMain: index == 0
            )
        }
        #expect(ScreenTopology.flipDisagreements(displays: displays, flipH: flipH).isEmpty)
    }
}

@Test func positionDescriptionNamesEachSideOfTheMainDisplay() {
    let mainBounds = AddyLayout.main.boundsCG

    #expect(AddyLayout.main.positionDescription(relativeTo: mainBounds) == "main")
    #expect(AddyLayout.left.positionDescription(relativeTo: mainBounds) == "left of main")
    #expect(AddyLayout.right.positionDescription(relativeTo: mainBounds) == "right of main")

    let above = makeDisplay(
        id: 4,
        boundsCG: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        frameAppKit: CGRect(x: 0, y: 1440, width: 1920, height: 1080)
    )
    #expect(above.positionDescription(relativeTo: mainBounds) == "above main")

    let below = makeDisplay(
        id: 5,
        boundsCG: CGRect(x: 0, y: 1440, width: 1920, height: 1080),
        frameAppKit: CGRect(x: 0, y: -1080, width: 1920, height: 1080)
    )
    #expect(below.positionDescription(relativeTo: mainBounds) == "below main")
}

// MARK: - Pixel density

@Test func pixelsPerPointIsMeasuredFromTheImage() {
    #expect(ScreenTopology.pixelsPerPoint(nativeWidthInPixels: 3840, regionWidthInPoints: 1920) == 2)
    #expect(ScreenTopology.pixelsPerPoint(nativeWidthInPixels: 3440, regionWidthInPoints: 3440) == 1)
    #expect(abs(ScreenTopology.pixelsPerPoint(nativeWidthInPixels: 2576, regionWidthInPoints: 3440) - 0.7488) < 1e-3)
}
