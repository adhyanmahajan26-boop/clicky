//
//  StudioDeskWindow.swift
//  leanring-buddy
//
//  A bot's desk on a hidden screen: a plain window of Theo's own with what it's doing. It never takes focus, stays out of
//  window lists and Exposé, and sits only on its tile.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

@MainActor
enum StudioDeskWindow {
    static func make(botID: String) -> NSWindow {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isExcludedFromWindowsMenu = true
        panel.contentView = NSHostingView(rootView: StudioDeskView(store: BotsStore.shared, botID: botID))
        return panel
    }
}

private struct StudioDeskView: View {
    @ObservedObject var store: BotsStore
    let botID: String
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var bot: NativeBot? { store.bot(botID) }
    private var run: T3Run? { store.liveRun(of: botID) }
    private var lines: [String] {
        let live = (store.replying[botID] ?? "").split(whereSeparator: \.isNewline).suffix(10).map(String.init)
        return store.conversation(botID).messages.suffix(live.isEmpty ? 14 : 6).flatMap { message in
            message.text.split(whereSeparator: \.isNewline).prefix(4).map { (message.author == "user" ? "> " : "") + String($0) }
        } + live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                if let bot { BotAvatar(bot: bot, size: 96, state: .idle) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(bot?.name ?? botID).font(.system(size: 44, weight: .semibold)).foregroundColor(.white)
                    Text(bot.map(store.liveStatus(of:)) ?? "").font(.system(size: 24)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer()
                Text(now, format: .dateTime.hour().minute().second()).font(.system(size: 20, design: .monospaced)).foregroundColor(.white.opacity(0.5))
            }
            .padding(24)
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            if let run {
                // A mirror of the run's card. Its terminal stays on the owner's machine.
                VStack(alignment: .leading, spacing: 12) {
                    Text(run.title).font(.system(size: 28, weight: .semibold)).foregroundColor(.white).lineLimit(2)
                    RunStepBar(fills: RunSteps.fills(phase: run.phase, stage: run.stage), stopping: run.stoppedByOwner == true)
                    if let activity = run.activity, !activity.isEmpty {
                        Text(activity).font(.system(size: 22, design: .monospaced)).foregroundColor(.white.opacity(0.75)).lineLimit(4)
                    }
                }
                .padding(24)
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 24, design: .monospaced)).foregroundColor(line.hasPrefix(">") ? Color(hex: 0x82AAFF) : Color(hex: 0xCFCFCF)).lineLimit(1)
                }
                if lines.isEmpty { Text("Nothing here yet.").font(.system(size: 24, design: .monospaced)).foregroundColor(.white.opacity(0.4)) }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: 0x0B0B0D))
        .environment(\.colorScheme, .dark)
        .onReceive(tick) { now = $0 }
    }
}
