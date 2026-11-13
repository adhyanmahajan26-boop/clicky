//
//  BotPersonaRefresh.swift
//  ClickyCore
//
//  Claude Code keeps a session's system prompt: `claude -p --resume <id> --append-system-prompt <new>` answers from the one
//  the session began with (checked 13 Nov 2026: a session started with "APPLE" and resumed with "BANANA" still said APPLE).
//  So when the owner edits a bot's instructions, or a Theo update changes what bots are told, a bot with a running session
//  never hears it. Theo remembers a fingerprint of what each session was told and, when it no longer matches, puts the
//  current instructions at the top of that one turn's message.
//

import Foundation

public enum BotPersonaRefresh {
    /// A stable fingerprint of the things that make up a bot's instructions (FNV-1a, 64 bit, as hex). Not a security hash:
    /// it only has to change when any of the parts does.
    public static func fingerprint(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// The session was told something else (or Theo has no record of it): it hears the current instructions now.
    public static func needsRefresh(storedFingerprint: String?, currentFingerprint: String) -> Bool {
        storedFingerprint != currentFingerprint
    }

    /// The turn's message with the current instructions on top, marked as replacing the ones the session began with.
    public static func refreshedPrompt(_ prompt: String, persona: String) -> String {
        "(Theo: your instructions have changed since this conversation began. From now on follow these; they replace the earlier ones.\n\n" +
            persona + "\n\nEnd of your instructions.)\n\n" + prompt
    }
}
