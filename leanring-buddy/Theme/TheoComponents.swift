//
//  TheoComponents.swift
//  leanring-buddy
//
//  The small parts every Theo screen is built from, so buttons, rows, tiles and fields look and behave the same
//  everywhere: Raycast's chrome (dense rows, icon tiles, hairlines) in Theo's dark ember. Hover, pressed, disabled and
//  focus states live here, not in each screen.
//

import AppKit
import SwiftUI

// MARK: - Type

enum TheoType {
    static let title = Font.system(size: 22, weight: .semibold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12)
    static let micro = Font.system(size: 11)
    static let label = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
}

// MARK: - Buttons

struct TheoButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    enum Size { case small, regular, large }
    var kind: Kind = .secondary
    var size: Size = .regular
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var height: CGFloat { size == .small ? 26 : size == .large ? 38 : 30 }
    private var padding: CGFloat { size == .small ? 10 : size == .large ? 18 : 12 }
    private var font: Font { .system(size: size == .small ? 12 : size == .large ? 14 : 13, weight: .medium) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundColor(foreground)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background(pressed: configuration.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering = $0 && isEnabled }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return DS.Colors.textPrimary
        case .ghost: return hovering ? DS.Colors.textPrimary : DS.Colors.textSecondary
        case .destructive: return DS.Colors.destructiveText
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return DS.Colors.accent.opacity(pressed ? 0.8 : hovering ? 0.92 : 1)
        case .secondary: return pressed ? DS.Colors.selected : hovering ? DS.Colors.surface : DS.Colors.surface1
        case .ghost: return pressed ? DS.Colors.selected : hovering ? DS.Colors.hover : .clear
        case .destructive: return pressed ? DS.Colors.destructiveText.opacity(0.22) : hovering ? DS.Colors.destructiveText.opacity(0.14) : .clear
        }
    }

    private var border: Color {
        switch kind {
        case .secondary: return hovering ? DS.Colors.borderStrong : DS.Colors.borderSubtle
        case .destructive: return DS.Colors.destructiveText.opacity(0.35)
        default: return .clear
        }
    }
}

extension ButtonStyle where Self == TheoButtonStyle {
    static var theoPrimary: TheoButtonStyle { TheoButtonStyle(kind: .primary) }
    static var theoSecondary: TheoButtonStyle { TheoButtonStyle(kind: .secondary) }
    static var theoGhost: TheoButtonStyle { TheoButtonStyle(kind: .ghost) }
    static var theoDestructive: TheoButtonStyle { TheoButtonStyle(kind: .destructive) }
    static func theo(_ kind: TheoButtonStyle.Kind, _ size: TheoButtonStyle.Size = .regular) -> TheoButtonStyle { TheoButtonStyle(kind: kind, size: size) }
}

// MARK: - Icon tiles and logos

