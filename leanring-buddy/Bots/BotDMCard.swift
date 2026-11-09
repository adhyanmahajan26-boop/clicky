//
//  BotDMCard.swift
//  leanring-buddy
//
//  What the owner sees of a private message between bots: one compact card in the chat it started from, collapsed by default. Two small
//  figures, "Theo messaged Coder privately", the time, a line of what was said, how many messages, and a chevron. One click opens the
//  whole exchange in place; another folds it. The other bot's own chat with the owner isn't touched.
//

import ClickyCore
import SwiftUI

struct BotDMCard: View {
    @ObservedObject var store: BotsStore
    let senderID: String
    let targetID: String
    let exchangeID: String
    let at: Date
    @State private var isOpen = false
    @State private var hovering = false

    private var sender: NativeBot? { store.bot(senderID) }
    private var target: NativeBot? { store.bot(targetID) }
    private var messages: [BotChatMessage] { store.exchangeMessages(exchangeID, senderID: senderID, targetID: targetID) }
    /// What's said in words. A card nested in the exchange isn't one.
    private var spoken: [BotChatMessage] { messages.filter { !$0.text.isEmpty && $0.author != BotsStore.noteAuthor } }
    private var live: BotDMLive? { store.liveExchanges[exchangeID] }

    /// "Coder is replying…" while it writes here; on the other Mac the thread itself shows there's no answer yet.
    private var statusLine: String? {
        guard let target else { return nil }
        if let live { return live.isReplying ? "\(target.name) is replying\u{2026}" : "\(target.name) is busy, and will answer when it's free" }
        guard let last = messages.last(where: { !$0.text.isEmpty }) else { return nil }
        return BotDMCardText.looksLive(lastAuthorIsSender: last.author == senderID, lastAt: last.at) ? "\(target.name) is replying\u{2026}" : nil
    }

    var body: some View {
        if let sender, let target {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(DS.Motion.hover) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        figures(sender, target)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(BotDMCardText.headline(sender: sender.name, target: target.name))
                                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                                Text(at.formatted(date: .omitted, time: .shortened)).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                            }
                            if let statusLine {
                                HStack(spacing: 6) {
                                    TypingDots()
                                    Text(statusLine).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                                }
                            } else if !isOpen, let newest = spoken.last {
                                Text(BotDMCardText.preview(newest.text)).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(BotDMCardText.count(spoken.count)).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1).fixedSize()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Fold this private exchange" : "Open this private exchange")
                .pointerCursor()
                .onHover { hovering = $0 }
                if isOpen {
                    Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            if let nested = BotDMThread.parseCard(message.card) {
                                BotDMCard(store: store, senderID: message.author, targetID: nested.targetID, exchangeID: nested.exchangeID, at: message.at)
                            } else if let author = store.bot(message.author), !message.text.isEmpty {
                                BotDMLine(author: author, message: message)
                            } else if message.author == BotsStore.noteAuthor {
                                ChatNote(text: message.text)
                            }
                        }
                    }
                    .padding(12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering && !isOpen ? DS.Colors.hover : DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.leading, 36)
        }
    }

    /// The sender's figure, with the other bot's tucked behind it.
    private func figures(_ sender: NativeBot, _ target: NativeBot) -> some View {
        ZStack(alignment: .topLeading) {
            BotAvatar(bot: target, size: 20, state: .idle).offset(x: 14, y: 8)
            BotAvatar(bot: sender, size: 20, state: .idle)
        }
        .frame(width: 34, height: 28, alignment: .topLeading)
    }
}

/// One message of a private exchange.
private struct BotDMLine: View {
    let author: NativeBot
    let message: BotChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            BotAvatar(bot: author, size: 22, state: .idle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(author.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text(message.at.formatted(date: .omitted, time: .shortened)).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                }
                RichBlock(text: message.text).equatable().textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A plain line from Theo itself in a chat: why something happened, or that a limit stopped it. It isn't any bot talking.
struct ChatNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).padding(.top, 1)
            Text(text).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 36)
    }
}

/// Something set to the other Mac, which can't be reached right now: said plainly, with the way to run it here instead.
struct BotWaitingCard: View {
    static func card(id: String) -> String { "waiting:\(id)" }
    static func id(of card: String?) -> String? {
        guard let card, card.hasPrefix("waiting:") else { return nil }
        return String(card.dropFirst("waiting:".count))
    }

