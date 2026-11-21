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
        var madeBots: [TeamBuildOrder.MadeBot] = []
        var filedBotLines: [String] = []
        var managerLines: [String] = []
        var brainLines: [String] = []

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
        // Mac, which the owner's default engine may not. A model or brain the block names is used when this Mac has it.
        let brains = brainsForBotsFromChat(maker: maker)
        for wanted in order.bots {
            let categoryID = wanted.category.flatMap { categoryIDsByName[$0.lowercased()] }
            if let existing = bots.first(where: { TeamBuildOrder.sameName($0.name, wanted.name) }) {
                // Already there: moved into its category rather than made a second time. The CEO stays on top, and
                // Pointer Assistant's own helpers stay on its team.
                let mayChange = !existing.primary && existing.id != Self.clickyID && existing.owner == nil
                if let categoryID, mayChange,
                   !(category(categoryID)?.items.contains(BotsLayout.item(forBot: existing.id)) ?? false) {
                    move(BotsLayout.item(forBot: existing.id), toSection: categoryID)
                    filedBotLines.append("\(existing.name) moved to \(savedCategoryName(wanted.category))")
                }
                // A model or brain named for a bot that exists switches it, as its settings' model picker does.
                if mayChange, wanted.model != nil || wanted.brain != nil {
                    let pick = TeamBuildBrains.pick(brain: wanted.brain, model: wanted.model, makerEngine: existing.provider, among: brains)
                    if let trouble = pick.trouble { brainLines.append("Vello couldn't switch \(existing.name) as asked: \(trouble)") }
                    let newModel = pick.model ?? (pick.engine == existing.provider ? existing.model : BotModels.startingModel(for: pick.engine))
                    if pick.engine != existing.provider || newModel != existing.model {
                        var switched = existing
                        let switching = pick.engine != existing.provider
                        switched.provider = pick.engine
                        switched.model = newModel
                        let levels = BotModels.efforts(for: pick.engine, model: newModel)
                        switched.effort = ModelEffort.carriedOver(effort: switching ? (existing.effort ?? HarnessPrefs.defaultEffort(pick.engine)) : existing.effort, toLevels: levels)
                        if pick.engine != "claude" { switched.thinking = nil; switched.fast = nil }
                        save(switched)
                        brainLines.append("\(existing.name) runs on \(brainWords(model: newModel, engine: pick.engine, makerEngine: maker.provider)) now")
                    }
                }
                continue
            }
            let pick = TeamBuildBrains.pick(brain: wanted.brain, model: wanted.model, makerEngine: maker.provider, among: brains)
            let engine = pick.engine
            let model = pick.model ?? BotModels.startingModel(for: engine)
            var made = addBot(name: wanted.name,
                              description: wanted.does.isEmpty ? "Your \(wanted.name) bot." : wanted.does,
                              instructions: TeamBuildOrder.instructions(for: wanted),
                              provider: engine, model: model, groupID: nil)
            made.effort = engine.hasPrefix("api:") ? nil : HarnessPrefs.defaultEffort(engine)
            save(made)
            if let categoryID { addMember(made.id, to: categoryID) }
            let modelWords = wanted.model != nil || wanted.brain != nil ? brainWords(model: model, engine: engine, makerEngine: maker.provider) : ""
            madeBots.append(TeamBuildOrder.MadeBot(name: made.name, category: categoryID == nil ? nil : savedCategoryName(wanted.category), modelWords: modelWords))
            if let trouble = pick.trouble {
                brainLines.append("\(made.name) runs on \(brainWords(model: model, engine: engine, makerEngine: maker.provider)) because \(trouble)")
            }
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
        if !madeBots.isEmpty { sentences.append(TeamBuildOrder.madeBotsSentence(madeBots)) }
        if !madeCategoryNames.isEmpty {
            sentences.append("New " + (madeCategoryNames.count == 1 ? "category: " : "categories: ") + TeamBuildOrder.listedInWords(madeCategoryNames) + ".")
        }
        sentences += filedBotLines.map { $0 + "." }
        sentences += managerLines.map { $0 + "." }
        sentences += brainLines.map { $0 + "." }
        if sentences.isEmpty {
            sentences.append("Everything \(maker.name) asked for was already set up that way, so nothing changed.")
        } else if !madeBots.isEmpty {
            sentences.append("They're in the sidebar, and each one's settings can change its brain, model and apps.")
        }
        // Marked as a team note so the CEO reads it at the start of its next turn (`takeWaitingReports`) and knows what was made.
        post(BotChatMessage(author: Self.noteAuthor, text: sentences.joined(separator: " "), card: Self.teamNoteCard), to: conversationID)
    }

    /// The `card` of Vello's note on what a ```team block changed. It draws as a plain note.
    static let teamNoteCard = "team-note"

    /// The brains a bot made or switched from chat can run on here, the maker's own first: command-line agents that are
    /// installed and not signed out, then API keys, each with the models Vello knows for it.
    private func brainsForBotsFromChat(maker: NativeBot) -> [TeamBuildBrains.Brain] {
        let center = HarnessCenter.shared
        var engines = NewBotSheet.engines.map { (id: $0.id, label: $0.label) }.filter { engine in
            engine.id == maker.provider || (center.hasStatus(for: engine.id) ? center.status(for: engine.id).ready : center.status(for: engine.id).installed)
        }
        engines += ProviderKeys.shared.usableChatProviders(for: .bots).map { (id: "api:\($0.id)", label: $0.label) }
        if !engines.contains(where: { $0.id == maker.provider }) { engines.insert((id: maker.provider, label: BrainAvailability.name(of: maker.model)), at: 0) }
        engines = engines.filter { $0.id == maker.provider } + engines.filter { $0.id != maker.provider }
        return engines.map { engine in
            let models = BotModels.list(for: engine.id, current: "").map { TeamBuildBrains.Model(id: $0, label: BotModels.label($0, on: engine.id)) }
            return TeamBuildBrains.Brain(engine: engine.id, label: engine.label, models: models)
        }
    }

    /// "Claude Haiku 5.5", or "gpt-6 on Codex" when it's not the maker's brain.
    private func brainWords(model: String, engine: String, makerEngine: String) -> String {
        let modelName = model.isEmpty ? "its usual model" : BotModels.label(model, on: engine)
        guard engine != makerEngine else { return modelName }
        let brainName = NewBotSheet.engines.first { $0.id == engine }?.label
            ?? ProviderKeys.shared.usableChatProviders(for: .bots).first { "api:\($0.id)" == engine }.map { "\($0.label) API key" }
            ?? engine
        return "\(modelName) (\(brainName))"
    }

    /// A category's name as it's saved, for the chat's note.
    private func savedCategoryName(_ name: String?) -> String {
        guard let name else { return "" }
        return layout.sections.first { TeamBuildOrder.sameName($0.name, name) }?.name ?? name
    }
}
