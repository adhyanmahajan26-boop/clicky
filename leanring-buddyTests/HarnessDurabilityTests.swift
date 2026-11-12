//
//  HarnessDurabilityTests.swift
//  leanring-buddyTests
//
//  The harness's restart and saved-file rules, proved on their own: what counts as cut off after a crash, and a
//  damaged save file never costing the owner what it held.
//

import Foundation
import Testing
@testable import Clicky

/// Serialized: the saved-file problems list is shared, and each test reads its own.
@Suite(.serialized)
@MainActor
struct HarnessDurabilityTests {
    private func owner(_ id: String) -> BotChatMessage { BotChatMessage(id: id, author: "user", text: id) }
    private func bot(_ id: String) -> BotChatMessage { BotChatMessage(id: id, author: "bot-1", text: id) }

    @Test func trailingOwnerMessagesAreCutOff() {
        let messages = [owner("a"), bot("b"), owner("c"), owner("d")]
        #expect(BotsStore.unanswered(messages).map(\.id) == ["c", "d"])
        #expect(BotsStore.unanswered([owner("a"), bot("b")]).isEmpty)
    }

    @Test func aTurnThatFinishedWithoutPostingIsNotAskedAgain() {
        // The bot's reply was only a [TELL:] line: nothing was posted, but its turn finished and heard "c".
        let messages = [owner("a"), bot("b"), owner("c")]
        #expect(BotsStore.unanswered(messages, heard: ["bot-1": "c"]).isEmpty)
        // A message that came in after the finished turn is still cut off.
        #expect(BotsStore.unanswered(messages + [owner("d")], heard: ["bot-1": "c"]).map(\.id) == ["d"])
        // What another bot heard earlier in the chat changes nothing.
        #expect(BotsStore.unanswered(messages, heard: ["bot-2": "a"]).map(\.id) == ["c"])
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saved-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aDamagedFileFallsBackToTheLastGoodCopyAndIsKeptAside() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bots.json")
        try Data(#"["Atlas","Ledger","Scout"]"#.utf8).write(to: file)
        #expect(BotsSavedFile.load([String].self, from: file, decoder: JSONDecoder(), what: "test") == ["Atlas", "Ledger", "Scout"])
        #expect(FileManager.default.fileExists(atPath: BotsSavedFile.lastGood(file).path))

        try Data(#"["Atlas","Led"#.utf8).write(to: file)
        _ = BotsSavedFile.takeProblems()
        // Every bot comes back, not just "something was kept".
        #expect(BotsSavedFile.load([String].self, from: file, decoder: JSONDecoder(), what: "test") == ["Atlas", "Ledger", "Scout"])
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("bots.json.unreadable-") }
        #expect(aside.count == 1)
        #expect(try String(contentsOf: dir.appendingPathComponent(aside[0]), encoding: .utf8) == #"["Atlas","Led"#)
        // The live file is whole again, and the owner is told once.
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: file)) == ["Atlas", "Ledger", "Scout"])
        #expect(BotsSavedFile.takeProblems().count == 1)
        #expect(BotsSavedFile.takeProblems().isEmpty)
    }

    @Test func aDamagedFileWithNoGoodCopyIsNeverDeleted() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("routines.json")
        try Data("{not json".utf8).write(to: file)
        _ = BotsSavedFile.takeProblems()
        #expect(BotsSavedFile.load([String].self, from: file, decoder: JSONDecoder(), what: "test") == nil)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("routines.json.unreadable-") }
        #expect(aside.count == 1)
        #expect(BotsSavedFile.takeProblems().count == 1)
    }

    // MARK: Faults and durability, round two

    private func note(_ text: String) -> BotChatMessage { BotChatMessage(author: BotsStore.noteAuthor, text: text) }
    private var retryNote: BotChatMessage { note("Theo stopped before Ledger answered your last message, so it's asking again now.") }

    @Test func aRetryCutOffByASecondCrashIsStillUnanswered() {
        // The first restart asked again, then Theo stopped again before any answer: still waiting, one retry used.
        let afterOne = BotsStore.interrupted([owner("a"), bot("b"), owner("c"), retryNote])
        #expect(afterOne.waiting.map(\.id) == ["c"])
        #expect(afterOne.retries == 1)
        let afterTwo = BotsStore.interrupted([owner("c"), retryNote, retryNote])
        #expect(afterTwo.retries == 2)
        // Answered after the retry: nothing waits.
        #expect(BotsStore.unanswered([owner("c"), retryNote, bot("d")]).isEmpty)
        // Told to send it again: nothing more happens by itself.
        #expect(BotsStore.unanswered([owner("c"), retryNote, note("Theo stopped before Ledger answered this. Send it again if you still need it.")]).isEmpty)
        // Any other note after the owner's message (a folder made, a routine set up) is an answer, as before.
        #expect(BotsStore.unanswered([owner("c"), note("Made the folder.")]).isEmpty)
    }

    private struct Item: Codable, Equatable { var id: String; var tags: [String] }

    @Test func aFileCutShortKeepsEveryWholeRecordBeforeTheCut() throws {
        let items = (0..<6).map { Item(id: "bot-\($0)", tags: ["a", "b [x]", "{c}"]) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let full = try encoder.encode(items)
        let cut = full.prefix(Int(Double(full.count) * 0.8))
        let rescued = try #require(BotsSavedFile.readablePart(of: Data(cut), as: [Item].self, decoder: JSONDecoder()))
        #expect(rescued.value == Array(items.prefix(rescued.value.count)))
        #expect(rescued.value.count >= 4)
        #expect(BotsSavedFile.readablePart(of: Data("{not json".utf8), as: [Item].self, decoder: JSONDecoder()) == nil)
    }

    @Test func aDamagedFileWithNoGoodCopyKeepsWhatCanStillBeRead() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("chat.json")
        var record = BotConversationRecord()
        record.messages = (0..<40).map { BotChatMessage(id: "m\($0)", author: $0 % 2 == 0 ? "user" : "bot-1", text: "line \($0)") }
        record.sessions = ["bot-1": "s"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let full = try encoder.encode(record)
        try Data(full.prefix(Int(Double(full.count) * 0.9))).write(to: file)
        _ = BotsSavedFile.takeProblems()
        let loaded = try #require(BotsSavedFile.load(BotConversationRecord.self, from: file, decoder: JSONDecoder(), what: "test"))
        #expect(loaded.messages.count >= 30)
        #expect(loaded.messages.map(\.id) == record.messages.prefix(loaded.messages.count).map(\.id))
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("chat.json.unreadable-") }
        #expect(aside.count == 1)
        #expect(BotsSavedFile.takeProblems().count == 1)
    }

    // MARK: Recall and skills under the read rule

    @Test func aBotMaySearchItsOwnChatsAndNoOneElses() throws {
        let bot = BotImport.starters[0]
        let chats = BotMemory.root.deletingLastPathComponent().appendingPathComponent("chats").path
        let mine = chats + "/\(bot.id).json"
        let allowed = BotRunner.claudeAllowedTools(for: bot, recall: [mine])
        #expect(allowed.contains("Read(/\(mine))"))
        #expect(allowed.contains("Grep(/\(mine))"))
        #expect(!allowed.contains { $0.hasPrefix("Edit(/\(chats)") || $0.hasPrefix("Write(/\(chats)") })
        let denied = BotRunner.secretReadRules(recall: [mine])
        // Its own file is never denied (a deny wins over any allow), the folder as a whole isn't either, and the other records stay denied.
        #expect(!denied.contains("Read(/\(mine))"))
        #expect(!denied.contains("Read(/\(chats)/**)"))
        #expect(denied.contains { $0.hasSuffix("/*.json)") })
        // With nothing to recall, the whole chats folder is denied, as before.
        #expect(BotRunner.secretReadRules().contains("Read(/\(chats)/**)"))
    }

    @Test func otherBotsFoldersAreDeniedButTheSharedSkillsAreNot() {
        let denied = BotRunner.otherBotsFolders(than: "nobody-has-this-id")
        #expect(!denied.contains("Read(/\(BotSkills.sharedFolder.path)/**)"))
    }

    @Test func anotherBotsSkillIsCopiedWithoutTheRestOfItsFolder() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let skill = dir.appendingPathComponent("author/skills/release", isDirectory: true)
        try FileManager.default.createDirectory(at: skill.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("---\nname: release\ndescription: cut a release\n---\n1. dry run".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("checklist".utf8).write(to: skill.appendingPathComponent("notes/check.md"))
        let secret = dir.appendingPathComponent("author/memory.md")
        try Data("private".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: skill.appendingPathComponent("leak.md"), withDestinationURL: secret)
        let copies = dir.appendingPathComponent("copies", isDirectory: true)
        let copied = try #require(BotSkills.copy(skill, of: "author", into: copies))
        #expect(try String(contentsOf: copied.appendingPathComponent("SKILL.md"), encoding: .utf8).hasSuffix("1. dry run"))
        #expect(FileManager.default.fileExists(atPath: copied.appendingPathComponent("notes/check.md").path))
        // A link to the author's private memory is never followed into the copy.
        #expect(!FileManager.default.fileExists(atPath: copied.appendingPathComponent("leak.md").path))
        // An edit by the author reaches the copy; a file it deleted goes from the copy.
        try FileManager.default.removeItem(at: skill.appendingPathComponent("notes/check.md"))
        try Data("---\nname: release\ndescription: cut a release\n---\n1. dry run\n2. back up".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        _ = BotSkills.copy(skill, of: "author", into: copies)
        #expect(try String(contentsOf: copied.appendingPathComponent("SKILL.md"), encoding: .utf8).hasSuffix("2. back up"))
        #expect(!FileManager.default.fileExists(atPath: copied.appendingPathComponent("notes/check.md").path))
    }
}
