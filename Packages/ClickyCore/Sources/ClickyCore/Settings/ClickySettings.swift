//
//  ClickySettings.swift
//  ClickyCore
//
//  Clicky v2 settings. New keys use the `v2.` prefix; keys that existed
//  before v2 are reused by their original names (listed in LegacyKeys) so
//  nobody loses their choices.
//

import Foundation

public enum ClickySettings {
    /// Pre-v2 keys, reused as-is (see docs/v2/INVENTORY.md).
    public enum LegacyKeys {
        public static let usesQwenLocalVoice = "usesQwenLocalVoice"
        public static let selectedSpeechVoiceIdentifier = "selectedSpeechVoiceIdentifier"
        public static let selectedClaudeCodeModelAlias = "selectedClaudeCodeModelAlias"
        public static let isClickyCursorEnabled = "isClickyCursorEnabled"
        public static let handsFreeEchoCancellationDisabled = "handsFreeEchoCancellationDisabled"
    }

    public enum Keys {
        public static let groundingEnabled = "v2.grounding.enabled"
        public static let groundingImageTier = "v2.grounding.imageTier"
        public static let groundingProbe = "v2.grounding.probe"
        /// Bool, default true: draw id badges on the images (A/B switch).
        public static let groundingBadges = "v2.grounding.badges"
        /// Bool, default false: P6.1 asks Haiku to check tentative marks on a zoomed crop
        /// (and P6.3 keeps a Haiku process waiting for it from key-down).
        public static let groundingVerifyWithHaiku = "v2.grounding.verifyWithHaiku"
        /// [String] bundle ids whose field values are never read.
        public static let groundingValueBlockedBundleIDs = "v2.grounding.valueBlockedBundleIDs"
        /// [String] bundle ids that get AXEnhancedUserInterface while frontmost
        /// ("electron" = any detected Electron app). See EnhancedUserInterfacePolicy.
        public static let groundingEnhancedUIBundleIDs = "v2.grounding.enhancedUIBundleIDs"
        /// Int, most marks on screen at once (the oldest goes first). Default 9.
        public static let marksMax = "v2.marks.max"
        /// Bool, follow AX-backed marks as their elements scroll/move. Default true.
        public static let marksTrackAX = "v2.marks.trackAX"
        /// "attached" (default: each note in a small pill right beside its
        /// mark, chip + bubble legend when there's no room), "nearCursor"
        /// (numbered chips on the marks, their words in the caption bubble)
        /// or "column" (labels in a column with leaders).
        public static let marksLabelStyle = "v2.marks.labelStyle"
        /// "open" (default: mic stays open while Clicky talks), "halfDuplex",
        /// or "aec" (P6.4: both voices play through the mic's engine with
        /// voice processing on; headphones stay open, a failure → halfDuplex).
        public static let voiceEchoMode = "v2.voice.echoMode"
        /// Int, caption bubble lines (default 4).
        public static let captionMaxLines = "v2.caption.maxLines"
        /// Double, caption bubble width in pt (default 360, 280–480).
        public static let captionMaxWidth = "v2.caption.maxWidth"
        /// Double, ms added to the Qwen audio clock for captions (default 0).
        public static let captionAVOffsetMs = "v2.caption.avOffsetMs"
        /// Bool gates for the P4/P5/P6 prompt sections (default off).
        public static let whiteboardAuto = "v2.whiteboard.auto"
        /// String "paper" (default), "chalk" or "dark": the board's look.
        public static let whiteboardTheme = "v2.whiteboard.theme"
        /// Bool, default false: the board panel fills the screen's visible frame.
        public static let whiteboardFullScreen = "v2.whiteboard.fullScreen"
        public static let codeEnabled = "v2.code.enabled"
        public static let typeForMeEnabled = "v2.typeForMe.enabled"
        /// Bool, default true: P7 computer-use actions (<actions> blocks: open apps, click, type, highlight, summarize).
        public static let actionsEnabled = "v2.actions.enabled"
        /// Double, default 1.5 (0.5–5): the on-screen countdown before typing or an ordinary click.
        public static let actionsCountdownSeconds = "v2.actions.countdownSeconds"
        /// [String] bundle ids Clicky never types into (default: password managers, Keychain Access).
        public static let typeForMeBlockedBundleIDs = "v2.typeForMe.blockedBundleIDs"
        /// String "low"/"medium"/"high": forces --effort for every answer (evals).
        public static let claudeEffortOverride = "v2.claude.effortOverride"
        /// String, Qwen CustomVoice speaker (default "Ryan"; the Base model ignores it).
        public static let qwenSpeaker = "v2.voice.qwen.speaker"
        /// String, Qwen style instruction (default: none — the speaker's own delivery).
        public static let qwenInstruct = "v2.voice.qwen.instruct"
        /// Double, playback rate for both voices: 0.85, 1.0 (default), 1.15, 1.3.
        public static let voiceRate = "v2.voice.rate"
        /// Int, debug only: send Qwen requests to this port instead of 11234
        /// (a closed port tests the Apple fallback). Clicky never spawns on it.
        public static let ttsPortOverride = "v2.debug.ttsPortOverride"
        /// String path, the WAV every Qwen segment clones (default ~/.clicky/voice/clicky-voice.wav).
        public static let qwenReferenceClip = "v2.voice.qwen.referenceClip"
        /// String, the voice-gallery entry id that was active before the last switch ("previous voice"). Written by the gallery.
        public static let voiceGalleryPrevious = "v2.voice.gallery.previous"
        /// Bool, default false: the code agent may get Bash (set true only by a passing sandbox probe).
        public static let codeBashAllowed = "v2.code.bashAllowed"
        /// [String], default ["~/Projects", "~/Developer"]: folders scanned for local clones.
        public static let codeRepoRoots = "v2.code.repoRoots"
        /// [String: String]: a spoken project name ("mahajan motor work") → the folder the owner picked for it.
        public static let codeProjectAliases = "v2.code.projectAliases"
        /// Bool, default true: short spoken updates (at most every 20 s) while the code agent works.
        public static let codeNarrateProgress = "v2.code.narrateProgress"
        /// Bool, default false: keep the Qwen server running from a LaunchAgent (also needs keepWarmAgentApproved).
        public static let keepWarmAgent = "v2.voice.keepWarmAgent"
        /// Bool, default false: the user said yes to installing the keep-warm LaunchAgent.
        public static let keepWarmAgentApproved = "v2.voice.keepWarmAgentApproved"
        /// Bool, default true: a click on the resting companion spark opens the
        /// Agents dashboard (the spark holds still while the pointer rests near it).
        public static let agentsSparkClickOpensDashboard = "v2.agents.sparkClickOpensDashboard"
        /// Int, finished agents kept in agents-history.json (default 50).
        public static let agentsHistoryLimit = "v2.agents.historyLimit"
        /// Bool, default true: the Dynamic Island-style pill at the top of the screen.
        public static let notchEnabled = "v2.notch.enabled"
        /// "main" (default: the display with the menu bar, screens[0]) or "cursor".
        public static let notchDisplay = "v2.notch.display"
        /// Bool, default true: hide the pill while a full-screen app covers its display.
        public static let notchHideOverFullscreen = "v2.notch.hideOverFullscreen"
        /// Bool, default true: "send this to my project …" writes the task to ~/.clicky/project-outbox.
        public static let projectEnabled = "v2.project.enabled"
        /// Bool, default true: say short updates when the project replies (thread started, done, failed).
        public static let projectSpeakUpdates = "v2.project.speakUpdates"
    }

