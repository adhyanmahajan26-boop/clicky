import CoreGraphics
import Foundation
import SwiftUI
@testable import ClickyCore

/// A synthetic Notion-style table: 15 rows of 22 pt in a window, each row
/// with a title cell and a shorter second-column cell of varying widths.
/// Five non-adjacent rows are marked as steps with labels like the ones in
/// Addy's screenshot. Pure data, plus a SwiftUI backdrop (light window, gray
/// text bars) for the offscreen renders.
enum DenseTableFixture {
    static let display = MarkSceneDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                          visible: CGRect(x: 0, y: 25, width: 1280, height: 700))
    static let windowFrame = CGRect(x: 120, y: 70, width: 1000, height: 640)
    static let rowHeight: CGFloat = 22
    static let rowCount = 15
    static let firstRowY: CGFloat = 170
    static let rowMinX: CGFloat = 150
    static let rowWidth: CGFloat = 820
    static let textHeight: CGFloat = 13
    static let titleWidths: [CGFloat] = [212, 148, 286, 174, 230, 120, 262, 198, 156, 304, 182, 240, 136, 220, 168]
    static let secondColumnX: CGFloat = 560
    static let secondColumnWidths: [CGFloat] = [96, 140, 72, 118, 160, 88, 104, 150, 64, 132, 110, 92, 146, 78, 124]
    /// 0-based rows marked as steps 1–5.
    static let markedRows = [1, 4, 7, 10, 13]
    static let labels = ["Replace hello@yourstudio.com", "Rename title, add favicon", "Swap the hero image",
                         "Update pricing to $49", "Delete the demo row"]

    static func rowFrame(_ row: Int) -> CGRect {
        CGRect(x: rowMinX, y: firstRowY + CGFloat(row) * rowHeight, width: rowWidth, height: rowHeight)
    }

    /// Text bars of `row` (the OCR lines), vertically centred in the row.
    static func textBounds(row: Int) -> [CGRect] {
        let textY = rowFrame(row).midY - textHeight / 2
        return [CGRect(x: rowMinX + 12, y: textY, width: titleWidths[row], height: textHeight),
                CGRect(x: secondColumnX, y: textY, width: secondColumnWidths[row], height: textHeight)]
    }

    /// Every text bound in the region: OCR lines plus the AX row frames
    /// (containers, which MarkSceneBuilder must see through).
    static var textObstacles: [CGRect] {
        (0..<rowCount).flatMap(textBounds(row:)) + (0..<rowCount).map(rowFrame)
    }

    static func inputs() -> [MarkSceneInput] {
        markedRows.enumerated().map { index, row in
            MarkSceneInput(id: UUID(), style: .step(index + 1), rectCG: rowFrame(row), displayText: labels[index],
                           isTentative: false, order: index, windowFrameCG: windowFrame, targetRole: .text)
        }
    }

    /// The backdrop the marks are drawn over.
    struct Backdrop: View {
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color(white: 0.86)
                RoundedRectangle(cornerRadius: 10).fill(Color.white)
                    .frame(width: windowFrame.width, height: windowFrame.height)
                    .offset(x: windowFrame.minX, y: windowFrame.minY)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                // Header text.
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.35))
                    .frame(width: 260, height: 22).offset(x: rowMinX + 12, y: 110)
                ForEach(0..<rowCount, id: \.self) { row in
                    Rectangle().fill(Color(white: 0.9))
                        .frame(width: rowWidth, height: 1).offset(x: rowMinX, y: rowFrame(row).maxY - 0.5)
                    ForEach(Array(textBounds(row: row).enumerated()), id: \.offset) { _, textRect in
                        RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.55))
                            .frame(width: textRect.width, height: textRect.height)
                            .offset(x: textRect.minX, y: textRect.minY)
                    }
                }
            }
            .frame(width: display.bounds.width, height: display.bounds.height, alignment: .topLeading)
        }
    }
}
