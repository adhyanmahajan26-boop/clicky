//
//  ArticleTests.swift
//  ClickyCoreTests
//
//  P8 article highlights and notes: sentence → range matching, OCR lines →
//  per-line rects, line fragments, off-screen ticks, notes Markdown and
//  file naming, dock side, the DSL steps, the tag / voice command, and
//  offscreen renders of the notes panel and a highlight overlay sample
//  into ~/Library/Logs/Clicky/renders/article/.
//

import AppKit
import CoreGraphics
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import ClickyCore

// MARK: - Sentence matching

struct ArticleSentenceMatcherTests {
    static let article = """
        The Quiet Revolution

        Researchers found that “sleep debt” accumulates faster than most people expect. In the study, participants who slept six hours a night performed as badly as those who had been awake for 24 hours.
        Yet the participants rated themselves as only slightly impaired — a dangerous gap between feeling and performance.
        """

    func substring(_ text: String, _ range: Range<Int>) -> String {
        ArticleDocument(text: text, source: .accessibility).substring(utf16Range: range)
    }

    @Test func exactSentenceMapsBackToTheSourceRange() throws {
        let sentence = "In the study, participants who slept six hours a night performed as badly as those who had been awake for 24 hours."
        let match = try #require(ArticleSentenceMatcher.match(sentence, in: Self.article))
        #expect(match.isExact)
        #expect(substring(Self.article, match.utf16Range) == sentence, "the range runs from the first letter through the closing period")
    }

    @Test func quotesCaseAndWhitespaceAreNormalised() throws {
        // Straight quotes, different case, a line break and double spaces in the model's copy.
        let sentence = "researchers found that \"sleep debt\"  accumulates\nfaster than most people expect."
        let match = try #require(ArticleSentenceMatcher.match(sentence, in: Self.article))
        #expect(match.isExact)
        #expect(substring(Self.article, match.utf16Range).hasPrefix("Researchers found that “sleep debt”"))
        #expect(substring(Self.article, match.utf16Range).hasSuffix("expect."))
    }

    @Test func dashesAndCurlyApostrophesDontMatter() throws {
        let sentence = "Yet the participants rated themselves as only slightly impaired - a dangerous gap between feeling and performance."
        #expect(ArticleSentenceMatcher.match(sentence, in: Self.article)?.isExact == true)
        #expect(ArticleSentenceMatcher.match("It's the owner’s book.", in: "Note: it’s the owner's book, really.")?.isExact == true)
    }

    @Test func hyphenationAcrossLinesAndSoftHyphensMatch() throws {
        let ocrText = "The finding is impor-\ntant because it is counter-\nintuitive for most readers."
        let match = try #require(ArticleSentenceMatcher.match("The finding is important because it is counterintuitive for most readers.", in: ocrText))
        #expect(match.isExact)
        let softHyphenText = "An extra\u{00AD}ordinary result."
        #expect(ArticleSentenceMatcher.match("An extraordinary result.", in: softHyphenText)?.isExact == true)
        // And "well-known" written either way.
        #expect(ArticleSentenceMatcher.match("a well known effect", in: "It is a well-\nknown effect.")?.isExact == true)
    }

    @Test func ocrMisreadsMatchApproximatelyButNonsenseDoesNot() throws {
        let ocrText = "Tlie quick brown fox jumps ovcr the lazy dog every rnorning."
        let match = try #require(ArticleSentenceMatcher.match("The quick brown fox jumps over the lazy dog every morning.", in: ocrText))
        #expect(!match.isExact)
        #expect(match.editDistance <= 5)
        #expect(ArticleSentenceMatcher.match("Completely different words that are nowhere here at all.", in: ocrText) == nil)
        // Short targets are exact-only.
        #expect(ArticleSentenceMatcher.match("dgo", in: ocrText) == nil)
    }

    @Test func skeletonKeepsLettersAndDigitsOnly() {
        #expect(ArticleSentenceMatcher.normalizedForComparison("Café — “24 hours”, ﬁne!") == "cafe24hoursfine")
    }
}

// MARK: - Assembly and run map

struct ArticleTextAssemblerTests {
    @Test func runsOfOneBlockJoinAndBlocksBecomeParagraphs() throws {
        let nodes = [
            ArticleTextNode(text: "Why sleep matters", blockIdentifier: 1, isHeading: true),
            ArticleTextNode(text: "  Most adults need ", blockIdentifier: 2),
            ArticleTextNode(text: "seven to nine hours", blockIdentifier: 2),
            ArticleTextNode(text: " of sleep.", blockIdentifier: 2),
            ArticleTextNode(text: "Naps help, too.", blockIdentifier: 3)
        ]
        let document = ArticleTextAssembler.assemble(nodes, title: "Sleep - Google Chrome", url: "https://example.com/sleep")
        #expect(document.text == "Why sleep matters\n\nMost adults need seven to nine hours of sleep.\n\nNaps help, too.")
        #expect(document.title == "Sleep")
        #expect(document.source == .accessibility)

        // A sentence across three runs (a link in the middle) → three run ranges, offsets into each AXValue.
        let match = try #require(ArticleSentenceMatcher.match("Most adults need seven to nine hours of sleep.", in: document.text))
        let runRanges = document.runRanges(for: match.utf16Range)
        #expect(runRanges.map(\.nodeIndex) == [1, 2, 3])
        // Node 1's AXValue starts with two spaces trimmed from the joined text: its range starts at 2.
        #expect(runRanges[0].range.lowerBound == 2)
        #expect(runRanges[1].range == 0..<19)
        #expect(runRanges[2].range.lowerBound == 0)
        #expect(runRanges[2].range.upperBound == 10, "\" of sleep.\" with its period")
    }

