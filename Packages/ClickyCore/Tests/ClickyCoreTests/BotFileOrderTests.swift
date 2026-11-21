import Foundation
import Testing
@testable import ClickyCore

struct BotFileOrderTests {
    @Test func takesFileAndSaveLinesOutAndKeepsTheWords() {
        let taken = BotFileOrder.extract(from: "Here's the report.\n[FILE: report.md]\n[SAVE FILE: report.pdf -> Desktop]\nAnything else?")
        #expect(taken.attached == ["report.md"])
        #expect(taken.saves == [BotFileOrder.SaveOrder(file: "report.pdf", place: .desktop)])
        #expect(taken.text == "Here's the report.\n\nAnything else?")
    }

    @Test func saveLinesTakeTheUsualWaysOfNamingThePlace() {
        let text = """
        [SAVE FILE: a.pdf -> Downloads]
        [SAVE FILE: b.pdf to my Desktop]
        [SAVE FILE: c.pdf → desktop]
        [SAVE FILE: d.pdf: the downloads folder]
        [SAVE FILE: e.pdf -> Documents]
        """
        let saves = BotFileOrder.extract(from: text).saves
        #expect(saves.map(\.file) == ["a.pdf", "b.pdf", "c.pdf", "d.pdf"])
        #expect(saves.map(\.place) == [.downloads, .desktop, .desktop, .downloads])
    }

    @Test func aFileNameWithToInItStillWorks() {
        let saves = BotFileOrder.extract(from: "[SAVE FILE: how to sell.pdf -> Desktop]").saves
        #expect(saves == [BotFileOrder.SaveOrder(file: "how to sell.pdf", place: .desktop)])
    }

    @Test func aTagInCodeIsLeftAlone() {
        let taken = BotFileOrder.extract(from: "Write `[FILE: x.md]` to share one.")
        #expect(taken.attached.isEmpty)
        #expect(taken.text.contains("[FILE: x.md]"))
    }

    @Test func aPDFTagIsNotAFileTag() {
        let taken = BotFileOrder.extract(from: "[PDF: x.md]")
        #expect(taken.attached.isEmpty)
        #expect(taken.text == "[PDF: x.md]")
    }

    @Test func atMostFivePerReply() {
        let text = (1...8).map { "[FILE: f\($0).md]" }.joined(separator: "\n")
        #expect(BotFileOrder.extract(from: text).attached.count == 5)
    }

    @Test func theCardHoldsThePathAndOldPDFNotesStillGiveTheirs() {
        #expect(BotFileOrder.path(card: BotFileOrder.card(forPath: "/Users/a/x.pdf"), noteText: nil) == "/Users/a/x.pdf")
        #expect(BotFileOrder.path(card: "screen|abc", noteText: nil) == nil)
        let old = "Vello made the PDF r.pdf for Vello: [r.pdf](file:///Users/a/Library/Application%20Support/Theo/Bots/memory/theo/r.pdf)\n/Users/a/Library/Application Support/Theo/Bots/memory/theo/r.pdf"
        #expect(BotFileOrder.path(card: nil, noteText: old) == "/Users/a/Library/Application Support/Theo/Bots/memory/theo/r.pdf")
        #expect(BotFileOrder.noteWithoutPath(old) == "Vello made the PDF r.pdf for Vello.")
        #expect(BotFileOrder.path(card: nil, noteText: "Vello couldn't make a PDF for Ada: no file") == nil)
        #expect(BotFileOrder.noteWithoutPath("Something else") == "Something else")
    }

    @Test func aCopyNeverReplacesWhatsThere() {
        let taken: Set<String> = ["report.pdf", "report 2.pdf", "notes"]
        #expect(BotFileOrder.freeName(for: "report.pdf") { taken.contains($0) } == "report 3.pdf")
        #expect(BotFileOrder.freeName(for: "new.pdf") { taken.contains($0) } == "new.pdf")
        #expect(BotFileOrder.freeName(for: "notes") { taken.contains($0) } == "notes 2")
    }

    @Test func programsAreShownNotOpened() {
        #expect(BotFileOrder.opensDirectly(fileName: "report.pdf"))
        #expect(BotFileOrder.opensDirectly(fileName: "sheet.csv"))
        #expect(BotFileOrder.opensDirectly(fileName: "page.html"))
        #expect(!BotFileOrder.opensDirectly(fileName: "run.command"))
        #expect(!BotFileOrder.opensDirectly(fileName: "Thing.app"))
        #expect(!BotFileOrder.opensDirectly(fileName: "install.PKG"))
        #expect(!BotFileOrder.opensDirectly(fileName: "go.sh"))
    }

    @Test func streamingHidesHalfWrittenFileLines() {
        #expect(BotTagWords.withoutTags(streaming: "Here it is. [FILE: rep") == "Here it is. ")
        #expect(BotTagWords.withoutTags(streaming: "Copying. [SAVE FILE: r.pdf -> Desk") == "Copying. ")
    }

    @Test func theHowToNamesBothLinesAndTheOwner() {
        let howTo = BotFileOrder.howTo(owner: "Sam")
        #expect(howTo.contains("[FILE: file name]"))
        #expect(howTo.contains("[SAVE FILE: file name -> Desktop]"))
        #expect(howTo.contains("Sam"))
        #expect(!howTo.contains("Addy"))
    }
}
