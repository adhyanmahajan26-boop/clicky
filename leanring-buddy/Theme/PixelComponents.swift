//
//  PixelComponents.swift
//  leanring-buddy
//
//  The Pixel status language as views: the badge, the status pill (badge shape plus the word), the small card every ask
//  and failure uses, the one line it folds to once answered, and the alert panel. Sizes and colours are kit/tokens.json.
//  Green is working, yellow needs you, red failed; colour is never the only signal.
//

import AppKit
import Combine
import ClickyCore
import SwiftUI

// MARK: - Status colours

extension PixelTone {
    /// The pill's words, readable on both themes.
    var text: Color {
        switch self {
        case .working, .ok: return DS.Colors.adaptive(dark: 0x22D391, light: 0x0A7F54)
        case .needs: return DS.Colors.adaptive(dark: 0xFFD938, light: 0x7A5B00)
        case .failed: return DS.Colors.adaptive(dark: 0xFF6B7C, light: 0xC7283B)
        case .done: return DS.Colors.textPrimary
        case .checking, .quiet: return DS.Colors.adaptive(dark: 0xA3A3AB, light: 0x55555C)
        }
    }

    /// The pill's soft fill.
    var tint: Color {
        switch self {
        case .working, .ok: return DS.Colors.dynamicColor { NSColor(srgbRed: $0 ? 34 / 255 : 16 / 255, green: $0 ? 211 / 255 : 160 / 255, blue: $0 ? 145 / 255 : 105 / 255, alpha: 0.13) }
        case .needs: return DS.Colors.dynamicColor { $0 ? NSColor(srgbRed: 1, green: 217 / 255, blue: 56 / 255, alpha: 0.14) : NSColor(srgbRed: 245 / 255, green: 196 / 255, blue: 0, alpha: 0.24) }
        case .failed: return DS.Colors.dynamicColor { NSColor(srgbRed: 1, green: 74 / 255, blue: 94 / 255, alpha: $0 ? 0.16 : 0.12) }
        case .done: return DS.Colors.dynamicColor { NSColor(white: $0 ? 1 : 0, alpha: $0 ? 0.1 : 0.07) }
        case .checking, .quiet: return DS.Colors.dynamicColor { NSColor(white: $0 ? 1 : 0, alpha: $0 ? 0.06 : 0.05) }
        }
    }

    /// A card's border in this tone: yellow at 42% for an ask, red at 50% for a failure.
    var cardBorder: Color {
        switch self {
        case .needs: return DS.Colors.dynamicColor { $0 ? NSColor(srgbRed: 1, green: 217 / 255, blue: 56 / 255, alpha: 0.42) : NSColor(srgbRed: 200 / 255, green: 150 / 255, blue: 0, alpha: 0.6) }
        case .failed: return DS.Colors.dynamicColor { $0 ? NSColor(srgbRed: 1, green: 74 / 255, blue: 94 / 255, alpha: 0.5) : NSColor(srgbRed: 220 / 255, green: 50 / 255, blue: 70 / 255, alpha: 0.5) }
        default: return DS.Colors.borderSubtle
        }
    }

    /// The solid colour (a bar, a lit step).
    var solid: Color { Color(hex: fill) }
}

// MARK: - Badge