    @Test func textIsCappedAtTheLimit() {
        let nodes = (0..<400).map { ArticleTextNode(text: "Sentence number \($0) is part of a long article body.", blockIdentifier: $0) }
        let document = ArticleTextAssembler.assemble(nodes, maximumCharacters: 2_000)
        #expect(document.isTruncated)
        #expect(document.utf16Length <= 2_000)
        #expect(document.spans.allSatisfy { $0.rangeInText.upperBound <= document.utf16Length })
    }

    @Test func ocrPagesDropTheScrollOverlapAndJoinHyphenatedWords() {
        let pages = [["The article starts here and", "continues with an impor-", "tant point."],
                     ["continues with an impor-", "tant point.", "Then a new paragraph begins."]]
        let document = ArticleTextAssembler.assembleOCRPages(pages)
        #expect(document.text == "The article starts here and continues with an important point.\nThen a new paragraph begins.")
        #expect(document.source == .ocr)
    }

    @Test func landmarkPolicy() {
        #expect(ArticleLandmarkPolicy.isSkipped(role: "AXGroup", subrole: "AXLandmarkNavigation"))
        #expect(ArticleLandmarkPolicy.isSkipped(role: "AXGroup", subrole: "AXLandmarkContentInfo"))
        #expect(ArticleLandmarkPolicy.isSkipped(role: "AXButton", subrole: nil))
        #expect(!ArticleLandmarkPolicy.isSkipped(role: "AXGroup", subrole: "AXLandmarkMain"))
        #expect(ArticleLandmarkPolicy.isArticleRoot(role: "AXGroup", subrole: "AXDocumentArticle"))
        #expect(!ArticleLandmarkPolicy.startsBlock(role: "AXLink", subrole: nil))
        #expect(!ArticleLandmarkPolicy.startsBlock(role: "AXGroup", subrole: "AXEmphasis"))
        #expect(ArticleLandmarkPolicy.startsBlock(role: "AXGroup", subrole: nil))
        #expect(ArticleLandmarkPolicy.startsBlock(role: "AXHeading", subrole: nil))
    }

    @Test func articleWindowIsTheFrontBrowserEvenBehindATerminal() {
        let terminal = ArticleWindowChoice.Candidate(processIdentifier: 10, bundleIdentifier: "com.apple.Terminal", windowNumber: 1, frameCG: CGRect(x: 0, y: 0, width: 800, height: 600))
        let chrome = ArticleWindowChoice.Candidate(processIdentifier: 20, bundleIdentifier: "com.google.Chrome", windowNumber: 2, frameCG: CGRect(x: 100, y: 50, width: 1200, height: 900))
        let tinyChrome = ArticleWindowChoice.Candidate(processIdentifier: 20, bundleIdentifier: "com.google.Chrome", windowNumber: 3, frameCG: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(ArticleWindowChoice.choose(frontmostProcessIdentifier: 10, windows: [terminal, tinyChrome, chrome])?.windowNumber == 2)
        #expect(ArticleWindowChoice.choose(frontmostProcessIdentifier: 20, windows: [terminal, chrome])?.windowNumber == 2)
        #expect(ArticleWindowChoice.choose(frontmostProcessIdentifier: 10, windows: [terminal])?.windowNumber == 1)
        #expect(ArticleWindowChoice.choose(frontmostProcessIdentifier: nil, windows: []) == nil)
    }
}

// MARK: - OCR lines and line fragments

struct ArticleGeometryTests {
    /// Three lines of a column, 600 pt wide, 20 pt tall, 6 pt apart.
    static let lines = [
        ArticleOCRLine(text: "Sleep is not a luxury. Researchers found that", frameCG: CGRect(x: 100, y: 200, width: 600, height: 20)),
        ArticleOCRLine(text: "sleep debt accumulates faster than most people", frameCG: CGRect(x: 100, y: 226, width: 600, height: 20)),
        ArticleOCRLine(text: "expect. Naps help a little, but not much.", frameCG: CGRect(x: 100, y: 252, width: 540, height: 20))
    ]

    @Test func aSentenceOverThreeOCRLinesGetsOneRectPerLine() throws {
        let rects = try #require(ArticleOCRMatcher.lineRects(for: "Researchers found that sleep debt accumulates faster than most people expect.", lines: Self.lines))
        #expect(rects.count == 3)
        // Starts mid-line on the first line, full second line, ends early on the third.
        #expect(rects[0].minX > 300 && abs(rects[0].maxX - 700) < 1)
        #expect(abs(rects[1].minX - 100) < 1 && abs(rects[1].width - 600) < 1)
        #expect(abs(rects[2].minX - 100) < 1 && rects[2].maxX < 220)
        #expect(rects.map(\.minY) == [200, 226, 252])
    }

