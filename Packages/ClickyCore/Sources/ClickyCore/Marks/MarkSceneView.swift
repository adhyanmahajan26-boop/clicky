//
//  MarkSceneView.swift
//  ClickyCore
//
//  Draws a display's share of the mark scene in its full-screen overlay.
//  SwiftUI Shapes only (no Canvas) so that a tracked mark's rect animates
//  (0.1 s) and each outline draws itself on with .trim (0.35 s). Arrows are
//  a white 6 pt halo at 90 % under a 3 pt orange line; outlines and
//  underlines are the fine weight (4 pt halo, 2 pt line) so they never spill
//  onto neighbouring rows; leaders are 1.5 pt on a 3 pt halo. All have a
//  soft shadow; tentative marks are dashed at 70 %. A step's number is a
//  white disc inside its label pill. nearCursor marks carry only a 14 pt
//  numbered chip (MarkChipView, also used by the caption bubble's legend).
//

import SwiftUI

public enum MarkPalette {
    public static let orange = Color(red: 0.85, green: 0.47, blue: 0.34)
    public static let haloWidth: CGFloat = 6
    public static let lineWidth: CGFloat = 3
    /// Outlines and underlines.
    public static let fineHaloWidth: CGFloat = 4
    public static let fineLineWidth: CGFloat = 2
    public static let leaderHaloWidth: CGFloat = 3
    public static let tentativeDash: [CGFloat] = [6, 4]
    public static let tentativeOpacity = 0.7
}

public struct MarkSceneView: View {
    let drawings: [MarkDrawing]
    /// This overlay's display, CG global points.
    let displayBoundsCG: CGRect
    /// Offscreen renders and tests: skip the draw-on animation.
    let drawsImmediately: Bool

    public init(drawings: [MarkDrawing], displayBoundsCG: CGRect, drawsImmediately: Bool = false) {
        self.drawings = drawings
        self.displayBoundsCG = displayBoundsCG
        self.drawsImmediately = drawsImmediately
    }

