//
//  BotPrivateMessages.swift
//  leanring-buddy
//
//  How bots message each other: privately, one exchange at a time. A bot writes [TELL: Coder: …] in its reply. The message goes in the
//  private thread of that pair ("dm:coder+theo", a chat file of its own, synced over Theo Link), Coder answers there with an engine
//  session kept for that partner, the whole answer goes back to the sender, and the sender carries on where it was and says what came of
//  it. The owner sees one collapsed card in the chat it started from (BotDMCard). Coder's own chat with the owner isn't touched.
//

import ClickyCore
import Foundation

/// One bot asking another about one thing. Another [TELL:] back and forth continues it, on the same card.
struct BotDMExchange: Equatable {
    var id: String = UUID().uuidString
    var threadID: String
    var senderID: String
    var targetID: String
    /// The chat the card sits in, and where the sender carries on.
    var room: String
    var rootRoom: String
    /// Which message of the owner's it belongs to.
    var ownerTurn: Int
    var roundTrips = 0
}

/// A private exchange going on right now, for its card and for Stop.
struct BotDMLive: Equatable {
    var senderID: String
    var targetID: String
    var room: String
    var rootRoom: String
    /// False while the other bot is busy with something else.
    var isReplying: Bool
}

/// What a chain of private messages belongs to.
struct BotDMContext {
    /// The chat the owner (or a routine) spoke in. Coding runs and budgets belong to this chat, however deep the messages go.
    var rootRoom: String
    /// The owner's own words behind it, when there are any.
    var ownerWords: String?
    var fromOwner: Bool
    /// On a call there's no chat turn to carry on in: the answers go here instead.
    var onReport: ((String) -> Void)?
}

/// A turn that answers a private message.
struct BotDMTurn {
    /// The exchange it answers. Nil for a bot carrying on in an ordinary chat after hearing back.
    var exchangeID: String?
    var askerID: String?
    var context: BotDMContext
}

extension BotsStore {
    nonisolated static let noteAuthor = "note"

    /// The owner said something in this chat: the limits on private messages start over.
    func ownerSpoke(in room: String) {
        ownerTurns[room, default: 0] += 1
        directMessageBudgets[room, default: BotDMBudget()].ownerSpoke()
        stoppedExchangeRooms.remove(room)
    }

    /// The private threads a bot is in, newest first.
    func privateThreads(of botID: String) -> [(id: String, partnerID: String, lastAt: Date)] {
        conversations.compactMap { id, record -> (id: String, partnerID: String, lastAt: Date)? in
            guard let partner = BotDMThread.partner(of: botID, in: id), let last = record.messages.last else { return nil }
            return (id, partner, last.at)
        }.sorted { $0.lastAt > $1.lastAt }
    }

    /// The messages of one exchange, in order.
    func exchangeMessages(_ exchangeID: String, senderID: String, targetID: String) -> [BotChatMessage] {
        conversation(BotDMThread.id(senderID, targetID)).messages.filter { $0.exchangeID == exchangeID }
    }

    /// Theo's [TELL:] can name a harness, Clicky or a group chat. Those stay orders. Only another bot is a private message.
    func isOrderRatherThanMessage(_ name: String) -> Bool {
        if CodingHarnessWords.id(forName: name) != nil { return true }
        let wanted = Self.searchName(name)
        if wanted == Self.searchName(Self.clickyID) { return true }
        let chats = groups.filter { $0.headID != nil }
        if chats.contains(where: { Self.searchName($0.name) == wanted }) { return true }
        if bots.contains(where: { Self.searchName($0.name) == wanted }) { return false }
        return chats.contains { Self.searchName($0.name).contains(wanted) }
    }

    /// Who this name means, for this sender.
    func directMessageTarget(named name: String, from sender: NativeBot) -> NativeBot? {
        let wanted = Self.searchName(name)
        // The CEO can also reach Clicky's helpers by name.
        let candidates = sender.primary ? bots.filter { $0.id != sender.id && $0.isOn } : reachable(from: sender)
        return candidates.first { Self.searchName($0.name) == wanted } ?? candidates.first { Self.searchName($0.name).contains(wanted) && !wanted.isEmpty }
    }

