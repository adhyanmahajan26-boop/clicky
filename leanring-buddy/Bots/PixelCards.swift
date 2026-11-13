//
//  PixelCards.swift
//  leanring-buddy
//
//  The small cards for everything a bot asks of the owner (kit/SPEC.md section 6), built on PixelCard: sign in to an app,
//  sign in to a coding agent, a failure in plain words, an app that stopped answering, an API key, a bot that's off, and a
//  yes/no or a choice. Each one folds to a single line once answered, everywhere it shows (PixelCardFolds).
//

import AppKit
import ClickyCore
import SwiftUI

// MARK: - Sign in to an app

/// A bot reached for an app that needs a sign-in. Sign in opens that app's own sign-in (claude.ai's connector page, or
/// OpenCode's); Theo checks again, and once the app answers the card folds and the bot picks the job back up.
struct AppSignInCard: View {
    let bot: NativeBot
    let connector: BotConnector
    @ObservedObject private var health = ConnectorHealth.shared
    @ObservedObject private var folds = PixelCardFolds.shared
    @State private var note: String?
    @State private var checking = false

    private var cardID: String { health.block(of: bot.id).map { ConnectorHealth.cardID(botID: bot.id, block: $0) } ?? "signin:\(bot.id):\(connector.id)" }

    var body: some View {
        if let folded = folds.line(cardID) {
            folded
        } else {
            PixelCard(tone: .needs, lead: .bot(bot, .needs), name: bot.name, context: waitingFor,
                      question: "Sign in to \(connector.name) so \(bot.name) can carry on",
                      buttons: [
                        PixelCardButton(title: checking ? "Checking…" : "Sign in to \(connector.name)", primary: true) { signIn() },
                        PixelCardButton(title: "Not now") {
                            let card = cardID
                            folds.fold(card, did: "You said not now", about: "\(bot.name) won't use \(connector.name) for this", tone: .quiet)
                            health.resolve(bot.id, card: card)
                        },
                      ],
                      foot: note ?? "Opens \(connector.name)'s own sign-in page. Theo never sees your password.") {
                PixelObjectRow(symbol: connector.symbol, name: connector.name, line: Self.scope(connector), pill: (.needs, "Needs sign-in"), badge: .needs)
            }
        }
    }

    private var waitingFor: String {
        guard let at = health.block(of: bot.id)?.at else { return "needs a sign-in" }
        return "waiting " + BotChatScreen.minutes(since: at)
    }

    static func scope(_ connector: BotConnector) -> String {
        if let hub = connector.hub {
            // A hub app: every brain reaches it the same way, and each bot's settings say how far it may go.
            return hub.isClaudeAccount ? "Through your Claude account. Each bot's settings say what it may do." : "Signed in inside Theo. Each bot's settings say what it may do."
        }
        return BotConnectors.bridged(connector) ? "Read and draft only. Never sends or deletes." : "Used by your bots on this Mac."
    }

    private func signIn() {
        checking = true
        Task {
            note = await health.signIn(connector, forBot: bot)
            // Check again shortly, and again when the owner comes back to Theo.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await health.refresh()
            checking = false
        }
    }
}

// MARK: - Sign in to a coding agent

/// The engine a bot runs on is signed out ("Grok isn't signed in"). Sign in runs the agent's own login in Theo's terminal;
/// once it reports signed in, the card folds and the bot's last message goes again.
struct HarnessSignInCard: View {
    let bot: NativeBot
    let harness: HarnessInfo
    let cardID: String
    @ObservedObject private var center = HarnessCenter.shared
    @ObservedObject private var folds = PixelCardFolds.shared
    @State private var terminalTask: HarnessTerminalTask?
    @State private var note: String?

