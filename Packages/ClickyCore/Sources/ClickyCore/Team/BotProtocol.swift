//
//  BotProtocol.swift
//  ClickyCore
//
//  How Theo's bots talk: one way to message a bot, one way to hand work over in a group, and one house style, in the same
//  words in every prompt. The pure parts live here so the assembled prompts can be tested for contradictions: private threads
//  and their caps, who speaks next in a group chat, @Name parsing, and the "where you are" and "who you are" blocks.
//

import Foundation

// MARK: - Private threads between two bots

/// A private thread per pair of bots, and the card that stands for one exchange in the chat it started from.
public enum BotDMThread {
    public static let prefix = "dm:"
    public static let cardPrefix = "dm:"

    /// The same id whichever of the two asks.
    public static func id(_ first: String, _ second: String) -> String {
        prefix + [first, second].sorted().joined(separator: "+")
    }

    public static func isThread(_ conversationID: String) -> Bool { conversationID.hasPrefix(prefix) }

    /// The two bots of a thread. Nil for anything else.
    public static func members(of conversationID: String) -> (first: String, second: String)? {
        guard isThread(conversationID) else { return nil }
        let parts = conversationID.dropFirst(prefix.count).components(separatedBy: "+")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// The other bot of a thread.
    public static func partner(of botID: String, in conversationID: String) -> String? {
        guard let pair = members(of: conversationID) else { return nil }
        if pair.first == botID { return pair.second }
        if pair.second == botID { return pair.first }
        return nil
    }

    /// `BotChatMessage.card` for an exchange: "dm:<exchange id>:<who was messaged>". The sender is the message's author.
    public static func card(exchangeID: String, targetID: String) -> String { "\(cardPrefix)\(exchangeID):\(targetID)" }

    public static func parseCard(_ card: String?) -> (exchangeID: String, targetID: String)? {
        guard let card, card.hasPrefix(cardPrefix) else { return nil }
        let parts = card.dropFirst(cardPrefix.count).components(separatedBy: ":")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// The chat file's name: a colon is awkward in a file name, and a bot id can't hold a "+".
    public static func fileName(forThread conversationID: String) -> String {
        conversationID.replacingOccurrences(of: ":", with: "-")
    }

    public static func thread(fromFileName name: String) -> String? {
        guard name.hasPrefix("dm-") else { return nil }
        let id = prefix + name.dropFirst("dm-".count)
        return members(of: id) == nil ? nil : id
    }
}

/// What may still be sent. An exchange (one bot asking another about one thing) is at most three round trips, and one message
/// from the owner sets off at most twelve private messages in all.
public struct BotDMBudget: Equatable, Sendable {
    public static let maximumRoundTrips = 3
    public static let maximumPerOwnerMessage = 12

    public enum Verdict: Equatable, Sendable { case send, roundTripCap, totalCap }

    public private(set) var sentSinceOwnerSpoke = 0
    public init() {}

    public mutating func ownerSpoke() { sentSinceOwnerSpoke = 0 }

    /// `roundTripsSoFar`: how many times this exchange has already gone there and back.
    public func verdict(roundTripsSoFar: Int) -> Verdict {
        if sentSinceOwnerSpoke >= Self.maximumPerOwnerMessage { return .totalCap }
        if roundTripsSoFar >= Self.maximumRoundTrips { return .roundTripCap }
        return .send
    }

    public mutating func noteSent() { sentSinceOwnerSpoke += 1 }

    /// Said plainly in the chat when a cap stops a message.
    public static func capLine(_ verdict: Verdict, sender: String, target: String) -> String? {
        switch verdict {
        case .send: return nil
        case .roundTripCap:
            return "\(sender) and \(target) have gone back and forth \(maximumRoundTrips) times on this, which is the limit for one exchange, so \(sender) didn't send another message."
        case .totalCap:
            return "The bots have sent \(maximumPerOwnerMessage) private messages since your last message, which is the limit, so \(sender)'s message to \(target) didn't go. Tell me if you want them to keep going."
        }
    }
}

/// What a card shows, from what's in the thread.
public enum BotDMCardText {
    public static func headline(sender: String, target: String) -> String { "\(sender) messaged \(target) privately" }

    public static func count(_ messages: Int) -> String { messages == 1 ? "1 message" : "\(messages) messages" }

    /// The first line of the newest message, without Markdown marks.
    public static func preview(_ text: String, limit: Int = 90) -> String {
        let cleaned = text.replacingOccurrences(of: "```", with: " ").replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#", with: "")
        let line = cleaned.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "\u{2026}" : line
    }

    /// Is the other bot still answering, as far as the thread can tell? `lastAuthorIsSender`: the newest message is the sender's, with
    /// nothing after it, not even a note that it was stopped. A message over eight minutes old got no answer: a turn is stopped at seven.
    public static func looksLive(lastAuthorIsSender: Bool, lastAt: Date, now: Date = Date()) -> Bool {
        lastAuthorIsSender && now.timeIntervalSince(lastAt) < 8 * 60
    }
}

// MARK: - @Name in group chats

public enum BotMentions {
    /// The ids of the bots @-named in `text`, in the order they're named, each once. Longest names win ("@Coder 2" isn't "@Coder").
    /// Code fences don't count, and "@Name" has to end at a word boundary.
    public static func ordered(in text: String, bots: [(id: String, name: String)]) -> [String] {
        let withoutCode = text.replacingOccurrences(of: "(?s)```.*?(```|$)", with: " ", options: .regularExpression)
        let lower = withoutCode.lowercased()
        var taken: [Range<String.Index>] = []
        var found: [(position: String.Index, id: String)] = []
        for bot in bots.sorted(by: { $0.name.count > $1.name.count }) {
            let needle = "@" + bot.name.lowercased()
            var searchFrom = lower.startIndex
            while let range = lower.range(of: needle, range: searchFrom..<lower.endIndex) {
                searchFrom = range.upperBound
                let endsWord = range.upperBound == lower.endIndex || !(lower[range.upperBound].isLetter || lower[range.upperBound].isNumber || lower[range.upperBound] == "-" || lower[range.upperBound] == "_")
                guard endsWord, !taken.contains(where: { $0.overlaps(range) }) else { continue }
                taken.append(range)
                if !found.contains(where: { $0.id == bot.id }) { found.append((range.lowerBound, bot.id)) }
            }
        }
        return found.sorted { $0.position < $1.position }.map(\.id)
    }

    /// Like `ordered`, but a name counts with or without the @: what a head means when it says "Backend first, then Frontend".
    /// Only the head's turns use this, so a member mentioning a name in passing doesn't hand on the turn.
    public static func named(in text: String, bots: [(id: String, name: String)]) -> [String] {
        let withoutCode = text.replacingOccurrences(of: "(?s)```.*?(```|$)", with: " ", options: .regularExpression)
        let lower = withoutCode.lowercased()
        func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "-" || character == "_" }
        var taken: [Range<String.Index>] = []
        var found: [(position: String.Index, id: String)] = []
        for bot in bots.sorted(by: { $0.name.count > $1.name.count }) {
            let needle = bot.name.lowercased()
            guard !needle.isEmpty else { continue }
            var searchFrom = lower.startIndex
            while let range = lower.range(of: needle, range: searchFrom..<lower.endIndex) {
                searchFrom = range.upperBound
                let startsWord = range.lowerBound == lower.startIndex || !isWordCharacter(lower[lower.index(before: range.lowerBound)])
                let endsWord = range.upperBound == lower.endIndex || !isWordCharacter(lower[range.upperBound])
                guard startsWord, endsWord, !taken.contains(where: { $0.overlaps(range) }) else { continue }
                taken.append(range)
                if !found.contains(where: { $0.id == bot.id }) { found.append((range.lowerBound, bot.id)) }
            }
        }
        return found.sorted { $0.position < $1.position }.map(\.id)
    }
}

// MARK: - Who speaks next in a group chat

/// Members take turns one at a time, in the order the head named them, each reading everything said so far; then the head writes
/// one wrap-up and it stops. A member can hand something on with @Name, which puts that bot next, as long as the cap on turns holds.
public struct GroupTurnPlan: Equatable, Sendable {
    public static let maximumTurns = 8
    /// A bot speaks twice at most in a round, so two members can't keep handing to each other.
    public static let maximumTurnsPerBot = 2