    @Test func aHyphenatedWordAcrossOCRLinesStillMatches() throws {
        let lines = [ArticleOCRLine(text: "This finding is impor-", frameCG: CGRect(x: 0, y: 0, width: 300, height: 18)),
                     ArticleOCRLine(text: "tant for everyone.", frameCG: CGRect(x: 0, y: 24, width: 250, height: 18))]
        let rects = try #require(ArticleOCRMatcher.lineRects(for: "This finding is important for everyone.", lines: lines))
        #expect(rects.count == 2)
    }

    @Test func readingOrderKeepsColumnsApart() {
        let sidebar = ArticleOCRLine(text: "Related: other story", frameCG: CGRect(x: 800, y: 210, width: 200, height: 20))
        let ordered = ArticleOCRMatcher.readingOrder([Self.lines[2], sidebar, Self.lines[0], Self.lines[1]])
        #expect(ordered.map(\.text) == Self.lines.map(\.text) + [sidebar.text])
        // So a sentence across the column's lines isn't broken by the sidebar.
        #expect(ArticleOCRMatcher.lineRects(for: "Researchers found that sleep debt accumulates faster than most people expect.",
                                            lines: [sidebar] + Self.lines)?.count == 3)
    }

    @Test func wordRectsGroupIntoLines() {
        let words = [CGRect(x: 10, y: 100, width: 40, height: 18), CGRect(x: 55, y: 101, width: 30, height: 17), CGRect(x: 90, y: 100, width: 50, height: 18),
                     CGRect(x: 10, y: 124, width: 60, height: 18), CGRect(x: 75, y: 124, width: 20, height: 18)]
        let lines = ArticleLineFragments.lineRects(fromWordRects: words)
        #expect(lines.count == 2)
        #expect(lines[0] == CGRect(x: 10, y: 100, width: 130, height: 18))
        #expect(lines[1] == CGRect(x: 10, y: 124, width: 85, height: 18))
        #expect(ArticleLineFragments.isSingleLine(rangeBounds: CGRect(x: 0, y: 0, width: 300, height: 20), lineHeight: 18))
        #expect(!ArticleLineFragments.isSingleLine(rangeBounds: CGRect(x: 0, y: 0, width: 300, height: 44), lineHeight: 18))
        #expect(ArticleLineFragments.wordRanges(in: "  two words ", base: 10) == [12..<15, 16..<21])
    }
}

// MARK: - Highlight layout and ticks

struct ArticleHighlightLayoutTests {
    static let viewport = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func visibleHighlightsAreClippedAndOffscreenOnesBecomeTicks() {
        let visible = ArticleHighlightGeometry(number: 2, lineRects: [CGRect(x: 150, y: 300, width: 500, height: 18), CGRect(x: 150, y: 324, width: 300, height: 18)])
        let straddling = ArticleHighlightGeometry(number: 3, lineRects: [CGRect(x: 150, y: 690, width: 500, height: 18), CGRect(x: 150, y: 714, width: 300, height: 18)])
        let above = ArticleHighlightGeometry(number: 1, lineRects: [CGRect(x: 150, y: -400, width: 500, height: 18)])
        let below1 = ArticleHighlightGeometry(number: 4, lineRects: [CGRect(x: 150, y: 1200, width: 500, height: 18)])
        let below2 = ArticleHighlightGeometry(number: 5, lineRects: [CGRect(x: 150, y: 1900, width: 500, height: 18)])
        let layout = ArticleHighlightLayout.layout(highlights: [below2, visible, above, straddling, below1], viewport: Self.viewport)

        #expect(layout.visibleNumbers == [2, 3])
        // The straddling one: its first line is clipped at the viewport's bottom; the second line is gone.
        let straddlingStrokes = layout.strokes.filter { $0.number == 3 }
        #expect(straddlingStrokes.count == 1)
        #expect(straddlingStrokes[0].rect.maxY <= Self.viewport.maxY)

        #expect(layout.ticks.map(\.number) == [1, 4, 5])
        #expect(layout.ticks.map(\.direction) == [.above, .below, .below])
        // In the right margin, inside the viewport.
        for tick in layout.ticks {
            #expect(tick.rect.maxX == Self.viewport.maxX - ArticleHighlightLayout.tickRightInset)
            #expect(Self.viewport.contains(tick.rect))
        }
        let aboveTick = layout.ticks[0], firstBelow = layout.ticks[1], secondBelow = layout.ticks[2]
        #expect(aboveTick.rect.minY < Self.viewport.minY + 20)
        #expect(secondBelow.rect.maxY > Self.viewport.maxY - 20)
        #expect(firstBelow.rect.maxY <= secondBelow.rect.minY, "below ticks keep note order top to bottom, without overlapping")
    }

