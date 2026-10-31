import Foundation
import Testing
@testable import ClickyCore

/// "save this as a PDF": the voice command (no model), the model's [SNAP:board]
/// tag, where the board goes and what the prompt tells the model.

@Test(arguments: ["save this as a pdf", "Save it as a PDF.", "okay save the board as a pdf", "export as pdf", "export it to pdf",
                  "make a pdf of the board", "make this a pdf", "download the whiteboard as a pdf", "pdf it", "save as p d f",
                  "save board", "save it", "export the whiteboard"])
func saveAsPDFPhrasesAreTheSaveCommand(utterance: String) {
    #expect(BoardVoiceCommand.parse(utterance) == .save, "\(utterance)")
    #expect(BoardVoiceCommand.save.needsOpenBoard)
}

@Test(arguments: ["what is a pdf", "how do i save a pdf in preview", "open the pdf", "save this as a pdf and email it to my boss tomorrow morning",
                  "why is my pdf so big", "save"])
func pdfQuestionsAreNotTheSaveCommand(utterance: String) {
    #expect(BoardVoiceCommand.parse(utterance) != .save, "\(utterance)")
}

@Test func snapBoardTagParses() throws {
    let tag = try #require(MarkTagParser.parse("[SNAP:board]"))
    #expect(tag.kind == .snap)
    #expect(tag.snapshot == SnapshotRequest(target: .board))
    #expect(MarkTagParser.parse("[ snap : Board ]")?.snapshot?.target == .board)
    // +marks means nothing for a board.
    #expect(MarkTagParser.parse("[SNAP:board+marks]") == nil)
}

@Test func snapBoardTagIsNeverSpoken() {
    let extraction = MarkTagParser.extractAll("sure, saving it now. [SNAP:board]")
    #expect(extraction.tags.map(\.snapshot?.target) == [.board])
    #expect(!extraction.speechText.contains("SNAP"))
    #expect(extraction.speechText.contains("saving it now"))

    var router = ResponseRouter()
    var tags: [ParsedTag] = []
    var narration = ""
    for output in router.feed("sure, saving it as a pdf [SN") + router.feed("AP:board] now.") + router.finish() {
        switch output {
        case .tag(_, let tag): tags.append(tag)
        case .narration(let text): narration += text
        default: break
        }
    }
    #expect(tags.map(\.snapshot?.target) == [.board])
    #expect(!narration.contains("SNAP") && !narration.contains("board]"))
}

@Test func boardsAreSavedToPicturesClicky() {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    #expect(BoardExportLocation.directory(home: home).path == "/Users/someone/Pictures/Clicky")
    #expect(BoardExportLocation.savedLine.contains("PDF") && BoardExportLocation.savedLine.contains("Pictures"))
    #expect(!BoardExportLocation.savedLine.contains("/"))
}

@Test func whiteboardPromptTellsTheModelItCanSaveABoard() {
    let text = WhiteboardPromptSection.text
    #expect(text.contains("[SNAP:board]"))
    #expect(text.lowercased().contains("pdf"))
    let prompt = SystemPromptBuilder.mainSystemPrompt(features: .whiteboard, sectionTexts: [.whiteboard: text])
    #expect(prompt.contains("[SNAP:board]"))
}