    public enum Step: Equatable, Sendable {
        /// This bot speaks next. `isWrapUp`: the head closing the round.
        case speak(botID: String, isWrapUp: Bool)
        /// The round's over.
        case finished
    }

    public let headID: String
    public private(set) var queue: [String]
    public private(set) var turnsTaken = 0
    public private(set) var spoke: [String: Int] = [:]
    public private(set) var isWrappingUp = false
    public private(set) var isFinished = false
    /// Someone other than the head has spoken in this round, so the head owes a wrap-up.
    public private(set) var needsWrapUp = false

    /// `first`: who was tagged, or the head when nobody was. A head who's tagged too reads it first.
    public init(headID: String, first: [String]) {
        self.headID = headID
        var seen = Set<String>()
        let unique = (first.isEmpty ? [headID] : first).filter { seen.insert($0).inserted }
        self.queue = unique.contains(headID) ? [headID] + unique.filter { $0 != headID } : unique
    }

    /// Who goes first.
    public mutating func start() -> Step { next() }

    /// A turn ended. `mentions`: the bots it named with @, in order (empty for a turn that failed). `canHandOut`: its words may
    /// bring others in. The wrap-up never can.
    public mutating func turnEnded(by botID: String, mentions: [String], canHandOut: Bool, others: [String]) -> Step {
        turnsTaken += 1
        spoke[botID, default: 0] += 1
        if botID != headID { needsWrapUp = true }
        if isWrappingUp {
            isFinished = true
            queue = []
            return .finished
        }
        if canHandOut {
            // The head has the wrap-up anyway, so naming the head brings nobody in.
            let wanted = mentions.filter { id in
                id != botID && id != headID && others.contains(id) && !queue.contains(id) && (spoke[id] ?? 0) < Self.maximumTurnsPerBot
            }
            if botID == headID {
                queue += wanted
            } else {
                // Handed on by a member: that bot goes next, then whoever was waiting.
                queue.insert(contentsOf: wanted, at: 0)
            }
        }
        return next()
    }

