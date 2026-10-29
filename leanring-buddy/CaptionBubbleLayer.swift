//
//  CaptionBubbleLayer.swift
//  leanring-buddy
//
//  Puts the caption bubble next to the companion inside one screen's
//  overlay. BubblePlacer picks the slot in CG points (keeping the current
//  one until it collides or leaves the screen); this view converts it to
//  overlay-local points (CG − display origin) and draws a leader line when
//  the bubble had to dock at the top.
//

import ClickyCore
import SwiftUI

struct CaptionBubbleLayer: View {
    let caption: CaptionState
    /// This overlay's display, CG global points.
    let displayBoundsCG: CGRect
    /// The companion's centre in overlay-local points.
    let companionLocalCenter: CGPoint
    let isCompanionFlying: Bool
    /// Marks, the POINT target and upcoming targets (CG).
    let obstaclesCG: [CGRect]
    /// On-screen text (AX / OCR bounds, CG): slots covering it are skipped.
    var textObstaclesCG: [CGRect] = []

    @State private var lastPlacement: BubblePlacement?
    /// Told each new bubble rect (CG); MarkController logs it to marks.jsonl.
    static var onPlacementChanged: ((CGRect) -> Void)?

    private var maxWidth: CGFloat { CGFloat(ClickySettings.captionMaxWidth) }
    private var maxLines: Int { ClickySettings.captionMaxLines }

    private var visibleFrameCG: CGRect {
        ScreenTopology.current().first { $0.boundsCG == displayBoundsCG }?.visibleCG ?? displayBoundsCG
    }

    private var placement: BubblePlacement {
        let companionCenterCG = CGPoint(x: displayBoundsCG.minX + companionLocalCenter.x, y: displayBoundsCG.minY + companionLocalCenter.y)
        let companionSize = CompanionLanding.companionSize
        let companionRectCG = CGRect(x: companionCenterCG.x - companionSize.width / 2, y: companionCenterCG.y - companionSize.height / 2,
                                     width: companionSize.width, height: companionSize.height)
        let mouseCG = ScreenTopology.cg(fromAppKit: NSEvent.mouseLocation, flipH: ScreenTopology.mainDisplayHeight)
        return BubblePlacer.place(BubblePlacer.Input(
            companionRect: companionRectCG,
            bubbleSize: BubblePlacer.estimatedBubbleSize(for: caption, maxWidth: maxWidth, maxLines: maxLines),
            visibleFrames: [visibleFrameCG],
            mouseLocation: mouseCG,
            obstacles: obstaclesCG,
            textObstacles: nearbyTextObstacles(around: companionRectCG),
            isCompanionFlying: isCompanionFlying,
            previous: lastPlacement
        ))
    }

    /// Only text a bubble slot could reach (the bubble is at most
    /// maxWidth wide, a few lines tall) is checked.
    private func nearbyTextObstacles(around companionRectCG: CGRect) -> [CGRect] {
        let reach = companionRectCG.insetBy(dx: -(maxWidth + 2 * BubblePlacer.gap), dy: -(maxWidth / 2 + 2 * BubblePlacer.gap))
        return textObstaclesCG.filter { $0.intersects(reach) }
    }

    var body: some View {
        let currentPlacement = placement
        let localRect = currentPlacement.rect.offsetBy(dx: -displayBoundsCG.minX, dy: -displayBoundsCG.minY)
        ZStack(alignment: .topLeading) {
            if let leaderLine = currentPlacement.leaderLine {
                Path { path in
                    path.move(to: CGPoint(x: leaderLine.start.x - displayBoundsCG.minX, y: leaderLine.start.y - displayBoundsCG.minY))
                    path.addLine(to: CGPoint(x: leaderLine.end.x - displayBoundsCG.minX, y: leaderLine.end.y - displayBoundsCG.minY))
                }
                .stroke(MarkPalette.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            CaptionBubbleView(caption: caption, maxWidth: maxWidth, maxLines: maxLines)
                .frame(width: localRect.width, height: localRect.height, alignment: .topLeading)
                .position(x: localRect.midX, y: localRect.midY)
                .animation(.easeOut(duration: 0.2), value: localRect)
        }
        .frame(width: displayBoundsCG.width, height: displayBoundsCG.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .onAppear { Self.onPlacementChanged?(currentPlacement.rect) }
        .onChange(of: currentPlacement) { _, newPlacement in
            lastPlacement = newPlacement
            Self.onPlacementChanged?(newPlacement.rect)
        }
    }
}
