//
//  LiveScreenMarksOverlayView.swift
//  leanring-buddy
//
//  Draws Claude's live marks (circles, arrows, numbered steps) inside each
//  screen's full-screen overlay. The overlay window is already click-through,
//  so marks never block the element they point at.
//
//  Marks draw in one after another (staggered by their order in the response)
//  so a 1-2-3 walkthrough reads in sequence.
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
                    markLocationInThisScreen: ScreenTopology.overlayLocal(fromCG: liveScreenMark.locationCG, displayBoundsCG: displayBoundsCG),
                    screenSize: screenFrame.size
                )
                .transition(.opacity)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .animation(.easeOut(duration: 0.3), value: liveScreenMarks)
        .allowsHitTesting(false)
    }

    private var liveScreenMarksOnThisScreen: [LiveScreenMark] {
        liveScreenMarks.filter { displayBoundsCG.contains($0.locationCG) }
    }

    /// This overlay's display in CG global points. Marks are stored in CG
    /// and drawn at overlay-local = CG − display origin (top-left, y down).
    private var displayBoundsCG: CGRect {
        ScreenTopology.cg(fromAppKit: screenFrame, flipH: ScreenTopology.mainDisplayHeight)
    }
}

private struct LiveScreenMarkView: View {
    let liveScreenMark: LiveScreenMark
    let markLocationInThisScreen: CGPoint
    let screenSize: CGSize

    /// 0 → 1 as the mark draws itself in.
    @State private var drawInProgress: CGFloat = 0

    private let circleMarkRadius: CGFloat = 34
    private let numberedStepBadgeDiameter: CGFloat = 26
    private let markLineWidth: CGFloat = 3.5
    /// How far the arrow's tail sits from its head.
    private let arrowTailOffset = CGSize(width: 90, height: 70)
    /// Gap between the arrow head and the element so the head doesn't cover it.
    private let arrowHeadGapFromTarget: CGFloat = 10
    private let staggerDelayBetweenMarksSeconds: Double = 0.35

    var body: some View {
        ZStack {
            switch liveScreenMark.markKind {
            case .circle:
                circleMark
            case .arrow:
                arrowMark
            case .numberedStep(let stepNumber):
                numberedStepMark(stepNumber: stepNumber)
            }
        }
        .onAppear {
            let drawInDelaySeconds = Double(liveScreenMark.orderInResponse) * staggerDelayBetweenMarksSeconds
            withAnimation(.easeOut(duration: 0.45).delay(drawInDelaySeconds)) {
                drawInProgress = 1
            }
        }
    }

    // MARK: - Circle

    private var circleMark: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: drawInProgress)
                .stroke(DS.Colors.overlayCompanionOrange, style: StrokeStyle(lineWidth: markLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: circleMarkRadius * 2, height: circleMarkRadius * 2)
                .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.6), radius: 6)
                .position(markLocationInThisScreen)

            if let markLabel = liveScreenMark.markLabel {
                markLabelPill(markLabel)
                    .position(x: markLocationInThisScreen.x, y: markLocationInThisScreen.y + circleMarkRadius + 16)
            }
        }
    }

    // MARK: - Arrow

    /// The arrow comes in from the upper-left like a cursor, flipping to the
    /// other side when the tail would land off-screen.
    private var arrowTailLocation: CGPoint {
        let tailXFromLeft = markLocationInThisScreen.x - arrowTailOffset.width
        let tailYFromAbove = markLocationInThisScreen.y - arrowTailOffset.height
        return CGPoint(
            x: tailXFromLeft < 20 ? markLocationInThisScreen.x + arrowTailOffset.width : tailXFromLeft,
            y: tailYFromAbove < 20 ? markLocationInThisScreen.y + arrowTailOffset.height : tailYFromAbove
        )
    }

    private var arrowMark: some View {
        let tailLocation = arrowTailLocation
        let distanceFromTailToTarget = hypot(markLocationInThisScreen.x - tailLocation.x, markLocationInThisScreen.y - tailLocation.y)
        let directionX = (markLocationInThisScreen.x - tailLocation.x) / distanceFromTailToTarget
        let directionY = (markLocationInThisScreen.y - tailLocation.y) / distanceFromTailToTarget
        let headLocation = CGPoint(
            x: markLocationInThisScreen.x - directionX * arrowHeadGapFromTarget,
            y: markLocationInThisScreen.y - directionY * arrowHeadGapFromTarget
        )

        return ZStack {
            LiveScreenArrowShape(tailLocation: tailLocation, headLocation: headLocation)
                .trim(from: 0, to: drawInProgress)
                .stroke(DS.Colors.overlayCompanionOrange, style: StrokeStyle(lineWidth: markLineWidth, lineCap: .round, lineJoin: .round))
                .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.6), radius: 6)

            if let markLabel = liveScreenMark.markLabel {
                markLabelPill(markLabel)
                    .opacity(Double(drawInProgress))
                    .position(x: tailLocation.x, y: tailLocation.y + (tailLocation.y < markLocationInThisScreen.y ? -16 : 16))
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }

    // MARK: - Numbered Step

    /// The badge sits just up-left of the target so the element itself stays readable.
    private func numberedStepMark(stepNumber: Int) -> some View {
        let badgeCenter = CGPoint(x: markLocationInThisScreen.x - 18, y: markLocationInThisScreen.y - 18)

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

    // MARK: - Label

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
