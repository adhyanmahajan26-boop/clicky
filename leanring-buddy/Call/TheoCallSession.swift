//
//  TheoCallSession.swift
//  leanring-buddy
//
//  A voice call with Theo, like ChatGPT's voice mode.
//
//    mic → voice gate → ears (Sarvam or Apple) → Theo's brain on Sonnet, streaming → voice (Sarvam or Apple) → speaker
//
//  Theo's reply goes to the voice clause by clause as it's written (CallSpeechChunker), so the first sound comes well before the sentence is
//  finished. When the owner talks over it the voice stops at once, the brain's turn is interrupted and what was heard counts as
//  the next turn. Hindi, English and Hinglish: the ears work out which, and Theo answers in kind. The transcript lands in
//  Theo's chat when the call ends, so the chat knows what was said.
//

import ClickyCore
import Combine
import Foundation
import AVFoundation

enum CallSettings {
    static let modelKey = "v2.call.model"
    static let languageKey = "v2.call.language"
    static let hearKey = "v2.call.ears"

    /// What calls think with. Unset: Claude Sonnet when Claude Code is ready (as calls always were), else Clicky's own
    /// brain, else whatever this Mac can think with.
    static var model: String {
        let saved = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty { return saved }
        return automaticModel
    }

    /// The model a call uses when none was picked.
    static var automaticModel: String {
        if BrainAvailability.isClaudeReady { return ClickyModels.sonnet }
        return BrainAvailability.startingModel(current: ClickyModels.main) ?? ClickyModels.sonnet
    }

    enum Language: String, CaseIterable, Identifiable {
        case auto, hinglish, english, hindi
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Auto"
            case .hinglish: return "Hinglish"
            case .english: return "English"
            case .hindi: return "Hindi"
            }
        }
        /// The computer's first preferred language ("en-US", "en-GB", "hi-IN"…): where "auto" starts.
        static var computerLanguage: String? { Locale.preferredLanguages.first }

        /// "Auto" on a Mac set to Hindi or an Indian region is the Hindi / English / Hinglish mix; elsewhere it's the
        /// computer's own language.
        var meansHinglish: Bool {
            switch self {
            case .hinglish: return true
            case .auto: return ComputerLanguage.isIndian(preferredLanguage: Self.computerLanguage)
            case .english, .hindi: return false
            }
        }

        /// What Apple's recognizer should expect.
        var appleLocale: String {
            switch self {
            case .hindi: return "hi-IN"
            case .hinglish: return "en-IN"
            case .english: return ComputerLanguage.englishLocale(preferredLanguage: Self.computerLanguage)
            case .auto: return meansHinglish ? "en-IN" : ComputerLanguage.recognizerLocale(preferredLanguage: Self.computerLanguage)
            }
        }
        var sarvamListening: String {
            switch self {
            case .auto, .hinglish: return "auto"
            case .english: return "en-IN"
            case .hindi: return "hi-IN"
            }
        }
        /// (language code, v2.voice.sarvam.language value) for Sarvam's voice.
        var sarvamVoice: (code: String, setting: String) {
            switch self {
            case .hinglish: return ("hi-IN", "hinglish")
            case .auto: return meansHinglish ? ("hi-IN", "hinglish") : ("en-IN", "en-IN")
            case .english: return ("en-IN", "en-IN")
            case .hindi: return ("hi-IN", "hi-IN")
            }
        }
    }

    static var language: Language { UserDefaults.standard.string(forKey: languageKey).flatMap(Language.init(rawValue:)) ?? .auto }

    /// How long Vello waits after the owner stops talking before it answers (Settings › Voice › Patience). ClickyCore
    /// `CallTurnEnd` makes it longer when the words sound unfinished and shorter for a clear question.
    static var patienceSeconds: Double {
        CallTurnPatience.seconds(saved: UserDefaults.standard.object(forKey: CallTurnPatience.settingKey) as? Double)
    }

    /// Once, at launch: "auto" used to mean Hinglish everywhere, so a Mac that finished setup before it followed the computer's
    /// language keeps Hinglish. A new install starts on "auto", the computer's language.
    static func migrateLanguageIfNeeded() {
        let savedValueExists = UserDefaults.standard.object(forKey: languageKey) != nil
        if let migrated = ComputerLanguage.migratedCallLanguage(savedValueExists: savedValueExists, setupCompleted: ClickySettings.isSetupCompleted) {
            UserDefaults.standard.set(migrated, forKey: languageKey)
        }
    }
}

/// What a bot is told for a call: Vello's own bot with its call controls, any other bot to just talk (ClickyCore
/// `CallPromptText`).
enum CallPrompt {
    static let fileName = "theo-call-system-prompt.txt"
    static let otherBotFileName = "bot-call-system-prompt.txt"

    @MainActor
    static func system(store: BotsStore, usesSarvamVoice: Bool, language: CallSettings.Language) -> String {
        vellosOwn(store: store, theo: store.primary, usesSarvamVoice: usesSarvamVoice, language: language,
                  carriedOverCharacters: carriedOverCharacters(brainSetting: CallSettings.model))
    }

    /// How much of the chat this call's brain has room for at the start (ClickyCore `ContextBudget`): its own context
    /// window, less the call's instructions and its answer, a quarter of what's left, at most about 13,000 words.
    @MainActor
    static func carriedOverCharacters(brainSetting: String) -> Int {
        let model = BrainModel(setting: brainSetting)
        let window: Int
        if let providerID = BrainInventory.apiProviderID(of: model), let provider = ProviderInfo.info(for: providerID) {
            let modelName = String(model.modelIdentifier.split(separator: "/", maxSplits: 1).last ?? "")
            window = ContextWindows.knownTokens(provider: provider, model: modelName)
        } else {
            window = ContextBudget.windowTokens(model: model.isClaude ? "claude" : model.modelIdentifier, isLocalServer: false)
        }
        let answer = ContextBudget.answerTokens(windowTokens: window, wantedAnswerTokens: APIChat.roomForThinkingTokens)
        // The call's own instructions run to about 20,000 characters with a big team.
        let room = ContextBudget.historyCharacters(windowTokens: window, answerTokens: answer, instructionsCharacters: 20_000)
        return ContextBudget.callCarryOverCharacters(historyCharacters: room)
    }

    /// The call's prompt for `bot`: Vello's own bot (`isVellosOwnBot`) gets its controls, any other bot only talks.
    @MainActor
    static func system(store: BotsStore, bot: NativeBot?, isVellosOwnBot: Bool, usesSarvamVoice: Bool, language: CallSettings.Language,
                       carriedOverCharacters: Int = CallPromptText.carriedOverCharacters) -> String {
        guard !isVellosOwnBot, let bot else {
            return vellosOwn(store: store, theo: bot ?? store.primary, usesSarvamVoice: usesSarvamVoice, language: language, carriedOverCharacters: carriedOverCharacters)
        }
        let owner = BotPrompts.ownerName
        let recent = store.conversation(bot.id).messages.filter { $0.author == "user" || $0.author == bot.id || BotsStore.isCallRecord($0) }.suffix(200)
            .map { CallPromptText.ChatLine(isFromOwner: $0.author == "user", text: $0.text, isCallRecord: BotsStore.isCallRecord($0)) }
        return CallPromptText.otherBot(name: bot.name, instructions: bot.personaHead, owner: owner,
                                       // Hindi in Roman letters, whatever the voice: a bot on a small local model wrote
                                       // garbled Devanagari its English voice couldn't read (Air, 24 Nov), while its Hinglish
                                       // in Roman letters came out clear.
                                       languageRule: languageRule(owner: owner, usesSarvamVoice: false, language: language),
                                       reportingLines: BotPrompts.reportingLines(for: bot, store: store),
                                       memorySection: BotMemoryPrompt.section(BotMemory.read(botID: bot.id), path: bot.memoryPath),
                                       recentChat: Array(recent), carriedOverLimit: carriedOverCharacters)
    }

    /// A Space on Vello's own X account: Vello's persona and the Space's rules, and nothing from the owner's chats, team,
    /// runs or memory, since everything it knows it could say in public (ClickyCore `CallOwnAccount`).
    @MainActor
    static func ownAccount(bot: NativeBot?, handle: String, usesSarvamVoice: Bool, language: CallSettings.Language) -> String {
        let theo = bot
        let fixedLanguage: String?
        switch language {
        case .english: fixedLanguage = "English"
        case .hindi: fixedLanguage = "Hindi, in Devanagari"
        case .auto, .hinglish: fixedLanguage = nil
        }
        let rule = CallOwnAccount.languageRule(followsSpeaker: true, hinglishInDevanagari: language.meansHinglish ? usesSarvamVoice : nil, fixedLanguage: fixedLanguage)
        return CallOwnAccount.systemPrompt(personaHead: theo?.personaHead ?? "You are Vello.", handle: handle, owner: BotPrompts.ownerName,
                                           botName: theo?.name ?? "Vello", languageRule: rule)
    }

    /// Which language to answer in.
    static func languageRule(owner: String, usesSarvamVoice: Bool, language: CallSettings.Language) -> String {
        switch language {
        case .auto where !language.meansHinglish:
            return "Answer in the language \(owner) just used."
        case .auto, .hinglish:
            return usesSarvamVoice
                ? "Answer in the language \(owner) just used: English in English, Hindi in Hindi written in Devanagari, Hinglish as Hinglish with the Hindi in Devanagari and the English in Latin letters."
                : "Answer in the language \(owner) just used: English in English, Hindi or Hinglish in Roman letters, the way people text it, since this voice reads Roman letters best."
        case .english: return "Answer in English."
        case .hindi: return usesSarvamVoice ? "Answer in Hindi, in Devanagari." : "Answer in Hindi, in Devanagari, keeping it simple."
        }
    }

