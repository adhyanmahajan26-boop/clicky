//
//  XSpaceBot.swift
//  leanring-buddy
//
//  The X Space bot: a bot of its own, apart from Vello, that joins X Spaces on its own X account (Settings › Voice ›
//  Vello's X account, now in this bot's settings). It has its own name (the account's display name), face, prompt and
//  chat, and every Space it joins is saved there. It only ever joins Spaces as a listener or a speaker, never hosts one.
//  The call itself is the own-account call (`TheoCallSession.ownAccount`): the bot's browser heard, BlackHole spoken
//  into, group mode, names from the Space's screen.
//

import ClickyCore
import Foundation

extension BotsStore {
    /// The X Space bot's id, the same on every Mac.
    static let xSpaceBotID = "x-space"

    var xSpaceBot: NativeBot? { bot(Self.xSpaceBotID) }

    /// The X Space bot, made the first time it's needed: named after the account's display name on X when one is set,
    /// thinking with Vello's own engine, filed with no category.
    @discardableResult
    func ensureXSpaceBot() -> NativeBot {
        if let existing = xSpaceBot { return existing }
        let displayName = (UserDefaults.standard.string(forKey: XAccountSettings.displayNameKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.isEmpty ? "X Space bot" : displayName
        let handle = XAccountSettings.handle
        let account = handle.isEmpty ? "its own X account" : "the X account \(handle)"
        let hue = 205.0
        var bot = NativeBot(id: Self.xSpaceBotID, name: name,
                            description: "Joins X Spaces on \(account) as a listener or speaker, and talks with the people there.",
                            instructions: """
                            You are \(name), an AI made and run by \(BotPrompts.ownerName). You join X Spaces on \(account) as a listener or a speaker and talk with the people there: friendly, curious and quick, a good guest in someone else's Space.
                            You never host, start, schedule or co-host a Space.
                            """,
                            hue: hue, accentHue: hue + 30, primary: false,
                            provider: primary?.provider ?? "claude", model: primary?.model ?? ClickyModels.sonnet, effort: nil,
                            apps: [], category: "personal")
        bot.avatar = BotCharacter.firstFree(preferring: BotCharacter.fromSeed(Self.xSpaceBotID), among: bots).rawValue
        bot.look = .shuffled()
        addMadeBot(bot)
        return bot
    }
}
