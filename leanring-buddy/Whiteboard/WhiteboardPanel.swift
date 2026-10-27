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
        let screen = forcedScreen ?? NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.screens.first
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

    var body: some View {
        let palette = boardController.theme.palette
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                palette.background
                Group {
                    if let scene = boardController.scene, let renderState = boardController.renderState {
                        WhiteboardView(scene: scene, state: renderState, theme: boardController.theme, reducesMotion: reducesMotion)
                    } else if !boardController.shellWorkerTitles.isEmpty {
                        WhiteboardShellView(workerTitles: boardController.shellWorkerTitles, palette: palette, reducesMotion: reducesMotion)
                    } else {
                        Text(AttributedString(boardController.placeholderText))
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .foregroundColor(palette.mutedInk)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                boardControls(palette: palette)
            }
            if !boardController.relatedLinks.isEmpty {
                linksStrip(palette: palette)
                    .frame(height: BoardController.linksStripHeight)
            }
        }
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.ink.opacity(0.12), lineWidth: 1))
    }
}

extension WhiteboardPanelRootView {
    /// × closes; the arrows grow the side board into the big one (then full screen).
    func boardControls(palette: WhiteboardPalette) -> some View {
        HStack(spacing: 6) {
            Button(action: { boardController.expand() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Expand the board")
            .accessibilityLabel("Expand board")
            Button(action: { boardController.close() }) {
                Image(systemName: "xmark")
            }
            .help("Close the board (Esc)")
            .accessibilityLabel("Close board")
        }
        .buttonStyle(BoardControlButtonStyle(palette: palette))
        .padding(10)
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
            .padding(.horizontal, isWide ? 9 : 7)
            .padding(.vertical, isWide ? 5 : 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.ink.opacity(configuration.isPressed ? 0.16 : 0.08)))
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
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundColor(palette.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 18)], spacing: 18) {
                ForEach(Array(workerTitles.enumerated()), id: \.offset) { workerIndex, workerTitle in
                    VStack(spacing: 12) {
                        OrbitingLogo(color: palette.strokeColors[.orange] ?? palette.ink, phase: Double(workerIndex) * 0.7, reducesMotion: reducesMotion)
                            .frame(width: 54, height: 54)
                        Text(AttributedString(workerTitle))
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundColor(palette.mutedInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(RoundedRectangle(cornerRadius: 12).stroke(palette.sectionStroke, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
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
