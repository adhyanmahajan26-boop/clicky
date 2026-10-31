//
//  WhiteboardPanel.swift
//  leanring-buddy
//
//  The floating window the board is drawn in: a borderless, non-activating,
//  resizable NSPanel at .floating level on every Space (and over full-screen
//  apps), sized to the mouse screen's visible frame inset 6 % (the whole
//  visible frame in full-screen mode). It can become key so its keys work
//  without activating Clicky: Esc close, ←/→ step, Space pause/resume,
//  r replay, e export, c copy, f full screen, 0 fit, +/− zoom. Keys go
//  through a local key monitor while the panel is key (keyDown is the
//  fallback). The SwiftUI root shows the board, the workers' shell, or a
//  "drawing…" placeholder.
//

import AppKit
import ClickyCore
import SwiftUI

final class WhiteboardPanel: NSPanel {
    /// Returns true when it handled the key.
    var keyHandler: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 480, height: 360)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Test-only (debug inbox "boardDisplay"): the display the board opens on, instead of the mouse's.
    /// Never set from a model answer.
    static var debugForcedDisplayID: CGDirectDisplayID?

    /// The board's frame on the screen the mouse is on (or the debug-forced display).
    static func frame(fullScreen: Bool, side: Bool = false) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let forcedScreen = debugForcedDisplayID.flatMap { displayID in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
        }
        // Claudia's own screen when one is picked, else the pointer's.
        let screen = forcedScreen ?? ClaudiaScreen.picked ?? NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        guard !fullScreen else { return visibleFrame }
        if side {
            // Docked at the right edge, a third of the screen wide: the owner keeps working next to it.
            let width = min(visibleFrame.width - 32, max(520, visibleFrame.width * 0.34))
            let height = min(visibleFrame.height - 32, max(460, visibleFrame.height * 0.72))
            return NSRect(x: visibleFrame.maxX - width - 16, y: visibleFrame.midY - height / 2, width: width, height: height)
        }
        return visibleFrame.insetBy(dx: visibleFrame.width * 0.06, dy: visibleFrame.height * 0.06)
    }
}

/// What the panel shows.
struct WhiteboardPanelRootView: View {
    @ObservedObject var boardController: BoardController
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var exportFlash = false

    var body: some View {
        let palette = boardController.theme.palette
        let cornerRadius: CGFloat = 16
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                palette.background
                Group {
                    if let scene = boardController.scene, let renderState = boardController.renderState {
                        WhiteboardView(scene: scene, state: renderState, theme: boardController.theme, reducesMotion: reducesMotion)
                    } else if !boardController.shellWorkerTitles.isEmpty {
                        WhiteboardShellView(workerTitles: boardController.shellWorkerTitles, palette: palette, reducesMotion: reducesMotion)
                    } else {
                        VStack(spacing: 12) {
                            OrbitingLogo(color: palette.strokeColors[.orange] ?? palette.ink, phase: 0, reducesMotion: reducesMotion)
                                .frame(width: 54, height: 54)
                            Text(AttributedString(boardController.placeholderText))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(palette.mutedInk)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                boardToolbar(palette: palette)
                    .padding(.bottom, boardController.scene == nil ? 16 : WhiteboardScene.subtitleBarHeight + 14)
            }
            if !boardController.relatedLinks.isEmpty {
                linksStrip(palette: palette)
                    .frame(height: BoardController.linksStripHeight)
            }
        }
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(palette.isDark ? 0.10 : 0.0), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(palette.ink.opacity(0.12), lineWidth: 1))
    }
}