    @Test func scrollingMovesHighlightsByTheAnchorsDelta() {
        let measured = ArticleHighlightGeometry(number: 1, lineRects: [CGRect(x: 150, y: 900, width: 500, height: 18)])
        let anchorThen = CGRect(x: 150, y: 880, width: 600, height: 60)
        let anchorNow = CGRect(x: 150, y: 380, width: 600, height: 60)
        let delta = ArticleHighlightLayout.trackingDelta(originalAnchorFrame: anchorThen, currentAnchorFrame: anchorNow)
        #expect(delta == CGVector(dx: 0, dy: -500))
        let moved = measured.translated(by: delta)
        #expect(moved.lineRects[0].minY == 400)
        #expect(!ArticleHighlightLayout.needsRemeasure(originalAnchorFrame: anchorThen, currentAnchorFrame: anchorNow))
        #expect(ArticleHighlightLayout.needsRemeasure(originalAnchorFrame: anchorThen, currentAnchorFrame: CGRect(x: 150, y: 380, width: 420, height: 84)))
        // Off-screen before the scroll (a tick), on screen after.
        #expect(ArticleHighlightLayout.layout(highlights: [measured], viewport: Self.viewport).ticks.count == 1)
        #expect(ArticleHighlightLayout.layout(highlights: [moved], viewport: Self.viewport).strokes.count == 1)
    }

    @Test func trackingRunsOnlyWhileThereIsSomethingToTrack() {
        #expect(ArticleHighlightCadence.shouldTrack(highlightCount: 3, isPanelOrOverlayShown: true))
        #expect(!ArticleHighlightCadence.shouldTrack(highlightCount: 0, isPanelOrOverlayShown: true))
        #expect(ArticleHighlightCadence.trackingInterval == 0.1)
    }
}

// MARK: - Notes

struct ArticleNotesTests {
    static let notes = ArticleNotes(
        title: "The Quiet Revolution: Sleep / Work",
        url: "https://example.com/sleep",
        summary: "Sleep debt builds quickly and people underestimate it.\nNaps only partly help.",
        items: [
            ArticleNoteItem(note: "Sleep debt builds faster than expected", quote: "Researchers found that “sleep debt” accumulates faster than most people expect."),
            ArticleNoteItem(note: "1. Six hours equals a full night awake", quote: "Participants who slept six hours performed as badly as those awake for 24 hours.")
        ])

    @Test func markdownHasTitleURLSummaryAndQuotedNotes() {
        let date = Date(timeIntervalSince1970: 1_761_400_000)
        let markdown = ArticleNotesMarkdown.render(Self.notes, savedAt: date, timeZone: TimeZone(identifier: "UTC")!)
        let expected = """
            # The Quiet Revolution: Sleep / Work

            Source: <https://example.com/sleep>
            Saved: 2025-10-25 13:46

            ## Summary

            Sleep debt builds quickly and people underestimate it. Naps only partly help.

            ## Notes

            1. Sleep debt builds faster than expected
               > Researchers found that “sleep debt” accumulates faster than most people expect.
            2. 1\\. Six hours equals a full night awake
               > Participants who slept six hours performed as badly as those awake for 24 hours.

            """
        #expect(markdown == expected)
    }

    @Test func fileNamesAreSafeAndNeverOverwriteSomeoneElsesNotes() {
        #expect(ArticleNotesFileNaming.baseName(forTitle: "The Quiet Revolution: Sleep / Work") == "The Quiet Revolution Sleep Work")
        #expect(ArticleNotesFileNaming.baseName(forTitle: "..hidden?") == "hidden")
        #expect(ArticleNotesFileNaming.baseName(forTitle: "  \n ") == "Article notes")
        #expect(ArticleNotesFileNaming.baseName(forTitle: String(repeating: "word ", count: 40)).count <= 80)
        #expect(ArticleNotesFileNaming.fileName(baseName: "A", fileExtension: "md", existingFileNames: [], ownedFileNames: []) == "A.md")
        #expect(ArticleNotesFileNaming.fileName(baseName: "A", fileExtension: "md", existingFileNames: ["A.md", "A 2.md"], ownedFileNames: []) == "A 3.md")
        #expect(ArticleNotesFileNaming.fileName(baseName: "A", fileExtension: "md", existingFileNames: ["A.md"], ownedFileNames: ["A.md"]) == "A.md")
        #expect(ArticleNotesFileNaming.defaultDirectory(homeDirectory: URL(fileURLWithPath: "/Users/x")).path == "/Users/x/Clicky Notes")
    }

