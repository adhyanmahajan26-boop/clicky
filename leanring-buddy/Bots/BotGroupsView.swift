//
//  BotGroupsView.swift
//  leanring-buddy
//
//  Making bot groups and bots from the Bots sidebar: a group's name, icon,
//  head and members; a new bot's role, instructions, engine and group. Also
//  Clicky's own chat, pinned at the top of the sidebar next to Theo.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

// MARK: - Group editor

struct GroupEditor: View {
    @ObservedObject var store: BotsStore
    @State var group: BotGroup
    /// The saved group, or nil when cancelled.
    let onDone: (BotGroup?) -> Void

    private static let symbols = ["person.2.fill", "person.3.fill", "briefcase.fill", "hammer.fill", "paintpalette.fill",
                                  "film.fill", "magnifyingglass", "envelope.fill", "chart.bar.fill", "sparkles"]
    @State private var confirmsDelete = false
    private var isNew: Bool { group.id.isEmpty }
    /// Like Grok's group chats: two to six bots, the head included.
    private var sizeFits: Bool { (2...6).contains(group.allIDs.count) && group.headID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New group" : "Edit \(group.name)").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                label("Name")
                TextField("Marketing, Research team, Side project…", text: $group.name).theoField()
            }
            VStack(alignment: .leading, spacing: 6) {
                label("Head")
                Picker("Head", selection: Binding(get: { group.headID ?? "" }, set: { group.headID = $0.isEmpty ? nil : $0 })) {
                    Text("Pick a head").tag("")
                    ForEach(store.bots) { bot in Text(bot.name).tag(bot.id) }
                }
                .labelsHidden()
                Text("The head leads the group chat: they hand your request to the others and merge their answers. Ask them to build something and it goes to your coding harness.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                label("Members")
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.bots.filter { $0.id != group.headID }) { bot in
                            Toggle(isOn: Binding(get: { group.memberIDs.contains(bot.id) }, set: { on in
                                if on { group.memberIDs.append(bot.id) } else { group.memberIDs.removeAll { $0 == bot.id } }
                            })) {
                                HStack(spacing: 8) {
                                    BotAvatar(bot: bot, size: 22, state: .idle)
                                    Text(bot.name)
                                    Text(bot.modelLabel).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 220)
                Text(sizeFits ? "\(group.allIDs.count) bots" : "Pick a head and 1 to 5 other bots (2 to 6 in all).")
                    .font(.system(size: 11)).foregroundColor(sizeFits ? DS.Colors.textTertiary : DS.Colors.warningText)
            }
            HStack {
                if !isNew {
                    Button("Delete group", role: .destructive) { confirmsDelete = true }
                        .buttonStyle(.theoDestructive)
                        .alert("Delete \(group.name)?", isPresented: $confirmsDelete) {
                            Button("Delete", role: .destructive) {
                                store.deleteGroup(group.id)
                                onDone(nil)
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Its chat goes too. The bots in it stay.")
                        }
                }
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.theoSecondary)
                Button(isNew ? "Create group" : "Save") {
                    var saved = group
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    if saved.id.isEmpty {
                        var id = BotsT3.slug(saved.name)
                        var suffix = 2
                        while store.group(id) != nil { id = "\(BotsT3.slug(saved.name))-\(suffix)"; suffix += 1 }
                        saved.id = id
                    }
                    store.save(saved)
                    onDone(saved)
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.theoPrimary)
                .disabled(group.name.trimmingCharacters(in: .whitespaces).isEmpty || !sizeFits)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.secondary)
    }
}

// MARK: - New bot

/// A starting point for a new bot: you pick one (or Blank) and change anything before creating it.
struct BotStencil: Identifiable {
    let id: String
    let name: String
    let summary: String
    let instructions: String
    let glyph: String
    let colour: String
    let apps: [String]

    /// The character each stencil starts with, so the gallery doesn't show twins.
    var character: BotCharacter {
        switch id {
        case "researcher": return .owl
        case "inbox": return .cloud
        case "builder": return .tank
        case "writer": return .drop
        case "reviewer": return .cat
        case "planner": return .cube
        case "briefing": return .sprout
        case "reels", "reel": return .tube
        case "tutor": return .gem
        default: return .pebble
        }
    }

