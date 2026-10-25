//
//  MarkChips.swift
//  ClickyCore
//
//  The `nearCursor` label style (v2.marks.labelStyle, the default): marks
//  carry no text on screen. With two or more marks in an answer each mark
//  gets only a small numbered chip (14 pt orange circle, white number: the
//  mark's place in the answer, or a step's own number) and the words go to
//  the caption bubble near the cursor as a legend ("1  Replace hello@…").
//  A single mark gets no chip and no legend: the spoken caption explains it.
//
//  Chip spots (pure geometry, CG points):
//   - underline: just left of the underline's start, centred on the text line;
//   - outline / spot: on the outline's top-left corner, just outside it;
//   - arrow: just beyond the tail, along the arrow.
//  A chip that would touch text, another mark or chip, or the companion is
//  nudged left, then up, then up-left (3 pt steps, up to 30 pt); with no
//  free spot it stays at the first one. Chips stay inside visible.insetBy(2).
//

import CoreGraphics
import Foundation

/// How mark labels are shown.
public enum MarkLabelStyle: String, Sendable, Equatable {
    /// Numbered chips on the marks, words in the caption bubble (default).
    case nearCursor
    /// Text pills in a clear-space column with leader arrows (2dfbab2).
    case column
}

/// One line of the bubble's legend: a chip number and the mark's words.
public struct MarkLegendEntry: Equatable, Hashable, Sendable, Identifiable {
    public let number: Int
    public let text: String
    public var id: String { "\(number)·\(text)" }

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

public enum MarkChips {
    public static let diameter: CGFloat = 14
    /// Between the chip and the underline's start / the outline.
    public static let gap: CGFloat = 4
    public static let nudgeStep: CGFloat = 3
    public static let maximumNudge: CGFloat = 30
    public static let screenMargin: CGFloat = 2

    public static func rect(center: CGPoint) -> CGRect {
        CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }

    /// Whether the answer's marks get chips and a legend: two or more marks
    /// (shown, or already parsed for this answer).
    public static func isMultiTarget(markCount: Int, expectedMarkCount: Int = 0) -> Bool {
        max(markCount, expectedMarkCount) >= 2
    }

    /// The chip's number for the `index`-th mark of the answer (0-based, by order).
    public static func number(for style: MarkStyleKind, index: Int) -> Int {
        if case .step(let stepNumber) = style { return stepNumber }
        return index + 1
    }

    /// The legend lines, in answer order: one per mark with words. Empty
    /// for the column style and for single-mark answers.
    public static func legend(for inputs: [MarkSceneInput], labelStyle: MarkLabelStyle, expectedMarkCount: Int = 0) -> [MarkLegendEntry] {
        guard labelStyle == .nearCursor, isMultiTarget(markCount: inputs.count, expectedMarkCount: expectedMarkCount) else { return [] }
        return inputs.sorted { $0.order < $1.order }.enumerated().compactMap { index, input in
            guard let text = input.displayText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return MarkLegendEntry(number: number(for: input.style, index: index), text: text)
        }
    }

    /// First spot left of an underline starting at `lineStart`, centred on `textLine`.
    public static func underlineSpot(lineStart: CGPoint, textLine: CGRect) -> CGPoint {
        CGPoint(x: lineStart.x - gap - diameter / 2, y: textLine.midY)
    }

    /// First spot on an outline's top-left corner, just outside it.
    public static func outlineSpot(_ outline: CGRect) -> CGPoint {
        CGPoint(x: outline.minX - 2, y: outline.minY - 2)
    }

    /// First spot just beyond an arrow's tail.
    public static func arrowSpot(_ arrow: ArrowSpec) -> CGPoint {
        let distance = gap + diameter / 2
        return CGPoint(x: arrow.tail.x + arrow.direction.dx * distance, y: arrow.tail.y + arrow.direction.dy * distance)
    }

    /// `preferred`, or the first nudge (left, up, up-left) whose chip is
    /// clear of `obstacles` and inside `visible`.
    public static func place(preferred: CGPoint, obstacles: [CGRect], visible: CGRect) -> CGPoint {
        let allowed = visible.insetBy(dx: screenMargin, dy: screenMargin)
        func clamped(_ point: CGPoint) -> CGPoint {
            let radius = diameter / 2
            return CGPoint(x: point.x.clamped(allowed.minX + radius, allowed.maxX - radius),
                           y: point.y.clamped(allowed.minY + radius, allowed.maxY - radius))
        }
        func isFree(_ point: CGPoint) -> Bool {
            let chip = rect(center: point)
            return allowed.contains(chip) && !obstacles.contains { $0.intersects(chip) }
        }
        var candidates = [preferred]
        let steps = Int(maximumNudge / nudgeStep)
        for step in 1...steps { candidates.append(CGPoint(x: preferred.x - CGFloat(step) * nudgeStep, y: preferred.y)) }
        for step in 1...steps { candidates.append(CGPoint(x: preferred.x, y: preferred.y - CGFloat(step) * nudgeStep)) }
        for step in 1...steps {
            candidates.append(CGPoint(x: preferred.x - CGFloat(step) * nudgeStep, y: preferred.y - CGFloat(step) * nudgeStep))
        }
        return candidates.first(where: isFree) ?? clamped(preferred)
    }
}