    @Test @MainActor func saveWritesMarkdownAndPDFIntoTheFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-notes-test-\(UUID().uuidString)/Clicky Notes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let first = try ArticleNotesExport.save(Self.notes, to: directory, ownedFileNames: [], savesPDF: true)
        #expect(first.markdownURL.lastPathComponent == "The Quiet Revolution Sleep Work.md")
        #expect(try String(contentsOf: first.markdownURL, encoding: .utf8).contains("## Notes"))
        let pdfURL = try #require(first.pdfURL)
        let document = try #require(PDFDocument(url: pdfURL))
        #expect(document.pageCount >= 1)
        #expect(document.string?.contains("Sleep debt builds faster") == true)
        // Saved again in the same session: the same files. By someone else: a new name.
        let owned = Set(first.paths.map { ($0 as NSString).lastPathComponent })
        #expect(try ArticleNotesExport.save(Self.notes, to: directory, ownedFileNames: owned, savesPDF: false).markdownURL == first.markdownURL)
        #expect(try ArticleNotesExport.save(Self.notes, to: directory, ownedFileNames: [], savesPDF: false).markdownURL.lastPathComponent == "The Quiet Revolution Sleep Work 2.md")
    }

    @Test func notesBoardCarriesSummaryAndNumberedNotes() {
        let board = ArticleNotesBoard.board(for: Self.notes)
        #expect(board.title == Self.notes.title)
        #expect(board.elements.map(\.id) == ["source", "summary", "items"])
        if case .list(let list) = board.elements[2].payload {
            #expect(list.isOrdered)
            #expect(list.items.count == 2)
            #expect(list.items[0].contains("“Researchers found"))
        } else {
            Issue.record("the notes should be a list")
        }
    }

    @Test func notesAreClippedToFifteenWords() {
        let long = (1...20).map { "w\($0)" }.joined(separator: " ")
        #expect(ArticleNotes.clippedNote(long).split(separator: " ").count == 15)
        #expect(ArticleNotes.clippedNote(long).hasSuffix("…"))
        #expect(ArticleNotes.clippedNote("short note") == "short note")
    }

    @Test func summaryIsSpokenOnlyWhenTheAnswerDidntSayIt() {
        let summary = "Sleep debt builds quickly and people underestimate how impaired they are."
        let saidIt = "sleep debt builds quickly, and people underestimate how impaired they are. <actions>{\"steps\":[{\"do\":\"notes\",\"summary\":\"\(summary)\"}]}</actions>"
        let didnt = "here are your notes. <actions>{\"steps\":[{\"do\":\"notes\",\"summary\":\"\(summary)\"}]}</actions>"
        #expect(!ArticleSummarySpeech.needsSpeaking(summary: summary, rawResponse: saidIt))
        #expect(ArticleSummarySpeech.needsSpeaking(summary: summary, rawResponse: didnt))
        #expect(ArticleSummarySpeech.needsSpeaking(summary: summary, rawResponse: "<actions>{\"summary\":\"\(summary)\""), "an unclosed block isn't speech")
        #expect(ArticleSummarySpeech.narrationOutsideActionBlocks("a <actions>x</actions> b <actions>y") == "a  b ")
    }

    @Test func modelTextHasTheHeaderAndTheArticle() {
        let document = ArticleDocument(text: "Body text.", title: "T", url: "https://e.com", source: .ocr, isTruncated: true)
        let text = ArticleModelText.text(for: document)
        #expect(text.hasPrefix("title: T\nurl: https://e.com\nread via: screenshots (OCR)"))
        #expect(text.contains("cut at the limit"))
        #expect(text.hasSuffix("\n\nBody text."))
    }
}

// MARK: - Docking

struct ArticleNotesDockTests {
    static let display = CGRect(x: 0, y: 25, width: 1728, height: 1050)

    @Test func docksOnTheSideWithMoreFreeSpace() {
        let leftHeavy = ArticleNotesDock.placement(windowFrameCG: CGRect(x: 600, y: 40, width: 1100, height: 1000), articleColumnCG: nil, visibleFrameCG: Self.display)
        #expect(leftHeavy.side == .left)
        #expect(leftHeavy.frameCG.maxX <= 600 - ArticleNotesDock.gap + 0.5)
        #expect(leftHeavy.frameCG.width == ArticleNotesDock.preferredWidth)
        #expect(!leftHeavy.coversArticleColumn)

        let rightHeavy = ArticleNotesDock.placement(windowFrameCG: CGRect(x: 10, y: 40, width: 1100, height: 1000), articleColumnCG: nil, visibleFrameCG: Self.display)
        #expect(rightHeavy.side == .right)
        #expect(rightHeavy.frameCG.minX >= 1110)
        #expect(Self.display.contains(rightHeavy.frameCG))
    }

    @Test func aFullScreenWindowGetsThePanelInItsMarginNotOverTheColumn() {
        let window = CGRect(x: 0, y: 25, width: 1728, height: 1050)
        let column = CGRect(x: 520, y: 25, width: 680, height: 1050)
        let placement = ArticleNotesDock.placement(windowFrameCG: window, articleColumnCG: column, visibleFrameCG: Self.display)
        #expect(placement.side == .insideRight)
        #expect(placement.frameCG.minX >= column.maxX)
        #expect(!placement.frameCG.intersects(column))
        #expect(!placement.coversArticleColumn)

        // Left margin wider than the right: docks left of the column.
        let offCentre = CGRect(x: 900, y: 25, width: 700, height: 1050)
        let leftPlacement = ArticleNotesDock.placement(windowFrameCG: window, articleColumnCG: offCentre, visibleFrameCG: Self.display)
        #expect(leftPlacement.side == .insideLeft)
        #expect(leftPlacement.frameCG.maxX <= offCentre.minX)
    }

