//
//  WBElementContentView.swift
//  ClickyCore
//
//  The content of one placed board element (everything but its strokes,
//  which the board's Canvas draws): box labels with their SF Symbol, typed
//  text and lists, highlighted code, typeset math, Swift Charts (bar, line,
//  pie via SectorMark), tables and callouts. Sized exactly like WBMeasure
//  measured them, so nothing clips; `elapsed` drives each kind's reveal.
//

import AppKit
import Charts
import SwiftUI

struct WBElementContentView: View {
    let element: WBElement
    let placed: WBPlacedElement
    /// Seconds since the element started appearing (.infinity = finished).
    let elapsed: TimeInterval
    let palette: WhiteboardPalette
    @Environment(\.wbDrawsMathExternally) private var drawsMathExternally

    var body: some View {
        let scale = placed.contentScale
        let unscaledSize = CGSize(width: placed.rect.width / scale, height: placed.rect.height / scale)
        content
            .frame(width: unscaledSize.width, height: unscaledSize.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: placed.rect.width, height: placed.rect.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch element.payload {
        case .box(let box): boxLabel(box)
        case .text(let text): typedText(text)
        case .list(let list): listContent(list)
        case .code(let code): codeContent(code)
        case .math(let math): mathContent(math)
        case .chart(let chart): chartContent(chart)
        case .table(let table): tableContent(table)
        case .callout(let callout): calloutContent(callout)
        case .arrow, .flow, .divider: EmptyView()
        }
    }

    private func plain(_ text: String) -> AttributedString { AttributedString(text) }

    // MARK: Box

    private func boxLabel(_ box: WBBox) -> some View {
        let labelOpacity = WBRevealClock.fraction(elapsed - WhiteboardAnimation.boxOutline * 0.6, over: WhiteboardAnimation.boxLabel)
        let strokeColor = palette.stroke(for: box.color)
        var insets = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        if box.shape == .diamond {
            let horizontalInset = placed.rect.width / placed.contentScale * (1 - 1 / WBLayoutAdapter.diamondGrowth) / 2
            let verticalInset = placed.rect.height / placed.contentScale * (1 - 1 / WBLayoutAdapter.diamondGrowth) / 2
            insets = EdgeInsets(top: verticalInset, leading: horizontalInset, bottom: verticalInset, trailing: horizontalInset)
        } else if box.shape == .cyl {
            insets.top += 12
        } else if box.shape == .pill {
            insets = EdgeInsets(top: 4, leading: 6 + WBLayoutAdapter.pillEndAllowance / 2, bottom: 4, trailing: 6 + WBLayoutAdapter.pillEndAllowance / 2)
        } else if box.shape == .circle {
            insets = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        }
        return HStack(spacing: 6) {
            if let icon = box.icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(strokeColor)
                    .frame(width: 20)
            }
            Text(plain(box.text))
                .font(WBViewFonts.hand(WBMeasure.boxFontSize))
                .foregroundColor(palette.ink)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: false)
        }
        .padding(insets)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(labelOpacity)
    }

    // MARK: Text

    private func typedText(_ text: WBText) -> some View {
        let revealedCount = elapsed == .infinity ? text.text.count : Int(elapsed * WhiteboardAnimation.textCharactersPerSecond)
        let fontSize = max(WBMeasure.minimumFontSize, WBLayoutAdapter.fontSize(for: text.size))
        return Text(plain(String(text.text.prefix(max(0, revealedCount)))))
            .font(WBViewFonts.hand(fontSize))
            .foregroundColor(palette.ink)
            .multilineTextAlignment(.leading)
            .minimumScaleFactor(0.8)
            .padding(WBMeasure.textPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: List

    private func listContent(_ list: WBList) -> some View {
        var lines: [(text: String, isTitle: Bool)] = []
        if let title = list.title { lines.append((title, true)) }
        for (itemIndex, item) in list.items.enumerated() {
            lines.append(((list.isOrdered ? "\(itemIndex + 1).  " : "•  ") + item, false))
        }
        let totalCharacters = lines.reduce(0) { $0 + $1.text.count }
        let charactersPerSecond = max(WhiteboardAnimation.textCharactersPerSecond, Double(totalCharacters) / WhiteboardAnimation.listMaximum)
        var remaining = elapsed == .infinity ? Int.max : Int(elapsed * charactersPerSecond)
        let visibleLines: [(text: String, isTitle: Bool)] = lines.map { line in
            let shown = String(line.text.prefix(max(0, remaining)))
            remaining = max(0, remaining - line.text.count)
            return (shown, line.isTitle)
        }
        return VStack(alignment: .leading, spacing: WBMeasure.listItemSpacing) {
            ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                Text(plain(line.text.isEmpty ? " " : line.text))
                    .font(WBViewFonts.hand(WBMeasure.listFontSize))
                    .foregroundColor(line.isTitle ? palette.ink : palette.ink.opacity(0.92))
                    .underline(line.isTitle && !line.text.isEmpty, color: palette.mutedInk)
                    .opacity(line.text.isEmpty ? 0 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(WBMeasure.listPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Code

    private func codeContent(_ code: WBCode) -> some View {
        let lines = code.displayText.components(separatedBy: "\n")
        let visibleLineCount = elapsed == .infinity ? lines.count : min(lines.count, Int(elapsed / WhiteboardAnimation.codeSecondsPerLine) + 1)
        let highlightedLines = Set(code.highlightedLines)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<lines.count, id: \.self) { lineIndex in
                Text(WBCodeHighlighter.attributedLine(lines[lineIndex], language: code.language, palette: palette))
                    .font(WBViewFonts.mono(WBMeasure.codeFontSize))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlightedLines.contains(lineIndex + 1) ? palette.codeHighlightLine : Color.clear)
                    .opacity(lineIndex < visibleLineCount ? 1 : 0)
            }
        }
        .padding(WBMeasure.codePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Math

    @ViewBuilder
    private func mathContent(_ math: WBMath) -> some View {
        let opacity = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.mathFade)
        Group {
            if let image = WBMathRenderer.image(tex: math.tex, fontSize: WBMeasure.mathFontSize, color: palette.mathInk) {
                if drawsMathExternally {
                    // The PDF exporter draws it (WhiteboardExporter.drawMath).
                    Color.clear.frame(width: image.size.width, height: image.size.height)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: image.size.width, height: image.size.height)
                }
            } else {
                Text(plain(math.tex))
                    .font(WBViewFonts.mono(WBMeasure.mathFontSize))
                    .foregroundColor(palette.ink)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(opacity)
    }

    // MARK: Chart

    private func chartContent(_ chart: WBChart) -> some View {
        let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.chart)
        let seriesColors = palette.chartColors
        return VStack(alignment: .leading, spacing: 4) {
            if let title = chart.title, !title.isEmpty {
                Text(plain(title))
                    .font(WBViewFonts.hand(15))
                    .foregroundColor(palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            WBChartBody(chart: chart, palette: palette, seriesColors: seriesColors)
                .scaleEffect(x: 1, y: max(0.001, progress), anchor: .bottom)
        }
        .padding(10)
        .opacity(progress)
    }

    // MARK: Table

    private func tableContent(_ table: WBTable) -> some View {
        let opacity = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.tableFade)
        let allRows = [table.columns] + table.rows
        let font = WBMeasure.handFont(size: WBMeasure.tableFontSize)
        let columnCount = allRows.map(\.count).max() ?? 0
        var columnWidths = [CGFloat](repeating: 0, count: columnCount)
        var rowHeights: [CGFloat] = []
        for row in allRows {
            var rowHeight: CGFloat = 0
            for (columnIndex, cell) in row.enumerated() {
                let cellSize = WBMeasure.textSize(cell, font: font, maximumWidth: WBMeasure.boxWrapWidth)
                columnWidths[columnIndex] = max(columnWidths[columnIndex], cellSize.width)
                rowHeight = max(rowHeight, cellSize.height)
            }
            rowHeights.append(rowHeight + 2 * WBMeasure.tableCellVerticalPadding)
        }
        let cellWidths = columnWidths.map { $0 + 2 * WBMeasure.tableCellHorizontalPadding }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<allRows.count, id: \.self) { rowIndex in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { columnIndex in
                        let cell = allRows[rowIndex][safe: columnIndex] ?? ""
                        Text(plain(cell))
                            .font(WBViewFonts.hand(WBMeasure.tableFontSize))
                            .foregroundColor(rowIndex == 0 ? palette.ink : palette.ink.opacity(0.9))
                            .lineLimit(nil)
                            .minimumScaleFactor(0.8)
                            .frame(width: columnWidths[columnIndex], alignment: .leading)
                            .padding(.horizontal, WBMeasure.tableCellHorizontalPadding)
                            .frame(width: cellWidths[columnIndex], height: rowHeights[rowIndex], alignment: .leading)
                            .overlay(alignment: .trailing) {
                                if columnIndex < columnCount - 1 { Rectangle().fill(palette.ink.opacity(0.18)).frame(width: 1) }
                            }
                    }
                }
                .background(rowIndex == 0 ? palette.tableHeaderFill : Color.clear)
                .overlay(alignment: .bottom) {
                    if rowIndex < allRows.count - 1 { Rectangle().fill(palette.ink.opacity(rowIndex == 0 ? 0.45 : 0.15)).frame(height: 1) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(opacity)
    }

    // MARK: Callout

    private func calloutContent(_ callout: WBCallout) -> some View {
        let labelOpacity = WBRevealClock.fraction(elapsed - WhiteboardAnimation.boxOutline * 0.5, over: WhiteboardAnimation.boxLabel)
        let symbolName: String
        switch callout.style {
        case .info: symbolName = "info.circle"
        case .tip: symbolName = "lightbulb"
        case .warning: symbolName = "exclamationmark.triangle"
        case .error: symbolName = "xmark.octagon"
        }
        return HStack(alignment: .center, spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(palette.calloutColor(callout.style))
                .frame(width: 18)
            Text(plain(callout.text))
                .font(WBViewFonts.hand(WBMeasure.boxFontSize))
                .foregroundColor(palette.ink)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, WBMeasure.boxPadding - 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(labelOpacity)
    }
}

/// PDF export: the exporter draws formulas itself, straight into the PDF
/// context (vectors), so the view leaves their place empty.
struct WBDrawsMathExternallyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var wbDrawsMathExternally: Bool {
        get { self[WBDrawsMathExternallyKey.self] }
        set { self[WBDrawsMathExternallyKey.self] = newValue }
    }
}

/// Invisible text (PDF text render mode 3) fitted to a rect of a y-up context:
/// a formula's TeX source over it, selectable and searchable, never visible
/// (the way OCR'd PDFs carry their text layer).
enum WBInvisibleText {
    static func draw(_ text: String, fittingYUp rect: CGRect, in cgContext: CGContext) {
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let baseSize: CGFloat = 12
        func line(size: CGFloat) -> CTLine {
            let attributes: [NSAttributedString.Key: Any] = [.font: WBMeasure.monospacedFont(size: size)]
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        let measuredWidth = CTLineGetTypographicBounds(line(size: baseSize), nil, nil, nil)
        guard measuredWidth > 0 else { return }
        // As wide as the formula (a selection lines up with it), never taller than it.
        let fontSize = max(1, min(rect.height * 0.8, baseSize * rect.width / CGFloat(measuredWidth)))
        cgContext.saveGState()
        cgContext.textMatrix = .identity
        cgContext.setTextDrawingMode(.invisible)
        cgContext.textPosition = CGPoint(x: rect.minX, y: rect.midY - fontSize * 0.35)
        CTLineDraw(line(size: fontSize), cgContext)
        cgContext.restoreGState()
    }
}

/// Bar, line or pie (SectorMark) of a board chart.
struct WBChartBody: View {
    let chart: WBChart
    let palette: WhiteboardPalette
    let seriesColors: [Color]

    private struct IndexedPoint: Identifiable {
        let id: Int
        let label: String
        let value: Double
    }

    private var points: [IndexedPoint] {
        chart.points.enumerated().map { IndexedPoint(id: $0.offset, label: $0.element.label, value: $0.element.value) }
    }

    var body: some View {
        let accent = seriesColors.first ?? palette.ink
        switch chart.kind {
        case .bar:
            Chart(points) { point in
                BarMark(x: .value("Label", point.label), y: .value("Value", point.value))
                    .foregroundStyle(accent.opacity(0.85))
                    .cornerRadius(3)
            }
            .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(palette.mutedInk).font(.system(size: 10)) } }
            .chartYAxis { AxisMarks { value in
                AxisGridLine().foregroundStyle(palette.ink.opacity(0.12))
                AxisValueLabel().foregroundStyle(palette.mutedInk).font(.system(size: 10))
            } }
        case .line:
            Chart(points) { point in
                LineMark(x: .value("Label", point.label), y: .value("Value", point.value))
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                PointMark(x: .value("Label", point.label), y: .value("Value", point.value))
                    .foregroundStyle(accent)
            }
            .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(palette.mutedInk).font(.system(size: 10)) } }
            .chartYAxis { AxisMarks { value in
                AxisGridLine().foregroundStyle(palette.ink.opacity(0.12))
                AxisValueLabel().foregroundStyle(palette.mutedInk).font(.system(size: 10))
            } }
        case .pie:
            HStack(spacing: 8) {
                Chart(points) { point in
                    SectorMark(angle: .value("Value", max(0, point.value)), innerRadius: .ratio(0.45), angularInset: 1.5)
                        .foregroundStyle(seriesColors[point.id % max(1, seriesColors.count)])
                }
                .aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(points.prefix(8)) { point in
                        HStack(spacing: 5) {
                            Circle().fill(seriesColors[point.id % max(1, seriesColors.count)]).frame(width: 8, height: 8)
                            Text(AttributedString(point.label))
                                .font(.system(size: 11))
                                .foregroundColor(palette.mutedInk)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
