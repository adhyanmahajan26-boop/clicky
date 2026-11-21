//
//  NotchView.swift
//  ClickyCore
//
//  The notch pill's SwiftUI content. Collapsed: the Clicky spark (spinning
//  while thinking, pulsing while listening or speaking) with up to four
//  minis orbiting it for running helper agents, and a short status.
//  Expanded: a header, the current caption, the running agents (status,
//  model, elapsed, cost; a click selects one for Cancel) and quick actions
//  (Cancel, Open review, the Agents window, the Code mode switch).
//
//  The bots are always on it: a chip per lane (yellow needs you, red failed,
//  green working, grey ready) sits beside the logo whenever any bot is on, and the
//  edge turns red or yellow while a bot has failed or needs you. Expanded,
//  the bots come first, most urgent first: face, name, one line, one button.
//
//  The pill is black in light and dark mode, like a hardware notch; dark
//  mode adds a faint edge so it still reads against a dark menu bar. The
//  view fills its window and draws the pill top-centred at the collapsed or
//  expanded size, springing between them, so the app can keep the window at
//  the bigger size while the pill shrinks. Row heights come from
//  NotchGeometry, so the computed panel size always fits. Buttons are drawn
//  by SwiftUI itself (no AppKit controls), so ImageRenderer renders it offscreen.
//

import AppKit
import SwiftUI

/// What the pill's controls do; the app wires them to the existing paths.
public struct NotchActions {
    public var expand: () -> Void
    public var selectAgent: (String) -> Void
    public var cancelAgent: (String) -> Void
    public var openReview: (String) -> Void
    public var showAgentsWindow: () -> Void
    public var setCodeModeEnabled: (Bool) -> Void
    /// The bot's face for its line: (bot id, PixelState name). Drawn by the app, which owns the faces.
    public var botFace: ((String, String) -> AnyView)? = nil
    /// The bot line's button.
    public var botLineAction: (String) -> Void = { _ in }
    /// A click anywhere else on a bot's row: open its chat.
    public var openBot: (String) -> Void = { _ in }

    public init(expand: @escaping () -> Void, selectAgent: @escaping (String) -> Void, cancelAgent: @escaping (String) -> Void,
                openReview: @escaping (String) -> Void, showAgentsWindow: @escaping () -> Void, setCodeModeEnabled: @escaping (Bool) -> Void) {
        self.expand = expand
        self.selectAgent = selectAgent
        self.cancelAgent = cancelAgent
        self.openReview = openReview
        self.showAgentsWindow = showAgentsWindow
        self.setCodeModeEnabled = setCodeModeEnabled
    }

    /// Does nothing (renders and previews).
    public static let inert = NotchActions(expand: {}, selectAgent: { _ in }, cancelAgent: { _ in }, openReview: { _ in },
                                           showAgentsWindow: {}, setCodeModeEnabled: { _ in })
}

/// How the pill looks: the theme's colours, and whether it floats free (a rounded
/// capsule anywhere on screen) instead of hanging from the top edge like a notch.
public struct NotchStyle: Equatable, Sendable {
    public var fillHex: UInt32
    public var accentHex: UInt32
    public var isFloating: Bool
    /// The cursor's shape and colours, so the notch logo is the same companion as the cursor.
    public var iconStyle: CompanionIconStyle

    public init(fillHex: UInt32 = 0x000000, accentHex: UInt32 = 0xD97757, isFloating: Bool = false,
                iconStyle: CompanionIconStyle = .claude) {
        self.fillHex = fillHex
        self.accentHex = accentHex
        self.isFloating = isFloating
        self.iconStyle = iconStyle
    }

    public static let `default` = NotchStyle()
}

/// The pill outline: flush with the screen's top edge, with small outward
/// flares where it meets the edge and rounded bottom corners.
public struct NotchShape: Shape {
    public var topFlareRadius: CGFloat
    public var bottomCornerRadius: CGFloat

