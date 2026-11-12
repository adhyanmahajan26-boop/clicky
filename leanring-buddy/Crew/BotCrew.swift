//
//  BotCrew.swift
//  leanring-buddy
//
//  Which Pixel face a bot shows, from its real state, and the one-line status under its name. The choice itself is
//  ClickyCore's `PixelStatePriority` (first match wins); this gathers the facts. A bot's last failure is kept on the bot
//  (`NativeBot.lastFailure`) until the owner opens its chat, retries, or gives it new work, so it survives a relaunch.
//

import AppKit
import ClickyCore
import Combine
import Foundation

extension BotsStore {
    private static let clickyLookKey = "theo.clicky.look"

    /// Clicky is a stand-in rather than a saved bot, so its look keeps to itself.
    static var savedClickyLook: CrewLook? {
        guard let data = UserDefaults.standard.data(forKey: clickyLookKey) else { return nil }
        return try? JSONDecoder().decode(CrewLook.self, from: data)
    }

    /// Saves a look from Make your bot.
    func setLook(_ look: CrewLook, for botID: String) {
        if botID == Self.clickyID {
            UserDefaults.standard.set(try? JSONEncoder().encode(look), forKey: Self.clickyLookKey)
            objectWillChange.send()
        } else if var bot = bot(botID) {
            bot.look = look
            save(bot)
        }
    }

    /// How long a finished bot stays pleased with itself.
    static let doneSeconds: TimeInterval = 120
    /// Quiet this long and a bot dozes off.
    static let dozeSeconds: TimeInterval = 600

    /// The room a bot's runs report to is its own chat.
    func liveRun(of botID: String) -> T3Run? {
        t3Runs.last { ($0.room == botID) && ($0.phase == "running" || $0.phase == "waiting" || $0.phase == "reporting") }
    }

    /// A question from this bot that's still waiting for the owner's answer.
    func openCall(of botID: String) -> BotCallPrompt? {
        guard let last = conversation(botID).messages.last, last.author == botID, last.text.contains("[CHOOSE:") else { return nil }
        return BotCallPrompt.parse(last.text)
    }

    // MARK: Failures

    /// The bot's last failure the owner hasn't seen yet.
    func lastFailure(of botID: String) -> BotFailureRecord? {
        bot(botID)?.lastFailure
    }