/// A symbol on a small coloured tile, as in Raycast's lists.
struct IconTile: View {
    let symbol: String
    var colors: [Color] = [Color(hex: 0x3A3A42), Color(hex: 0x26262C)]
    var size: CGFloat = 22
    var symbolColor: Color = .white

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.52, weight: .semibold)).foregroundColor(symbolColor))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The colour pairs for tiles (from docs/DESIGN.md's palette).
enum TileColors {
    static let ember = [Color(hex: 0xF2784B), Color(hex: 0xE0476A)]
    static let amber = [Color(hex: 0xF5B13D), Color(hex: 0xE8782E)]
    static let lime = [Color(hex: 0x9BD14B), Color(hex: 0x3FA65C)]
    static let teal = [Color(hex: 0x3FC8B4), Color(hex: 0x2E8FB8)]
    static let sky = [Color(hex: 0x4EA8F0), Color(hex: 0x4A6FE0)]
    static let indigo = [Color(hex: 0x6E7BF0), Color(hex: 0x8A55E0)]
    static let violet = [Color(hex: 0xA468EB), Color(hex: 0xD152B8)]
    static let rose = [Color(hex: 0xF06A8F), Color(hex: 0xE24A58)]
    static let slate = [Color(hex: 0x7C8697), Color(hex: 0x4D5666)]
    static let graphite = [Color(hex: 0x3A3A42), Color(hex: 0x26262C)]
}

/// A service's real logo from the asset catalog (Assets.xcassets/Logos), on a neutral tile. An id with no logo
/// shows its first letter rather than a blank square. Tests check every id Theo names has its logo.
struct BrandLogo: View {
    let id: String
    var name = ""
    var size: CGFloat = 28
    /// Plain: only the mark, with no tile behind it.
    var plain = false

    static func hasLogo(_ id: String) -> Bool { NSImage(named: "logo-\(id)") != nil }

    var body: some View {
        let mark = Group {
            if Self.hasLogo(id) {
                Image("logo-\(id)").resizable().renderingMode(Self.isTemplate(id) ? .template : .original).interpolation(.high).scaledToFit()
                    .foregroundColor(DS.Colors.textPrimary)
            } else {
                Text(String((name.isEmpty ? id : name).prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundColor(DS.Colors.textPrimary)
            }
        }
        if plain {
            mark.frame(width: size, height: size).accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                .overlay(mark.padding(size * 0.2))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private static func isTemplate(_ id: String) -> Bool { NSImage(named: "logo-\(id)")?.isTemplate ?? false }
}

// MARK: - Status

struct StatusPill: View {
    enum Tone { case good, warn, bad, neutral, info }
    let text: String
    var tone: Tone = .neutral
    var busy = false

    private var color: Color {
        switch tone {
        case .good: return DS.Colors.success
        case .warn: return DS.Colors.warning
        case .bad: return DS.Colors.destructiveText
        case .info: return DS.Colors.blue
        case .neutral: return DS.Colors.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 8, height: 8)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(tone == .neutral ? DS.Colors.textSecondary : color).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 22)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Layout

/// A titled group of rows on a card, like a grouped section in System Settings.
struct TheoSection<Content: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let hint {
                Text(hint).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A hairline between rows of a section.
struct RowDivider: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1).padding(.leading, inset)
    }
}

/// A plain label and control row inside a section.
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TheoType.body).foregroundColor(DS.Colors.textPrimary)
                if let detail { Text(detail).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// What an empty screen or list says, and what to do about it.
struct TheoEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            IconTile(symbol: symbol, colors: TileColors.graphite, size: 44, symbolColor: DS.Colors.textSecondary)
            Text(title).font(TheoType.headline).foregroundColor(DS.Colors.textPrimary)
            Text(detail).font(TheoType.body).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let action {
                Button(action.title, action: action.run).buttonStyle(.theoPrimary).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

/// A field that looks the same everywhere and shows focus in ember.
struct TheoFieldStyle: ViewModifier {
    var isFocused = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(TheoType.body)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.background))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused ? DS.Colors.accent.opacity(0.7) : DS.Colors.borderStrong, lineWidth: isFocused ? 1.5 : 1))
    }
}

extension View {
    func theoField(focused: Bool = false) -> some View { modifier(TheoFieldStyle(isFocused: focused)) }
}

// MARK: - Clicks

/// Every view in a Theo window takes the first click, so a control works on the click that brings the window
/// forward. AppKit asks the deepest view under the pointer, and SwiftUI's own containers (PlatformGroupContainer, the
/// insides of a ScrollView) answer no: that was most of the window, and it read as "I have to click twice". The earlier
/// fix only changed the hosting view at the top. This patches NSView and every subclass that overrides the answer.
@MainActor
enum TheoFirstClick {
    static func install() {
        let selector = #selector(NSView.acceptsFirstMouse(for:))
        let alwaysAccept: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        let implementation = imp_implementationWithBlock(alwaysAccept)
        if let method = class_getInstanceMethod(NSView.self, selector) { method_setImplementation(method, implementation) }
        var classCount: UInt32 = 0
        guard let classes = objc_copyClassList(&classCount) else { return }
        // Read as raw pointers: the typed list's accessor retains each class, and some root classes (JSExport) abort on that.
        let rawClasses = UnsafeMutableRawPointer(classes).assumingMemoryBound(to: UnsafeRawPointer.self)
        defer { free(rawClasses) }
        for index in 0..<Int(classCount) {
            let candidate = unsafeBitCast(rawClasses[index], to: AnyClass.self)
            // Walked by hand: asking the class itself would run its +initialize.
            var ancestor: AnyClass? = class_getSuperclass(candidate)
            var isView = false
            while let current = ancestor {
                if current == NSView.self { isView = true; break }
                ancestor = class_getSuperclass(current)
            }
            guard isView else { continue }
            var methodCount: UInt32 = 0
            guard let methods = class_copyMethodList(candidate, &methodCount) else { continue }
            for methodIndex in 0..<Int(methodCount) where method_getName(methods[methodIndex]) == selector {
                method_setImplementation(methods[methodIndex], implementation)
            }
            free(methods)
        }
    }
}