    public init(topFlareRadius: CGFloat, bottomCornerRadius: CGFloat) {
        self.topFlareRadius = topFlareRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFlareRadius, bottomCornerRadius) }
        set {
            topFlareRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let flare = min(topFlareRadius, rect.width / 4)
        let bodyMinX = rect.minX + flare
        let bodyMaxX = rect.maxX - flare
        let corner = min(bottomCornerRadius, (bodyMaxX - bodyMinX) / 2, rect.height - flare)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: bodyMinX, y: rect.minY + flare), control: CGPoint(x: bodyMinX, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY - corner))
        path.addQuadCurve(to: CGPoint(x: bodyMinX + corner, y: rect.maxY), control: CGPoint(x: bodyMinX, y: rect.maxY))
        path.addLine(to: CGPoint(x: bodyMaxX - corner, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: bodyMaxX, y: rect.maxY - corner), control: CGPoint(x: bodyMaxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: bodyMaxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

public struct NotchView: View {
    let content: NotchContent
    let layout: NotchLayout
    let isExpanded: Bool
    let actions: NotchActions
    /// Set for offscreen renders: the logo is drawn at this moment instead of animating.
    let fixedAnimationDate: Date?
    let style: NotchStyle
    @Environment(\.colorScheme) private var colorScheme

    public static let expandSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// How long the spring takes to settle (the app shrinks the window after it).
    public static let springSettleSeconds: TimeInterval = 0.5

    public init(content: NotchContent, layout: NotchLayout, isExpanded: Bool, actions: NotchActions, fixedAnimationDate: Date? = nil,
                style: NotchStyle = .default) {
        self.style = style
        self.content = content
        self.layout = layout
        self.isExpanded = isExpanded
        self.actions = actions
        self.fixedAnimationDate = fixedAnimationDate
    }

    /// The pill's size for this content (the app sizes the panel the same way).
    public static func pillSize(content: NotchContent, layout: NotchLayout, isExpanded: Bool) -> CGSize {
        guard isExpanded else {
            return NotchGeometry.collapsedSize(layout: layout, isIdle: isIdle(content), botChipCount: content.botTally.chips.count)
        }
        return NotchGeometry.expandedSize(layout: layout, agentRowCount: content.agentRows.count, hasMoreAgentsLine: content.hiddenAgentCount > 0,
                                          hasCaption: content.captionText != nil, actionStepLineCount: content.actionStepLines.count,
                                          botRowCount: content.botLines.count, hasMoreBotsLine: content.hiddenBotCount > 0)
    }

    /// Nothing to show beside the logo: no status, no helpers orbiting it, no bot working, failed or waiting.
    private static func isIdle(_ content: NotchContent) -> Bool {
        content.phase == .idle && content.statusText.isEmpty && content.orbitingAgentIDs.isEmpty && content.botTally.isEmpty
    }

    /// While the companion is quiet, the edge says the most urgent thing about the bots:
    /// red while one has failed, yellow while one needs you. Static, so it costs nothing.
    private var urgentEdgeColor: Color? {
        if content.botTally.failed > 0 { return Self.color(NotchBotLane.failed.hex) }
        if content.botTally.needsYou > 0 { return Self.color(NotchBotLane.needsYou.hex) }
        return nil
    }

    static func color(_ hex: UInt32) -> Color { Color(cgColor: CompanionIconStyle.color(hex)) }

    private var pillShape: NotchShape {
        NotchShape(topFlareRadius: NotchGeometry.topFlareRadius,
                   bottomCornerRadius: isExpanded ? NotchGeometry.expandedBottomCornerRadius : NotchGeometry.collapsedBottomCornerRadius)
    }

    /// Busy: listening, thinking, speaking, or helpers running. The edge glows in the theme's accent.
    private var isBusy: Bool { content.phase != .idle || !content.orbitingAgentIDs.isEmpty }

    private var outline: AnyShape {
        if style.isFloating {
            let pill = NotchGeometry.collapsedSize(layout: layout)
            return AnyShape(RoundedRectangle(cornerRadius: isExpanded ? 20 : pill.height / 2, style: .continuous))
        }
        return AnyShape(pillShape)
    }

    public var body: some View {
        let pillSize = Self.pillSize(content: content, layout: layout, isExpanded: isExpanded)
        let accent = Color(cgColor: CompanionIconStyle.color(style.accentHex))
        ZStack(alignment: .top) {
            outline.fill(Color(cgColor: CompanionIconStyle.color(style.fillHex)))
            if isBusy {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: fixedAnimationDate != nil)) { timeline in
                    let seconds = (fixedAnimationDate ?? timeline.date).timeIntervalSinceReferenceDate
                    outline.stroke(AngularGradient(colors: [accent, accent.opacity(0.15), accent.opacity(0.6), accent.opacity(0.15), accent],
                                                   center: .center, angle: .degrees(seconds.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360)),
                                   lineWidth: 1.6)
                }
            } else if let urgentEdgeColor {
                outline.stroke(urgentEdgeColor.opacity(0.75), lineWidth: 1.4)
            } else {
                outline.stroke(Color.white.opacity(colorScheme == .dark || style.isFloating ? 0.14 : 0), lineWidth: 1)
            }
            if isExpanded {
                expandedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.08)))
            } else {
                collapsedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .frame(width: pillSize.width, height: pillSize.height, alignment: .top)
        .clipShape(outline)
        .contentShape(outline)
        .shadow(color: isBusy ? accent.opacity(0.45) : .black.opacity(style.isFloating ? 0.35 : 0), radius: isBusy ? 10 : 8, y: style.isFloating ? 4 : 0)
        .animation(Self.expandSpring, value: isExpanded)
        .animation(Self.expandSpring, value: pillSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        let isIdle = Self.isIdle(content)
        let chips = content.botTally.chips
        let bodySize = NotchGeometry.collapsedBodySize(layout: layout, isIdle: isIdle, botChipCount: chips.count)
        let wingWidth = NotchGeometry.collapsedWingWidth(layout: layout, isIdle: isIdle, botChipCount: chips.count)
        return Group {
            if layout.hasPhysicalNotch {
                // The hardware notch hides the middle: logo and bot chips in the left wing, status in the right.
                HStack(spacing: 0) {
                    if chips.isEmpty {
                        logo.frame(width: wingWidth)
                    } else {
                        HStack(spacing: NotchGeometry.botChipsLeadingGap) {
                            logo
                            NotchBotChipsView(chips: chips)
                            Spacer(minLength: 0)
                        }
                        .frame(width: wingWidth)
                    }
                    Spacer().frame(width: layout.notchRect.width)
                    statusLabel
                        .frame(width: max(0, wingWidth - 10), alignment: .leading)
                        .padding(.trailing, 10)
                }
            } else if content.statusText.isEmpty && chips.isEmpty {
                logo
            } else {
                HStack(spacing: 7) {
                    logo
                    statusLabel
                    Spacer(minLength: 0)
                    if !chips.isEmpty { NotchBotChipsView(chips: chips) }
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .contentShape(Rectangle())
        .onTapGesture { actions.expand() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(collapsedAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// "Vello, Researcher needs you, 1 needs you, 2 working".
    private var collapsedAccessibilityLabel: String {
        (["Vello", content.statusText, content.botTally.spokenText]).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var statusLabel: some View {
        Text(content.statusText)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.88))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var logo: some View {
        NotchLogoView(phase: content.phase, iconStyle: style.iconStyle, orbitingAgentCount: content.orbitingAgentIDs.count, isAnimating: content.isLogoAnimating,
                      fixedAnimationDate: fixedAnimationDate)
            .overlay(alignment: .bottomTrailing) { wakeIndicatorDot }
    }

    /// P7: a small dot on the logo while the wake word is armed (red while paused).
    @ViewBuilder private var wakeIndicatorDot: some View {
        switch content.wakeIndicator {
        case .hidden:
            EmptyView()
        case .armed, .paused:
            Circle()
                .fill(content.wakeIndicator == .paused ? Color(red: 1, green: 0.27, blue: 0.23) : Color.white.opacity(0.72))
                .frame(width: 4.5, height: 4.5)
                .padding(1.5)
                .accessibilityLabel(content.wakeIndicator == .paused ? "Wake word paused" : "Wake word listening")
        }
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(spacing: 0) {
            header.frame(height: layout.headerHeight)
            Spacer().frame(height: NotchGeometry.expandedTopPadding)
            if !content.botLines.isEmpty {
                botsSection
                    .frame(height: NotchGeometry.botsSectionHeight(botRowCount: content.botLines.count, hasMoreBotsLine: content.hiddenBotCount > 0))
                Spacer().frame(height: NotchGeometry.sectionSpacing)
            }
            if let captionText = content.captionText {
                captionCard(captionText).frame(height: NotchGeometry.captionHeight)
                Spacer().frame(height: NotchGeometry.sectionSpacing)
            }
            if !content.actionStepLines.isEmpty {
                actionStepsCard.frame(height: NotchGeometry.actionStepsHeight(lineCount: content.actionStepLines.count))
                Spacer().frame(height: NotchGeometry.sectionSpacing)
            }
            if NotchGeometry.showsAgentsSection(agentRowCount: content.agentRows.count, botRowCount: content.botLines.count) {
                agentsSection
                    .frame(height: NotchGeometry.agentsSectionHeight(agentRowCount: content.agentRows.count, hasMoreAgentsLine: content.hiddenAgentCount > 0))
                Spacer().frame(height: NotchGeometry.sectionSpacing)
            }
            actionsRow.frame(height: NotchGeometry.actionsRowHeight)
            Spacer().frame(height: NotchGeometry.expandedBottomPadding)
        }
        .padding(.horizontal, NotchGeometry.expandedHorizontalPadding + NotchGeometry.topFlareRadius)
    }

    @ViewBuilder
    private var header: some View {
        if layout.hasPhysicalNotch {
            // Nothing may sit under the hardware notch: one group each side of it.
            let innerWidth = NotchView.pillSize(content: content, layout: layout, isExpanded: true).width
                - 2 * (NotchGeometry.expandedHorizontalPadding + NotchGeometry.topFlareRadius)
            let sideWidth = max(0, (innerWidth - layout.notchRect.width) / 2)
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    logo
                    headerTitle(content.statusText.isEmpty ? "Vello" : content.statusText, isPrimary: content.statusText.isEmpty)
                }
                .frame(width: sideWidth, alignment: .leading)
                Spacer(minLength: 0)
                headerTrailing.frame(width: sideWidth, alignment: .trailing)
            }
        } else {
            HStack(spacing: 7) {
                logo
                headerTitle("Vello", isPrimary: true)
                if !content.statusText.isEmpty { headerTitle(content.statusText, isPrimary: false) }
                Spacer(minLength: 8)
                headerTrailing
            }
        }
    }

    /// The bot chips while any bot is on; otherwise how many helpers are running.
    @ViewBuilder private var headerTrailing: some View {
        if content.botTally.isEmpty {
            runningSummaryLabel
        } else {
            NotchBotChipsView(chips: content.botTally.chips)
        }
    }

    /// The bots, most urgent first: needs you, failed, working, then one that just finished, then the ready ones.
    private var botsSection: some View {
        VStack(alignment: .leading, spacing: NotchGeometry.botRowSpacing) {
            ForEach(content.botLines) { botLine in
                NotchBotRowView(botLine: botLine, face: actions.botFace?(botLine.botID, botLine.state),
                                buttonAction: { actions.botLineAction(botLine.botID) },
                                openAction: { actions.openBot(botLine.botID) })
                    .frame(height: NotchGeometry.botRowHeight)
            }
            if content.hiddenBotCount > 0 {
                Text("+\(content.hiddenBotCount) more on Home")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(height: NotchGeometry.moreBotsLineHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func headerTitle(_ title: String, isPrimary: Bool) -> some View {
        Text(title)
            .font(.system(size: isPrimary ? 12.5 : 11.5, weight: isPrimary ? .bold : .medium, design: .rounded))
            .foregroundColor(.white.opacity(isPrimary ? 1 : 0.6))
            .lineLimit(1)
    }

    private var runningSummaryLabel: some View {
        Text(runningSummary)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.5))
            .lineLimit(1)
    }

    private var runningSummary: String {
        let runningCount = content.agentRows.filter { $0.status.isActive }.count + content.hiddenAgentCount
        return runningCount == 0 ? "nothing running" : "\(runningCount) running"
    }

    private func captionCard(_ captionText: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.clickyCompanionOrange)
                .padding(.top, 2)
            Text(captionText)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(3)
                // The newest words matter most: cut the start, not the end.
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    /// P7: the running action task's steps, newest last ("✓ open Chrome", "▸ type … in 1.5 s").
    private var actionStepsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(content.actionStepLines.suffix(NotchGeometry.maximumActionStepLines).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, weight: line.hasPrefix("▸") ? .semibold : .regular, design: .rounded))
                    .foregroundColor(.white.opacity(line.hasPrefix("▸") ? 0.95 : 0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: NotchGeometry.actionStepLineHeight)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, NotchGeometry.actionStepsVerticalPadding / 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Action steps")
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: NotchGeometry.agentRowSpacing) {
            if content.agentRows.isEmpty {
                Text("No agents running")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, minHeight: NotchGeometry.noAgentsLineHeight, alignment: .leading)
            } else {
                ForEach(content.agentRows) { row in
                    NotchAgentRowView(row: row, isSelected: row.id == content.selectedAgentID, isRecent: content.agentRowsAreRecent) {
                        actions.selectAgent(row.id)
                    }
                    .frame(height: NotchGeometry.agentRowHeight)
                }
            }
            if content.hiddenAgentCount > 0 {
                Text("+\(content.hiddenAgentCount) more in the Agents window")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(height: NotchGeometry.moreAgentsLineHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var actionsRow: some View {
        HStack(spacing: 6) {
            NotchActionButton(title: "Cancel", systemImage: "xmark.circle.fill", role: .destructive, isEnabled: content.cancelTargetID != nil) {
                if let cancelTargetID = content.cancelTargetID { actions.cancelAgent(cancelTargetID) }
            }
            if let reviewTargetID = content.reviewTargetID {
                NotchActionButton(title: "Open review", systemImage: "doc.text.magnifyingglass", role: .normal, isEnabled: true) {
                    actions.openReview(reviewTargetID)
                }
            }
            NotchActionButton(title: "Agents", systemImage: "rectangle.stack", role: .normal, isEnabled: true) {
                actions.showAgentsWindow()
            }
            Spacer(minLength: 4)
            NotchCodeModeSwitch(isOn: content.isCodeModeOn) {
                actions.setCodeModeEnabled(!content.isCodeModeOn)
            }
        }
    }
}

// MARK: - Logo

/// The companion spark at notch size: still while idle, spinning while
/// thinking, pulsing while listening or speaking; helper agents orbit it.
struct NotchLogoView: View {
    let phase: NotchCompanionPhase
    let iconStyle: CompanionIconStyle
    let orbitingAgentCount: Int
    let isAnimating: Bool
    let fixedAnimationDate: Date?

    static let frameDiameter: CGFloat = 26
    static let sparkDiameter: CGFloat = 14
    static let miniDiameter: CGFloat = 5
    static let orbitRadius: CGFloat = 10

    var body: some View {
        Group {
            if let fixedAnimationDate {
                drawing(seconds: fixedAnimationDate.timeIntervalSinceReferenceDate)
            } else {
                // 30 fps is plenty at this size; paused (no redraws) while idle.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { timelineContext in
                    drawing(seconds: timelineContext.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: Self.frameDiameter, height: Self.frameDiameter)
    }

    private func drawing(seconds: Double) -> some View {
        let spinDegrees = phase == .thinking ? (seconds * 220).truncatingRemainder(dividingBy: 360) : 0
        let pulseScale: Double
        switch phase {
        case .listening: pulseScale = 1 + 0.14 * sin(seconds * 2 * .pi / 0.9)
        case .speaking: pulseScale = 1 + 0.08 * sin(seconds * 2 * .pi / 0.6)
        case .idle, .thinking: pulseScale = 1
        }
        let orbitDegrees = (seconds * 80).truncatingRemainder(dividingBy: 360)
        let visibleMiniCount = min(orbitingAgentCount, NotchGeometry.maximumAgentRows)
        let gradient = iconStyle.gradientHexes.map { Color(cgColor: CompanionIconStyle.color($0)) }
        let glow = Color(cgColor: CompanionIconStyle.color(iconStyle.glowHex))
        return ZStack {
            CompanionIconShape(style: iconStyle)
                .fill(LinearGradient(colors: gradient.count > 1 ? gradient : gradient + gradient,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: Self.sparkDiameter, height: Self.sparkDiameter)
                .rotationEffect(.degrees(spinDegrees))
                .scaleEffect(pulseScale)
                .shadow(color: glow.opacity(phase == .idle ? 0.35 : 0.8), radius: phase == .idle ? 2 : 4)
            ForEach(0..<visibleMiniCount, id: \.self) { miniIndex in
                CompanionIconShape(style: iconStyle)
                    .fill(Color(cgColor: CompanionIconStyle.color(iconStyle.miniHex)))
                    .frame(width: Self.miniDiameter, height: Self.miniDiameter)
                    .offset(x: Self.orbitRadius)
                    .rotationEffect(.degrees(-90 + Double(miniIndex) * 360 / Double(visibleMiniCount)))
            }
            .rotationEffect(.degrees(orbitDegrees))
        }
    }
}

// MARK: - Bots

/// The count chips: a dot in the lane's colour and the number, one per lane with bots in it.
struct NotchBotChipsView: View {
    let chips: [NotchBotChip]

    var body: some View {
        HStack(spacing: NotchGeometry.botChipSpacing) {
            ForEach(chips) { chip in
                let laneColor = NotchView.color(chip.lane.hex)
                HStack(spacing: 3) {
                    Circle()
                        .fill(laneColor)
                        .frame(width: 6, height: 6)
                    Text(NotchBotTally.countText(chip.count))
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(width: NotchGeometry.botChipWidth, height: 16)
                .background(Capsule().fill(laneColor.opacity(0.2)))
                .accessibilityLabel(chip.lane == .needsYou && chip.count == 1 ? "1 needs you" : "\(chip.count) \(chip.lane.countWord)")
            }
        }
        .fixedSize()
    }
}

/// One bot on the board: a stripe in its lane's colour, its face, its name and lane, one line,
/// and the one button (Sign in, Answer, Fix, Open) or how long it has been working.
private struct NotchBotRowView: View {
    let botLine: NotchBotLine
    let face: AnyView?
    let buttonAction: () -> Void
    let openAction: () -> Void
    @State private var isHovering = false

    private var laneColor: Color { NotchView.color(botLine.lane.hex) }

    private var laneWord: String {
        switch botLine.lane {
        case .needsYou: return "Needs you"
        case .failed: return "Failed"
        case .working: return "Working"
        case .done: return "Done"
        case .ready: return "Ready"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(laneColor)
                .frame(width: 3, height: 24)
            Group {
                if let face {
                    face
                } else {
                    NotchFallbackFace(laneColor: laneColor)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(botLine.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(laneWord)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(laneColor.opacity(botLine.lane == .done || botLine.lane == .ready ? 0.6 : 1))
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(botLine.line)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(isHovering ? 0.1 : 0.06)))
        .contentShape(Rectangle())
        .onTapGesture { openAction() }
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(botLine.title): \(botLine.line)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var trailing: some View {
        if let button = botLine.button {
            NotchBotButton(title: button, lane: botLine.lane, action: buttonAction)
        } else if let sinceText = botLine.sinceText, !sinceText.isEmpty {
            Text(sinceText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A bot row's one button: filled in the lane's colour for needs you and failed, quiet otherwise.
private struct NotchBotButton: View {
    let title: String
    let lane: NotchBotLane
    let action: () -> Void
    @State private var isHovering = false

    private var isUrgent: Bool { lane == .needsYou || lane == .failed }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(lane == .needsYou ? .black : .white)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isUrgent ? NotchView.color(lane.hex).opacity(isHovering ? 1 : 0.9) : Color.white.opacity(isHovering ? 0.2 : 0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// A plain face for renders and previews, where the app's Pixel faces aren't available.
private struct NotchFallbackFace: View {
    let laneColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(white: 0.17))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1).fill(laneColor).frame(width: 4, height: 6)
                RoundedRectangle(cornerRadius: 1).fill(laneColor).frame(width: 4, height: 6)
            }
        }
    }
}

// MARK: - Rows and controls

private struct NotchAgentRowView: View {
    let row: NotchAgentRow
    let isSelected: Bool
    let isRecent: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: row.kind.symbolName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(row.kind == .codeTask ? Color.clickyCompanionOrange : .white.opacity(0.75))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(isRecent ? 0.6 : 0.95))
                        .lineLimit(1)
                    Text(row.detailText)
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(backgroundOpacity)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.clickyCompanionOrange.opacity(isSelected ? 0.7 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel("\(row.kind.displayName): \(row.title), \(row.detailText)")
    }

    private var backgroundOpacity: Double {
        if isSelected { return 0.13 }
        return isHovering ? 0.1 : 0.05
    }

    private var statusColor: Color {
        switch row.status {
        case .running: return Color(red: 0.32, green: 0.84, blue: 0.45)
        case .queued: return .white.opacity(0.4)
        case .done: return Color(red: 0.4, green: 0.6, blue: 1)
        case .failed: return Color(red: 1, green: 0.38, blue: 0.35)
        case .cancelled: return .white.opacity(0.25)
        }
    }
}

private struct NotchActionButton: View {
    enum Role {
        case normal, destructive
    }

    let title: String
    let systemImage: String
    let role: Role
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 9)
            .frame(maxHeight: .infinity)
            .background(Capsule().fill(backgroundColor))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovering = hovering && isEnabled
            guard isEnabled else { return }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var foregroundColor: Color {
        guard isEnabled else { return .white.opacity(0.3) }
        return role == .destructive ? Color(red: 1, green: 0.47, blue: 0.43) : .white.opacity(0.92)
    }

    private var backgroundColor: Color {
        guard isEnabled else { return .white.opacity(0.04) }
        if role == .destructive { return Color(red: 1, green: 0.3, blue: 0.27).opacity(isHovering ? 0.28 : 0.18) }
        return .white.opacity(isHovering ? 0.18 : 0.1)
    }
}

/// The Code mode switch. The app passes the click to CodeModeController's
/// own setEnabled, the same call as the menu bar panel's switch.
private struct NotchCodeModeSwitch: View {
    let isOn: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("Code mode")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Color.clickyCompanionOrange : Color.white.opacity(0.22))
                        .frame(width: 26, height: 15)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 11, height: 11)
                        .padding(.horizontal, 2)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
            }
            .foregroundColor(.white.opacity(isOn ? 0.95 : 0.7))
            .padding(.horizontal, 9)
            .frame(maxHeight: .infinity)
            .background(Capsule().fill(Color.white.opacity(isHovering ? 0.14 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel("Code mode")
        .accessibilityValue(isOn ? "on" : "off")
    }
}