    @MainActor
    private static func vellosOwn(store: BotsStore, theo: NativeBot?, usesSarvamVoice: Bool, language: CallSettings.Language, carriedOverCharacters: Int) -> String {
        let owner = BotPrompts.ownerName
        var parts = [theo?.personaHead ?? "You are Vello."]
        var rules = CallPromptText.talkingRules(owner: owner)
        // The apps Vello has in its own text chat, which a call reaches with [TELL: Vello: …].
        let ownApps = theo.map { bot in BotConnectors.known.filter { bot.apps.contains($0.id) && $0.id != "theo" && !$0.isSkill }.map(\.name) } ?? []
        // Vello's own hands: it looks at the screen and acts itself (ClickyCore `CallHands`), with no Pointer Assistant between.
        rules += "\n" + ClickyTeamPrompts.callHowTo(owner: owner, ownChatApps: ownApps, hasHands: VelloHands.isOn,
                                                    leavesSafariAlone: ClickySettings.actionsLeaveSafariAlone)
        rules += "\n" + languageRule(owner: owner, usesSarvamVoice: usesSarvamVoice, language: language)
        parts.append(rules)
        if let theo {
            parts += BotPrompts.reportingLines(for: theo, store: store)
            let roster = store.rosterForCEO
            if !roster.isEmpty { parts.append(roster) }
            let routineNames = store.routines.map(\.name)
            if !routineNames.isEmpty { parts.append("\(OwnerName.startingSentence(owner))'s routines: " + routineNames.joined(separator: ", ") + ".") }
            let work = store.memoryStore.teamWorkContext()
            if !work.isEmpty { parts.append(work) }
            parts.append(store.runsStatus)
            parts.append(store.projectsNote + " On this call, put those words inside the [TELL: …] line. To just make a new empty folder, say it's for your chat afterward.")
            // Typed messages and earlier calls, so a call remembers what the last one said (ClickyCore `CallPromptText.recentChat`).
            let recent = store.conversation(theo.id).messages.suffix(200).compactMap { message -> CallPromptText.ChatLine? in
                if message.author == "user" { return CallPromptText.ChatLine(isFromOwner: true, text: message.text) }
                if message.author == theo.id { return CallPromptText.ChatLine(isFromOwner: false, text: message.text) }
                if message.author == BotsStore.clickyID { return CallPromptText.ChatLine(isFromOwner: false, text: message.text, speakerName: "Pointer Assistant") }
                if BotsStore.isCallRecord(message) { return CallPromptText.ChatLine(isFromOwner: false, text: message.text, isCallRecord: true) }
                return nil
            }
            if let chat = CallPromptText.recentChat(botName: theo.name, owner: owner, lines: recent, mostCharacters: carriedOverCharacters) { parts.append(chat) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// "Grok", "LM Studio", "Codex": a bot's engine as the owner knows it.
    @MainActor
    static func engineName(of bot: NativeBot) -> String {
        if let setting = BotEngineChoice(provider: bot.provider, model: bot.model).brainSetting { return BrainAvailability.name(of: setting) }
        switch bot.provider {
        case "grok": return "Grok"
        case "gemini": return "Gemini CLI"
        case "t3": return "T3 Code"
        default: return bot.provider.capitalized
        }
    }

    /// What the voice shouldn't read: markdown marks and the like.
    static func speakable(_ text: String) -> String {
        text.replacingOccurrences(of: "```[a-zA-Z]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class TheoCallSession: ObservableObject {
    enum State: Equatable {
        case connecting, listening, userSpeaking, thinking, speaking, ended
    }

    struct Line: Identifiable, Equatable {
        enum Who { case addy, theo }
        let id = UUID()
        let who: Who
        var text: String
        var isLive: Bool
        var wasCut = false
        /// Heard in Listen mode and kept, not answered. It may not be the owner speaking.
        var wasOnlyHeard = false
        /// Heard in group mode: the owner and other people, marked by who it sounded like ("Addy: …", "Someone: …").
        var isGroupTalk = false
        /// In a Space: written but never heard there, since the voice couldn't play it even after a second try.
        var wasNotHeard = false
    }

    /// One turn's timings, from the moment the owner's voice stopped.
    struct TurnTiming {
        var heard: TimeInterval?
        var firstText: TimeInterval?
        var firstAudio: TimeInterval?
        var ears = ""
        var voice = ""
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var lines: [Line] = []
    @Published private(set) var isMuted = false
    @Published private(set) var micLevel: CGFloat = 0
    @Published private(set) var problem: String?
    @Published private(set) var earsName = ""
    @Published private(set) var voiceName = ""
    @Published private(set) var lastFirstAudio: TimeInterval?
    @Published var language = CallSettings.language
    /// Listen mode: Vello only listens and keeps what it hears, and answers when spoken to.
    @Published private(set) var isListenMode = false
    /// The owner stopped talking and Vello is giving them a moment to go on before it answers.
    @Published private(set) var isHoldingTurn = false
    /// Group mode: an X Space, a group call or a room with other people (ClickyCore `CallGroupMode`). Every voice counts,
    /// lines are marked by who they sounded like, other people's words never throw an answer away, and Vello answers only
    /// when spoken to or when it has something to add.
    @Published private(set) var isGroupMode = false
    /// In a Space on Vello's own X account, who the Space's screen shows talking now (`SpaceSpeakerWatcher`).
    @Published private(set) var currentSpeaker: String?
    let startedAt = Date()
    /// A Space joined on Vello's own X account: heard only from the bot's browser, spoken into its virtual mic, in group
    /// mode for good, with nobody at the mic counted as the owner (ClickyCore `CallOwnAccount`).
    let ownAccount: XAccountSetup?
    var isOwnAccount: Bool { ownAccount != nil }
    /// Vello's call controls (its hands on the screen, orders, routines, switches): only on its own call with the owner.
    /// In a Space on its own account everyone it hears is a stranger, so it only talks.
    private var hasCallControls: Bool { isVellosOwnBot && !isOwnAccount }
    private var speakerWatcher: SpaceSpeakerWatcher?
    /// When the last words were given a speaker: the next words' name is the one seen most since then.
    private var wordsLastNamedAt: Date?
    /// A standing instruction for this Space from the owner (debug inbox `ownAccountNote`), added to every turn.
    var spaceNote: String?
    /// Someone talked over the bot in a Space: it finishes what's already playing and says no more this turn
    /// (ClickyCore `SpaceInterruption`).
    private var speaksNoMoreThisTurn = false
    /// Someone talked over the bot in a Space: it says the rest of the sentence it's on, then no more this turn.
    private var stopsAfterThisSentence = false
    /// The last turn's reply wasn't heard in the Space: the brain is told with the next turn, so it doesn't count it as said.
    private var lastReplyWasNotHeard = false
    /// The turn being answered had a line from the boss, who may switch the stance ([STANCE: …]).
    private var turnHadTheBoss = false
    /// Waiting to take a partial as the words when the ears' final is slow (`takePartialIfTheFinalIsSlow`).
    private var earlyPartialTask: Task<Void, Never>?

    private let audio: CallAudio
    private let isLive: Bool
    private let store: BotsStore
    /// Who's on the call: Vello's own bot, or any other bot. Only Vello's own has the call controls.
    let bot: NativeBot?
    let isVellosOwnBot: Bool
    /// The bot's id, for "is this the call with that bot".
    var botID: String { bot?.id ?? store.primary?.id ?? "theo" }
    /// The bot's name, for the call's lines, title and state.
    var botName: String { bot?.name ?? "Vello" }
    /// Keeps another bot's bracket lines out of the voice (it has none of Vello's controls).
    private var bracketLines = CallBracketLineStream()
    private var brain: ConversationBrain?
    private var ears: CallEars?
    private var voice: CallVoice?
    private var gate = VoiceActivityGate(endSeconds: 0.55)
    private var chunker = CallSpeechChunker()
    /// Keeps Theo's orders to Clicky out of the voice, wherever a tag splits.
    private var orders = ClickyOrderStream()
    /// Keeps the call's own switches ([POINTER: on], [ROUTINE: …]) out of the voice the same way.
    private var controls = CallControlStream()
    /// Takes Vello's own screen work out of the voice: [LOOK] and <actions> blocks (ClickyCore `CallHands`).
    private var screenPieces = CallScreenStream()
    /// The screen Vello's brain was last shown, whose badge numbers its next block uses, and when.
    private var lastShownScreen: GroundedTurn?
    private var lastShownScreenAt: Date?
    /// This reply answers the screen work (an observe or look turn) or carried steps: its end is reported to the task.
    private var replyIsScreenWork = false
    private var replyHadBlock = false
    /// This reply's block went to the steps: a [LOOK] in the same reply is moot, since the steps look again when they end.
    private var replyStartedSteps = false
    /// The owner's words this reply answers, for the safety tiers ("delete it" said by the owner).
    private var replyOwnerWords = ""
    /// After this reply the brain is shown the screen with these words ([LOOK], or a stray Pointer Assistant line).
    private var looksAfterReply: String?
    /// Turns about the screen waiting for the call to be free: their words, and whether they belong to a task's loop.
    private var waitingScreenTurns: [(text: String, isObserveTurn: Bool)] = []
    private var screenTurnPump: Task<Void, Never>?
    private var clickyReports: [String] = []
    private var flushTimer: Task<Void, Never>?
    private var replyInProgress = false
    private var speechEndedAt: Date?
    private var speechStartedAt: Date?
    private var heardAt: Date?
    private var firstTextAt: Date?
    private var pendingTurnTiming: TurnTiming?
    private(set) var timings: [TurnTiming] = []
    private(set) var bargeIns: [TimeInterval] = []
    private var heardBargeInAt: Date?
    private var theoLineID: UUID?
    private var turnNumber = 0
    /// What the owner has said this turn, held until a real pause (`waitForTheEndOfTheTurn`).
    private var heldTurnWords = ""
    private var heldTurnLineID: UUID?
    private var heldTurnTask: Task<Void, Never>?
    /// When the ears last gave any words, partial or final.
    private var lastWordsAt: Date?
    private var listenTranscript = CallListenTranscript()
    /// How long each turn waited after the voice stopped, for `uiCallStatus`.
    private(set) var turnWaits: [TimeInterval] = []
    /// A sound that keeps the gate open with no words in it (a fan, a TV in another language) stops holding the turn after
    /// this long, counted from the later of when it started and the last words. Eight seconds let a noisy room keep Vello
    /// listening long after the owner had finished, so it's three: longer than the ears' quiet spells mid-sentence.
    private static let longestWordlessSoundSeconds = 3.0
    /// When Vello's voice last stopped, for telling its own voice coming back through the mic from the owner's.
    private var voiceLastStoppedAt: Date?
    /// Words the ears wrote down that were Vello's own voice, for `uiCallStatus`.
    private(set) var echoesDropped: [String] = []
    /// The turn Vello is answering now: if the owner turns out to be still talking before any of the answer is heard, the
    /// answer is dropped and the turn carries on (`heardFinal`).
    private var lastReleasedTurn: (words: String, lineID: UUID?)?
    /// Some of this turn's answer has been heard.
    private var turnHasSounded = false
    /// Times the answer being written now was dropped and started over with more words (`CallCutIn`).
    private var restartsOfThisAnswer = 0
    /// What thinks for this call as the owner knows it ("Claude Sonnet 5.5", "LM Studio"), for the words said when it fails.
    private var brainNameForWords = "the brain"
    /// Turns on this call the brain gave no answer to: the first says why, later ones are short (ClickyCore `CallBrainFailure`).
    private var brainFailures = 0
    /// This turn's answer switched something on the call or gave Pointer Assistant an order: it did answer, even with no words.
    private var turnActedOnTheCall = false
    /// When the ears last gave words in a partial: the owner is still going, so the turn isn't let go yet.
    private var lastPartialWordsAt: Date?
    /// Only the voice near the Mac counts (Settings › Voice, on by default): someone talking across the room opens the
    /// gate too, and the ears write their words down, so a stretch of speech counts only when it's about as loud as the
    /// owner's own (ClickyCore `CallNearVoice`).
    private var nearVoice = CallNearVoice()
    private var nearVoiceOnly: Bool { CallNearVoice.isOn(saved: UserDefaults.standard.object(forKey: CallNearVoice.settingKey) as? Bool) }
    /// The last few blocks' levels (about 0.4 s), for how loud a stretch of speech starts.
    private var recentBlockLevels: [Double] = []
    private static let onsetBlockCount = 8
    /// The levels of the stretch of speech going on now, and whether it's the owner's.
    private var stretchBlockLevels: [Double] = []
    private var stretchIsNear = false
    /// Stretches of speech, and words, from voices too far away, for `uiCallStatus`.
    private(set) var farVoicesIgnored = 0
    private(set) var farWordsDropped = 0
    /// Words the ears give this long after the owner's own voice last sounded are someone else's.
    private static let nearWordsWindowSeconds = 3.5
    /// The owner is talking: the gate is open on a voice near the Mac.
    private var isOwnerSpeaking: Bool { gate.isSpeaking && stretchIsNear }
    /// The stretch going on now is about as loud as the owner's own voice. Outside group mode it's the same as
    /// `stretchIsNear` whenever only the near voice counts; in group mode every voice counts and this tells them apart.
    private var stretchSoundsLikeOwner = false
    /// What's held for this turn in group mode, by who it sounded like.
    private var heldGroupLines: [CallGroupMode.HeardLine] = []
    /// When the first words of the turn being held came, for letting long group talk go at its first gap.
    private var heldTurnStartedAt: Date?
    /// Words a group-mode answer had, raw, for telling a [PASS] from a turn that gave nothing.
    private var rawAnswerOfThisTurn = ""
    /// This turn's answer was [PASS]: Vello chose to stay quiet.
    private var turnPassed = false

    /// `botID` nil, or Vello's own bot's id: the call with Vello. Any other bot: a call with that bot.
    init(store: BotsStore, hub: AudioEngineHub, isLive: Bool, botID: String? = nil, ownAccount: XAccountSetup? = nil) {
        self.store = store
        self.isLive = isLive
        self.ownAccount = ownAccount
        audio = CallAudio(hub: hub, isLive: isLive, ownAccount: ownAccount)
        // A Space on the X account is always the X Space bot, a bot of its own apart from Vello.
        if ownAccount != nil {
            bot = store.ensureXSpaceBot()
            isVellosOwnBot = false
        } else if let chosen = botID.flatMap({ store.bot($0) }), !chosen.primary {
            bot = chosen
            isVellosOwnBot = false
        } else {
            bot = store.primary
            isVellosOwnBot = true
        }
    }

    // MARK: Start and end

    /// `openingWords`: what the owner said before the call began ("hey vello, …"), answered as the first turn.
    func start(openingWords: String = "") {
        // No App Nap or timer coalescing while someone is on the line, even with Theo in the background.
        liveActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Voice call with \(botName)")
        audio.onBlock = { [weak self] block in self?.handle(block) }
        audio.onDrained = { [weak self] in self?.voiceDrained() }
        audio.onOwnAccountProblem = { [weak self] message in self?.problem = message }
        do {
            try audio.open()
        } catch {
            problem = "The microphone didn't start."
            callLog("📞 Call audio: \(error)")
        }
        if let ownAccount {
            problem = audio.ownAccountProblem
            if let browser = ownAccount.browser {
                let watcher = SpaceSpeakerWatcher(browserBundleID: browser.bundleID, handle: ownAccount.handle, botName: botName,
                                                  displayName: ownAccount.displayName)
                watcher.onCurrentSpeaker = { [weak self] name in
                    if self?.currentSpeaker != name { self?.currentSpeaker = name }
                }
                speakerWatcher = watcher
                // The first look loads Vision and finds the window, which took 17 s on the Studio: done now, while the
                // Space is quiet, so the first speaker is named.
                Task { await watcher.lookOnce() }
            }
            callLog("📞 Space: joined as \(ownAccount.handle.isEmpty ? "Vello's own account" : ownAccount.handle), hearing \(ownAccount.browser?.name ?? "no browser")")
        }
        // Theo's voice reaches the mic with no echo cancelling: it takes a much louder voice to count as a cut-in. The
        // bot's browser never hears Vello's voice, so a Space on its own account needs no margin.
        if isLive && !audio.isEchoCancelled && !isOwnAccount { gate.bargeInMarginDecibels = 34 }
        startVoice()
        startEars()
        // Any other bot thinks with its own engine and model. One that can't take a call says why and what fixes it.
        let brainSetting: String
        if isVellosOwnBot {
            brainSetting = CallSettings.model
        } else {
            switch callBrainForOtherBot() {
            case .use(let setting):
                brainSetting = setting
            case .cannotCall(let words):
                problem = words
                state = .listening
                sayWithoutThinking(words)
                return
            }
        }
        brainNameForWords = BrainAvailability.name(of: brainSetting)
        // The call starts with as much of the chat as its brain has room for. A public Space gets none of it.
        let prompt = ownAccount.map { CallPrompt.ownAccount(bot: bot, handle: $0.handle, usesSarvamVoice: voice is SarvamCallVoice, language: language) }
            ?? CallPrompt.system(store: store, bot: bot, isVellosOwnBot: isVellosOwnBot, usesSarvamVoice: voice is SarvamCallVoice, language: language,
                                 carriedOverCharacters: CallPrompt.carriedOverCharacters(brainSetting: brainSetting))
        let brain = ConversationBrains.make(model: brainSetting, systemPrompt: prompt,
                                            promptFileName: isVellosOwnBot ? CallPrompt.fileName : CallPrompt.otherBotFileName, effort: "low")
        brain.onEnded = { [weak self] message in self?.problem = message }
        self.brain = brain
        do {
            try brain.start()
        } catch {
            problem = error.localizedDescription
        }
        state = .listening
        if isOwnAccount {
            // Group mode for good. No hello: Vello may not be a speaker yet, and nobody asked. A first turn it lets pass
            // warms up the brain, so the first answer in the Space is as quick as the rest.
            setGroupMode(true)
            ask("(You just joined the Space. Nobody has spoken to you yet: write only \(CallGroupMode.passMarker).)")
            return
        }
        // Called with "hey vello, …": the words said with the name are the first turn, answered straight away.
        if !openingWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            takeWordsSaidBeforeTheCall(openingWords)
            return
        }
        // Theo says hello: it's what a call does, and it warms up the brain and the voice, so the owner's first question gets
        // the same quick answer as the rest.
        ask(CallPromptText.hello(owner: BotPrompts.ownerName))
    }

    /// The brain for a call with a bot that isn't Vello's own: its own engine and model, when that works here.
    private func callBrainForOtherBot() -> CallBrainChoice {
        guard let bot else { return .use(brainSetting: CallSettings.model) }
        let engine = BotEngineChoice(provider: bot.provider, model: bot.model)
        let choice = CallBrainChoice.forBot(named: bot.name, engine: engine, engineName: CallPrompt.engineName(of: bot), inventory: BrainAvailability.inventory)
        // A Claude bot with no model picked thinks with Claude's usual call model.
        if case .use(let setting) = choice, BrainModel(setting: setting).isClaude, BrainModel(setting: setting).modelIdentifier.isEmpty {
            return .use(brainSetting: ClickyModels.sonnet)
        }
        return choice
    }

    func end() {
        guard state != .ended else { return }
        state = .ended
        heldTurnTask?.cancel()
        screenTurnPump?.cancel()
        speakerWatcher?.stop()
        if hasCallControls { CompanionManager.current?.actionTaskController.endCallTask() }
        if let liveActivity { ProcessInfo.processInfo.endActivity(liveActivity) }
        liveActivity = nil
        ears?.stop()
        voice?.shutDown()
        brain?.stop()
        audio.close()
        store.recordCall(lines.filter { !$0.text.isEmpty }.map { line in
                             let prefix = line.wasOnlyHeard ? "(heard in listen mode) " : (line.isGroupTalk ? (isOwnAccount ? "(in the X Space) " : "(in the group) ") : "")
                             return (line.who == .addy, prefix + line.text)
                         },
                         startedAt: startedAt, botID: isVellosOwnBot ? nil : bot?.id)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        micLevel = 0
    }

    private func startVoice() {
        // The call speaks with Sarvam whenever its key is saved, whichever voice Clicky uses.
        // A bot with its own call voice speaks with it; otherwise the usual call voice.
        if let key = ProviderKeychain.get("sarvam") {
            let voiceLanguage = language.sarvamVoice
            let ownSpeaker = CallVoiceChoice.voiceID(saved: bot?.callVoice, engine: .sarvam)
            let speaker = SarvamClient.speaker(ownSpeaker ?? SarvamVoiceConfig.speaker, in: voiceLanguage.setting)
            let sarvam = SarvamCallVoice(audio: audio, apiKey: key, speaker: speaker, languageCode: voiceLanguage.code, pace: SarvamVoiceConfig.pace)
            use(voice: sarvam)
        } else {
            use(voice: AppleCallVoice(audio: audio, voiceIdentifier: CallVoiceChoice.voiceID(saved: bot?.callVoice, engine: .apple)))
        }
    }

    private func use(voice newVoice: CallVoice) {
        voice = newVoice
        voiceName = newVoice.name
        newVoice.onFirstAudio = { [weak self] in self?.voiceStartedSounding() }
        newVoice.onFinished = { [weak self] in self?.voiceFinished() }
        newVoice.onFailed = { [weak self] message, pieces in self?.voiceFailed(message, pieces: pieces) }
        newVoice.prepare()
    }

    private func voiceFailed(_ message: String, pieces: [String]) {
        problem = "Sarvam's voice stopped (\(message)), using the Mac voice."
        let replacement = AppleCallVoice(audio: audio, voiceIdentifier: CallVoiceChoice.voiceID(saved: bot?.callVoice, engine: .apple))
        use(voice: replacement)
        for piece in pieces { replacement.speak(piece) }
        if !replyInProgress { replacement.endOfTurn() }
    }

    private func startEars() {
        if let key = ProviderKeychain.get("sarvam") {
            use(ears: SarvamCallEars(apiKey: key, languageCode: language.sarvamListening))
        } else {
            use(ears: appleEars())
        }
    }

    private func appleEars() -> AppleCallEars {
        let owner = BotPrompts.ownerName
        let ownerNameWords = OwnerName.isUnset(owner) ? [] : [owner]
        return AppleCallEars(locale: language.appleLocale, phrases: ["Vello", "Pointer Assistant", "Sarvam"] + ownerNameWords + store.bots.map(\.name))
    }

    private func use(ears newEars: CallEars) {
        ears?.stop()
        ears = newEars
        earsName = newEars.name
        newEars.onPartial = { [weak self] text in self?.heardPartial(text) }
        newEars.onFinal = { [weak self] text in self?.heardFinal(text) }
        newEars.onFailed = { [weak self] message in self?.earsFailed(message) }
        newEars.start()
        earsName = newEars.name
        callLog("📞 Call: listening with \(newEars.name)")
    }

    private func earsFailed(_ message: String) {
        guard state != .ended else { return }
        guard !(ears is AppleCallEars) else {
            callLog("📞 Call: Apple's listening stopped: \(message)")
            problem = message
            return
        }
        // Sarvam's socket closed mid-call: reconnect it rather than hand the call to Apple, which hears a busy Space poorly.
        let now = Date()
        if let key = ProviderKeychain.get("sarvam"), CallEarsReconnect.reconnects(earlierReconnects: sarvamReconnects, now: now) {
            sarvamReconnects.append(now)
            callLog("📞 Call: Sarvam's listening stopped (\(message)), reconnecting")
            use(ears: SarvamCallEars(apiKey: key, languageCode: language.sarvamListening))
            return
        }
        callLog("📞 Call: Sarvam's listening keeps stopping (\(message)), using Apple for now")
        problem = "Sarvam's listening keeps stopping (\(message)), using Apple on this Mac for now."
        use(ears: appleEars())
        // Sarvam is tried again in a while, so one bad minute doesn't leave the rest of the call on Apple.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CallEarsReconnect.backToSarvamAfterSeconds * 1_000_000_000))
            guard let self, self.state != .ended, self.ears is AppleCallEars, let key = ProviderKeychain.get("sarvam") else { return }
            callLog("📞 Call: trying Sarvam's listening again")
            self.sarvamReconnects = []
            self.problem = nil
            self.use(ears: SarvamCallEars(apiKey: key, languageCode: self.language.sarvamListening))
        }
    }

    /// When Sarvam's listening was reconnected on this call (`CallEarsReconnect`).
    private var sarvamReconnects: [Date] = []
    /// Group turns Vello let pass since it last spoke, so it's nudged to join in (`CallGroupMode.passesBeforeNudge`).
    private var groupPassesInARow = 0

    func changeLanguage(_ new: CallSettings.Language) {
        guard new != language else { return }
        language = new
        UserDefaults.standard.set(new.rawValue, forKey: CallSettings.languageKey)
        // The new language takes hold from the next turn: new ears and voice, and Theo told in so many words.
        voice?.shutDown()
        startVoice()
        startEars()
        guard let brain, brain.isRunning, new != .auto else { return }
        pendingLanguageNote = "(From now on answer in \(new.title).) "
    }

    private var pendingLanguageNote = ""
    private var liveActivity: NSObjectProtocol?

    // MARK: Mic

    private func handle(_ block: CallAudioBlock) {
        guard state != .ended, state != .connecting else { return }
        if isMuted {
            // Muted: nothing heard, and nothing leaves the Mac. The ears hear silence so their socket stays open.
            ears?.feed(CallAudioBlock(pcm16: Data(count: block.pcm16.count), levelDecibels: -100), isSpeech: false)
            return
        }
        micLevel = CGFloat(min(max((block.levelDecibels + 55) / 40, 0), 1))
        // The bot's browser never hears Vello's own voice, so in a Space on its own account the gate needn't wait for a
        // voice above it.
        let voiceIsOn = (state == .speaking || audio.isVoicePlaying) && !isOwnAccount
        let now = Date()
        recentBlockLevels.append(block.levelDecibels)
        if recentBlockLevels.count > Self.onsetBlockCount { recentBlockLevels.removeFirst(recentBlockLevels.count - Self.onsetBlockCount) }
        let event = gate.feed(levelDecibels: block.levelDecibels, seconds: CallAudioBlock.seconds, otherSideTalking: voiceIsOn)
        // Whose voice it is, decided before the ears get the audio, so a voice across the room never starts their words.
        var ownerStartedTalking = false
        switch event {
        case .speechStarted:
            stretchBlockLevels = recentBlockLevels
            // On its own account nobody heard is the owner, however loud.
            stretchSoundsLikeOwner = !isOwnAccount && nearVoice.isNear(levelDecibels: recentBlockLevels.max() ?? block.levelDecibels, now: now)
            // In group mode every voice counts: the other people in the Space come out of a phone's speaker well below the
            // owner's level, and turning them away left Vello deaf to everyone but the owner (Air, 24 Nov).
            stretchIsNear = !nearVoiceOnly || isGroupMode || stretchSoundsLikeOwner
            if stretchIsNear {
                ownerStartedTalking = true
            } else {
                farVoicesIgnored += 1
                callLog("📞 Call: a voice too far from the Mac, ignored (\(Int(recentBlockLevels.max() ?? 0)) dB, the owner's is \(Int(nearVoice.ownerLevelDecibels ?? 0)) dB)")
            }
        case .speechEnded, nil:
            if gate.isSpeaking { stretchBlockLevels.append(block.levelDecibels) }
            // Someone far away was talking and the owner joined in, louder: from here it's the owner's.
            if gate.isSpeaking, !isOwnAccount, !stretchSoundsLikeOwner, nearVoice.isNear(levelDecibels: recentBlockLevels.max() ?? block.levelDecibels, now: now) {
                stretchSoundsLikeOwner = true
                if !stretchIsNear {
                    stretchIsNear = true
                    ownerStartedTalking = true
                }
            }
        }
        // In group mode other people's voices count too, but only the owner's teaches the owner's level and marks near speech.
        let isTheOwnersOwnVoice = isGroupMode ? stretchSoundsLikeOwner : true
        if isOwnerSpeaking && isTheOwnersOwnVoice { nearVoice.heardNearSpeech(at: now) }
        // The ears get the audio before the event is acted on, so the first words aren't missing.
        ears?.feed(block, isSpeech: isOwnerSpeaking)
        // Who's talking is looked for on the Space's screen only while someone is.
        speakerWatcher?.setSpeechGoingOn(gate.isSpeaking)
        if ownerStartedTalking { speechStarted() }
        if event == .speechEnded {
            let wasTheOwner = stretchIsNear
            if wasTheOwner, isTheOwnersOwnVoice, let loudLevel = CallNearVoice.loudLevel(of: stretchBlockLevels) {
                nearVoice.learn(nearStretchLevelDecibels: loudLevel, at: now)
            }
            stretchIsNear = false
            stretchSoundsLikeOwner = false
            stretchBlockLevels = []
            if wasTheOwner { speechEnded() }
        }
    }

    /// Words from the ears that came from someone else in the room: none of the owner's own voice near the Mac lately.
    private func isSomeoneElseTalking() -> Bool {
        guard nearVoiceOnly, !isGroupMode, !isOwnerSpeaking, let lastNearSpeechAt = nearVoice.lastNearSpeechAt else { return false }
        return Date().timeIntervalSince(lastNearSpeechAt) > Self.nearWordsWindowSeconds
    }

    private func speechStarted() {
        speechStartedAt = Date()
        speechEndedAt = nil
        if (audio.isVoicePlaying || state == .speaking) && !isGroupMode {
            // Talking over Vello's voice: it stops at once (the gate already wants a voice well above the speakers).
            // In a group a laugh or a "haan" over it is just people reacting: words decide there (`heardPartial`), so
            // Vello isn't cut off mid-sentence by every sound in the Space.
            bargeIn()
        }
        // While Vello is still writing, a sound on its own no longer throws the answer away. A cough, a chair, or someone
        // nearby used to start every answer over (Air, 23 Nov: "the owner spoke during the answer" 25 times in one call,
        // often with no new words, so the same turn was asked again and again and the answer came late or never). Words
        // decide instead: `heardPartial` and `heardFinal` cut in once the owner really says something.
        state = .userSpeaking
        startAddyLine()
    }

    /// The owner's words came in while Vello was still answering: if none of the answer was heard yet, the owner was just
    /// carrying on and the turn goes on as one; otherwise Vello stops.
    private func ownerWordsCameDuringTheAnswer(_ words: String = "") {
        // In a group the talk goes on while Vello writes: those words wait and go with the next turn. Starting the answer
        // over for each of them meant it came late or never (Air, 24 Nov, in an X Space).
        if isGroupMode, replyInProgress, !turnHasSounded, !audio.isVoicePlaying { return }
        // In a Space only the boss, or someone calling the bot by name and going on, stops it mid-sentence; anyone else
        // lets it finish what's already playing. Stopping for everyone left half its answers unsaid (a public Space, 25 Nov).
        if isOwnAccount {
            let newWords = words.split(separator: " ").count
            let byBoss = SpaceBoss.isBoss(currentSpeaker, bossNames: ownAccount?.bossNames ?? [])
            switch SpaceInterruption.decision(newWords: newWords, isAddressed: isAddressedInTheGroup(words), byBoss: byBoss) {
            case .stopNow:
                callLog("📞 Space: stopped mid-sentence for \(byBoss ? "the boss" : "someone calling it")")
                bargeIn()
            case .finishTheSentence:
                // Chatter as it starts is the room carrying on, not someone talking over it: in a public Space this
                // stopped it after its first phrase nearly every turn (25 Nov), so it only counts once it's been heard.
                guard turnHasSounded, !stopsAfterThisSentence, !speaksNoMoreThisTurn else { break }
                callLog("📞 Space: someone talked over it, finishing the sentence")
                stopsAfterThisSentence = true
            case .carryOn:
                break
            }
            return
        }
        if replyInProgress, !turnHasSounded, lastReleasedTurn != nil {
            // Started over twice already: the answer is kept, and the new words wait for it and are answered next.
            guard CallCutIn.restartsTheAnswer(restartsSoFar: restartsOfThisAnswer) else { return }
            restartsOfThisAnswer += 1
            supersedeTheAnswer()
        } else if replyInProgress || audio.isVoicePlaying || state == .speaking {
            bargeIn()
        }
    }

    /// The words of the turn being answered and any held since: a repeat of these isn't the owner saying more.
    private var wordsOfThisTurn: String {
        [lastReleasedTurn?.words ?? "", heldTurnWords].joined(separator: " ")
    }

    /// Words in a partial before it counts as the owner cutting in (one word is too often a cough or the room).
    static let partialWordsToCutIn = 2

    private func speechEnded() {
        // The gate waits out a stretch of quiet to be sure. The clock starts from the voice's real end, before that wait.
        if speechEndedAt == nil { speechEndedAt = Date().addingTimeInterval(-gate.endSeconds) }
        if state == .userSpeaking {
            // The ears may have given their words and the reply may even be done by now.
            let isWaiting = replyInProgress || audio.isVoicePlaying || lines.last?.isLive == true
            state = isWaiting ? (audio.isVoicePlaying ? .speaking : .thinking) : .listening
        }
        ears?.speechEnded()
    }

    /// The owner talked over Theo: the voice stops at once and the rest of the reply is dropped.
    private func bargeIn() {
        // The answer may be fully written and only still playing: that line was cut too.
        let voiceWasPlaying = audio.isVoicePlaying || state == .speaking
        if theoLineID == nil, voiceWasPlaying, let answerIndex = lines.lastIndex(where: { $0.who == .theo }),
           !lines[answerIndex].text.isEmpty, lines[(answerIndex + 1)...].allSatisfy(\.isLive) {
            lines[answerIndex].wasCut = true
        }
        if voiceWasPlaying { voiceLastStoppedAt = Date() }
        voice?.stopNow()
        let screenReplyWasCut = replyInProgress && (replyIsScreenWork || replyHadBlock)
        if replyInProgress { brain?.interrupt() }
        replyInProgress = false
        // A screen turn cut off before its steps came: the task isn't left waiting for an answer that won't arrive.
        if screenReplyWasCut, hasCallControls { screenReplyEnded(failed: !replyHadBlock) }
        flushTimer?.cancel()
        chunker = CallSpeechChunker()
        if let theoLineID, let index = lines.firstIndex(where: { $0.id == theoLineID }) {
            lines[index].isLive = false
            lines[index].wasCut = true
        }
        theoLineID = nil
        // How long a voice took to stop it: the gate's wait for a real voice (double while Theo talks), and this.
        if let speechStartedAt { bargeIns.append(Date().timeIntervalSince(speechStartedAt) + gate.startSeconds * 2) }
    }

    // MARK: Words in

    private func startAddyLine() {
        if let last = lines.last, last.who == .addy, last.isLive { return }
        // Talking again while Vello waits for more: the same turn goes on, on the same line.
        if let heldTurnLineID, let last = lines.last, last.id == heldTurnLineID {
            lines[lines.count - 1].isLive = true
            return
        }
        lines.append(Line(who: .addy, text: "", isLive: true))
    }

    private func heardPartial(_ text: String) {
        // Vello's own voice coming back through the mic: not the owner, so no line and no turn.
        if isVellosOwnVoiceComingBack(text) || isSomeoneElseTalking() { return }
        // A partial only stops Vello's voice. An answer not heard yet is started over only by a final with new words: a
        // partial often re-hears words already taken in other spellings, and starting over on it, then getting a final
        // that was only a repeat, asked the same turn again after another full pause (Air, 24 Nov: "137 words" let go
        // three times, each 4 s apart).
        let answerNotHeardYet = replyInProgress && !turnHasSounded && !audio.isVoicePlaying
        if replyInProgress || audio.isVoicePlaying, !answerNotHeardYet,
           CallCutIn.bringsNewWords(text, alreadyHeard: wordsOfThisTurn,
                                    atLeast: isGroupMode ? CallGroupMode.partialWordsToCutIn : Self.partialWordsToCutIn) {
            ownerWordsCameDuringTheAnswer(text)
        }
        startAddyLine()
        lastWordsAt = Date()
        lastPartialWordsAt = lastWordsAt
        guard let index = lines.lastIndex(where: { $0.who == .addy && $0.isLive }) else { return }
        lines[index].text = lines[index].id == heldTurnLineID && !heldTurnWords.isEmpty ? CallHeldWords.adding(text, to: heldTurnWords) : text
        if isOwnAccount { takePartialIfTheFinalIsSlow(text) }
    }

    /// In a Space, someone who calls the bot by name and stops shouldn't wait for the ears' final words: Sarvam's came
    /// 1.5 to 2 s after the voice stopped (Studio, 25 Nov), most of the wait before an answer. Once their voice has been
    /// quiet for the addressed wait with no final yet, the last partial is taken as the words; the final that follows
    /// with nothing new is dropped as a repeat, as usual.
    private func takePartialIfTheFinalIsSlow(_ text: String) {
        earlyPartialTask?.cancel()
        let words = CallHeardWords.withoutRunawayRepeats(text)
        guard !words.isEmpty, isAddressedInTheGroup(words) else { return }
        earlyPartialTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled, self.state != .ended else { return }
                if self.gate.isSpeaking || self.replyInProgress { continue }
                guard let speechEndedAt = self.speechEndedAt,
                      Date().timeIntervalSince(speechEndedAt) >= CallOwnAccount.pauseBeforeAnswering else { continue }
                self.earlyPartialTask = nil
                callLog("📞 Space: took the words before the ears' final (\(words.split(separator: " ").count) words)")
                self.heardFinal(words)
                return
            }
        }
    }

    /// The ears give their words after about half a second of quiet, far less than people pause mid-thought. The words are
    /// held, and Vello answers only once the pause is a real one (`waitForTheEndOfTheTurn`).
    private func heardFinal(_ text: String) {
        earlyPartialTask?.cancel()
        earlyPartialTask = nil
        let words = CallHeardWords.withoutRunawayRepeats(text)
        if !words.isEmpty, isVellosOwnVoiceComingBack(words) {
            // The ears wrote down Vello's own voice. Taking it as the owner cut Vello off mid-answer (the voice stopped and
            // the answer was dropped) and then answered its own words, so it's dropped here.
            echoesDropped.append(words)
            callLog("📞 Call: dropped Vello's own voice coming back (\(words.split(separator: " ").count) words)")
            if echoesDropped.count > 20 { echoesDropped.removeFirst(echoesDropped.count - 20) }
            if let liveIndex = lines.lastIndex(where: { $0.who == .addy && $0.isLive }), lines[liveIndex].id != heldTurnLineID {
                lines.remove(at: liveIndex)
            }
            return
        }
        if !words.isEmpty, isSomeoneElseTalking() {
            // Someone across the room: their words are neither a turn nor a cut-in.
            farWordsDropped += 1
            callLog("📞 Call: dropped words from a voice too far from the Mac (\(words.split(separator: " ").count) words)")
            if let liveIndex = lines.lastIndex(where: { $0.who == .addy && $0.isLive }), lines[liveIndex].id != heldTurnLineID {
                lines.remove(at: liveIndex)
            }
            return
        }
        // A server's own voice detection can beat the gate. Its default wait is half a second of quiet.
        if isOwnerSpeaking, speechEndedAt == nil, !words.isEmpty { speechEndedAt = Date().addingTimeInterval(-0.5) }
        // The ears handing over words already taken for the turn being answered: a repeat, not more from the owner.
        // The same goes for a stretch of speech the ears hand over again while a turn is held (`CallHeldWords`).
        let isRepeat = !words.isEmpty && (
            (lastReleasedTurn != nil && heldTurnWords.isEmpty && !CallCutIn.bringsNewWords(words, alreadyHeard: wordsOfThisTurn))
            || (!heldTurnWords.isEmpty && CallHeldWords.adding(words, to: heldTurnWords) == heldTurnWords.trimmingCharacters(in: .whitespacesAndNewlines)))
        if isRepeat { callLog("📞 Call: the ears repeated words already taken (\(words.split(separator: " ").count) words)") }
        if !words.isEmpty, !isRepeat, replyInProgress || audio.isVoicePlaying { ownerWordsCameDuringTheAnswer(words) }
        let liveIndex = lines.lastIndex(where: { $0.who == .addy && $0.isLive })
        if words.isEmpty || isRepeat {
            // A cough, or the room. No new words; whatever was held still waits for its pause.
            if let liveIndex {
                if lines[liveIndex].id == heldTurnLineID {
                    lines[liveIndex].text = heldTurnWords
                    lines[liveIndex].isLive = false
                } else {
                    lines.remove(at: liveIndex)
                }
            }
            if heldTurnWords.isEmpty, !replyInProgress, state == .thinking || state == .userSpeaking { state = .listening }
            return
        }
        lastWordsAt = Date()
        if heldTurnWords.isEmpty { heldTurnStartedAt = lastWordsAt }
        let wordsHeldBefore = heldTurnWords
        heldTurnWords = CallHeldWords.adding(words, to: heldTurnWords)
        if isGroupMode {
            // Only the part that's new goes on the speaker's line (`CallHeldWords` leaves a repeat out).
            let added = heldTurnWords.hasPrefix(wordsHeldBefore) ? String(heldTurnWords.dropFirst(wordsHeldBefore.count)) : words
            if isOwnAccount {
                heldGroupLines = CallGroupMode.adding(added, isOwner: false, speaker: speakerOfWordsJustHeard(), to: heldGroupLines)
            } else {
                heldGroupLines = CallGroupMode.adding(added, isOwner: wordsSoundLikeTheOwner(), to: heldGroupLines)
            }
        }
        if let liveIndex {
            lines[liveIndex].text = heldTurnWords
            lines[liveIndex].isLive = false
            heldTurnLineID = lines[liveIndex].id
        } else if let heldTurnLineID, let heldIndex = lines.firstIndex(where: { $0.id == heldTurnLineID }) {
            lines[heldIndex].text = heldTurnWords
        } else {
            let line = Line(who: .addy, text: heldTurnWords, isLive: false)
            lines.append(line)
            heldTurnLineID = line.id
        }
        if !isOwnerSpeaking, !replyInProgress, state == .userSpeaking || state == .thinking { state = .listening }
        waitForTheEndOfTheTurn()
    }

    /// In a Space on Vello's own account, the name seen speaking most since the last words were named, or nil ("Someone").
    private func speakerOfWordsJustHeard() -> String? {
        let now = Date()
        let from = wordsLastNamedAt ?? startedAt
        wordsLastNamedAt = now
        let name = speakerWatcher?.speaker(from: from, to: now)
        callLog("📞 Space: words from \(SpaceSpeakerVotes.label(name))")
        return name
    }

    /// In group mode, whether words the ears just gave were the owner's: their voice right at the Mac was going a moment ago.
    /// A guess from loudness, said as one to the brain.
    private func wordsSoundLikeTheOwner() -> Bool {
        if gate.isSpeaking && stretchSoundsLikeOwner { return true }
        guard let lastNearSpeechAt = nearVoice.lastNearSpeechAt else { return true }
        return Date().timeIntervalSince(lastNearSpeechAt) <= 1.5
    }

    /// Whether words from the ears are Vello's own voice coming back through the mic rather than the owner talking.
    /// While the voice plays, the gate only opens for a voice well above it (its cut-in margin), and a real cut-in stops the
    /// voice at once (`bargeIn`). So words that arrive while the voice is still playing with the gate shut came from the
    /// speakers. Just after the voice stops, the ears can still hand over its last words: those are told by how much of them
    /// Vello had just said.
    private func isVellosOwnVoiceComingBack(_ heard: String) -> Bool {
        // The bot's browser doesn't play Vello's own voice back, so only words that are mostly what it just said are its
        // own (someone's phone in the Space playing it back).
        if isOwnAccount {
            return CallEcho.soundsLikeVello(heard, vellosRecentWords: lines.last(where: { $0.who == .theo })?.text ?? "")
        }
        let voiceIsOn = audio.isVoicePlaying || state == .speaking
        if voiceIsOn { return !isOwnerSpeaking }
        guard let voiceLastStoppedAt, Date().timeIntervalSince(voiceLastStoppedAt) < 2.0 else { return false }
        let vellosLastWords = lines.last(where: { $0.who == .theo })?.text ?? ""
        return CallEcho.soundsLikeVello(heard, vellosRecentWords: vellosLastWords)
    }

    /// More words came while Vello was answering, with no new start of speech to cut in on (the voice never stopped, or
    /// the gate opened before the turn was let go). The answer stops. If none of it was heard yet, the owner was simply
    /// still going: the answer is taken out and the turn carries on as one, on its own line.
    private func supersedeTheAnswer() {
        let answerLineID = theoLineID
        let answerWasHeard = turnHasSounded
        let wasAnsweringATurn = replyInProgress
        callLog("📞 Call: the owner spoke during the answer (answer heard yet: \(answerWasHeard), still writing: \(wasAnsweringATurn))")
        // The turn is asked again below with all the owner's words, so its first try leaves the conversation's memory.
        // Kept, the model saw the same question twice with an answer the owner never heard, and lost the thread.
        if wasAnsweringATurn, !answerWasHeard, heldTurnWords.isEmpty, lastReleasedTurn != nil {
            brain?.forgetTheTurnBeingAnswered()
            // That already interrupted the brain: `bargeIn` mustn't send Claude Code a second interrupt, which could land
            // on the turn asked again next and leave it with no answer (Air, 24 Nov: two restarts, then silence).
            replyInProgress = false
        }
        bargeIn()
        guard wasAnsweringATurn, !answerWasHeard, heldTurnWords.isEmpty, let lastReleasedTurn else { return }
        self.lastReleasedTurn = nil
        if let answerLineID, let answerIndex = lines.firstIndex(where: { $0.id == answerLineID }) { lines.remove(at: answerIndex) }
        heldTurnWords = lastReleasedTurn.words
        guard let earlierLineID = lastReleasedTurn.lineID, lines.contains(where: { $0.id == earlierLineID }) else {
            waitForTheEndOfTheTurn()
            return
        }
        heldTurnLineID = earlierLineID
        // The words now coming in were on a line of their own: they join the earlier one. The earlier line is found again
        // by its id after the removal: a live line above it shifted it, and the old index crashed the app (Air, 23 Nov).
        if let liveIndex = lines.lastIndex(where: { $0.who == .addy && $0.isLive && $0.id != earlierLineID }) {
            lines.remove(at: liveIndex)
            if let earlierIndex = lines.firstIndex(where: { $0.id == earlierLineID }) { lines[earlierIndex].isLive = true }
        }
        waitForTheEndOfTheTurn()
    }

    /// Waits until the owner has been quiet for the patience (longer when the words sound unfinished, shorter for a clear
    /// question), counted from when their voice stopped. Talking again restarts the wait once the new words are in.
    private func waitForTheEndOfTheTurn() {
        heldTurnTask?.cancel()
        isHoldingTurn = true
        heldTurnTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.state != .ended, !self.heldTurnWords.isEmpty else { return }
                // Words that came while an answer was kept (`CallCutIn`) wait for it to be written and spoken.
                if self.replyInProgress || self.audio.isVoicePlaying {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                let now = Date()
                let lastWords = self.lastWordsAt ?? now
                let soundOrWordsSince = max(lastWords, self.speechStartedAt ?? lastWords)
                // Still talking: wait for the voice to stop. A sound with no words in it doesn't hold the turn forever.
                if self.isOwnerSpeaking && now.timeIntervalSince(soundOrWordsSince) < Self.longestWordlessSoundSeconds {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continue
                }
                // Partials still coming keep the turn open a little longer, but never for good: people talking near the Mac
                // keep them coming too, and Vello sat quiet for half a minute (`CallQuietLimit`).
                let voiceStopped = self.isOwnerSpeaking ? soundOrWordsSince : (self.speechEndedAt ?? lastWords)
                let secondsSinceVoiceStopped = now.timeIntervalSince(voiceStopped)
                let secondsSincePartialWords = self.lastPartialWordsAt.map { now.timeIntervalSince($0) }
                var wait = CallTurnEnd.waitSeconds(after: self.heldTurnWords, patienceSeconds: CallSettings.patienceSeconds)
                let releases: Bool
                if self.isGroupMode {
                    // A group takes the floor at shorter pauses, and long talk is let go at its first gap.
                    wait = self.isOwnAccount ? CallOwnAccount.pauseBeforeAnswering
                        : CallGroupMode.waitSeconds(ownWait: wait, isAddressed: self.isAddressedInTheGroup(self.heldTurnWords))
                    releases = CallGroupMode.releasesTurn(someoneIsTalking: self.isOwnerSpeaking, secondsSinceVoiceStopped: secondsSinceVoiceStopped,
                                                          secondsSincePartialWords: secondsSincePartialWords, waitSeconds: wait,
                                                          secondsHeld: now.timeIntervalSince(self.heldTurnStartedAt ?? now))
                } else {
                    releases = CallQuietLimit.releasesTurn(secondsSinceVoiceStopped: secondsSinceVoiceStopped,
                                                           secondsSincePartialWords: secondsSincePartialWords, waitSeconds: wait)
                }
                if releases {
                    self.releaseHeldTurn(quietSeconds: secondsSinceVoiceStopped)
                    return
                }
                // Short steps, so a voice that starts again is noticed at once.
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func releaseHeldTurn(quietSeconds: TimeInterval) {
        let words = heldTurnWords
        let lineID = heldTurnLineID
        let groupLines = isGroupMode ? (heldGroupLines.isEmpty ? [CallGroupMode.HeardLine(isOwner: !isOwnAccount, text: words)] : heldGroupLines) : nil
        heldTurnWords = ""
        heldGroupLines = []
        heldTurnStartedAt = nil
        heldTurnLineID = nil
        heldTurnTask = nil
        isHoldingTurn = false
        turnWaits.append(quietSeconds)
        callLog("📞 Call: turn ends after \(String(format: "%.1f", quietSeconds)) s of quiet (\(words.split(separator: " ").count) words)")
        lastReleasedTurn = (words, lineID)
        // The line may have been reopened by a sound that brought no words.
        if let lineID, let index = lines.firstIndex(where: { $0.id == lineID }) {
            lines[index].isLive = false
            // Shown and saved by who it sounded like, so the next call knows it wasn't all the owner.
            if let groupLines {
                lines[index].text = CallGroupMode.labelled(groupLines, owner: BotPrompts.ownerName)
                lines[index].isGroupTalk = true
            }
        }
        takeTurn(words, lineID: lineID, groupLines: groupLines)
    }

    /// Words the owner said before the call could hear them (after "hey vello"): a line of theirs and a turn, like words
    /// the call's own ears heard. Nothing while Vello is still answering, so an answer is never cut by words from outside.
    func takeWordsSaidBeforeTheCall(_ words: String) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state != .ended, !words.isEmpty, !replyInProgress else { return }
        let line = Line(who: .addy, text: words, isLive: false)
        lines.append(line)
        takeTurn(words, lineID: line.id)
    }

    /// The owner's words that reached a running call without its mic: a signed or finger-spelled line, a hand sign's
    /// question. They're a turn of the owner's like spoken words (they pause Vello's steps, a yes answers a step waiting
    /// for one), taken once Vello isn't in the middle of writing an answer so none are lost.
    func takeOwnerWordsFromOutside(_ words: String) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        // A Space on Vello's own account only takes what's said in the Space: the owner's words at the Mac would be
        // spoken into it as a stranger's.
        guard state != .ended, !words.isEmpty, !isOwnAccount else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<200 {
                guard let self, self.state != .ended else { return }
                if !self.replyInProgress { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard let self, self.state != .ended else { return }
            self.takeWordsSaidBeforeTheCall(words)
        }
    }

    /// The owner's whole turn: a Listen mode switch, something heard in Listen mode, or a question for Vello.
    private func takeTurn(_ words: String, lineID: UUID?, groupLines: [CallGroupMode.HeardLine]? = nil) {
        // Only the owner switches group mode by voice: someone else in the Space saying "group mode off" doesn't. On
        // Vello's own account nobody heard is the owner, so nothing said there switches anything.
        let saidByTheOwner = !isOwnAccount && (groupLines.map { lines in lines.contains(where: \.isOwner) } ?? true)
        if CallOwnAccount.acceptsSpokenSwitches(isOwnAccount: isOwnAccount, saidByTheOwner: saidByTheOwner), let groupCommand = CallGroupMode.command(in: words) {
            let turnOn = groupCommand == .start
            if turnOn != isGroupMode {
                setGroupMode(turnOn)
                let speaksHindi = language == .hindi || language.meansHinglish
                sayWithoutThinking(CallGroupMode.acknowledgement(turnOn: turnOn, speaksHindi: speaksHindi, readsDevanagari: voice is SarvamCallVoice))
                // "Talk normally" also ends Listen mode.
                if !turnOn, CallListenMode.command(in: words) == .stop { isListenMode = false }
                return
            }
        }
        switch isOwnAccount ? nil : CallListenMode.command(in: words) {
        case .start?:
            startListenMode(announce: true)
            return
        case .stop?:
            stopListenMode(announce: true)
            return
        case nil:
            break
        }
        let owner = BotPrompts.ownerName
        if isListenMode {
            guard CallListenMode.isAddressed(words, assistantNames: assistantNames) else {
                listenTranscript.add(words)
                if let lineID, let index = lines.firstIndex(where: { $0.id == lineID }) { lines[index].wasOnlyHeard = true }
                return
            }
            // Called by name: Vello comes back to talking, and answers or does what was asked with all it heard.
            if CallListenMode.callsVelloByName(words, assistantNames: assistantNames) {
                isListenMode = false
                ask(listenTranscript.messageForVello(asking: words, owner: owner, staysInListenMode: false), acknowledgesIfSlow: true)
                return
            }
            ask(listenTranscript.messageForVello(asking: words, owner: owner, staysInListenMode: true), acknowledgesIfSlow: true)
            return
        }
        // Vello is working on screen: a yes or no to a step is answered at once, and anything else pauses the steps and
        // reaches the brain with what was done and the screen as it is now. In a group only the owner's words do that.
        if hasCallControls, saidByTheOwner, ownerWordsReachTheScreenWork(words) { return }
        // A Space on Vello's own account: what was said, by the names on the Space's screen.
        if isOwnAccount {
            let heard = groupLines ?? [CallGroupMode.HeardLine(isOwner: false, text: words)]
            let isAddressed = isAddressedInTheGroup(words)
            var message = CallOwnAccount.message(lines: heard, handle: ownAccount?.handle ?? "", botName: botName, isAddressed: isAddressed,
                                                 passesInARow: groupPassesInARow, onStage: speakerWatcher?.onStage ?? [],
                                                 bossNames: ownAccount?.bossNames ?? [], owner: BotPrompts.ownerName)
            if let spaceNote, !spaceNote.isEmpty { message += "\n" + CallOwnAccount.standingNote(spaceNote, owner: BotPrompts.ownerName) }
            if let stance = XAccountSettings.stance.instruction(target: XAccountSettings.stanceTarget) { message += "\n" + stance }
            if let tone = XAccountSettings.tone.instruction(custom: XAccountSettings.toneCustom) { message += "\n" + tone }
            if lastReplyWasNotHeard {
                message = "(Your last reply wasn't heard in the Space: the voice couldn't play it. It doesn't count as said.)\n" + message
                lastReplyWasNotHeard = false
            }
            turnHadTheBoss = heard.contains { SpaceBoss.isBoss($0.speaker, bossNames: ownAccount?.bossNames ?? []) }
            ask(message,
                acknowledgesIfSlow: isAddressed)
            return
        }
        // A group: what was heard, by who it sounded like, and Vello answers only when it fits ([PASS] otherwise).
        if isGroupMode {
            let heard = groupLines ?? [CallGroupMode.HeardLine(isOwner: true, text: words)]
            let isAddressed = CallGroupMode.isAddressed(words, assistantNames: assistantNames)
            ask(CallGroupMode.message(lines: heard, owner: owner, botName: botName, isAddressed: isAddressed, passesInARow: groupPassesInARow),
                acknowledgesIfSlow: isAddressed)
            return
        }
        // Back from Listen mode with things Vello hasn't been given yet: they come with this turn.
        if listenTranscript.hasUnsent {
            ask(listenTranscript.messageForVello(asking: words, owner: owner, staysInListenMode: false), acknowledgesIfSlow: true)
            return
        }
        ask(words, acknowledgesIfSlow: true, ownerWords: words)
    }

    /// Whether group talk calls the bot: in a Space on its own account, its name one letter off counts too
    /// (ClickyCore `CallOwnAccount.isAddressed`).
    private func isAddressedInTheGroup(_ words: String) -> Bool {
        isOwnAccount ? CallOwnAccount.isAddressed(words, botName: botName, assistantNames: assistantNames)
            : CallGroupMode.isAddressed(words, assistantNames: assistantNames)
    }

    /// Vello's name as the ears hear it: its own name and the usual mishearings.
    private var assistantNames: [String] {
        // Another bot also answers to a word of its name on its own ("Observer"), as people call it.
        CallListenMode.names(forBotNamed: bot?.name ?? store.primary?.name)
    }

    func setListenMode(_ on: Bool) {
        // A Space on Vello's own account is always in group mode, never Listen mode.
        if on, isOwnAccount { return }
        if on { startListenMode(announce: false) } else { stopListenMode(announce: false) }
    }

    /// Group mode on or off: from the call window, the owner's words, or Vello's own [GROUP: on].
    func setGroupMode(_ on: Bool) {
        guard on != isGroupMode, on || !isOwnAccount else { return }
        isGroupMode = on
        callLog("📞 Call: group mode \(on ? "on" : "off")")
        // What's held so far was all taken as one voice: from here it's marked by speaker.
        heldGroupLines = on && !heldTurnWords.isEmpty ? [CallGroupMode.HeardLine(isOwner: true, text: heldTurnWords)] : []
    }

    private func startListenMode(announce: Bool) {
        guard !isListenMode else { return }
        isListenMode = true
        if announce { sayWithoutThinking("Okay, I'll just listen. Ask me what I think whenever you want.") }
    }

    private func stopListenMode(announce: Bool) {
        guard isListenMode else { return }
        isListenMode = false
        if announce { sayWithoutThinking("Okay, I'm back to talking.") }
    }

    /// A few fixed words, spoken at once with no turn for the brain: Listen mode's acknowledgements.
    private func sayWithoutThinking(_ text: String) {
        guard state != .ended, !replyInProgress else { return }
        pendingTurnTiming = nil
        lines.append(Line(who: .theo, text: text, isLive: false))
        state = .thinking
        speak(text)
        voice?.endOfTurn()
    }

    // MARK: Words out

    /// `acknowledgesIfSlow`: an answer to the owner. If none of it has sounded `CallQuietLimit.acknowledgeAfterSeconds`
    /// after the turn was let go, Vello says a few words first, so a slow answer never sounds like it wasn't heard.
    private func ask(_ text: String, images: [ClaudeContentBlock] = [], acknowledgesIfSlow: Bool = false, isScreenWork: Bool = false,
                     ownerWords: String? = nil) {
        guard let brain else { return }
        replyIsScreenWork = isScreenWork
        replyHadBlock = false
        replyStartedSteps = false
        looksAfterReply = nil
        if let ownerWords { replyOwnerWords = ownerWords }
        turnNumber += 1
        let turn = turnNumber
        state = isOwnerSpeaking ? .userSpeaking : .thinking
        heardAt = Date()
        firstTextAt = nil
        var timing = TurnTiming(ears: earsName, voice: voiceName)
        if let speechEndedAt { timing.heard = Date().timeIntervalSince(speechEndedAt) }
        pendingTurnTiming = timing
        replyInProgress = true
        turnHasSounded = false
        speaksNoMoreThisTurn = false
        stopsAfterThisSentence = false
        audio.resetLoudness()
        turnActedOnTheCall = false
        turnPassed = false
        rawAnswerOfThisTurn = ""
        chunker = CallSpeechChunker()
        orders = ClickyOrderStream()
        controls = CallControlStream()
        screenPieces = CallScreenStream()
        bracketLines = CallBracketLineStream()
        let line = Line(who: .theo, text: "", isLive: true)
        lines.append(line)
        theoLineID = line.id
        let note = pendingLanguageNote
        pendingLanguageNote = ""
        brain.send(note + text, images: images, onDelta: { [weak self] delta in
            guard let self, self.turnNumber == turn, self.replyInProgress else { return }
            self.replyDelta(delta)
        }, onDone: { [weak self] result in
            guard let self, self.turnNumber == turn, self.replyInProgress else { return }
            self.replyFinished(result)
        })
        if acknowledgesIfSlow { acknowledgeIfStillQuiet(turn: turn) }
    }

    private func acknowledgeIfStillQuiet(turn: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CallQuietLimit.acknowledgeAfterSeconds * 1_000_000_000))
            guard let self, self.state != .ended, self.turnNumber == turn, self.replyInProgress,
                  !self.turnHasSounded, !self.audio.isVoicePlaying, !self.isOwnerSpeaking else { return }
            let speaksHindi = self.language == .hindi || self.language.meansHinglish
            let words = CallQuietLimit.acknowledgement(speaksHindi: speaksHindi, readsDevanagari: self.voice is SarvamCallVoice, turnNumber: turn)
            callLog("📞 Call: the answer is slow, saying a few words first")
            self.speak(words)
        }
    }

    private func replyDelta(_ rawDelta: String) {
        rawAnswerOfThisTurn += rawDelta
        if firstTextAt == nil {
            firstTextAt = Date()
            if let speechEndedAt { pendingTurnTiming?.firstText = firstTextAt?.timeIntervalSince(speechEndedAt) }
        }
        let delta: String
        if hasCallControls {
            let looked = screenPieces.feed(rawDelta)
            looked.pieces.forEach(takeScreenPiece)
            let switched = controls.feed(looked.speech)
            switched.controls.forEach(carryOut)
            let filtered = orders.feed(switched.speech)
            filtered.orders.forEach(orderClicky)
            delta = filtered.speech
        } else {
            // Another bot has none of Vello's controls: its bracket lines are taken out and never spoken.
            delta = bracketLines.feed(rawDelta)
        }
        guard !delta.isEmpty else { return }
        if let theoLineID, let index = lines.firstIndex(where: { $0.id == theoLineID }) { lines[index].text += delta }
        for piece in chunker.feed(delta) { speak(piece) }
        // Nothing more for a moment and the sentence looks done: say it, rather than wait for the end of the reply.
        flushTimer?.cancel()
        flushTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, self.replyInProgress, let piece = self.chunker.flushFinishedSentence() else { return }
            self.speak(piece)
        }
    }