    /// Nobody else is to speak: the owner stopped it, or spoke again.
    public mutating func finish() {
        isFinished = true
        queue = []
    }

    private mutating func next() -> Step {
        if isFinished { return .finished }
        // Always room for the wrap-up at the cap: the round ends with one answer, not mid-air.
        if turnsTaken >= Self.maximumTurns - (needsWrapUp ? 1 : 0) { queue = [] }
        if !queue.isEmpty { return .speak(botID: queue.removeFirst(), isWrapUp: false) }
        if needsWrapUp {
            isWrappingUp = true
            return .speak(botID: headID, isWrapUp: true)
        }
        isFinished = true
        return .finished
    }
}

// MARK: - The prompts

public enum BotProtocol {
    /// The house style for every bot message.
    public static func houseStyle(owner: String) -> String {
        "How you write: talk to whoever you're answering. Keep it short, 1 to 4 sentences unless asked for depth. No name or heading at the start. " +
            "Refer to what the other person actually said. Never claim something happened that hasn't. When you're waiting on someone, say who and for what. " +
            "Don't talk about your tools, sessions or sandbox: say in plain words what you can and can't do. Talking to \(owner), say you. Talking about \(owner) to anyone else, say they, never he or she."
    }

    /// Who can be reached, by name with what they do, as a line of text.
    public static func reachableList(_ bots: [(name: String, description: String)]) -> String {
        bots.map { $0.description.isEmpty ? $0.name : "\($0.name) (\($0.description.prefix(70)))" }.joined(separator: "; ")
    }

    /// The one way to reach another bot, from any chat. Inside a group chat @Name also hands that bot the next turn there, and nowhere else.
    public static func reachHowTo(reachable: [(name: String, description: String)], owner: String) -> String {
        let how = "To message another bot, put a line [TELL: their exact name: what you need] in your reply, from any chat. It's private: they answer you, and you then carry on where you were and tell \(owner) what came of it. " +
            "\(owner) sees a small card and can open it. Only that line reaches them. @Name means something only inside a group chat, where it hands that bot the next turn. Just do it: don't explain to \(owner) how you reach them, and never ask \(owner) to pass a message on or add anyone to a group."
        return reachable.isEmpty ? how + " No other bots are on right now." : how + " Who you can reach: \(reachableList(reachable))."
    }

