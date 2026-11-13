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

    /// How many times a cut-off message is asked again by itself. A message whose answer keeps getting cut off (Theo
    /// crashing on it, say) isn't retried forever: after this many the owner is told to send it again.
    static let resumeRetries = 2

    /// Theo's own lines about a cut-off turn start with this; "…so it's asking again now." marks a retry.
    nonisolated static let resumePrefix = "Theo stopped before "
    nonisolated static let resumeRetrySuffix = "so it's asking again now."

    /// The owner's messages at the end of a chat with nothing after them: what was cut off.
    /// `heard`: the last message each bot's finished turn took in (`BotConversationRecord.heard`). A turn that finished
    /// without posting anything (its reply was only [TELL:] lines or an order) did answer: what it heard isn't asked again,
    /// or a restart would carry out the same orders twice.
    nonisolated static func unanswered(_ messages: [BotChatMessage], heard: [String: String]? = nil) -> [BotChatMessage] {
        interrupted(messages, heard: heard).waiting
    }

    /// What was cut off, and how many times it has already been asked again. Theo's own "asking again" line isn't an
    /// answer: a retry that was itself cut off (a second crash) is still unanswered, and is never left sitting under
    /// "asking again now" with nothing coming. A line telling the owner to send it again ends it.
    nonisolated static func interrupted(_ messages: [BotChatMessage], heard: [String: String]? = nil) -> (waiting: [BotChatMessage], retries: Int) {
        let heardIDs = Set((heard ?? [:]).values)
        var trailing: [BotChatMessage] = []
        var retries = 0
        for message in messages.reversed() {
            if message.author == noteAuthor, message.text.hasPrefix(resumePrefix) {
                guard message.text.hasSuffix(resumeRetrySuffix) else { break }
                if trailing.isEmpty { retries += 1 }
                continue
            }
            guard message.author == "user", !heardIDs.contains(message.id) else { break }
            trailing.insert(message, at: 0)
        }
        return (trailing, retries)
    }

    func resumeInterruptedTurns(now: Date = Date()) {
        for bot in bots where bot.owner == nil && bot.isOn && replying[bot.id] == nil {
            let record = conversation(bot.id)
            let (waiting, retries) = Self.interrupted(record.messages, heard: record.heard)
            guard !waiting.isEmpty else { continue }
            let recent = waiting.filter { now.timeIntervalSince($0.at) < Self.resumeWindow }
            if recent.isEmpty || retries >= Self.resumeRetries {
                let why = recent.isEmpty ? "" : " (it was cut off \(retries + 1) times, so it isn't asking again by itself)"
                post(BotChatMessage(author: Self.noteAuthor, text: "\(Self.resumePrefix)\(bot.name) answered this\(why). Send it again if you still need it."), to: bot.id)
                continue
            }
            let what = recent.count == 1 ? "your last message" : "your last \(recent.count) messages"
            post(BotChatMessage(author: Self.noteAuthor, text: "\(Self.resumePrefix)\(bot.name) answered \(what), \(Self.resumeRetrySuffix)"), to: bot.id)
            for message in recent { send(message.text, to: bot.id, messageID: message.id, writtenAt: message.at) }
        }
        for group in groups where group.headID != nil {
            let room = group.roomID
            let record = conversation(room)
            let (waiting, retries) = Self.interrupted(record.messages, heard: record.heard)
            guard !isBusy(room), let last = waiting.last else { continue }
            guard now.timeIntervalSince(last.at) < Self.resumeWindow, retries < Self.resumeRetries else {
                post(BotChatMessage(author: Self.noteAuthor, text: "\(Self.resumePrefix)\(group.name) answered this. Send it again if you still need it."), to: room)
                continue
            }
            post(BotChatMessage(author: Self.noteAuthor, text: "\(Self.resumePrefix)\(group.name) answered your last message, \(Self.resumeRetrySuffix)"), to: room)
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
