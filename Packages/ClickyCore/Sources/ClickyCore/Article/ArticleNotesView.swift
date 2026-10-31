//
//  ArticleNotesView.swift
//  ClickyCore
//
//  P8: the notes panel's content and the highlighter overlay's drawing.
//  Plain SwiftUI with system colors (follows light/dark) and no ScrollView
//  when rendered offscreen, so ImageRenderer can draw both for the render
//  tests. Nothing here touches the page: the app passes the actions
//  (scroll to a note's highlight, save, close).
//
//   - ArticleNotesView: "NOTES" + the article title + a close button, the
//     summary (also spoken), numbered notes each with its quote (a note
//     whose highlight is scrolled away shows ↑ / ↓), a Save button and
//     where the notes were saved.
//   - ArticleHighlightCanvas: soft yellow highlighter strokes over the text
//     lines (no outline) and the small numbered off-screen ticks.
//

import AppKit
import SwiftUI

public struct ArticleNotesViewState: Equatable, Sendable {
    public var notes: ArticleNotes
    /// Notes whose highlight couldn't be found on the page (no link to scroll to).
    public var unmatchedNumbers: Set<Int>
    /// Notes whose highlight is scrolled out of view, and which way.
    public var offscreenDirections: [Int: ArticleHighlightTickDirection]
    public var savedPaths: [String]
    public var statusLine: String?

    public init(notes: ArticleNotes, unmatchedNumbers: Set<Int> = [], offscreenDirections: [Int: ArticleHighlightTickDirection] = [:],
                savedPaths: [String] = [], statusLine: String? = nil) {
        self.notes = notes
        self.unmatchedNumbers = unmatchedNumbers
        self.offscreenDirections = offscreenDirections
        self.savedPaths = savedPaths
        self.statusLine = statusLine
    }
}

public struct ArticleNotesViewActions {
    public var selectNote: (Int) -> Void
    public var save: () -> Void
    public var close: () -> Void

    public init(selectNote: @escaping (Int) -> Void, save: @escaping () -> Void, close: @escaping () -> Void) {
        self.selectNote = selectNote
        self.save = save
        self.close = close
    }

    public static let inert = ArticleNotesViewActions(selectNote: { _ in }, save: {}, close: {})
}

public enum ArticleNotesColors {
    // The theme picked in Setup (v2.ui.theme); "system" keeps the Mac's colours.
    private static var palette: ClaudiaTheme.Palette? { ClickySettings.uiTheme.palette }
    public static var highlighterYellow: Color { palette.map { ClaudiaTheme.color($0.highlighter) } ?? Color(red: 1.0, green: 0.86, blue: 0.2) }
    static var panelBackground: Color { palette.map { ClaudiaTheme.color($0.panel) } ?? Color(nsColor: .windowBackgroundColor) }
    static var primaryText: Color { palette.map { ClaudiaTheme.color($0.text) } ?? Color(nsColor: .labelColor) }
    static var secondaryText: Color { palette.map { ClaudiaTheme.color($0.secondary) } ?? Color(nsColor: .secondaryLabelColor) }
    static var tertiaryText: Color { palette.map { ClaudiaTheme.color($0.tertiary) } ?? Color(nsColor: .tertiaryLabelColor) }
    static var separator: Color { palette.map { ClaudiaTheme.color($0.line) } ?? Color(nsColor: .separatorColor) }
    static var rowHover: Color { primaryText.opacity(0.06) }
}

public struct ArticleNotesView: View {
    let state: ArticleNotesViewState
    let actions: ArticleNotesViewActions
    let isScrollable: Bool
    /// P9 live writing: characters revealed so far (Int.max = all, e.g. offscreen renders and Reduce Motion).
    @State private var revealedCharacters = Int.max
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    private var reveal: NotesStreamReveal { NotesStreamReveal(notes: state.notes) }

    /// The app's panel writes notes in live; offscreen renders show them finished.
    let animatesWriting: Bool