    /// In a group chat: @Name for this chat, [TELL:] for anything private.
    public static func groupChatHowTo(others: [(name: String, description: String)]) -> String {
        "In this group chat, @Name hands that bot the next turn here, so use it only to hand something on. For a private message to any bot, use a line [TELL: their exact name: what you need] instead. " +
            "The others here: \(reachableList(others))."
    }

    /// In a private thread.
    public static func privateThreadHowTo(partner: String) -> String {
        "This is a private thread between you and \(partner). Just write your answer: it goes back to \(partner) by itself. To ask a third bot first, put a line [TELL: their exact name: what you need]."
    }

    /// What a bot reads when another bot messages it. It holds the whole message and says who sent it and why.
    public static func privateMessagePrompt(from sender: String, senderRole: String?, message: String, ownerAsked: String?, earlier: [String], owner: String) -> String {
        var parts: [String] = []
        if !earlier.isEmpty {
            parts.append("Earlier in your private thread with \(sender):\n" + earlier.joined(separator: "\n"))
        }
        let who = senderRole.map { "\(sender) (\($0))" } ?? sender
        var head = "Private message from \(who)"
        if let ownerAsked = ownerAsked?.trimmingCharacters(in: .whitespacesAndNewlines), !ownerAsked.isEmpty {
            head += ", because \(owner) said: \"\(ownerAsked.count > 400 ? String(ownerAsked.prefix(399)) + "\u{2026}" : ownerAsked)\""
        }
        parts.append(head + ":\n\n" + message)
        parts.append("Answer \(sender) directly and fully, once. Your answer goes back to \(sender) by itself and they tell \(owner) what matters, so don't address \(owner), don't message \(sender), and don't ask them to confirm. " +
                     "If you can't do what's asked, say why and who could.")
        return parts.joined(separator: "\n\n")
    }

    /// What the sender reads when the answers are in.
    /// `reader`: who it tells: the owner, or the bot it's answering when this is inside a private thread.
    public static func repliesPrompt(_ replies: [(name: String, text: String)], notes: [String], lastRoundWith: [String], reader: String, mayMessage: Bool = true) -> String {
        var parts = replies.map { "\($0.name) answered you privately:\n\n\($0.text)" }
        parts += notes
        if !lastRoundWith.isEmpty {
            parts.append("That was your last message to \(lastRoundWith.joined(separator: " and ")) on this, so finish without them.")
        }
        parts.append("Carry on where you were and tell \(reader) what came of it, in your own words, using what they actually said. Only say what's new: don't repeat what you've already told \(reader) in this chat. " +
                     "Don't thank them or confirm with them. " + (mayMessage ? "Send another [TELL:] line only if you really need something more from them." : "Don't send any more [TELL:] lines for now: tell \(reader) where things stand."))
        return parts.joined(separator: "\n\n")
    }

    // MARK: Group turns

    /// The head reads the owner's message first.
    public static func headOpensNote(owner: String) -> String {
        "You lead this group. Read \(owner)'s message. If you can answer it yourself, answer. Otherwise hand the parts out with @Name, in the order they should answer: " +
            "they answer one at a time and each reads what the others said. Just say who answers what, without describing how the turns work. Once they've all answered you'll write one wrap-up, so don't write it now."
    }

    /// A member's turn.
    public static func memberTurnNote(name: String, headName: String) -> String {
        "It's your turn, \(name), and nobody else is writing. Read everything above first. Don't repeat a point already made: agree in a few words or add what's new. " +
            "Answer the part you were given. Use @Name only to hand something on; \(headName) wraps up after the last answer, so don't summarise for the group."
    }

    /// The head closes the round.
    public static func wrapUpNote(owner: String) -> String {
        "Everyone has answered. Read the round and write one wrap-up for \(owner): what they said that matters and what happens next. Don't @ anyone: this ends the round."
    }

    /// Saying plainly that a group member couldn't be waited for.
    public static func busyMemberLine(name: String) -> String { "\(name) is busy with something else, so it sat this one out." }

    // MARK: Bots' other how-tos

    /// Shown in the chat as a card with option tiles (BotCallCard).
    public static let askingStyle =
        "When the user really has to choose between options, end your message with one line in exactly this form, " +
        "and don't also list the options in your words: [CHOOSE: the question | First option: a few words on it | Second option: a few words on it]. " +
        "Two to four options, the one you'd pick first. Most messages need none of this."