    private func speak(_ piece: String) {
        // In a Space: nothing more once someone talked over it, and only what the voice can read (Gurmukhi was silent).
        if isOwnAccount, speaksNoMoreThisTurn { return }
        var text = CallPrompt.speakable(piece)
        if isOwnAccount { text = SpeakableText.speakable(text) }
        guard !text.isEmpty else { return }
        voice?.speak(text)
        // The rest of the sentence is said; at its end the bot stops for whoever talked over it.
        if isOwnAccount, stopsAfterThisSentence, let last = text.trimmingCharacters(in: .whitespaces).last, ".?!।…".contains(last) {
            speaksNoMoreThisTurn = true
            voice?.endOfTurn()
        }
    }

    private func replyFinished(_ result: Result<String, Error>) {
        replyInProgress = false
        restartsOfThisAnswer = 0
        lastReleasedTurn = nil
        let neverStreamed = firstTextAt == nil
        var unstreamed = ""
        let restSpeech: String
        if hasCallControls {
            if case .success(let whole) = result, neverStreamed {
                let looked = CallScreenStream.extract(from: whole)
                looked.pieces.forEach(takeScreenPiece)
                let switched = CallControlStream.extract(from: looked.text)
                switched.controls.forEach(carryOut)
                let taken = ClickyOrder.extract(from: switched.text)
                unstreamed = taken.text
                taken.orders.forEach(orderClicky)
            }
            let lookedRest = screenPieces.finish()
            lookedRest.pieces.forEach(takeScreenPiece)
            let switchedMore = controls.feed(lookedRest.speech)
            switchedMore.controls.forEach(carryOut)
            let switchedRest = controls.finish()
            switchedRest.controls.forEach(carryOut)
            let tail = orders.feed(switchedMore.speech + switchedRest.speech)
            tail.orders.forEach(orderClicky)
            let finished = orders.finish()
            finished.orders.forEach(orderClicky)
            restSpeech = tail.speech + finished.speech
        } else {
            if case .success(let whole) = result, neverStreamed { unstreamed = CallBracketLineStream.strip(whole) }
            restSpeech = bracketLines.finish()
        }
        var answerText = ""
        if let theoLineID, let index = lines.firstIndex(where: { $0.id == theoLineID }) {
            lines[index].isLive = false
            lines[index].text += restSpeech
            if lines[index].text.isEmpty { lines[index].text = unstreamed }
            // A tag taken off the end leaves its line break behind.
            lines[index].text = lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            answerText = lines[index].text
        }
        let emptyLineID = theoLineID
        theoLineID = nil
        // [PASS]: Vello chose to say nothing this turn. Another bot's bracket lines are all taken out, so its [PASS] is
        // found in what it wrote.
        if case .success(let whole) = result, turnPassed || CallGroupMode.saysPass(rawAnswerOfThisTurn + (neverStreamed ? whole : "")) {
            turnPassed = true
            turnActedOnTheCall = true
        }
        if turnPassed, answerText.isEmpty, unstreamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || CallGroupMode.saysPass(unstreamed) {
            flushTimer?.cancel()
            if let emptyLineID { lines.removeAll { $0.id == emptyLineID } }
            if state == .thinking { state = .listening }
            voice?.endOfTurn()
            groupPassesInARow += 1
            callLog("📞 Call: \(botName) let that one pass (\(groupPassesInARow) in a row)")
            return
        }
        switch result {
        case .success where CallBrainFailure.isSilentAnswer(spokenText: answerText + unstreamed, actedOnTheCall: turnActedOnTheCall):
            // The turn "succeeded" with nothing to say (Air, 24 Nov: after a model switch Vello went quiet with no error).
            // Said out loud like any failure, so it never sounds like the call went dead.
            flushTimer?.cancel()
            if let emptyLineID { lines.removeAll { $0.id == emptyLineID } }
            problem = "\(brainNameForWords): \(CallBrainFailure.emptyAnswerReason.lowercased())."
            if state == .thinking { state = .listening }
            sayTheBrainFailed(CallBrainFailure.emptyAnswerReason)
        case .success:
            // A reply that never streamed (a CLI that gave only its result) still gets spoken.
            flushTimer?.cancel()
            if neverStreamed { for piece in chunker.feed(unstreamed) { speak(piece) } }
            for piece in chunker.feed(restSpeech) { speak(piece) }
            if let piece = chunker.finish() { speak(piece) }
            voice?.endOfTurn()
            if isOwnAccount {
                // The boss switched the stance ([STANCE: debate PEW]): kept for this Space and the next.
                if turnHadTheBoss, let command = SpaceStance.command(in: rawAnswerOfThisTurn) {
                    XAccountSettings.setStance(command.stance, target: command.target)
                    callLog("📞 Space: the boss switched the stance to \(command.stance.rawValue)\(command.target.isEmpty ? "" : " for \(command.target)")")
                }
                if turnHadTheBoss, let command = SpaceTone.command(in: rawAnswerOfThisTurn) {
                    XAccountSettings.setTone(command.tone, custom: command.custom)
                    callLog("📞 Space: the boss switched the tone to \(command.tone.rawValue)")
                }
                if let emptyLineID, !answerText.isEmpty { checkTheReplyWasHeard(lineID: emptyLineID, text: answerText, turn: turnNumber, isRetry: false) }
            }
        case .failure(let error):
            problem = error.localizedDescription
            if state == .thinking { state = .listening }
            sayTheBrainFailed(error.localizedDescription)
        }
        if hasCallControls {
            var failed = false
            if case .failure = result { failed = true }
            screenReplyEnded(failed: failed)
        }
    }