    private var drawingsOnThisDisplay: [MarkDrawing] {
        drawings.filter { !$0.isHidden && $0.drawnBounds.intersects(displayBoundsCG) }
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(drawingsOnThisDisplay) { drawing in
                MarkDrawingView(drawing: drawing, origin: displayBoundsCG.origin, displaySize: displayBoundsCG.size,
                                drawsImmediately: drawsImmediately)
                    .opacity(drawing.opacity * (drawing.isTentative ? MarkPalette.tentativeOpacity : 1))
                    .transition(.opacity)
            }
        }
        .frame(width: displayBoundsCG.width, height: displayBoundsCG.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.1), value: drawingsOnThisDisplay)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct MarkDrawingView: View {
    let drawing: MarkDrawing
    let origin: CGPoint
    let displaySize: CGSize
    let drawsImmediately: Bool

    @State private var drawProgress: CGFloat

    init(drawing: MarkDrawing, origin: CGPoint, displaySize: CGSize, drawsImmediately: Bool) {
        self.drawing = drawing
        self.origin = origin
        self.displaySize = displaySize
        self.drawsImmediately = drawsImmediately
        _drawProgress = State(initialValue: drawsImmediately ? 1 : 0)
    }

    private func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
    private func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -origin.x, dy: -origin.y) }

    private func strokeStyle(_ lineWidth: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round,
                    dash: drawing.isTentative ? MarkPalette.tentativeDash : [])
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if drawing.style == .spot, let outline = drawing.outline {
                SpotShape(cutout: local(outline.rect), cornerRadius: outline.cornerRadius)
                    .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
            }
            if drawing.style == .box, let outline = drawing.outline {
                OutlineShape(kind: outline.kind, rect: local(outline.rect), cornerRadius: outline.cornerRadius)
                    .fill(MarkPalette.orange.opacity(0.04))
            }
            if let outline = drawing.outline, drawing.style != .spot {
                haloed(OutlineShape(kind: outline.kind, rect: local(outline.rect), cornerRadius: outline.cornerRadius),
                       halo: MarkPalette.fineHaloWidth, line: MarkPalette.fineLineWidth)
            }
            if let arrow = drawing.arrow {
                haloed(ArrowShape(arrow: arrow, origin: origin), halo: MarkPalette.haloWidth, line: MarkPalette.lineWidth)
            }
            if let underline = drawing.underline {
                haloed(SegmentShape(start: local(underline.start), end: local(underline.end)),
                       halo: MarkPalette.fineHaloWidth, line: MarkPalette.fineLineWidth)
            }
            if let leader = drawing.leader {
                haloed(LeaderShape(start: local(leader.start), tip: local(leader.tip), headLeft: local(leader.headLeft), headRight: local(leader.headRight)),
                       halo: MarkPalette.leaderHaloWidth, line: LabelColumnPlacer.leaderLineWidth)
            }
            if let connectorFrom = drawing.connectorFrom, let stepDiscCenter = drawing.stepDiscCenter {
                SegmentShape(start: local(connectorFrom), end: local(stepDiscCenter))
                    .trim(from: 0, to: drawProgress)
                    .stroke(MarkPalette.orange.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
            }
            if let stepDiscCenter = drawing.stepDiscCenter, case .step(let stepNumber) = drawing.style {
                stepDisc(stepNumber).position(local(stepDiscCenter))
            }
            if let chipCenter = drawing.chipCenter, let chipNumber = drawing.chipNumber {
                MarkChipView(number: chipNumber)
                    .scaleEffect(drawProgress)
                    .position(local(chipCenter))
            }
            if let labelRect = drawing.labelRect, drawing.labelText != nil || drawing.labelStepNumber != nil {
                let labelText = drawing.labelText
                Group {
                    if drawing.isLabelAttached {
                        attachedNotePill(labelText.map(AttachedNotes.noteText), stepNumber: drawing.labelStepNumber, size: labelRect.size)
                    } else {
                        labelPill(labelText, stepNumber: drawing.labelStepNumber, size: labelRect.size)
                    }
                }
                .position(x: local(labelRect).midX, y: local(labelRect).midY)
                .opacity(Double(drawProgress))
            }
        }
        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
        .onAppear {
            guard !drawsImmediately else { return }
            withAnimation(.easeOut(duration: 0.35).delay(Double(drawing.order) * 0.2)) { drawProgress = 1 }
        }
    }

    private func haloed<S: Shape>(_ shape: S, halo: CGFloat, line: CGFloat) -> some View {
        ZStack {
            shape.trim(from: 0, to: drawProgress).stroke(Color.white.opacity(0.9), style: strokeStyle(halo))
            shape.trim(from: 0, to: drawProgress).stroke(MarkPalette.orange, style: strokeStyle(line))
        }
        .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1)
    }

    private func stepDisc(_ stepNumber: Int) -> some View {
        Text("\(stepNumber)")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: MarkLayout.stepDiscDiameter, height: MarkLayout.stepDiscDiameter)
            .background(Circle().fill(MarkPalette.orange))
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
            .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1)
            .scaleEffect(drawProgress)
    }

    /// attached style: the small single-line note beside its mark.
    private func attachedNotePill(_ text: String?, stepNumber: Int?, size: CGSize) -> some View {
        HStack(spacing: AttachedNotes.stepBadgeSpacing) {
            if let stepNumber {
                Text("\(stepNumber)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(MarkPalette.orange)
                    .frame(width: AttachedNotes.stepBadgeDiameter, height: AttachedNotes.stepBadgeDiameter)
                    .background(Circle().fill(Color.white))
            }
            if let text {
                Text(text)
                    .font(.system(size: AttachedNotes.fontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, AttachedNotes.horizontalPadding)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AttachedNotes.cornerRadius, style: .continuous).fill(MarkPalette.orange))
        .shadow(color: Color.black.opacity(0.22), radius: 2, x: 0, y: 1)
    }

    private func labelPill(_ text: String?, stepNumber: Int?, size: CGSize) -> some View {
        HStack(spacing: LabelPlacer.stepBadgeSpacing) {
            if let stepNumber {
                Text("\(stepNumber)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(MarkPalette.orange)
                    .frame(width: LabelPlacer.stepBadgeDiameter, height: LabelPlacer.stepBadgeDiameter)
                    .background(Circle().fill(Color.white))
            }
            if let text {
                Text(text)
                    .font(.system(size: LabelPlacer.fontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, text == nil ? LabelPlacer.verticalPadding : LabelPlacer.horizontalPadding)
        .padding(.vertical, LabelPlacer.verticalPadding)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LabelPlacer.cornerRadius, style: .continuous).fill(MarkPalette.orange))
        .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1)
    }
}

/// The small numbered chip: an orange circle with a white number and a thin
/// white rim, MarkChips.diameter wide.
public struct MarkChipView: View {
    let number: Int
    let diameter: CGFloat

    public init(number: Int, diameter: CGFloat = MarkChips.diameter) {
        self.number = number
        self.diameter = diameter
    }

    public var body: some View {
        Text("\(number)")
            .font(.system(size: diameter * (number >= 10 ? 0.55 : 0.68), weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(MarkPalette.orange))
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.25))
            .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Shapes (rect-animatable)

extension CGRect {
    fileprivate var animatablePair: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(origin.x, origin.y), AnimatablePair(size.width, size.height)) }
        set { self = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }
}

struct OutlineShape: Shape {
    let kind: MarkShapeKind
    var rect: CGRect
    let cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { rect.animatablePair }
        set { rect.animatablePair = newValue }
    }

    func path(in _: CGRect) -> Path {
        Path(MarkShapeSpec(kind: kind, rect: rect, cornerRadius: cornerRadius).path)
    }
}

