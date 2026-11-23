import Foundation
import Testing
@testable import ClickyCore

struct EngineMadeImagesTests {
    private let turnStarted = Date(timeIntervalSince1970: 1_000_000)

    @Test func codexKeepsAThreadsPicturesInItsOwnFolder() {
        let home = URL(fileURLWithPath: "/Users/someone/.codex", isDirectory: true)
        let folder = EngineMadeImages.codexFolder(codexHome: home, threadID: "01a2073b-b691-7753-a29e-e7e44a1995fe")
        #expect(folder?.path == "/Users/someone/.codex/generated_images/01a2073b-b691-7753-a29e-e7e44a1995fe")
    }

    @Test func aThreadIDThatCouldLeaveTheFolderIsRefused() {
        let home = URL(fileURLWithPath: "/Users/someone/.codex", isDirectory: true)
        #expect(EngineMadeImages.codexFolder(codexHome: home, threadID: "../../Documents") == nil)
        #expect(EngineMadeImages.codexFolder(codexHome: home, threadID: "..") == nil)
        #expect(EngineMadeImages.codexFolder(codexHome: home, threadID: "  ") == nil)
    }

    @Test func codexHomeComesFromItsVariableElseTheHomeFolder() {
        #expect(EngineMadeImages.codexHome(environment: [:], home: "/Users/someone").path == "/Users/someone/.codex")
        #expect(EngineMadeImages.codexHome(environment: ["CODEX_HOME": "/opt/codex"], home: "/Users/someone").path == "/opt/codex")
        #expect(EngineMadeImages.codexHome(environment: ["CODEX_HOME": "relative"], home: "/Users/someone").path == "/Users/someone/.codex")
    }

    @Test func onlyPicturesWrittenOnThisTurnAreTaken() {
        let files = [
            EngineMadeImages.ListedFile(name: "exec-old.png", modified: turnStarted.addingTimeInterval(-600)),
            EngineMadeImages.ListedFile(name: "exec-second.png", modified: turnStarted.addingTimeInterval(40)),
            EngineMadeImages.ListedFile(name: "exec-first.jpg", modified: turnStarted.addingTimeInterval(30)),
            EngineMadeImages.ListedFile(name: "notes.txt", modified: turnStarted.addingTimeInterval(35)),
            EngineMadeImages.ListedFile(name: "exec-just-before.PNG", modified: turnStarted.addingTimeInterval(-1))
        ]
        #expect(EngineMadeImages.madeThisTurn(files, turnStarted: turnStarted) == ["exec-just-before.PNG", "exec-first.jpg", "exec-second.png"])
    }

    @Test func noMoreThanOneReplyMayAttach() {
        let files = (1...9).map { EngineMadeImages.ListedFile(name: "exec-\($0).png", modified: turnStarted.addingTimeInterval(Double($0))) }
        #expect(EngineMadeImages.madeThisTurn(files, turnStarted: turnStarted).count == BotFileOrder.maximumAttachedPerReply)
    }

    @Test func theCopyGetsAPlainNameThatIsntTaken() {
        #expect(EngineMadeImages.nameInBotFolder(forOriginal: "exec-7626.png") { _ in false } == "image.png")
        let taken: Set<String> = ["image.png", "image 2.png"]
        #expect(EngineMadeImages.nameInBotFolder(forOriginal: "exec-7626.PNG") { taken.contains($0) } == "image 3.png")
        #expect(EngineMadeImages.nameInBotFolder(forOriginal: "exec.webp") { _ in false } == "image.webp")
    }

    @Test func theReplyGetsAFileLineForEachPictureAndTheCardsComeThroughTheUsualPath() {
        let reply = EngineMadeImages.reply("Here's your monkey eating a banana.", attaching: ["image.png", "image 2.png"])
        #expect(reply == "Here's your monkey eating a banana.\n\n[FILE: image.png]\n[FILE: image 2.png]")
        let taken = BotFileOrder.extract(from: reply)
        #expect(taken.attached == ["image.png", "image 2.png"])
        #expect(taken.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Here's your monkey eating a banana.")
    }

    @Test func aPictureTheReplyAlreadySharesIsntAddedTwice() {
        let reply = EngineMadeImages.reply("Here it is.\n[FILE: image.png]", attaching: ["image.png"])
        #expect(reply == "Here it is.\n[FILE: image.png]")
        #expect(EngineMadeImages.reply("Nothing made.", attaching: []) == "Nothing made.")
    }

    @Test func aReplyWithNoWordsStillCarriesThePicture() {
        #expect(EngineMadeImages.reply("  ", attaching: ["image.png"]) == "[FILE: image.png]")
    }
}