    public static var qwenReferenceClipPath: String {
        let path = (defaults.string(forKey: Keys.qwenReferenceClip) ?? "").trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? QwenTuning.referenceClipDefaultPath : path
    }

    public static var qwenSpeaker: String {
        let speaker = defaults.string(forKey: Keys.qwenSpeaker) ?? ""
        return QwenTuning.speakers.contains(speaker) ? speaker : QwenTuning.defaultSpeaker
    }

    public static var qwenInstruct: String {
        let instruct = (defaults.string(forKey: Keys.qwenInstruct) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return instruct
    }

    public static var voiceRate: Double {
        get { QwenTuning.nearestRate(to: defaults.object(forKey: Keys.voiceRate) as? Double ?? 1.0) }
        set { defaults.set(QwenTuning.nearestRate(to: newValue), forKey: Keys.voiceRate) }
    }

    public static var ttsPortOverride: Int? {
        guard let port = defaults.object(forKey: Keys.ttsPortOverride) as? Int, (1...65535).contains(port) else { return nil }
        return port
    }

    public static var claudeEffortOverride: String? {
        guard let effort = defaults.string(forKey: Keys.claudeEffortOverride), ["low", "medium", "high"].contains(effort) else { return nil }
        return effort
    }

    public enum EchoMode: String, Sendable {
        case open
        case halfDuplex
        /// Echo cancellation on the shared mic + voice engine (P6.4).
        case aec
    }

    public static var echoMode: EchoMode {
        (defaults.string(forKey: Keys.voiceEchoMode)).flatMap(EchoMode.init(rawValue:)) ?? .open
    }

    public static var captionMaxLines: Int {
        max(1, defaults.object(forKey: Keys.captionMaxLines) as? Int ?? 4)
    }

    public static var captionMaxWidth: Double {
        min(480, max(280, defaults.object(forKey: Keys.captionMaxWidth) as? Double ?? 360))
    }

    public static var captionAVOffsetMilliseconds: Double {
        defaults.object(forKey: Keys.captionAVOffsetMs) as? Double ?? 0
    }

    public static var isWhiteboardAutoEnabled: Bool { defaults.object(forKey: Keys.whiteboardAuto) as? Bool ?? false }
    /// "paper" | "chalk" | "dark"; anything else reads as "paper".
    public static var whiteboardTheme: String {
        let theme = defaults.string(forKey: Keys.whiteboardTheme)?.lowercased() ?? "paper"
        return ["paper", "chalk", "dark"].contains(theme) ? theme : "paper"
    }
    public static var isWhiteboardFullScreen: Bool {
        get { defaults.object(forKey: Keys.whiteboardFullScreen) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.whiteboardFullScreen) }
    }
    public static var isCodeEnabled: Bool { defaults.object(forKey: Keys.codeEnabled) as? Bool ?? false }
    public static var isTypeForMeEnabled: Bool { defaults.object(forKey: Keys.typeForMeEnabled) as? Bool ?? false }
    public static var isActionsEnabled: Bool { defaults.object(forKey: Keys.actionsEnabled) as? Bool ?? true }
    /// Clamped to 0.5…5 s.
    public static var actionsCountdownSeconds: Double {
        min(5, max(0.5, defaults.object(forKey: Keys.actionsCountdownSeconds) as? Double ?? 1.5))
    }

