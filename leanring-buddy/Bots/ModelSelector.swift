//
//  ModelSelector.swift
//  leanring-buddy
//
//  The composer's model selector: one chip ("Sonnet 5.5 · High") that opens a two-column popover. On the left, every
//  subscription (the signed-in coding agents: Claude Code, Codex, Cursor, OpenCode, Grok, Gemini) and every saved API
//  key, each with its state. On the right, the models of the one being looked at, then its effort levels and, for
//  Claude, thinking and fast mode. Picking a model under another subscription moves the bot there. Changes save at
//  once and apply from the next reply. The rules (levels per model, words, chip label) are ClickyCore `ModelEffort`.
//

import ClickyCore
import SwiftUI

extension BotModels {
    /// The effort levels a bot on `engine` with `model` can pick; empty when it has no effort setting.
    static func efforts(for engine: String, model: String) -> [String] {
        ModelEffort.levels(engine: engine, model: model, engineListed: HarnessCenter.shared.efforts(for: engine, model: model))
    }
}

/// The chip in the composer. It replaces the separate model and effort chips.
struct ModelSelectorChip: View {
    @ObservedObject var store: BotsStore
    let bot: NativeBot
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let levels = BotModels.efforts(for: bot.provider, model: bot.model)
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                BrandLogo(id: ModelSelectorSources.logoID(for: bot.provider), name: HarnessCatalog.label(bot.provider), size: 14, plain: true)
                Text(ModelEffort.chipLabel(modelLabel: BotModels.label(bot.model, on: bot.provider), effort: bot.effort, levels: levels))
                    .font(.system(size: 12)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.7)
            }
            .foregroundColor(DS.Colors.textSecondary).padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering || open ? DS.Colors.hover : DS.Colors.selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .help("\(HarnessCatalog.label(bot.provider)): model and effort")
        .popover(isPresented: $open, arrowEdge: .top) {
            ModelSelectorPopover(store: store, botID: bot.id) { open = false }
        }
    }
}

/// One row of the left column: a subscription or an API key.
struct ModelSelectorSource: Identifiable, Equatable {
    /// The bot's `provider` value: a harness id, or "api:<provider id>".
    let id: String
    let label: String
    let state: BrainSourceState
}

@MainActor
enum ModelSelectorSources {
    /// The logo asset for an engine: a key's provider logo, else the harness's own.
    static func logoID(for engine: String) -> String {
        engine.hasPrefix("api:") ? String(engine.dropFirst(4)) : engine
    }

    static func subscriptions(center: HarnessCenter) -> [ModelSelectorSource] {
        HarnessCatalog.botEngines.map { info in
            let status = center.status(for: info.id)
            let state = BrainSourceState.of(checked: center.hasStatus(for: info.id), installed: status.installed,
                                            loggedIn: status.loggedIn, account: status.account, usesAPIKey: center.usesAPIKey(info.id))
            return ModelSelectorSource(id: info.id, label: info.label, state: state)
        }
    }

    static func apiKeys(keys: ProviderKeys, forPrimaryBot: Bool, current: String) -> [ModelSelectorSource] {
        var sources = keys.usableChatProviders(for: forPrimaryBot ? .theo : .bots).map { provider in
            ModelSelectorSource(id: "api:\(provider.id)", label: provider.label, state: .onAPIKey)
        }
        // A bot left on a key that's since been removed still shows where it is.
        if current.hasPrefix("api:"), !sources.contains(where: { $0.id == current }) {
            sources.append(ModelSelectorSource(id: current, label: HarnessCatalog.label(current), state: .signedOut))
        }
        return sources
    }

    static func maskedKey(for engine: String, keys: ProviderKeys) -> String? {
        engine.hasPrefix("api:") ? keys.maskedPreview(for: String(engine.dropFirst(4))) : nil
    }
}

struct ModelSelectorPopover: View {
    @ObservedObject var store: BotsStore
    let botID: String
    let close: () -> Void
    @ObservedObject private var center = HarnessCenter.shared
    @ObservedObject private var keys = ProviderKeys.shared
    @ObservedObject private var catalog = BrainCatalog.shared
    /// The subscription or key whose models are on the right. Starts on the bot's own.
    @State private var browsing: String?
    @State private var typedModel = ""

    private var bot: NativeBot? { store.bot(botID) }

