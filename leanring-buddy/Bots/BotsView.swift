//
//  BotsView.swift
//  leanring-buddy
//
//  The Bots window: the team chat, one ongoing chat per bot, and the
//  Connectors page. Chats show only messages; while a bot thinks its avatar
//  floats and tilts, and while it replies the words type in behind a comet
//  caret in the bot's colour.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

enum BotsPane: Hashable {
    case team
    case bot(String)
    case connectors
}

@MainActor
final class BotsSelection: ObservableObject {
    static let shared = BotsSelection()
    @Published var pane: BotsPane = .team
}

struct BotsRootView: View {
    @ObservedObject var store: BotsStore
    @ObservedObject var selection: BotsSelection
    /// Inside Theo's home window, Connectors is its own tab instead.
    var showsConnectors = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.white.opacity(0.06))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Project handlers")
            sidebarRow(.team, title: "Project room", subtitle: "Theo leads \(store.projectBots.count - 1) bots") {
                ZStack {
                    Circle().fill(DS.Colors.accent.opacity(0.18))
                    Image(systemName: "person.3.fill").font(.system(size: 13)).foregroundColor(DS.Colors.accentText)
                }
                .frame(width: 34, height: 34)
            }
            ForEach(store.projectBots) { bot in botRow(bot) }
            sectionTitle("Personal").padding(.top, 8)
            ForEach(store.personalBots) { bot in botRow(bot) }
            Spacer()
            if showsConnectors {
            sidebarRow(.connectors, title: "Connectors", subtitle: "Gmail, Notion and more") {
                ZStack {
                    Circle().fill(Color.white.opacity(0.08))
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary)
                }
                .frame(width: 34, height: 34)
            }
            .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 240)
        .background(DS.Colors.surface1)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 2)
    }

    private func botRow(_ bot: NativeBot) -> some View {
        sidebarRow(.bot(bot.id), title: bot.primary ? "\(bot.name) · CEO" : bot.name, subtitle: bot.modelLabel) {
            BotAvatar(bot: bot, size: 34, state: store.replying[bot.id].map { $0.isEmpty ? .thinking : .typing } ?? .idle)
        }
    }

    private func sidebarRow<Icon: View>(_ pane: BotsPane, title: String, subtitle: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button { selection.pane = pane } label: {
            HStack(spacing: 10) {
                icon()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(selection.pane == pane ? Color.white.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var detail: some View {
        switch selection.pane {
        case .team:
            BotChatScreen(store: store, conversationID: BotsStore.teamID, bot: nil)
        case .bot(let id):
            if let bot = store.bot(id) {
                BotChatScreen(store: store, conversationID: id, bot: bot).id(id)
            }
        case .connectors:
            ConnectorsScreen(bots: store.bots)
        }
    }
}

// MARK: - Chat

struct BotChatScreen: View {
    @ObservedObject var store: BotsStore
    let conversationID: String
    /// Nil for the team chat.
    let bot: NativeBot?
    @State private var draft = ""
    /// Replies that were there when the chat opened show at once; new ones type in.
    @State private var settledIDs: Set<String> = []
    @State private var showsModelSettings = false

    private var record: BotConversationRecord { store.conversation(conversationID) }
    private var inProgress: [(NativeBot, String)] {
        let ids = bot.map { [$0.id] } ?? store.projectBots.map(\.id)
        return ids.compactMap { id in store.replying[id].flatMap { text in store.bot(id).map { ($0, text) } } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.06))
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain VStack: a lazy one guesses the heights of long replies it hasn't drawn, and
                    // scrolling to the end then lands in empty space until something redraws.
                    VStack(alignment: .leading, spacing: 18) {
                        if record.messages.isEmpty && inProgress.isEmpty { emptyState }
                        ForEach(record.messages) { message in
                            if message.author == "user" {
                                UserBubble(text: message.text)
                            } else if let author = store.bot(message.author) {
                                BotLine(bot: author, text: message.text, showsName: bot == nil,
                                        animatesIn: !settledIDs.contains(message.id), isLive: false)
                                if let runID = message.runID, let run = store.t3Runs.first(where: { $0.id == runID }) {
                                    T3ResultCard(run: run).padding(.leading, 46)
                                }
                                if let prompt = BotsT3.promptBlock(in: message.text) {
                                    let title = BotsT3.projectTitle(in: message.text, prompt: prompt)
                                    T3HandoffButton(text: message.text, prominent: true,
                                                    alreadySent: store.t3Runs.contains { $0.title == title }
                                                        || record.messages.contains { $0.text.hasPrefix("Submitted to T3 Code: **\(title)**") })
                                }
                            }
                        }
                        if bot == nil {
                            ForEach(store.t3Runs.filter { $0.phase == "running" || $0.phase == "waiting" }) { run in
                                T3RunCard(run: run)
                            }
                        }
                        ForEach(inProgress, id: \.0.id) { pending in
                            if pending.1.isEmpty {
                                ThinkingLine(bot: pending.0, showsName: bot == nil)
                            } else {
                                BotLine(bot: pending.0, text: pending.1, showsName: bot == nil, animatesIn: true, isLive: true)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24).padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: record.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: inProgress.map(\.1.count).reduce(0, +)) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onAppear {
                    settledIDs = Set(record.messages.map(\.id))
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let bot {
                BotAvatar(bot: bot, size: 28, state: store.replying[bot.id].map { $0.isEmpty ? .thinking : .typing } ?? .idle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.name).font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text("\(["claude": "Claude", "grok": "Grok"][bot.provider] ?? "OpenCode") · \(bot.modelLabel)\(bot.effort.map { " · \($0)" } ?? "")")
                        .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                }
            } else {
                HStack(spacing: -8) {
                    ForEach(store.projectBots) { member in BotAvatar(bot: member, size: 24, state: .idle) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Project room").font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text("Theo (CEO) and the project team turn your idea into a prompt for T3 Code")
                        .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer()
            if let bot {
                Button { showsModelSettings = true } label: {
                    Label("Model settings", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless).foregroundColor(DS.Colors.textSecondary).font(.system(size: 12))
                .popover(isPresented: $showsModelSettings, arrowEdge: .bottom) {
                    BotModelSettings(bot: bot) { store.save($0) }
                }
            }
            Button("New chat") {
                store.clearConversation(conversationID)
                settledIDs = []
            }
            .buttonStyle(.borderless).foregroundColor(DS.Colors.textSecondary).font(.system(size: 12))
            .disabled(!inProgress.isEmpty)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if let bot {
                BotAvatar(bot: bot, size: 84, state: .idle)
                Text(bot.name).font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text(bot.description).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center)
            } else {
                Text("Pitch an idea to the project team").font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text("Theo, your CEO, brings in the Project Manager, Design Critic and Code Improver, then writes one prompt you can send to T3 Code.")
                    .font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if bot == nil {
                HStack(spacing: 6) {
                    ForEach(store.projectBots) { member in
                        Button { draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + "@\(member.name) " } label: {
                            HStack(spacing: 4) {
                                BotAvatar(bot: member, size: 16, state: .idle)
                                Text("@\(member.name)").font(.system(size: 11))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain).foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(bot.map { "Message \($0.name)" } ?? "Pitch an idea to Theo and the team", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .onSubmit(send)
                if !inProgress.isEmpty && draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        if let bot { store.stop(bot.id) } else { store.stopTeam() }
                    } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .help("Stop the reply")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.12) : DS.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 22).fill(DS.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.07)))
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 6)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if let bot { store.send(text, to: bot.id) } else { store.sendToTeam(text) }
    }
}

struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text)
                .font(.system(size: 14)).foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 15).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.1)))
        }
    }
}

