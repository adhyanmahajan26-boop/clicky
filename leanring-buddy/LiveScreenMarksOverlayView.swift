//
//  LiveScreenMarksOverlayView.swift
//  leanring-buddy
//
//  Draws Claude's live marks inside each screen's full-screen overlay, around
//  the resolved element frames. The overlay window is already click-through,
//  so marks never block the element they point at. Marks draw in one after
//  another (staggered by their order in the response).
//

import ClickyCore
import SwiftUI

struct LiveScreenMarksOverlayView: View {
    let screenFrame: CGRect
    let liveScreenMarks: [LiveScreenMark]

    var body: some View {
        ZStack {
            ForEach(liveScreenMarksOnThisScreen) { liveScreenMark in
                LiveScreenMarkView(
                    liveScreenMark: liveScreenMark,
                    targetRectInThisScreen: overlayLocalRect(for: liveScreenMark.frameCG),
                    screenSize: screenFrame.size
                )
                .transition(.opacity)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .animation(.easeOut(duration: 0.3), value: liveScreenMarks)
        .allowsHitTesting(false)
    }

    /// This overlay's display in CG global points. Marks are stored in CG
    /// and drawn at overlay-local = CG − display origin (top-left, y down).
    private var displayBoundsCG: CGRect {
        ScreenTopology.cg(fromAppKit: screenFrame, flipH: ScreenTopology.mainDisplayHeight)
    }

    private var liveScreenMarksOnThisScreen: [LiveScreenMark] {
        liveScreenMarks.filter { displayBoundsCG.contains($0.locationCG) }
    }

    private func overlayLocalRect(for frameCG: CGRect) -> CGRect {
        CGRect(origin: ScreenTopology.overlayLocal(fromCG: frameCG.origin, displayBoundsCG: displayBoundsCG), size: frameCG.size)
    }
}

private struct LiveScreenMarkView: View {
    let liveScreenMark: LiveScreenMark
    let targetRectInThisScreen: CGRect
    let screenSize: CGSize

    /// 0 → 1 as the mark draws itself in.
    @State private var drawInProgress: CGFloat = 0

    private let markLineWidth: CGFloat = 3.5
    private let numberedStepBadgeDiameter: CGFloat = 26
    private let arrowTailOffset = CGSize(width: 90, height: 70)
    private let staggerDelayBetweenMarksSeconds: Double = 0.35

    private var targetCenter: CGPoint { CGPoint(x: targetRectInThisScreen.midX, y: targetRectInThisScreen.midY) }

    var body: some View {
        ZStack {
            switch liveScreenMark.markKind {
            case .circle:
                circleMark
            case .box:
                boxMark
            case .arrow:
                arrowMark
            case .underline:
                underlineMark
            case .spot:
                spotMark
            case .numberedStep(let stepNumber):
                numberedStepMark(stepNumber: stepNumber)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .onAppear {
            let drawInDelaySeconds = Double(liveScreenMark.orderInResponse) * staggerDelayBetweenMarksSeconds
            withAnimation(.easeOut(duration: 0.45).delay(drawInDelaySeconds)) {
                drawInProgress = 1
            }
        }
    }

    // MARK: - Shapes

    /// A ring a little larger than the target (at least 40 pt across).
    private var circleMark: some View {
        let ringRect = targetRectInThisScreen.insetBy(dx: -8, dy: -8)
        let ringSize = CGSize(width: max(40, ringRect.width), height: max(40, ringRect.height))
        return ZStack {
            Ellipse()
                .trim(from: 0, to: drawInProgress)
                .stroke(DS.Colors.overlayCompanionOrange, style: StrokeStyle(lineWidth: markLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: ringSize.width, height: ringSize.height)
                .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.6), radius: 6)
                .position(targetCenter)
            labelBelow(offsetFromCenter: ringSize.height / 2 + 16)
        }
    }

    private var boxMark: some View {
        let boxRect = targetRectInThisScreen.insetBy(dx: -4, dy: -4)
        let boxSize = CGSize(width: max(16, boxRect.width), height: max(16, boxRect.height))
        return ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .trim(from: 0, to: drawInProgress)
                .stroke(DS.Colors.overlayCompanionOrange, style: StrokeStyle(lineWidth: markLineWidth, lineCap: .round, lineJoin: .round))
                .frame(width: boxSize.width, height: boxSize.height)
                .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.6), radius: 6)
                .position(targetCenter)
            labelBelow(offsetFromCenter: boxSize.height / 2 + 16)
        }
    }

