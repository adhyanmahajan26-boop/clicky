import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

private func solidGrayImage(width: Int, height: Int, value: UInt8) -> GrayImage {
    GrayImage(width: width, height: height, pixels: [UInt8](repeating: value, count: width * height))
}

/// A white image with a dark rectangle drawn at the given pixel ranges.
private func whiteImage(width: Int, height: Int, darkX: Range<Int>, darkY: Range<Int>) -> GrayImage {
    var pixels = [UInt8](repeating: 255, count: width * height)
    for pixelY in darkY {
        for pixelX in darkX {
            pixels[pixelY * width + pixelX] = 0
        }
    }
    return GrayImage(width: width, height: height, pixels: pixels)
}

@Test func blockDiffReportsNoChangeForIdenticalImages() {
    let image = solidGrayImage(width: 3440, height: 1440, value: 255)
    let result = BlockDiff.compare(image, image)

    #expect(!result.hasChanges)
    #expect(result.changedRowIndexes.isEmpty)
    #expect(result.changedBlockRects.isEmpty)
    #expect(result.changedStrips(imageWidth: 3440, imageHeight: 1440).isEmpty)
}

@Test func blockDiffMarksOnlyTheRowsTouchedByANewLine() {
    let before = solidGrayImage(width: 3440, height: 1440, value: 255)
    // 13 px tall dark line (rows 700...712), 300 px wide, starting on a block boundary.
    let after = whiteImage(width: 3440, height: 1440, darkX: 1024..<1324, darkY: 700..<713)
    let result = BlockDiff.compare(before, after)

    #expect(result.hasChanges)
    // Row 700 / 64 = 10 is changed; the line also reaches into row 11 (704...767).
    #expect(result.changedRowIndexes == [10, 11])
    #expect(result.changedRowIndexes.contains(700 / BlockDiff.blockSize))
    // Columns 16...20 cover x 1024...1323.
    #expect(result.changedBlockRects.count == 10)
}

@Test func blockDiffStripCoversChangedRowsPaddedByOneBlockAndIsFullWidth() {
    let before = solidGrayImage(width: 3440, height: 1440, value: 255)
    let after = whiteImage(width: 3440, height: 1440, darkX: 1024..<1324, darkY: 700..<713)
    let strips = BlockDiff.compare(before, after).changedStrips(imageWidth: 3440, imageHeight: 1440)

    #expect(strips.count == 1)
    let strip = strips[0]
    // Rows 10 and 11 padded by one block each side: rows 9...12 = y 576..<832.
    #expect(strip == CGRect(x: 0, y: 576, width: 3440, height: 256))
    #expect(strip.minX == 0)
    #expect(strip.width == 3440)
    #expect(strip.minY <= 700)
    #expect(strip.maxY >= 713)
}

@Test func blockDiffIgnoresATinyOneLevelChange() {
    let before = solidGrayImage(width: 3440, height: 1440, value: 255)
    var pixels = [UInt8](repeating: 255, count: 3440 * 1440)
    // A whole block one grey level darker: mean difference 1/255, below 4/255.
    for pixelY in 0..<64 {
        for pixelX in 0..<64 {
            pixels[pixelY * 3440 + pixelX] = 254
        }
    }
    let after = GrayImage(width: 3440, height: 1440, pixels: pixels)
    let result = BlockDiff.compare(before, after)

    #expect(!result.hasChanges)
    #expect(result.changedRowIndexes.isEmpty)
}

@Test func blockDiffTreatsDifferentSizedImagesAsFullyChanged() {
    let small = solidGrayImage(width: 100, height: 100, value: 255)
    let wide = solidGrayImage(width: 200, height: 100, value: 255)
    let result = BlockDiff.compare(small, wide)

    // ceil(200 / 64) = 4 columns, ceil(100 / 64) = 2 rows.
    #expect(result.columns == 4)
    #expect(result.rows == 2)
    #expect(result.changed.count == 8)
    #expect(result.changed.allSatisfy { $0 })
    #expect(result.hasChanges)
}
