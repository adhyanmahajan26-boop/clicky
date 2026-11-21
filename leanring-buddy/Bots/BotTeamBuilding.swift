//
//  BotTeamBuilding.swift
//  leanring-buddy
//
//  The CEO makes new bots and categories when the owner asks for them in chat. The CEO writes a ```team block
//  (ClickyCore `TeamBuildOrder`, how-to in `BotProtocol.teamBuildHowTo`); this makes what it asks for, the same way the
//  New bot sheet and the New category row do, and says what it made in the chat.
//

import ClickyCore
import Foundation

extension BotsStore {
    /// Who may make bots and categories from chat: the CEO, and Vello's own bot when another bot was made CEO.
    func mayBuildTeam(_ bot: NativeBot) -> Bool {
        bot.owner == nil && (bot.primary || bot.id == BotsRootView.theoID)
    }

    /// Carries out a ```team block from `maker`'s answer in `conversationID`. Only the owner's own words asking for new
    /// bots or categories let it through; anything else is said in the chat and dropped, as a routine block is.
    func buildTeamFromChat(_ order: TeamBuildOrder, maker: NativeBot, conversationID: String, fromOwner: Bool) {
        guard fromOwner, mayBuildTeam(maker),
              let ownerWords = ownerWordsBehindTurn(in: conversationID), TeamBuildIntent.ownerAsked(ownerWords) else {
            post(BotChatMessage(author: Self.noteAuthor,
                                text: "\(maker.name) wrote new bots or categories, but they weren't asked for in your own words here, so Vello didn't make them. Ask for them yourself if you want them."),
                 to: conversationID)
            return
        }

        var madeCategoryNames: [String] = []
        var madeBotLines: [String] = []
        var filedBotLines: [String] = []

        // Categories first, so the bots can join them. One with the same name is used rather than made twice.
        var categoryIDsByName: [String: String] = [:]
        for wanted in order.categories {
            if let existing = layout.sections.first(where: { TeamBuildOrder.sameName($0.name, wanted.name) }) {
                categoryIDsByName[wanted.name.lowercased()] = existing.id
                continue
            }
            guard let newID = addSection(named: wanted.name) else { continue }
            if let purpose = wanted.purpose { updateCategory(newID) { $0.purpose = purpose } }
            categoryIDsByName[wanted.name.lowercased()] = newID
            madeCategoryNames.append(wanted.name)
        }

        // New bots run on the same engine as the bot that made them, on that engine's usual starting model: it works on this
        // Mac, which the owner's default engine may not.
        let engine = maker.provider
        for wanted in order.bots {
            let categoryID = wanted.category.flatMap { categoryIDsByName[$0.lowercased()] }
            let categoryWords = wanted.category.map { " in \($0)" } ?? ""
            if let existing = bots.first(where: { TeamBuildOrder.sameName($0.name, wanted.name) }) {
                // Already there: filed into its category rather than made a second time. The CEO stays on top.
                if let categoryID, !existing.primary, existing.id != Self.clickyID {
                    addMember(existing.id, to: categoryID)
                    filedBotLines.append("\(existing.name) was already here, so it's now\(categoryWords)")
                }
                continue
            }
            var made = addBot(name: wanted.name,
                              description: wanted.does.isEmpty ? "Your \(wanted.name) bot." : wanted.does,
                              instructions: TeamBuildOrder.instructions(for: wanted),
                              provider: engine, model: BotModels.startingModel(for: engine), groupID: nil)
            made.effort = engine.hasPrefix("api:") ? nil : HarnessPrefs.defaultEffort(engine)
            save(made)
            if let categoryID { addMember(made.id, to: categoryID) }
            madeBotLines.append("\(made.name)\(categoryWords)")
        }

        var sentences: [String] = []
        if !madeBotLines.isEmpty {
            sentences.append("Vello made " + (madeBotLines.count == 1 ? "the bot " : "the bots ") + Self.listedInWords(madeBotLines) + ".")
        }
        if !madeCategoryNames.isEmpty {
            sentences.append("New " + (madeCategoryNames.count == 1 ? "category: " : "categories: ") + Self.listedInWords(madeCategoryNames) + ".")
        }
        sentences += filedBotLines.map { $0 + "." }
        if sentences.isEmpty {
            sentences.append("Everything \(maker.name) asked for was already here, so Vello didn't make anything new.")
        } else if !madeBotLines.isEmpty {
            sentences.append("They're in the sidebar, and each one's settings can change its brain, model and apps.")
        }
        post(BotChatMessage(author: Self.noteAuthor, text: sentences.joined(separator: " ")), to: conversationID)
    }

    /// "A", "A and B", "A, B and C".
    static func listedInWords(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }
}
