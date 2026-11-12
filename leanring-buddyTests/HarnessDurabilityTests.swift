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
}
