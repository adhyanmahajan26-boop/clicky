//
//  BotTeamBuilding.swift
//  leanring-buddy
//
//  The CEO makes new bots and categories, picks their managers and moves bots between them, when the owner asks in chat. The CEO writes a ```team block
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
        // The owner's words, a manager and a move included ("make Penny the manager of Growth").
        guard fromOwner, mayBuildTeam(maker),
              let ownerWords = ownerWordsBehindTurn(in: conversationID), TeamBuildIntent.ownerAsked(ownerWords) else {
            post(BotChatMessage(author: Self.noteAuthor,
                                text: "\(maker.name) wrote changes to the bots or categories, but they weren't asked for in your own words here, so Vello didn't make them. Ask for them yourself if you want them."),
                 to: conversationID)
            return
        }

        var madeCategoryNames: [String] = []
        var madeBotLines: [String] = []
        var filedBotLines: [String] = []
        var managerLines: [String] = []

        // Each category's manager before any change, so a manager filled in by itself (the first bot in a category takes the
        // job) is said in the note too, and the CEO doesn't think the category has none.
        var managerBeforeBySectionID: [String: String] = [:]
        for section in layout.sections { if let leaderID = section.leaderID { managerBeforeBySectionID[section.id] = leaderID } }
        var categoryIDsWithManagerNamed: Set<String> = []

        // Categories first, so the bots can join them. One with the same name is used rather than made twice.
        var categoryIDsByName: [String: String] = [:]
        for wanted in order.categories {
            if let existing = layout.sections.first(where: { TeamBuildOrder.sameName($0.name, wanted.name) }) {
                categoryIDsByName[wanted.name.lowercased()] = existing.id
                if let purpose = wanted.purpose, purpose != existing.purpose { updateCategory(existing.id) { $0.purpose = purpose } }
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
                // Already there: moved into its category rather than made a second time. The CEO stays on top, and
                // Pointer Assistant's own helpers stay on its team.
                if let categoryID, !existing.primary, existing.id != Self.clickyID, existing.owner == nil,
                   !(category(categoryID)?.items.contains(BotsLayout.item(forBot: existing.id)) ?? false) {
                    move(BotsLayout.item(forBot: existing.id), toSection: categoryID)
                    filedBotLines.append("\(existing.name) moved to \(savedCategoryName(wanted.category))")
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

        // Managers last, so a bot made in this same answer can be one.
        for wanted in order.categories where wanted.manager != nil {
            guard let categoryID = categoryIDsByName[wanted.name.lowercased()], let team = category(categoryID),
                  team.leaderID != BotsStore.clickyID else { continue }
            categoryIDsWithManagerNamed.insert(categoryID)
            if wanted.wantsNoManager {
                if team.leaderID != nil || team.wantsManager != false {
                    setLeader(nil, of: categoryID)
                    managerLines.append("\(team.name) has no manager now, so its bots report to \(maker.name)")
                }
                continue
            }
            guard let managerName = wanted.manager else { continue }
            guard let manager = bots.first(where: { TeamBuildOrder.sameName($0.name, managerName) }),
                  !manager.primary, manager.id != Self.clickyID, manager.owner == nil else {
                managerLines.append("Vello couldn't make \(managerName) the manager of \(team.name): there's no bot by that name that can manage a team")
                continue
            }
            // Already the manager: said anyway when it only became one in this answer (a new category's first bot takes the job
            // as it joins, before this loop), so the note always names the manager it was asked for.
            guard team.leaderID != manager.id else {
                if managerBeforeBySectionID[categoryID] != manager.id { managerLines.append("\(manager.name) manages \(team.name) now") }
                continue
            }
            addMember(manager.id, to: categoryID)
            setLeader(manager.id, of: categoryID)
            managerLines.append("\(manager.name) manages \(team.name) now")
        }

        // A manager the block didn't name but the category got anyway: a new category's first bot, or the next bot in one
        // whose manager moved out.
        for section in layout.sections where !categoryIDsWithManagerNamed.contains(section.id) && section.leaderID != BotsStore.clickyID {
            guard let leaderID = section.leaderID, leaderID != managerBeforeBySectionID[section.id], let manager = bot(leaderID) else { continue }
            managerLines.append("\(manager.name) manages \(section.name) now, as its first bot (ask for another manager, or none, if you'd like)")
        }

        var sentences: [String] = []
        if !madeBotLines.isEmpty {
            sentences.append("Vello made " + (madeBotLines.count == 1 ? "the bot " : "the bots ") + Self.listedInWords(madeBotLines) + ".")
        }
        if !madeCategoryNames.isEmpty {
            sentences.append("New " + (madeCategoryNames.count == 1 ? "category: " : "categories: ") + Self.listedInWords(madeCategoryNames) + ".")
        }
        sentences += filedBotLines.map { $0 + "." }
        sentences += managerLines.map { $0 + "." }
        if sentences.isEmpty {
            sentences.append("Everything \(maker.name) asked for was already set up that way, so nothing changed.")
        } else if !madeBotLines.isEmpty {
            sentences.append("They're in the sidebar, and each one's settings can change its brain, model and apps.")
        }
        // Marked as a team note so the CEO reads it at the start of its next turn (`takeWaitingReports`) and knows what was made.
        post(BotChatMessage(author: Self.noteAuthor, text: sentences.joined(separator: " "), card: Self.teamNoteCard), to: conversationID)
    }

    /// The `card` of Vello's note on what a ```team block changed. It draws as a plain note.
    static let teamNoteCard = "team-note"

    /// A category's name as it's saved, for the chat's note.
    private func savedCategoryName(_ name: String?) -> String {
        guard let name else { return "" }
        return layout.sections.first { TeamBuildOrder.sameName($0.name, name) }?.name ?? name
    }

    /// "A", "A and B", "A, B and C".
    static func listedInWords(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }
}
