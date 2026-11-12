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
    /// False after its last messages reached nobody: it says where things stand instead of trying again.
    var mayMessage = true
}

extension BotDMTurn {
    /// A turn run on the other Mac needs what it's part of: who asked, the chat the owner spoke in and in what words. `chain`: which message of
    /// the owner's it belongs to, so the limits there start over for each.
    func linkFields(chain: String) -> [String: String] {
        var fields = ["rootRoom": context.rootRoom, "chain": chain, "chainFromOwner": context.fromOwner ? "1" : "0", "mayMessage": mayMessage ? "1" : "0"]
        if let exchangeID { fields["exchange"] = exchangeID }
        if let askerID { fields["asker"] = askerID }
        if let ownerWords = context.ownerWords { fields["ownerWords"] = ownerWords }
        return fields
    }

    init?(linkFields fields: [String: String]) {
        guard let rootRoom = fields["rootRoom"] else { return nil }
        self.init(exchangeID: fields["exchange"], askerID: fields["asker"],
                  context: BotDMContext(rootRoom: rootRoom, ownerWords: fields["ownerWords"], fromOwner: fields["chainFromOwner"] == "1"),
                  mayMessage: fields["mayMessage"] != "0")
    }
}

extension BotsStore {
    nonisolated static let noteAuthor = "note"
    /// How long a turn waits for a group chat it asked. A stuck round can't hold the turn, or the routine behind it, for good.
    nonisolated static let groupAnswerLimitSeconds: Double = 20 * 60

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

    /// The group chat Theo's [TELL:] means, when it means one.
    func groupTarget(named name: String) -> BotGroup? {
        guard CodingHarnessWords.id(forName: name) == nil else { return nil }
        let wanted = Self.searchName(name)
        guard wanted != Self.searchName(Self.clickyID) else { return nil }
        let chats = groups.filter { $0.headID != nil }
        if let exact = chats.first(where: { Self.searchName($0.name) == wanted }) { return exact }
        if bots.contains(where: { Self.searchName($0.name) == wanted }) { return nil }
        return chats.first { Self.searchName($0.name).contains(wanted) }
    }

