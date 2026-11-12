import Foundation
import Testing
@testable import ClickyCore

struct BotPDFOrderTests {
    @Test func takesTheTagOutAndKeepsTheWords() {
        let taken = BotPDFOrder.extract(from: "Here's the invoice.\n[PDF: invoice.md]\nAnything else?")
        #expect(taken.files == ["invoice.md"])
        #expect(taken.text == "Here's the invoice.\n\nAnything else?")
    }

    @Test func aTagInCodeIsLeftAlone() {
        let taken = BotPDFOrder.extract(from: "Write `[PDF: x.md]` to get one.")
        #expect(taken.files.isEmpty)
    }

    @Test func onlyFilesInsideTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-order-\(UUID().uuidString)/ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        #expect(BotPDFOrder.file(named: "invoice.md", in: folder)?.lastPathComponent == "invoice.md")
        #expect(BotPDFOrder.file(named: "sub/invoice.md", in: folder)?.lastPathComponent == "invoice.md")
        #expect(BotPDFOrder.file(named: "../bots.json", in: folder) == nil)
        #expect(BotPDFOrder.file(named: "sub/../../bots.json", in: folder) == nil)
        #expect(BotPDFOrder.file(named: "/etc/passwd", in: folder) == nil)
        #expect(BotPDFOrder.file(named: folder.appendingPathComponent("ok.md").path, in: folder) != nil)
    }

    @Test func atMostThreePerReply() {
        let text = (1...5).map { "[PDF: f\($0).md]" }.joined(separator: "\n")
        #expect(BotPDFOrder.extract(from: text).files.count == 3)
    }
}