struct ThinkingLine: View {
    let bot: NativeBot
    let showsName: Bool
    @State private var sweep = false

    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(bot: bot, size: 34, state: .thinking)
            OrbitingDots(color: bot.accentColor)
            Text("\(bot.name) is thinking")
                .font(.system(size: 13))
                .foregroundStyle(
                    LinearGradient(colors: [DS.Colors.textTertiary, bot.accentColor, DS.Colors.textTertiary],
                                   startPoint: UnitPoint(x: sweep ? 1 : -1, y: 0.5), endPoint: UnitPoint(x: sweep ? 2 : 0, y: 0.5)))
                .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweep = true } }
        }
    }
}

struct BotLine: View {
    let bot: NativeBot
    let text: String
    let showsName: Bool
    /// New replies type in; old ones show at once.
    let animatesIn: Bool
    /// Still streaming from the engine.
    let isLive: Bool
    @State private var shown = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BotAvatar(bot: bot, size: 34, state: isTyping ? .typing : .idle)
            VStack(alignment: .leading, spacing: 4) {
                if showsName {
                    Text(bot.name).font(.system(size: 11.5, weight: .semibold)).foregroundColor(bot.accentColor)
                }
                if isTyping {
                    (Text(String(text.prefix(shown))) + Text(" ")).font(.system(size: 14)).foregroundColor(DS.Colors.textPrimary)
                        .overlay(alignment: .bottomTrailing) { CometCaret(color: bot.accentColor).offset(x: 10, y: -4) }
                } else {
                    BotRichText(text: text)
                    if !isLive { BotMessageActions(text: text).padding(.top, 2) }
                }
            }
            .padding(.top, 6)
            Spacer(minLength: 40)
        }
        .task(id: text.count) { await typeOut() }
        .onAppear { if !animatesIn { shown = text.count } }
    }

    private var isTyping: Bool { animatesIn && (isLive || shown < text.count) }

    /// Reveals the text a few characters per frame, faster when far behind the stream.
    private func typeOut() async {
        guard animatesIn else { shown = text.count; return }
        while shown < text.count {
            let left = text.count - shown
            shown += max(1, left / 22)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }
}