/// One badge shape, drawn with Core Animation layers so its spin or pulse costs nothing per frame.
struct PixelBadge: View {
    let tone: PixelTone
    var size: CGFloat = 14
    /// The surface behind it, for the ring; nil draws no ring (pills).
    var ring: Color? = nil
    var animated = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        PixelBadgeRepresentable(tone: tone, size: size, ring: ring.map { NSColor($0) }, isDark: scheme == .dark, animated: animated && !DS.Motion.isReduced)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct PixelBadgeRepresentable: NSViewRepresentable {
    let tone: PixelTone
    let size: CGFloat
    let ring: NSColor?
    let isDark: Bool
    let animated: Bool

    func makeNSView(context: Context) -> PixelBadgeNSView { PixelBadgeNSView() }

    func updateNSView(_ view: PixelBadgeNSView, context: Context) {
        view.configure(tone: tone, size: size, ring: ring, isDark: isDark, animated: animated)
    }
}

final class PixelBadgeNSView: NSView {
    private let host = CALayer()
    private let badge = PixelBadgeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = false
        // The badge paths are y-down, like the figure's.
        host.isGeometryFlipped = true
        host.anchorPoint = .zero
        layer?.addSublayer(host)
        host.addSublayer(badge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(tone: PixelTone, size: CGFloat, ring: NSColor?, isDark: Bool, animated: Bool) {
        var ringColor: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { ringColor = ring?.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = CGRect(x: 0, y: 0, width: size, height: size)
        badge.configure(tone: tone, side: size, ring: ringColor, isDark: isDark, animated: animated)
        badge.anchorPoint = CGPoint(x: 0.3, y: 0.8)
        badge.frame = CGRect(x: 0, y: 0, width: size, height: size)
        CATransaction.commit()
    }
}

// MARK: - Status pill

/// A badge shape and a word: "Working", "Needs sign-in", "Can't connect". 22 pt high, fully round.
struct StatusPill: View {
    /// The old tones still work: good is ok, warn needs you, bad failed, neutral quiet (or checking while busy), info working.
    enum Tone { case good, warn, bad, neutral, info, working, done, checking, asleep }
    let text: String
    var tone: Tone = .neutral
    var busy = false

    init(text: String, tone: Tone = .neutral, busy: Bool = false) {
        self.text = text
        self.tone = tone
        self.busy = busy
    }

    /// The pill for a bot's state, in its own word unless `text` says otherwise.
    init(state: PixelState, text: String? = nil) {
        self.text = text ?? state.label
        switch state {
        case .working, .thinking: tone = .working
        case .needs: tone = .warn
        case .failed: tone = .bad
        case .done: tone = .done
        case .idle: tone = .asleep
        default: tone = .neutral
        }
    }

    var pixelTone: PixelTone {
        switch tone {
        case .good: return busy ? .working : .ok
        case .warn: return .needs
        case .bad: return .failed
        case .neutral: return busy ? .checking : .quiet
        case .info, .working: return .working
        case .done: return .done
        case .checking: return .checking
        case .asleep: return .quiet
        }
    }

    var body: some View {
        let pixel = pixelTone
        HStack(spacing: 6) {
            if pixel.badge != nil {
                PixelBadge(tone: pixel, size: 14)
            } else if tone == .asleep {
                Moon().fill(pixel.text.opacity(0.8)).frame(width: 9, height: 9)
            } else {
                Circle().fill(pixel.text.opacity(0.75)).frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(pixel.text).lineLimit(1)
        }
        .padding(.leading, pixel.badge == nil ? 9 : 5).padding(.trailing, 9).frame(height: 22)
        .background(Capsule().fill(pixel.tint))
        .fixedSize()
    }
}

/// The crescent the Asleep pill uses instead of a dot.
struct Moon: Shape {
    func path(in rect: CGRect) -> Path {
        var outer = Path(ellipseIn: rect)
        let bite = Path(ellipseIn: rect.offsetBy(dx: -rect.width * 0.33, dy: -rect.height * 0.11))
        outer = outer.subtracting(bite)
        return outer
    }
}

// MARK: - Small card

/// A button on a small card. One primary at most; never more than three.
struct PixelCardButton: Identifiable {
    let id = UUID()
    let title: String
    var primary = false
    var plain = false
    let action: () -> Void
}

/// Who a card is from: a bot (its face at 28 pt with its badge) or an app tile when no bot is involved.
enum PixelCardLead {
    case bot(NativeBot, PixelState)
    case look(CrewLook, PixelState)
    case app(symbol: String, state: PixelState?)
    case connector(BotConnector, PixelState?)
    case none
}

/// The one card every ask, failure and result uses: header, question, body, an optional object row or field, buttons, foot.
struct PixelCard<Extra: View>: View {
    var tone: PixelTone = .quiet
    var lead: PixelCardLead = .none
    var name: String
    var context: String? = nil
    var pill: (tone: PixelTone, text: String)? = nil
    var question: String
    var detail: String? = nil
    var buttons: [PixelCardButton] = []
    var foot: String? = nil
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                leadView
                (Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                 + Text(context.map { " · " + $0 } ?? "").font(.system(size: 12.5)).foregroundColor(DS.Colors.textSecondary))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let pill { StatusPill(text: pill.text, tone: Self.legacy(pill.tone)) }
            }
            Text(question).font(.system(size: 14.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            extra()
            if !buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(buttons.prefix(3)) { button in
                        if button.primary {
                            Button(button.title, action: button.action).buttonStyle(.theo(.primary, .small))
                        } else if button.plain {
                            Button(button.title, action: button.action).buttonStyle(.theo(.ghost, .small))
                        } else {
                            Button(button.title, action: button.action).buttonStyle(.theo(.secondary, .small))
                        }
                    }
                }
                .padding(.top, 2)
            }
            if let foot {
                Text(foot).font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 12).padding(.horizontal, 13).padding(.bottom, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tone.cardBorder, lineWidth: 1))
    }

