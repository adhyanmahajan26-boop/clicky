//
//  AgentsDashboardView.swift
//  ClickyCore
//
//  The Agents window's content: a sidebar of agents (Running, Recent) and a
//  detail pane for the selected one (status, model, timing, tokens and cost,
//  code-task details, the last log lines and the actions). Plain SwiftUI with
//  system colors, so it follows light/dark mode, and with its own button
//  style so ImageRenderer can draw it offscreen for the render test. The
//  app hosts it (AgentsWindowController) and supplies the actions; nothing
//  here acts outward or touches a window.
//

import AppKit
import SwiftUI

/// What the dashboard's buttons do (the app wires them to existing paths).
public struct AgentsDashboardActions {
    public var canCancel: (AgentRecord) -> Bool
    public var canOpenReview: (AgentRecord) -> Bool
    public var canRevealWorktree: (AgentRecord) -> Bool
    public var cancel: (AgentRecord) -> Void
    public var openReview: (AgentRecord) -> Void
    public var revealWorktree: (AgentRecord) -> Void
    public var copyLog: (AgentRecord) -> Void

    public init(canCancel: @escaping (AgentRecord) -> Bool, canOpenReview: @escaping (AgentRecord) -> Bool, canRevealWorktree: @escaping (AgentRecord) -> Bool,
                cancel: @escaping (AgentRecord) -> Void, openReview: @escaping (AgentRecord) -> Void, revealWorktree: @escaping (AgentRecord) -> Void,
                copyLog: @escaping (AgentRecord) -> Void) {
        self.canCancel = canCancel
        self.canOpenReview = canOpenReview
        self.canRevealWorktree = canRevealWorktree
        self.cancel = cancel
        self.openReview = openReview
        self.revealWorktree = revealWorktree
        self.copyLog = copyLog
    }

    /// Buttons shown by status alone, doing nothing (previews and renders).
    public static let inert = AgentsDashboardActions(
        canCancel: { $0.status.isActive }, canOpenReview: { $0.kind == .codeTask && $0.status == .running && $0.worktreePath != nil },
        canRevealWorktree: { $0.worktreePath != nil }, cancel: { _ in }, openReview: { _ in }, revealWorktree: { _ in }, copyLog: { _ in })
}

public struct AgentsDashboardView: View {
    public static let sidebarWidth: CGFloat = 270
    public static let minimumSize = CGSize(width: 760, height: 480)

    let store: AgentStore
    @Binding var selectedAgentID: String?
    let now: Date
    let actions: AgentsDashboardActions
    /// False for offscreen renders (ImageRenderer can't draw a ScrollView).
    let isScrollable: Bool

    public init(store: AgentStore, selectedAgentID: Binding<String?>, now: Date, actions: AgentsDashboardActions, isScrollable: Bool = true) {
        self.store = store
        self._selectedAgentID = selectedAgentID
        self.now = now
        self.actions = actions
        self.isScrollable = isScrollable
    }

    /// The selection, else the first running agent, else the newest one.
    var displayedRecord: AgentRecord? {
        if let selectedAgentID, let selected = store[selectedAgentID] { return selected }
        return store.runningRecords.first ?? store.recentRecords.first
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(AgentsDashboardColors.sidebarBackground)
            Rectangle()
                .fill(AgentsDashboardColors.separator)
                .frame(width: 1)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AgentsDashboardColors.windowBackground)
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            scrollable {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarSection(title: "Running", records: store.runningRecords, emptyText: "Nothing running")
                    sidebarSection(title: "Recent", records: store.recentRecords, emptyText: "No agents yet")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }

    private var sidebarHeader: some View {
        let totals = store.usageTotals()
        return VStack(alignment: .leading, spacing: 3) {
            Text("Agents")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AgentsDashboardColors.primaryText)
            Text(Self.totalsLine(totals))
                .font(.system(size: 11))
                .foregroundColor(AgentsDashboardColors.secondaryText)
                .lineLimit(1)
        }
    }

    static func totalsLine(_ totals: AgentUsageTotals) -> String {
        var parts = ["\(totals.agentCount) agent\(totals.agentCount == 1 ? "" : "s")"]
        if totals.agentsWithUsage > 0 {
            parts.append("\(AgentUsage.compact(totals.usage.totalTokens)) tokens")
            if let costText = totals.usage.costText { parts.append(costText) }
        }
        return parts.joined(separator: " · ")
    }

    private func sidebarSection(title: String, records: [AgentRecord], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AgentsDashboardColors.tertiaryText)
                Spacer()
                if !records.isEmpty {
                    Text("\(records.count)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(AgentsDashboardColors.tertiaryText)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
            if records.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundColor(AgentsDashboardColors.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            ForEach(records) { record in
                AgentSidebarRow(record: record, now: now, isSelected: record.id == displayedRecord?.id) {
                    selectedAgentID = record.id
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let record = displayedRecord {
            scrollable {
                AgentDetailView(record: record, helpers: record.kind == .brain ? store.children(of: record.id) : [], now: now, actions: actions) { helperID in
                    selectedAgentID = helperID
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundColor(AgentsDashboardColors.tertiaryText)
                Text("No agents yet")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AgentsDashboardColors.secondaryText)
                Text("Ask Clicky something and its brain, helpers and code tasks show up here.")
                    .font(.system(size: 12))
                    .foregroundColor(AgentsDashboardColors.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func scrollable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if isScrollable {
            ScrollView(.vertical) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Colors

/// System colors only, so light and dark both follow the system.
enum AgentsDashboardColors {
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let selection = Color(nsColor: .selectedContentBackgroundColor)
    static let hover = Color(nsColor: .labelColor).opacity(0.06)
    static let accent = Color(nsColor: .systemOrange)

    static func status(_ status: AgentStatus) -> Color {
        switch status {
        case .queued: return Color(nsColor: .systemGray)
        case .running: return Color(nsColor: .systemOrange)
        case .done: return Color(nsColor: .systemGreen)
        case .failed: return Color(nsColor: .systemRed)
        case .cancelled: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - Sidebar row

private struct AgentSidebarRow: View {
    let record: AgentRecord
    let now: Date
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: record.kind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? .white : AgentsDashboardColors.status(record.status))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(isSelected ? .white : AgentsDashboardColors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(isSelected ? Color.white.opacity(0.85) : AgentsDashboardColors.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(isSelected ? Color.white : AgentsDashboardColors.status(record.status))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AgentsDashboardColors.selection : (isHovering ? AgentsDashboardColors.hover : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        var parts = [record.phase.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? record.status.displayName]
        if let model = record.model { parts.append(model) }
        parts.append(AgentRecord.elapsedText(seconds: record.elapsedSeconds(now: now)))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail

private struct AgentDetailView: View {
    let record: AgentRecord
    let helpers: [AgentRecord]
    let now: Date
    let actions: AgentsDashboardActions
    let onSelectHelper: (String) -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            actionRow
            factsCard
            if let usage = record.usage { usageCard(usage) }
            if record.kind == .codeTask { codeCard }
            if !helpers.isEmpty { helpersCard }
            if let errorDescription = record.errorDescription { errorCard(errorDescription) }
            logCard
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.kind.symbolName)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(AgentsDashboardColors.status(record.status))
                .frame(width: 34, height: 34)
                .background(Circle().fill(AgentsDashboardColors.status(record.status).opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AgentsDashboardColors.primaryText)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    AgentStatusBadge(status: record.status, phase: record.phase)
                    Text(record.kind.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(AgentsDashboardColors.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if actions.canCancel(record) {
                AgentsDashboardButton(title: "Cancel", systemImage: "stop.fill", role: .destructive) { actions.cancel(record) }
            }
            if actions.canOpenReview(record) {
                AgentsDashboardButton(title: "Open review", systemImage: "doc.text.magnifyingglass", role: .prominent) { actions.openReview(record) }
            }
            if actions.canRevealWorktree(record) {
                AgentsDashboardButton(title: "Reveal worktree", systemImage: "folder", role: .normal) { actions.revealWorktree(record) }
            }
            AgentsDashboardButton(title: "Copy log", systemImage: "doc.on.doc", role: .normal) { actions.copyLog(record) }
            Spacer(minLength: 0)
        }
    }

    private var factsCard: some View {
        AgentsDashboardCard(title: nil) {
            AgentFactRow(label: "Model", value: record.usage?.model ?? record.model ?? "—")
            AgentFactRow(label: "Started", value: Self.timeFormatter.string(from: record.startedAt))
            AgentFactRow(label: record.status.isActive ? "Elapsed" : "Took", value: AgentRecord.elapsedText(seconds: record.elapsedSeconds(now: now)), isMonospaced: true)
            if let endedAt = record.endedAt {
                AgentFactRow(label: "Ended", value: Self.timeFormatter.string(from: endedAt))
            }
        }
    }

    private func usageCard(_ usage: AgentUsage) -> some View {
        AgentsDashboardCard(title: "Usage") {
            HStack(alignment: .top, spacing: 18) {
                AgentUsageFigure(label: "Input", value: AgentUsage.compact(usage.inputTokens))
                AgentUsageFigure(label: "Output", value: AgentUsage.compact(usage.outputTokens))
                AgentUsageFigure(label: "Cache read", value: AgentUsage.compact(usage.cacheReadTokens))
                AgentUsageFigure(label: "Cache write", value: AgentUsage.compact(usage.cacheCreationTokens))
                AgentUsageFigure(label: "Cost", value: usage.costText ?? "—")
                Spacer(minLength: 0)
            }
        }
    }

    private var codeCard: some View {
        AgentsDashboardCard(title: "Code task") {
            AgentFactRow(label: "Repository", value: record.repository ?? "—")
            if let branch = record.branch { AgentFactRow(label: "Branch", value: branch, isMonospaced: true) }
            if let worktreePath = record.worktreePath {
                AgentFactRow(label: "Worktree", value: (worktreePath as NSString).abbreviatingWithTildeInPath, isMonospaced: true)
            } else if let clonePath = record.clonePath {
                AgentFactRow(label: "Clone", value: (clonePath as NSString).abbreviatingWithTildeInPath, isMonospaced: true)
            }
            if let currentStep = record.currentStep { AgentFactRow(label: "Step", value: currentStep) }
            if let queuedBehindCount = record.queuedBehindCount, queuedBehindCount > 0 {
                AgentFactRow(label: "Queue", value: "\(queuedBehindCount) waiting after this")
            }
            AgentFactRow(label: "Files changed", value: record.changedFiles.isEmpty ? "None yet" : "\(record.changedFiles.count)")
            if !record.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(record.changedFiles.prefix(12), id: \.self) { filePath in
                        Text(filePath)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(AgentsDashboardColors.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if record.changedFiles.count > 12 {
                        Text("and \(record.changedFiles.count - 12) more")
                            .font(.system(size: 11))
                            .foregroundColor(AgentsDashboardColors.tertiaryText)
                    }
                }
                .padding(.leading, 110)
            }
        }
    }

    private var helpersCard: some View {
        AgentsDashboardCard(title: "Helpers") {
            ForEach(helpers) { helper in
                HStack(spacing: 8) {
                    Circle().fill(AgentsDashboardColors.status(helper.status)).frame(width: 7, height: 7)
                    Text(helper.title)
                        .font(.system(size: 12.5))
                        .foregroundColor(AgentsDashboardColors.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(helper.status.displayName) · \(AgentRecord.elapsedText(seconds: helper.elapsedSeconds(now: now)))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(AgentsDashboardColors.secondaryText)
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelectHelper(helper.id) }
                .onHover { hovering in if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }
        }
    }

    private func errorCard(_ errorDescription: String) -> some View {
        AgentsDashboardCard(title: "Error") {
            Text(errorDescription)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: .systemRed))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logCard: some View {
        AgentsDashboardCard(title: "Log") {
            if record.logLines.isEmpty {
                Text("Nothing logged yet.")
                    .font(.system(size: 12))
                    .foregroundColor(AgentsDashboardColors.tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(record.logLines.enumerated()), id: \.offset) { _, logLine in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.timeFormatter.string(from: logLine.date))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(AgentsDashboardColors.tertiaryText)
                            Text(logLine.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(AgentsDashboardColors.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct AgentStatusBadge: View {
    let status: AgentStatus
    let phase: String?

    var body: some View {
        let label = phase.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? status.displayName
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(AgentsDashboardColors.status(status))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(AgentsDashboardColors.status(status).opacity(0.15)))
    }
}

private struct AgentsDashboardCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AgentsDashboardColors.secondaryText)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AgentsDashboardColors.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(AgentsDashboardColors.separator, lineWidth: 0.5))
    }
}

private struct AgentFactRow: View {
    let label: String
    let value: String
    var isMonospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(AgentsDashboardColors.secondaryText)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(isMonospaced ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                .foregroundColor(AgentsDashboardColors.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct AgentUsageFigure: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundColor(AgentsDashboardColors.primaryText)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(AgentsDashboardColors.secondaryText)
        }
    }
}

/// A button drawn by SwiftUI itself (renders offscreen, shows a pointing hand on hover).
struct AgentsDashboardButton: View {
    enum Role {
        case normal, prominent, destructive
    }

    let title: String
    let systemImage: String
    let role: Role
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(backgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(AgentsDashboardColors.separator, lineWidth: role == .normal ? 0.5 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var foregroundColor: Color {
        switch role {
        case .normal: return AgentsDashboardColors.primaryText
        case .prominent, .destructive: return .white
        }
    }

    private var backgroundColor: Color {
        let hoverDim = isHovering ? 0.85 : 1.0
        switch role {
        case .normal: return AgentsDashboardColors.cardBackground.opacity(isHovering ? 0.7 : 1)
        case .prominent: return Color(nsColor: .controlAccentColor).opacity(hoverDim)
        case .destructive: return Color(nsColor: .systemRed).opacity(hoverDim)
        }
    }
}