    var body: some View {
        if let folded = folds.line(cardID) {
            folded
        } else {
            PixelCard(tone: .needs, lead: .bot(bot, .needs), name: bot.name, context: "can't start",
                      question: "\(harness.label) is signed out",
                      detail: "\(bot.name) runs on \(harness.label). Sign in once and it picks the job back up.",
                      buttons: [
                        PixelCardButton(title: "Sign in", primary: true) { signIn() },
                        PixelCardButton(title: "Use an API key instead") { BotsSelection.shared.openSettings(.keys) },
                      ],
                      foot: note) {
                PixelObjectRow(symbol: "terminal", name: harness.label, line: HarnessCatalog.setups[harness.id]?.signInHint ?? "Your \(harness.label) account",
                               pill: center.status(for: harness.id).loggedIn == true ? (.ok, "Signed in") : (.needs, "Signed out"), badge: .needs)
            }
            .sheet(item: $terminalTask) { task in
                HarnessTerminalSheet(task: task) {
                    terminalTask = nil
                    center.refresh(force: true)
                }
            }
            .onChange(of: center.status(for: harness.id).loggedIn) { _, signedIn in
                guard signedIn == true, folds.folds[cardID] == nil else { return }
                folds.fold(cardID, did: "Signed in to \(harness.label)", about: "\(bot.name) is trying again")
                BotFailureCardActions.retry(bot: bot)
            }
        }
    }

    private func signIn() {
        // The test profile's agents are the owner's real ones: only a stand-in in the test home's fake-bin may sign in.
        if TheoProfile.isTest, HarnessCatalog.executable(for: harness.id)?.path.contains("/fake-bin/") != true {
            TheoOpen.record("harness sign-in \(harness.id) (held: not a fake-bin agent)")
            note = "In the test profile only a stand-in \(harness.label) may sign in."
            return
        }
        terminalTask = .signIn(harness)
    }
}

// MARK: - Failures

enum BotFailureCardActions {
    /// Retry: the owner's last words to this bot go again, and its red face goes.
    @MainActor
    static func retry(bot: NativeBot) {
        let store = BotsStore.shared
        store.clearFailure(of: bot.id)
        guard let last = store.conversation(bot.id).messages.last(where: { $0.author == "user" }) else { return }
        store.send(last.text, to: bot.id)
    }
}

/// A reply that couldn't happen, in plain words, with one fix and the raw output behind See details.
struct ReplyFailureCard: View {
    let bot: NativeBot
    let message: BotChatMessage
    @ObservedObject private var folds = PixelCardFolds.shared
    @State private var showsDetails = false

    private var cardID: String { "failure:\(message.id)" }
    private var raw: String { message.text.replacingOccurrences(of: "Couldn't reply: ", with: "") }

    var body: some View {
        if let harness = BotFailureWords.signedOutHarness(in: raw) {
            HarnessSignInCard(bot: bot, harness: harness, cardID: cardID)
        } else if let folded = folds.line(cardID) {
            folded
        } else {
            let plain = BotFailureRecord(reason: raw)
            PixelCard(tone: .failed, lead: .bot(bot, .failed), name: bot.name, context: "stopped · " + BotsStore.ago(message.at),
                      question: "\(bot.name) couldn't answer",
                      detail: plain.firstSentence + ". Your message is still here and nothing was lost.",
                      buttons: [
                        PixelCardButton(title: "Try again", primary: true) {
                            folds.fold(cardID, did: "You tried again", about: plain.firstSentence)
                            BotFailureCardActions.retry(bot: bot)
                        },
                        PixelCardButton(title: showsDetails ? "Hide details" : "See details") { withAnimation(DS.Motion.hover) { showsDetails.toggle() } },
                      ]) {
                if showsDetails { FailureDetails(text: raw) }
            }
        }
    }
}

/// The raw output, only when asked for.
struct FailureDetails: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundColor(PixelTone.failed.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(.theo(.ghost, .small))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
    }
}

/// An app a bot uses stopped answering ("Can't reach Gmail"): when it last worked, Try again and Open Connectors.
struct ConnectorFailedCard: View {
    let connector: BotConnector
    var bot: NativeBot? = nil
    let reason: String
    @ObservedObject private var health = ConnectorHealth.shared
    @ObservedObject private var folds = PixelCardFolds.shared
    @State private var showsDetails = false

    /// The same id ConnectorHealth folds when the app answers again, so either way it folds once.
    private var cardID: String {
        if let bot, let block = health.block(of: bot.id) { return ConnectorHealth.cardID(botID: bot.id, block: block) }
        return "connector-failed:\(connector.id):\(bot?.id ?? "")"
    }

