//
//  ClickySettingsCatalog.swift
//  ClickyCore
//
//  Every v2 key (and the pre-v2 keys v2 reuses), with the control the
//  Diagnostics window edits it with and its default. The defaults here
//  mirror the accessors in ClickySettings.swift; a test checks both that
//  every `v2.` key in that file is listed here and that the defaults fit.
//

import Foundation

public struct ClickySettingsEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case toggle(defaultValue: Bool)
        case choice(options: [String], defaultValue: String)
        case integer(defaultValue: Int, range: ClosedRange<Int>, step: Int)
        case number(defaultValue: Double, range: ClosedRange<Double>, step: Double)
        case text(defaultValue: String)
        case textList(defaultValue: [String])
        /// JSON the app writes for itself (e.g. the tier-probe records). Shown read-only.
        case internalData
    }

    public let key: String
    public let kind: Kind
    /// One short line for the settings row.
    public let explanation: String

    /// The settings section the row sits in: the word after `v2.`, or "pre-v2" for reused keys.
    public var sectionName: String {
        let components = key.split(separator: ".")
        return components.first == "v2" && components.count > 1 ? String(components[1]) : "pre-v2"
    }
}

public enum ClickySettingsCatalog {
    public static let entries: [ClickySettingsEntry] = [
        // Pre-v2 keys, reused.
        ClickySettingsEntry(key: ClickySettings.LegacyKeys.usesQwenLocalVoice, kind: .toggle(defaultValue: true),
                            explanation: "Speak with the local Qwen voice (falls back to the Mac voice when off or unavailable)."),
        ClickySettingsEntry(key: ClickySettings.LegacyKeys.selectedSpeechVoiceIdentifier, kind: .text(defaultValue: ""),
                            explanation: "Mac voice identifier used by the fallback voice. Empty means the automatic choice."),

        // Grounding (element ids on screenshots).
        ClickySettingsEntry(key: ClickySettings.Keys.groundingEnabled, kind: .toggle(defaultValue: true),
                            explanation: "Read the accessibility tree and badge elements on screenshots."),
        ClickySettingsEntry(key: ClickySettings.Keys.groundingImageTier, kind: .choice(options: ["auto", "high", "standard"], defaultValue: "auto"),
                            explanation: "Image size sent for the cursor screen. Auto uses the tier probe result."),
        ClickySettingsEntry(key: ClickySettings.Keys.groundingProbe, kind: .internalData,
                            explanation: "Tier-probe results per model. Written by the probe, not edited here."),
        ClickySettingsEntry(key: ClickySettings.Keys.groundingBadges, kind: .toggle(defaultValue: true),
                            explanation: "Draw id badges on the screenshots (A/B switch)."),
        ClickySettingsEntry(key: ClickySettings.Keys.groundingValueBlockedBundleIDs, kind: .textList(defaultValue: ClickySettings.defaultValueBlockedBundleIDs),
                            explanation: "Bundle ids whose field values are never read. Comma separated."),
        ClickySettingsEntry(key: ClickySettings.Keys.groundingEnhancedUIBundleIDs, kind: .textList(defaultValue: EnhancedUserInterfacePolicy.defaultBundleIdentifiers),
                            explanation: "Apps that get AXEnhancedUserInterface while in front (\"electron\" = any Electron app). Comma separated."),
        ClickySettingsEntry(key: ClickySettings.Keys.groundingVerifyWithHaiku, kind: .toggle(defaultValue: false),
                            explanation: "Ask Haiku to check tentative marks on a zoomed crop."),

        // Marks.
        ClickySettingsEntry(key: ClickySettings.Keys.marksMax, kind: .integer(defaultValue: 9, range: 1...30, step: 1),
                            explanation: "Most marks on screen at once; the oldest goes first."),
        ClickySettingsEntry(key: ClickySettings.Keys.marksTrackAX, kind: .toggle(defaultValue: true),
                            explanation: "Follow marks on accessibility elements as they scroll or move."),
        ClickySettingsEntry(key: ClickySettings.Keys.marksLabelStyle, kind: .choice(options: ["nearCursor", "column"], defaultValue: "nearCursor"),
                            explanation: "nearCursor: numbered chips on the marks, their words in the caption bubble. column: labels in a column with leaders."),

        // Voice.
        ClickySettingsEntry(key: ClickySettings.Keys.voiceEchoMode, kind: .choice(options: ["open", "halfDuplex", "aec"], defaultValue: "open"),
                            explanation: "open keeps the mic live while Clicky talks; halfDuplex mutes it; aec cancels Clicky's own voice."),
        ClickySettingsEntry(key: ClickySettings.Keys.qwenSpeaker, kind: .choice(options: QwenTuning.speakers, defaultValue: QwenTuning.defaultSpeaker),
                            explanation: "Qwen CustomVoice speaker. The Base model ignores it."),
        ClickySettingsEntry(key: ClickySettings.Keys.qwenInstruct, kind: .text(defaultValue: ""),
                            explanation: "Qwen style instruction. Empty means the speaker's own delivery."),
        ClickySettingsEntry(key: ClickySettings.Keys.qwenReferenceClip, kind: .text(defaultValue: ""),
                            explanation: "WAV the Qwen voice is cloned from. Empty means \(QwenTuning.referenceClipDefaultPath)."),
        ClickySettingsEntry(key: ClickySettings.Keys.voiceRate, kind: .number(defaultValue: 1.0, range: 0.85...1.3, step: 0.15),
                            explanation: "Playback rate for both voices (0.85, 1.0, 1.15 or 1.3)."),
        ClickySettingsEntry(key: ClickySettings.Keys.ttsPortOverride, kind: .integer(defaultValue: 0, range: 0...65535, step: 1),
                            explanation: "Debug: Qwen port instead of 11234. 0 means off; a closed port tests the Apple fallback."),

        ClickySettingsEntry(key: ClickySettings.Keys.keepWarmAgent, kind: .toggle(defaultValue: false),
                            explanation: "Keep the Qwen server running from a LaunchAgent. Install also needs the approval below."),
        ClickySettingsEntry(key: ClickySettings.Keys.keepWarmAgentApproved, kind: .toggle(defaultValue: false),
                            explanation: "Set after you approve installing the keep-warm LaunchAgent."),

        // Captions.
        ClickySettingsEntry(key: ClickySettings.Keys.captionMaxLines, kind: .integer(defaultValue: 4, range: 1...10, step: 1),
                            explanation: "Caption bubble lines."),
        ClickySettingsEntry(key: ClickySettings.Keys.captionMaxWidth, kind: .number(defaultValue: 360, range: 280...480, step: 10),
                            explanation: "Caption bubble width in points."),
        ClickySettingsEntry(key: ClickySettings.Keys.captionAVOffsetMs, kind: .number(defaultValue: 0, range: -1000...1000, step: 10),
                            explanation: "Milliseconds added to the Qwen audio clock for captions."),

        // Whiteboard.
        ClickySettingsEntry(key: ClickySettings.Keys.whiteboardAuto, kind: .toggle(defaultValue: false),
                            explanation: "Gate for the whiteboard prompt section (off by default)."),
        ClickySettingsEntry(key: ClickySettings.Keys.whiteboardTheme, kind: .choice(options: ["paper", "chalk", "dark"], defaultValue: "paper"),
                            explanation: "The board's look."),
        ClickySettingsEntry(key: ClickySettings.Keys.whiteboardFullScreen, kind: .toggle(defaultValue: false),
                            explanation: "The board panel fills the screen's visible frame."),

        // Code mode.
        ClickySettingsEntry(key: ClickySettings.Keys.codeEnabled, kind: .toggle(defaultValue: false),
                            explanation: "Turn on Code mode."),
        ClickySettingsEntry(key: ClickySettings.Keys.codeBashAllowed, kind: .toggle(defaultValue: false),
                            explanation: "Let the code agent use Bash. Only a passing sandbox probe should turn this on."),
        ClickySettingsEntry(key: ClickySettings.Keys.codeRepoRoots, kind: .textList(defaultValue: ClickySettings.defaultCodeRepoRoots),
                            explanation: "Folders scanned for local clones. Comma separated."),

        // Other.
        ClickySettingsEntry(key: ClickySettings.Keys.typeForMeEnabled, kind: .toggle(defaultValue: false),
                            explanation: "Turn on the type-for-me feature."),
        ClickySettingsEntry(key: ClickySettings.Keys.typeForMeBlockedBundleIDs, kind: .textList(defaultValue: Array(ClickySettings.defaultTypeForMeBlockedBundleIDs)),
                            explanation: "Apps Clicky never types into (Copy only). Comma separated bundle ids."),
        ClickySettingsEntry(key: ClickySettings.Keys.claudeEffortOverride, kind: .choice(options: ["", "low", "medium", "high"], defaultValue: ""),
                            explanation: "Forces --effort for every answer (evals). Empty means no override."),
    ]
}
