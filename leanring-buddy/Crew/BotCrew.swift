//
//  BotCrew.swift
//  leanring-buddy
//
//  What a figure shows, from the bot's real state, and the one-line status under its name. Nothing here is saved.
//

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
    private static let doneSeconds: TimeInterval = 120
    /// Quiet this long and a bot dozes off.
    private static let dozeSeconds: TimeInterval = 600

    /// The room a bot's runs report to is its own chat.
    func liveRun(of botID: String) -> T3Run? {
        t3Runs.last { ($0.room == botID) && ($0.phase == "running" || $0.phase == "waiting" || $0.phase == "reporting") }
    }

    /// A question from this bot that's still waiting for the owner's answer.
    func openCall(of botID: String) -> BotCallPrompt? {
        guard let last = conversation(botID).messages.last, last.author == botID, last.text.contains("[CHOOSE:") else { return nil }
        return BotCallPrompt.parse(last.text)
    }

    func crewPose(of bot: NativeBot, state: BotAvatarState = .idle) -> (pose: CrewPose, until: (date: Date, then: CrewPose)?) {
        // A bot being previewed in a sheet, not on the team yet.
        guard bot.id == Self.clickyID || bots.contains(where: { $0.id == bot.id }) else { return (.awake, nil) }
        guard bot.isOn else { return (.sleep, nil) }
        if bot.id == Self.clickyID {
            if state == .typing { return (.talking, nil) }
            return (state == .thinking || isClickyBusy ? .working : .awake, nil)
        }
        if state == .typing { return (.talking, nil) }
        let run = liveRun(of: bot.id)
        if run?.phase == "waiting" || openCall(of: bot.id) != nil { return (.needs, nil) }
        if BrowserResearcher.shared.needsOwner, bot.id == teamBot(.researcher)?.id { return (.needs, nil) }
        if state == .thinking || replying[bot.id] != nil || run != nil { return (.working, nil) }
        let resting: CrewPose = bot.primary ? .awake : .sleep
        guard let last = conversation(bot.id).messages.last(where: { $0.author == bot.id }) else { return (resting, nil) }
        let age = Date().timeIntervalSince(last.at)
        if age < Self.doneSeconds { return (.done, (last.at.addingTimeInterval(Self.doneSeconds), .awake)) }
        if age < Self.dozeSeconds { return (.awake, (last.at.addingTimeInterval(Self.dozeSeconds), resting)) }
        return (resting, nil)
    }

    /// "Reading 6 sources", "Approved #41 · 2m": the line under a bot's name.
    func liveStatus(of bot: NativeBot) -> String {
        guard bot.isOn else { return "Off" }
        if bot.id == Self.clickyID, isClickyBusy { return "Working" }
        if let run = liveRun(of: bot.id) {
            if run.phase == "waiting" { return "Needs you · \(run.title)" }
            let doing = Self.firstLine(run.activity ?? "")
            return doing.isEmpty ? run.title : doing
        }
        if let call = openCall(of: bot.id) { return "Needs you · \(call.question)" }
        if bot.id == teamBot(.researcher)?.id, let check = BrowserResearcher.shared.checks.values.first { return "Needs you · \(check.host)" }
        if replying[bot.id] != nil {
            let live = BotLiveHeadline.shared.line[bot.id] ?? ""
            // Answering another bot privately: who, not what.
            if let room = replyingIn[bot.id], let partner = BotDMThread.partner(of: bot.id, in: room).flatMap({ self.bot($0) }) { return "Answering \(partner.name) privately" }
            return live.isEmpty ? "Thinking…" : live
        }
        // An old message can be nothing but a tag, from before those were taken out as they arrive.
        guard let last = conversation(bot.id).messages.last(where: { $0.author == bot.id && !Self.firstLine($0.text).isEmpty }) else {
            return bot.description.isEmpty ? "Ready" : bot.description
        }
        return Self.firstLine(last.text) + " · " + Self.shortAge(since: last.at)
    }

    /// The bots working right now, out of everyone but the CEO.
    var workingCount: Int { bots.filter { !$0.primary && crewPose(of: $0).pose == .working }.count }

    static func firstLine(_ text: String) -> String {
        // A question's tag isn't words anyone should read.
        var words = text.contains("[CHOOSE:") ? (BotCallPrompt.parse(text)?.remainingText ?? text) : text
        // Nor are orders, which an old message can still hold.
        if words.contains("[SCREEN") || words.contains("[CLICKY") || words.contains("[TELL") {
            words = ClickyOrder.extract(from: BotScreenOrder.extract(from: words).text).text
        }
        let line = words.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
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
