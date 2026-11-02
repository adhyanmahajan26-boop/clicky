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

    @State private var pose: CrewPose = .awake

    private let poses: [(CrewPose, String)] = [(.awake, "Awake"), (.working, "Working"), (.talking, "Talking"), (.needs, "Needs you"), (.done, "Done"), (.sleep, "Idle")]

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            stage
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    options("Hat", CrewLook.Hat.allCases, title: \.rawValue) { look.hat == $0 } apply: { $0.hat = $1 }
                    options("Antenna", isClicky ? CrewLook.Antenna.allCases : CrewLook.Antenna.pickable, title: \.rawValue) { look.antenna == $0 } apply: { $0.antenna = $1 }
                    options("Eyes", CrewLook.Eyes.allCases, title: \.rawValue) { look.eyes == $0 } apply: { $0.eyes = $1 }
                    options("Extras", CrewLook.Extra.allCases, title: \.rawValue) { look.extra == $0 } apply: { $0.extra = $1 }
                    swatches("Body", CrewLook.shellOrder, color: { CrewLook.shells[$0] ?? 0xECECEE }, selected: look.shell) { look.shell = $0 }
                    swatches("Screen glow", CrewLook.glows, color: CrewLook.hex, selected: look.glow) { look.glow = $0 }
                    swatches("Hat colour", CrewLook.hatColors, color: CrewLook.hex, selected: look.hatColor) { look.hatColor = $0 }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(24)
        .frame(width: 1080, height: 660)
        .background(DS.Colors.background)
        .modifier(TheoAppearanceRoot())
    }

    private var stage: some View {
        VStack(spacing: 14) {
            CrewAvatar(look: look, size: 220, pose: pose)
                .padding(.top, 34)
            VStack(spacing: 2) {
                Text(name).font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text("Tap the bot to boop it").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
            }
            WrappingChips(items: poses.map(\.1), selected: poses.first { $0.0 == pose }?.1 ?? "") { label in
                if let match = poses.first(where: { $0.1 == label }) { pose = match.0 }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Shuffle") { shuffle() }.buttonStyle(.theoSecondary)
                Button("Save look") { onDone(look) }.buttonStyle(.theoPrimary).keyboardShortcut(.defaultAction)
                Button("Cancel") { onDone(nil) }.buttonStyle(.theoGhost).keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(RadialGradient(colors: [DS.Colors.surface, DS.Colors.surface1], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 360)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }

    private func shuffle() {
        let antenna = look.antenna
        look = .shuffled()
        // Clicky keeps its cursor through a shuffle.
        if isClicky, antenna == .cursor { look.antenna = .cursor }
    }

    private func options<Option: Hashable>(_ label: String, _ values: [Option], title: KeyPath<Option, String>,
                                           isOn: @escaping (Option) -> Bool, apply: @escaping (inout CrewLook, Option) -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textSecondary).frame(width: 84, alignment: .leading)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
                ForEach(values, id: \.self) { value in
                    let on = isOn(value)
                    let name = value[keyPath: title]
                    Button { apply(&look, value) } label: {
                        VStack(spacing: 4) {
                            CrewAvatar(look: dressed(value, apply), size: 40, interactive: false)
                            Text(name == "none" ? "None" : name.prefix(1).uppercased() + name.dropFirst())
                                .font(.system(size: 10.5)).foregroundColor(on ? DS.Colors.textPrimary : DS.Colors.textSecondary).lineLimit(1)
                        }
                        .padding(.top, 8).padding(.bottom, 6).frame(width: 62)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? DS.Colors.accentSoft : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: on ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(name)
                }
            }
        }
    }

    private func dressed<Option>(_ value: Option, _ apply: (inout CrewLook, Option) -> Void) -> CrewLook {
        var copy = look
        apply(&copy, value)
        return copy
    }

    private func swatches(_ label: String, _ values: [String], color: @escaping (String) -> UInt32, selected: String, pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textSecondary).frame(width: 84, alignment: .leading)
            HStack(spacing: 10) {
                ForEach(values, id: \.self) { value in
                    Button { pick(value) } label: {
                        Circle().fill(Color(hex: color(value))).frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                            .padding(3)
                            .overlay(Circle().strokeBorder(value == selected ? DS.Colors.textPrimary : .clear, lineWidth: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).help(value)
                }
            }
        }
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
