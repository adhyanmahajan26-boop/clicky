import XCTest
@testable import ClickyCore

final class ChatTakeBackTests: XCTestCase {
    private struct Line: Equatable { var id: String; var author: String; var text: String }

    private let chat = [
        Line(id: "1", author: "user", text: "hi"),
        Line(id: "2", author: "bot", text: "hello"),
        Line(id: "3", author: "user", text: "write a poem"),
        Line(id: "4", author: "bot", text: "roses"),
        Line(id: "5", author: "note", text: "a card"),
    ]

    func testCommandsAreTheWholeMessageOnly() {
        XCTAssertEqual(ChatTakeBack.command(in: " /Retry \n"), .retry)
        XCTAssertEqual(ChatTakeBack.command(in: "/undo"), .undo)
        XCTAssertNil(ChatTakeBack.command(in: "/undo that please"))
        XCTAssertNil(ChatTakeBack.command(in: "please retry"))
        XCTAssertTrue(ChatCommandsHelp.asksForHelp("/HELP"))
        XCTAssertFalse(ChatCommandsHelp.asksForHelp("help me"))
    }

    func testRetryTakesOutTheAnswerAndUndoTakesOutTheQuestionToo() throws {
        let exchange = try XCTUnwrap(ChatTakeBack.lastExchange(in: chat, id: \.id, isOwner: { $0.author == "user" }, text: \.text))
        XCTAssertEqual(exchange.ownerMessageID, "3")
        XCTAssertEqual(exchange.ownerText, "write a poem")
        XCTAssertEqual(exchange.previousID, "2")
        XCTAssertEqual(ChatTakeBack.removedIDs(exchange, command: .retry), ["4", "5"])
        XCTAssertEqual(ChatTakeBack.removedIDs(exchange, command: .undo), ["3", "4", "5"])
        let afterUndo = ChatTakeBack.keeping(chat, id: \.id, takenBack: Set(ChatTakeBack.removedIDs(exchange, command: .undo)))
        XCTAssertEqual(afterUndo.map(\.id), ["1", "2"])
        // A second /undo walks back one more.
        let second = try XCTUnwrap(ChatTakeBack.lastExchange(in: afterUndo, id: \.id, isOwner: { $0.author == "user" }, text: \.text))
        XCTAssertEqual(ChatTakeBack.removedIDs(second, command: .undo), ["1", "2"])
        XCTAssertNil(second.previousID)
        XCTAssertNil(ChatTakeBack.lastExchange(in: [Line(id: "9", author: "bot", text: "hey")], id: \.id, isOwner: { $0.author == "user" }, text: \.text))
    }

    func testHeardMarkMovesBackOnlyWhenItWasInTheExchange() throws {
        let exchange = try XCTUnwrap(ChatTakeBack.lastExchange(in: chat, id: \.id, isOwner: { $0.author == "user" }, text: \.text))
        XCTAssertEqual(ChatTakeBack.heardAfterRemoving(heard: "4", exchange: exchange), "2")
        XCTAssertEqual(ChatTakeBack.heardAfterRemoving(heard: "3", exchange: exchange), "2")
        XCTAssertEqual(ChatTakeBack.heardAfterRemoving(heard: "1", exchange: exchange), "1")
        XCTAssertNil(ChatTakeBack.heardAfterRemoving(heard: nil, exchange: exchange))
    }

    func testAnAPIConversationLosesOnlyItsNewestExchange() {
        let roles = ["user", "assistant", "user", "assistant"]
        XCTAssertEqual(ChatTakeBack.droppingLastExchange(roles, role: { $0 }), ["user", "assistant"])
        XCTAssertEqual(ChatTakeBack.droppingLastExchange(["user"], role: { $0 }), [])
        XCTAssertEqual(ChatTakeBack.droppingLastExchange(["assistant"], role: { $0 }), ["assistant"])
    }

    func testTakenBackIdsAreRememberedOnceAndCapped() {
        XCTAssertEqual(ChatTakeBack.remembering(["a"], adding: ["a", "b"]), ["a", "b"])
        let many = (0..<500).map(String.init)
        let kept = ChatTakeBack.remembering([], adding: many)
        XCTAssertEqual(kept.count, ChatTakeBack.rememberedIDs)
        XCTAssertEqual(kept.last, "499")
    }

    func testTheEngineIsToldPlainlyAndNamesTheOwner() {
        let retry = ChatTakeBack.engineNote(.retry, ownerText: "write a poem", owner: "Addy")
        XCTAssertTrue(retry.hasPrefix("Addy asked for another try"))
        XCTAssertTrue(retry.contains("\"write a poem\""))
        let undo = ChatTakeBack.engineNote(.undo, ownerText: "x", owner: "")
        XCTAssertTrue(undo.contains("/undo"))
        XCTAssertFalse(undo.contains("Addy"))
    }
}

final class BusyMessagesTests: XCTestCase {
    func testOneMessageGoesAsItIsAndSeveralGoTogether() {
        XCTAssertEqual(BusyMessages.combined(["just this"], owner: "Addy"), "just this")
        XCTAssertEqual(BusyMessages.combined(["first", " ", "second\n"], owner: "Addy"),
                       "(Addy sent these 2 messages while you were answering. Answer them together, in one reply.)\n\nfirst\n\nsecond")
        XCTAssertTrue(BusyMessages.combined(["a", "b"], owner: OwnerName.unset).hasPrefix("(The owner sent these 2"))
    }
}