    @ViewBuilder private var leadView: some View {
        switch lead {
        case .bot(let bot, let state):
            CrewAvatar(look: bot.crewLook, size: 28, pose: state, moves: true, interactive: false, name: bot.name, ring: DS.Colors.surface1)
        case .look(let look, let state):
            CrewAvatar(look: look, size: 28, pose: state, interactive: false, ring: DS.Colors.surface1)
        case .app(let symbol, let state):
            AppTile(symbol: symbol, size: 28, badge: state.flatMap(PixelTone.init(badgeFor:)))
        case .connector(let connector, let state):
            AppTile(symbol: connector.symbol, size: 28, badge: state.flatMap(PixelTone.init(badgeFor:)))
        case .none:
            EmptyView()
        }
    }

    /// StatusPill speaks the old tones; this maps a Pixel tone onto one.
    static func legacy(_ tone: PixelTone) -> StatusPill.Tone {
        switch tone {
        case .working: return .working
        case .ok: return .good
        case .needs: return .warn
        case .failed: return .bad
        case .done: return .done
        case .checking: return .checking
        case .quiet: return .neutral
        }
    }
}

extension PixelCard where Extra == EmptyView {
    init(tone: PixelTone = .quiet, lead: PixelCardLead = .none, name: String, context: String? = nil, pill: (tone: PixelTone, text: String)? = nil,
         question: String, detail: String? = nil, buttons: [PixelCardButton] = [], foot: String? = nil) {
        self.init(tone: tone, lead: lead, name: name, context: context, pill: pill, question: question, detail: detail, buttons: buttons, foot: foot) { EmptyView() }
    }
}

extension PixelTone {
    /// The badge an app tile wears for a state, if any.
    init?(badgeFor state: PixelState) {
        switch state {
        case .needs: self = .needs
        case .failed: self = .failed
        case .done: self = .done
        case .working, .thinking: self = .working
        case .awake: self = .ok
        default: return nil
        }
    }
}

/// A square tile with a symbol, optionally with a badge on its corner (the tick, "?" or cross on an app).
struct AppTile: View {
    let symbol: String
    var size: CGFloat = 30
    var badge: PixelTone? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(DS.Colors.logoTile)
                .overlay(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundColor(DS.Colors.textSecondary))
                .frame(width: size, height: size)
            if let badge {
                PixelBadge(tone: badge, size: max(12, size * 0.42), ring: DS.Colors.surface1).offset(x: size * 0.12, y: size * 0.12)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The object a card is about: an app tile, its name, one line, and its status pill.
struct PixelObjectRow: View {
    let symbol: String
    let name: String
    var line: String? = nil
    var pill: (tone: PixelTone, text: String)? = nil
    var badge: PixelTone? = nil

    var body: some View {
        HStack(spacing: 10) {
            AppTile(symbol: symbol, size: 30, badge: badge)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                if let line { Text(line).font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if let pill { StatusPill(text: pill.text, tone: PixelCard<EmptyView>.legacy(pill.tone)) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface))
    }
}

/// One radio row, for a card's options.
struct PixelRadioRow: View {
    let title: String
    var detail: String? = nil
    let isOn: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(isOn ? DS.Colors.accent : DS.Colors.borderStrong, lineWidth: 1.5).frame(width: 15, height: 15)
                    if isOn { Circle().fill(DS.Colors.accent).frame(width: 7, height: 7) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    if let detail, !detail.isEmpty { Text(detail).font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(2).multilineTextAlignment(.leading) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isOn ? DS.Colors.accentSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isOn ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Folded line

/// A card once answered: one line, 30 pt, that stays in the chat as a record.
struct PixelFoldedLine: View {
    let tone: PixelTone
    /// "You allowed this once".
    let did: String
    /// "Start a database on this Mac".
    var about: String? = nil
    var undo: (title: String, action: () -> Void)? = nil
    var at: Date = Date()

    var body: some View {
        HStack(spacing: 8) {
            if tone.badge != nil { PixelBadge(tone: tone, size: 14, animated: false) } else { Circle().strokeBorder(DS.Colors.textTertiary, lineWidth: 1.2).frame(width: 13, height: 13) }
            (Text(did).font(.system(size: 12.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
             + Text(about.map { " · " + $0 } ?? "").font(.system(size: 12.5)).foregroundColor(DS.Colors.textSecondary))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let undo {
                Button(undo.title, action: undo.action).buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundColor(DS.Colors.accentText).pointerCursor()
            }
            Text(at.formatted(date: .omitted, time: .shortened)).font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }
}

/// Answered cards, by card id, so answering in one place (chat, Home, the menu bar, an alert) folds it everywhere, and the
/// record survives a relaunch.
@MainActor
final class PixelCardFolds: ObservableObject {
    static let shared = PixelCardFolds()

    struct Fold: Codable, Equatable {
        var did: String
        var about: String?
        /// "ok", "quiet", "failed": the badge the line wears.
        var tone: String
        var at: Date
    }

    @Published private(set) var folds: [String: Fold] = [:]
    private static let key = "theo.cards.folds"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([String: Fold].self, from: data) { folds = saved }
    }

    func fold(_ cardID: String, did: String, about: String? = nil, tone: PixelTone = .ok) {
        folds[cardID] = Fold(did: did, about: about, tone: tone == .failed ? "failed" : tone == .quiet ? "quiet" : "ok", at: Date())
        // Keep the newest few hundred.
        if folds.count > 400, let oldest = folds.min(by: { $0.value.at < $1.value.at })?.key { folds[oldest] = nil }
        UserDefaults.standard.set(try? JSONEncoder().encode(folds), forKey: Self.key)
    }

    func unfold(_ cardID: String) {
        folds[cardID] = nil
        UserDefaults.standard.set(try? JSONEncoder().encode(folds), forKey: Self.key)
    }

    func line(_ cardID: String, undo: (title: String, action: () -> Void)? = nil) -> PixelFoldedLine? {
        guard let fold = folds[cardID] else { return nil }
        let tone: PixelTone = fold.tone == "failed" ? .failed : fold.tone == "quiet" ? .quiet : .ok
        return PixelFoldedLine(tone: tone, did: fold.did, about: fold.about, undo: undo, at: fold.at)
    }
}

// MARK: - Alert panel

/// The alert for an ask or a failure, at the top right of the screen: the face, "<Bot> needs you" or "<Bot> failed", one
/// sentence and the card's button. It never takes focus, and goes by itself after a while. The test profile keeps it in
/// `BotAlerts.recent` only (nothing appears on the owner's screen); `uiAlertPreview` shows it inside Theo's window.
@MainActor
final class BotAlertPanel {
    static let shared = BotAlertPanel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func update() {
        guard !TheoProfile.isTest, let alert = BotAlerts.shared.recent.first, let screen = NSScreen.main else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: BotAlertView(alert: alert, onClose: { [weak self] in
            BotAlerts.shared.dismiss(alert)
            self?.panel?.orderOut(nil)
        }).modifier(TheoAppearanceRoot()))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 150)
        panel.contentView = host
        let size = host.fittingSize
        panel.setFrame(NSRect(x: screen.visibleFrame.maxX - size.width - 16, y: screen.visibleFrame.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 14, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

/// What an alert looks like: the same parts as the small card.
struct BotAlertView: View {
    let alert: BotAlerts.Alert
    var onClose: () -> Void = {}
    @ObservedObject private var store = BotsStore.shared

    var body: some View {
        let bot = store.bot(alert.botID)
        HStack(alignment: .top, spacing: 12) {
            if let bot { CrewAvatar(look: bot.crewLook, size: 44, pose: alert.state, interactive: false, name: bot.name, ring: DS.Colors.surface) }
            VStack(alignment: .leading, spacing: 4) {
                Text("THEO · " + BotsStore.shortAge(since: alert.at)).font(.system(size: 11, design: .monospaced)).foregroundColor(DS.Colors.textTertiary)
                Text(alert.title).font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text(alert.line).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(alert.state == .failed ? "Open" : "Answer") {
                        NotificationCenter.default.post(name: .theoOpenBot, object: alert.botID)
                        onClose()
                    }
                    .buttonStyle(.theo(.primary, .small))
                    Button("Later", action: onClose).buttonStyle(.theo(.ghost, .small))
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
    }
}