    static let all: [BotStencil] = [
        BotStencil(id: "blank", name: "Blank", summary: "Start from nothing and write its job yourself.",
                   instructions: "", glyph: "", colour: "slate", apps: []),
        BotStencil(id: "researcher", name: "Researcher", summary: "Digs into a question and answers with sources.",
                   instructions: "Investigate the question, read primary sources, and answer with a short brief that cites them. Say what's uncertain.",
                   glyph: "magnifyingglass", colour: "sky", apps: ["chrome", "theo"]),
        BotStencil(id: "inbox", name: "Inbox assistant", summary: "Sorts your mail and drafts replies for you to send.",
                   instructions: "Read the inbox, group mail into needs-a-reply, FYI and ignore, and draft replies when asked. Never send, delete or label mail.",
                   glyph: "envelope.fill", colour: "rose", apps: ["gmail", "calendar"]),
        BotStencil(id: "builder", name: "Builder", summary: "Plans an app or a fix, then hands it to your harness.",
                   instructions: "Turn the idea into a short plan, then write one final prompt for the coding agent: a line \"Project: <name>\" and the prompt in a ```prompt block.",
                   glyph: "chevron.left.forwardslash.chevron.right", colour: "indigo", apps: []),
        BotStencil(id: "writer", name: "Writer", summary: "Drafts posts, emails and docs in your voice.",
                   instructions: "Write clear, plain drafts in the owner's voice. Ask for the audience and length when they matter. Keep it short.",
                   glyph: "doc.text.fill", colour: "amber", apps: ["docs", "notion"]),
        BotStencil(id: "reviewer", name: "Design reviewer", summary: "Looks at a screen or a plan and says what to change.",
                   instructions: "Review the design or plan honestly: what's confusing, what's missing, and the three changes that matter most.",
                   glyph: "paintbrush.pointed.fill", colour: "violet", apps: ["chrome"]),
        BotStencil(id: "planner", name: "Planner", summary: "Breaks a goal into steps, owners and dates.",
                   instructions: "Turn a goal into an ordered plan: scope, milestones, what's left out, risks. Push back on scope creep.",
                   glyph: "list.bullet.clipboard.fill", colour: "lime", apps: ["notion"]),
        BotStencil(id: "briefing", name: "Daily briefing", summary: "A morning summary of mail, calendar and news.",
                   instructions: "Each morning, sum up what needs the owner today: mail that needs a reply, the calendar, and three relevant headlines.",
                   glyph: "sun.max.fill", colour: "ember", apps: ["gmail", "calendar", "chrome"]),
        BotStencil(id: "reels", name: "Reel editor", summary: "Turns footage and ideas into short videos.",
                   instructions: "Make and edit reels with the HyperFrames skills and the Content Studio tools. Ask before long GPU runs.",
                   glyph: "film.fill", colour: "teal", apps: ["studio", "hyperframes"]),
        BotStencil(id: "tutor", name: "Tutor", summary: "Explains a topic step by step and checks you got it.",
                   instructions: "Teach step by step with small examples, then ask one short question to check understanding.",
                   glyph: "graduationcap.fill", colour: "sky", apps: ["theo"]),
    ]
}

/// The models a bot can pick for its engine, and what a new bot starts on.
@MainActor
enum BotModels {
    /// Sonnet rather than the list's first entry: Opus would be an expensive default for a bot that mostly chats.
    static func startingModel(for engine: String) -> String {
        if engine.hasPrefix("api:") {
            return ProviderInfo.info(for: String(engine.dropFirst(4))).flatMap { ProviderKeys.shared.models(for: $0).first } ?? ""
        }
        return HarnessPrefs.defaultModel(engine)
            ?? ["claude": "claude-sonnet-5-5", "grok": "grok-4.6", "opencode": "opencode/deepseek-v4.1-flash-free"][engine]
            ?? HarnessCenter.shared.models(for: engine).first?.id ?? ""
    }

    static func list(for bot: NativeBot) -> [String] { list(for: bot.provider, current: bot.model) }

    static func list(for engine: String, current: String) -> [String] {
        let listed: [String]
        if engine.hasPrefix("api:") {
            listed = ProviderInfo.info(for: String(engine.dropFirst(4))).map { ProviderKeys.shared.models(for: $0) } ?? []
        } else {
            switch engine {
            case "grok": listed = BotModelSettings.grokModels
            case "claude": listed = BrainCatalog.shared.models[.claude] ?? HarnessCatalog.claudeModels.map(\.id)
            case "opencode": listed = BrainCatalog.shared.models[.opencode] ?? HarnessCenter.shared.models(for: "opencode").map(\.id)
            default: listed = HarnessCenter.shared.models(for: engine).map(\.id)
            }
        }
        return listed.contains(current) || current.isEmpty ? listed : [current] + listed
    }