    /// Sends a bot's [TELL:] lines one at a time, then lets it carry on with all the answers at once. `then` gets its last words.
    /// `askerID` and `exchangeID`: this bot is itself answering a private message, so it carries on there.
    func runPrivateMessages(_ tells: [(name: String, message: String)], from sender: NativeBot, room: String, context: BotDMContext,
                            askerID: String? = nil, exchangeID: String? = nil, then: @escaping (String?) -> Void) {
        Task { [weak self] in
            guard let self else { return then(nil) }
            var replies: [(name: String, text: String)] = []
            var notes: [String] = []
            var lastRound: [String] = []
            for tell in tells {
                if self.stoppedExchangeRooms.contains(context.rootRoom) { break }
                guard let target = self.directMessageTarget(named: tell.name, from: sender) else {
                    let names = (sender.primary ? self.bots.filter { $0.id != sender.id && $0.isOn } : self.reachable(from: sender)).map(\.name).joined(separator: ", ")
                    notes.append("There's nobody called \(tell.name) you can message. Who you can reach: \(names).")
                    continue
                }
                let key = [room, sender.id, target.id].joined(separator: "|")
                let turn = self.ownerTurns[context.rootRoom] ?? 0
                var exchange = self.openExchanges[key].flatMap { $0.ownerTurn == turn ? $0 : nil }
                    ?? BotDMExchange(threadID: BotDMThread.id(sender.id, target.id), senderID: sender.id, targetID: target.id, room: room, rootRoom: context.rootRoom, ownerTurn: turn)
                let verdict = (self.directMessageBudgets[context.rootRoom] ?? BotDMBudget()).verdict(roundTripsSoFar: exchange.roundTrips)
                if let line = BotDMBudget.capLine(verdict, sender: sender.name, target: target.name) {
                    // Said plainly in the chat, and the sender knows not to wait for it.
                    self.post(BotChatMessage(author: Self.noteAuthor, text: line, exchangeID: exchangeID), to: room)
                    notes.append(line)
                    continue
                }
                self.directMessageBudgets[context.rootRoom, default: BotDMBudget()].noteSent()
                if exchange.roundTrips == 0 {
                    // The card goes in the chat it started from. In a private thread it belongs to that exchange's messages.
                    self.post(BotChatMessage(author: sender.id, text: "", card: BotDMThread.card(exchangeID: exchange.id, targetID: target.id), exchangeID: exchangeID), to: room)
                }
                exchange.roundTrips += 1
                self.openExchanges[key] = exchange
                self.exchangeRooms[exchange.threadID] = (sender.id, room, context)
                let words = sender.primary ? self.withTeamWork(tell.message, ownerWords: context.ownerWords) : tell.message
                self.post(BotChatMessage(author: sender.id, text: words, exchangeID: exchange.id), to: exchange.threadID)
                let answer = await self.privateTurn(of: target, from: sender, message: words, exchange: exchange, context: context)
                self.liveExchanges[exchange.id] = nil
                if self.stoppedExchangeRooms.contains(context.rootRoom) { break }
                guard let answer, !answer.isEmpty else {
                    notes.append("\(target.name) didn't answer.")
                    continue
                }
                replies.append((target.name, self.startRunIfAsked(answer, target: target, context: context)))
                if exchange.roundTrips >= BotDMBudget.maximumRoundTrips { lastRound.append(target.name) }
            }
            if self.stoppedExchangeRooms.contains(context.rootRoom) { return then(nil) }
            guard !replies.isEmpty || !notes.isEmpty else { return then(nil) }
            // On a call nobody carries on in a chat: the answers go to the call, which says them.
            if let onReport = context.onReport {
                onReport((replies.map { "\($0.name) answered: \($0.text.components(separatedBy: "```prompt").first ?? $0.text)" } + notes).joined(separator: "\n\n"))
                return then(nil)
            }
            self.carryOn(sender, room: room, replies: replies, notes: notes, lastRound: lastRound, context: context, askerID: askerID, exchangeID: exchangeID, then: then)
        }
    }

    /// The other bot's turn, in the private thread. Nil when it couldn't answer.
    private func privateTurn(of target: NativeBot, from sender: NativeBot, message: String, exchange: BotDMExchange, context: BotDMContext) async -> String? {
        liveExchanges[exchange.id] = BotDMLive(senderID: sender.id, targetID: target.id, room: exchange.room, rootRoom: context.rootRoom, isReplying: replying[target.id] == nil)
        let deadline = Date().addingTimeInterval(BotRunner.turnLimitSeconds + 60)
        while replying[target.id] != nil {
            if stoppedExchangeRooms.contains(context.rootRoom) || Date() > deadline { return nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        liveExchanges[exchange.id]?.isReplying = true
        let thread = exchange.threadID
        let record = conversation(thread)
        let session = record.sessions[target.id]
        let prompt = BotPrompts.awarenessNote(for: target, room: thread) + "(\(BotProtocol.privateThreadHowTo(partner: sender.name)))\n\n" +
            privateMessageWords(for: target, from: sender, message: message, record: record, hasSession: session != nil, context: context)
        let firstMessage = session == nil ? BotPrompts.firstMessage(bot: target, team: bots, text: prompt) : prompt
        // Only the owner's own words can have a screen job done on the way.
        let turn = BotDMTurn(exchangeID: exchange.id, askerID: sender.id, context: context)
        return await withCheckedContinuation { continuation in
            reply(bot: target, in: thread, prompt: firstMessage, session: session, handsOnWhenStopped: true, fromOwner: false, mayUseScreen: context.ownerWords != nil, privately: turn) { answer in
                continuation.resume(returning: answer)
            }
        }
    }

    /// The whole message, who sent it and why, and what the engine session hasn't seen of this thread.
    private func privateMessageWords(for target: NativeBot, from sender: NativeBot, message: String, record: BotConversationRecord, hasSession: Bool, context: BotDMContext) -> String {
        // The newest message is this one.
        let earlier = Array(record.messages.filter { !$0.text.isEmpty }.dropLast())
        let unseen: [BotChatMessage]
        if hasSession {
            // A session already has what it answered on this Mac. Only what happened on the other Mac is new to it.
            if let heard = record.heard?[target.id], let index = earlier.lastIndex(where: { $0.id == heard }) {
                unseen = Array(earlier[(index + 1)...])
            } else {
                unseen = []
            }
        } else {
            unseen = Array(earlier.suffix(6))
        }
        return BotProtocol.privateMessagePrompt(from: sender.name, senderRole: BotPrompts.roleLine(for: sender), message: message, ownerAsked: context.ownerWords,
                                                earlier: lines(unseen), owner: BotPrompts.ownerName)
    }

    private func lines(_ messages: [BotChatMessage]) -> [String] {
        messages.map { "\(bot($0.author)?.name ?? $0.author): \($0.text)" }
    }

    /// A coder's final prompt for work the owner asked for starts the run, in the chat the owner asked in. The sender hears that rather
    /// than the whole prompt. Anything else goes back as it was written.
    private func startRunIfAsked(_ answer: String, target: NativeBot, context: BotDMContext) -> String {
        guard let owner = context.ownerWords, let prompt = BotsT3.promptBlock(in: answer), BotsStore.ownerAskedToBuild(owner) else { return answer }
        let folder = projectChoice(ownerWords: owner, answer: answer)
        guard folder.repo != nil || folder.newFolder != nil || !BotsStore.isAboutExistingCode(owner) else { return answer }
        let choices = codingChoices(from: owner)
        let title = BotsT3.projectTitle(in: answer, prompt: prompt)
        submitToT3(prompt: prompt, title: title, repo: folder.repo, room: context.rootRoom, harness: choices.harness, modelChoice: choices.model, effortChoice: choices.effort, newFolder: folder.newFolder)
        let words = answer.components(separatedBy: "```prompt").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (words.isEmpty ? "" : words + "\n\n") + "(\(target.name)'s prompt has started the run \"\(title)\", so don't start it again. It shows on its card in this chat.)"
    }

    /// The sender reads the answers and carries on where it was.
    func carryOn(_ sender: NativeBot, room: String, replies: [(name: String, text: String)], notes: [String], lastRound: [String], context: BotDMContext,
                         askerID: String?, exchangeID: String?, then: @escaping (String?) -> Void) {
        Task { [weak self] in
            while self?.replying[sender.id] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard let self else { return then(nil) }
            if self.stoppedExchangeRooms.contains(context.rootRoom) { return then(nil) }
            let session = self.conversation(room).sessions[sender.id]
            let words = BotProtocol.repliesPrompt(replies, notes: notes, lastRoundWith: lastRound, owner: BotPrompts.ownerName)
            let prompt = session == nil ? BotPrompts.firstMessage(bot: sender, team: self.bots, text: words) : words
            let turn = BotDMTurn(exchangeID: exchangeID, askerID: askerID, context: context)
            self.reply(bot: sender, in: room, prompt: prompt, session: session, handsOnWhenStopped: true, fromOwner: context.fromOwner, mayUseScreen: context.ownerWords != nil, privately: turn, then: then)
        }
    }

    /// Stop on a chat: its private messages stop, and nobody carries on from them.
    func stopPrivateMessages(in room: String) {
        let live = liveExchanges.filter { $0.value.rootRoom == room || $0.value.room == room }
        guard !live.isEmpty else { return }
        stoppedExchangeRooms.insert(room)
        for (id, exchange) in live {
            stoppedExchangeRooms.insert(exchange.rootRoom)
            liveExchanges[id] = nil
            if replyingIn[exchange.targetID] == BotDMThread.id(exchange.senderID, exchange.targetID) { stop(exchange.targetID) }
        }
    }
}
