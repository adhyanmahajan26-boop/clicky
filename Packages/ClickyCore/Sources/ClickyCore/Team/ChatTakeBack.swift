//
//  ChatTakeBack.swift
//  ClickyCore
//
//  "/retry" and "/undo" in a bot's own chat (Hermes's /retry and /undo): the owner's newest message and what came after it.
//

import Foundation

public enum ChatTakeBack {
    public enum Command: String, Sendable {
        /// The newest message is asked again, and what answered it leaves the chat.
        case retry
        /// The newest message and what answered it both leave the chat.
        case undo
    }

    /// "/retry" or "/undo", the whole message and nothing else, any case.
    public static func command(in text: String) -> Command? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "/retry": return .retry
        case "/undo": return .undo
        default: return nil
        }
    }

    /// The owner's newest message in a chat and the ids of everything after it (the bot's answer, notes, cards).
    public struct Exchange: Equatable, Sendable {
        public var ownerMessageID: String
        public var ownerText: String
        public var laterIDs: [String]
        /// The message just before the owner's, which a session that heard any of the exchange has now heard last.
        public var previousID: String?
    }

    public static func lastExchange<Message>(in messages: [Message], id: (Message) -> String, isOwner: (Message) -> Bool,
                                             text: (Message) -> String) -> Exchange? {
        guard let index = messages.lastIndex(where: isOwner) else { return nil }
        return Exchange(ownerMessageID: id(messages[index]), ownerText: text(messages[index]),
                        laterIDs: messages[(index + 1)...].map(id), previousID: index > 0 ? id(messages[index - 1]) : nil)
    }

    /// The ids that leave the chat for this command.
    public static func removedIDs(_ exchange: Exchange, command: Command) -> [String] {
        command == .undo ? [exchange.ownerMessageID] + exchange.laterIDs : exchange.laterIDs
    }

    /// Where a session's "heard up to here" mark goes once those ids are gone: unchanged unless it pointed at the owner's message or
    /// after it, and then the message before the owner's (on /retry the owner's message is that turn's own words, not news).
    public static func heardAfterRemoving(heard: String?, exchange: Exchange) -> String? {
        guard let heard, heard == exchange.ownerMessageID || exchange.laterIDs.contains(heard) else { return heard }
        return exchange.previousID
    }

    /// A conversation kept for an API key (user and assistant turns) without its newest exchange: the last "user" turn and
    /// anything after it. Nothing older is touched.
    public static func droppingLastExchange<Message>(_ messages: [Message], role: (Message) -> String) -> [Message] {
        guard let index = messages.lastIndex(where: { role($0) == "user" }) else { return messages }
        return Array(messages[..<index])
    }

    /// Messages without the ones taken back, on this Mac or the other one.
    public static func keeping<Message>(_ messages: [Message], id: (Message) -> String, takenBack: Set<String>) -> [Message] {
        takenBack.isEmpty ? messages : messages.filter { !takenBack.contains(id($0)) }
    }

    /// At most this many ids are remembered per chat: plenty for undoing a few turns, small enough to send with the chat.
    public static let rememberedIDs = 400

    public static func remembering(_ existing: [String], adding ids: [String]) -> [String] {
        var all = existing
        for id in ids where !all.contains(id) { all.append(id) }
        return Array(all.suffix(rememberedIDs))
    }

    /// Goes on top of the bot's next turn when its engine keeps its own session (Claude Code, Codex and the rest), which Vello can't
    /// edit. A bot on an API key has the exchange taken out of its conversation instead.
    public static func engineNote(_ command: Command, ownerText: String, owner: String) -> String {
        let quoted = String(ownerText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        switch command {
        case .retry:
            return "\(OwnerName.startingSentence(owner)) asked for another try at their last message (\"\(quoted)\") with /retry. Your earlier answer to it was taken out of the chat and they didn't want it: answer afresh, not the same way."
        case .undo:
            return "\(OwnerName.startingSentence(owner)) took back their last message (\"\(quoted)\") and your answer to it with /undo. Both are gone from the chat: act as if neither was said, and don't bring them up."
        }
    }

    /// The note left in the chat after /undo. Files a bot already changed stay as they are, and it says so.
    public static let undoneNote = "Took back your last message and the reply to it. Anything the bot already did, such as files it changed or messages it sent, stays as it is."
    public static let notAnsweredYet = "It hasn't answered your last message yet. It goes to the bot as soon as the answer in progress ends."
    public static let nothingToRetry = "There's no message of yours here to try again."
    public static let nothingToUndo = "There's no message of yours here to take back."
    public static let onlyInOwnChat = "/retry and /undo work in a bot's own chat."
}

/// "/help" (or "/commands") in any bot's chat: the commands a chat takes, answered with a note and no bot turn.
public enum ChatCommandsHelp {
    public static func asksForHelp(_ text: String) -> Bool {
        ["/help", "/commands", "/?"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static let markdown = """
    **Commands for this chat**

    - `/retry`: ask your last message again. The reply to it is taken out.
    - `/undo`: take back your last message and the reply to it.
    - `/new`: start a fresh session. Memory, skills and this chat are kept.
    - `/doctor`: check everything Vello needs on this computer, with a fix for each problem.
    - `/help`: this list.

    You can also just say what you want changed, like "switch to haiku" or "what model are you on".
    """
}

/// Messages the owner sends while a bot is still answering: they show at once and go to it together in its next turn, instead of
/// one turn each (OpenClaw's "collect" queue mode). One message goes as it is.
public enum BusyMessages {
    public static func combined(_ texts: [String], owner: String) -> String {
        let said = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard said.count > 1 else { return said.first ?? texts.first ?? "" }
        return "(\(OwnerName.startingSentence(owner)) sent these \(said.count) messages while you were answering. Answer them together, in one reply.)\n\n" +
            said.joined(separator: "\n\n")
    }
}