    var body: some View {
        if let folded = folds.line(cardID) {
            folded
        } else {
            let worked = health.lastConnected[connector.id].map { ConnectorListing.workedAgo($0) }
            PixelCard(tone: .failed, lead: bot.map { .bot($0, .failed) } ?? .connector(connector, .failed), name: bot?.name ?? connector.name,
                      context: health.lastChecked.map { BotsStore.ago($0) },
                      question: "Can't reach \(connector.name)",
                      detail: ConnectorListing.plainReason(reason, app: connector.name) + (worked.map { " It \($0), so this is probably temporary." } ?? ""),
                      buttons: [
                        PixelCardButton(title: health.isChecking ? "Checking…" : "Try again", primary: true) {
                            Task {
                                await health.refresh()
                                guard [.connected, .claudeOnly, .othersOnly].contains(health.state(of: connector)) else { return }
                                if folds.folds[cardID] == nil { folds.fold(cardID, did: "\(connector.name) answers again", about: bot.map { "\($0.name) can carry on" }) }
                                if let bot { BotsStore.shared.clearFailure(of: bot.id) }
                            }
                        },
                        PixelCardButton(title: "Open Connectors") { BotsSelection.shared.pane = .connectors },
                        PixelCardButton(title: showsDetails ? "Hide details" : "See details", plain: true) { showsDetails.toggle() },
                      ]) {
                PixelObjectRow(symbol: connector.symbol, name: connector.name, line: worked.map { "Last connected " + $0.replacingOccurrences(of: "worked ", with: "") } ?? "Not seen connected yet",
                               pill: (.failed, "Can't connect"), badge: .failed)
                if showsDetails { FailureDetails(text: reason) }
            }
        }
    }
}

// MARK: - API key

/// Dictation needs a Sarvam key. Saving it here unblocks Dictation everywhere, and the card folds.
struct SarvamKeyCard: View {
    @ObservedObject private var products = TheoProducts.shared
    @ObservedObject private var folds = PixelCardFolds.shared
    private let cardID = "key:sarvam"

    var body: some View {
        if products.dictationAccess == .ready {
            folds.line(cardID) ?? PixelFoldedLine(tone: .ok, did: "Sarvam key saved", about: "Dictation is ready")
        } else {
            PixelCard(tone: .needs, lead: .app(symbol: "mic.fill", state: .needs), name: "Dictation", context: "blocked",
                      question: "Dictation needs a Sarvam API key",
                      foot: "Keys stay in your Keychain.") {
                SarvamKeyField()
            }
        }
    }
}

// MARK: - A Mac permission

/// A permission Theo needs and doesn't have. Only the owner can flip the switch in System Settings.
struct PermissionCard: View {
    let title: String
    let detail: String
    let symbol: String
    let isAsked: Bool
    let open: () -> Void

    var body: some View {
        PixelCard(tone: .needs, lead: .look(BotsStore.shared.clickyBot.crewLook, .needs), name: "Clicky", context: "can't \(detail.lowercased()) yet",
                  question: "Turn on \(title) for Theo",
                  buttons: [PixelCardButton(title: isAsked ? "Open System Settings" : "Allow", primary: true, action: open)],
                  foot: "Only you can flip this switch. Theo picks it up as soon as you do.") {
            PixelObjectRow(symbol: symbol, name: title, line: "In System Settings › Privacy & Security", pill: isAsked ? (.needs, "Needs you") : (.quiet, "Not asked"), badge: .needs)
        }
    }
}

// MARK: - A bot that's off

struct BotOffCard: View {
    let bot: NativeBot

    var body: some View {
        PixelCard(tone: .quiet, lead: .bot(bot, .off), name: bot.name, context: "switched off",
                  question: "This bot is off",
                  detail: "It keeps its memory and routines. Turn it on to give it work.",
                  buttons: [PixelCardButton(title: "Turn on") { BotsStore.shared.setEnabled(true, botID: bot.id) }])
    }
}

// MARK: - A yes or no, or a choice

