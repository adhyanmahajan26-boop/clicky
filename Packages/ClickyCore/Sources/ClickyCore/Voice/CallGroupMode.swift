//
//  CallGroupMode.swift
//  ClickyCore
//
//  Group mode on a voice call: Vello in an X Space, a group call or a room with the owner and other people.
//
//  A call is built for two: only the voice near the Mac counts, every word heard is the owner's, new words throw away an
//  answer not yet heard, and every turn gets an answer. In an X Space all four go wrong (Air, 24 Nov): the other speakers
//  come out of the phone's speaker about 10 to 20 dB quieter than the owner, so they were turned away as "a voice too far
//  from the Mac"; what did get through was labelled as the owner's; the talk never stopped, so answers were started over
//  and over ("the owner spoke during the answer" again and again) and came late or never; and since a turn with nothing to
//  say is now said out loud as a failure, Vello filled every turn with "I'm staying quiet, call me if you need me" until
//  people told it to shut up.
//
//  In group mode every voice counts, each line is marked as the owner's (the voice right at the Mac) or someone else's,
//  other people's words never throw an answer away (they wait and go with the next turn), a turn is let go at a shorter
//  pause, and Vello answers only when spoken to or when it has something worth adding. Otherwise it writes [PASS] and
//  stays quiet without saying so.
//

import Foundation

/// What was said about group mode, if anything.
public enum CallGroupModeCommand: Equatable, Sendable {
    case start
    case stop
}

public enum CallGroupMode {
    /// What the brain writes when it has nothing to add: never read aloud, and not a failure.
    public static let passMarker = "[PASS]"

    /// The longest utterance that can switch group mode on or off by its words alone. Longer talk that mentions a Space
    /// is left to the brain, which puts [GROUP: on] when it means one.
    static let longestCommandWords = 14

    static let startPhrases = [
        "group mode", "space mode", "spaces mode", "x space", "x spaces", "twitter space", "twitter spaces",
        "x ki space", "x pe space", "x par space", "x की space", "एक्स की स्पेस", "ट्विटर स्पेस",
        "talk to everyone", "talk to all of them", "talk to them all", "talk with everyone", "sab se baat karo",
        "sabse baat karo", "sab se baat kar", "sabse baat kar", "सबसे बात करो", "सब से बात करो",
    ]

    static let stopPhrases = [
        "group mode off", "stop group mode", "end group mode", "exit group mode", "leave group mode", "turn off group mode",
        "space mode off", "stop space mode", "end space mode", "exit space mode", "space is over", "space is done",
        "space ended", "left the space", "just us now", "just me now", "only me now", "just the two of us",
        "talk normally", "talk normal", "back to normal", "normal mode",
    ]

    public static func command(in utterance: String) -> CallGroupModeCommand? {
        let words = CallTurnEnd.simplifiedWords(utterance)
        guard !words.isEmpty, words.count <= longestCommandWords else { return nil }
        let joined = " " + words.joined(separator: " ") + " "
        // "group mode off" holds "group mode", so stopping is checked first.
        if stopPhrases.contains(where: { joined.contains(" \($0) ") }) { return .stop }
        if startPhrases.contains(where: { joined.contains(" \($0) ") }) { return .start }
        return nil
    }

    // MARK: Turns

    /// The wait for a pause in a group: people take the floor after about a second, so Vello waits no longer than this,
    /// and less when it was called by name.
    public static let longestWaitSeconds = 1.0
    public static let addressedWaitSeconds = 0.7
    /// Talk that runs on with only short gaps is let go at the first gap once it has been held this long, so Vello keeps
    /// up with the conversation instead of waiting for a silence a lively Space never has.
    public static let longestHeldSeconds = 12.0
    /// The gap that's enough once the talk has been held that long.
    public static let shortGapSeconds = 0.3

    /// Seconds of quiet before a group turn is let go. `ownWait`: what `CallTurnEnd.waitSeconds` says for the words.
    public static func waitSeconds(ownWait: Double, isAddressed: Bool) -> Double {
        min(ownWait, isAddressed ? addressedWaitSeconds : longestWaitSeconds)
    }

