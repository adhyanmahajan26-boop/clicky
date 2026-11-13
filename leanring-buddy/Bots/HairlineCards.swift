//
//  HairlineCards.swift
//  leanring-buddy
//
//  The chat's richer answers: a long reply as a brief card that opens to the full document, and a [CHOOSE: …] question as
//  a card with option tiles. Also the live dot and Clicky's waveform.
//

import AppKit
import ClickyCore
import QuartzCore
import SwiftUI

/// A dot with a ring that spreads while something's live. The ring runs in Core Animation: no work per frame.
struct LiveDot: View {
    var color: Color = DS.Colors.accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LiveDotRepresentable(color: NSColor(color), isDark: scheme == .dark).frame(width: 7, height: 7)
    }
}

private struct LiveDotRepresentable: NSViewRepresentable {
    let color: NSColor
    let isDark: Bool

    func makeNSView(context: Context) -> LiveDotNSView { LiveDotNSView() }
    func updateNSView(_ view: LiveDotNSView, context: Context) { view.update(color: color) }
}

private final class LiveDotNSView: NSView {
    private let ring = CALayer()
    private let dot = CALayer()
    private var color: NSColor = .orange

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(color: NSColor) {
        self.color = color
        applyColor()
    }

    override func viewDidChangeEffectiveAppearance() { applyColor() }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let resolved = color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor
            dot.backgroundColor = resolved
            ring.backgroundColor = resolved
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [ring, dot] {
            item.frame = bounds
            item.cornerRadius = bounds.width / 2
        }
        CATransaction.commit()
        animate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    private func animate() {
        guard window != nil, DS.Motion.level == .lively else {
            ring.removeAllAnimations()
            ring.opacity = 0
            return
        }
        // Already pulsing: starting over on every redraw would make it stutter.
        guard ring.animation(forKey: "pulse") == nil else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.7
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.8
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        ring.opacity = 0
        ring.add(group, forKey: "pulse")
    }
}

/// Five bars rising and falling while Clicky listens, in Core Animation.
struct ListeningWave: View {
    var body: some View { ListeningWaveRepresentable().frame(width: 20.5, height: 16) }
}

private struct ListeningWaveRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> ListeningWaveNSView { ListeningWaveNSView() }
    func updateNSView(_ view: ListeningWaveNSView, context: Context) { view.refresh() }
}

private final class ListeningWaveNSView: NSView {
    private var bars: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        for _ in 0..<5 {
            let bar = CALayer()
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        refresh()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }
    override func viewDidChangeEffectiveAppearance() { refresh() }

    func refresh() {
        var color = NSColor(DS.Colors.accent).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor(DS.Colors.accent).usingColorSpace(.sRGB)?.cgColor ?? color }
        let lively = window != nil && DS.Motion.level == .lively
        let rest: [CGFloat] = [0.5, 0.8, 1, 0.7, 0.45]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.transform = CATransform3DIdentity
            bar.frame = CGRect(x: CGFloat(index) * 4.5, y: 0, width: 2.5, height: bounds.height)
            bar.cornerRadius = 1.25
            bar.backgroundColor = color
            bar.transform = CATransform3DMakeScale(1, rest[index], 1)
            guard lively else {
                bar.removeAllAnimations()
                continue
            }
            // Already moving: starting over on every redraw would make it stutter.
            guard bar.animation(forKey: "wave") == nil else { continue }
            let wave = CABasicAnimation(keyPath: "transform.scale.y")
            wave.fromValue = 0.35
            wave.toValue = 1
            wave.duration = 0.5
            wave.autoreverses = true
            wave.repeatCount = .infinity
            wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            wave.timeOffset = 1 - Double(index) * 0.15
            wave.isRemovedOnCompletion = false
            bar.add(wave, forKey: "wave")
        }
        CATransaction.commit()
    }
}

extension View {
    /// Makes this view open a menu. A macOS menu flattens whatever label it's given, so the label here is an empty image
    /// the size of this view, laid over it.
    func coverMenu<Items: View>(help: String = "", @ViewBuilder items: @escaping () -> Items) -> some View {
        overlay(GeometryReader { box in
            Menu(content: items) { Image(nsImage: NSImage(size: box.size)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: box.size.width, height: box.size.height)
                .help(help)
        })
    }
}

/// Parsing every message on every redraw adds up in a long chat, so each message's card is worked out once.
@MainActor
enum BotMessageCards {
    private static var briefs: [String: BriefCard?] = [:]