    @Test func nothingFitsSoItSaysItCoversTheColumn() {
        let narrowDisplay = CGRect(x: 0, y: 25, width: 900, height: 700)
        let placement = ArticleNotesDock.placement(windowFrameCG: narrowDisplay, articleColumnCG: CGRect(x: 120, y: 25, width: 700, height: 700), visibleFrameCG: narrowDisplay)
        #expect(placement.coversArticleColumn)
        #expect(placement.frameCG.width == ArticleNotesDock.minimumWidth)
        #expect(narrowDisplay.contains(placement.frameCG))
    }
}

// MARK: - DSL, tiers, loop, tags, prompt

struct ArticleActionsTests {
    static let longSentence = "Researchers found that sleep debt accumulates faster than most people expect, and that it takes several nights of recovery to repay."

    @Test func readArticleAndNotesSteps() throws {
        let body = """
            {"goal":"notes on the article","steps":[
              {"do":"highlight","targets":["\(Self.longSentence)","Opening hours",7]},
              {"do":"notes","title":"Sleep","summary":"Sleep debt builds fast.","items":[{"note":"Debt accumulates faster than expected","quote":"“\(Self.longSentence)”"},"plain note"]},
              {"do":"read_article"}],"done":true}
            """
        let plan = try ActionDSL.parse(body).get()
        #expect(plan.rejectedSteps.isEmpty)
        guard case .highlight(let targets, _) = plan.steps[0] else { Issue.record("highlight"); return }
        #expect(targets == [.text(Self.longSentence), .text("Opening hours"), .element(7)])
        #expect(targets.map(\.isSentence) == [true, false, false])
        guard case .notes(let notes) = plan.steps[1] else { Issue.record("notes"); return }
        #expect(notes.title == "Sleep")
        #expect(notes.summary == "Sleep debt builds fast.")
        #expect(notes.items == [ArticleNoteItem(note: "Debt accumulates faster than expected", quote: Self.longSentence), ArticleNoteItem(note: "plain note", quote: "")])
        #expect(plan.steps[2] == .readArticle)
        #expect(plan.steps[2].verb == "read_article")
        #expect(plan.steps[2].shortDescription == "read the article")
        #expect(plan.steps[1].shortDescription == "show 2 notes")
        #expect(plan.steps.allSatisfy { $0.isReadOnly && !$0.changesScreen })
        // A notes step with nothing in it is rejected.
        let empty = try ActionDSL.parse(#"{"steps":[{"do":"notes"},{"do":"wait","seconds":1}]}"#).get()
        #expect(empty.rejectedSteps.first?.verb == "notes")
    }

    @Test func sentenceTargetsBecomeHighlightMarksAndShortTextUnderlines() throws {
        let tags = ActionHighlightTags.tags(targets: [.text(Self.longSentence), .text("Opening hours")], notes: [])
        #expect(tags[0].hasPrefix("[MARK:highlight:\""))
        #expect(tags[1].hasPrefix("[MARK:underline:\""))
        let parsed = try #require(MarkTagParser.parse(tags[0]))
        #expect(parsed.style == .highlight)
        #expect(parsed.hasExplicitStyle)
        // A 400-character sentence is still a target; longer ones are dropped.
        let long = String(repeating: "a", count: 400)
        #expect(ActionDSL.highlightTarget(long) == .text(long))
        #expect(ActionDSL.highlightTarget(long + "a") == nil)
    }

    @Test func readingAndNotesAreFreeButSafariStaysProtected() {
        let chrome = ActionTargetFacts(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "Article")
        let safari = ActionTargetFacts(bundleIdentifier: "com.apple.Safari", applicationName: "Safari", windowTitle: "Article")
        let notes = ActionStep.notes(ArticleNotes(title: "", summary: "s", items: []))
        let context = ActionTurnContext(ownerTranscript: "highlight the important things")
        #expect(ActionTierClassifier.classify(.readArticle, target: chrome, context: context).tier == .free)
        #expect(ActionTierClassifier.classify(notes, target: chrome, context: context).tier == .free)
        #expect(ActionTierClassifier.classify(.readArticle, target: safari, context: context).tier == .refused)
        #expect(ActionTierClassifier.classify(.readArticle, target: safari, context: ActionTurnContext(ownerTranscript: "make notes on this safari article")).tier == .free)
        #expect(ActionTierClassifier.classify(.readArticle, target: ActionTargetFacts(isOwnApplication: true), context: context).tier == .refused)
    }

    @Test func aReadArticleAlwaysGetsAnObserveTurnWithTheArticle() {
        var loop = ActionTaskLoop(goal: "highlight the important things", ownerTranscript: "highlight the important things")
        loop.record(.readArticle, tier: .free, tierReason: nil, outcome: .done(detail: "read 1200 characters via AX"))
        loop.pendingArticleText = "title: Sleep\n\nBody."
        #expect(loop.needsObserveTurn(planWasDone: true, wasCancelled: false))
        let message = loop.continuationMessage()
        #expect(message.contains("ARTICLE (read from the front browser window):\ntitle: Sleep\n\nBody.\nEND ARTICLE"))
        #expect(message.contains("7 to 8 most important sentences"))
        #expect(message.contains("WORD FOR WORD"))
        #expect(message.contains("\"do\":\"notes\""))
    }

    @Test func notesTagAndVoiceCommand() {
        #expect(NotesTag.parse("[NOTES:save]") == .save)
        #expect(NotesTag.parse("[ notes: Export ]") == .save)
        #expect(NotesTag.parse("[NOTES:close]") == .close)
        #expect(NotesTag.parse("[NOTES:burn]") == nil)
        #expect(NotesVoiceCommand.parse("save my notes") == .save)
        #expect(NotesVoiceCommand.parse("Okay clicky, save the notes please.") == .save)
        #expect(NotesVoiceCommand.parse("save my notes as a p d f") == .save)
        #expect(NotesVoiceCommand.parse("save the board") == nil)
        #expect(NotesVoiceCommand.parse("can you tell me what my notes say about sleep") == nil)
    }

    @Test func routerEmitsTheNotesTagAndNeverSpeaksIt() {
        var router = ResponseRouter()
        let outputs = router.feed("saving them now. [NOTES:save] done.") + router.finish()
        #expect(outputs.contains(.notesCommand(.save)))
        let narration = outputs.compactMap { output -> String? in
            if case .narration(let text) = output { return text }
            return nil
        }.joined()
        #expect(!narration.contains("NOTES"))
        #expect(narration.contains("saving them now."))
    }

    @Test func promptTeachesTheArticleFlow() {
        let prompt = ActionsPromptSection.text
        #expect(prompt.contains("read_article {}"))
        #expect(prompt.contains("notes {title, summary, items: [{note, quote}]}"))
        #expect(prompt.contains("7–8 most important sentences"))
        #expect(prompt.contains("word for word"))
        #expect(prompt.contains("at most 15 words"))
        #expect(prompt.contains("[NOTES:save]"))
    }
}

// MARK: - Renders

/// Offscreen renders (ImageRenderer: no window, nothing on screen) of the
/// notes panel, light and dark, and of a highlighter overlay over a mock
/// article, into ~/Library/Logs/Clicky/renders/article/.
@MainActor
struct ArticleRenderTests {
    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clicky/renders/article", isDirectory: true)