    static func label(_ model: String, on engine: String) -> String {
        HarnessCenter.shared.models(for: engine).first { $0.id == model }?.label ?? NativeBot.label(for: model)
    }
}

struct NewBotSheet: View {
    @ObservedObject var store: BotsStore
    let onDone: (NativeBot?) -> Void
    @State private var stencil: BotStencil?
    @State private var name = ""
    @State private var role = ""
    @State private var instructions = ""
    @State private var provider = HarnessPrefs.defaultHarness
    @State private var model = BotModels.startingModel(for: HarnessPrefs.defaultHarness)
    @ObservedObject private var keys = ProviderKeys.shared
    @State private var groupID = ""
    @State private var look = NativeBot(id: "new", name: "", description: "", instructions: "", hue: 205, accentHue: 235,
                                        primary: false, provider: "claude", model: "", effort: nil, apps: [], category: nil, shape: "slate")

    /// The engines a bot can run on, and the model each starts with (changed later in its settings).
    static let engines: [(id: String, label: String, model: String)] = [
        ("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor"), ("opencode", "OpenCode"), ("grok", "Grok"), ("gemini", "Gemini"),
    ].map { ($0.0, $0.1, EngineSetupRules.starterModels[$0.0] ?? "") }
    /// The engines installed on this Mac (all of them until the check has run).
    private var installedEngines: [(id: String, label: String, model: String)] {
        let center = HarnessCenter.shared
        let ready = Self.engines.filter { center.status(for: $0.id).installed }
        return ready.isEmpty ? Array(Self.engines.prefix(5)) : ready
    }

