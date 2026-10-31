//
//  NotesLibraryViews.swift
//  leanring-buddy
//
//  The pieces of the Notes library: kind styling, filter chips, search field,
//  the empty state and the grid card (large thumbnail, kind badge, hover
//  lift with quick actions, picked-for-code state).
//

import AppKit
import SwiftUI

/// Theo's orange -> pink -> purple accent.
enum NotesAccent {
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.30)
    static let pink = Color(red: 0.96, green: 0.36, blue: 0.62)
    static let purple = Color(red: 0.62, green: 0.40, blue: 0.96)
    static let gradient = LinearGradient(colors: [orange, pink, purple], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// How each ClaudiaLibrary kind looks.
enum NotesKindStyle {
    static func label(_ kind: String) -> String {
        switch kind {
        case "notes": return "Article"
        case "research": return "Research"
        case "whiteboard": return "Whiteboard"
        case "screenshot": return "Screenshot"
        default: return kind.capitalized
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "notes": return "doc.text"
        case "research": return "sparkle.magnifyingglass"
        case "whiteboard": return "scribble.variable"
        case "screenshot": return "camera.viewfinder"
        default: return "doc"
        }
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "notes": return DS.Colors.blue400
        case "research": return Color(red: 0.72, green: 0.58, blue: 1.0)
        case "whiteboard": return Color(red: 1.0, green: 0.66, blue: 0.40)
        case "screenshot": return DS.Colors.success
        default: return DS.Colors.textSecondary
        }
    }
}

/// A rounded filter chip with a count.
struct NotesFilterChip: View {
    let title: String
    let symbol: String
    let count: Int
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
                Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit().opacity(0.6)
            }
            .foregroundColor(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(isActive ? Color.white.opacity(0.13) : Color.white.opacity(isHovering ? 0.08 : 0.045)))
            .overlay(Capsule().strokeBorder(isActive ? Color.white.opacity(0.18) : DS.Colors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isActive)
    }
}

/// The search box in the library header.
struct NotesSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textTertiary)
            TextField("Search notes", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isFocused)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(width: 240)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous).fill(DS.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
            .strokeBorder(isFocused ? Color.white.opacity(0.28) : DS.Colors.borderSubtle, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Shown when there is nothing to list.
struct NotesEmptyState: View {
    let isFiltering: Bool

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.white.opacity(0.05)).frame(width: 76, height: 76)
                Image(systemName: isFiltering ? "magnifyingglass" : "tray")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(NotesAccent.gradient)
            }
            Text(isFiltering ? "Nothing matches" : "No notes yet")
                .font(.system(size: 16, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            Text(isFiltering ? "Try another search or filter." : "Ask Theo to save an article, research a link or draw a whiteboard, and it lands here.")
                .font(.system(size: 13)).foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// One library card.
struct NotesLibraryCard: View {
    let item: ClaudiaLibrary.Item
    let isPicked: Bool
    let onTogglePick: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    private var kindColor: Color { NotesKindStyle.color(item.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
                .frame(height: 148).frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topLeading) { kindBadge.padding(9) }
                .overlay(alignment: .topTrailing) { pickControl.padding(9) }
                .overlay(alignment: .bottomTrailing) { quickActions.padding(9) }
            VStack(alignment: .leading, spacing: 5) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                Text(Self.relativeDate(item.date))
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 12)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isHovering ? DS.Colors.surface3.opacity(0.9) : DS.Colors.surface))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if isPicked {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(NotesAccent.gradient, lineWidth: 2)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isHovering ? Color.white.opacity(0.16) : DS.Colors.borderSubtle, lineWidth: 1)
            }
        }
        .shadow(color: Color.black.opacity(isHovering ? 0.45 : 0.18), radius: isHovering ? 16 : 5, x: 0, y: isHovering ? 8 : 2)
        .offset(y: isHovering ? -2 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering } }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
    }

    @State private var excerpt: String?

    /// The title without a leading "Research" the badge already says.
    private var displayTitle: String {
        let label = NotesKindStyle.label(item.kind)
        guard item.title.lowercased().hasPrefix(label.lowercased() + " ") else { return item.title }
        let rest = item.title.dropFirst(label.count + 1)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// The first words of a text note, without Markdown marks, read off the main thread.
    static func excerpt(of url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard ["md", "txt", "markdown"].contains(url.pathExtension.lowercased()),
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 1200)) ?? Data(), as: UTF8.self)
            let lines = head.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("---") && !$0.hasPrefix("![") }
                .map { $0.replacingOccurrences(of: #"[*_`>\[\]]"#, with: "", options: .regularExpression) }
            return lines.prefix(6).joined(separator: " ")
        }.value
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.isImage {
            NotesThumbnailView(url: item.url, modified: item.date, maxPixel: 640) {
                ZStack { DS.Colors.surface1; ProgressView().controlSize(.small) }
            }
            .overlay(LinearGradient(colors: [Color.black.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
        } else {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [kindColor.opacity(0.22), kindColor.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let excerpt, !excerpt.isEmpty {
                    // A text note shows its first lines, like a page peeking out.
                    Text(excerpt)
                        .font(.system(size: 10.5)).foregroundColor(DS.Colors.textSecondary).lineSpacing(2)
                        .lineLimit(6).multilineTextAlignment(.leading)
                        .padding(.horizontal, 14).padding(.top, 40).padding(.bottom, 10)
                        .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                } else {
                    Image(systemName: NotesKindStyle.symbol(item.kind))
                        .font(.system(size: 38, weight: .light))
                        .foregroundColor(kindColor.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: item.id) { excerpt = await Self.excerpt(of: item.url) }
        }
    }

    private var kindBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: NotesKindStyle.symbol(item.kind)).font(.system(size: 9.5, weight: .bold))
            Text(NotesKindStyle.label(item.kind)).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundColor(kindColor)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(kindColor.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder
    private var pickControl: some View {
        if isPicked || isHovering {
            Button(action: onTogglePick) {
                HStack(spacing: 5) {
                    Image(systemName: isPicked ? "checkmark" : "plus").font(.system(size: 10, weight: .bold))
                    Text(isPicked ? "In code" : "Use in code").font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(isPicked ? AnyShapeStyle(NotesAccent.gradient) : AnyShapeStyle(Color.black.opacity(0.6))))
                .overlay(Capsule().strokeBorder(Color.white.opacity(isPicked ? 0 : 0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(isPicked ? "Remove from the notes attached to code tasks" : "Attach to code tasks")
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        if isHovering {
            HStack(spacing: 2) {
                NotesQuickActionButton(symbol: "arrow.up.forward.app", help: "Open", isDestructive: false) { NSWorkspace.shared.open(item.url) }
                NotesQuickActionButton(symbol: "folder", help: "Show in Finder", isDestructive: false) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                NotesQuickActionButton(symbol: "trash", help: "Move to Trash", isDestructive: true, action: onDelete)
            }
            .padding(3)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    static func relativeDate(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct NotesQuickActionButton: View {
    let symbol: String
    let help: String
    let isDestructive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isHovering && isDestructive ? DS.Colors.destructiveText : Color.white.opacity(isHovering ? 1 : 0.8))
                .frame(width: 27, height: 27)
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
