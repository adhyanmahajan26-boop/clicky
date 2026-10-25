//
//  BlockDiff.swift
//  ClickyCore
//
//  What changed between the prewarm capture and the key-up capture: the
//  screen is split into 64x64 native-pixel blocks and a block counts as
//  changed when its mean grey difference is above 4/255. Only changed rows
//  are re-OCRed and only windows over changed blocks are re-walked.
//

import CoreGraphics
import Foundation

public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    /// Native pixels per grey pixel (8 when built downsampled).
    public let nativePixelsPerPixel: Int

    public init(width: Int, height: Int, pixels: [UInt8], nativePixelsPerPixel: Int = 1) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
        self.nativePixelsPerPixel = nativePixelsPerPixel
    }

    /// Luma of any CGImage, downsampled by `downsampleFactor` (roughly averaging, so
    /// a block's mean is unchanged: an 8 px block of an 8x-downsampled image
    /// is a 64 px native block, at 1/64 of the work).
    public init?(cgImage: CGImage, downsampleFactor: Int = 8) {
        let imageWidth = max(1, cgImage.width / downsampleFactor)
        let imageHeight = max(1, cgImage.height / downsampleFactor)
        var grayPixels = [UInt8](repeating: 0, count: imageWidth * imageHeight)
        guard let grayContext = CGContext(data: &grayPixels, width: imageWidth, height: imageHeight, bitsPerComponent: 8,
                                          bytesPerRow: imageWidth, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        grayContext.interpolationQuality = .low
        grayContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        self.init(width: imageWidth, height: imageHeight, pixels: grayPixels, nativePixelsPerPixel: downsampleFactor)
    }
}

public enum BlockDiff {
    public static let blockSize = 64
    public static let changeThreshold = 4.0 / 255.0

    public struct Result: Sendable, Equatable {
        public let columns: Int
        public let rows: Int
        /// changed[row * columns + column]
        public let changed: [Bool]
        /// Native pixels per block side (always 64).
        public var nativeBlockSize: Int = BlockDiff.blockSize

        public var changedRowIndexes: [Int] {
            (0..<rows).filter { rowIndex in (0..<columns).contains { changed[rowIndex * columns + $0] } }
        }

        public var hasChanges: Bool { changed.contains(true) }

        /// Native-pixel rects of changed blocks.
        public var changedBlockRects: [CGRect] {
            var blockRects: [CGRect] = []
            for rowIndex in 0..<rows {
                for columnIndex in 0..<columns where changed[rowIndex * columns + columnIndex] {
                    blockRects.append(CGRect(x: columnIndex * nativeBlockSize, y: rowIndex * nativeBlockSize,
                                             width: nativeBlockSize, height: nativeBlockSize))
                }
            }
            return blockRects
        }

        /// Full-width native-pixel strips covering changed rows ±1 block,
        /// merged where they touch.
        public func changedStrips(imageWidth: Int, imageHeight: Int) -> [CGRect] {
            var paddedRows = Set<Int>()
            for rowIndex in changedRowIndexes {
                for neighbourRow in (rowIndex - 1)...(rowIndex + 1) where neighbourRow >= 0 && neighbourRow < rows {
                    paddedRows.insert(neighbourRow)
                }
            }
            var strips: [CGRect] = []
            var currentStart: Int?
            var previousRow: Int?
            for rowIndex in paddedRows.sorted() {
                if let start = currentStart, let previous = previousRow, rowIndex != previous + 1 {
                    strips.append(stripRect(fromRow: start, toRow: previous, imageWidth: imageWidth, imageHeight: imageHeight))
                    currentStart = rowIndex
                } else if currentStart == nil {
                    currentStart = rowIndex
                }
                previousRow = rowIndex
            }
            if let start = currentStart, let previous = previousRow {
                strips.append(stripRect(fromRow: start, toRow: previous, imageWidth: imageWidth, imageHeight: imageHeight))
            }
            return strips
        }

        private func stripRect(fromRow: Int, toRow: Int, imageWidth: Int, imageHeight: Int) -> CGRect {
            let top = fromRow * nativeBlockSize
            let bottom = min(imageHeight, (toRow + 1) * nativeBlockSize)
            return CGRect(x: 0, y: top, width: imageWidth, height: bottom - top)
        }
    }

    /// Images must be the same size; otherwise everything counts as changed.
    /// Blocks are 64 NATIVE pixels whatever the grey image's downsampling.
    public static func compare(_ before: GrayImage, _ after: GrayImage) -> Result {
        let blockSize = max(1, BlockDiff.blockSize / after.nativePixelsPerPixel)
        let columns = (after.width + blockSize - 1) / blockSize
        let rows = (after.height + blockSize - 1) / blockSize
        guard before.width == after.width, before.height == after.height else {
            return Result(columns: columns, rows: rows, changed: Array(repeating: true, count: columns * rows), nativeBlockSize: BlockDiff.blockSize)
        }
        var changed = Array(repeating: false, count: columns * rows)
        before.pixels.withUnsafeBufferPointer { beforePixels in
            after.pixels.withUnsafeBufferPointer { afterPixels in
                for rowIndex in 0..<rows {
                    let top = rowIndex * blockSize
                    let bottom = min(after.height, top + blockSize)
                    for columnIndex in 0..<columns {
                        let left = columnIndex * blockSize
                        let right = min(after.width, left + blockSize)
                        var totalDifference = 0
                        for pixelY in top..<bottom {
                            let rowOffset = pixelY * after.width
                            for pixelX in left..<right {
                                let difference = Int(beforePixels[rowOffset + pixelX]) - Int(afterPixels[rowOffset + pixelX])
                                totalDifference += difference < 0 ? -difference : difference
                            }
                        }
                        let pixelCount = (bottom - top) * (right - left)
                        if Double(totalDifference) / Double(pixelCount * 255) > changeThreshold {
                            changed[rowIndex * columns + columnIndex] = true
                        }
                    }
                }
            }
        }
        return Result(columns: columns, rows: rows, changed: changed, nativeBlockSize: BlockDiff.blockSize)
    }
}