    var body: some View {
        Group {
            if stencil == nil { gallery } else { form }
        }
        .frame(width: 560)
        .background(DS.Colors.surface)
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New bot").font(.system(size: 20, weight: .semibold))
                Text("Pick a starting point. Everything can be changed before and after you create it.")
                    .font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(BotStencil.all) { item in
                    Button { choose(item) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            BotAvatar(bot: preview(of: item), size: 32, state: .idle)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                                Text(item.summary).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12).frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack { Spacer(); Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.theoSecondary) }
        }
        .padding(24)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                LookButton(bot: $look)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $name).textFieldStyle(.plain).font(.system(size: 18, weight: .semibold))
                    TextField("What it does", text: $role).textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary)
                }
            }
            field("Instructions") {
                TextEditor(text: $instructions)
                    .font(.system(size: 13)).scrollContentBackground(.hidden).padding(8).frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.surface1))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            }
            HStack(alignment: .top, spacing: 12) {
                field("Runs on") {
                    Picker("Runs on", selection: Binding(get: { provider }, set: { choice in
                        if choice == "__add_key" {
                            onDone(nil)
                            TheoSettingsWindowController.show(section: .keys)
                            return
                        }
                        provider = choice
                        model = BotModels.startingModel(for: choice)
                    })) {
                        Section("Subscriptions") {
                            ForEach(installedEngines, id: \.id) { engine in Text(engine.label).tag(engine.id) }
                        }
                        Section("API keys") {
                            ForEach(keys.usableChatProviders(for: .bots)) { key in Text(key.label).tag("api:\(key.id)") }
                            Text("Add a key…").tag("__add_key")
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                field("Model") {
                    let choices = BotModels.list(for: provider, current: model)
                    if choices.isEmpty {
                        TextField("Model id", text: $model).textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $model) {
                            ForEach(choices, id: \.self) { choice in Text(BotModels.label(choice, on: provider)).tag(choice) }
                        }
                        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !store.groups.isEmpty {
                field("Group") {
                    Picker("Group", selection: $groupID) {
                        Text("None").tag("")
                        ForEach(store.groups) { group in Text(group.name).tag(group.id) }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Button("Back") { stencil = nil }.buttonStyle(.theoGhost)
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.theoSecondary)
                Button("Create bot", action: create)
                    .keyboardShortcut(.defaultAction).buttonStyle(.theoPrimary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choose(_ item: BotStencil) {
        stencil = item
        name = item.id == "blank" ? "" : item.name
        role = item.id == "blank" ? "" : item.summary
        instructions = item.instructions
        look.avatar = BotCharacter.firstFree(preferring: item.character, among: store.bots).rawValue
        look.name = name
        // A stencil wears the gear of its job; a blank bot gets a random tasteful figure.
        look.look = item.id == "blank" ? .shuffled() : .standard(id: item.id, name: item.name)
    }

    private func preview(of item: BotStencil) -> NativeBot {
        var bot = look
        bot.name = item.name
        bot.avatar = item.character.rawValue
        bot.look = item.id == "blank" ? .clicky : .standard(id: item.id, name: item.name)
        return bot
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var bot = store.addBot(name: trimmedName, description: role.isEmpty ? "Your \(trimmedName) bot." : role,
                               instructions: instructions.isEmpty ? "You are \(trimmedName). \(role)" : instructions,
                               provider: provider, model: model, groupID: groupID.isEmpty ? nil : groupID)
        bot.avatar = look.avatar
        if let dressed = look.look { bot.look = dressed }
        bot.apps = stencil?.apps ?? []
        bot.effort = provider.hasPrefix("api:") ? nil : HarnessPrefs.defaultEffort(provider)
        store.save(bot)
        onDone(bot)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
            content()
        }
    }
}

// MARK: - Clicky

/// Three dots rising and falling: someone is typing. Holds still with Reduce Motion on.
struct TypingDots: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(DS.Colors.textTertiary).frame(width: 6, height: 6)
                    .opacity(phase ? 1 : 0.3)
                    .offset(y: phase ? -2 : 1)
                    .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(Double(index) * 0.14), value: phase)
            }
        }
        .frame(height: 20)
        .onAppear { phase = true }
    }
}

/// Clicky's crew figure: white, with a cursor for an antenna. It talks while it speaks and works while it's busy.
struct ClickyAvatar: View {
    let size: CGFloat
    var isActive = false

    var body: some View {
        if let companion = CompanionManager.current {
            SpeakingClickyAvatar(companion: companion, size: size, isActive: isActive)
        } else {
            CrewAvatar(look: BotsStore.shared.clickyBot.crewLook, size: size, pose: isActive ? .working : .awake)
        }
    }
}

private struct SpeakingClickyAvatar: View {
    @ObservedObject var companion: CompanionManager
    let size: CGFloat
    let isActive: Bool

    var body: some View {
        let pose: PixelState = companion.voiceState == .responding ? .talking : companion.voiceState == .listening ? .listening : isActive ? .working : .awake
        CrewAvatar(look: BotsStore.shared.clickyBot.crewLook, size: size, pose: pose)
    }
}

/// Clicky's own chat, in the bots' style: the same brain as talking to Theo (it sees your screens, points, draws boards
/// and researches), typed instead of spoken. Its team's jobs and reports land here as cards, in time order with the turns.
struct ClickyChatScreen: View {
    @ObservedObject private var store = BotsStore.shared
    @State private var draft = ""
    @State private var turns: [[String: Any]] = []
    @State private var pending: String?
    @State private var speaks = false

    private var messages: [BotChatMessage] {
        store.conversation(BotsStore.clickyID).messages.filter { message in
            // A job's waiting card gives way to its finished one.
            guard message.text.isEmpty, let id = BotsStore.delegationID(of: message) else { return true }
            return store.delegation(id)?.isLive == true
        }
    }

    private var entries: [ClickyChatEntry] {
        let fromTurns = turns.map { turn -> ClickyChatEntry in
            let id = turn["id"] as? String ?? UUID().uuidString
            return .turn(id: id, you: turn["you"] as? String ?? "", answer: turn["claudia"] as? String ?? "", at: ClickyChatEntry.date(ofTurn: id))
        }
        return (fromTurns + messages.map { ClickyChatEntry.message($0) }).sorted { $0.at < $1.at }
    }

    /// "Manages Clicky · reports to Theo · Sonnet 5.5"
    private var statusLine: String {
        var parts = store.categories(of: BotsStore.clickyID).filter { $0.leaderID == BotsStore.clickyID }.map { "Manages \($0.name)" }
        if !parts.isEmpty { parts.append("reports to \(store.primary?.name ?? "the CEO")") }
        if parts.isEmpty { parts.append("Screen companion") }
        parts.append(NativeBot.label(for: ClickyModels.main))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let timeline = entries
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                ClickyAvatar(size: 34, isActive: store.isClickyBusy)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clicky").font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text(statusLine).font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 4) {
                    ForEach(store.clickyTeam) { bot in
                        Button { BotsSelection.shared.pane = .bot(bot.id) } label: {
                            BotAvatar(bot: bot, size: 24, state: store.replying[bot.id] != nil ? .thinking : .idle)
                        }
                        .buttonStyle(.plain).help("\(bot.name)'s chat")
                    }
                }
                .padding(.trailing, 6)
                Toggle("Speak answers", isOn: $speaks).toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
            }
            // Room on the right for the settings button, as in a bot's header.
            .padding(.leading, 20).padding(.trailing, 48).frame(height: 60)
            .overlay(alignment: .bottom) { Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if timeline.isEmpty && pending == nil {
                            VStack(spacing: 12) {
                                ClickyAvatar(size: 84)
                                    .padding(.top, 120)
                                Text("Clicky").font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                                Text("Ask about what's on your screen, have it point things out, draw a whiteboard, or say \u{201C}remember this\u{201D} or \u{201C}research this\u{201D} and its team takes it from there.")
                                    .font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 80)
                        }
                        ForEach(timeline) { entry in
                            switch entry {
                            case .turn(_, let you, let answer, _):
                                if you.hasPrefix(ClickyTeamPrompts.orderPrefix), let ceo = store.primary {
                                    BotLine(bot: ceo, text: String(you.dropFirst(ClickyTeamPrompts.orderPrefix.count)), showsName: true, animatesIn: false, isLive: false)
                                } else {
                                    UserBubble(text: you)
                                }
                                clickyLine(answer)
                            case .message(let message):
                                messageRow(message)
                            }
                        }
                        if let pending {
                            UserBubble(text: pending)
                            HStack(spacing: 10) {
                                ClickyAvatar(size: 28, isActive: true)
                                TypingDots()
                            }
                            .padding(.top, 8)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 24).padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
                .modifier(ChatScrollAnchor())
                .onChange(of: timeline.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: pending) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                // A job's finished card takes the place of its waiting one, so the count can stay the same.
                .onChange(of: store.conversation(BotsStore.clickyID).messages.count) { _, _ in
                    for delay in [0.1, 0.5, 1.2] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo("end", anchor: .bottom) } }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: 10) {
                TextField("Message Clicky", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...6)
                    .onSubmit(send)
                HStack(spacing: 6) {
                    Button { NotificationCenter.default.post(name: .theoShowBotSettings, object: nil) } label: {
                        HStack(spacing: 4) {
                            Text(BrainCatalog.shared.label(for: ClickyModels.main)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.textSecondary).padding(.horizontal, 8).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.hover))
                    }
                    .buttonStyle(.plain).help("Change Clicky's model")
                    Spacer()
                    if pending != nil {
                        Button {
                            ClaudiaControlInbox.shared?.execute(["cmd": "stop"]) { _, _, _ in }
                            pending = nil
                            load()
                        } label: {
                            Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
                                .frame(width: 28, height: 28).background(Circle().fill(DS.Colors.surface))
                                .overlay(Circle().strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                        }
                        .buttonStyle(.plain).help("Stop")
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(draft.trimmingCharacters(in: .whitespaces).isEmpty ? DS.Colors.textDisabled : DS.Colors.accent))
                        }
                        .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty).help("Send")
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .frame(maxWidth: 720)
            .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 4)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            store.viewing = BotsStore.clickyID
            load()
        }
        .onDisappear { if store.viewing == BotsStore.clickyID { store.viewing = nil } }
        // A voice turn, or one the CEO ordered, shows as soon as it's done.
        // Without dropFirst this never settles: each redraw subscribes anew, gets the current state, loads and redraws.
        .onReceive(CompanionManager.current?.$voiceState.dropFirst().eraseToAnyPublisher() ?? Empty<CompanionVoiceState, Never>().eraseToAnyPublisher()) { state in
            if state == .idle { load() }
        }
        .onChange(of: store.delegations.count) { _, _ in load() }
    }

    @ViewBuilder private func messageRow(_ message: BotChatMessage) -> some View {
        if let job = BotsStore.delegationID(of: message).flatMap({ store.delegation($0) }) {
            DelegationCard(job: job)
        } else if message.author == "routine" {
            RoutineMarker(text: message.text, at: message.at)
        } else if let author = store.bot(message.author) {
            // A team report that came up to Clicky.
            BotLine(bot: author, text: message.text, showsName: true, animatesIn: false, isLive: false)
        }
    }

    private func clickyLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ClickyAvatar(size: 34)
            VStack(alignment: .leading, spacing: 4) {
                BotRichText(text: text.isEmpty ? "_(Answered on screen.)_" : text)
                BotMessageActions(text: text).padding(.top, 2)
            }
            .padding(.top, 6)
            Spacer(minLength: 40)
        }
    }

    private func load() {
        ClaudiaControlInbox.shared?.execute(["cmd": "turns", "limit": 30]) { _, result, _ in
            turns = result as? [[String: Any]] ?? []
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pending == nil else { return }
        draft = ""
        pending = text
        ClaudiaControlInbox.shared?.execute(["cmd": "ask", "text": text, "speak": speaks, "owner": true]) { _, _, _ in
            pending = nil
            load()
        }
    }
}