/// A bot's [CHOOSE: …] question. Two or three short options are buttons (a yes or no); longer ones are radio rows with one
/// button. Left alone with the chat open it picks the highlighted option after ten minutes; a stale card waits.
struct BotCallCard: View {
    let call: BotCallPrompt
    let author: NativeBot
    let at: Date
    /// False once the owner has replied after it.
    let isOpen: Bool
    /// Only the chat itself picks by itself after ten minutes; Home and the menu bar wait for the owner.
    var autoPicks = false
    let onAnswer: (String) -> Void
    @State private var picked = 0
    @ObservedObject private var folds = PixelCardFolds.shared

    private var cardID: String { "call:\(author.id):\(Int(at.timeIntervalSince1970))" }
    private var deadline: Date { at.addingTimeInterval(Double(BotCallPrompt.autoPickMinutes) * 60) }
    /// Short options with nothing to explain are answers in themselves.
    private var isYesOrNo: Bool { call.options.count <= 3 && call.options.allSatisfy { $0.detail.isEmpty && $0.title.count <= 22 } }

    var body: some View {
        if let folded = folds.line(cardID) {
            folded
        } else if !isOpen {
            PixelFoldedLine(tone: .quiet, did: "You answered", about: call.question, at: at)
        } else {
            PixelCard(tone: .needs, lead: .bot(author, .needs), name: author.name, context: "waiting " + BotChatScreen.minutes(since: at),
                      question: call.question,
                      buttons: isYesOrNo ? call.options.enumerated().map { index, option in
                          PixelCardButton(title: option.title, primary: index == 0) { answer(option.title) }
                      } : [PixelCardButton(title: "Use this", primary: true) { answer(call.options[picked].title) },
                           PixelCardButton(title: "Skip", plain: true) { answer("Skip this one for now.") }],
                      foot: countdown(now: Date())) {
                if !isYesOrNo {
                    VStack(spacing: 6) {
                        ForEach(Array(call.options.enumerated()), id: \.offset) { index, option in
                            PixelRadioRow(title: option.title, detail: option.detail, isOn: picked == index) { picked = index }
                        }
                    }
                }
            }
            .task(id: isOpen) {
                guard autoPicks else { return }
                let wait = deadline.timeIntervalSinceNow
                // An old card reopened hours later doesn't decide anything by itself.
                guard wait > -3600 else { return }
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard !Task.isCancelled, isOpen, folds.folds[cardID] == nil else { return }
                answer(call.options[picked].title)
            }
        }
    }

    private func answer(_ text: String) {
        guard folds.folds[cardID] == nil else { return }
        folds.fold(cardID, did: text.hasPrefix("Skip") ? "You skipped this" : "You said \(text)", about: call.question, tone: text.hasPrefix("Skip") ? .quiet : .ok)
        onAnswer(text)
    }

    private func countdown(now: Date) -> String {
        guard autoPicks else { return "\(author.name) waits for you. Your other bots keep working." }
        let minutes = Int((deadline.timeIntervalSince(now) / 60).rounded(.up))
        return minutes > 0 ? "\(author.name) picks the first one in \(minutes) min if you don't. Your other bots keep working." : "\(author.name) waits here. Your other bots keep working."
    }
}

// MARK: - In a bot's chat

/// What a bot is stuck on, at the end of its chat: an app sign-in, an app that isn't answering, or that it's off.
struct ChatStatusCards: View {
    let bot: NativeBot
    @ObservedObject private var health = ConnectorHealth.shared
    @ObservedObject private var folds = PixelCardFolds.shared

    var body: some View {
        // The last answered sign-in stays as its folded line.
        if health.block(of: bot.id) == nil, let card = health.resolved[bot.id], let line = folds.line(card) { line }
        if !bot.isOn {
            BotOffCard(bot: bot)
        } else if let connector = health.blockingConnector(of: bot.id) {
            AppSignInCard(bot: bot, connector: connector)
            Text("\(bot.name) waits here. Your other bots keep working.").font(.system(size: 11.5)).foregroundColor(DS.Colors.textTertiary)
        } else if let failed = health.failedConnector(of: bot.id) {
            ConnectorFailedCard(connector: failed.connector, bot: bot, reason: failed.reason)
        }
    }
}
