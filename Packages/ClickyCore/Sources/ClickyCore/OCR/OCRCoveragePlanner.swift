//
//  OCRCoveragePlanner.swift
//  ClickyCore
//
//  P6.8: OCR only where accessibility doesn't already say what's there.
//  The capture is split into 256 native-px tiles. A tile is skipped when
//  less than 10% of it is uncovered by trusted AX text frames, or when its
//  uncovered part is blank (flat colour in the grey image: no ink to read).
//  The tiles left are grouped (8-connected), their bounding boxes merged
//  and padded, and only those regions are OCRed. When most of the screen
//  needs reading anyway, one full-image pass is planned instead.
//
//  Only frames whose text the resolver can look up live (static text,
//  text fields, text areas) count as coverage, and only from apps whose AX
//  was checked against OCR before (`AXAlignmentLedger`), so a misaligned
//  app is still OCRed and still caught. Canvas text has no AX at all, so
//  it is always OCRed.
//

import CoreGraphics
import Foundation

public enum OCRCoveragePlanner {
    public static let tileSizePx = 256
    /// A tile with less than this fraction uncovered is skipped.
    public static let skipBelowUncoveredFraction = 0.10
    /// Coverage/ink are evaluated on cells of this many native px.
    public static let coverageCellPx = 8
    /// Grey-level step between neighbouring cells that counts as ink.
    public static let inkContrastThreshold = 10
    /// Native px added around each planned region (text on a tile edge).
    public static let regionPaddingPx = 24
    /// More planned area than this fraction → one full-image pass.
    public static let fullImageAreaFraction = 0.70
    public static let maximumRegionCount = 6

    public struct Plan: Sendable, Equatable {
        /// Native-px regions to OCR (each later split into bands).
        public let regionsPx: [CGRect]
        public let totalTileCount: Int
        public let skippedTileCount: Int
        public let isFullImage: Bool

        public var skippedFraction: Double { totalTileCount > 0 ? Double(skippedTileCount) / Double(totalTileCount) : 0 }
    }

    /// The AX element roles whose frames count as "AX already read this":
    /// the resolver's live text lookup works on exactly these.
    public static let coveringRoles: Set<GroundingRole> = [.text, .textField, .textArea]

    /// CG frames of AX elements that may stand in for OCR on one display.
    public static func coveringFramesCG(axElements: [GroundingElement], displayID: CGDirectDisplayID, windowStack: WindowStack,
                                        trustedProcessIdentifiers: Set<pid_t>) -> [CGRect] {
        axElements.compactMap { element in
            guard element.source == .accessibility, element.displayID == displayID, coveringRoles.contains(element.role),
                  trustedProcessIdentifiers.contains(element.processIdentifier),
                  element.role == .textArea || hasText(element),
                  !windowStack.isBehind(point: element.visibleFrameCG.center, processIdentifier: element.processIdentifier),
                  element.visibleFrameCG.area > 0 else { return nil }
            return element.visibleFrameCG
        }
    }

    private static func hasText(_ element: GroundingElement) -> Bool {
        !(element.label ?? "").isEmpty || !(element.value ?? "").isEmpty
    }

    /// CG rect → native-px rect of a capture.
    public static func nativePxRect(fromCG rectCG: CGRect, frame: CaptureFrame) -> CGRect {
        let scaleX = CGFloat(frame.native.width) / frame.regionCG.width
        let scaleY = CGFloat(frame.native.height) / frame.regionCG.height
        return CGRect(x: (rectCG.minX - frame.regionCG.minX) * scaleX, y: (rectCG.minY - frame.regionCG.minY) * scaleY,
                      width: rectCG.width * scaleX, height: rectCG.height * scaleY)
    }

