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
    @Environment(\.colorScheme) private var colorScheme

    public static let expandSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// How long the spring takes to settle (the app shrinks the window after it).
    public static let springSettleSeconds: TimeInterval = 0.5

    public init(content: NotchContent, layout: NotchLayout, isExpanded: Bool, actions: NotchActions, fixedAnimationDate: Date? = nil) {
        self.content = content
        self.layout = layout
        self.isExpanded = isExpanded
        self.actions = actions
        self.fixedAnimationDate = fixedAnimationDate
    }

    /// The pill's size for this content (the app sizes the panel the same way).
    public static func pillSize(content: NotchContent, layout: NotchLayout, isExpanded: Bool) -> CGSize {
        guard isExpanded else { return NotchGeometry.collapsedSize(layout: layout) }
        return NotchGeometry.expandedSize(layout: layout, agentRowCount: content.agentRows.count, hasMoreAgentsLine: content.hiddenAgentCount > 0,
                                          hasCaption: content.captionText != nil, actionStepLineCount: content.actionStepLines.count)
    }

    private var pillShape: NotchShape {
        NotchShape(topFlareRadius: NotchGeometry.topFlareRadius,
                   bottomCornerRadius: isExpanded ? NotchGeometry.expandedBottomCornerRadius : NotchGeometry.collapsedBottomCornerRadius)
    }

    public var body: some View {
        let pillSize = Self.pillSize(content: content, layout: layout, isExpanded: isExpanded)
        ZStack(alignment: .top) {
            pillShape.fill(Color.black)
            pillShape.stroke(Color.white.opacity(colorScheme == .dark ? 0.14 : 0), lineWidth: 1)
            if isExpanded {
                expandedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.08)))
            } else {
                collapsedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .frame(width: pillSize.width, height: pillSize.height, alignment: .top)
        .clipShape(pillShape)
        .contentShape(pillShape)
        .animation(Self.expandSpring, value: isExpanded)
        .animation(Self.expandSpring, value: pillSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        let bodySize = NotchGeometry.collapsedBodySize(layout: layout)
        return Group {
            if layout.hasPhysicalNotch {
                // The hardware notch hides the middle: logo in the left wing, status in the right.
                HStack(spacing: 0) {
                    logo.frame(width: NotchGeometry.physicalNotchWingWidth)
                    Spacer().frame(width: layout.notchRect.width)
                    statusLabel
                        .frame(width: NotchGeometry.physicalNotchWingWidth - 10, alignment: .leading)
                        .padding(.trailing, 10)
                }
            } else if content.statusText.isEmpty {
                logo
            } else {
                HStack(spacing: 7) {
                    logo
                    statusLabel
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .contentShape(Rectangle())
        .onTapGesture { actions.expand() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(content.statusText.isEmpty ? "Clicky" : "Clicky, \(content.statusText)")
        .accessibilityAddTraits(.isButton)
    }

    private var statusLabel: some View {
        Text(content.statusText)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.88))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var logo: some View {
        NotchLogoView(phase: content.phase, orbitingAgentCount: content.orbitingAgentIDs.count, isAnimating: content.isLogoAnimating,
                      fixedAnimationDate: fixedAnimationDate)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(spacing: 0) {
            header.frame(height: layout.headerHeight)
            Spacer().frame(height: NotchGeometry.expandedTopPadding)
            if let captionText = content.captionText {
                captionCard(captionText).frame(height: NotchGeometry.captionHeight)
                Spacer().frame(height: NotchGeometry.sectionSpacing)
            }
            if !content.actionStepLines.isEmpty {
                actionStepsCard.frame(height: NotchGeometry.actionStepsHeight(lineCount: content.actionStepLines.count))
                Spacer().frame(height: NotchGeometry.sectionSpacing)
            }
            agentsSection
                .frame(height: NotchGeometry.agentsSectionHeight(agentRowCount: content.agentRows.count, hasMoreAgentsLine: content.hiddenAgentCount > 0))
            Spacer().frame(height: NotchGeometry.sectionSpacing)
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
                    headerTitle(content.statusText.isEmpty ? "Clicky" : content.statusText, isPrimary: content.statusText.isEmpty)
                }
                .frame(width: sideWidth, alignment: .leading)
                Spacer(minLength: 0)
                runningSummaryLabel.frame(width: sideWidth, alignment: .trailing)
            }
        } else {
            HStack(spacing: 7) {
                logo
                headerTitle("Clicky", isPrimary: true)
                if !content.statusText.isEmpty { headerTitle(content.statusText, isPrimary: false) }
                Spacer(minLength: 8)
                runningSummaryLabel
            }
        }
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
        return ZStack {
            ClaudeSparkShape()
                .fill(Color.clickyCompanionOrange)
                .frame(width: Self.sparkDiameter, height: Self.sparkDiameter)
                .rotationEffect(.degrees(spinDegrees))
                .scaleEffect(pulseScale)
                .shadow(color: Color.clickyCompanionOrange.opacity(phase == .idle ? 0.35 : 0.8), radius: phase == .idle ? 2 : 4)
            ForEach(0..<visibleMiniCount, id: \.self) { miniIndex in
                ClaudeSparkShape()
                    .fill(Color.clickyCompanionOrange)
                    .frame(width: Self.miniDiameter, height: Self.miniDiameter)
                    .offset(x: Self.orbitRadius)
                    .rotationEffect(.degrees(-90 + Double(miniIndex) * 360 / Double(visibleMiniCount)))
            }
            .rotationEffect(.degrees(orbitDegrees))
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
