//
//  VoiceGalleryView.swift
//  ClickyCore
//
//  The Voices window's content: one row per gallery entry (number, name,
//  engine, pitch), a Play/Stop button and "Use this voice", with the active
//  voice marked. Plain SwiftUI with system colors (follows light/dark) and
//  SwiftUI-drawn buttons, so ImageRenderer can draw it offscreen for the
//  render test. Nothing here plays audio or writes settings: the app passes
//  the actions, and Play only runs when the user presses it.
//

import AppKit
import SwiftUI

public struct VoiceGalleryActions {
    public var play: (VoiceGalleryEntry) -> Void
    public var stopPlaying: () -> Void
    public var use: (VoiceGalleryEntry) -> Void

    public init(play: @escaping (VoiceGalleryEntry) -> Void, stopPlaying: @escaping () -> Void, use: @escaping (VoiceGalleryEntry) -> Void) {
        self.play = play
        self.stopPlaying = stopPlaying
        self.use = use
    }

    public static let inert = VoiceGalleryActions(play: { _ in }, stopPlaying: {}, use: { _ in })
}

public struct VoiceGalleryView: View {
    public static let preferredWidth: CGFloat = 600

    let gallery: VoiceGallery
    let activeEntryID: String?
    let playingEntryID: String?
    let actions: VoiceGalleryActions
    /// False for offscreen renders (ImageRenderer can't draw a ScrollView).
    let isScrollable: Bool

    public init(gallery: VoiceGallery, activeEntryID: String?, playingEntryID: String?, actions: VoiceGalleryActions, isScrollable: Bool = true) {
        self.gallery = gallery
        self.activeEntryID = activeEntryID
        self.playingEntryID = playingEntryID
        self.actions = actions
        self.isScrollable = isScrollable
    }

    public var body: some View {
        Group {
            if isScrollable {
                ScrollView(.vertical) { content }
            } else {
                content
            }
        }
        .frame(minWidth: Self.preferredWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VoiceGalleryColors.windowBackground)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if gallery.entries.isEmpty {
                Text("No voices found. Candidates go in ~/.clicky/voice/candidates/manifest.json.")
                    .font(.system(size: 12))
                    .foregroundColor(VoiceGalleryColors.secondaryText)
            }
            sectionRows(title: "Cloned voices (local Qwen)", entries: gallery.entries.filter(\.isQwen))
            sectionRows(title: "Mac voices (Enhanced / Premium)", entries: gallery.entries.filter { !$0.isQwen })
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Voices")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(VoiceGalleryColors.primaryText)
            Text("Play only runs when you press it. Or say \u{201C}next voice\u{201D}, \u{201C}use voice 3\u{201D}, \u{201C}previous voice\u{201D}.")
                .font(.system(size: 11))
                .foregroundColor(VoiceGalleryColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func sectionRows(title: String, entries: [VoiceGalleryEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(VoiceGalleryColors.tertiaryText)
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { rowIndex, entry in
                        if rowIndex > 0 {
                            Rectangle().fill(VoiceGalleryColors.separator).frame(height: 0.5)
                        }
                        VoiceGalleryRow(entry: entry, isActive: entry.id == activeEntryID, isPlaying: entry.id == playingEntryID, actions: actions)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(VoiceGalleryColors.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(VoiceGalleryColors.separator, lineWidth: 0.5))
            }
        }
    }
}

enum VoiceGalleryColors {
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let activeTint = Color(nsColor: .systemOrange)
    static let activeRowBackground = Color(nsColor: .systemOrange).opacity(0.10)
}

private struct VoiceGalleryRow: View {
    let entry: VoiceGalleryEntry
    let isActive: Bool
    let isPlaying: Bool
    let actions: VoiceGalleryActions

    var body: some View {
        HStack(spacing: 12) {
            Text("\(entry.number)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(isActive ? .white : VoiceGalleryColors.secondaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(isActive ? VoiceGalleryColors.activeTint : VoiceGalleryColors.separator.opacity(0.5)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(VoiceGalleryColors.primaryText)
                        .lineLimit(1)
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(VoiceGalleryColors.activeTint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(VoiceGalleryColors.activeTint, lineWidth: 1))
                    }
                }
                Text(entry.disabledReason ?? entry.detail)
                    .font(.system(size: 11))
                    .foregroundColor(entry.isEnabled ? VoiceGalleryColors.secondaryText : Color(nsColor: .systemRed))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(entry.pitchLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(VoiceGalleryColors.secondaryText)
                .frame(width: 56, alignment: .trailing)

            VoiceGalleryButton(title: isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill",
                               isProminent: false, isEnabled: canPlay) {
                if isPlaying { actions.stopPlaying() } else { actions.play(entry) }
            }
            .frame(width: 72)

            if isActive {
                Text("In use")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(VoiceGalleryColors.activeTint)
                    .frame(width: 118)
            } else {
                VoiceGalleryButton(title: "Use this voice", systemImage: "checkmark", isProminent: true, isEnabled: entry.isEnabled) {
                    actions.use(entry)
                }
                .frame(width: 118)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isActive ? VoiceGalleryColors.activeRowBackground : Color.clear)
        .opacity(entry.isEnabled ? 1 : 0.6)
    }

    private var canPlay: Bool {
        entry.isQwen ? entry.previewAudioPath != nil : true
    }
}

/// A button drawn by SwiftUI itself (renders offscreen, pointing hand on hover).
private struct VoiceGalleryButton: View {
    let title: String
    let systemImage: String
    let isProminent: Bool
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isProminent ? .white : VoiceGalleryColors.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(backgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(VoiceGalleryColors.separator, lineWidth: isProminent ? 0 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            // Only pop a cursor this button pushed (a disabled button pushes none).
            if hovering && isEnabled && !isHovering {
                NSCursor.pointingHand.push()
                isHovering = true
            } else if !hovering && isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
    }

    private var backgroundColor: Color {
        if isProminent { return Color(nsColor: .controlAccentColor).opacity(isHovering ? 0.85 : 1) }
        return VoiceGalleryColors.windowBackground.opacity(isHovering ? 0.6 : 1)
    }
}
