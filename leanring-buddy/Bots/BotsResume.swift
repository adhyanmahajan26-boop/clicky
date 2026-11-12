//
//  BotsResume.swift
//  leanring-buddy
//
//  After a quit or a crash: the owner's messages that never got an answer (the turn was cut off, or they were waiting
//  behind it) are asked again, once, with a line in the chat saying so. A harness doesn't drop work on the floor.
//

import Foundation

extension BotsStore {
    /// How old an unanswered message may be and still be asked again by itself. Older ones only get the note.
    static let resumeWindow: TimeInterval = 6 * 60 * 60

    /// The owner's messages at the end of a chat with nothing after them: what was cut off.
    nonisolated static func unanswered(_ messages: [BotChatMessage]) -> [BotChatMessage] {
        var trailing: [BotChatMessage] = []
        for message in messages.reversed() {
            guard message.author == "user" else { break }
            trailing.insert(message, at: 0)
        }
        return trailing
    }

    func resumeInterruptedTurns(now: Date = Date()) {
        for bot in bots where bot.owner == nil && bot.isOn && replying[bot.id] == nil {
            let waiting = Self.unanswered(conversation(bot.id).messages)
            guard !waiting.isEmpty else { continue }
            let recent = waiting.filter { now.timeIntervalSince($0.at) < Self.resumeWindow }
            if recent.isEmpty {
                post(BotChatMessage(author: Self.noteAuthor, text: "Theo stopped before \(bot.name) answered this. Send it again if you still need it."), to: bot.id)
                continue
            }
            let what = recent.count == 1 ? "your last message" : "your last \(recent.count) messages"
            post(BotChatMessage(author: Self.noteAuthor, text: "Theo stopped before \(bot.name) answered \(what), so it's asking again now."), to: bot.id)
            for message in recent { send(message.text, to: bot.id, messageID: message.id, writtenAt: message.at) }
        }
        for group in groups where group.headID != nil {
            let room = group.roomID
            guard !isBusy(room), let last = Self.unanswered(conversation(room).messages).last else { continue }
            guard now.timeIntervalSince(last.at) < Self.resumeWindow else {
                post(BotChatMessage(author: Self.noteAuthor, text: "Theo stopped before \(group.name) answered this. Send it again if you still need it."), to: room)
                continue
            }
            post(BotChatMessage(author: Self.noteAuthor, text: "Theo stopped before \(group.name) answered your last message, so it's asking again now."), to: room)
            sendToGroup(last.text, groupID: group.id, messageID: last.id, writtenAt: last.at)
        }
    }
}

extension BotsStore {
    /// The most a reply shows in the chat. A runaway engine can print megabytes; the chat keeps the start and the whole of it goes in a file.
    static let longestShownReply = 60_000

    static func keepingLongReplyAside(_ text: String, bot: NativeBot) -> String {
        guard text.count > longestShownReply else { return text }
        let folder = BotMemory.file(botID: bot.id).deletingLastPathComponent().appendingPathComponent("long-replies", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let file = folder.appendingPathComponent("reply-\(stamp).md")
        let saved = (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil
        let kept = String(text.prefix(longestShownReply))
        return kept + "\n\n_(This reply was \(text.count.formatted()) characters long, so the chat shows the start" +
            (saved ? ". The whole of it is in \(file.path).)_" : " only.)_")
    }
}
