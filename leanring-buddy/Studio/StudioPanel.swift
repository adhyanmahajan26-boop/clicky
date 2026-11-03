//
//  StudioPanel.swift
//  leanring-buddy
//
//  The right-hand Studio panel: both hidden screens with small live views, who's waiting for a tile, and a meter. Plus the
//  Settings page.
//

import AppKit
import ClickyCore
import SwiftUI

struct StudioPanel: View {
    @ObservedObject var store: BotsStore
    @ObservedObject var selection: BotsSelection
    @ObservedObject private var studio = StudioController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HairlineIcon(name: "studio", size: 20, color: DS.Colors.textPrimary, live: studio.isOn && studio.liveCount > 0)
                Text("Studio").font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                if studio.isOn {
                    HStack(spacing: 6) {
                        LiveDot()
                        Text("\(studio.liveCount) live").font(.system(size: 11.5, weight: .medium)).foregroundColor(DS.Colors.accentText)
                    }
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(DS.Colors.accentSoft))
                }
                Spacer()
                Button { selection.openSettings(.studio) } label: {
                    HairlineIcon(name: "expand", size: 16, color: DS.Colors.textSecondary).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Studio settings")
            }
            .frame(height: 30)
            if studio.isOn {
                Text("\(studio.screenCount) hidden screen\(studio.screenCount == 1 ? "" : "s") · \(studio.tilesPerScreen) tile\(studio.tilesPerScreen == 1 ? "" : "s") each · Mac Studio only")
                    .font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).padding(.top, -6)
                if let problem = studio.problem {
                    Text(problem).font(.system(size: 11.5)).foregroundColor(DS.Colors.warningText).fixedSize(horizontal: false, vertical: true)
                }
                if let tile = studio.expandedTile { expanded(tile) }
                ForEach(0..<studio.screenCount, id: \.self) { screen in screenCard(screen) }
                queue
            } else {
                off
            }
            Spacer(minLength: 0)
            meter
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)
        .background(DS.Colors.sidebar)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var off: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(studio.problem ?? "Hidden screens for your bots are off.").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
            Text("Two invisible 1440×900 screens with two tiles each. Your bots work there and you watch small views here.")
                .font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button("Turn on in Settings") { selection.openSettings(.studio) }.buttonStyle(.theoSecondary).padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }

    private func screenCard(_ screen: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Screen \(screen + 1)").font(.system(size: 11.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text("1440×900").font(.system(size: 11, design: .monospaced)).foregroundColor(DS.Colors.textSecondary)
            }
            HStack(spacing: 4) {
                ForEach(0..<studio.tilesPerScreen, id: \.self) { tile in
                    tileView(StudioTileID(screen: screen, tile: tile))
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .padding(0)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }

    /// A tile opened large, with a way to bring its window to the owner and send it back.
    private func expanded(_ tile: StudioTileID) -> some View {
        let bot = studio.roster.bots[tile].flatMap { store.bot($0) }
        let isOut = studio.pulledOut.contains(tile)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Screen \(tile.screen + 1), \(tile.tile == 0 ? "left" : "right")").font(.system(size: 11.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button { studio.expandedTile = nil } label: {
                    HairlineIcon(name: "close", size: 13, color: DS.Colors.textSecondary).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Close")
            }
            ZStack {
                Color(hex: 0x0C0C0E)
                if let image = studio.thumbnails[tile] {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else if let bot {
                    VStack(spacing: 6) {
                        CrewAvatar(look: bot.crewLook, size: 64, pose: store.crewPose(of: bot).pose, interactive: false)
                        Text(studio.liveCapture ? "Waiting for a picture" : "Turn on Live capture in Settings to see other apps here").font(.system(size: 11)).foregroundColor(.white.opacity(0.65)).multilineTextAlignment(.center).padding(.horizontal, 12)
                    }
                }
            }
            .aspectRatio(0.8, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                if let bot {
                    Text(studio.tileNotes[tile] ?? store.liveStatus(of: bot)).font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(isOut ? "Send back" : "Show on my screen") {
                    if isOut { studio.sendBack(tile) } else { studio.showOnMyScreen(tile) }
                }
                .buttonStyle(.theoSecondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
    }

    private func tileView(_ tile: StudioTileID) -> some View {
        let bot = studio.roster.bots[tile].flatMap { store.bot($0) }
        let image = studio.thumbnails[tile]
        return ZStack {
            Color(hex: 0x0C0C0E)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill).frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
            } else if let bot {
                CrewAvatar(look: bot.crewLook, size: 54, pose: store.crewPose(of: bot).pose, interactive: false)
            }
            if image != nil {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: 0xFF4D4F)).frame(width: 5, height: 5)
                    Text("LIVE").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.white)
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.6)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(6)
            }
            if let bot {
                HStack(spacing: 6) {
                    CrewAvatar(look: bot.crewLook, size: 20, pose: store.crewPose(of: bot).pose, moves: false, interactive: false)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(bot.name).font(.system(size: 11, weight: .medium)).foregroundColor(.white).lineLimit(1)
                        Text(studio.tileNotes[tile] ?? store.liveStatus(of: bot)).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4).padding(.trailing, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.72)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(6)
            }
            if bot == nil {
                Text("Assign").font(.system(size: 11.5, weight: .medium)).foregroundColor(.white.opacity(0.6))
            }
        }
        .overlay {
            if bot != nil {
                // A click opens it large; the menu for changing it is a right-click away.
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { studio.expandedTile = studio.expandedTile == tile ? nil : tile }
                    .contextMenu { tileMenu(tile, occupied: true) }
                    .help("Open this tile")
            } else {
                Color.clear.contentShape(Rectangle()).coverMenu(help: "Assign a bot to this tile") { tileMenu(tile, occupied: false) }
            }
        }
        .onHover { inside in
            if inside { studio.hoveredTile = tile } else if studio.hoveredTile == tile { studio.hoveredTile = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder private func tileMenu(_ tile: StudioTileID, occupied: Bool) -> some View {
        ForEach(store.bots) { candidate in
            Button(candidate.name) { studio.assign(botID: candidate.id, to: tile) }
        }
        Button("Clicky") { studio.assign(botID: BotsStore.clickyID, to: tile) }
        if occupied {
            Divider()
            Button("Clear this tile") { studio.clear(tile) }
        }
    }

    /// Bots at work with no tile of their own.
    private var queue: some View {
        let waiting = store.bots.filter { store.crewPose(of: $0).pose == .working && studio.roster.tile(of: $0.id) == nil }
        return Group {
            if !waiting.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WAITING FOR A TILE").font(.system(size: 11, weight: .semibold)).tracking(0.66).foregroundColor(DS.Colors.textTertiary)
                    ForEach(waiting.prefix(5)) { bot in
                        HStack(spacing: 8) {
                            BotAvatar(bot: bot, size: 22, state: .idle)
                            Text(bot.name).font(.system(size: 12.5, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(store.liveStatus(of: bot)).font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var meter: some View {
        HStack(spacing: 8) {
            meterCell("CPU", value: String(format: "%.0f%%", studio.cpuPercent), fill: min(1, studio.cpuPercent / 100))
            meterCell("Memory", value: String(format: "%.0f MB", studio.memoryMB), fill: min(1, studio.memoryMB / 1024))
            meterCell("Preview", value: studio.isOn && studio.liveCount > 0 ? "\(studio.previewFPS) fps" : "Off", fill: studio.isOn && studio.liveCount > 0 ? Double(studio.previewFPS) / 5 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }

    private func meterCell(_ label: String, value: String, fill: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary)
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.borderStrong)
                    Capsule().fill(DS.Colors.accent).frame(width: box.size.width * fill)
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tile's tiny view in the sidebar: its thumbnail if there is one, otherwise a dark frame.
struct StudioTileThumb: View {
    @ObservedObject var studio: StudioController
    let tile: StudioTileID

    var body: some View {
        ZStack {
            Color(hex: 0x0C0C0E)
            if let image = studio.thumbnails[tile] {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill).frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
    }
}

// MARK: - Settings › Studio

struct StudioSettingsContent: View {
    @ObservedObject private var studio = StudioController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "Studio screens", hint: "Mac Studio only. While these are on, macOS takes your monitors out of HDR, and turning them on or off nudges a monitor aside for a second. Either can interrupt a video that's playing, so don't turn them on during Netflix.") {
                SettingRow(title: "Hidden bot screens", detail: "Bots work on screens you never see") {
                    Toggle("", isOn: Binding(get: { studio.isEnabled }, set: { studio.setEnabled($0) })).labelsHidden().toggleStyle(.switch).tint(DS.Colors.accent)
                }
                RowDivider()
                SettingRow(title: "Screens") {
                    HStack(spacing: 10) {
                        stepButton("−") { studio.screenCount -= 1 }.disabled(studio.screenCount <= 1)
                        Text("\(studio.screenCount)").font(.system(size: 12.5).monospacedDigit()).foregroundColor(DS.Colors.textPrimary)
                        stepButton("+") { studio.screenCount += 1 }.disabled(studio.screenCount >= 2)
                    }
                }
                RowDivider()
                SettingRow(title: "Tiles per screen") {
                    HairlineSegments(options: [("1", "1"), ("2", "2")], selection: Binding(get: { String(studio.tilesPerScreen) }, set: { studio.tilesPerScreen = Int($0) ?? 2 }))
                }
                RowDivider()
                SettingRow(title: "Live preview", detail: "Frames a second, for windows of Theo's own") {
                    HStack(spacing: 10) {
                        stepButton("−") { studio.previewFPS -= 1 }.disabled(studio.previewFPS <= 1)
                        Text("\(studio.previewFPS) fps").font(.system(size: 12.5).monospacedDigit()).foregroundColor(DS.Colors.textPrimary)
                        stepButton("+") { studio.previewFPS += 1 }.disabled(studio.previewFPS >= 5)
                    }
                }
            }
            TheoSection(title: "Research", hint: "When a plain fetch can't read a page, Researcher opens it in a new window of your own Chrome on a hidden screen, reads the text and closes it. It only reads: no clicks, no typing, no cookies or passwords touched, and private places like mail and banks never open. Chrome blinks to the front for a moment each time, so it waits until you pause. Visits show in your Chrome history. If a site wants a human check, it waits for you.") {
                SettingRow(title: "Research agents use my browser on Studio screens", detail: "Only Researcher, at most two tiles at once, freed when each page is done") {
                    Toggle("", isOn: Binding(get: { studio.researchUsesBrowser }, set: { studio.researchUsesBrowser = $0 })).labelsHidden().toggleStyle(.switch).tint(DS.Colors.accent)
                }
                if studio.researchUsesBrowser {
                    RowDivider()
                    ResearchBrowserPermissionRow()
                }
            }
            TheoSection(title: "Other apps on a tile", hint: captureNote) {
                SettingRow(title: "Live capture", detail: "Shows other apps' windows by capturing the hidden screens") {
                    Toggle("", isOn: Binding(get: { studio.liveCapture }, set: { studio.liveCapture = $0 })).labelsHidden().toggleStyle(.switch).tint(DS.Colors.accent)
                }
            }
            if !studio.displays.isEmpty {
                TheoSection(title: "Where they are") {
                    ForEach(Array(studio.displayBounds().enumerated()), id: \.offset) { index, box in
                        SettingRow(title: "Screen \(index + 1)", detail: "Off to the side, away from your monitors") {
                            Text("\(Int(box["x"] ?? 0)), \(Int(box["y"] ?? 0))").font(.system(size: 12, design: .monospaced)).foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var captureNote: String {
        let permission = studio.hasCapturePermission ? "" : " It also needs Screen Recording, which Theo never asks for by itself."
        return "Capturing a display can black out Netflix on your monitors, the way screen recording does, so this stays off until you've tried it. A tile with another app shows its bot and status instead." + permission
    }

    private func stepButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.selected))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small segmented choice, the chosen one raised on a hairline.
struct HairlineSegments: View {
    let options: [(id: String, title: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { option in
                let on = option.id == selection
                Button { selection = option.id } label: {
                    Text(option.title).font(.system(size: 11.5)).foregroundColor(on ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? DS.Colors.surface : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? DS.Colors.borderSubtle : .clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.selected))
    }
}
