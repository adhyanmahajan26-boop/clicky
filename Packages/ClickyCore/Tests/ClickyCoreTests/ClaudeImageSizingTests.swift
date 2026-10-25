import CoreGraphics
import Testing
@testable import ClickyCore

/// Deterministic linear congruential generator so property tests are repeatable.
private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int((state >> 33) % span)
    }
}

@Test func standardTierResizesLandscapeAndPortraitImages() {
    #expect(ClaudeImageSizing.claudeResizedSize(PixelSize(width: 1920, height: 1080), tier: .standard) == PixelSize(width: 1456, height: 819))
    #expect(ClaudeImageSizing.claudeResizedSize(PixelSize(width: 1075, height: 1520), tier: .standard) == PixelSize(width: 924, height: 1307))
}

@Test func highTierResizesLargeImagesAndLeavesFittingImagesAlone() {
    #expect(ClaudeImageSizing.claudeResizedSize(PixelSize(width: 3840, height: 2160), tier: .high) == PixelSize(width: 2576, height: 1449))
    #expect(ClaudeImageSizing.claudeResizedSize(PixelSize(width: 2560, height: 1440), tier: .high) == PixelSize(width: 2560, height: 1440))
}

@Test func addysRealDisplaySizesResizeAsExpected() {
    let ultrawide = PixelSize(width: 3440, height: 1440)
    let fullHD = PixelSize(width: 1920, height: 1080)

    #expect(ClaudeImageSizing.claudeResizedSize(ultrawide, tier: .high) == PixelSize(width: 2576, height: 1078))
    #expect(ClaudeImageSizing.claudeResizedSize(ultrawide, tier: .standard) == PixelSize(width: 1568, height: 656))
    #expect(ClaudeImageSizing.claudeResizedSize(fullHD, tier: .high) == fullHD)
    #expect(ClaudeImageSizing.claudeResizedSize(fullHD, tier: .standard) == PixelSize(width: 1456, height: 819))
}

@Test func capLongEdgeScalesLandscapeImages() {
    #expect(ClaudeImageSizing.capLongEdge(PixelSize(width: 2576, height: 1078), cap: 2000) == PixelSize(width: 2000, height: 837))
    #expect(ClaudeImageSizing.capLongEdge(PixelSize(width: 2560, height: 1440), cap: 2000) == PixelSize(width: 2000, height: 1125))
}

@Test func capLongEdgeReturnsInputUnchangedWhenUnderTheCap() {
    let small = PixelSize(width: 1000, height: 500)
    #expect(ClaudeImageSizing.capLongEdge(small, cap: 2000) == small)
    #expect(ClaudeImageSizing.capLongEdge(PixelSize(width: 2000, height: 1000), cap: 2000) == PixelSize(width: 2000, height: 1000))
}

@Test func capLongEdgeScalesPortraitImages() {
    // 1080 * 1000 / 1920 = 562.5, which rounds to even: 562.
    #expect(ClaudeImageSizing.capLongEdge(PixelSize(width: 1080, height: 1920), cap: 1000) == PixelSize(width: 562, height: 1000))
}

@Test func randomSizesAlwaysFitTheTierAndFittingSizesAreUnchanged() {
    var generator = SeededGenerator(seed: 42)

    for tier in ImageTier.allCases {
        for _ in 0..<300 {
            let size = PixelSize(width: generator.nextInt(in: 1...8000), height: generator.nextInt(in: 1...8000))
            let output = ClaudeImageSizing.claudeResizedSize(size, tier: tier)

            #expect(
                ClaudeImageSizing.fits(output, maxEdge: tier.maxEdge, maxTokens: tier.maxTokens),
                "\(size) at \(tier) resized to \(output), which does not fit"
            )
            if ClaudeImageSizing.fits(size, maxEdge: tier.maxEdge, maxTokens: tier.maxTokens) {
                #expect(output == size, "\(size) already fits \(tier) but became \(output)")
            }
        }
    }
}

@Test func modelImageSizeUsesTheCursorScreenTierAndTheMeasuredCap() {
    let region = CGSize(width: 3440, height: 1440)
    let native = PixelSize(width: 3440, height: 1440)

    #expect(ClaudeImageSizing.modelImageSize(regionInPoints: region, nativePixels: native, isCursorScreen: true, tierForCursorScreen: .high, effectiveMaxEdge: nil) == PixelSize(width: 2576, height: 1078))
    #expect(ClaudeImageSizing.modelImageSize(regionInPoints: region, nativePixels: native, isCursorScreen: false, tierForCursorScreen: .high, effectiveMaxEdge: nil) == PixelSize(width: 1568, height: 656))
    #expect(ClaudeImageSizing.modelImageSize(regionInPoints: region, nativePixels: native, isCursorScreen: true, tierForCursorScreen: .high, effectiveMaxEdge: 2000) == PixelSize(width: 2000, height: 837))
}

@Test func modelImageSizeNeverExceedsNativePixelsAndHonoursTheRegion() {
    // A 1920x1080-point region captured at 2x (3840x2160 native) on the cursor screen.
    let size = ClaudeImageSizing.modelImageSize(
        regionInPoints: CGSize(width: 1920, height: 1080),
        nativePixels: PixelSize(width: 3840, height: 2160),
        isCursorScreen: true,
        tierForCursorScreen: .high,
        effectiveMaxEdge: nil
    )
    #expect(size == PixelSize(width: 1920, height: 1080))

    let nonCursor = ClaudeImageSizing.modelImageSize(
        regionInPoints: CGSize(width: 1920, height: 1080),
        nativePixels: PixelSize(width: 3840, height: 2160),
        isCursorScreen: false,
        tierForCursorScreen: .high,
        effectiveMaxEdge: nil
    )
    #expect(nonCursor == PixelSize(width: 1456, height: 819))
}