    var body: some View {
        if let bot {
            let shown = browsing ?? bot.provider
            HStack(alignment: .top, spacing: 0) {
                sourceColumn(bot: bot, shown: shown)
                    .frame(width: 236)
                Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1)
                detailColumn(bot: bot, shown: shown)
                    .frame(width: 300)
            }
            .frame(height: 430)
            .onAppear {
                catalog.load()
                center.refresh()
            }
        }
    }

    // MARK: Left: subscriptions and keys

    private func sourceColumn(bot: NativeBot, shown: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                heading("Subscriptions")
                ForEach(ModelSelectorSources.subscriptions(center: center)) { source in
                    sourceRow(source, bot: bot, shown: shown)
                }
                heading("API keys").padding(.top, 10)
                let keyed = ModelSelectorSources.apiKeys(keys: keys, forPrimaryBot: bot.primary, current: bot.provider)
                ForEach(keyed) { source in sourceRow(source, bot: bot, shown: shown) }
                if keyed.isEmpty {
                    Text("No keys saved yet.").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).padding(.horizontal, 10).padding(.vertical, 4)
                }
                Button {
                    close()
                    TheoSettingsWindowController.show(section: .keys)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22)
                        Text("Add an API key…").font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(DS.Colors.textSecondary).padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(SidebarButtonStyle(isSelected: false)).pointerCursor()
            }
            .padding(8)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
            .foregroundColor(DS.Colors.textTertiary).padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
    }

    private func sourceRow(_ source: ModelSelectorSource, bot: NativeBot, shown: String) -> some View {
        let isCurrent = source.id == bot.provider
        let caption = ModelSelectorSources.maskedKey(for: source.id, keys: keys).map { "Key \($0)" } ?? source.state.caption
        return Button {
            browsing = source.id
            typedModel = ""
        } label: {
            HStack(spacing: 9) {
                BrandLogo(id: ModelSelectorSources.logoID(for: source.id), name: source.label, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.label).font(.system(size: 13, weight: isCurrent ? .semibold : .regular)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    Text(caption).font(.system(size: 11)).foregroundColor(source.state.isUsable ? DS.Colors.textTertiary : DS.Colors.warningText).lineLimit(1)
                }
                Spacer(minLength: 4)
                if isCurrent {
                    Circle().fill(DS.Colors.success).frame(width: 6, height: 6).help("\(bot.name) is on this one")
                }
            }
            .padding(.horizontal, 8).frame(height: 40).contentShape(Rectangle())
            .opacity(source.state.isUsable || isCurrent ? 1 : 0.7)
        }
        .buttonStyle(SidebarButtonStyle(isSelected: source.id == shown)).pointerCursor()
    }

    // MARK: Right: models, effort, thinking

    @ViewBuilder private func detailColumn(bot: NativeBot, shown: String) -> some View {
        let isSameEngine = shown == bot.provider
        let state = sourceState(for: shown, bot: bot)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(HarnessCatalog.label(shown)).font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text(isSameEngine ? "\(bot.name) thinks with this. Pick a model." : "Pick a model to move \(bot.name) here.")
                    .font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if !state.isUsable && !isSameEngine {
                notReady(engine: shown, state: state)
            } else {
                modelList(bot: bot, shown: shown)
                if isSameEngine { tuning(bot: bot) }
            }
            Spacer(minLength: 0)
            RowDivider()
            Button {
                close()
                NotificationCenter.default.post(name: .theoShowBotSettings, object: nil)
            } label: {
                HStack {
                    Text("All of \(bot.name)'s settings").font(.system(size: 12))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                }
                .foregroundColor(DS.Colors.textSecondary).padding(.horizontal, 14).frame(height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
        }
    }

    private func sourceState(for engine: String, bot: NativeBot) -> BrainSourceState {
        if engine.hasPrefix("api:") {
            return ModelSelectorSources.apiKeys(keys: keys, forPrimaryBot: bot.primary, current: bot.provider).first { $0.id == engine }?.state ?? .signedOut
        }
        return ModelSelectorSources.subscriptions(center: center).first { $0.id == engine }?.state ?? .notInstalled
    }

    private func notReady(engine: String, state: BrainSourceState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state == .notInstalled ? "\(HarnessCatalog.label(engine)) isn't on this Mac yet." :
                    state == .checking ? "Checking \(HarnessCatalog.label(engine))…" :
                    "\(HarnessCatalog.label(engine)) is signed out. Sign in with your subscription, or run it on an API key.")
                .font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            if state != .checking {
                Button(state == .notInstalled ? "Set it up in Harnesses" : "Sign in in Harnesses") {
                    close()
                    TheoSettingsWindowController.show(section: engine.hasPrefix("api:") ? .keys : .coding)
                }
                .buttonStyle(.theo(.primary, .small))
            }
        }
        .padding(.horizontal, 14).padding(.top, 6)
    }

    @ViewBuilder private func modelList(bot: NativeBot, shown: String) -> some View {
        let models = BotModels.list(for: shown, current: shown == bot.provider ? bot.model : "")
        if models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(HarnessCatalog.label(shown)) doesn't list its models. Type one, or leave it on its own default.")
                    .font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    TextField(shown == bot.provider && !bot.model.isEmpty ? bot.model : "Model id", text: $typedModel)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit { choose(model: typedModel, on: shown, bot: bot) }
                    Button(typedModel.isEmpty ? "Use default" : "Use") { choose(model: typedModel, on: shown, bot: bot) }
                        .buttonStyle(.theo(.secondary, .small))
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(models, id: \.self) { model in
                        let isChosen = shown == bot.provider && model == bot.model
                        Button { choose(model: model, on: shown, bot: bot) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(DS.Colors.accentText)
                                    .frame(width: 12).opacity(isChosen ? 1 : 0)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(BotModels.label(model, on: shown)).font(.system(size: 13, weight: isChosen ? .semibold : .regular))
                                        .foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                                    if let hint = ModelEffort.modelHint(engine: shown, model: model) {
                                        Text(hint).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).frame(minHeight: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(SidebarButtonStyle(isSelected: isChosen)).pointerCursor()
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: shown == bot.provider ? 170 : 330)
        }
    }

    @ViewBuilder private func tuning(bot: NativeBot) -> some View {
        let levels = BotModels.efforts(for: bot.provider, model: bot.model)
        VStack(alignment: .leading, spacing: 8) {
            RowDivider()
            HStack {
                Text("Effort").font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                Spacer()
                if levels.isEmpty {
                    Text("Set by the model").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                }
            }
            if levels.isEmpty {
                Text(bot.provider.hasPrefix("api:") ? "API models think as they're built to. Pick a different model for more or less." :
                        "\(BotModels.label(bot.model, on: bot.provider)) has no effort setting here.")
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                EffortSegments(levels: levels, selection: ModelEffort.carriedOver(effort: bot.effort, toLevels: levels)) { level in
                    var edited = bot
                    edited.effort = level
                    store.save(edited)
                }
                Text(ModelEffort.hint(for: ModelEffort.carriedOver(effort: bot.effort, toLevels: levels)))
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            if bot.provider == "claude" {
                HStack(spacing: 16) {
                    claudeToggle("Thinking", isOn: bot.thinking ?? false) { var edited = bot; edited.thinking = $0; store.save(edited) }
                    claudeToggle("Fast mode", isOn: bot.fast ?? false) { var edited = bot; edited.fast = $0; store.save(edited) }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14).padding(.top, 6)
    }

    private func claudeToggle(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Toggle(title, isOn: Binding(get: { isOn }, set: set)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            Text(title).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
        }
    }

    /// Saves a model choice. Under another subscription or key it moves the bot there, keeping its effort when the
    /// new model takes the same level and dropping Claude-only switches elsewhere.
    private func choose(model: String, on engine: String, bot: NativeBot) {
        var edited = bot
        let switching = engine != bot.provider
        edited.provider = engine
        edited.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && switching ? BotModels.startingModel(for: engine) : model.trimmingCharacters(in: .whitespacesAndNewlines)
        let levels = BotModels.efforts(for: engine, model: edited.model)
        edited.effort = ModelEffort.carriedOver(effort: switching ? (bot.effort ?? HarnessPrefs.defaultEffort(engine)) : bot.effort, toLevels: levels)
        if engine != "claude" { edited.thinking = nil; edited.fast = nil }
        store.save(edited)
        browsing = nil
        typedModel = ""
        if !switching || levels.isEmpty { close() }
    }
}

/// Auto plus each level, as one row of segments.
struct EffortSegments: View {
    let levels: [String]
    let selection: String?
    let choose: (String?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(nil)
            ForEach(levels, id: \.self) { segment($0) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.selected))
    }

    private func segment(_ level: String?) -> some View {
        let isOn = selection == level
        return Button { choose(level) } label: {
            Text(level.map(ModelEffort.shortTitle(for:)) ?? "Auto")
                .font(.system(size: 11, weight: isOn ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundColor(isOn ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(maxWidth: .infinity).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? DS.Colors.surface : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(ModelEffort.hint(for: level))
    }
}