    /// Plans the OCR regions for an image of `imageWidthPx` x `imageHeightPx`
    /// native px. `coveredRectsPx` are AX text frames in native px;
    /// `grayImage` (any downsampling) lets blank tiles be skipped — without
    /// it every uncovered cell counts as ink.
    public static func plan(imageWidthPx: Int, imageHeightPx: Int, coveredRectsPx: [CGRect], grayImage: GrayImage?) -> Plan {
        let fullImage = CGRect(x: 0, y: 0, width: imageWidthPx, height: imageHeightPx)
        guard imageWidthPx > 0, imageHeightPx > 0 else { return Plan(regionsPx: [], totalTileCount: 0, skippedTileCount: 0, isFullImage: false) }
        let tileColumns = (imageWidthPx + tileSizePx - 1) / tileSizePx
        let tileRows = (imageHeightPx + tileSizePx - 1) / tileSizePx
        let totalTileCount = tileColumns * tileRows
        guard !coveredRectsPx.isEmpty || grayImage != nil else {
            return Plan(regionsPx: [fullImage], totalTileCount: totalTileCount, skippedTileCount: 0, isFullImage: true)
        }

        let cellGrid = CellGrid(imageWidthPx: imageWidthPx, imageHeightPx: imageHeightPx, coveredRectsPx: coveredRectsPx, grayImage: grayImage)
        var tileNeedsOCR = [Bool](repeating: false, count: totalTileCount)
        for tileRow in 0..<tileRows {
            for tileColumn in 0..<tileColumns {
                let tileRectPx = CGRect(x: tileColumn * tileSizePx, y: tileRow * tileSizePx, width: tileSizePx, height: tileSizePx).intersection(fullImage)
                let tileStats = cellGrid.stats(inPxRect: tileRectPx)
                tileNeedsOCR[tileRow * tileColumns + tileColumn] = tileStats.uncoveredFraction >= skipBelowUncoveredFraction && tileStats.uncoveredInkCellCount > 0
            }
        }
        let skippedTileCount = tileNeedsOCR.filter { !$0 }.count

        let tileBoxes = mergedBoundingBoxes(of: tileNeedsOCR, columns: tileColumns, rows: tileRows)
        var regionsPx = tileBoxes.map { box -> CGRect in
            CGRect(x: box.minX * CGFloat(tileSizePx), y: box.minY * CGFloat(tileSizePx),
                   width: box.width * CGFloat(tileSizePx), height: box.height * CGFloat(tileSizePx))
                .insetBy(dx: -CGFloat(regionPaddingPx), dy: -CGFloat(regionPaddingPx))
                .intersection(fullImage)
        }
        regionsPx = mergeOverlapping(regionsPx)
        regionsPx = mergeDownTo(maximumRegionCount, regionsPx)

        let plannedArea = regionsPx.reduce(0) { $0 + $1.area }
        if plannedArea >= CGFloat(fullImageAreaFraction) * fullImage.area {
            return Plan(regionsPx: [fullImage], totalTileCount: totalTileCount, skippedTileCount: skippedTileCount, isFullImage: true)
        }
        return Plan(regionsPx: regionsPx.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) },
                    totalTileCount: totalTileCount, skippedTileCount: skippedTileCount, isFullImage: false)
    }

    // MARK: - Cells

    struct TileStats {
        let uncoveredFraction: Double
        let uncoveredInkCellCount: Int
    }

    /// Coverage and ink per 8 px cell.
    struct CellGrid {
        let columns: Int
        let rows: Int
        let isCovered: [Bool]
        let isInk: [Bool]

        init(imageWidthPx: Int, imageHeightPx: Int, coveredRectsPx: [CGRect], grayImage: GrayImage?) {
            let cellPx = OCRCoveragePlanner.coverageCellPx
            columns = (imageWidthPx + cellPx - 1) / cellPx
            rows = (imageHeightPx + cellPx - 1) / cellPx
            var coveredCells = [Bool](repeating: false, count: columns * rows)
            // A cell is covered when its centre is inside an AX text frame.
            for coveredRect in coveredRectsPx where !coveredRect.isNull && !coveredRect.isEmpty {
                let firstColumn = max(0, Int((coveredRect.minX / CGFloat(cellPx) - 0.5).rounded(.up)))
                let lastColumn = min(columns - 1, Int((coveredRect.maxX / CGFloat(cellPx) - 0.5).rounded(.down)))
                let firstRow = max(0, Int((coveredRect.minY / CGFloat(cellPx) - 0.5).rounded(.up)))
                let lastRow = min(rows - 1, Int((coveredRect.maxY / CGFloat(cellPx) - 0.5).rounded(.down)))
                guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }
                for row in firstRow...lastRow {
                    for column in firstColumn...lastColumn { coveredCells[row * columns + column] = true }
                }
            }
            isCovered = coveredCells
            isInk = Self.inkCells(columns: columns, rows: rows, isCovered: coveredCells, grayImage: grayImage)
        }

        /// Ink = an uncovered cell whose grey differs from an uncovered
        /// 4-neighbour by more than the threshold (flat areas of any colour
        /// are blank; the edge of a covered text frame is not ink). No grey
        /// image: everything is ink.
        private static func inkCells(columns: Int, rows: Int, isCovered: [Bool], grayImage: GrayImage?) -> [Bool] {
            guard let grayImage, grayImage.width > 0, grayImage.height > 0 else { return [Bool](repeating: true, count: columns * rows) }
            let cellPx = OCRCoveragePlanner.coverageCellPx
            func gray(column: Int, row: Int) -> Int {
                let grayX = min(grayImage.width - 1, (column * cellPx + cellPx / 2) / max(1, grayImage.nativePixelsPerPixel))
                let grayY = min(grayImage.height - 1, (row * cellPx + cellPx / 2) / max(1, grayImage.nativePixelsPerPixel))
                return Int(grayImage.pixels[grayY * grayImage.width + grayX])
            }
            var cellGray = [Int](repeating: 0, count: columns * rows)
            for row in 0..<rows {
                for column in 0..<columns { cellGray[row * columns + column] = gray(column: column, row: row) }
            }
            var inkCells = [Bool](repeating: false, count: columns * rows)
            let threshold = OCRCoveragePlanner.inkContrastThreshold
            for row in 0..<rows {
                for column in 0..<columns {
                    let cellIndex = row * columns + column
                    guard !isCovered[cellIndex] else { continue }
                    let centre = cellGray[cellIndex]
                    func differs(_ neighbourIndex: Int) -> Bool {
                        !isCovered[neighbourIndex] && abs(centre - cellGray[neighbourIndex]) > threshold
                    }
                    inkCells[cellIndex] = (column > 0 && differs(cellIndex - 1)) || (column < columns - 1 && differs(cellIndex + 1))
                        || (row > 0 && differs(cellIndex - columns)) || (row < rows - 1 && differs(cellIndex + columns))
                }
            }
            return inkCells
        }

        func stats(inPxRect pxRect: CGRect) -> TileStats {
            let cellPx = OCRCoveragePlanner.coverageCellPx
            let firstColumn = Int(pxRect.minX) / cellPx
            let lastColumn = min(columns - 1, (Int(pxRect.maxX.rounded(.up)) - 1) / cellPx)
            let firstRow = Int(pxRect.minY) / cellPx
            let lastRow = min(rows - 1, (Int(pxRect.maxY.rounded(.up)) - 1) / cellPx)
            guard firstColumn <= lastColumn, firstRow <= lastRow else { return TileStats(uncoveredFraction: 0, uncoveredInkCellCount: 0) }
            var cellCount = 0
            var uncoveredCount = 0
            var uncoveredInkCount = 0
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    cellCount += 1
                    let cellIndex = row * columns + column
                    if !isCovered[cellIndex] {
                        uncoveredCount += 1
                        if isInk[cellIndex] { uncoveredInkCount += 1 }
                    }
                }
            }
            return TileStats(uncoveredFraction: cellCount > 0 ? Double(uncoveredCount) / Double(cellCount) : 0, uncoveredInkCellCount: uncoveredInkCount)
        }
    }

    // MARK: - Regions

    /// Bounding boxes (in tile units) of 8-connected groups of `true` tiles,
    /// with overlapping boxes merged.
    static func mergedBoundingBoxes(of tileNeedsOCR: [Bool], columns: Int, rows: Int) -> [CGRect] {
        var isVisited = [Bool](repeating: false, count: tileNeedsOCR.count)
        var boxes: [CGRect] = []
        for startIndex in tileNeedsOCR.indices where tileNeedsOCR[startIndex] && !isVisited[startIndex] {
            var minColumn = startIndex % columns, maxColumn = minColumn
            var minRow = startIndex / columns, maxRow = minRow
            var pendingIndexes = [startIndex]
            isVisited[startIndex] = true
            while let tileIndex = pendingIndexes.popLast() {
                let column = tileIndex % columns
                let row = tileIndex / columns
                minColumn = min(minColumn, column); maxColumn = max(maxColumn, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                for neighbourRow in max(0, row - 1)...min(rows - 1, row + 1) {
                    for neighbourColumn in max(0, column - 1)...min(columns - 1, column + 1) {
                        let neighbourIndex = neighbourRow * columns + neighbourColumn
                        if tileNeedsOCR[neighbourIndex] && !isVisited[neighbourIndex] {
                            isVisited[neighbourIndex] = true
                            pendingIndexes.append(neighbourIndex)
                        }
                    }
                }
            }
            boxes.append(CGRect(x: minColumn, y: minRow, width: maxColumn - minColumn + 1, height: maxRow - minRow + 1))
        }
        return mergeOverlapping(boxes)
    }

    /// Unions rects that intersect until none do.
    static func mergeOverlapping(_ rects: [CGRect]) -> [CGRect] {
        var mergedRects = rects
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for firstIndex in mergedRects.indices {
                for secondIndex in mergedRects.indices where secondIndex > firstIndex {
                    let intersection = mergedRects[firstIndex].intersection(mergedRects[secondIndex])
                    if !intersection.isNull && intersection.width > 0 && intersection.height > 0 {
                        mergedRects[firstIndex] = mergedRects[firstIndex].union(mergedRects[secondIndex])
                        mergedRects.remove(at: secondIndex)
                        didMerge = true
                        break outer
                    }
                }
            }
        }
        return mergedRects
    }

    /// Too many small Vision calls cost more than a few bigger ones: merge
    /// the pair whose union adds the least area until `maximumCount` remain.
    static func mergeDownTo(_ maximumCount: Int, _ rects: [CGRect]) -> [CGRect] {
        var mergedRects = rects
        while mergedRects.count > maximumCount {
            var bestPair = (0, 1)
            var bestExtraArea = CGFloat.greatestFiniteMagnitude
            for firstIndex in mergedRects.indices {
                for secondIndex in mergedRects.indices where secondIndex > firstIndex {
                    let extraArea = mergedRects[firstIndex].union(mergedRects[secondIndex]).area - mergedRects[firstIndex].area - mergedRects[secondIndex].area
                    if extraArea < bestExtraArea { bestExtraArea = extraArea; bestPair = (firstIndex, secondIndex) }
                }
            }
            mergedRects[bestPair.0] = mergedRects[bestPair.0].union(mergedRects[bestPair.1])
            mergedRects.remove(at: bestPair.1)
            mergedRects = mergeOverlapping(mergedRects)
        }
        return mergedRects
    }
}

/// Which apps' AX frames have been checked against OCR (the misalignment
/// check in the grounding coordinator) and found to agree. Only those may
/// stand in for OCR; a verdict lasts `maximumAge`, a drop clears it.
public struct AXAlignmentLedger: Sendable {
    public var maximumAge: TimeInterval
    private var verifiedDates: [pid_t: Date] = [:]

    public init(maximumAge: TimeInterval = 600) {
        self.maximumAge = maximumAge
    }

    public mutating func recordVerified(_ processIdentifiers: Set<pid_t>, at date: Date) {
        for processIdentifier in processIdentifiers { verifiedDates[processIdentifier] = date }
    }

    public mutating func recordMisaligned(_ processIdentifier: pid_t) {
        verifiedDates[processIdentifier] = nil
    }

    public mutating func evict(_ processIdentifier: pid_t) {
        verifiedDates[processIdentifier] = nil
    }

    public func trustedProcessIdentifiers(at date: Date) -> Set<pid_t> {
        Set(verifiedDates.filter { date.timeIntervalSince($0.value) <= maximumAge }.keys)
    }
}
