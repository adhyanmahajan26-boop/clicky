//
//  CaptionBubbleView.swift
//  ClickyCore
//
//  The caption bubble: the previous segment (dimmed) and the current one,
//  15 pt, at most 4 lines, up to caption.maxWidth wide. Text not spoken yet
//  is drawn at 25 % opacity in place, so revealing words never re-wraps the
//  bubble. Fence contents are monospaced.
//
//  Below the caption, the marks' legend (nearCursor label style, and attached
//  notes that found no room beside their mark): one line
//  per numbered mark, its chip then its words (13 pt, one line each, cut
//  with "…"), each row a fixed height so the size is known up front.
//

import SwiftUI

public enum CaptionBubbleMetrics {
    public static let fontSize: CGFloat = 15
    public static let horizontalPadding: CGFloat = 12
    public static let verticalPadding: CGFloat = 9
    public static let cornerRadius: CGFloat = 12
    public static let unrevealedOpacity = 0.25
    public static let previousOpacity = 0.55
    public static let legendFontSize: CGFloat = 13
    public static let legendRowHeight: CGFloat = 18
    public static let legendRowSpacing: CGFloat = 3
    /// Between the caption text and the first legend row.
    public static let legendTopGap: CGFloat = 8
    public static let legendChipSpacing: CGFloat = 7
    /// More rows than this are cut (the bubble stays near the cursor).
    public static let maximumLegendRows = 9

    /// The legend block's height for `rowCount` rows (0 when empty).
    public static func legendHeight(rowCount: Int) -> CGFloat {
        let rows = min(rowCount, maximumLegendRows)
        guard rows > 0 else { return 0 }
        return legendTopGap + CGFloat(rows) * legendRowHeight + CGFloat(rows - 1) * legendRowSpacing
    }
}

public struct CaptionBubbleView: View {
    let caption: CaptionState
    let maxWidth: CGFloat
    let maxLines: Int

    public init(caption: CaptionState, maxWidth: CGFloat, maxLines: Int) {
        self.caption = caption
        self.maxWidth = maxWidth
        self.maxLines = maxLines
    }

    private var legendRows: [MarkLegendEntry] {
        caption.statusText == nil ? Array(caption.markLegend.prefix(CaptionBubbleMetrics.maximumLegendRows)) : []
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let statusText = caption.statusText {
                    Text(statusText).foregroundColor(.white.opacity(0.85))
                } else {
                    captionText
                }
            }
            .font(.system(size: CaptionBubbleMetrics.fontSize, weight: .medium))
            .lineLimit(maxLines)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            if !legendRows.isEmpty {
                legend.padding(.top, CaptionBubbleMetrics.legendTopGap)
            }
        }
        .frame(maxWidth: maxWidth - 2 * CaptionBubbleMetrics.horizontalPadding, alignment: .leading)
        .padding(.horizontal, CaptionBubbleMetrics.horizontalPadding)
        .padding(.vertical, CaptionBubbleMetrics.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: CaptionBubbleMetrics.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CaptionBubbleMetrics.cornerRadius, style: .continuous)
                .stroke(MarkPalette.orange.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: CaptionBubbleMetrics.legendRowSpacing) {
            ForEach(legendRows) { entry in
                HStack(spacing: CaptionBubbleMetrics.legendChipSpacing) {
                    MarkChipView(number: entry.number)
                    Text(entry.text)
                        .font(.system(size: CaptionBubbleMetrics.legendFontSize, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(height: CaptionBubbleMetrics.legendRowHeight, alignment: .leading)
            }
        }
    }

    private var captionText: Text {
        var text = Text("")
        if let previous = caption.previous {
            text = text + styled(previous.display, monospacedRanges: previous.monospacedRanges, opacity: CaptionBubbleMetrics.previousOpacity) + Text(" ")
        }
        if let current = caption.current {
            let revealedCount = min(caption.revealedDisplayCharacters, current.display.count)
            let revealedText = String(current.display.prefix(revealedCount))
            let unrevealedText = String(current.display.dropFirst(revealedCount))
            text = text + styled(revealedText, monospacedRanges: current.monospacedRanges, opacity: 1)
                + styled(unrevealedText, monospacedRanges: current.monospacedRanges.map { ($0.lowerBound - revealedCount)..<($0.upperBound - revealedCount) },
                         opacity: CaptionBubbleMetrics.unrevealedOpacity)
        }
        return text
    }

    /// `text` in white at `opacity`, with monospaced ranges (offsets into `text`).
    private func styled(_ text: String, monospacedRanges: [Range<Int>], opacity: Double) -> Text {
        let characters = Array(text)
        var result = Text("")
        var runStart = 0
        func isMonospaced(_ index: Int) -> Bool { monospacedRanges.contains { $0.contains(index) } }
        while runStart < characters.count {
            let runIsMonospaced = isMonospaced(runStart)
            var runEnd = runStart + 1
            while runEnd < characters.count && isMonospaced(runEnd) == runIsMonospaced { runEnd += 1 }
            var run = Text(String(characters[runStart..<runEnd])).foregroundColor(.white.opacity(opacity))
            if runIsMonospaced { run = run.font(.system(size: CaptionBubbleMetrics.fontSize - 1, design: .monospaced)) }
            result = result + run
            runStart = runEnd
        }
        return result
    }
}