extension WhiteboardPanelRootView {
    /// A floating capsule: step back / next, replay, pause | expand, export, close.
    func boardToolbar(palette: WhiteboardPalette) -> some View {
        let hasBoard = boardController.scene != nil
        let isPaused = boardController.renderState?.isPaused == true
        return HStack(spacing: 2) {
            if hasBoard {
                BoardToolbarButton(symbol: "chevron.left", help: "Previous step (←)", palette: palette) { boardController.back() }
                BoardToolbarButton(symbol: "chevron.right", help: "Next step (→)", palette: palette) { boardController.next() }
                BoardToolbarButton(symbol: "arrow.counterclockwise", help: "Replay (R)", palette: palette) { boardController.replay() }
                BoardToolbarButton(symbol: isPaused ? "play.fill" : "pause.fill", help: isPaused ? "Resume (Space)" : "Pause (Space)", palette: palette) { boardController.togglePause() }
                BoardToolbarDivider(palette: palette)
                BoardToolbarButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Expand the board", palette: palette) { boardController.expand() }
                BoardToolbarButton(symbol: exportFlash ? "checkmark" : "square.and.arrow.up", help: "Export PNG, PDF and board file (E)", palette: palette) {
                    if boardController.exportBoard() != nil {
                        exportFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { exportFlash = false }
                    }
                }
                BoardToolbarDivider(palette: palette)
            } else {
                BoardToolbarButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Expand the board", palette: palette) { boardController.expand() }
            }
            BoardToolbarButton(symbol: "xmark", help: "Close the board (Esc)", palette: palette, isDestructive: true) { boardController.close() }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(palette.isDark ? Color(white: 0.11, opacity: 0.92) : Color.white.opacity(0.92))
        )
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(palette.ink.opacity(0.14), lineWidth: 1))
        .shadow(color: Color.black.opacity(palette.isDark ? 0.45 : 0.16), radius: 14, x: 0, y: 6)
    }

    /// Search results for the board's topic, each clickable, plus "Deep research" and "Expand".
    func linksStrip(palette: WhiteboardPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Read more")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.mutedInk)
                Spacer()
                Button(action: { boardController.startDeepResearch() }) {
                    Label(boardController.deepResearchStarted ? "Researching with Haiku agents…" : "Deep research (Haiku agents)",
                          systemImage: "sparkles")
                }
                .disabled(boardController.deepResearchStarted)
                .accessibilityLabel("Deep research")
                if boardController.isSideBoard {
                    Button(action: { boardController.expand() }) {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
            }
            .buttonStyle(BoardControlButtonStyle(palette: palette, isWide: true))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(boardController.relatedLinks) { link in
                        Button(action: { NSWorkspace.shared.open(link.url) }) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(link.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(link.url.host ?? "").font(.system(size: 9)).foregroundColor(palette.mutedInk).lineLimit(1)
                            }
                            .frame(maxWidth: 220, alignment: .leading)
                        }
                        .buttonStyle(BoardControlButtonStyle(palette: palette, isWide: true))
                        .help(link.url.absoluteString)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.ink.opacity(0.04))
        .overlay(alignment: .top) { Rectangle().fill(palette.ink.opacity(0.08)).frame(height: 1) }
    }
}

/// One round icon button of the floating toolbar, with a hover highlight.
private struct BoardToolbarButton: View {
    let symbol: String
    let help: String
    let palette: WhiteboardPalette
    var isDestructive = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovering && isDestructive ? Color(red: 1.0, green: 0.45, blue: 0.42) : palette.ink.opacity(isHovering ? 1 : 0.78))
                .frame(width: 30, height: 30)
                .background(Circle().fill(palette.ink.opacity(isHovering ? 0.10 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct BoardToolbarDivider: View {
    let palette: WhiteboardPalette
    var body: some View {
        Rectangle().fill(palette.ink.opacity(0.14)).frame(width: 1, height: 16).padding(.horizontal, 4)
    }
}

/// A small rounded button in the board's own colours.
struct BoardControlButtonStyle: ButtonStyle {
    let palette: WhiteboardPalette
    var isWide = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: isWide ? 11 : 12, weight: .semibold))
            .foregroundColor(palette.ink)
            .padding(.horizontal, isWide ? 10 : 7)
            .padding(.vertical, isWide ? 5 : 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.ink.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Rectangle())
    }
}

/// While helpers research a several-questions board: one frame per worker
/// with a small logo orbiting in it.
struct WhiteboardShellView: View {
    let workerTitles: [String]
    let palette: WhiteboardPalette
    let reducesMotion: Bool

    var body: some View {
        VStack(spacing: 18) {
            Text(AttributedString("Getting the board ready…"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(palette.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 18)], spacing: 18) {
                ForEach(Array(workerTitles.enumerated()), id: \.offset) { workerIndex, workerTitle in
                    VStack(spacing: 12) {
                        OrbitingLogo(color: palette.strokeColors[.orange] ?? palette.ink, phase: Double(workerIndex) * 0.7, reducesMotion: reducesMotion)
                            .frame(width: 54, height: 54)
                        Text(AttributedString(workerTitle))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(palette.mutedInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.defaultBoxFill))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.ink.opacity(0.10), lineWidth: 1))
                }
            }
            .padding(.horizontal, 40)
        }
        .padding(30)
    }
}

/// A small dot circling a spark, Clicky's "working" sign.
private struct OrbitingLogo: View {
    let color: Color
    let phase: Double
    let reducesMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reducesMotion)) { context in
            let angle = (reducesMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 2.4) + phase
            ZStack {
                Image(systemName: "sparkle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(color)
                Circle()
                    .fill(color.opacity(0.85))
                    .frame(width: 8, height: 8)
                    .offset(x: cos(angle) * 22, y: sin(angle) * 22)
            }
        }
    }
}
