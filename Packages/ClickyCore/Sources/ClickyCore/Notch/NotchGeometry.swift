//
//  NotchGeometry.swift
//  ClickyCore
//
//  Where the notch pill sits and how big it is. A display with a camera
//  housing (NSScreen.safeAreaInsets.top > 0 and auxiliary top areas on both
//  sides) gets a pill that hugs the real notch and adds a "wing" on each
//  side for the logo and the status; any other display (the owner's
//  ultrawide) gets a virtual notch, 200 × 32 pt, flush with the top edge and
//  overlapping the menu bar. The expanded panel grows downward from the
//  notch and stays centred on it. Everything is in AppKit global points
//  (y up); the panel frame's top is always the screen's top edge.
//  Pure CoreGraphics: the app passes in the NSScreen values.
//

import CoreGraphics
import Foundation

/// The NSScreen values the notch needs, copied out so this stays pure.
public struct NotchScreenMetrics: Equatable, Sendable {
    /// NSScreen.frame (AppKit global points).
    public var screenFrame: CGRect
    /// NSScreen.safeAreaInsets.top (0 without a camera housing).
    public var safeAreaTopInset: CGFloat
    /// NSScreen.auxiliaryTopLeftArea / auxiliaryTopRightArea: the menu bar
    /// space left and right of the housing (nil without one).
    public var auxiliaryTopLeftArea: CGRect?
    public var auxiliaryTopRightArea: CGRect?
    /// This display's menu bar height (frame top minus visible-frame top; 0 when it auto-hides).
    public var menuBarHeight: CGFloat

    public init(screenFrame: CGRect, safeAreaTopInset: CGFloat = 0, auxiliaryTopLeftArea: CGRect? = nil, auxiliaryTopRightArea: CGRect? = nil,
                menuBarHeight: CGFloat = 0) {
        self.screenFrame = screenFrame
        self.safeAreaTopInset = safeAreaTopInset
        self.menuBarHeight = menuBarHeight
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }
}

/// The notch the pill is drawn around, on one screen.
public struct NotchLayout: Equatable, Sendable {
    /// The hardware notch, or the virtual one, in AppKit global points.
    public let notchRect: CGRect
    public let hasPhysicalNotch: Bool
    public let screenFrame: CGRect
    /// Logo / status wings beside a real notch, scaled to that notch.
    public let wingWidth: CGFloat
    /// The widest a wing may grow for the bot chips: half the free menu bar on the narrower side.
    public let maximumWingWidth: CGFloat

    public init(notchRect: CGRect, hasPhysicalNotch: Bool, screenFrame: CGRect, wingWidth: CGFloat = NotchGeometry.physicalNotchWingWidth,
                maximumWingWidth: CGFloat = NotchGeometry.physicalNotchWingWidth * 2) {
        self.notchRect = notchRect
        self.hasPhysicalNotch = hasPhysicalNotch
        self.screenFrame = screenFrame
        self.wingWidth = wingWidth
        self.maximumWingWidth = max(wingWidth, maximumWingWidth)
    }

    /// The height of the collapsed pill and of the expanded panel's header row.
    public var headerHeight: CGFloat { notchRect.height }

    /// A sample layout for previews and renders.
    public static func sample(hasPhysicalNotch: Bool) -> NotchLayout {
        if hasPhysicalNotch {
            let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
            return NotchGeometry.layout(for: NotchScreenMetrics(screenFrame: screenFrame, safeAreaTopInset: 32,
                                                                auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 662, height: 32),
                                                                auxiliaryTopRightArea: CGRect(x: 850, y: 950, width: 662, height: 32)))
        }
        return NotchGeometry.layout(for: NotchScreenMetrics(screenFrame: CGRect(x: 0, y: 0, width: 3440, height: 1440)))
    }
}

public enum NotchGeometry {
    /// The drawn notch on a display without one.
    public static let virtualNotchSize = CGSize(width: 200, height: 32)
    /// Logo on the left wing, status on the right, around a real notch.
    public static let physicalNotchWingWidth: CGFloat = 70
    /// With nothing to report the wings only hold the logo, so the pill stays off the menu bar.
    public static let idleWingWidth: CGFloat = 26
    /// The small outward curves where the pill meets the screen's top edge
    /// (NotchShape), added on both sides of the body.
    public static let topFlareRadius: CGFloat = 6
    public static let collapsedBottomCornerRadius: CGFloat = 10
    public static let expandedBottomCornerRadius: CGFloat = 22