    /// Password managers and Keychain: never read their field values.
    public static let defaultValueBlockedBundleIDs = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.agilebits.onepassword7", "com.1password.1password",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
        "com.callpod.keepermac.lite", "com.nordpass.macos.NordPass", "in.sinew.Enpass-Desktop"
    ]

    public static var valueBlockedBundleIDs: Set<String> {
        Set(defaults.stringArray(forKey: Keys.groundingValueBlockedBundleIDs) ?? defaultValueBlockedBundleIDs)
    }

    /// Chromium/Electron apps whose full AX tree is switched on while frontmost.
    public static var enhancedUIBundleIDs: Set<String> {
        Set(defaults.stringArray(forKey: Keys.groundingEnhancedUIBundleIDs) ?? EnhancedUserInterfacePolicy.defaultBundleIdentifiers)
    }

    public static var areBadgesEnabled: Bool {
        defaults.object(forKey: Keys.groundingBadges) as? Bool ?? true
    }

    public static var isVerifyWithHaikuEnabled: Bool {
        defaults.object(forKey: Keys.groundingVerifyWithHaiku) as? Bool ?? false
    }

    public static var maximumMarks: Int {
        max(1, defaults.object(forKey: Keys.marksMax) as? Int ?? 9)
    }

    public static var isMarkTrackingEnabled: Bool {
        defaults.object(forKey: Keys.marksTrackAX) as? Bool ?? true
    }

    public static var markLabelStyle: MarkLabelStyle {
        defaults.string(forKey: Keys.marksLabelStyle).flatMap(MarkLabelStyle.init(rawValue:)) ?? .attached
    }

    public enum ImageTierSetting: String, Sendable {
        case auto
        case high
        case standard

        /// The tier the cursor screen is sent at.
        public var cursorScreenTier: ImageTier { self == .standard ? .standard : .high }
    }

    /// One model's tier-probe result.
    public struct ProbeRecord: Codable, Equatable, Sendable {
        /// Set when the model sees less than we send; images get capped to it.
        public var effectiveMaxEdge: Int?
        /// The sizes probed, e.g. ["2576x1078", "1920x1080"].
        public var sizes: [String]
        /// Worst error in pixels across the probes that passed.
        public var error: Double
        public var date: Date
        /// Why effectiveMaxEdge is set (e.g. "CLI downscale").
        public var reason: String?

        public init(effectiveMaxEdge: Int?, sizes: [String], error: Double, date: Date, reason: String? = nil) {
            self.effectiveMaxEdge = effectiveMaxEdge
            self.sizes = sizes
            self.error = error
            self.date = date
            self.reason = reason
        }
    }

    private static var defaults: UserDefaults { .standard }

    /// The saved preference. The startup geometry self-check can turn
    /// grounding off for one session without ever writing this.
    public static var isGroundingEnabled: Bool {
        defaults.object(forKey: Keys.groundingEnabled) as? Bool ?? true
    }

    public static var imageTier: ImageTierSetting {
        ImageTierSetting(rawValue: defaults.string(forKey: Keys.groundingImageTier) ?? "") ?? .auto
    }

    /// Tier-probe results keyed by resolved model id.
    public static var probeRecords: [String: ProbeRecord] {
        get {
            guard let probeData = defaults.data(forKey: Keys.groundingProbe) else { return [:] }
            return (try? JSONDecoder().decode([String: ProbeRecord].self, from: probeData)) ?? [:]
        }
        set {
            guard let probeData = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(probeData, forKey: Keys.groundingProbe)
        }
    }

    public static func effectiveMaxEdge(forModelIdentifier modelIdentifier: String?) -> Int? {
        guard let modelIdentifier else { return nil }
        return probeRecords[modelIdentifier]?.effectiveMaxEdge
    }

    // MARK: - P5 Code mode

    /// The home folder itself is scanned one level deep, ~/Projects and ~/Developer three, the rest two (LocalRepoIndexer.maximumDepth(forRoot:)).
    public static let defaultCodeRepoRoots = ["~/Projects", "~/Developer", "~", "~/Documents", "~/Downloads", "~/jstest"]
    public static var isKeepWarmAgentEnabled: Bool { defaults.object(forKey: Keys.keepWarmAgent) as? Bool ?? false }
    public static var isKeepWarmAgentApproved: Bool { defaults.object(forKey: Keys.keepWarmAgentApproved) as? Bool ?? false }
    public static var isCodeBashAllowed: Bool { defaults.object(forKey: Keys.codeBashAllowed) as? Bool ?? false }
    public static var codeRepoRoots: [String] { defaults.stringArray(forKey: Keys.codeRepoRoots) ?? defaultCodeRepoRoots }
    /// The owner's project picks (ProjectAliasBook): an alias match wins outright.
    public static var projectAliases: [String: String] {
        (defaults.dictionary(forKey: Keys.codeProjectAliases) as? [String: String]) ?? [:]
    }
    public static func saveProjectAlias(spokenName: String, path: String) {
        defaults.set(ProjectAliasBook.adding(spokenName: spokenName, path: path, to: projectAliases), forKey: Keys.codeProjectAliases)
    }
    public static func removeProjectAlias(key aliasKey: String) {
        defaults.set(ProjectAliasBook.removing(key: aliasKey, from: projectAliases), forKey: Keys.codeProjectAliases)
    }
    public static var isAgentsSparkClickEnabled: Bool { defaults.object(forKey: Keys.agentsSparkClickOpensDashboard) as? Bool ?? true }
    public static var agentsHistoryLimit: Int { min(500, max(10, defaults.object(forKey: Keys.agentsHistoryLimit) as? Int ?? AgentStore.defaultMaximumFinishedRecords)) }
    public static var isCodeProgressNarrationEnabled: Bool { defaults.object(forKey: Keys.codeNarrateProgress) as? Bool ?? true }

    // MARK: - Notch

    /// Which display the notch pill sits on.
    public enum NotchDisplayChoice: String, CaseIterable, Sendable {
        /// screens[0], the display with the menu bar (never NSScreen.main, which follows focus).
        case main
        /// The display the pointer is on.
        case cursor
    }

    public static var isNotchEnabled: Bool { defaults.object(forKey: Keys.notchEnabled) as? Bool ?? true }
    public static var notchDisplay: NotchDisplayChoice {
        defaults.string(forKey: Keys.notchDisplay).flatMap(NotchDisplayChoice.init(rawValue:)) ?? .main
    }
    public static var isNotchHiddenOverFullScreen: Bool { defaults.object(forKey: Keys.notchHideOverFullscreen) as? Bool ?? true }

    // MARK: - Project bridge

    public static var isProjectBridgeEnabled: Bool { defaults.object(forKey: Keys.projectEnabled) as? Bool ?? true }
    public static var isProjectSpeakUpdatesEnabled: Bool { defaults.object(forKey: Keys.projectSpeakUpdates) as? Bool ?? true }

    // MARK: - P6.2 Type this for me

    /// Password managers and Keychain Access (the same list as valueBlockedBundleIDs).
    public static let defaultTypeForMeBlockedBundleIDs = defaultValueBlockedBundleIDs
    public static var typeForMeBlockedBundleIDs: Set<String> {
        Set(defaults.stringArray(forKey: Keys.typeForMeBlockedBundleIDs) ?? defaultTypeForMeBlockedBundleIDs)
    }
}