    /// Asks a group chat and waits for its last word.
    private func answer(of chat: BotGroup, to words: String, from ceo: NativeBot, ownerWords: String?, rootRoom: String) async -> String {
        await withCheckedContinuation { continuation in
            var isDone = false
            let finish: (String) -> Void = { text in
                guard !isDone else { return }
                isDone = true
                continuation.resume(returning: text)
            }
            sendToGroup(fromCEO: words, ceo: ceo, groupID: chat.id, ownerWords: ownerWords, rootRoom: rootRoom) { finish($0) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.groupAnswerLimitSeconds * 1_000_000_000))
                finish("\(chat.name) didn't finish in time, so there's no answer from them yet.")
            }
        }
    }

    /// Who this name means, for this sender.
    func directMessageTarget(named name: String, from sender: NativeBot) -> NativeBot? {
        let wanted = Self.searchName(name)
        // The CEO can also reach Clicky's helpers by name.
        let candidates = sender.primary ? bots.filter { $0.id != sender.id && $0.isOn } : reachable(from: sender)
        return candidates.first { Self.searchName($0.name) == wanted } ?? candidates.first { Self.searchName($0.name).contains(wanted) && !wanted.isEmpty }
    }

    /// Sends a bot's [TELL:] lines one at a time, then lets it carry on with all the answers at once. `then` gets its last words.
    /// Theo's can name a group chat too: it's asked in turn with the rest, so one turn wakes him once however many he asked.
    /// `askerID` and `exchangeID`: this bot is itself answering a private message, so it carries on there.
    func runPrivateMessages(_ tells: [(name: String, message: String)], from sender: NativeBot, room: String, context: BotDMContext,
                            askerID: String? = nil, exchangeID: String? = nil, then: @escaping (String?) -> Void) {
        Task { [weak self] in
            guard let self else { return then(nil) }
            var replies: [(name: String, text: String)] = []
            var notes: [String] = []
            var lastRound: [String] = []
            let stopsBefore = self.stopCounts[context.rootRoom] ?? 0
            let wasStopped: @MainActor () -> Bool = { self.stoppedExchangeRooms.contains(context.rootRoom) || (self.stopCounts[context.rootRoom] ?? 0) != stopsBefore }
            for tell in tells {
                if wasStopped() { break }
                if sender.primary, let chat = self.groupTarget(named: tell.name) {
                    guard chat.roomID != room else {
                        notes.append("You're already talking in \(chat.name), so there's nothing to ask them separately.")
                        continue
                    }
                    // A round in a group counts as a message too, or Theo could keep asking the group forever.
                    let verdict = (self.directMessageBudgets[self.budgetKey(context.rootRoom)] ?? BotDMBudget()).verdict(roundTripsSoFar: 0)
                    if let line = BotDMBudget.capLine(verdict, sender: sender.name, target: chat.name) {
                        self.post(BotChatMessage(author: Self.noteAuthor, text: line), to: room)
                        notes.append(line)
                        continue
                    }
                    self.directMessageBudgets[self.budgetKey(context.rootRoom), default: BotDMBudget()].noteSent()
                    self.post(BotChatMessage(author: Self.noteAuthor, text: "\(sender.name) asked \(chat.name) in their group chat."), to: room)
                    let words = self.withTeamWork(tell.message, ownerWords: context.ownerWords)
                    let answer = await self.answer(of: chat, to: words, from: sender, ownerWords: context.ownerWords, rootRoom: context.rootRoom)
                    if wasStopped() { break }
                    // The group chat has the whole of it, a final prompt included.
                    replies.append((chat.name, answer.components(separatedBy: "```prompt").first ?? answer))
                    continue
                }
                guard let target = self.directMessageTarget(named: tell.name, from: sender) else {
                    let names = (sender.primary ? self.bots.filter { $0.id != sender.id && $0.isOn } : self.reachable(from: sender)).map(\.name).joined(separator: ", ")
                    notes.append("There's nobody called \(tell.name) you can message. Who you can reach: \(names).")
                    continue
                }
                let key = [room, sender.id, target.id].joined(separator: "|")
                let turn = self.ownerTurns[context.rootRoom] ?? 0
                var exchange = self.openExchanges[key].flatMap { $0.ownerTurn == turn ? $0 : nil }
                    ?? BotDMExchange(threadID: BotDMThread.id(sender.id, target.id), senderID: sender.id, targetID: target.id, room: room, rootRoom: context.rootRoom, ownerTurn: turn)
                let verdict = (self.directMessageBudgets[self.budgetKey(context.rootRoom)] ?? BotDMBudget()).verdict(roundTripsSoFar: exchange.roundTrips)
                if let line = BotDMBudget.capLine(verdict, sender: sender.name, target: target.name) {
                    // Said plainly in the chat, and the sender knows not to wait for it.
                    self.post(BotChatMessage(author: Self.noteAuthor, text: line, exchangeID: exchangeID), to: room)
                    notes.append(line)
                    continue
                }
                self.directMessageBudgets[self.budgetKey(context.rootRoom), default: BotDMBudget()].noteSent()
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
                if wasStopped() { break }
                guard let answer, !answer.isEmpty else {
                    notes.append("\(target.name) didn't answer.")
                    continue
                }
                replies.append((target.name, self.startRunIfAsked(answer, target: target, context: context)))
                if exchange.roundTrips >= BotDMBudget.maximumRoundTrips { lastRound.append(target.name) }
            }
            if wasStopped() { return then(nil) }
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
    func privateMessageWords(for target: NativeBot, from sender: NativeBot, message: String, record: BotConversationRecord, hasSession: Bool, context: BotDMContext) -> String {
        // The newest message is this one. A session already has what it answered on this Mac: only what happened on the other Mac is new to it.
        let earlier = Array(record.messages.dropLast())
        let isWords: (BotChatMessage) -> Bool = { !$0.text.isEmpty && $0.author != Self.noteAuthor }
        let unseen = hasSession
            ? BotCatchUp.unheard(messages: earlier, id: \.id, heard: record.heard?[target.id], hasSession: true, isLinked: true, counts: isWords)
            : Array(earlier.filter(isWords).suffix(6))
        let lines = BotCatchUp.lines(unseen.map { (bot($0.author)?.name ?? $0.author, $0.text) })
        return BotProtocol.privateMessagePrompt(from: sender.name, senderRole: BotPrompts.roleLine(for: sender), message: message, ownerAsked: context.ownerWords,
                                                earlier: lines, owner: BotPrompts.ownerName)
    }

    /// A coder's final prompt for work the owner just asked for starts the run, in the chat the owner asked in. The sender hears that rather
    /// than the whole prompt. Anything else goes back as it was written.
    private func startRunIfAsked(_ answer: String, target: NativeBot, context: BotDMContext) -> String {
        guard context.ownerWords != nil, let title = startRunFromPrivateAnswer(answer, room: context.rootRoom) else { return answer }
        let words = answer.components(separatedBy: "```prompt").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (words.isEmpty ? "" : words + "\n\n") + "(\(target.name)'s prompt has started the run \"\(title)\", so don't start it again. It shows on its card in this chat.)"
    }

    /// The sender reads the answers and carries on where it was.
    func carryOn(_ sender: NativeBot, room: String, replies: [(name: String, text: String)], notes: [String], lastRound: [String], context: BotDMContext,
                         askerID: String?, exchangeID: String?, then: @escaping (String?) -> Void) {
        // Nothing got through this time: it says where things stand. Letting it try again is how a stubborn model loops forever.
        let mayMessage = !replies.isEmpty
        let stopsBefore = stopCounts[context.rootRoom] ?? 0
        Task { [weak self] in
            while self?.replying[sender.id] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard let self else { return then(nil) }
            // Stopped while it waited, even if the owner has written something new since.
            if self.stoppedExchangeRooms.contains(context.rootRoom) || (self.stopCounts[context.rootRoom] ?? 0) != stopsBefore { return then(nil) }
            let session = self.conversation(room).sessions[sender.id]
            // Inside a private thread it's answering the bot that asked, not the owner.
            let reader = askerID.flatMap { self.bot($0)?.name } ?? BotPrompts.ownerName
            let words = BotProtocol.repliesPrompt(replies, notes: notes, lastRoundWith: lastRound, reader: reader, mayMessage: mayMessage)
            let prompt = session == nil ? BotPrompts.firstMessage(bot: sender, team: self.bots, text: words) : words
            let turn = BotDMTurn(exchangeID: exchangeID, askerID: askerID, context: context, mayMessage: mayMessage)
            self.reply(bot: sender, in: room, prompt: prompt, session: session, handsOnWhenStopped: true, fromOwner: context.fromOwner, mayUseScreen: context.ownerWords != nil, privately: turn, then: then)
        }
    }

    /// Stop on a chat: its private messages stop, and nobody carries on from them.
    func stopPrivateMessages(in room: String) {
        // Marked even with nothing live: a carry-on can be waiting for its turn.
        stoppedExchangeRooms.insert(room)
        stopCounts[room, default: 0] += 1
        let live = liveExchanges.filter { $0.value.rootRoom == room || $0.value.room == room }
        for (id, exchange) in live {
            stoppedExchangeRooms.insert(exchange.rootRoom)
            if exchange.rootRoom != room { stopCounts[exchange.rootRoom, default: 0] += 1 }
            liveExchanges[id] = nil
            // The card can tell it's over.
            post(BotChatMessage(author: Self.noteAuthor, text: "Stopped.", exchangeID: id), to: BotDMThread.id(exchange.senderID, exchange.targetID))
            if replyingIn[exchange.targetID] == BotDMThread.id(exchange.senderID, exchange.targetID) { stop(exchange.targetID) }
        }
    }
}
