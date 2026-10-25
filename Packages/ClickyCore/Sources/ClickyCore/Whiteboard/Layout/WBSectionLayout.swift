//
//  WBSectionLayout.swift
//  ClickyCore
//
//  Cuts the board into sections: 1 → the full width; 2–3 → side-by-side
//  columns when the board is wide (width > 1.3 × height), else stacked rows;
//  4 → 2 × 2; more → 3 columns (rows sized for two on screen; the camera
//  handles the overflow). A section never shrinks below its content: its
//  column widens and its row grows instead, so every element stays inside
//  its section rect. Inside a section, blocks stack in first-appearance
//  order with 24 pt gaps.
//

import AppKit
import CoreGraphics

public enum WBSectionArrangement: String, Sendable, Equatable {
    case single, columns, rows, grid, threeColumns
}

public struct WBSectionGrid: Equatable, Sendable {
    public let arrangement: WBSectionArrangement
    public let columnCount: Int
    public let rowCount: Int
    /// The share of the viewport one section gets before content grows it.
    public let allocatedCellSize: CGSize

    /// Width the section's content is laid out against.
    public var contentWidth: CGFloat { max(120, allocatedCellSize.width - 2 * WBSectionLayout.sectionPadding) }
}

public enum WBSectionLayout {
    public static let boardMargin: CGFloat = 24
    public static let sectionGap: CGFloat = 24
    public static let sectionPadding: CGFloat = 20
    public static let blockGap: CGFloat = 24
    public static let titleGap: CGFloat = 10
    public static let titleFontSize: CGFloat = 22
    public static let wideBoardRatio: CGFloat = 1.3
    static let minimumCellSize = CGSize(width: 240, height: 160)

    public static func grid(sectionCount: Int, viewportSize: CGSize) -> WBSectionGrid {
        let arrangement: WBSectionArrangement
        let columnCount: Int
        let rowCount: Int
        switch sectionCount {
        case ...1:
            (arrangement, columnCount, rowCount) = (.single, 1, 1)
        case 2...3:
            if viewportSize.width > wideBoardRatio * viewportSize.height {
                (arrangement, columnCount, rowCount) = (.columns, sectionCount, 1)
            } else {
                (arrangement, columnCount, rowCount) = (.rows, 1, sectionCount)
            }
        case 4:
            (arrangement, columnCount, rowCount) = (.grid, 2, 2)
        default:
            (arrangement, columnCount, rowCount) = (.threeColumns, 3, (sectionCount + 2) / 3)
        }
        let visibleRowCount = arrangement == .threeColumns ? min(rowCount, 2) : rowCount
        let cellWidth = (viewportSize.width - 2 * boardMargin - CGFloat(columnCount - 1) * sectionGap) / CGFloat(columnCount)
        let cellHeight = (viewportSize.height - 2 * boardMargin - CGFloat(visibleRowCount - 1) * sectionGap) / CGFloat(visibleRowCount)
        return WBSectionGrid(arrangement: arrangement, columnCount: columnCount, rowCount: rowCount,
                             allocatedCellSize: CGSize(width: max(minimumCellSize.width, cellWidth),
                                                       height: max(minimumCellSize.height, cellHeight)))
    }

    public static func titleSize(_ title: String?) -> CGSize {
        guard let title, !title.isEmpty else { return .zero }
        return WBMeasure.textSize(title, font: WBMeasure.handFont(size: titleFontSize), maximumWidth: WBMeasure.unboundedWidth)
    }

    /// Height above the content taken by the title (and its gap).
    public static func titleBlockHeight(_ title: String?) -> CGFloat {
        let measuredTitle = titleSize(title)
        return measuredTitle.height > 0 ? measuredTitle.height + titleGap : 0
    }

    /// Section rects in board points, from each section's needed outer size
    /// (content + padding + title). Columns take their widest member, rows
    /// their tallest; never smaller than the allocated cell.
    public static func sectionRects(neededSizes: [CGSize], grid: WBSectionGrid) -> [CGRect] {
        var columnWidths = [CGFloat](repeating: grid.allocatedCellSize.width, count: grid.columnCount)
        var rowHeights = [CGFloat](repeating: grid.allocatedCellSize.height, count: max(1, grid.rowCount))
        for (sectionIndex, neededSize) in neededSizes.enumerated() {
            let column = sectionIndex % grid.columnCount
            let row = sectionIndex / grid.columnCount
            columnWidths[column] = max(columnWidths[column], ceil(neededSize.width))
            rowHeights[row] = max(rowHeights[row], ceil(neededSize.height))
        }
        var rects: [CGRect] = []
        for sectionIndex in neededSizes.indices {
            let column = sectionIndex % grid.columnCount
            let row = sectionIndex / grid.columnCount
            let originX = boardMargin + columnWidths[..<column].reduce(0, +) + CGFloat(column) * sectionGap
            let originY = boardMargin + rowHeights[..<row].reduce(0, +) + CGFloat(row) * sectionGap
            rects.append(CGRect(x: originX, y: originY, width: columnWidths[column], height: rowHeights[row]))
        }
        return rects
    }
}
