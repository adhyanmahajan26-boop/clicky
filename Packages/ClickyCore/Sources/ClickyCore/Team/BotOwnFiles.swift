//
//  BotOwnFiles.swift
//  ClickyCore
//
//  A bot's own files, easy for the owner to edit in any editor: `instructions.md` and `nature.md` in its memory folder.
//  When `instructions.md` is there its text is the bot's instructions (it wins over the settings field, and editing the
//  field writes the file). When `nature.md` is there it goes into the bot's prompt as "Your nature", right after the
//  instructions, on chats and on calls. Each is capped like the memory file (`BotMemoryPrompt`); a file that's cut gets a
//  first-line comment saying so.
//

import Foundation

public enum BotOwnFiles {
    public static let instructionsFileName = "instructions.md"
    public static let natureFileName = "nature.md"
    /// Characters of each file that go into a prompt.
    public static let limit = BotMemoryPrompt.limit

    /// The first-line comment a cut file gets.
    public static func cutNotice(limit: Int = BotOwnFiles.limit) -> String {
        "<!-- Vello reads only the first \(limit) characters of this file; the rest is cut. -->"
    }

    /// The file's text without a first-line comment (Vello's cut notice, or the owner's own note): that line is for
    /// whoever edits the file, not for the bot.
    public static func body(of fileText: String) -> String {
        var text = fileText
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let firstLineEnd = text.firstIndex(of: "\n") ?? text.endIndex
        let firstLine = text[..<firstLineEnd].trimmingCharacters(in: .whitespaces)
        if firstLine.hasPrefix("<!--"), firstLine.hasSuffix("-->") {
            text = firstLineEnd < text.endIndex ? String(text[text.index(after: firstLineEnd)...]) : ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The body capped at `limit` characters, cut at the last line break before it when there is one.
    public static func capped(_ body: String, limit: Int = BotOwnFiles.limit) -> (text: String, wasCut: Bool) {
        guard body.count > limit else { return (body, false) }
        var kept = String(body.prefix(limit))
        if let lastBreak = kept.lastIndex(of: "\n"), kept.distance(from: kept.startIndex, to: lastBreak) > limit / 2 {
            kept = String(kept[..<lastBreak])
        }
        return (kept.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    /// The file's new text when it's over the limit and doesn't say so yet (the cut notice as its first line); nil when it
    /// needs no change.
    public static func addingCutNoticeIfNeeded(_ fileText: String, limit: Int = BotOwnFiles.limit) -> String? {
        guard capped(body(of: fileText), limit: limit).wasCut, !fileText.hasPrefix(cutNotice(limit: limit)) else { return nil }
        return cutNotice(limit: limit) + "\n" + fileText
    }

    /// The bot's instructions: the instructions file's text when there is one, else the settings field.
    public static func instructions(field: String, instructionsFile: String?) -> String {
        guard let instructionsFile else { return field }
        return capped(body(of: instructionsFile)).text
    }

    /// "Your nature" for the prompt, or nil without a nature file (or an empty one).
    public static func natureSection(natureFile: String?) -> String? {
        guard let natureFile else { return nil }
        let nature = capped(body(of: natureFile)).text
        guard !nature.isEmpty else { return nil }
        return "Your nature:\n\(nature)"
    }

    /// What starts a bot's prompt: its instructions, then its nature right after.
    public static func personaHead(field: String, instructionsFile: String?, natureFile: String?) -> String {
        let ownInstructions = instructions(field: field, instructionsFile: instructionsFile)
        guard let nature = natureSection(natureFile: natureFile) else { return ownInstructions }
        return ownInstructions.isEmpty ? nature : ownInstructions + "\n\n" + nature
    }

    /// What a new instructions file starts with: the field as it is.
    public static func newInstructionsFile(field: String) -> String {
        field.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// What a new nature file starts with: a comment saying what it's for.
    public static func newNatureFile(botName: String) -> String {
        "<!-- \(botName)'s nature: how it talks and behaves, its personality. Vello puts this right after its instructions. -->\n"
    }
}

/// A bot's own call voice, saved with the bot as "sarvam:<speaker>" or "apple:<voice id>". Unset, or saved for the other
/// engine, means the call voice everyone gets today.
public enum CallVoiceChoice {
    public enum Engine: String, Sendable { case sarvam, apple }

    public static func saved(engine: Engine, voiceID: String) -> String { "\(engine.rawValue):\(voiceID)" }

    /// The voice to use with `engine`, or nil for the usual one.
    public static func voiceID(saved: String?, engine: Engine) -> String? {
        guard let saved, let colon = saved.firstIndex(of: ":"), String(saved[..<colon]) == engine.rawValue else { return nil }
        let voiceID = String(saved[saved.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return voiceID.isEmpty ? nil : voiceID
    }
}