/// Inline Markdown (bold, italics, code, links) for finished replies.
enum BotMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Motion

enum BotAvatarState { case idle, thinking, typing }

extension NativeBot {
    var bodyColor: Color { Color(hue: hue / 360, saturation: 0.62, brightness: 0.82) }
    var accentColor: Color { Color(hue: accentHue.truncatingRemainder(dividingBy: 360) / 360, saturation: 0.7, brightness: 0.95) }
}

/// A bot's face: a glowing orb with eyes and an orbit ring. Thinking, it floats and tilts while
/// the ring spins fast; typing, it nods along.
struct BotAvatar: View {
    let bot: NativeBot
    let size: CGFloat
    let state: BotAvatarState
    @State private var phase = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [bot.accentColor, bot.bodyColor, bot.bodyColor.opacity(0.7)],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.6))
                .frame(width: size * 0.66, height: size * 0.66)
                .shadow(color: bot.accentColor.opacity(state == .idle ? 0.25 : 0.7), radius: state == .idle ? 3 : size * 0.18)
            HStack(spacing: size * 0.1) {
                Capsule().fill(Color.black.opacity(0.75)).frame(width: size * 0.07, height: size * (state == .thinking && phase ? 0.05 : 0.12))
                Capsule().fill(Color.black.opacity(0.75)).frame(width: size * 0.07, height: size * (state == .thinking && phase ? 0.05 : 0.12))
            }
            .offset(x: state == .thinking ? (phase ? size * 0.05 : -size * 0.05) : 0, y: -size * 0.02)
            Ellipse()
                .stroke(bot.accentColor.opacity(0.75), lineWidth: max(1, size * 0.035))
                .frame(width: size * 0.98, height: size * 0.34)
                .rotationEffect(.degrees(-18))
                .overlay(
                    Circle().fill(bot.accentColor).frame(width: size * 0.09, height: size * 0.09)
                        .offset(x: size * 0.49)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .scaleEffect(x: 1, y: 0.34)
                        .rotationEffect(.degrees(-18))
                )
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if size >= 24 {
                // The bot's role, so bots of similar colour are told apart at a glance.
                Image(systemName: bot.symbol)
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: size * 0.38, height: size * 0.38)
                    .background(Circle().fill(bot.bodyColor.opacity(0.95)))
                    .overlay(Circle().stroke(DS.Colors.background, lineWidth: max(1.5, size * 0.04)))
                    .offset(x: size * 0.04, y: size * 0.04)
            }
        }
        .rotationEffect(.degrees(state == .thinking ? (phase ? 9 : -9) : 0))
        .offset(y: state == .thinking ? (phase ? -size * 0.08 : size * 0.02) : 0)
        .scaleEffect(x: 1, y: state == .typing && phase ? 1.05 : 1, anchor: .bottom)
        .onAppear { restart() }
        .onChange(of: state) { _, _ in restart() }
    }

    private func restart() {
        phase = false
        spin = false
        let duration: Double = state == .thinking ? 0.9 : state == .typing ? 0.22 : 3.2
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) { phase = state != .idle }
        withAnimation(.linear(duration: state == .idle ? 6 : 1.1).repeatForever(autoreverses: false)) { spin = true }
    }
}

/// Three moons circling while a bot thinks.
struct OrbitingDots: View {
    let color: Color
    @State private var turning = false
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(color.opacity(1 - Double(index) * 0.28)).frame(width: 5, height: 5)
                    .offset(y: -7).rotationEffect(.degrees(Double(index) * 120))
            }
        }
        .frame(width: 18, height: 18)
        .rotationEffect(.degrees(turning ? 360 : 0))
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { turning = true } }
    }
}