    /// Bots' screen jobs run on the Mac Studio's hidden screens, through Clicky.
    /// How a bot gets a PDF made: it writes the document, Theo renders it.
    public static let pdfHowTo = "For a PDF, write the document as Markdown or HTML in your memory folder, then put a line [PDF: file name] in your reply: " +
        "Theo makes the PDF next to that file and puts it in the chat. Say the PDF is made only once Theo's line says so."

    public static let screenHowTo =
        "Addy's Mac Studio has hidden screens set aside for you, and Addy watches them in the Studio panel. For a simple job in an " +
        "ordinary app (Stickies, Calculator, Clock, Notes and the like) put a line [SCREEN: what to do, in plain words] in your reply. " +
        "Clicky does it on a free tile without touching Addy's own monitors, then tells you what happened. Say a job happened only if " +
        "that report says so. Browsers, terminals, mail and chat apps aren't allowed there. " +
        "To have Clicky's research agents look something up in Addy's browser, put a line [RESEARCH: the question]; you'll hear the brief. " +
        "If Addy asks for a bot to get a screen, put a line [GIVE SCREEN: bot name: screen name, own, shared or none]; Addy confirms it on a card. " +
        "Writing or changing code doesn't go through this: use a ```prompt block."

    /// How a bot sets up a routine. Theo does the scheduling, so no scheduling tool or skill is needed.
    public static let routineHowTo =
        "Routines: when Addy asks for something on a schedule (\"every weekday at 8, …\"), don't use any scheduling, " +
        "cron or schedule tool or skill: Theo runs routines for you. Say what you'll do and when, then add a ```routine " +
        "block with JSON {\"name\": short name, \"when\": \"daily 08:00\" | \"weekdays 08:30\" | \"weekly mon 09:00\" | " +
        "\"hourly\" | \"every 30 minutes\", \"do\": the instruction you'll be given at each run}. Theo then runs it on " +
        "time, and Addy can pause, run or delete it."

    /// How any bot starts a coding run. Bots don't edit code themselves: a harness does it in its own branch.
    public static func codingHowTo(harnessLabel: String) -> String {
        "Coding: when the owner asks to build, fix or change code, don't edit files yourself. Plan it in a sentence or two, then write: a line " +
            "\"Project: <short name>\", a line \"Repo: <path>\" when they named an existing folder (\"New folder: <name>\" for a new one), and the full instructions for the coding agent " +
            "in a ```prompt fenced block. Theo makes the folder and starts the agent inside it, so never tell the agent to create or go to a folder. Theo then runs it on \(harnessLabel): an existing git repo gets its own branch and " +
            "worktree, and the result comes back with the changes, tests and a draft pull request. The run goes on the Mac your \"where you are\" note says; if the owner names their other Mac, add a line \"Mac: <that Mac>\". " +
            "To carry on an earlier harness chat instead of starting a new one, add a line \"Continue: <chat id or title>\". For a change to the run you already started, " +
            "put it in a ```followup fenced block instead. Writing a block doesn't start anything by itself: never say a run has started or been passed on until the list of runs shows it, or Theo's own line in the chat says so."
    }

    /// One team a bot is on, for its reporting lines.
    public struct TeamFacts: Equatable, Sendable {
        public var name: String
        public var purpose: String?
        public var mates: [String]
        public var isManager: Bool
        public var managerName: String?
        public init(name: String, purpose: String? = nil, mates: [String] = [], isManager: Bool = false, managerName: String? = nil) {
            self.name = name
            self.purpose = purpose
            self.mates = mates
            self.isManager = isManager
            self.managerName = managerName
        }
    }

    /// Who a bot reports to. Reports and messages go by [TELL:]; @Name is only for handing over inside a group chat.
    public static func reportingLine(_ team: TeamFacts, ceoName: String) -> String {
        var line = "Your team: \(team.name)" + (team.purpose.map { " (\($0))" } ?? "") + (team.mates.isEmpty ? "" : ", with \(team.mates.joined(separator: ", "))") + ". "
        if team.isManager {
            line += "You are its manager: they send you their reports and messages. Give them work with a [TELL:] line, roll their reports up, and report to \(ceoName), the CEO."
        } else if let manager = team.managerName {
            line += "\(manager) is your manager: send your reports and messages to \(manager) with a [TELL:] line, not to \(ceoName). \(manager) passes on what matters."
        } else {
            line += "It has no manager, so you report straight to \(ceoName), the CEO, with a [TELL:] line when something is worth knowing."
        }
        return line
    }