    /// In a Space, whether a reply really reached the virtual mic: the voice's audio for it must have had some sound. If it
    /// didn't (an empty clip, a script the voice can't read, a voice error), it's said once more in Roman letters; if that
    /// fails too, the line is marked not heard and the brain is told with the next turn. The bot thought it had spoken
    /// when nobody heard a thing (a public Space, 25 Nov).
    private func checkTheReplyWasHeard(lineID: UUID, text: String, turn: Int, isRetry: Bool) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for _ in 0..<120 {
                guard let self, self.state != .ended, self.turnNumber == turn else { return }
                if !self.audio.isVoicePlaying && self.state != .speaking { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let self, self.state != .ended, self.turnNumber == turn, !self.speaksNoMoreThisTurn else { return }
            if self.audio.loudestDecibelsSinceReset > -55 { return }
            if !isRetry {
                callLog("📞 Space: that reply made no sound, saying it again in Roman letters")
                self.audio.resetLoudness()
                let roman = SpeakableText.speakable(text).applyingTransform(.toLatin, reverse: false) ?? text
                self.voice?.speak(CallPrompt.speakable(roman))
                self.voice?.endOfTurn()
                self.checkTheReplyWasHeard(lineID: lineID, text: text, turn: turn, isRetry: true)
                return
            }
            callLog("📞 Space: not heard (the voice couldn't play it)")
            if let index = self.lines.firstIndex(where: { $0.id == lineID }) { self.lines[index].wasNotHeard = true }
            self.lastReplyWasNotHeard = true
        }
    }