    static func brief(for message: BotChatMessage) -> BriefCard? {
        if let known = briefs[message.id] { return known }
        let card = BriefCard.parse(message.text)
        if briefs.count > 400 { briefs.removeAll() }
        briefs[message.id] = .some(card)
        return card
    }
}

/// A long answer, read as an article: cover on the left, serif title, excerpt and sections. Opens to the whole thing.
struct BriefCardView: View {
    let card: BriefCard
    let text: String
    let at: Date
    let author: NativeBot
    /// Other bots the document mentions, for the cover.
    var cast: [NativeBot] = []
    @State private var reading = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                cover
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Text(card.kind.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundColor(DS.Colors.accentText)
                        Text("· \(card.minutes) min read · \(Self.when(at))").font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary)
                    }
                    Text(card.title).font(.system(size: 21, weight: .bold, design: .serif)).foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true).padding(.top, 6).padding(.bottom, 6)
                    Text(card.excerpt).font(.system(size: 12.5)).foregroundColor(DS.Colors.textSecondary).lineSpacing(3).lineLimit(3)
                    if !card.sections.isEmpty {
                        FlowLayout(spacing: 6, centered: false) {
                            ForEach(card.sections, id: \.self) { section in
                                Text(section).font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.selected))
                            }
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
            HStack(spacing: 8) {
                Button { reading = true } label: {
                    HStack(spacing: 6) { HairlineIcon(name: "open", size: 15, color: DS.Colors.textOnAccent); Text("Open") }
                }
                .buttonStyle(.theoPrimary)
                Button { share() } label: {
                    HStack(spacing: 6) { HairlineIcon(name: "share", size: 15, color: DS.Colors.textPrimary); Text("Share") }
                }
                .buttonStyle(.theoSecondary).help("Copy the document")
                Spacer()
                CrewAvatar(look: author.crewLook, size: 18, moves: false, interactive: false)
                Text("by \(author.name)").font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovering ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .sheet(isPresented: $reading) { BriefReaderSheet(card: card, text: text, author: author) { reading = false } }
    }

    /// Whoever the document's about, in little screens.
    private var cover: some View {
        let figures = Array(([author] + cast).prefix(4))
        return ZStack {
            DS.Colors.surface
            VStack(spacing: 10) {
                ForEach(0..<(figures.count > 2 ? 2 : 1), id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            if index < figures.count {
                                CrewAvatar(look: figures[index].crewLook, size: figures.count == 1 ? 60 : 34, pose: index == 0 ? .working : .awake)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            if column == 0 { Rectangle().fill(DS.Colors.borderStrong).frame(width: 1) }
                        }
                    }
                    .frame(height: 62)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                }
            }
            .padding(18)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) { Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1) }
    }

    private func share() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func when(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 90 ? "just now" : date.formatted(.relative(presentation: .named))
    }
}

/// The whole document.
struct BriefReaderSheet: View {
    let card: BriefCard
    let text: String
    let author: NativeBot
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BotAvatar(bot: author, size: 28, state: .idle)
                Text("\(card.kind) by \(author.name)").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Close", action: onClose).buttonStyle(.theoSecondary).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(card.title).font(.system(size: 28, weight: .bold, design: .serif)).foregroundColor(DS.Colors.textPrimary).textSelection(.enabled)
                    RichBlock(text: body(of: text))
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 32).padding(.vertical, 26)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 780, height: 680)
        .background(DS.Colors.background)
        .modifier(TheoAppearanceRoot())
    }

    /// The title is drawn above, so a first-line heading doesn't show twice.
    private func body(of text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        guard lines.first?.hasPrefix("#") == true else { return text }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// "Theo needs one call": a question with option tiles. Confirm sends the answer as the owner's reply. Left alone with the
/// chat open it picks the highlighted option after ten minutes; a card that's gone stale stays waiting instead.
struct BotCallCard: View {
    let call: BotCallPrompt
    let author: NativeBot
    let at: Date
    /// False once the owner has replied after it.
    let isOpen: Bool
    let onAnswer: (String) -> Void
    @State private var picked = 0
    @State private var answered: String?

    private var deadline: Date { at.addingTimeInterval(Double(BotCallPrompt.autoPickMinutes) * 60) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if isOpen && answered == nil { LiveDot() } else { Circle().fill(DS.Colors.textTertiary).frame(width: 7, height: 7) }
                Text(isOpen && answered == nil ? "\(author.name) needs one call" : "\(author.name) asked").font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary)
                Spacer()
                if isOpen && answered == nil {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(countdown(now: context.date)).font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }
            Text(call.question).font(.system(size: 14.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6).padding(.bottom, 12)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Array(call.options.enumerated()), id: \.offset) { index, option in
                    tile(index, option)
                }
            }
            if isOpen && answered == nil {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Skip") { answer("Skip this one for now.") }.buttonStyle(.theoGhost)
                    Button("Confirm") { answer(call.options[picked].title) }.buttonStyle(.theoPrimary)
                }
                .padding(.top, 12)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        .task(id: isOpen) {
            guard isOpen else { return }
            let wait = deadline.timeIntervalSinceNow
            // An old card reopened hours later doesn't decide anything by itself.
            guard wait > -3600 else { return }
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled, answered == nil, isOpen else { return }
            answer(call.options[picked].title)
        }
    }

    private func answer(_ text: String) {
        guard answered == nil else { return }
        answered = text
        onAnswer(text)
    }

    private func countdown(now: Date) -> String {
        let minutes = Int((deadline.timeIntervalSince(now) / 60).rounded(.up))
        return minutes > 0 ? "auto-picks in \(minutes) min" : "waiting for you"
    }

    private func tile(_ index: Int, _ option: BotCallPrompt.Option) -> some View {
        let on = picked == index
        return Button { if isOpen && answered == nil { picked = index } } label: {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    if index % 2 == 0 {
                        RoundedRectangle(cornerRadius: 2).fill(on ? DS.Colors.accent : DS.Colors.borderStrong)
                        RoundedRectangle(cornerRadius: 2).fill(on ? DS.Colors.accent : DS.Colors.borderStrong)
                    } else {
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2).fill(on ? DS.Colors.accent : DS.Colors.borderStrong)
                            RoundedRectangle(cornerRadius: 2).fill(on ? DS.Colors.accent : DS.Colors.borderStrong)
                        }
                    }
                }
                .padding(3).frame(width: 46, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    if !option.detail.isEmpty {
                        Text(option.detail).font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(on ? DS.Colors.accentSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(on ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