    // MARK: A group chat's discussion, step by step

    public static func planNote(hasOthers: Bool, owner: String = "Addy") -> String {
        hasOthers
            ? "Lay out your plan for the group in a few lines, so they can pick it apart. No ```prompt block yet, and don't say anything has been sent or started."
            : mergeNote
    }

    public static let critiqueNote = "Give a real critique of the plan above from your own role: what's missing, what's likely to go wrong, what you'd change. Be specific and disagree where you do. Don't write the final prompt."

    public static let mergeNote = "Now write the outcome. Say briefly what each person raised and what changed because of it, then a line \"Project: <short name>\" and the complete final instructions in a ```prompt block. You don't start or send anything yourself: Theo starts the run on the harness and model Addy chose as soon as you've written it, and you'll see it in the list of runs. Theo makes the folder and starts the agent inside it, so the instructions must never tell the agent to create or go to a folder."

    // MARK: What a group member reads

    /// Everything since the bot last spoke, with names, and how to behave.
    public static func groupTurnPrompt(botName: String, groupName: String, owner: String, others: [(name: String, description: String)], firstTimeIntro: [String],
                                       transcript: [(speaker: String, text: String)], includesScreenHowTo: Bool, turnNote: String) -> String {
        var parts = firstTimeIntro
        parts.append(groupChatHowTo(others: others))
        if includesScreenHowTo { parts.append(screenHowTo) }
        let lines = transcript.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n\n")
        parts.append("New in the \"\(groupName)\" group chat since you last spoke:\n\n\(lines)")
        parts.append("(\(turnNote))")
        parts.append("Reply as \(botName), with only your chat message.")
        return parts.joined(separator: "\n\n")
    }

    /// What a bot reads of a group chat: everything since the owner last spoke, always, and as much from before that as fits. A bot new to a
    /// chat once got 94,000 characters to answer one line.
    public static func trimmedTranscript<Message>(_ messages: [Message], isOwner: (Message) -> Bool, length: (Message) -> Int, maximumCharacters: Int = 24_000) -> [Message] {
        let lastOwner = messages.lastIndex(where: isOwner) ?? messages.startIndex
        var kept = Array(messages[lastOwner...])
        var used = kept.reduce(0) { $0 + length($1) }
        for message in messages[..<lastOwner].reversed() {
            used += length(message)
            if used > maximumCharacters { break }
            kept.insert(message, at: 0)
        }
        return kept
    }

    // MARK: Word counts

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

// MARK: - What an engine session hasn't seen

/// Each Mac has its own engine session for a chat, and the chat also goes on from the other Mac. This says what a session still has to be told.
/// Theo asking a group chat, or a turn run on the other Mac, on the owner's behalf. One message of the owner's starts that chat's limits over
/// once, however many times it's asked. Never starting them over would leave a chat the owner only reaches through Theo with no messages left.
public struct OwnerMessageMark: Equatable, Sendable {
    private var lastSeen: [String: String] = [:]

    public init() {}

    /// True the first time this chat hears of that message of the owner's.
    public mutating func isNew(room: String, message: String) -> Bool {
        guard lastSeen[room] != message else { return false }
        lastSeen[room] = message
        return true
    }
}

public enum BotCatchUp {
    public static let maximumMessages = 20
    public static let maximumCharactersEach = 1500
    public static let maximumCharactersTotal = 12_000
    /// In `heard`: nothing here has been seen yet. A session may still hold earlier words, but none of what's here is certain.
    public static let fromTheStart = ""

    /// The messages after the newest one this session has heard. With no session at all: the chat's latest, if another Mac could have written it.
    /// `messages`: all of them, since what it heard last can be a card or a note. `counts`: the ones that are words to read.
    public static func unheard<Message>(messages: [Message], id: (Message) -> String, heard: String?, hasSession: Bool, isLinked: Bool, counts: (Message) -> Bool = { _ in true }) -> [Message] {
        guard hasSession else { return isLinked ? Array(messages.filter(counts).suffix(6)) : [] }
        if heard == fromTheStart { return Array(messages.filter(counts).suffix(maximumMessages)) }
        guard let heard, let index = messages.lastIndex(where: { id($0) == heard }) else { return [] }
        return Array(messages[messages.index(after: index)...].filter(counts).suffix(maximumMessages))
    }

