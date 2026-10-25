//
//  MarkSceneView.swift
//  ClickyCore
//
//  Draws a display's share of the mark scene in its full-screen overlay.
//  SwiftUI Shapes only (no Canvas) so that a tracked mark's rect animates
//  (0.1 s) and each outline draws itself on with .trim (0.35 s). Every
//  stroke is a white 6 pt halo at 90 % under the 3 pt orange line, with a
//  soft shadow; tentative marks are dashed at 70 %.
//

import SwiftUI

public enum MarkPalette {
    public static let orange = Color(red: 0.85, green: 0.47, blue: 0.34)
    public static let haloWidth: CGFloat = 6
    public static let lineWidth: CGFloat = 3
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

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: MarkPalette.lineWidth, lineCap: .round, lineJoin: .round,
                    dash: drawing.isTentative ? MarkPalette.tentativeDash : [])
    }
    private var haloStyle: StrokeStyle {
        StrokeStyle(lineWidth: MarkPalette.haloWidth, lineCap: .round, lineJoin: .round,
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
                    .fill(MarkPalette.orange.opacity(0.12))
            }
            if let outline = drawing.outline, drawing.style != .spot {
                haloed(OutlineShape(kind: outline.kind, rect: local(outline.rect), cornerRadius: outline.cornerRadius))
            }
            if let arrow = drawing.arrow {
                haloed(ArrowShape(arrow: arrow, origin: origin))
            }
            if let underline = drawing.underline {
                haloed(SegmentShape(start: local(underline.start), end: local(underline.end)))
            }
            if let connectorFrom = drawing.connectorFrom, let stepDiscCenter = drawing.stepDiscCenter {
                SegmentShape(start: local(connectorFrom), end: local(stepDiscCenter))
                    .trim(from: 0, to: drawProgress)
                    .stroke(MarkPalette.orange.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
            }
            if let stepDiscCenter = drawing.stepDiscCenter, case .step(let stepNumber) = drawing.style {
                stepDisc(stepNumber).position(local(stepDiscCenter))
            }
            if let labelRect = drawing.labelRect, let labelText = drawing.labelText {
                labelPill(labelText, size: labelRect.size)
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

    private func haloed<S: Shape>(_ shape: S) -> some View {
        ZStack {
            shape.trim(from: 0, to: drawProgress).stroke(Color.white.opacity(0.9), style: haloStyle)
            shape.trim(from: 0, to: drawProgress).stroke(MarkPalette.orange, style: strokeStyle)
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

    private func labelPill(_ text: String, size: CGSize) -> some View {
        Text(text)
            .font(.system(size: LabelPlacer.fontSize, weight: .semibold))
            .foregroundColor(.white)
            .multilineTextAlignment(.leading)
            .frame(width: size.width - 2 * LabelPlacer.horizontalPadding, height: size.height - 2 * LabelPlacer.verticalPadding, alignment: .leading)
            .padding(.horizontal, LabelPlacer.horizontalPadding)
            .padding(.vertical, LabelPlacer.verticalPadding)
            .background(RoundedRectangle(cornerRadius: LabelPlacer.cornerRadius, style: .continuous).fill(MarkPalette.orange))
            .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1)
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
