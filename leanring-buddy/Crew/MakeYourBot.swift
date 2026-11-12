//
//  MakeYourBot.swift
//  leanring-buddy
//
//  Dressing a bot up: a big live figure on the left to boop and try poses on, and every option on the right drawn as this
//  bot wearing it. The look is kept on the bot, so it shows everywhere and survives a restart.
//

import ClickyCore
import SwiftUI

struct MakeYourBotSheet: View {
    let name: String
    @State var look: CrewLook
    var isClicky = false
    let onDone: (CrewLook?) -> Void

    /// The five main states, shown small under the preview so people see their bot in each.
    private let states: [PixelState] = [.working, .needs, .failed, .done, .idle]
    private let eyes: [(CrewLook.Eyes, String)] = [(.pixel, "block"), (.round, "round"), (.pill, "tall"), (.visor, "wide"), (.hearts, "heart")]
    private let extras: [(CrewLook.Extra, String)] = [(.none, "None"), (.bowtie, "Bowtie"), (.tie, "Tie"), (.scarf, "Scarf"), (.glasses, "Bezel"), (.pencil, "Pencil"), (.badge, "Star")]
    private var antennas: [CrewLook.Antenna] {
        let order: [CrewLook.Antenna] = [.none, .ball, .twin, .handle, .dish, .flag, .bolt, .heart]
        return isClicky ? order + [.cursor] : order
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            stage
            Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Body") {
                        HStack(spacing: 8) {
                            ForEach(CrewLook.shellOrder, id: \.self) { shell in
                                let finish = PixelDrawing.finish(look.with(shell: shell).pixel.finish)
                                swatch(selected: look.pixel.finish == look.with(shell: shell).pixel.finish,
                                       fill: LinearGradient(colors: [Color(hex: finish.top), Color(hex: finish.bottom)], startPoint: .top, endPoint: .bottom), help: look.with(shell: shell).pixel.finish) {
                                    look.shell = shell
                                }
                            }
                        }
                    }
                    group("Trim") {
                        HStack(spacing: 8) {
                            ForEach(PixelLook.trimOrder, id: \.name) { trim in
                                let hex = String(format: "#%06x", trim.hex)
                                swatch(selected: look.pixel.trim == trim.hex, fill: LinearGradient(colors: [Color(hex: trim.hex)], startPoint: .top, endPoint: .bottom), help: trim.name) {
                                    look.glow = hex
                                    look.hatColor = hex
                                }
                            }
                        }
                    }
                    group("Eyes") {
                        HStack(spacing: 8) {
                            ForEach(eyes, id: \.1) { option in
                                choice(selected: look.eyes == option.0, help: option.1) { EyePattern(eye: option.1).frame(width: 44, height: 22) } pick: { look.eyes = option.0 }
                            }
                        }
                    }
                    group("On top") {
                        FlowLayout(spacing: 8, centered: false) {
                            ForEach(antennas, id: \.self) { antenna in
                                pill(antenna == .none ? "None" : antenna.rawValue.capitalized, selected: look.hat == .none && look.antenna == antenna) {
                                    look.hat = .none
                                    look.antenna = antenna
                                }
                            }
                            ForEach(CrewLook.Hat.allCases.filter { $0 != .none }, id: \.self) { hat in
                                pill(hat.rawValue.capitalized, selected: look.hat == hat) {
                                    look.hat = hat
                                    look.antenna = .none
                                    look.hatColor = look.glow
                                }
                            }
                        }
                    }
                    group("Extra") {
                        FlowLayout(spacing: 8, centered: false) {
                            ForEach(extras, id: \.1) { option in
                                pill(option.1, selected: look.extra == option.0) { look.extra = option.0 }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 1000, height: 640)
        .background(DS.Colors.background)
        .modifier(TheoAppearanceRoot())
    }

    private var stage: some View {
        VStack(spacing: 16) {
            CrewAvatar(look: look, size: 150, pose: .awake, name: name)
                .padding(.top, 40)
            VStack(spacing: 2) {
                Text(name).font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text("Tap the bot to boop it").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
            }
            HStack(spacing: 12) {
                ForEach(states, id: \.self) { state in
                    CrewAvatar(look: look, size: 36, pose: state, interactive: false, name: name, ring: DS.Colors.surface1)
                        .help(state.label)
                }
            }
            .padding(.top, 6)
            Button("Shuffle") { shuffle() }.buttonStyle(.theoSecondary)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Cancel") { onDone(nil) }.buttonStyle(.theoGhost).keyboardShortcut(.cancelAction)
                Button("Save look") { onDone(look) }.buttonStyle(.theoPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(DS.Colors.surface1)
    }

    private func shuffle() {
        let antenna = look.antenna
        look = .shuffled()
        // Clicky keeps its cursor through a shuffle.
        if isClicky, antenna == .cursor {
            look.hat = .none
            look.antenna = .cursor
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(DS.Colors.textTertiary).tracking(1.2)
            content()
        }
    }

    private func swatch(selected: Bool, fill: LinearGradient, help: String, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Circle().fill(fill).frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? DS.Colors.textPrimary : DS.Colors.borderSubtle, lineWidth: selected ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).pointerCursor()
    }

    private func choice<Label: View>(selected: Bool, help: String, @ViewBuilder label: () -> Label, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            label()
                .padding(.horizontal, 10).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? DS.Colors.textPrimary : DS.Colors.borderSubtle, lineWidth: selected ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).pointerCursor()
    }

    private func pill(_ title: String, selected: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundColor(selected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 12).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? DS.Colors.textPrimary : DS.Colors.borderSubtle, lineWidth: selected ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

/// An eye style drawn as the light pattern it makes: the awake face's eyes, cropped.
struct EyePattern: View {
    let eye: String

    var body: some View {
        Canvas { context, size in
            let rows = PixelFaces.frames(.awake, eye: eye).first?.rows ?? []
            let used = rows.enumerated().filter { $0.element.contains("#") }.map(\.offset)
            guard let top = used.first, let bottom = used.last else { return }
            let height = bottom - top + 1
            let pitch = min(size.width / CGFloat(PixelFaces.columns), size.height / CGFloat(height))
            let originX = (size.width - pitch * CGFloat(PixelFaces.columns)) / 2
            let originY = (size.height - pitch * CGFloat(height)) / 2
            for (rowIndex, row) in rows.enumerated() where rowIndex >= top && rowIndex <= bottom {
                for (columnIndex, character) in row.enumerated() where character != "." {
                    let rect = CGRect(x: originX + CGFloat(columnIndex) * pitch, y: originY + CGFloat(rowIndex - top) * pitch, width: pitch * 0.82, height: pitch * 0.82)
                    context.fill(Path(roundedRect: rect, cornerRadius: pitch * 0.2), with: .color(Color(hex: 0xC6C7D1)))
                }
            }
        }
        .accessibilityLabel(eye)
    }
}

extension CrewLook {
    func with(shell: String) -> CrewLook {
        var copy = self
        copy.shell = shell
        return copy
    }
}

/// A centred row of pill choices that wraps.
struct WrappingChips: View {
    let items: [String]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                let on = item == selected
                Button { pick(item) } label: {
                    Text(item).font(.system(size: 11.5)).foregroundColor(on ? DS.Colors.background : DS.Colors.textSecondary)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(on ? DS.Colors.textPrimary : .clear))
                        .overlay(Capsule().strokeBorder(on ? .clear : DS.Colors.borderSubtle, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children out in rows, each row centred. Wraps at the width it's given.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var centered = true

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if used + size.width > width, !(rows.last?.isEmpty ?? true) {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append((index, size))
            used += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let laidOut = rows(subviews, width: width)
        let height = laidOut.map { ($0.map(\.size.height).max() ?? 0) }.reduce(0, +) + spacing * CGFloat(max(0, laidOut.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let rowWidth = row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1))
            var x = centered ? bounds.midX - rowWidth / 2 : bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }
}
