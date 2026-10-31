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
                                .background(RoundedRectangle(cornerRadius: 8).fill(group.symbol == symbol ? DS.Colors.accent.opacity(0.35) : Color.white.opacity(0.06)))
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

struct NewBotSheet: View {
    @ObservedObject var store: BotsStore
    let onDone: (NativeBot?) -> Void
    @State private var name = ""
    @State private var role = ""
    @State private var instructions = ""
    @State private var provider = "opencode"
    @State private var groupID = ""
    @State private var look = NativeBot(id: "new", name: "", description: "", instructions: "", hue: 205, accentHue: 235,
                                        primary: false, provider: "opencode", model: "", effort: nil, apps: [], category: nil, shape: "orb")

    private static let models = ["claude": "claude-sonnet-5-5", "opencode": "opencode/deepseek-v4.1-flash-free", "grok": "grok-4.6"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New bot").font(.system(size: 17, weight: .semibold))
            field("Name") { TextField("Travel Planner, SEO Writer…", text: $name).textFieldStyle(.roundedBorder) }
            field("Look") { BotLookPicker(bot: $look) }
            field("What it does") { TextField("One line, shown under its name", text: $role).textFieldStyle(.roundedBorder) }
            field("Instructions") {
                TextEditor(text: $instructions)
                    .font(.system(size: 12.5))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
            field("Engine") {
                Picker("Engine", selection: $provider) {
                    Text("Claude").tag("claude")
                    Text("OpenCode (free)").tag("opencode")
                    Text("Grok").tag("grok")
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            field("Group chat") {
                Picker("Group chat", selection: $groupID) {
                    Text("None").tag("")
                    ForEach(store.groups) { group in Text(group.name).tag(group.id) }
                }
                .labelsHidden()
            }
            Text("You can change its model, effort and apps afterwards from Model settings in its chat.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Create bot") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    var bot = store.addBot(
                        name: trimmedName,
                        description: role.isEmpty ? "Your \(trimmedName) bot." : role,
                        instructions: instructions.isEmpty ? "You are \(trimmedName). \(role)" : instructions,
                        provider: provider, model: Self.models[provider] ?? "claude-sonnet-5-5",
                        groupID: groupID.isEmpty ? nil : groupID)
                    bot.shape = look.shape
                    bot.hue = look.hue
                    bot.accentHue = look.accentHue
                    store.save(bot)
                    onDone(bot)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.secondary)
            content()
        }
    }
}

// MARK: - Clicky

/// Clicky's face in the bots list: Theo's gradient spark with a cursor.
struct ClickyAvatar: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 0.93, green: 0.27, blue: 0.45),
                                              Color(red: 0.75, green: 0.27, blue: 0.9)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.78, height: size * 0.78)
                .shadow(color: Color(red: 0.93, green: 0.27, blue: 0.45).opacity(0.45), radius: size * 0.12)
            Image(systemName: "cursorarrow.rays").font(.system(size: size * 0.36, weight: .semibold)).foregroundColor(.white)
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
            Divider().overlay(Color.white.opacity(0.06))
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
                            HStack(spacing: 12) {
                                ClickyAvatar(size: 34)
                                ProgressView().controlSize(.small)
                                Text("Clicky is on it").font(.system(size: 13)).foregroundColor(DS.Colors.textTertiary)
                            }
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
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Clicky", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...6)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(draft.trimmingCharacters(in: .whitespaces).isEmpty || pending != nil ? Color.white.opacity(0.12) : DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || pending != nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 22).fill(DS.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.07)))
            .frame(maxWidth: 760)
            .padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 6)
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