struct SpotShape: Shape {
    var cutout: CGRect
    let cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { cutout.animatablePair }
        set { cutout.animatablePair = newValue }
    }

    func path(in bounds: CGRect) -> Path {
        var spotPath = Path(bounds)
        spotPath.addRoundedRect(in: cutout, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        return spotPath
    }
}

struct SegmentShape: Shape {
    var start: CGPoint
    var end: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(start.x, start.y), AnimatablePair(end.x, end.y)) }
        set {
            start = CGPoint(x: newValue.first.first, y: newValue.first.second)
            end = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in _: CGRect) -> Path {
        var segmentPath = Path()
        segmentPath.move(to: start)
        segmentPath.addLine(to: end)
        return segmentPath
    }
}

/// Quadratic tail from the tail to the tip, then the two head strokes. The
/// whole arrow moves with its tip when the target is tracked.
struct ArrowShape: Shape {
    var tip: CGPoint
    let tailOffset: CGVector
    let controlOffset: CGVector
    let headLeftOffset: CGVector
    let headRightOffset: CGVector

    init(arrow: ArrowSpec, origin: CGPoint) {
        tip = CGPoint(x: arrow.tip.x - origin.x, y: arrow.tip.y - origin.y)
        tailOffset = CGVector(dx: arrow.tail.x - arrow.tip.x, dy: arrow.tail.y - arrow.tip.y)
        controlOffset = CGVector(dx: arrow.control.x - arrow.tip.x, dy: arrow.control.y - arrow.tip.y)
        headLeftOffset = CGVector(dx: arrow.headLeft.x - arrow.tip.x, dy: arrow.headLeft.y - arrow.tip.y)
        headRightOffset = CGVector(dx: arrow.headRight.x - arrow.tip.x, dy: arrow.headRight.y - arrow.tip.y)
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(tip.x, tip.y) }
        set { tip = CGPoint(x: newValue.first, y: newValue.second) }
    }

    private func offset(_ vector: CGVector) -> CGPoint { CGPoint(x: tip.x + vector.dx, y: tip.y + vector.dy) }

    func path(in _: CGRect) -> Path {
        var arrowPath = Path()
        arrowPath.move(to: offset(tailOffset))
        arrowPath.addQuadCurve(to: tip, control: offset(controlOffset))
        arrowPath.move(to: offset(headLeftOffset))
        arrowPath.addLine(to: tip)
        arrowPath.addLine(to: offset(headRightOffset))
        return arrowPath
    }
}

/// A label's leader: a straight shaft and a small open head at the tip.
struct LeaderShape: Shape {
    let start: CGPoint
    let tip: CGPoint
    let headLeft: CGPoint
    let headRight: CGPoint

    func path(in _: CGRect) -> Path {
        var leaderPath = Path()
        leaderPath.move(to: start)
        leaderPath.addLine(to: tip)
        leaderPath.move(to: headLeft)
        leaderPath.addLine(to: tip)
        leaderPath.addLine(to: headRight)
        return leaderPath
    }
}