    /// Whether a held group turn is let go now. `someoneIsTalking`: a voice is going right now. `secondsSinceVoiceStopped`:
    /// since the last voice ended. `secondsHeld`: since the first words of this turn were held.
    public static func releasesTurn(someoneIsTalking: Bool, secondsSinceVoiceStopped: Double, secondsSincePartialWords: Double?,
                                    waitSeconds: Double, secondsHeld: Double) -> Bool {
        // Never over someone: an answer that starts while a person talks sounds like Vello cutting them off.
        guard !someoneIsTalking else { return false }
        if secondsHeld >= longestHeldSeconds && secondsSinceVoiceStopped >= shortGapSeconds { return true }
        return CallQuietLimit.releasesTurn(secondsSinceVoiceStopped: secondsSinceVoiceStopped,
                                           secondsSincePartialWords: secondsSincePartialWords, waitSeconds: waitSeconds)
    }

    /// Words a partial needs, beyond what's already taken, to stop Vello's voice in a group. A laugh, a "haan" or someone
    /// agreeing over it shouldn't cut it off mid-sentence; someone really talking over it should.
    public static let partialWordsToCutIn = 3

    // MARK: What the brain is given

    /// One stretch of what was heard, and whether it was the owner's voice right at the Mac.
    public struct HeardLine: Equatable, Sendable {
        public var isOwner: Bool
        public var text: String

        public init(isOwner: Bool, text: String) {
            self.isOwner = isOwner
            self.text = text
        }
    }

    /// `lines` with `text` added: joined to the last line when the same voice is still talking.
    public static func adding(_ text: String, isOwner: Bool, to lines: [HeardLine]) -> [HeardLine] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lines }
        var lines = lines
        if let last = lines.last, last.isOwner == isOwner {
            lines[lines.count - 1].text = last.text + " " + trimmed
        } else {
            lines.append(HeardLine(isOwner: isOwner, text: trimmed))
        }
        return lines
    }

    /// No usable name: the unset placeholder or a blank one, so a line never starts with a bare ": ".
    private static func hasNoName(_ owner: String) -> Bool {
        OwnerName.isUnset(owner) || owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The lines as they're shown and saved: "Addy: …" and "Someone: …", one per line.
    public static func labelled(_ lines: [HeardLine], owner: String) -> String {
        let ownerWord = hasNoName(owner) ? "Owner" : owner
        return lines.map { ($0.isOwner ? ownerWord : "Someone") + ": " + $0.text }.joined(separator: "\n")
    }

    /// The turn for the brain in group mode: what was heard since it last spoke, by speaker as far as can be told, and how
    /// to take part. `isAddressed`: its name or a "what do you think" was in it.
    public static func message(lines: [HeardLine], owner: String, botName: String, isAddressed: Bool) -> String {
        let ownerWord = hasNoName(owner) ? "the owner" : owner
        let labelOwner = hasNoName(owner) ? "Owner" : owner
        var message = "(Group call: you're in an X Space or a room with \(ownerWord) and other people, and they can all hear you. "
        message += "Here is what was said since you last spoke. Who said it is a guess from how loud it was: \"\(labelOwner)\" is the voice right at the Mac, \"Someone\" is anyone else, and words can be misheard.)\n"
        message += labelled(lines, owner: owner)
        message += "\n(Take part like one more person in the conversation. Answer when someone talks to you, even with your name a bit off ("
        message += misheardNames(for: botName).joined(separator: ", ")
        message += "), asks you something, or when you have something genuinely worth adding. Otherwise write only \(passMarker) and nothing else: "
        message += "never say you're staying quiet or listening. Keep it to one or two short sentences, the way people talk in a Space, answer the person who spoke to you, and use the language they're using."
        message += isAddressed ? " You were just spoken to, so answer.)" : ")"
        return message
    }

    /// How the ears tend to write the bot's name, for the brain to recognise it.
    static func misheardNames(for botName: String) -> [String] {
        let name = botName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.lowercased() == "vello" { return ["Velo", "Bello", "Fellow", "Hello Vello"] }
        return [name]
    }

    /// Whether a reply is the brain choosing to stay quiet: [PASS], on its own or at the end of a word or two.
    public static func saysPass(_ reply: String) -> Bool {
        reply.range(of: #"\[\s*PASS\s*\]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What's said when group mode is switched on or off by the owner's words.
    public static func acknowledgement(turnOn: Bool, speaksHindi: Bool, readsDevanagari: Bool) -> String {
        if speaksHindi {
            if readsDevanagari { return turnOn ? "ठीक है, मैं सबके साथ हूँ। जब बात बने, बोलूँगा।" : "ठीक है, अब सिर्फ़ हम दोनों।" }
            return turnOn ? "Theek hai, main sabke saath hoon. Jab baat bane, bolunga." : "Theek hai, ab sirf hum dono."
        }
        return turnOn ? "Okay, I'm in. I'll jump in when it fits." : "Okay, just us again."
    }
}