    /// A run or reply of this bot ended in failure. Plain words only; raw output stays behind See details.
    func recordFailure(of botID: String, reason: String, step: String? = nil, runID: String? = nil) {
        guard botID != Self.clickyID, var bot = bot(botID) else { return }
        // A signed-out coding agent is something the owner does, not a failure: its card asks for the sign-in (needs you).
        let signIn = BotFailureWords.signedOutHarness(in: reason)
        // A failure that happens in the chat the owner is looking at has been seen.
        let watching = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.title == "Theo" }
        guard FailureTriage.marksUnseen(botID: botID, viewing: viewing, isWatching: watching, isSignIn: signIn != nil) else {
            if let signIn, viewing != botID || !watching { BotAlerts.shared.needs(bot: bot, line: "Sign in to \(signIn.label)") }
            return
        }
        bot.lastFailure = BotFailureRecord(reason: reason, at: Date(), step: step, runID: runID)
        save(bot)
        BotAlerts.shared.failed(bot: bot, reason: reason)
    }

    /// Opened, retried, or given new work: the red face goes.
    func clearFailure(of botID: String) {
        guard var bot = bot(botID), bot.lastFailure != nil else { return }
        bot.lastFailure = nil
        save(bot)
    }

    /// Bots that are red right now.
    var failedBots: [NativeBot] { bots.filter { pixelState(of: $0).state == .failed } }
    /// Bots waiting on the owner right now.
    var botsNeedingYou: [NativeBot] { bots.filter { pixelState(of: $0).state == .needs } }

    /// The coding agent this bot runs on, when its last reply failed because that agent is signed out and it still is.
    func signedOutEngine(of bot: NativeBot) -> HarnessInfo? {
        guard let last = conversation(bot.id).messages.last(where: { $0.author == bot.id }), last.text.hasPrefix("Couldn't reply: "),
              let harness = BotFailureWords.signedOutHarness(in: last.text) else { return nil }
        return HarnessCenter.shared.status(for: harness.id).loggedIn == true ? nil : harness
    }

    // MARK: Which face

    /// What's true of this bot, for `PixelStatePriority`.
    func pixelFacts(of passed: NativeBot, state: BotAvatarState = .idle) -> PixelStateFacts {
        // A view can hold a copy from before a failure was recorded or cleared: the saved one is the truth.
        let bot = self.bot(passed.id) ?? passed
        var facts = PixelStateFacts(isOn: bot.isOn)
        if bot.id == Self.clickyID {
            let voice = CompanionManager.current?.voiceState
            facts.isTyping = state == .typing || voice == .responding
            facts.isListening = voice == .listening
            facts.isWorking = isClickyBusy && !(replying[Self.clickyID]?.isEmpty ?? true)
            facts.isThinking = state == .thinking || isClickyBusy || voice == .processing
            facts.isAwake = true
            return facts
        }
        let run = liveRun(of: bot.id)
        facts.isWaitingOnOwner = run?.phase == "waiting" || openCall(of: bot.id) != nil
            || (BrowserResearcher.shared.needsOwner && bot.id == teamBot(.researcher)?.id)
            || ConnectorHealth.shared.blockingConnector(of: bot.id) != nil
            || signedOutEngine(of: bot) != nil
        facts.hasUnseenFailure = bot.lastFailure != nil
        facts.isTyping = state == .typing
        if bot.primary, let call = TheoCallController.session, TheoCallController.isActive {
            facts.isListening = call.state == .listening || call.state == .userSpeaking
            facts.isTyping = facts.isTyping || call.state == .speaking
        }
        let streamed = !(BotLiveText.shared.text[bot.id] ?? "").isEmpty
        facts.isWorking = run != nil || (replying[bot.id] != nil && streamed)
        facts.isThinking = state == .thinking || (replying[bot.id] != nil && !streamed)
        // A reply that couldn't happen isn't a result.
        let last = conversation(bot.id).messages.last(where: { $0.author == bot.id && !$0.text.hasPrefix("Couldn't reply: ") })
        let age = last.map { Date().timeIntervalSince($0.at) } ?? .infinity
        // A reply that said an app wasn't answering didn't finish anything.
        facts.finishedRecently = (age < Self.doneSeconds || ((unread[bot.id] ?? 0) > 0 && last != nil)) && ConnectorHealth.shared.failedConnector(of: bot.id) == nil
        facts.isAwake = bot.primary || age < Self.dozeSeconds
        return facts
    }

    /// The face to show, and when it changes on its own (done fades to ready, ready dozes off).
    func pixelState(of bot: NativeBot, state: BotAvatarState = .idle) -> (state: PixelState, until: (date: Date, then: PixelState)?) {
        // A bot being previewed in a sheet, not on the team yet.
        guard bot.id == Self.clickyID || bots.contains(where: { $0.id == bot.id }) else { return (.awake, nil) }
        let facts = pixelFacts(of: bot, state: state)
        let shown = PixelStatePriority.state(for: facts)
        guard shown == .done || shown == .awake, bot.id != Self.clickyID,
              let last = conversation(bot.id).messages.last(where: { $0.author == bot.id }), (unread[bot.id] ?? 0) == 0 else { return (shown, nil) }
        if shown == .done { return (shown, (last.at.addingTimeInterval(Self.doneSeconds), .awake)) }
        if !bot.primary { return (shown, (last.at.addingTimeInterval(Self.dozeSeconds), .idle)) }
        return (shown, nil)
    }

    /// "Reading 6 sources", "Approved #41 · 2m", "Failed · GitHub sign-in expired": the line under a bot's name.
    func liveStatus(of passed: NativeBot) -> String {
        let bot = self.bot(passed.id) ?? passed
        guard bot.isOn else { return "Off" }
        if bot.id == Self.clickyID, isClickyBusy { return "Working" }
        if let run = liveRun(of: bot.id) {
            if run.phase == "waiting" { return "Needs you · \(run.title)" }
            let doing = Self.firstLine(run.activity ?? "")
            return doing.isEmpty ? run.title : doing
        }
        if let call = openCall(of: bot.id) { return "Needs you · \(call.question)" }
        if bot.id == teamBot(.researcher)?.id, let check = BrowserResearcher.shared.checks.values.first { return "Needs you · \(check.host)" }
        if let connector = ConnectorHealth.shared.blockingConnector(of: bot.id) { return "Needs you · Sign in to \(connector.name)" }
        if let harness = signedOutEngine(of: bot) { return "Needs you · Sign in to \(harness.label)" }
        if let failure = bot.lastFailure { return "Failed · \(failure.firstSentence)" }
        if replying[bot.id] != nil {
            let live = BotLiveHeadline.shared.line[bot.id] ?? ""
            // Answering another bot privately: who, not what.
            if let room = replyingIn[bot.id], let partner = BotDMThread.partner(of: bot.id, in: room).flatMap({ self.bot($0) }) { return "Answering \(partner.name) privately" }
            return live.isEmpty ? "Thinking…" : live
        }
        // An old message can be nothing but a tag, from before those were taken out as they arrive.
        guard let last = conversation(bot.id).messages.last(where: { $0.author == bot.id && !Self.firstLine($0.text).isEmpty && !$0.text.hasPrefix("Couldn't reply: ") }) else {
            return bot.description.isEmpty ? "Ready" : bot.description
        }
        return Self.firstLine(last.text) + " · " + Self.shortAge(since: last.at)
    }

    /// Since when the bot has been in its current state, for the time on the right of its row ("4m", "1:42").
    func stateSince(of passed: NativeBot) -> Date? {
        let bot = self.bot(passed.id) ?? passed
        if let run = liveRun(of: bot.id) { return run.startedAt }
        if let failure = bot.lastFailure { return failure.at }
        if let block = ConnectorHealth.shared.block(of: bot.id) { return block.at }
        if openCall(of: bot.id) != nil { return conversation(bot.id).messages.last?.at }
        return nil
    }

    /// The bots working right now, out of everyone but the CEO.
    var workingCount: Int { bots.filter { !$0.primary && pixelState(of: $0).state.lane == .working }.count }

    static func firstLine(_ text: String) -> String {
        // A question's tag isn't words anyone should read.
        var words = text.contains("[CHOOSE:") ? (BotCallPrompt.parse(text)?.remainingText ?? text) : text
        // Nor are orders, which an old message can still hold.
        if words.contains("[SCREEN") || words.contains("[CLICKY") || words.contains("[TELL") {
            words = ClickyOrder.extract(from: BotScreenOrder.extract(from: words).text).text
        }
        // Only the start is looked at: this runs on every streamed chunk, and a reply can be very long.
        let line = words.prefix(2_000).split(maxSplits: 1, whereSeparator: \.isNewline).first.map { String($0.prefix(300)) } ?? ""
        return line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "just now", "2m ago".
    static func ago(_ date: Date) -> String {
        let age = shortAge(since: date)
        return age == "now" ? "just now" : age + " ago"
    }

    /// "now", "2m", "3h", "4d".
    static func shortAge(since date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}