    static let notes = ArticleNotes(
        title: "Why We Underestimate Sleep Debt",
        url: "http://localhost:8000/sleep.html",
        summary: "Losing sleep piles up faster than people think, and they feel far less impaired than they are.",
        items: [
            ArticleNoteItem(note: "Sleep debt builds faster than people expect", quote: "Researchers found that sleep debt accumulates faster than most people expect."),
            ArticleNoteItem(note: "Six hours a night ≈ a full night awake", quote: "Participants who slept six hours a night performed as badly as those awake for 24 hours."),
            ArticleNoteItem(note: "People don't notice how impaired they are", quote: "Yet they rated themselves as only slightly impaired."),
            ArticleNoteItem(note: "Weekend catch-up sleep doesn't fully repay it", quote: "Two nights of recovery sleep did not restore performance."),
            ArticleNoteItem(note: "Consistency matters more than total hours", quote: "Regular bedtimes predicted performance better than total sleep.")
        ])

    func renderNotes(appearanceName: NSAppearance.Name, colorScheme: ColorScheme) throws -> NSImage {
        let state = ArticleNotesViewState(notes: Self.notes, unmatchedNumbers: [5], offscreenDirections: [1: .above, 4: .below],
                                          savedPaths: ["/Users/owner/Clicky Notes/Why We Underestimate Sleep Debt.md"])
        let content = ArticleNotesView(state: state, actions: .inert, isScrollable: false)
            .frame(width: ArticleNotesDock.preferredWidth)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, colorScheme)
        let appearance = try #require(NSAppearance(named: appearanceName))
        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            image = renderer.nsImage
        }
        return try #require(image)
    }

    @Test func notesPanelRendersLightAndDark() throws {
        let light = try renderNotes(appearanceName: .aqua, colorScheme: .light)
        let dark = try renderNotes(appearanceName: .darkAqua, colorScheme: .dark)
        #expect(light.size.width == ArticleNotesDock.preferredWidth)
        #expect(light.size.height > 400, "height \(light.size.height)")
        _ = try AgentsDashboardRenderTests.writePNGFile(light, to: Self.outputDirectory.appendingPathComponent("notes-panel-light.png"))
        _ = try AgentsDashboardRenderTests.writePNGFile(dark, to: Self.outputDirectory.appendingPathComponent("notes-panel-dark.png"))
        #expect(AgentsDashboardRenderTests.averageLuminance(light) > 0.7)
        #expect(AgentsDashboardRenderTests.averageLuminance(dark) < 0.4)
    }

    /// A mock article column (monospaced lines at known positions) with two
    /// highlighted sentences, one wrapping over three lines, and two ticks.
    @Test func highlightOverlaySampleRenders() throws {
        let lineHeight: CGFloat = 26
        let characterWidth: CGFloat = 8.4 // 14 pt Menlo
        let left: CGFloat = 40
        let top: CGFloat = 60
        let lines = [
            "Sleep is not a luxury. Researchers found that sleep",
            "debt accumulates faster than most people expect, and",
            "that it takes several nights of recovery to repay.",
            "In the study, participants who slept six hours a",
            "night performed as badly as those awake for 24 hours.",
            "Yet they rated themselves as only slightly impaired."
        ]
        let ocrLines = lines.enumerated().map { index, text in
            ArticleOCRLine(text: text, frameCG: CGRect(x: left, y: top + CGFloat(index) * lineHeight, width: CGFloat(text.count) * characterWidth, height: 18))
        }
        let firstRects = try #require(ArticleOCRMatcher.lineRects(for: "Researchers found that sleep debt accumulates faster than most people expect, and that it takes several nights of recovery to repay.", lines: ocrLines))
        let secondRects = try #require(ArticleOCRMatcher.lineRects(for: "Yet they rated themselves as only slightly impaired.", lines: ocrLines))
        #expect(firstRects.count == 3)
        let viewport = CGRect(x: 0, y: 0, width: 640, height: 260)
        let layout = ArticleHighlightLayout.layout(highlights: [
            ArticleHighlightGeometry(number: 2, lineRects: firstRects),
            ArticleHighlightGeometry(number: 3, lineRects: secondRects),
            ArticleHighlightGeometry(number: 1, lineRects: [CGRect(x: left, y: -300, width: 300, height: 18)]),
            ArticleHighlightGeometry(number: 4, lineRects: [CGRect(x: left, y: 900, width: 300, height: 18)])
        ], viewport: viewport)
        #expect(layout.strokes.count == 4)
        #expect(layout.ticks.map(\.number) == [1, 4])

        let page = ZStack(alignment: .topLeading) {
            Color.white
            Text("Why We Underestimate Sleep Debt").font(.system(size: 18, weight: .bold)).foregroundColor(.black).offset(x: left, y: 18)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                Text(text).font(.custom("Menlo", size: 14)).foregroundColor(.black)
                    .frame(height: 18, alignment: .leading)
                    .offset(x: left, y: top + CGFloat(index) * lineHeight)
            }
            ArticleHighlightCanvas(layout: layout, originCG: viewport.origin)
        }
        .frame(width: viewport.width, height: viewport.height)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        _ = try AgentsDashboardRenderTests.writePNGFile(image, to: Self.outputDirectory.appendingPathComponent("highlight-overlay-sample.png"))
        // The strokes are yellow: a pixel inside the first stroke is warmer than the white page.
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let probe = layout.strokes[1].rect
        let color = try #require(bitmap.colorAt(x: Int((probe.minX + 4) * 2), y: Int((probe.midY) * 2))?.usingColorSpace(.sRGB))
        #expect(color.blueComponent < color.redComponent - 0.15, "stroke pixel \(color)")
    }
}