    @ObservedObject var store: BotsStore
    @ObservedObject private var link = TheoLink.shared
    let id: String
    let text: String

    var body: some View {
        if let waiting = link.waiting(id) {
            VStack(alignment: .leading, spacing: 8) {
                ChatNote(text: text)
                if waiting.isStale {
                    ChatNote(text: "This waited over a day, so it won't go now. Send it again if you still want it.")
                } else if waiting.heldForOwner == true {
                    HStack(spacing: 8) {
                        Button("Start on your \(TheoLink.shortName(link.peerName ?? link.knownPeerName ?? "other Mac"))") { _ = link.sendHeld(id) }
                            .buttonStyle(.theo(.primary, .small))
                            .disabled(!link.isConnected)
                        if waiting.canRunHere {
                            Button("Run it on this \(TheoLink.shortName(TheoLink.localName))") { store.runWaitingHere(id) }
                                .buttonStyle(.theo(.secondary, .small))
                        }
                        Button("Don't start it") { _ = link.takeWaiting(id) }
                            .buttonStyle(.theo(.secondary, .small))
                    }
                    .pointerCursor()
                    .padding(.leading, 54)
                } else if waiting.canRunHere {
                    Button("Run it on this \(TheoLink.shortName(TheoLink.localName)) instead") { store.runWaitingHere(id) }
                        .buttonStyle(.theo(.secondary, .small))
                        .pointerCursor()
                        .padding(.leading, 54)
                }
            }
        } else {
            // It's gone now, or was run here. This Mac said so at the time.
            ChatNote(text: "This waited for your other Mac.")
        }
    }
}

/// A bot's private threads with the other bots, for reading. Under its settings.
struct BotPrivateThreadsList: View {
    @ObservedObject var store: BotsStore
    let botID: String
    @State private var openThread: String?

    var body: some View {
        let threads = store.privateThreads(of: botID)
        if !threads.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Messages with other bots").font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                ForEach(threads, id: \.id) { thread in
                    if let partner = store.bot(thread.partnerID) {
                        Button { openThread = thread.id } label: {
                            HStack(spacing: 8) {
                                BotAvatar(bot: partner, size: 22, state: .idle)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(partner.name).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                                    Text(BotDMCardText.preview(store.conversation(thread.id).messages.last { !$0.text.isEmpty }?.text ?? ""))
                                        .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Text(thread.lastAt.formatted(date: .abbreviated, time: .omitted)).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1).fixedSize()
                            }
                            .padding(.horizontal, 8).frame(minHeight: 36).contentShape(Rectangle())
                        }
                        .buttonStyle(SidebarButtonStyle(isSelected: false))
                        .pointerCursor()
                    }
                }
            }
            .sheet(item: Binding(get: { openThread.map { ThreadSheetID(id: $0) } }, set: { openThread = $0?.id })) { sheet in
                BotPrivateThreadSheet(store: store, threadID: sheet.id) { openThread = nil }
            }
        }
    }

    private struct ThreadSheetID: Identifiable { let id: String }
}

/// One private thread, read-only.
private struct BotPrivateThreadSheet: View {
    @ObservedObject var store: BotsStore
    let threadID: String
    let onClose: () -> Void

    private var names: String {
        guard let pair = BotDMThread.members(of: threadID) else { return "Private messages" }
        return "\(store.bot(pair.first)?.name ?? pair.first) and \(store.bot(pair.second)?.name ?? pair.second)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(names).font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button("Done", action: onClose).buttonStyle(.theoSecondary).keyboardShortcut(.cancelAction)
            }
            Text("Their private messages. You can read them here; they don't write in your chats.").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.conversation(threadID).messages) { message in
                        if let nested = BotDMThread.parseCard(message.card) {
                            BotDMCard(store: store, senderID: message.author, targetID: nested.targetID, exchangeID: nested.exchangeID, at: message.at)
                        } else if let author = store.bot(message.author), !message.text.isEmpty {
                            BotDMLine(author: author, message: message)
                        } else if message.author == BotsStore.noteAuthor {
                            ChatNote(text: message.text)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(width: 560, height: 520)
        .background(DS.Colors.background)
    }
}
