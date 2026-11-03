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
    @ObservedObject private var live = StudioController.shared.live
    @ObservedObject private var link = TheoLink.shared

    var body: some View {
        if StudioController.isAvailable { localPanel } else { RemoteStudioPanel(store: store, studio: studio) }
    }

    private var localPanel: some View {
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
                HStack {
                    Text("\(studio.screenCount) hidden screen\(studio.screenCount == 1 ? "" : "s") · \(studio.allTiles.count) tiles · Mac Studio only")
                        .font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary)
                    Spacer(minLength: 8)
                    Button {
                        studio.stageNewScreen()
                        selection.openSettings(.studio)
                    } label: { Label("New screen", systemImage: "plus") }
                    .buttonStyle(.theo(.ghost, .small))
                    .help("Add a hidden screen. It's made when you press Apply in Settings.")
                }
                .padding(.top, -6)
                LinkStatusLine(link: link)
                if let problem = studio.problem {
                    Text(problem).font(.system(size: 11.5)).foregroundColor(DS.Colors.warningText).fixedSize(horizontal: false, vertical: true)
                }
                if let tile = studio.expandedTile { expanded(tile) }
                ForEach(0..<studio.screenCount, id: \.self) { screen in screenCard(screen) }
                StudioPanelHint(isPaused: studio.liveViewPaused, isIdle: studio.liveCount == 0)
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
        let spec = studio.config.screens.indices.contains(screen) ? studio.config.screens[screen] : nil
        let count = studio.tiles(onScreen: screen)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(spec?.name ?? "Screen \(screen + 1)").font(.system(size: 11.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                Spacer()
                Text(spec?.sizeLabel ?? "").font(.system(size: 11, design: .monospaced)).foregroundColor(DS.Colors.textSecondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: StudioLayout.grid(forTiles: count).columns), spacing: 4) {
                ForEach(0..<count, id: \.self) { tile in
                    tileView(StudioTileID(screen: screen, tile: tile))
                        .aspectRatio(Double(spec?.width ?? 1440) / Double(StudioLayout.grid(forTiles: count).columns) / (Double(spec?.height ?? 900) / Double(StudioLayout.grid(forTiles: count).rows)), contentMode: .fit)
                }
            }
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
            } else if let page = studio.tilePages[tile] {
                StudioPageCard(page: page)
            } else if let bot {
                CrewAvatar(look: bot.crewLook, size: 54, pose: store.crewPose(of: bot).pose, interactive: false)
            }
            if image != nil, studio.liveViewPaused {
                Color.black.opacity(0.45)
                Text("Paused while video plays").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.85)).multilineTextAlignment(.center).padding(8)
            }
            if let cursor = studio.tileCursors[tile] { StudioTileCursorView(cursor: cursor) }
            if image != nil, !studio.liveViewPaused {
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
                    let heading = StudioRemoteView.headline(note: studio.tileNotes[tile], fallback: bot.name)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(heading.title).font(.system(size: 11, weight: .medium)).foregroundColor(.white).lineLimit(1)
                        Text(heading.detail ?? store.liveStatus(of: bot)).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4).padding(.trailing, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.72)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(6)
            }
            if bot == nil, image == nil {
                if let owner = studio.owner(ofScreen: tile.screen).flatMap({ store.bot($0) }) {
                    // Nothing here right now: its owner, asleep.
                    VStack(spacing: 4) {
                        CrewAvatar(look: owner.crewLook, size: 44, pose: .sleep, moves: false, interactive: false)
                        Text(owner.name).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                    }
                } else {
                    Text("Shared pool").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.55)).multilineTextAlignment(.center)
                }
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
        Divider()
        Menu("\(studio.config.screens.indices.contains(tile.screen) ? studio.config.screens[tile.screen].name : "This screen") belongs to") {
            ForEach(store.bots) { candidate in
                Button((studio.owner(ofScreen: tile.screen) == candidate.id ? "✓ " : "") + candidate.name) { studio.setOwner(candidate.id, ofScreen: tile.screen) }
            }
            Divider()
            Button("Shared pool") { studio.setOwner(nil, ofScreen: tile.screen) }
        }
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
            let previewRate = studio.config.screens.map(\.previewFPS).max() ?? StudioPreviewSchedule.defaultFPS
            meterCell("Preview", value: studio.isOn && !studio.liveViewPaused ? "\(previewRate) fps" : "Off", fill: studio.isOn && !studio.liveViewPaused ? Double(previewRate) / Double(StudioScreenSpec.previewFPSRange.upperBound) : 0)
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
/// A tile with no picture: the page the agent is on, from the page itself.
struct StudioPageCard: View {
    let page: StudioTilePage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(page.host).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            if let title = page.title, !title.isEmpty {
                Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.white).lineLimit(2)
            }
            Text(page.excerpt).font(.system(size: 9)).foregroundColor(.white.opacity(0.6)).lineLimit(nil)
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

struct StudioPanelHint: View {
    let isPaused: Bool
    let isIdle: Bool

    var body: some View {
        if isPaused {
            Text("Live view paused while video plays").font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary)
        } else if isIdle {
            Text("Ask Clicky to research something and its agents work here.").font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary)
        }
    }
}

/// The panel on a Mac with no screens of its own: the Studio's tiles, sent over Theo Link.
struct RemoteStudioPanel: View {
    @ObservedObject var store: BotsStore
    @ObservedObject var studio: StudioController
    @ObservedObject private var link = TheoLink.shared

