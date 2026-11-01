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
import SwiftUI

// MARK: - Group editor

struct GroupEditor: View {
    @ObservedObject var store: BotsStore
    @State var group: BotGroup
    /// The saved group, or nil when cancelled.
    let onDone: (BotGroup?) -> Void

    private static let symbols = ["person.2.fill", "person.3.fill", "briefcase.fill", "hammer.fill", "paintpalette.fill",
                                  "film.fill", "magnifyingglass", "envelope.fill", "chart.bar.fill", "sparkles"]
    private var isNew: Bool { group.id.isEmpty }
    /// Like Grok's group chats: two to six bots, the head included.
    private var sizeFits: Bool { (2...6).contains(group.allIDs.count) && group.headID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New group" : "Edit \(group.name)").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                label("Name")
                TextField("Marketing, Research team, Side project…", text: $group.name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                label("Icon")
                HStack(spacing: 6) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Button { group.symbol = symbol } label: {
                            Image(systemName: symbol).font(.system(size: 13))
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8).fill(group.symbol == symbol ? DS.Colors.accent.opacity(0.35) : DS.Colors.hover))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                label("Head")
                Picker("Head", selection: Binding(get: { group.headID ?? "" }, set: { group.headID = $0.isEmpty ? nil : $0 })) {
                    Text("Pick a head").tag("")
                    ForEach(store.bots) { bot in Text(bot.name).tag(bot.id) }
                }
                .labelsHidden()
                Text("The head leads the group chat: they hand your request to the others and merge their answers. Ask them to build something and it goes to T3 Code.")
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
                                    Text(bot.modelLabel).font(.system(size: 11)).foregroundColor(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 220)
                Text(sizeFits ? "\(group.allIDs.count) bots" : "Pick a head and 1 to 5 other bots (2 to 6 in all).")
                    .font(.system(size: 11)).foregroundColor(sizeFits ? .secondary : .orange)
            }
            HStack {
                if !isNew {
                    Button("Delete group", role: .destructive) {
                        store.deleteGroup(group.id)
                        onDone(nil)
                    }
                }
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
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
                .keyboardShortcut(.defaultAction)
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

    static let all: [BotStencil] = [
        BotStencil(id: "blank", name: "Blank", summary: "Start from nothing and write its job yourself.",
                   instructions: "", glyph: "", colour: "slate", apps: []),
        BotStencil(id: "researcher", name: "Researcher", summary: "Digs into a question and answers with sources.",
                   instructions: "Investigate the question, read primary sources, and answer with a short brief that cites them. Say what's uncertain.",
                   glyph: "magnifyingglass", colour: "sky", apps: ["chrome", "theo"]),
        BotStencil(id: "inbox", name: "Inbox assistant", summary: "Sorts your mail and drafts replies for you to send.",
                   instructions: "Read the inbox, group mail into needs-a-reply, FYI and ignore, and draft replies when asked. Never send, delete or label mail.",
                   glyph: "envelope.fill", colour: "rose", apps: ["gmail", "calendar"]),
        BotStencil(id: "builder", name: "Builder", summary: "Plans an app or a fix and hands it to your coding harness.",
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

struct NewBotSheet: View {
    @ObservedObject var store: BotsStore
    let onDone: (NativeBot?) -> Void
    @State private var stencil: BotStencil?
    @State private var name = ""
    @State private var role = ""
    @State private var instructions = ""
    @State private var provider = HarnessPrefs.defaultHarness
    @State private var groupID = ""
    @State private var look = NativeBot(id: "new", name: "", description: "", instructions: "", hue: 205, accentHue: 235,
                                        primary: false, provider: "claude", model: "", effort: nil, apps: [], category: nil, shape: "slate")

    /// The engines a bot can run on, and the model each starts with (changed later in its settings).
    static let engines: [(id: String, label: String, model: String)] = [
        ("claude", "Claude Code", "claude-sonnet-5-5"), ("codex", "Codex", "gpt-5.6-luna"), ("cursor", "Cursor", "auto"),
        ("opencode", "OpenCode", "opencode/deepseek-v4.1-flash-free"), ("grok", "Grok", "grok-4.6"), ("gemini", "Gemini", "gemini-3-pro"),
    ]
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
            HStack { Spacer(); Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction) }
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
            field("Runs on") {
                Picker("Runs on", selection: $provider) {
                    ForEach(installedEngines, id: \.id) { engine in Text(engine.label).tag(engine.id) }
                }
                .pickerStyle(.segmented).labelsHidden()
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
                Button("Back") { stencil = nil }
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Create bot", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(24)
    }

    private func choose(_ item: BotStencil) {
        stencil = item
        name = item.id == "blank" ? "" : item.name
        role = item.id == "blank" ? "" : item.summary
        instructions = item.instructions
        look.shape = item.colour
        look.glyph = item.glyph.isEmpty ? nil : item.glyph
        look.name = name
    }

    private func preview(of item: BotStencil) -> NativeBot {
        var bot = look
        bot.name = item.name
        bot.shape = item.colour
        bot.glyph = item.glyph.isEmpty ? nil : item.glyph
        return bot
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let engine = Self.engines.first { $0.id == provider } ?? Self.engines[0]
        let model = HarnessCenter.shared.resolvedModel(for: engine.id) ?? engine.model
        var bot = store.addBot(name: trimmedName, description: role.isEmpty ? "Your \(trimmedName) bot." : role,
                               instructions: instructions.isEmpty ? "You are \(trimmedName). \(role)" : instructions,
                               provider: engine.id, model: model, groupID: groupID.isEmpty ? nil : groupID)
        bot.shape = look.shape
        bot.glyph = look.glyph
        bot.apps = stencil?.apps ?? []
        bot.effort = HarnessPrefs.defaultEffort(engine.id)
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

/// Clicky's tile: flat ember with the spark-and-cursor mark (docs/DESIGN.md).
struct ClickyAvatar: View {
    let size: CGFloat
    var isActive = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(DS.Colors.accent)
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .overlay {
                // The cursor drifts in a small loop and its rays pulse, like Clicky on screen.
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { timeline in
                    let t = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    Image(systemName: "cursorarrow.rays").font(.system(size: size * 0.46, weight: .semibold)).foregroundColor(.white)
                        .offset(x: cos(t * 1.4) * size * 0.04, y: sin(t * 2.1) * size * 0.04)
                        .scaleEffect(1 + 0.05 * sin(t * 3))
                }
            }
            .overlay {
                if isActive { RoundedRectangle(cornerRadius: size * 0.34, style: .continuous).inset(by: -3).stroke(DS.Colors.accent, lineWidth: 1.5) }
            }
            .frame(width: size, height: size)
    }
}

/// Clicky's own chat, in the bots' style: the same brain as talking to Theo (it sees your screens, points,
/// draws boards and researches), typed instead of spoken.
struct ClickyChatScreen: View {
    @State private var draft = ""
    @State private var turns: [[String: Any]] = []
    @State private var pending: String?
    @State private var speaks = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ClickyAvatar(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Clicky").font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text("Screen companion · \(NativeBot.label(for: ClickyModels.main)) with \(NativeBot.label(for: ClickyModels.helper)) helpers")
                        .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Toggle("Speak answers", isOn: $speaks).toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if turns.isEmpty && pending == nil {
                            VStack(spacing: 12) {
                                ClickyAvatar(size: 84)
                                Text("Clicky").font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                                Text("Ask about what's on your screen, have it point things out, draw a whiteboard, or research a few links.")
                                    .font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 80)
                        }
                        ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                            UserBubble(text: turn["you"] as? String ?? "")
                            clickyLine(turn["claudia"] as? String ?? "")
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
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24).padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: turns.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: pending) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
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
        .onAppear(perform: load)
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
            // The log lists the newest turn first; the chat reads top to bottom.
            turns = (result as? [[String: Any]] ?? []).reversed()
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pending == nil else { return }
        draft = ""
        pending = text
        ClaudiaControlInbox.shared?.execute(["cmd": "ask", "text": text, "speak": speaks]) { _, _, _ in
            pending = nil
            load()
        }
    }
}