    public init(state: ArticleNotesViewState, actions: ArticleNotesViewActions, isScrollable: Bool = true, animatesWriting: Bool = false) {
        self.animatesWriting = animatesWriting
        self.state = state
        self.actions = actions
        self.isScrollable = isScrollable
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(ArticleNotesColors.separator)
            Group {
                if isScrollable {
                    ScrollView(.vertical) { content }
                } else {
                    content
                }
            }
            Divider().overlay(ArticleNotesColors.separator)
            footer
        }
        .background(ArticleNotesColors.panelBackground)
        .task(id: state.notes) { await streamIn() }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ArticleNotesColors.separator, lineWidth: 0.5))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NOTES")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(ArticleNotesColors.secondaryText)
                Text(state.notes.title.isEmpty ? "Article" : state.notes.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ArticleNotesColors.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            ArticleNotesIconButton(systemName: "xmark", help: "Close notes (the highlights go too)", action: actions.close)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !state.notes.summary.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(ArticleNotesColors.highlighterYellow).frame(width: 3)
                    StreamingText(visible: reveal.visible(segment: 0, revealed: revealedCharacters))
                        .font(.system(size: 12.5))
                        .foregroundColor(ArticleNotesColors.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(state.notes.items.enumerated()), id: \.offset) { index, item in
                    ArticleNoteRow(number: index + 1, item: item,
                                   noteText: reveal.visible(segment: 1 + index * 2, revealed: revealedCharacters),
                                   quoteText: reveal.visible(segment: 2 + index * 2, revealed: revealedCharacters),
                                   isLinked: !state.unmatchedNumbers.contains(index + 1),
                                   offscreenDirection: state.offscreenDirections[index + 1], select: { actions.selectNote(index + 1) })
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Writes the notes in at about 50 characters a second, like a streamed answer.
    private func streamIn() async {
        let total = reveal.totalCharacters
        guard animatesWriting, !reducesMotion, total > 0 else {
            revealedCharacters = Int.max
            return
        }
        revealedCharacters = 0
        let step = 3
        let interval = UInt64(Double(step) / NotesStreamReveal.charactersPerSecond * 1_000_000_000)
        while revealedCharacters < total {
            try? await Task.sleep(nanoseconds: interval)
            if Task.isCancelled { return }
            revealedCharacters = min(total, revealedCharacters + step)
        }
        revealedCharacters = Int.max
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if let savedPath = state.savedPaths.first {
                    Text("Saved to \((savedPath as NSString).abbreviatingWithTildeInPath)")
                        .font(.system(size: 10.5))
                        .foregroundColor(ArticleNotesColors.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text(state.statusLine ?? "Say \u{201C}save my notes\u{201D} or press Save.")
                        .font(.system(size: 10.5))
                        .foregroundColor(ArticleNotesColors.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            ArticleNotesTextButton(title: "Save", systemName: "square.and.arrow.down", action: actions.save)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// Settled text, the newest characters lighter, then Clicky's orange caret while writing.
struct StreamingText: View {
    let visible: NotesStreamReveal.Visible

    var text: Text {
        Text(visible.settled)
            + Text(visible.tail).foregroundColor(ArticleNotesColors.primaryText.opacity(0.45))
            + Text(visible.hasCaret ? "\u{258D}" : "").foregroundColor(ClickySettings.uiTheme.palette.map { ClaudiaTheme.color($0.accent) } ?? Color(red: 0.85, green: 0.47, blue: 0.34))
    }

    var body: some View { text }
}

private struct ArticleNoteRow: View {
    let number: Int
    let item: ArticleNoteItem
    let noteText: NotesStreamReveal.Visible
    let quoteText: NotesStreamReveal.Visible
    let isLinked: Bool
    let offscreenDirection: ArticleHighlightTickDirection?
    let select: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 9) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundColor(.black.opacity(0.8))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(ArticleNotesColors.highlighterYellow.opacity(isLinked ? 0.9 : 0.35)))
                VStack(alignment: .leading, spacing: 3) {
                    StreamingText(visible: noteText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(ArticleNotesColors.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.quote.isEmpty && !(quoteText.settled + quoteText.tail).isEmpty {
                        (Text("\u{201C}") + StreamingText(visible: quoteText).text + Text(quoteText.hasCaret ? "" : "\u{201D}"))
                            .font(.system(size: 11).italic())
                            .foregroundColor(ArticleNotesColors.secondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let offscreenDirection {
                    Image(systemName: offscreenDirection == .above ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(ArticleNotesColors.tertiaryText)
                        .padding(.top, 3)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(isHovering && isLinked ? ArticleNotesColors.rowHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isLinked)
        .help(isLinked ? "Show this highlight on the page" : "This sentence wasn't found on the page")
        .onHover { hovering in
            isHovering = hovering
            guard isLinked else { return }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private struct ArticleNotesIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(ArticleNotesColors.secondaryText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(ArticleNotesColors.primaryText.opacity(isHovering ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private struct ArticleNotesTextButton: View {
    let title: String
    let systemName: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(.black.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(ArticleNotesColors.highlighterYellow.opacity(isHovering ? 1 : 0.85)))
        }
        .buttonStyle(.plain)
        .help("Save the notes as Markdown and PDF in ~/Clicky Notes")
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Highlighter overlay

/// Draws a layout inside an overlay whose top-left is `originCG` (CG global points).
public struct ArticleHighlightCanvas: View {
    let layout: ArticleHighlightLayout
    let originCG: CGPoint

    public static let strokeOpacity = 0.36

    public init(layout: ArticleHighlightLayout, originCG: CGPoint) {
        self.layout = layout
        self.originCG = originCG
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for stroke in layout.strokes {
                    let local = stroke.rect.offsetBy(dx: -originCG.x, dy: -originCG.y)
                    context.fill(Path(roundedRect: local, cornerRadius: 2.5), with: .color(ArticleNotesColors.highlighterYellow.opacity(Self.strokeOpacity)))
                }
            }
            ForEach(layout.ticks, id: \.number) { tick in
                let local = tick.rect.offsetBy(dx: -originCG.x, dy: -originCG.y)
                HStack(spacing: 1) {
                    Image(systemName: tick.direction == .above ? "chevron.up" : "chevron.down").font(.system(size: 6.5, weight: .heavy))
                    Text("\(tick.number)").font(.system(size: 8, weight: .bold).monospacedDigit())
                }
                .foregroundColor(.black.opacity(0.75))
                .frame(width: local.width, height: local.height)
                .background(Capsule().fill(ArticleNotesColors.highlighterYellow.opacity(0.92)))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                .offset(x: local.minX, y: local.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