    private var underlineMark: some View {
        let lineWidth = max(20, targetRectInThisScreen.width)
        let lineY = targetRectInThisScreen.maxY + 3
        return ZStack {
            Capsule()
                .fill(DS.Colors.overlayCompanionOrange)
                .frame(width: lineWidth * drawInProgress, height: 3)
                .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.6), radius: 4)
                .position(x: targetRectInThisScreen.minX + lineWidth * drawInProgress / 2, y: lineY)
            labelBelow(offsetFromCenter: targetRectInThisScreen.height / 2 + 18)
        }
    }

    private var spotMark: some View {
        ZStack {
            Circle()
                .fill(DS.Colors.overlayCompanionOrange.opacity(0.45))
                .frame(width: 22, height: 22)
                .scaleEffect(drawInProgress)
                .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.8), radius: 8)
                .position(targetCenter)
            labelBelow(offsetFromCenter: 26)
        }
    }

    /// The arrow comes in from the upper-left like a cursor, flipping to the
    /// other side when the tail would land off-screen, and stops at the
    /// target's edge.
    private var arrowMark: some View {
        let tailXFromLeft = targetCenter.x - arrowTailOffset.width
        let tailYFromAbove = targetCenter.y - arrowTailOffset.height
        let tailLocation = CGPoint(
            x: tailXFromLeft < 20 ? targetCenter.x + arrowTailOffset.width : tailXFromLeft,
            y: tailYFromAbove < 20 ? targetCenter.y + arrowTailOffset.height : tailYFromAbove
        )
        let headLocation = edgePoint(of: targetRectInThisScreen.insetBy(dx: -6, dy: -6), towards: tailLocation)

        return ZStack {
            LiveScreenArrowShape(tailLocation: tailLocation, headLocation: headLocation)
                .trim(from: 0, to: drawInProgress)
                .stroke(DS.Colors.overlayCompanionOrange, style: StrokeStyle(lineWidth: markLineWidth, lineCap: .round, lineJoin: .round))
                .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.6), radius: 6)

            if let markLabel = liveScreenMark.markLabel {
                markLabelPill(markLabel)
                    .opacity(Double(drawInProgress))
                    .position(x: tailLocation.x, y: tailLocation.y + (tailLocation.y < targetCenter.y ? -16 : 16))
            }
        }
    }

    /// The badge sits just outside the target's top-left corner.
    private func numberedStepMark(stepNumber: Int) -> some View {
        let badgeCenter = CGPoint(
            x: max(numberedStepBadgeDiameter / 2, targetRectInThisScreen.minX - 6),
            y: max(numberedStepBadgeDiameter / 2, targetRectInThisScreen.minY - 6)
        )
        return ZStack {
            Text("\(stepNumber)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: numberedStepBadgeDiameter, height: numberedStepBadgeDiameter)
                .background(
                    Circle()
                        .fill(DS.Colors.overlayCompanionOrange)
                        .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.6), radius: 6)
                )
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                .scaleEffect(drawInProgress)
                .position(badgeCenter)

            if let markLabel = liveScreenMark.markLabel {
                markLabelPill(markLabel)
                    .opacity(Double(drawInProgress))
                    .position(x: badgeCenter.x, y: badgeCenter.y - numberedStepBadgeDiameter / 2 - 12)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func labelBelow(offsetFromCenter: CGFloat) -> some View {
        if let markLabel = liveScreenMark.markLabel {
            markLabelPill(markLabel)
                .opacity(Double(drawInProgress))
                .position(x: targetCenter.x, y: targetCenter.y + offsetFromCenter)
        }
    }

    /// Where the line from the rect's centre to `point` crosses its edge.
    private func edgePoint(of rect: CGRect, towards point: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let deltaX = point.x - center.x
        let deltaY = point.y - center.y
        guard rect.width > 0 || rect.height > 0, deltaX != 0 || deltaY != 0 else { return center }
        let scaleX = deltaX != 0 ? (rect.width / 2) / abs(deltaX) : .greatestFiniteMagnitude
        let scaleY = deltaY != 0 ? (rect.height / 2) / abs(deltaY) : .greatestFiniteMagnitude
        let scale = min(scaleX, scaleY, 1)
        return CGPoint(x: center.x + deltaX * scale, y: center.y + deltaY * scale)
    }

    private func markLabelPill(_ markLabel: String) -> some View {
        Text(markLabel)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Colors.overlayCompanionOrange)
                    .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.5), radius: 6)
            )
            .fixedSize()
    }
}

/// A straight shaft with a two-stroke head. Drawn tail-first so trimming it
/// animates the arrow shooting toward its target.
private struct LiveScreenArrowShape: Shape {
    let tailLocation: CGPoint
    let headLocation: CGPoint

    private let arrowHeadLength: CGFloat = 14
    private let arrowHeadSpreadRadians: CGFloat = .pi / 6

    func path(in rect: CGRect) -> Path {
        var arrowPath = Path()
        arrowPath.move(to: tailLocation)
        arrowPath.addLine(to: headLocation)

        let shaftAngle = atan2(headLocation.y - tailLocation.y, headLocation.x - tailLocation.x)
        let leftHeadStrokeEnd = CGPoint(
            x: headLocation.x - arrowHeadLength * cos(shaftAngle - arrowHeadSpreadRadians),
            y: headLocation.y - arrowHeadLength * sin(shaftAngle - arrowHeadSpreadRadians)
        )
        let rightHeadStrokeEnd = CGPoint(
            x: headLocation.x - arrowHeadLength * cos(shaftAngle + arrowHeadSpreadRadians),
            y: headLocation.y - arrowHeadLength * sin(shaftAngle + arrowHeadSpreadRadians)
        )
        arrowPath.move(to: leftHeadStrokeEnd)
        arrowPath.addLine(to: headLocation)
        arrowPath.addLine(to: rightHeadStrokeEnd)
        return arrowPath
    }
}