    /// Lines to read: each cut to a size, and the newest kept when there's too much.
    public static func lines(_ said: [(who: String, text: String)]) -> [String] {
        var kept: [String] = []
        var used = 0
        for line in said.suffix(maximumMessages).reversed() {
            let text = "\(line.who): \(line.text.prefix(maximumCharactersEach))"
            used += text.count
            if used > maximumCharactersTotal { break }
            kept.insert(text, at: 0)
        }
        return kept
    }

    /// After messages arrive from the other Mac, possibly in the middle of what's here: what a session has heard moves back so none of them is missed.
    public static func heardAfterMerge(heard: String?, merged: [String], arrived: Set<String>) -> String? {
        guard let heard, let heardAt = merged.lastIndex(of: heard), let firstArrived = merged.firstIndex(where: arrived.contains), firstArrived < heardAt else { return heard }
        return firstArrived == 0 ? fromTheStart : merged[firstArrived - 1]
    }

    /// The same for a group chat's count of how many messages a bot has read.
    public static func seenAfterMerge(seen: Int, merged: [String], arrived: Set<String>) -> Int {
        guard let firstArrived = merged.firstIndex(where: arrived.contains) else { return seen }
        return min(seen, firstArrived)
    }
}

// MARK: - Where a bot is, and who it is

/// The facts behind the "where you are" block.
public struct BotPlaceFacts: Equatable, Sendable {
    public var owner: String
    /// This Mac's short name, like "MacBook Air".
    public var thisMac: String
    /// The Mac the owner is typing on. Nil or the same as `thisMac`: this one.
    public var ownerMac: String?
    /// Why this turn runs here when the owner is on the other Mac.
    public var whyHere: String?
    /// Where folders and coding runs from this chat go (normally `thisMac`).
    public var codingMac: String
    /// Project folder names there, most recent first.
    public var projects: [String]
    /// Where those folders are, in words an agent's shell understands.
    public var projectsFolder: String
    /// "Claude Code (signed in)", "T3 Code 0.1.7", …
    public var ready: [String]
    public var otherMac: String?
    public var otherMacConnected: Bool
    /// The other Mac has the hidden screens and the research browser.
    public var otherMacHasScreens: Bool
    public var thisMacHasScreens: Bool

    public init(owner: String, thisMac: String, ownerMac: String? = nil, whyHere: String? = nil, codingMac: String? = nil, projects: [String] = [], projectsFolder: String = "~/Projects", ready: [String] = [],
                otherMac: String? = nil, otherMacConnected: Bool = false, otherMacHasScreens: Bool = false, thisMacHasScreens: Bool = false) {
        self.projectsFolder = projectsFolder
        self.owner = owner
        self.thisMac = thisMac
        self.ownerMac = ownerMac
        self.whyHere = whyHere
        self.codingMac = codingMac ?? thisMac
        self.projects = projects
        self.ready = ready
        self.otherMac = otherMac
        self.otherMacConnected = otherMacConnected
        self.otherMacHasScreens = otherMacHasScreens
        self.thisMacHasScreens = thisMacHasScreens
    }
}

/// The facts behind the "who you are" block.
public struct BotIdentityFacts: Equatable, Sendable {
    public var name: String
    public var owner: String
    /// One line on what it's for.
    public var job: String
    public var isCEO: Bool
    public var teams: [String]
    public var managerName: String?
    public var managesTeams: [String]
    public var ceoName: String?
    public var apps: [String]
    /// Clicky's helpers get their jobs from Clicky: no chat-style purpose talk.
    public var canStartCoding: Bool
    public var canMessageOthers: Bool
    public var canSetRoutines: Bool
    /// Its memory file, said every turn: a session that began before the file moved still remembers the old place.
    public var memoryPath: String?