    // Expanded panel. NotchView lays its rows out at exactly these heights,
    // so the computed size and the drawn content always agree.
    public static let expandedBodyWidth: CGFloat = 380
    public static let maximumAgentRows = 4
    public static let expandedHorizontalPadding: CGFloat = 16
    public static let expandedTopPadding: CGFloat = 6
    public static let expandedBottomPadding: CGFloat = 14
    public static let sectionSpacing: CGFloat = 10
    public static let captionHeight: CGFloat = 54
    public static let agentRowHeight: CGFloat = 36
    public static let agentRowSpacing: CGFloat = 2
    public static let noAgentsLineHeight: CGFloat = 22
    public static let moreAgentsLineHeight: CGFloat = 16
    public static let actionsRowHeight: CGFloat = 28
    /// P7: the action task's step list card (one line each, plus padding).
    public static let maximumActionStepLines = 4
    public static let actionStepLineHeight: CGFloat = 15
    public static let actionStepsVerticalPadding: CGFloat = 12

    /// Height of the step list card for this many lines (0 lines: no card).
    public static func actionStepsHeight(lineCount: Int) -> CGFloat {
        let visibleLineCount = min(max(0, lineCount), maximumActionStepLines)
        return visibleLineCount == 0 ? 0 : CGFloat(visibleLineCount) * actionStepLineHeight + actionStepsVerticalPadding
    }

    /// The notch on this screen: the hardware one when the screen reports a
    /// top safe-area inset and both auxiliary areas, otherwise the virtual one.
    public static func layout(for metrics: NotchScreenMetrics) -> NotchLayout {
        let screenFrame = metrics.screenFrame
        if metrics.safeAreaTopInset > 0, let leftArea = metrics.auxiliaryTopLeftArea, let rightArea = metrics.auxiliaryTopRightArea {
            // Only the widths are used: the housing is whatever the two
            // auxiliary areas leave uncovered in the middle of the top edge.
            let notchWidth = screenFrame.width - leftArea.width - rightArea.width
            if notchWidth > 0 {
                let notchHeight = metrics.safeAreaTopInset
                let notchRect = CGRect(x: screenFrame.minX + leftArea.width, y: screenFrame.maxY - notchHeight, width: notchWidth, height: notchHeight)
                // Room for a short status beside the notch, never wider than the free menu bar.
                let wingWidth = min(physicalNotchWingWidth, min(leftArea.width, rightArea.width) * 0.5)
                return NotchLayout(notchRect: notchRect, hasPhysicalNotch: true, screenFrame: screenFrame, wingWidth: wingWidth,
                                   maximumWingWidth: min(leftArea.width, rightArea.width) * 0.5)
            }
        }
        // No notch: a virtual one in proportion to the display, as tall as its menu bar.
        let size = virtualNotchSize(screenWidth: screenFrame.width, menuBarHeight: metrics.menuBarHeight)
        let notchRect = CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
        return NotchLayout(notchRect: notchRect, hasPhysicalNotch: false, screenFrame: screenFrame)
    }

