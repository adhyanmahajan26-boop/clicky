//
//  BotsSettings.swift
//  leanring-buddy
//
//  Settings › Bots & categories: every bot and every category on one page, so nothing about them hides behind a
//  right-click in the sidebar. Make a bot or a category, rename either, move a bot by dragging it onto a category (or
//  with its Move menu), pick a category's manager, turn a bot off, show a hidden one, and delete a bot or a category.
//  It's a view over `BotsStore`, the same calls the sidebar and the team pages make.
//

import ClickyCore
import SwiftUI

struct BotsSettingsContent: View {
    @ObservedObject private var store = BotsStore.shared
    @ObservedObject private var products = TheoProducts.shared
    @ObservedObject private var selection = BotsSelection.shared
    @State private var addingBot = false
    /// The category the New bot sheet was opened from: the bot it makes goes in there.
    @State private var addingBotToCategoryID: String?
    /// The item ("bot:<id>") or category ("category:<id>") waiting for a yes to delete it.
    @State private var confirmingDelete: String?
    /// The bot or category whose name is being typed over, and what's typed so far.
    @State private var renaming: String?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    private var ceoName: String { store.primary?.name ?? "Vello" }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "", hint: "Drag a bot onto a category to move it there, or use Move on its row. You can also ask \(ceoName) in chat: \u{201C}make a bot that checks my email\u{201D} or \u{201C}move Ledger to Finance\u{201D}.") {
                HStack(spacing: 8) {
                    Button { addingBotToCategoryID = nil; addingBot = true } label: { Label("New bot", systemImage: "plus") }
                        .buttonStyle(.theoPrimary).pointerCursor()
                    Button { newCategory() } label: { Label("New category", systemImage: "folder.badge.plus") }
                        .buttonStyle(.theoSecondary).pointerCursor()
                    Button { selection.openSettings(.teams) } label: { Label("Ready-made teams", systemImage: "person.3") }
                        .buttonStyle(.theoGhost).pointerCursor()
                        .help("Add a whole category at once: a manager and the bots who report to it")
                    Spacer(minLength: 0)
                    Text(countLine).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                }
                .padding(12)
            }
            ceoCard
            ForEach(shownCategories) { category in categoryCard(category) }
            otherBotsCard
        }
        .sheet(isPresented: $addingBot, onDismiss: { addingBotToCategoryID = nil }) {
            NewBotSheet(store: store, joiningTeamName: addingBotToCategoryID.flatMap { store.category($0)?.name }) { newBot in
                if let newBot, let addingBotToCategoryID { store.move(BotsLayout.item(forBot: newBot.id), toSection: addingBotToCategoryID) }
                addingBot = false
                addingBotToCategoryID = nil
            }
        }
        .alert(deleteTitle, isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let confirmingDelete { delete(confirmingDelete) }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: - What's on the page

    /// Every category, a sub-category right after its parent. Pointer Assistant's own team leaves with Pointer Assistant.
    private var shownCategories: [BotsLayout.Section] {
        var ordered: [BotsLayout.Section] = []
        func addWithChildren(_ category: BotsLayout.Section) {
            ordered.append(category)
            store.subsections(of: category.id).forEach(addWithChildren)
        }
        store.rootSections.forEach(addWithChildren)
        // A sub-category whose parent is gone still shows.
        ordered += store.layout.sections.filter { section in !ordered.contains { $0.id == section.id } }
        return ordered.filter { products.isOn(.clicky) || $0.leaderID != BotsStore.clickyID }
    }

    /// Bots in a category, its manager first. The CEO has its own card, so it isn't repeated.
    private func botsShown(in category: BotsLayout.Section) -> [NativeBot] {
        let members = store.members(of: category).filter { !$0.primary }
        guard let managerID = category.leaderID, let manager = members.first(where: { $0.id == managerID }) else { return members }
        return [manager] + members.filter { $0.id != managerID }
    }

    /// Bots in no category at all.
    private var unfiledBots: [NativeBot] {
        let filed = Set(store.layout.sections.flatMap(\.items))
        return store.bots.filter { bot in
            !bot.primary && !filed.contains(BotsLayout.item(forBot: bot.id))
                && (products.isOn(.clicky) || bot.owner != BotsStore.clickyID)
        }
    }

    private var countLine: String {
        let botCount = store.bots.count
        let categoryCount = store.layout.sections.count
        return "\(botCount) bot\(botCount == 1 ? "" : "s") in \(categoryCount) categor\(categoryCount == 1 ? "y" : "ies")"
    }

    // MARK: - Cards

    /// The CEO: every category reports to it, and it can't be deleted or moved.
    @ViewBuilder private var ceoCard: some View {
        if let ceo = store.primary {
            TheoSection(title: "Your CEO", hint: "\(ceo.name) runs the company: every category's manager reports here. It can't be deleted, and it can make bots and categories for you when you ask in chat.") {
                botRow(ceo, in: nil, isManager: false)
            }
        }
    }

    private func categoryCard(_ category: BotsLayout.Section) -> some View {
        let bots = botsShown(in: category)
        let parentName = category.parentID.flatMap { store.category($0)?.name }
        return VStack(alignment: .leading, spacing: 8) {
            categoryHeader(category, botCount: bots.count, parentName: parentName)
            VStack(alignment: .leading, spacing: 0) {
                if bots.isEmpty {
                    Text("No bots yet. Drag one here, or make a new one.")
                        .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
                        if index > 0 { RowDivider(inset: 56) }
                        botRow(bot, in: category, isManager: category.leaderID == bot.id)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .dropTarget { dropped in dropped.forEach { store.move($0, toSection: category.id) } }
        }
        .padding(.leading, parentName == nil ? 0 : 24)
    }

    private func categoryHeader(_ category: BotsLayout.Section, botCount: Int, parentName: String?) -> some View {
        let renameKey = "category:\(category.id)"
        let members = store.members(of: category).filter { !$0.primary }
        return HStack(spacing: 8) {
            Image(systemName: "folder.fill").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
            if renaming == renameKey {
                renameField(placeholder: "Category name") { store.renameSection(category.id, to: $0) }
            } else {
                Text(category.name).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                if let parentName { Text("in \(parentName)").font(TheoType.micro).foregroundColor(DS.Colors.textTertiary) }
                Text("\(botCount)").font(TheoType.micro).foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(DS.Colors.hover))
            }
            Spacer(minLength: 8)
            if category.leaderID != BotsStore.clickyID {
                Menu {
                    Button("No manager (everyone reports to \(ceoName))") { store.setLeader(nil, of: category.id) }
                    if !members.isEmpty { Divider() }
                    ForEach(members) { bot in Button(bot.name) { store.setLeader(bot.id, of: category.id) } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "crown.fill").font(.system(size: 9))
                        Text(category.leaderID.flatMap { store.bot($0)?.name }.map { "Manager: \($0)" } ?? "No manager").font(TheoType.caption)
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().pointerCursor()
                .help("Who this category's bots report to before \(ceoName)")
            }
            Button { addingBotToCategoryID = category.id; addingBot = true } label: { Image(systemName: "plus") }
                .buttonStyle(.theo(.ghost, .small)).pointerCursor().help("New bot in \(category.name)")
            Button { startRenaming(renameKey, current: category.name) } label: { Image(systemName: "pencil") }
                .buttonStyle(.theo(.ghost, .small)).pointerCursor().help("Rename \(category.name)")
            Button { selection.pane = .category(category.id) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.theo(.ghost, .small)).pointerCursor().help("Open the team page: reports, schedule and what it's for")
            Button { confirmingDelete = renameKey } label: { Image(systemName: "trash") }
                .buttonStyle(.theo(.ghost, .small)).pointerCursor().help("Delete \(category.name) (its bots stay)")
        }
        .padding(.horizontal, 4)
    }

    private var otherBotsCard: some View {
        let bots = unfiledBots
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
                Text("Not in a category").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                Text("\(bots.count)").font(TheoType.micro).foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(DS.Colors.hover))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                if bots.isEmpty {
                    Text("Every bot is in a category. Drag one here to take it out.")
                        .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
                        if index > 0 { RowDivider(inset: 56) }
                        botRow(bot, in: nil, isManager: false)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .dropTarget { dropped in dropped.forEach { store.move($0, toSection: nil) } }
        }
    }

    // MARK: - One bot

    /// A bot's row: its face, name, what it does and its model, then Move, Rename, Open and Delete. The row drags onto
    /// any category. The CEO's row has no Move or Delete.
    private func botRow(_ bot: NativeBot, in category: BotsLayout.Section?, isManager: Bool) -> some View {
        let item = BotsLayout.item(forBot: bot.id)
        let renameKey = item
        let isCEO = bot.primary
        // Pointer Assistant manages its own team; its name and settings live in Settings › Pointer Assistant.
        let isPointerAssistant = bot.id == BotsStore.clickyID
        let isFixed = isCEO || isPointerAssistant
        return HStack(spacing: 12) {
            BotAvatar(bot: bot, size: 32, state: .idle, badge: false)
            VStack(alignment: .leading, spacing: 2) {
                if renaming == renameKey {
                    renameField(placeholder: "Bot name") { newName in
                        guard var renamed = store.bot(bot.id) else { return }
                        renamed.name = newName
                        store.save(renamed)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(bot.name).font(TheoType.bodyMedium).foregroundColor(bot.isOn ? DS.Colors.textPrimary : DS.Colors.textTertiary).lineLimit(1)
                        if isManager {
                            HStack(spacing: 2) {
                                Image(systemName: "crown.fill").font(.system(size: 8))
                                Text("Manager").font(.system(size: 9.5, weight: .semibold))
                            }
                            .foregroundColor(DS.Colors.gold).fixedSize()
                        }
                        if !bot.isOn { chip("Off") }
                        if store.isHidden(item) { chip("Hidden from sidebar") }
                        if bot.owner == BotsStore.clickyID { chip("Pointer Assistant's team") }
                    }
                }
                Text(detailLine(bot)).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !isFixed {
                moveMenu(item: item, botName: bot.name, currentCategory: category)
            }
            if !isPointerAssistant {
                Button { startRenaming(renameKey, current: bot.name) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.theo(.ghost, .small)).pointerCursor().help("Rename \(bot.name)")
            }
            Button { openBotSettings(bot.id) } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.theo(.ghost, .small)).pointerCursor().help("\(bot.name)'s settings: instructions, model, apps, look")
            if !isPointerAssistant { moreMenu(bot, item: item) }
            if !isFixed {
                Button { confirmingDelete = item } label: { Image(systemName: "trash") }
                    .buttonStyle(.theo(.ghost, .small)).pointerCursor().help("Delete \(bot.name)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .modifier(DraggableBotRow(item: item, name: bot.name, isDraggable: !isFixed && renaming != renameKey))
    }

    private func moveMenu(item: String, botName: String, currentCategory: BotsLayout.Section?) -> some View {
        Menu {
            ForEach(shownCategories) { category in
                Button(category.name) { store.move(item, toSection: category.id) }
                    .disabled(category.id == currentCategory?.id)
            }
            if !shownCategories.isEmpty { Divider() }
            Button("New category with \(botName)") {
                store.move(item, toSection: nil, newSectionName: freshCategoryName())
                if let made = store.layout.sections.last { startRenaming("category:\(made.id)", current: made.name) }
            }
            if store.layout.section(of: item) != nil {
                Button("Take out of its category") { store.move(item, toSection: nil) }
            }
        } label: {
            Text("Move").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().pointerCursor()
        .help("Move \(botName) to another category")
    }

    private func moreMenu(_ bot: NativeBot, item: String) -> some View {
        Menu {
            Button("Open chat") { selection.pane = .bot(bot.id) }
            Button(bot.isOn ? "Turn off" : "Turn on") { store.setEnabled(!bot.isOn, botID: bot.id) }
                .disabled(bot.primary)
            if store.isHidden(item) {
                Button("Show in sidebar") { store.setHidden(false, item) }
            } else if !bot.primary {
                Button("Hide from sidebar") { store.setHidden(true, item) }
            }
            if !bot.primary && bot.owner == nil {
                Button("Make CEO") { store.makePrimary(bot.id) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointerCursor()
        .help("More for \(bot.name)")
    }

    private func detailLine(_ bot: NativeBot) -> String {
        let job = bot.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = bot.model.isEmpty ? "" : bot.modelLabel
        return [job.isEmpty ? "No job written yet" : job, model].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(TheoType.micro).foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(DS.Colors.hover))
            .fixedSize()
    }

    // MARK: - Renaming

    private func startRenaming(_ key: String, current: String) {
        renameText = current
        renaming = key
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    /// The name, typed over in place: Return saves, Escape or clicking away keeps the old one unless something was typed.
    private func renameField(placeholder: String, save: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $renameText)
                .textFieldStyle(.roundedBorder).font(TheoType.body).frame(maxWidth: 240)
                .focused($renameFieldFocused)
                .onSubmit { finishRenaming(save) }
                .onExitCommand { renaming = nil }
            Button("Save") { finishRenaming(save) }.buttonStyle(.theo(.secondary, .small)).pointerCursor()
            Button("Cancel") { renaming = nil }.buttonStyle(.theo(.ghost, .small)).pointerCursor()
        }
    }

    private func finishRenaming(_ save: (String) -> Void) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { save(name) }
        renaming = nil
    }

    // MARK: - Actions

    private func newCategory() {
        if let id = store.addSection(named: freshCategoryName()), let made = store.category(id) {
            startRenaming("category:\(id)", current: made.name)
        }
    }

    private func freshCategoryName() -> String {
        let taken = Set(store.layout.sections.map(\.name))
        if !taken.contains("New category") { return "New category" }
        var number = 2
        while taken.contains("New category \(number)") { number += 1 }
        return "New category \(number)"
    }

    /// Opens the bot's chat with its settings slid over, the way the sidebar's Settings… does.
    private func openBotSettings(_ botID: String) {
        if botID == BotsStore.clickyID { selection.openSettings(.clicky); return }
        selection.pane = .bot(botID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .theoShowBotSettings, object: nil)
        }
    }

    private var deleteTitle: String {
        guard let confirmingDelete else { return "" }
        if confirmingDelete.hasPrefix("category:") {
            return "Delete \(store.category(String(confirmingDelete.dropFirst(9)))?.name ?? "this category")?"
        }
        return "Delete \(BotsLayout.botID(ofItem: confirmingDelete).flatMap { store.bot($0)?.name } ?? "this bot")?"
    }

    private var deleteMessage: String {
        guard let confirmingDelete else { return "" }
        if confirmingDelete.hasPrefix("category:") { return "Its bots stay, under Not in a category." }
        if BotsLayout.botID(ofItem: confirmingDelete).flatMap({ store.bot($0) })?.owner != nil {
            return "Its chat goes too, and a hidden helper does this job for Pointer Assistant from now on. To keep it working out of sight, hide it instead."
        }
        return "Its chat and its routines go too. To keep it but stop it working, turn it off instead."
    }

    private func delete(_ key: String) {
        if key.hasPrefix("category:") {
            let categoryID = String(key.dropFirst(9))
            if selection.pane == .category(categoryID) { selection.pane = .home }
            // Its sub-categories move up to the top level rather than vanish with it.
            for child in store.subsections(of: categoryID) { store.updateCategory(child.id) { $0.parentID = nil } }
            store.deleteSection(categoryID)
        } else if let botID = BotsLayout.botID(ofItem: key) {
            store.deleteBot(botID)
        }
    }
}

/// A bot's row picks up like the sidebar's rows, so it drops on any category here or in the sidebar.
private struct DraggableBotRow: ViewModifier {
    let item: String
    let name: String
    let isDraggable: Bool

    func body(content: Content) -> some View {
        if isDraggable {
            content.draggable(item) {
                Text(name).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(DS.Colors.accent))
            }
        } else {
            content
        }
    }
}