/// Live: Safari was frontmost with the owner's Netflix window first in the list; the reader picked it.
@Test func articleWindowChoiceSkipsNetflix() {
    let netflix = ArticleWindowChoice.Candidate(processIdentifier: 10, bundleIdentifier: "com.apple.Safari", windowNumber: 1,
                                                frameCG: CGRect(x: -1920, y: 155, width: 1920, height: 1080), title: "Netflix")
    let nasa = ArticleWindowChoice.Candidate(processIdentifier: 10, bundleIdentifier: "com.apple.Safari", windowNumber: 2,
                                             frameCG: CGRect(x: 0, y: 25, width: 1700, height: 1400), title: "Black Hole Basics - NASA Science")
    #expect(ArticleWindowChoice.choose(frontmostProcessIdentifier: 10, windows: [netflix, nasa])?.windowNumber == 2)
    #expect(ArticleWindowChoice.choose(frontmostProcessIdentifier: 10, windows: [netflix]) == nil)
}

@Test func readFurtherHeuristicsAndExpanders() {
    #expect(ArticleReadFurther.looksCutShort(text: "intro… Read more", characterCount: 9000, hitDeadline: false))
    #expect(ArticleReadFurther.looksCutShort(text: "short", characterCount: 1200, hitDeadline: false))
    #expect(!ArticleReadFurther.looksCutShort(text: String(repeating: "a ", count: 5000), characterCount: 10000, hitDeadline: false))
    #expect(!ArticleReadFurther.looksCutShort(text: "x", characterCount: 100, hitDeadline: true))
    #expect(ArticleReadFurther.isPlainExpander("Read more"))
    #expect(ArticleReadFurther.isPlainExpander("Continue reading"))
    #expect(!ArticleReadFurther.isPlainExpander("Subscribe to read more"))
    #expect(!ArticleReadFurther.isPlainExpander("Sign in to continue reading"))
}