    /// 12 % of the display's width (160–260 pt), as tall as its menu bar (24–40 pt; 32 when the bar auto-hides).
    public static func virtualNotchSize(screenWidth: CGFloat, menuBarHeight: CGFloat) -> CGSize {
        let width = min(max(screenWidth * 0.06, 116), 170)
        let height = menuBarHeight > 0 ? min(max(menuBarHeight - 4, 24), 30) : 28
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    // The bot chips that are always on the collapsed pill: one per lane with bots in it
    // (needs you, failed, working), a coloured dot and a number.
    public static let botChipWidth: CGFloat = 24
    public static let botChipSpacing: CGFloat = 3
    /// Between the logo and the chips beside a real notch, and between the status and the chips on a virtual one.
    public static let botChipsLeadingGap: CGFloat = 4
    /// After the chips, before the wing's or the pill's edge.
    public static let botChipsTrailingPadding: CGFloat = 8

    /// The width of `chipCount` chips side by side (0 for none).
    public static func botChipsWidth(chipCount: Int) -> CGFloat {
        let visibleChipCount = min(max(0, chipCount), NotchBotLane.allCases.count - 1)
        guard visibleChipCount > 0 else { return 0 }
        return CGFloat(visibleChipCount) * botChipWidth + CGFloat(visibleChipCount - 1) * botChipSpacing
    }

    /// One wing beside a real notch: slim while idle, wide enough for the status otherwise. With bot chips
    /// the left wing holds the logo and the chips, and both wings grow to match so the pill stays centred on the notch.
    public static func collapsedWingWidth(layout: NotchLayout, isIdle: Bool, botChipCount: Int = 0) -> CGFloat {
        if isIdle { return min(idleWingWidth, layout.wingWidth) }
        guard botChipCount > 0 else { return layout.wingWidth }
        let logoAndChips = logoFrameWidth + botChipsLeadingGap + botChipsWidth(chipCount: botChipCount) + botChipsTrailingPadding
        return min(max(layout.wingWidth, logoAndChips), layout.maximumWingWidth)
    }

    /// The logo's frame (NotchLogoView.frameDiameter), for the wing maths.
    public static let logoFrameWidth: CGFloat = 26

    /// The black body of the collapsed pill (without the top flares). A virtual notch grows on the
    /// right by the width of the bot chips, so the logo and status keep their places.
    public static func collapsedBodySize(layout: NotchLayout, isIdle: Bool = false, botChipCount: Int = 0) -> CGSize {
        let bodyWidth: CGFloat
        if layout.hasPhysicalNotch {
            bodyWidth = layout.notchRect.width + 2 * collapsedWingWidth(layout: layout, isIdle: isIdle, botChipCount: botChipCount)
        } else {
            let chipsWidth = botChipsWidth(chipCount: botChipCount)
            bodyWidth = layout.notchRect.width + (chipsWidth > 0 ? chipsWidth + botChipsLeadingGap : 0)
        }
        return CGSize(width: bodyWidth, height: layout.notchRect.height)
    }

    /// The collapsed pill including its flares (the panel's collapsed size).
    public static func collapsedSize(layout: NotchLayout, isIdle: Bool = false, botChipCount: Int = 0) -> CGSize {
        let bodySize = collapsedBodySize(layout: layout, isIdle: isIdle, botChipCount: botChipCount)
        return CGSize(width: bodySize.width + 2 * topFlareRadius, height: bodySize.height)
    }

    /// Height of the agents section for this many rows (0 rows: the "No agents" line).
    public static func agentsSectionHeight(agentRowCount: Int, hasMoreAgentsLine: Bool) -> CGFloat {
        let visibleRowCount = min(max(0, agentRowCount), maximumAgentRows)
        let rowsHeight = visibleRowCount == 0
            ? noAgentsLineHeight
            : CGFloat(visibleRowCount) * agentRowHeight + CGFloat(visibleRowCount - 1) * agentRowSpacing
        return rowsHeight + (hasMoreAgentsLine ? moreAgentsLineHeight : 0)
    }

    // The bots section: one row per bot (face, name, one line, one button or the time),
    // most urgent first, at most NotchBots.maximumRows, plus a "+N more on Home" line.
    public static let botRowHeight: CGFloat = 42
    public static let botRowSpacing: CGFloat = 4
    public static let moreBotsLineHeight: CGFloat = 16

    /// Height of the bots section for this many rows (0 rows: no section).
    public static func botsSectionHeight(botRowCount: Int, hasMoreBotsLine: Bool) -> CGFloat {
        let visibleRowCount = min(max(0, botRowCount), NotchBots.maximumRows)
        guard visibleRowCount > 0 else { return 0 }
        return CGFloat(visibleRowCount) * botRowHeight + CGFloat(visibleRowCount - 1) * botRowSpacing
            + (hasMoreBotsLine ? moreBotsLineHeight : 0)
    }

    /// With bots on the board and no helper agents, the "No agents running" line is left out:
    /// the bots already say what's going on.
    public static func showsAgentsSection(agentRowCount: Int, botRowCount: Int) -> Bool {
        agentRowCount > 0 || botRowCount == 0
    }

    /// The expanded panel including its flares: header, the bots, optional caption,
    /// action steps, agent rows (at most 4, plus a "+N more" line), the actions row.
    public static func expandedSize(layout: NotchLayout, agentRowCount: Int, hasMoreAgentsLine: Bool, hasCaption: Bool, actionStepLineCount: Int = 0,
                                    botRowCount: Int = 0, hasMoreBotsLine: Bool = false) -> CGSize {
        let bodyWidth = max(expandedBodyWidth, collapsedBodySize(layout: layout).width)
        var height = layout.headerHeight + expandedTopPadding
        if botRowCount > 0 { height += botsSectionHeight(botRowCount: botRowCount, hasMoreBotsLine: hasMoreBotsLine) + sectionSpacing }
        if hasCaption { height += captionHeight + sectionSpacing }
        if actionStepLineCount > 0 { height += actionStepsHeight(lineCount: actionStepLineCount) + sectionSpacing }
        if showsAgentsSection(agentRowCount: agentRowCount, botRowCount: botRowCount) {
            height += agentsSectionHeight(agentRowCount: agentRowCount, hasMoreAgentsLine: hasMoreAgentsLine) + sectionSpacing
        }
        height += actionsRowHeight + expandedBottomPadding
        return CGSize(width: bodyWidth + 2 * topFlareRadius, height: height)
    }

    /// The panel frame for a pill of `size`: top flush with the screen's top
    /// edge, centred on the notch, nudged sideways only if it would leave the screen.
    public static func panelFrame(layout: NotchLayout, size: CGSize) -> CGRect {
        let screenFrame = layout.screenFrame
        let width = min(size.width, screenFrame.width)
        let height = min(size.height, screenFrame.height)
        var originX = layout.notchRect.midX - width / 2
        originX = min(max(originX, screenFrame.minX), screenFrame.maxX - width)
        return CGRect(x: originX, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// While the pill shrinks, the panel keeps the bigger of the two sizes
    /// until the spring has finished, so the shrinking pill is never clipped.
    public static func unionSize(_ first: CGSize, _ second: CGSize) -> CGSize {
        CGSize(width: max(first.width, second.width), height: max(first.height, second.height))
    }
}