    var body: some View {
        let view = studio.remoteView
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HairlineIcon(name: "studio", size: 20, color: DS.Colors.textPrimary, live: view?.tiles.isEmpty == false)
                Text("Studio").font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                if let count = view?.tiles.count, count > 0 {
                    HStack(spacing: 6) {
                        LiveDot()
                        Text("\(count) live").font(.system(size: 11.5, weight: .medium)).foregroundColor(DS.Colors.accentText)
                    }
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(DS.Colors.accentSoft))
                }
                Spacer()
            }
            .frame(height: 30)
            Text(link.isConnected ? "Your Mac Studio's screens" : "Your Mac Studio isn't connected").font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).padding(.top, -6)
            ForEach(0..<(view?.screens ?? 2), id: \.self) { screen in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Screen \(screen + 1)").font(.system(size: 11.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    HStack(spacing: 4) {
                        ForEach(0..<(view?.tilesPerScreen ?? 2), id: \.self) { index in tile(view?.tiles.first { $0.screen == screen && $0.tile == index }) }
                    }
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            }
            StudioPanelHint(isPaused: view?.paused == true && view?.tiles.isEmpty == false, isIdle: view?.tiles.isEmpty != false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)
        .background(DS.Colors.sidebar)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func tile(_ item: StudioRemoteView.Tile?) -> some View {
        let bot = item.flatMap { store.bot($0.bot) }
        return ZStack {
            Color(hex: 0x0C0C0E)
            if let data = item?.jpeg, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
            } else if let page = item?.page {
                StudioPageCard(page: page)
            } else if let bot {
                CrewAvatar(look: bot.crewLook, size: 44, pose: .sleep, moves: false, interactive: false)
            }
            if let item, let bot {
                let heading = StudioRemoteView.headline(note: item.note, fallback: bot.name)
                VStack(alignment: .leading, spacing: 0) {
                    Text(heading.title).font(.system(size: 11, weight: .medium)).foregroundColor(.white).lineLimit(1)
                    if let detail = heading.detail { Text(detail).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.65)).lineLimit(1) }
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.72)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Whether the other Mac is linked, and what to do if it isn't working.
struct LinkStatusLine: View {
    @ObservedObject var link: TheoLink

    var body: some View {
        if link.isPaired {
            let other = TheoLink.shortName(link.peerName ?? link.knownPeerName ?? "Your other Mac")
            let build = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(link.isConnected ? Color(hex: 0x4ADE80) : DS.Colors.textDisabled).frame(width: 6, height: 6)
                if !link.isConnected {
                    Text("\(other) isn't connected. Open Theo there.")
                } else if let theirs = link.peerBuild, theirs < build {
                    Text("\(other) is linked, on an older build: click Update now there.")
                } else {
                    Text("\(other) is linked and sees these screens.")
                }
            }
            .font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Clicky's own cursor drawn over a tile. The real pointer never moves for this.
struct StudioTileCursorView: View {
    let cursor: StudioTileCursor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { area in
            Image(systemName: "cursorarrow").font(.system(size: 17, weight: .medium)).foregroundColor(.white)
                .shadow(color: .black.opacity(0.7), radius: 2)
                .scaleEffect(cursor.clicks % 2 == 0 ? 1 : 0.86)
                .position(x: area.size.width * min(max(cursor.point.x, 0), 1), y: area.size.height * min(max(cursor.point.y, 0), 1))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: cursor)
        }
        .allowsHitTesting(false)
    }
}

struct StudioTileThumb: View {
    @ObservedObject var studio: StudioController
    @ObservedObject private var live = StudioController.shared.live
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
            TheoSection(title: "Studio screens", hint: "Off by default. macOS treats these as part of your desktop, so Theo puts your pointer and windows straight back if they land on one. Mac Studio only. While these are on, macOS takes your monitors out of HDR, and turning them on or off nudges a monitor aside for a second. Either can interrupt a video that's playing, so don't turn them on during Netflix.") {
                SettingRow(title: "Hidden bot screens", detail: "Bots work on screens you never see") {
                    Toggle("", isOn: Binding(get: { studio.isEnabled }, set: { studio.setEnabled($0) })).labelsHidden().toggleStyle(.switch).tint(DS.Colors.accent)
                }
            }
            if StudioController.isAvailable {
                StudioScreensSection()
            } else {
                TheoSection(title: "Screens", hint: "Screens live on the Mac Studio. Set them up there, and this Mac shows them in the Studio panel.") { EmptyView() }
            }
            ResearchAgentSettingsSection()
            TheoSection(title: "Research", hint: "When a plain fetch can't read a page, Researcher opens it in a new window of your own Chrome on a hidden screen, reads the text and closes it. It only reads: no clicks, no typing, no cookies or passwords touched, and private places like mail and banks never open. Chrome blinks to the front for a moment each time, so it waits until you pause. Visits show in your Chrome history. If a site wants a human check, it waits for you.") {
                SettingRow(title: "Research agents use my browser on Studio screens", detail: "Clicky's research agents, one tile each. Tiles are freed when they're done") {
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
                        SettingRow(title: studio.config.screens.indices.contains(index) ? studio.config.screens[index].name : "Screen \(index + 1)", detail: "Off to the side, away from your monitors") {
                            Text("\(Int(box["x"] ?? 0)), \(Int(box["y"] ?? 0))").font(.system(size: 12, design: .monospaced)).foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var captureNote: String {
        let permission = studio.hasCapturePermission ? "" : " It also needs Screen Recording, which Theo never asks for by itself."
        return "Capturing can black out Netflix on your monitors, the way screen recording does, so nothing is captured while anything's playing: tiles show the page's words instead, and pictures come back when it stops. A tile with another app shows its bot and status instead." + permission
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
