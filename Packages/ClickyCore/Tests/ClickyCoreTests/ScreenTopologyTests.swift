import CoreGraphics
import Testing
@testable import ClickyCore

/// Addy's real layout in AppKit coordinates: main ultrawide 3440x1440 at the
/// origin, plus a 1920x1080 display to the left (negative x) and one above.
private let mainDisplayHeight: CGFloat = 1440
private let appKitDisplayFrames: [CGRect] = [
    CGRect(x: 0, y: 0, width: 3440, height: 1440),
    CGRect(x: -1920, y: 180, width: 1920, height: 1080),
    CGRect(x: 760, y: 1440, width: 1920, height: 1080)
]

@Test func pointFlipRoundTripsWithinAHundredthOfAPoint() {
    for displayFrame in appKitDisplayFrames {
        for appKitPoint in [
            CGPoint(x: displayFrame.minX, y: displayFrame.minY),
            CGPoint(x: displayFrame.midX + 0.37, y: displayFrame.midY - 0.61),
            CGPoint(x: displayFrame.maxX - 1, y: displayFrame.maxY - 1)
        ] {
            let cgPoint = ScreenTopology.cg(fromAppKit: appKitPoint, flipH: mainDisplayHeight)
            let roundTripped = ScreenTopology.appKit(fromCG: cgPoint, flipH: mainDisplayHeight)
            #expect(abs(roundTripped.x - appKitPoint.x) <= 0.01)
            #expect(abs(roundTripped.y - appKitPoint.y) <= 0.01)
        }
    }
}

@Test func rectFlipMapsEachDisplayToItsCGFrame() {
    // Main display's top-left is the CG origin.
    #expect(ScreenTopology.cg(fromAppKit: appKitDisplayFrames[0], flipH: mainDisplayHeight) == CGRect(x: 0, y: 0, width: 3440, height: 1440))
    // The left display (AppKit y 180..1260) sits 180 pt below the main top in CG.
    #expect(ScreenTopology.cg(fromAppKit: appKitDisplayFrames[1], flipH: mainDisplayHeight) == CGRect(x: -1920, y: 180, width: 1920, height: 1080))
    // The display above the main one has negative CG y.
    #expect(ScreenTopology.cg(fromAppKit: appKitDisplayFrames[2], flipH: mainDisplayHeight) == CGRect(x: 760, y: -1080, width: 1920, height: 1080))

    for displayFrame in appKitDisplayFrames {
        let roundTripped = ScreenTopology.appKit(fromCG: ScreenTopology.cg(fromAppKit: displayFrame, flipH: mainDisplayHeight), flipH: mainDisplayHeight)
        #expect(abs(roundTripped.minX - displayFrame.minX) <= 0.01)
        #expect(abs(roundTripped.minY - displayFrame.minY) <= 0.01)
        #expect(roundTripped.size == displayFrame.size)
    }
}