    public init(name: String, owner: String, job: String, isCEO: Bool = false, teams: [String] = [], managerName: String? = nil, managesTeams: [String] = [],
                ceoName: String? = nil, apps: [String] = [], canStartCoding: Bool = true, canMessageOthers: Bool = true, canSetRoutines: Bool = true, memoryPath: String? = nil) {
        self.name = name
        self.owner = owner
        self.job = job
        self.isCEO = isCEO
        self.teams = teams
        self.managerName = managerName
        self.managesTeams = managesTeams
        self.ceoName = ceoName
        self.apps = apps
        self.canStartCoding = canStartCoding
        self.canMessageOthers = canMessageOthers
        self.canSetRoutines = canSetRoutines
        self.memoryPath = memoryPath
    }
}

public enum BotAwareness {
    public static let maximumProjectsShown = 12

    /// Short, refreshed every turn, since a resumed engine session keeps old context.
    public static func whereYouAre(_ facts: BotPlaceFacts) -> String {
        var lines: [String] = []
        let ownerMac = facts.ownerMac ?? facts.thisMac
        if ownerMac == facts.thisMac {
            lines.append("Where you are now: you're running on \(facts.owner)'s \(facts.thisMac), the Mac \(facts.owner) is using.")
        } else {
            lines.append("Where you are now: you're running on \(facts.owner)'s \(facts.thisMac), while \(facts.owner) is typing on their \(ownerMac)" + (facts.whyHere.map { " (\($0))" } ?? "") + ".")
        }
        let shown = facts.projects.prefix(maximumProjectsShown)
        let more = facts.projects.count - shown.count
        let names = shown.isEmpty ? "none yet" : shown.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
        lines.append("Folders and coding runs from this chat are on the \(facts.codingMac) (\(facts.projectsFolder): \(names)).")
        if !facts.ready.isEmpty { lines.append("Ready on the \(facts.thisMac): \(facts.ready.joined(separator: ", ")).") }
        if let other = facts.otherMac {
            var line = "\(facts.owner)'s other Mac, the \(other), is \(facts.otherMacConnected ? "connected" : "not connected right now")"
            if facts.otherMacHasScreens { line += "; it has the hidden screens for [SCREEN:] jobs and the research browser" }
            lines.append(line + ".")
        } else {
            lines.append("There's no other Mac linked.")
        }
        if facts.thisMacHasScreens { lines.append("The hidden screens for [SCREEN:] jobs and the research browser are on this Mac.") }
        lines.append("Never offer a folder on one Mac and run on the other.")
        return lines.joined(separator: " ")
    }

    /// Identity and purpose, built from the bot's own settings.
    public static func whoYouAre(_ facts: BotIdentityFacts) -> String {
        var lines: [String] = []
        let job = facts.job.trimmingCharacters(in: .whitespacesAndNewlines)
        var opening = "Who you are: you're \(facts.name), \(facts.owner)'s " + (facts.isCEO ? "CEO bot" : "bot")
        if !job.isEmpty { opening += ". Your job: \(job.hasSuffix(".") ? String(job.dropLast()) : job)" }
        lines.append(opening + ".")
        for team in facts.managesTeams { lines.append("You manage the \(team) team.") }
        if let team = facts.teams.first(where: { !facts.managesTeams.contains($0) }) {
            if let manager = facts.managerName {
                lines.append("You're on the \(team) team; your manager is \(manager).")
            } else if let ceo = facts.ceoName, !facts.isCEO {
                lines.append("You're on the \(team) team and report to \(ceo), the CEO.")
            } else {
                lines.append("You're on the \(team) team.")
            }
        }
        var can = ["chat"]
        if facts.canMessageOthers { can.append("message other bots privately with [TELL:]") }
        if facts.canStartCoding { can.append("hand coding to a harness with a ```prompt block") }
        if facts.canSetRoutines { can.append("set routines") }
        if !facts.apps.isEmpty { can.append("use \(facts.apps.joined(separator: ", "))") }
        lines.append("You can: \(can.joined(separator: ", ")).")
        if let memory = facts.memoryPath { lines.append("Your memory file is \(memory).") }
        if facts.canMessageOthers { lines.append("When a request is outside your job, say who on the team fits and offer to message them.") }
        lines.append("Work out what \(facts.owner) actually wants, not just the literal words; if the next step is obvious and safe, take it; ask one short question only when you really can't tell.")
        return lines.joined(separator: " ")
    }
}