    /// The brain gave no answer: say so out loud, with the reason, rather than go quiet. A call that only set its window's
    /// problem line sounded on the phone like the bot had gone mute.
    private func sayTheBrainFailed(_ detail: String) {
        guard state != .ended, !CallBrainFailure.isTheCallsOwnDoing(detail) else { return }
        callLog("📞 Call: \(brainNameForWords) gave no answer: \(CallBrainFailure.shortReason(detail))")
        let speaksHindi = language == .hindi || language.meansHinglish
        // In a public Space the brain's name and error mean nothing to anyone: a short sorry, the reason in the window.
        let words = isOwnAccount
            ? CallOwnAccount.brainFailureWords(speaksHindi: speaksHindi, readsDevanagari: voice is SarvamCallVoice, failuresSoFar: brainFailures)
            : CallBrainFailure.spokenWords(brainName: brainNameForWords, detail: detail, failuresSoFar: brainFailures,
                                           speaksHindi: speaksHindi, readsDevanagari: voice is SarvamCallVoice)
        brainFailures += 1
        sayWithoutThinking(words)
    }

    /// Theo gave Clicky an order on the call. What Clicky says comes back to him as his next turn, once nobody's talking.
    private func orderClicky(_ order: String) {
        turnActedOnTheCall = true
        // There's no Pointer Assistant between Vello and the screen any more: a line for it out of habit is done by Vello's
        // own hands, after Vello sees the screen. [TELL: …] lines still go to their bots.
        if VelloHands.isOn, ClickyOrder.tellTarget(in: order) == nil {
            looksAfterReply = CallHands.pointerOrderNote(order: order, owner: BotPrompts.ownerName)
            return
        }
        let addySaid = lines.filter { $0.who == .addy && !$0.isLive }.suffix(6).reversed().map(\.text).joined(separator: "\n")
        // Clicky's helpers finish after Clicky's first answer: their reports come here too.
        store.onCEOReport = { [weak self] report in self?.reportArrived(report) }
        let toPointerAssistant = ClickyOrder.tellTarget(in: order) == nil
        store.carryOutOrder(order, ownerWords: addySaid) { [weak self] report in
            self?.reportArrived(toPointerAssistant ? "Pointer Assistant: \(report)" : report)
        }
    }

