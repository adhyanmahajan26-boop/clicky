//
//  StudioScreensSettings.swift
//  leanring-buddy
//
//  Settings › Studio › Screens: what each hidden screen is and who it belongs to. Changes wait for Apply, because making a
//  display again drops the monitors out of HDR and nudges the left one. Who owns what takes effect straight away.
//

import ClickyCore
import SwiftUI

struct StudioScreensSection: View {
    @ObservedObject private var studio = StudioController.shared
    @ObservedObject private var store = BotsStore.shared
    @State private var customSizes: Set<String> = []

    var body: some View {
        TheoSection(title: "Screens", hint: "Each one is a virtual display on this Mac Studio. Tiles nobody owns are a shared pool, and a coder's terminal always stays on your own monitors.") {
            ForEach($studio.draft.screens) { $spec in
                if spec.id != studio.draft.screens.first?.id { RowDivider() }
                card($spec)
            }
            RowDivider()
            HStack(spacing: 10) {
                Button { studio.draft.addScreen() } label: { Label("New screen", systemImage: "plus") }
                    .buttonStyle(.theo(.secondary, .small))
                    .disabled(studio.draft.screens.count >= StudioScreensConfig.maximumScreens)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("All screens").font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textTertiary)
                    Text(StudioScreenCost.total(studio.draft.screens).label).font(.system(size: 11).monospacedDigit()).foregroundColor(DS.Colors.textSecondary)
                }
            }
            .padding(12)
            RowDivider()
            applyRow.padding(12)
        }
    }

    private func card(_ spec: Binding<StudioScreenSpec>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Name", text: spec.name).theoField().frame(maxWidth: 200)
                Spacer(minLength: 8)
                Text(StudioScreenCost.estimate(spec.wrappedValue).label).font(.system(size: 11).monospacedDigit()).foregroundColor(DS.Colors.textTertiary)
                Button { studio.draft.removeScreen(spec.wrappedValue.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(DS.Colors.textTertiary).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Remove this screen").disabled(studio.draft.screens.count <= 1)
            }
            row("Resolution") {
                HStack(spacing: 8) {
                    if isCustom(spec.wrappedValue) {
                        number(spec.width).frame(width: 64)
                        Text("×").foregroundColor(DS.Colors.textTertiary)
                        number(spec.height).frame(width: 64)
                    }
                    Picker("Resolution", selection: sizeChoice(spec)) {
                        ForEach(StudioScreenSpec.presets, id: \.width) { Text(verbatim: "\($0.width)×\($0.height)").tag("\($0.width)x\($0.height)") }
                        Text("Custom").tag("custom")
                    }
                    .labelsHidden().frame(width: 130)
                }
            }
            row("HiDPI") { Toggle("HiDPI", isOn: spec.hiDPI).labelsHidden().toggleStyle(.switch).tint(DS.Colors.accent) }
            row("Refresh") {
                HairlineSegments(options: StudioScreenSpec.refreshRates.map { (String($0), "\($0) Hz") },
                                 selection: Binding(get: { String(spec.wrappedValue.refresh) }, set: { spec.wrappedValue.refresh = Int($0) ?? 60 }))
            }
            row("Tiles") {
                HairlineSegments(options: StudioScreenSpec.tileChoices.map { (String($0), String($0)) },
                                 selection: Binding(get: { String(spec.wrappedValue.tiles) }, set: { spec.wrappedValue.tiles = Int($0) ?? 2 }))
            }
            row("Live preview") {
                Stepper("\(spec.wrappedValue.previewFPS) fps", value: spec.previewFPS, in: StudioScreenSpec.previewFPSRange)
                    .font(.system(size: 12).monospacedDigit()).foregroundColor(DS.Colors.textPrimary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(spec.wrappedValue.owners.isEmpty ? "Owners: nobody, so it's in the shared pool" : "Owners").font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(store.bots) { bot in ownerChip(bot, spec: spec) }
                }
            }
        }
        .padding(12)
    }

    private func ownerChip(_ bot: NativeBot, spec: Binding<StudioScreenSpec>) -> some View {
        let on = spec.wrappedValue.owners.contains(bot.id)
        return Button {
            if on { spec.wrappedValue.owners.removeAll { $0 == bot.id } } else { spec.wrappedValue.owners.append(bot.id) }
        } label: {
            HStack(spacing: 5) {
                CrewAvatar(look: bot.crewLook, size: 18, moves: false, interactive: false)
                Text(bot.name).font(.system(size: 11.5)).foregroundColor(on ? DS.Colors.textPrimary : DS.Colors.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? DS.Colors.accentSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(on ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
            Spacer(minLength: 8)
            content()
        }
    }

    private func number(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number.grouping(.never)).theoField()
    }

    private func isCustom(_ spec: StudioScreenSpec) -> Bool {
        customSizes.contains(spec.id) || !StudioScreenSpec.presets.contains { $0.width == spec.width && $0.height == spec.height }
    }

    private func sizeChoice(_ spec: Binding<StudioScreenSpec>) -> Binding<String> {
        Binding(get: { isCustom(spec.wrappedValue) ? "custom" : "\(spec.wrappedValue.width)x\(spec.wrappedValue.height)" }, set: { choice in
            if choice == "custom" {
                customSizes.insert(spec.wrappedValue.id)
            } else {
                customSizes.remove(spec.wrappedValue.id)
                let parts = choice.split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { spec.wrappedValue.width = parts[0]; spec.wrappedValue.height = parts[1] }
            }
        })
    }

    @ViewBuilder private var applyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if studio.isWaitingToApply {
                Text("Waiting: this applies once nothing has played for a minute and no agent is on a tile.").font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary)
                HStack(spacing: 8) {
                    Button("Apply now") { studio.applyDraft(wait: false) }.buttonStyle(.theo(.secondary, .small))
                    Button("Cancel") { studio.cancelWaitingToApply() }.buttonStyle(.theo(.ghost, .small))
                }
            } else if studio.hasStagedChanges {
                if studio.stagedNeedsRebuild {
                    Text("Apply makes the hidden screens again. That drops your monitors out of HDR and nudges the left one, then Theo puts it back and checks. It closes anything on a tile.")
                        .font(.system(size: 11.5)).foregroundColor(DS.Colors.warningText).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Apply") { studio.applyDraft(wait: true) }.buttonStyle(.theo(.primary, .small))
                    Button("Discard") { studio.discardDraft() }.buttonStyle(.theo(.ghost, .small))
                }
            } else {
                Text(studio.measuredAfterApply ?? "Nothing to apply.").font(.system(size: 11.5).monospacedDigit()).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Screen: none, the shared pool or a named one. Takes effect straight away, since it changes no display.
struct BotScreenPicker: View {
    let botID: String
    @ObservedObject private var studio = StudioController.shared

    var body: some View {
        Picker("Screen", selection: Binding(get: { studio.config.choice(for: botID).tag }, set: { studio.setScreen(StudioScreenChoice(tag: $0), forBot: botID) })) {
            Text("None").tag("none")
            Text("Shared pool").tag("shared")
            ForEach(studio.config.screens) { Text($0.name).tag($0.id) }
        }
    }
}

/// Theo proposing a screen for a bot: nothing changes until the owner says yes here.
struct BotScreenGiftCard: View {
    let card: String
    @ObservedObject private var store = BotsStore.shared
    @ObservedObject private var studio = StudioController.shared
    @State private var answered: String?

    private var parts: [Substring] { card.split(separator: "|", maxSplits: 2) }

    var body: some View {
        if parts.count == 3, let bot = store.bot(String(parts[1])) {
            let choice = StudioScreenChoice(tag: String(parts[2]))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    CrewAvatar(look: bot.crewLook, size: 24, moves: false, interactive: false)
                    Text("\(bot.name): \(name(of: choice))").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                }
                if let answered {
                    Text(answered).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                } else {
                    HStack(spacing: 8) {
                        Button("Confirm") {
                            studio.setScreen(choice, forBot: bot.id)
                            answered = "Done. \(bot.name) now uses \(name(of: choice))."
                        }
                        .buttonStyle(.theo(.primary, .small))
                        Button("No") { answered = "Left as it was." }.buttonStyle(.theo(.ghost, .small))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 400, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .padding(.leading, 38)
        }
    }

    private func name(of choice: StudioScreenChoice) -> String {
        switch choice {
        case .none: return "no screen"
        case .sharedPool: return "the shared pool"
        case .screen(let id): return studio.config.screens.first { $0.id == id }?.name ?? "that screen"
        }
    }
}