/// The glowing dot that leads typed text.
struct CometCaret: View {
    let color: Color
    @State private var pulse = false
    var body: some View {
        Circle().fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color, radius: pulse ? 7 : 3)
            .shadow(color: color.opacity(0.5), radius: 10, x: -6)
            .scaleEffect(pulse ? 0.65 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

// MARK: - Connectors

struct ConnectorsScreen: View {
    let bots: [NativeBot]
    @State private var claude: [String: BotConnectors.Status] = [:]
    @State private var openCode: [String: BotConnectors.Status] = [:]
    @State private var checking = true
    @State private var note: String?
    @State private var working: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connectors").font(.system(size: 18, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text("Bots on Claude use your claude.ai connectors. Bots on OpenCode and Grok reach Gmail, Notion and Google through Theo, on the same account, for reading and drafts.")
                        .font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Button(checking ? "Checking…" : "Refresh") { Task { await refresh() } }
                    .disabled(checking).buttonStyle(.borderless).foregroundColor(DS.Colors.textSecondary)
            }
            .padding(20)
            if let note {
                Text(note).font(.system(size: 12)).foregroundColor(DS.Colors.accentText).padding(.horizontal, 20).padding(.bottom, 8)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(BotConnectors.known.filter { $0.id != "calendar" }) { connector in row(connector) }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .task { await refresh() }
    }

    private func row(_ connector: BotConnector) -> some View {
        let users = bots.filter { $0.apps.contains(connector.id) || (connector.id == "notion" && $0.apps.contains("calendar")) }
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07))
                Image(systemName: connector.symbol).font(.system(size: 14)).foregroundColor(DS.Colors.textSecondary)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(connector.name).font(.system(size: 13.5, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                Text(users.isEmpty ? "No bot uses it yet" : "Used by " + users.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            if connector.isSkill {
                badge("Skills", .connected)
            } else {
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Claude").font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary)
                        badge(status(claude, connector.claudeServer), status(claude, connector.claudeServer))
                        if !checking && status(claude, connector.claudeServer) != .connected && connector.claudeServer?.hasPrefix("claude.ai") == true {
                            Button("Connect") { BotConnectors.openClaudeConnectors() }.buttonStyle(.borderless).font(.system(size: 11))
                        }
                    }
                    HStack(spacing: 6) {
                        Text("OpenCode & Grok").font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary)
                        if BotConnectors.bridged(connector) && status(openCode, connector.openCodeServer) != .connected {
                            // Reached through Theo's claudia_app tool on the Claude account, read-only.
                            let viaClaude = status(claude, connector.claudeServer)
                            badge(viaClaude == .connected ? "Via Claude" : viaClaude.label, viaClaude)
                        } else {
                            badge(status(openCode, connector.openCodeServer), status(openCode, connector.openCodeServer))
                        }
                        if !checking && !BotConnectors.bridged(connector) && status(openCode, connector.openCodeServer) != .connected && connector.openCodeURL != nil {
                            Button(working == connector.id ? "Signing in…" : "Connect") {
                                working = connector.id
                                Task {
                                    note = await BotConnectors.addToOpenCode(connector)
                                    working = nil
                                    await refresh()
                                }
                            }
                            .buttonStyle(.borderless).font(.system(size: 11)).disabled(working != nil)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.surface1))
    }

    private func status(_ map: [String: BotConnectors.Status], _ name: String?) -> BotConnectors.Status {
        guard let name else { return .missing }
        if checking && map.isEmpty { return .unknown }
        return map[name] ?? .missing
    }

    private func badge(_ status: BotConnectors.Status, _ tone: BotConnectors.Status) -> some View {
        badge(status.label, tone)
    }

    private func badge(_ label: String, _ tone: BotConnectors.Status) -> some View {
        let color: Color = tone == .connected ? .green : tone == .needsSignIn ? .orange : tone == .unknown ? .gray : Color.white.opacity(0.4)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func refresh() async {
        checking = true
        async let claudeListing = BotConnectors.listing(.claude)
        async let openCodeListing = BotConnectors.listing(.opencode)
        let (claudeText, openCodeText) = await (claudeListing, openCodeListing)
        claude = BotConnectors.parseClaude(claudeText)
        openCode = BotConnectors.parseOpenCode(openCodeText)
        checking = false
    }
}

// MARK: - Hand-off to T3 Code

struct T3HandoffButton: View {
    let text: String
    let prominent: Bool
    var alreadySent = false
    @State private var sentHere = false
    private var sent: Bool { sentHere || alreadySent }

    var body: some View {
        HStack {
            Spacer().frame(width: 46)
            Button {
                let prompt = BotsT3.promptBlock(in: text) ?? text
                BotsStore.shared.submitToT3(prompt: prompt, title: BotsT3.projectTitle(in: text, prompt: prompt))
                sentHere = true
            } label: {
                Label(sent ? "Submitted to T3 Code" : (BotsT3.promptBlock(in: text) != nil ? "Submit prompt to T3 Code" : "Submit to T3 Code"),
                      systemImage: sent ? "checkmark" : "arrow.up.forward.app")
                    .font(.system(size: prominent ? 12 : 11, weight: prominent ? .semibold : .regular))
                    .padding(.horizontal, prominent ? 12 : 0).padding(.vertical, prominent ? 6 : 0)
                    .background(Capsule().fill(prominent ? DS.Colors.accent.opacity(0.9) : .clear))
                    .foregroundColor(prominent ? .white : DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(sent)
            Spacer()
        }
    }
}

/// A coding run in T3 Code while it works: what it's on, for how long, and a way to watch it there.
struct T3RunCard: View {
    let run: T3Run

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Spacer().frame(width: 34)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(alignment: .top, spacing: 10) {
                    if run.phase == "waiting" {
                        Image(systemName: "questionmark.bubble").foregroundColor(.orange)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        let minutes = max(0, Int(context.date.timeIntervalSince(run.startedAt) / 60))
                        Text(run.phase == "waiting" ? "\(run.title): waiting for your answer (@T3)"
                                                    : "\(BotsT3.modelName) is coding \(run.title) · \(minutes) min")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        if let activity = run.activity, !activity.isEmpty {
                            Text(activity).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(2)
                        }
                        if run.link != nil {
                            Button("Watch in T3 Code") { BotsT3.openInApp(run) }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }
        }
    }
}

/// A bot's engine, model, effort, thinking and fast mode. Changes save as they're made and apply from
/// the bot's next reply.
struct BotModelSettings: View {
    @State var bot: NativeBot
    let onChange: (NativeBot) -> Void
    @ObservedObject private var catalog = BrainCatalog.shared

    private static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    private static let openCodeEfforts = ["minimal", "low", "medium", "high", "max"]

    private var isClaude: Bool { bot.provider == "claude" }

    private static let grokModels = ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"]
    private static let grokEfforts = ["low", "medium", "high"]

    private var models: [String] {
        let listed = bot.provider == "grok" ? Self.grokModels : catalog.models[isClaude ? .claude : .opencode] ?? []
        return listed.contains(bot.model) ? listed : [bot.model] + listed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BotAvatar(bot: bot, size: 26, state: .idle)
                Text("\(bot.name) · model").font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            }
            row("Engine") {
                Picker("Engine", selection: Binding(get: { bot.provider }, set: { provider in
                    bot.provider = provider
                    bot.model = ["claude": "claude-sonnet-5-5", "grok": "grok-4.6"][provider] ?? "opencode/deepseek-v4.1-flash-free"
                    bot.effort = nil
                    commit()
                })) {
                    Text("Claude").tag("claude")
                    Text("OpenCode").tag("opencode")
                    Text("Grok").tag("grok")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            row("Model") {
                Picker("Model", selection: Binding(get: { bot.model }, set: { bot.model = $0; commit() })) {
                    ForEach(models, id: \.self) { model in
                        Text(NativeBot.label(for: model)).tag(model)
                    }
                }
                .labelsHidden().frame(width: 260)
            }
            row("Effort") {
                Picker("Effort", selection: Binding(get: { bot.effort ?? "" }, set: { bot.effort = $0.isEmpty ? nil : $0; commit() })) {
                    Text("Default").tag("")
                    ForEach(isClaude ? Self.claudeEfforts : bot.provider == "grok" ? Self.grokEfforts : Self.openCodeEfforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden().frame(width: 160)
            }
            row("Thinking") {
                Toggle("Thinking", isOn: Binding(get: { bot.thinking ?? false }, set: { bot.thinking = $0; commit() }))
                    .toggleStyle(.switch).labelsHidden().disabled(!isClaude)
            }
            row("Fast mode") {
                Toggle("Fast mode", isOn: Binding(get: { bot.fast ?? false }, set: { bot.fast = $0; commit() }))
                    .toggleStyle(.switch).labelsHidden().disabled(!isClaude)
            }
            Text(isClaude ? "Applies from the next reply." : "Thinking and fast mode are for Claude models. \(bot.provider == "grok" ? "Grok takes the effort as its reasoning effort." : "OpenCode takes the effort as the model's variant.")")
                .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 400)
        .onAppear { catalog.load() }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary).frame(width: 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func commit() { onChange(bot) }
}