    /// One of the call's own switches. Everything said on a call is the owner's own voice, so these run straight away.
    private func carryOut(_ control: CallControl) {
        turnActedOnTheCall = true
        switch control {
        case .pointerAssistant(let turnOn):
            // [POINTER: on|off] is Vello's own hands now: seeing and using the screen on calls.
            VelloHands.set(turnOn)
            if !turnOn { CompanionManager.current?.actionTaskController.endCallTask() }
            store.post(BotChatMessage(author: BotsStore.noteAuthor, text: "Vello's use of the screen is \(turnOn ? "on" : "off"), as asked on the call."), to: store.primary?.id ?? "theo")
        case .runRoutine(let name):
            let routines = store.routines
            guard let index = CallControl.routine(named: name, among: routines.map(\.name)) else {
                let names = routines.map(\.name)
                reportArrived(names.isEmpty
                    ? "There are no routines yet, so nothing ran. You can set one up in your text chat."
                    : "No routine matched \"\(name)\", so nothing ran. The routines are: \(names.joined(separator: ", ")).")
                return
            }
            store.runRoutineNow(routines[index].id)
        case .groupMode(let turnOn):
            setGroupMode(turnOn)
        case .stayQuiet:
            turnPassed = true
        }
    }

    private func reportArrived(_ report: String) {
        guard state != .ended else { return }
        clickyReports.append(report)
        Task { @MainActor [weak self] in
            for _ in 0..<90 {
                guard let self, self.state != .ended, !self.clickyReports.isEmpty else { return }
                if self.state == .listening, !self.replyInProgress, !self.audio.isVoicePlaying, !self.isOwnerSpeaking, self.heldTurnWords.isEmpty {
                    self.speechEndedAt = nil
                    self.lastReleasedTurn = nil
                    self.ask(ClickyTeamPrompts.theoFromCallNote(report: self.clickyReports.removeFirst(), owner: BotPrompts.ownerName))
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func voiceStartedSounding() {
        turnHasSounded = true
        groupPassesInARow = 0
        restartsOfThisAnswer = 0
        lastReleasedTurn = nil
        if let speechEndedAt {
            let seconds = Date().timeIntervalSince(speechEndedAt)
            pendingTurnTiming?.firstAudio = seconds
            lastFirstAudio = seconds
            callLog("📞 Call: \(botName) is speaking, \(String(format: "%.1f", seconds)) s after the voice stopped (ears: \(earsName), voice: \(voiceName))")
        } else {
            callLog("📞 Call: \(botName) is speaking (ears: \(earsName), voice: \(voiceName))")
        }
        if var timing = pendingTurnTiming, speechEndedAt != nil {
            timing.ears = earsName
            timing.voice = voiceName
            timings.append(timing)
            pendingTurnTiming = nil
        }
        if state == .thinking { state = .speaking }
    }

    private func voiceDrained() {
        (voice as? SarvamCallVoice)?.audioDrained()
        (voice as? AppleCallVoice)?.audioDrained()
    }

    private func voiceFinished() {
        voiceLastStoppedAt = Date()
        if state == .speaking || state == .thinking { state = .listening }
    }

    // MARK: Vello's hands

    /// A [LOOK] or an <actions> block in Vello's reply.
    private func takeScreenPiece(_ piece: CallScreenPiece) {
        turnActedOnTheCall = true
        switch piece {
        case .look:
            print("🖐️ Vello's hands: asked to look")
            if looksAfterReply == nil, !replyStartedSteps { looksAfterReply = CallHands.lookMessage(owner: BotPrompts.ownerName) }
        case .actions(let body):
            replyHadBlock = true
            startSteps(body)
        }
    }

    /// Runs a block Vello wrote. Steps with badge numbers need the screen Vello last saw to be recent; otherwise Vello is
    /// shown the screen again first, since a number from an old screen could press the wrong thing.
    private func startSteps(_ body: String) {
        guard let manager = CompanionManager.current else { return }
        let owner = BotPrompts.ownerName
        guard VelloHands.isOn else {
            looksAfterReply = nil
            waitingScreenTurns.append(("(Vello's eyes, not \(owner) speaking: using the screen is switched off, so nothing ran. Say so, and offer to switch it on.)", false))
            pumpScreenTurns()
            return
        }
        var usesBadgeNumbers = false
        if case .success(let plan) = ActionDSL.parse(body) { usesBadgeNumbers = plan.steps.contains { !$0.referencedElementIDs.isEmpty } }
        let screenIsRecent = lastShownScreenAt.map { Date().timeIntervalSince($0) < VelloHands.badgeNumbersLastSeconds } ?? false
        if usesBadgeNumbers, !screenIsRecent || lastShownScreen == nil {
            looksAfterReply = "(Vello's eyes, not \(owner) speaking: those steps used numbers from a screen you saw a while ago, so nothing ran. Here is the screen now with new numbers; write the steps again.)"
            return
        }
        let ownerWords = replyOwnerWords
        let replyStillOpen = replyInProgress
        // The steps look again when they end, so a [LOOK] in this reply (before or after the block) isn't sent as well.
        replyStartedSteps = true
        looksAfterReply = nil
        Task { @MainActor [weak self] in
            guard let self, self.state != .ended else { return }
            var grounded = self.lastShownScreen
            if grounded == nil { grounded = await self.captureScreen() }
            guard let grounded else {
                self.waitingScreenTurns.append(("(Vello's eyes, not \(owner) speaking: the screen couldn't be read, so nothing ran. Say so.)", false))
                self.pumpScreenTurns()
                return
            }
            let trouble = manager.actionTaskController.handleCallActionsBlock(body, groundedTurn: grounded, ownerWords: ownerWords, hooks: self.screenHooks())
            if let trouble {
                self.waitingScreenTurns.append(("(Vello's eyes, not \(owner) speaking: \(trouble))", false))
                self.pumpScreenTurns()
            } else if !replyStillOpen || !self.replyInProgress {
                // The reply that carried the steps already ended: the task mustn't wait for it.
                manager.actionTaskController.callTurnDidFinish(hadBlock: true, failed: false)
            }
            print("🖐️ Vello's hands: steps started")
        }
    }

    private func screenHooks() -> ActionTaskController.CallTaskHooks {
        ActionTaskController.CallTaskHooks(
            speak: { [weak self] line in self?.sayAside(line) },
            wantsObserveTurn: { [weak self] continuation in
                guard let self else { return }
                self.waitingScreenTurns.append((CallHands.observeMessage(continuation: continuation, owner: BotPrompts.ownerName), true))
                self.pumpScreenTurns()
            },
            ended: { [weak self] report, status, cancelReason in
                guard let self, self.state != .ended else { return }
                print("🖐️ Vello's hands: work \(status.rawValue)\(cancelReason.map { " (\($0))" } ?? "")")
                // Done: Vello already said so in its last answer. Anything else is told to Vello, who tells the owner.
                guard status != .done else { return }
                self.waitingScreenTurns.removeAll { $0.isObserveTurn }
                self.waitingScreenTurns.append((CallHands.workStopped(report: report, owner: BotPrompts.ownerName), false))
                self.pumpScreenTurns()
            })
    }

    /// A screen turn's reply ended (or was cut off): the task hears it, and a [LOOK] shows the screen next.
    private func screenReplyEnded(failed: Bool) {
        guard let manager = CompanionManager.current else { return }
        if replyIsScreenWork || replyHadBlock {
            manager.actionTaskController.callTurnDidFinish(hadBlock: replyHadBlock, failed: failed)
        }
        replyIsScreenWork = false
        replyHadBlock = false
        if let look = looksAfterReply, !failed {
            looksAfterReply = nil
            waitingScreenTurns.append((look, false))
            pumpScreenTurns()
        }
    }

    /// Sends the waiting screen turns one at a time, each once the call is free: no answer being written, the owner not
    /// talking and no turn of theirs held. Vello's voice may still be playing: the next line queues behind it, so it keeps
    /// talking through a long job.
    private func pumpScreenTurns() {
        guard screenTurnPump == nil else { return }
        screenTurnPump = Task { @MainActor [weak self] in
            defer { self?.screenTurnPump = nil }
            while let self, self.state != .ended, !self.waitingScreenTurns.isEmpty {
                guard !Task.isCancelled else { return }
                let stepsUnderWay = CompanionManager.current?.actionTaskController.isCallBatchUnderWay == true
                if self.replyInProgress || self.isOwnerSpeaking || !self.heldTurnWords.isEmpty || self.isHoldingTurn || stepsUnderWay {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continue
                }
                let next = self.waitingScreenTurns.removeFirst()
                // A task's next look is moot once the task has ended (the owner spoke, the mouse moved).
                if next.isObserveTurn, CompanionManager.current?.actionTaskController.isRunningCallTask != true { continue }
                let screen = await self.captureScreen()
                guard self.state != .ended, !self.replyInProgress, !self.isOwnerSpeaking, self.heldTurnWords.isEmpty else {
                    self.waitingScreenTurns.insert(next, at: 0)
                    continue
                }
                if next.isObserveTurn, CompanionManager.current?.actionTaskController.isRunningCallTask != true { continue }
                self.speechEndedAt = nil
                self.ask(next.text, images: screen?.contentBlocks ?? [], isScreenWork: next.isObserveTurn)
            }
        }
    }

    /// The screen as Vello's brain sees it: every display's badged screenshot and element list (the same grounding Pointer
    /// Assistant used). Kept as the screen the next block's numbers refer to.
    private func captureScreen() async -> GroundedTurn? {
        guard let manager = CompanionManager.current else { return nil }
        do {
            let grounded = try await manager.groundingCoordinator.prepareTurn(keyUpDate: Date())
            lastShownScreen = grounded
            lastShownScreenAt = Date()
            return grounded
        } catch {
            print("🖐️ Vello's hands: the screen couldn't be read: \(error)")
            return nil
        }
    }

    /// The owner's turn while Vello works on screen. True when it was a yes or no to a waiting step and needs nothing more.
    private func ownerWordsReachTheScreenWork(_ words: String) -> Bool {
        guard let manager = CompanionManager.current else { return false }
        let owner = BotPrompts.ownerName
        switch manager.actionTaskController.takeCallOwnerWords(words, ownerName: owner) {
        case .noCallTask:
            return false
        case .answeredConfirmation:
            print("🖐️ Vello's hands: the owner answered a step waiting for a yes")
            return true
        case .pausedWork(let report):
            print("🖐️ Vello's hands: paused for the owner's words")
            waitingScreenTurns.removeAll { $0.isObserveTurn }
            Task { @MainActor [weak self] in
                guard let self, self.state != .ended else { return }
                let screen = await self.captureScreen()
                guard self.state != .ended else { return }
                self.ask(CallHands.ownerSpokeDuringWork(words: words, report: report, owner: owner), images: screen?.contentBlocks ?? [],
                         acknowledgesIfSlow: true, ownerWords: words)
            }
            return true
        }
    }

    /// A line said by the work itself (a refusal, a yes to wait for), through the call's voice, without a turn for the brain.
    private func sayAside(_ text: String) {
        guard state != .ended else { return }
        let words = CallPrompt.speakable(text)
        guard !words.isEmpty else { return }
        lines.append(Line(who: .theo, text: words, isLive: false))
        voice?.speak(words)
        if !replyInProgress { voice?.endOfTurn() }
    }

    // MARK: Test files

    /// `uiCallFeed`: a sound file in place of the mic, at real-time pace. With `trailingSilence` it's followed by quiet.
    func feed(fileURL: URL, trailingSilence: Double) async -> Bool {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return false }
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.05)
        while file.framePosition < file.length, state != .ended {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames), (try? file.read(into: buffer, frameCount: frames)) != nil, buffer.frameLength > 0 else { break }
            audio.feed(buffer)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let silence = Int(trailingSilence / 0.05)
        for _ in 0..<silence where state != .ended {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            buffer.frameLength = frames
            // Room noise rather than digital silence, so the gate sees a real floor.
            if let channel = buffer.floatChannelData?[0] { for index in 0..<Int(frames) { channel[index] = Float.random(in: -0.0005...0.0005) } }
            audio.feed(buffer)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// A Space on Vello's own account: its handle, what it hears and where its voice goes, and who it has seen talking.
    private var ownAccountReport: [String: Any]? {
        guard let ownAccount else { return nil }
        var report = audio.ownAccountReport
        report["handle"] = ownAccount.handle
        report["browser"] = ownAccount.browser?.bundleID ?? ""
        report["currentSpeaker"] = currentSpeaker ?? ""
        report["bot"] = bot?.id ?? ""
        report["speakers"] = speakerWatcher?.report() ?? [:]
        return report
    }

    /// `ownAccountLook`: one frame of the speaker watcher now, whoever is talking.
    func lookForSpeakerNow(savingTo fileURL: URL? = nil) async -> [String: Any] {
        guard let speakerWatcher else { return ["error": "No speaker watcher."] }
        await speakerWatcher.lookOnce(savingTo: fileURL)
        return speakerWatcher.report()
    }

    /// What `uiCallStatus` shows.
    func report() -> [String: Any] {
        [
            "state": String(describing: state), "ears": earsName, "voice": voiceName, "muted": isMuted, "problem": problem ?? "",
            "botID": botID, "botName": botName, "isVellosOwnBot": isVellosOwnBot, "botCallVoice": bot?.callVoice ?? "",
            "appleVoiceUsed": (voice as? AppleCallVoice)?.ownVoice?.identifier ?? "",
            "timings": timings.map { timing in
                ["heardSeconds": timing.heard as Any? ?? NSNull(), "firstTextSeconds": timing.firstText as Any? ?? NSNull(),
                 "firstAudioSeconds": timing.firstAudio as Any? ?? NSNull(), "ears": timing.ears, "voice": timing.voice] as [String: Any]
            },
            "bargeInSeconds": bargeIns,
            "turnWaitSeconds": turnWaits,
            "echoesDropped": echoesDropped,
            "nearVoiceOnly": nearVoiceOnly,
            "ownerLevelDecibels": nearVoice.ownerLevelDecibels as Any? ?? NSNull(),
            "farVoicesIgnored": farVoicesIgnored,
            "farWordsDropped": farWordsDropped,
            "patienceSeconds": CallSettings.patienceSeconds,
            "listenMode": isListenMode,
            "groupMode": isGroupMode,
            "holdingTurn": isHoldingTurn,
            "ownAccount": ownAccountReport as Any? ?? NSNull(),
            "lines": lines.map { ["who": $0.who == .addy ? "addy" : "theo", "text": $0.text, "live": $0.isLive, "cut": $0.wasCut, "heard": $0.wasOnlyHeard, "group": $0.isGroupTalk] as [String: Any] },
        ]
    }
}
