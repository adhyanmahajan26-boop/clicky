import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import ClickyCore

/// The whiteboard PDF export (P6.10), end to end and offscreen: five boards
/// (a real DNS board from a turn log, math, a 30-line code block, a long
/// 8-section board, charts + a table, and "tall": the long board with code in
/// every section, taller than A4 proportions so it's paged) × three themes go through the app's
/// own export path (WhiteboardExporter.exportPDFData, what
/// BoardController.exportBoard writes) and each PDF is checked:
///  - pages: count and size (A4-proportioned paging of tall boards, cut
///    between section rows), every element inside its page;
///  - pixels: each page rendered with CoreGraphics vs the same rows of the
///    1:1 board render (WhiteboardExporter.exportImage, the PNG export of
///    the on-screen view), downsampled luma SSIM / mean abs diff; charts not blank;
///  - text layer (PDFKit): title and key labels, formulas' TeX source;
///  - vector: text-show and path operators, no image covering the page
///    (formulas included: no image XObjects at all on the math board);
///  - fonts embedded; light / dark legible (ink vs background contrast).
/// Outputs: ~/Library/Logs/Clicky/renders/pdf/<board>-<theme>.pdf, a PNG per
/// page, the 1:1 reference and the panel render, and report.txt.
@MainActor
@Suite(.serialized)
struct PDFExportTests {
    static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixturesDirectory = testsDirectory.appendingPathComponent("Fixtures/pdf", isDirectory: true)
    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clicky/renders/pdf", isDirectory: true)
    static let panelSize = CGSize(width: 1280, height: 860)

    static let minimumSSIM = 0.97
    static let maximumMeanAbsoluteDifference = 0.02

    nonisolated static let boardNames = ["dns", "math", "code", "long", "chart", "tall"]

    /// Words each board's PDF text must contain (compared with all whitespace removed).
    static let expectedText: [String: [String]] = [
        "dns": ["How DNS resolution works", "Browser", "Recursive resolver", "Root server", ".com TLD server",
                "Authoritative server for example.com", "where is example.com?", "Key points"],
        "math": ["Three formulas", "Quadratic formula", "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", "\\int_0^1 x^2 \\, dx = \\frac{1}{3}",
                 "\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}", "Each row times the column vector"],
        "code": ["Breadth-first search in Python", "def bfs(graph, start, goal):", "queue.append(neighbour)",
                 "print(bfs(graph, \"f\", \"a\"))  # None", "# 30 lines of breadth-first search", "The parent map doubles as the visited set."],
        "long": ["From source code to a running program", "Agenda", "Parsing", "Type checking", "Optimisation", "Code generation",
                 "Linking", "Loading", "Loading d", "Recap", "The linker joins the pieces"],
        "tall": ["Compiler pipeline with code", "Parsing", "Loading", "step_30 = loading(step_29)  # line 30", "Loading d", "The linker joins the pieces"],
        "chart": ["Language popularity", "Developers using it (%)", "Rust usage by year", "Backend share", "JavaScript", "62%"]
    ]

    static func scene(named boardName: String) throws -> WhiteboardScene {
        WBMathRenderer.install()
        let answerText = try String(contentsOf: fixturesDirectory.appendingPathComponent("\(boardName).txt"), encoding: .utf8)
        let outcome = WBStreamParser.parse(WBBlockExtractor.whiteboardBody(in: answerText))
        #expect(outcome.isUsable && outcome.stats.droppedCount == 0, "\(boardName) should parse cleanly")
        return WhiteboardScene(board: outcome.board, viewportSize: WhiteboardScene.viewportSize(forPanelSize: panelSize))
    }

    static func squashed(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    struct Row {
        var name = ""
        var pages = 0
        var size = ""
        var missingText: [String] = []
        var isVector = false
        var imageCount = 0
        var fontsEmbedded = false
        var fontCount = 0
        var worstSSIM = 1.0
        var worstMAD = 0.0
        var elementsOffPage: [String] = []
        var blankCharts = 0
        var inkContrast = 1.0
        var meanLuma = 0.0

        var passes: Bool {
            pages >= 1 && missingText.isEmpty && isVector && fontsEmbedded && elementsOffPage.isEmpty && blankCharts == 0
                && worstSSIM >= PDFExportTests.minimumSSIM && worstMAD <= PDFExportTests.maximumMeanAbsoluteDifference && inkContrast >= 0.45
        }

        var line: String {
            "| \(name) | \(pages) | \(size) | \(missingText.isEmpty ? "all" : "missing \(missingText)") | \(isVector ? "yes" : "NO") (images \(imageCount)) | " +
                "\(fontsEmbedded ? "yes" : "NO") (\(fontCount)) | ssim \(String(format: "%.3f", worstSSIM)) mad \(String(format: "%.4f", worstMAD)), off-page \(elementsOffPage.count), blank charts \(blankCharts) | " +
                "contrast \(String(format: "%.2f", inkContrast)) | \(passes ? "PASS" : "FAIL") |"
        }
    }

    /// Exports one board in one theme the way the app does, writes the samples and measures them.
    static func evaluate(boardName: String, theme: WhiteboardTheme) throws -> Row {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let scene = try scene(named: boardName)
        let baseName = "\(boardName)-\(theme.rawValue)"
        var row = Row(name: baseName)

        let pdfURL = outputDirectory.appendingPathComponent(baseName + ".pdf")
        try WhiteboardExporter.exportPDF(scene: scene, theme: theme, to: pdfURL)
        let data = try Data(contentsOf: pdfURL)
        let report = try #require(WhiteboardPDFInspector.inspect(data: data))
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        let plan = WhiteboardExporter.pdfPages(for: scene)

        row.pages = report.pageCount
        row.size = Set(report.pages.map { "\(Int($0.size.width.rounded()))×\(Int($0.size.height.rounded()))" }).sorted().joined(separator: ",")
        let text = squashed(report.text)
        row.missingText = (expectedText[boardName] ?? []).filter { !text.contains(squashed($0)) }
        if !text.contains(squashed(scene.board.title)) { row.missingText.append(scene.board.title) }
        row.isVector = report.isVector
        row.imageCount = report.pages.map(\.imageDrawCount).reduce(0, +)
        row.fontsEmbedded = !report.fonts.isEmpty && report.allFontsEmbedded
        row.fontCount = report.fonts.count

        // Every element on exactly one page and inside it.
        #expect(plan.count == report.pageCount)
        for placed in scene.layout.elements {
            let pagesShowing = plan.indices.filter { plan[$0].sectionIdentifiers.contains(placed.sectionID) }
            guard pagesShowing.count == 1, let page = plan[safe: pagesShowing[0]] else {
                row.elementsOffPage.append(placed.id)
                continue
            }
            let rectInPage = placed.rect.offsetBy(dx: 0, dy: WhiteboardScene.headerHeight - page.boardRect.minY)
            let body = CGRect(x: 0, y: WhiteboardScene.headerHeight, width: page.pageSize.width, height: page.pageSize.height - WhiteboardScene.headerHeight)
            if !body.contains(rectInPage) { row.elementsOffPage.append(placed.id) }
        }

        // Pixels: each page vs the same rows of the 1:1 board render.
        let scale = WhiteboardExporter.exportScale
        let reference = try #require(WhiteboardExporter.exportImage(scene: scene, theme: theme))
        try WhiteboardExporter.pngData(reference)?.write(to: outputDirectory.appendingPathComponent(baseName + "-reference.png"))
        if let panel = WhiteboardExporter.panelImage(scene: scene, theme: theme, panelSize: panelSize) {
            try WhiteboardExporter.pngData(panel)?.write(to: outputDirectory.appendingPathComponent(baseName + "-panel.png"))
        }
        var contrasts: [Double] = [], means: [Double] = []
        for (pageIndex, page) in plan.enumerated() {
            let cgPage = try #require(document.page(at: pageIndex + 1))
            let pageImage = try #require(PDFImageCompare.render(page: cgPage, scale: scale))
            try WhiteboardExporter.pngData(pageImage)?.write(to: outputDirectory.appendingPathComponent("\(baseName)-p\(pageIndex + 1).png"))
            let header = WhiteboardScene.headerHeight
            let pageCrop = CGRect(x: 0, y: header * scale, width: page.boardRect.width * scale, height: page.boardRect.height * scale)
            let referenceCrop = CGRect(x: 0, y: (header + page.boardRect.minY) * scale, width: page.boardRect.width * scale,
                                       height: min(page.boardRect.height * scale, CGFloat(reference.height) - (header + page.boardRect.minY) * scale))
            let size = (width: max(8, Int(pageCrop.width / 4)), height: max(8, Int(referenceCrop.height / 4)))
            let pageLuma = PDFImageCompare.luma(pageImage, crop: CGRect(origin: pageCrop.origin, size: CGSize(width: pageCrop.width, height: referenceCrop.height)), size: size)
            let referenceLuma = PDFImageCompare.luma(reference, crop: referenceCrop, size: size)
            let score = PDFImageCompare.compare(pageLuma, referenceLuma, width: size.width, height: size.height)
            row.worstSSIM = min(row.worstSSIM, score.ssim)
            row.worstMAD = max(row.worstMAD, score.meanAbsoluteDifference)
            let contrast = PDFImageCompare.contrast(PDFImageCompare.luma(pageImage, size: (pageImage.width / 2, pageImage.height / 2)))
            contrasts.append(contrast.inkContrast)
            means.append(contrast.mean)
            for chartRect in WhiteboardExporter.chartRects(in: scene, page: page) where WhiteboardExporter.isBlank(pageImage, rect: chartRect, scale: scale) {
                row.blankCharts += 1
            }
        }
        row.inkContrast = contrasts.min() ?? 0
        row.meanLuma = means.reduce(0, +) / Double(max(1, means.count))
        return row
    }

    // MARK: The matrix

    @Test(arguments: boardNames)
    func exportedPDFPassesEveryCheck(boardName: String) throws {
        var lines: [String] = []
        for theme in WhiteboardTheme.allCases {
            let row = try Self.evaluate(boardName: boardName, theme: theme)
            lines.append(row.line)
            print("PDFCHECK " + row.line)
            #expect(row.missingText.isEmpty, "\(row.name): text not found: \(row.missingText)")
            #expect(row.isVector, "\(row.name) isn't vector (images: \(row.imageCount))")
            #expect(row.fontsEmbedded, "\(row.name): a font isn't embedded")
            #expect(row.elementsOffPage.isEmpty, "\(row.name): elements cross a page edge: \(row.elementsOffPage)")
            #expect(row.blankCharts == 0, "\(row.name): a chart is blank")
            #expect(row.worstSSIM >= Self.minimumSSIM && row.worstMAD <= Self.maximumMeanAbsoluteDifference,
                    "\(row.name): PDF differs from the board render (ssim \(row.worstSSIM), mad \(row.worstMAD))")
            #expect(row.inkContrast >= 0.45, "\(row.name): low contrast \(row.inkContrast)")
            if theme == .paper { #expect(row.meanLuma > 0.6, "\(row.name) should be light") } else { #expect(row.meanLuma < 0.45, "\(row.name) should be dark") }
            if boardName == "math" { #expect(row.imageCount == 0, "\(row.name): formulas should be vectors, not images") }
        }
        let reportURL = Self.outputDirectory.appendingPathComponent("report-\(boardName).txt")
        try (lines.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    }

    // MARK: Paging

    @Test func smallBoardsAreOnePageTheirOwnSize() throws {
        // "long" (8 sections, 1866 × 2155) still fits A4 proportions: one zoomable vector page.
        for boardName in ["dns", "math", "code", "chart", "long"] {
            let scene = try Self.scene(named: boardName)
            let pages = WhiteboardExporter.pdfPages(for: scene)
            #expect(pages.count == 1)
            #expect(pages.first?.pageSize == CGSize(width: scene.layout.bounds.width, height: scene.layout.bounds.height + WhiteboardScene.headerHeight))
        }
    }

    @Test func tallBoardsArePagedBetweenSectionRows() throws {
        let scene = try Self.scene(named: "tall")
        let pages = WhiteboardExporter.pdfPages(for: scene)
        #expect(pages.count >= 2, "the tall board (\(scene.layout.bounds.size)) should be paged")
        // Same size everywhere, A4 proportions, every section on exactly one page, in order, never cut.
        #expect(Set(pages.map(\.pageSize)).count == 1)
        let pageSize = try #require(pages.first?.pageSize)
        #expect(pageSize.width == scene.layout.bounds.width)
        #expect(pageSize.height <= ceil(pageSize.width * WhiteboardExporter.maximumPageAspectRatio) + 1)
        #expect(pages.flatMap(\.sectionIdentifiers).sorted() == scene.layout.sections.map(\.id).sorted())
        for page in pages {
            #expect(page.boardRect.height <= pageSize.height - WhiteboardScene.headerHeight + 0.5)
            for sectionIdentifier in page.sectionIdentifiers {
                let section = try #require(scene.layout.sections.first { $0.id == sectionIdentifier })
                #expect(page.boardRect.contains(section.rect), "section \(sectionIdentifier) is cut by a page break")
            }
        }
        for (first, second) in zip(pages, pages.dropFirst()) { #expect(abs(first.boardRect.maxY - second.boardRect.minY) < 0.5) }
        #expect(abs((pages.last?.boardRect.maxY ?? 0) - scene.layout.bounds.height) < 0.5)

        // Each page's header: the title and "page n of m"; the PDF's Title is the board's.
        let data = try #require(WhiteboardExporter.exportPDFData(scene: scene, theme: .paper))
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == pages.count)
        for pageIndex in 0..<document.pageCount {
            let pageText = document.page(at: pageIndex)?.string ?? ""
            #expect(pageText.contains(scene.board.title))
            #expect(pageText.contains("page \(pageIndex + 1) of \(pages.count)"))
        }
        #expect((document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) == scene.board.title)
        // A page's text is its own sections only (others aren't drawn off-page).
        let firstPageText = document.page(at: 0)?.string ?? ""
        #expect(!firstPageText.contains("The linker joins the pieces"))
    }

    /// A one-page PDF has no step counter ("8 / 8" means nothing on paper).
    @Test func onePageHeaderHasNoStepCounter() throws {
        let scene = try Self.scene(named: "dns")
        let data = try #require(WhiteboardExporter.exportPDFData(scene: scene, theme: .paper))
        let text = try #require(PDFDocument(data: data)?.string)
        #expect(!text.contains("\(scene.board.steps.count) / \(scene.board.steps.count)"))
    }

    /// TeX SwiftMath can't typeset falls back to the source as monospaced text: still in the PDF text.
    @Test func unparseableMathFallsBackToSearchableText() throws {
        WBMathRenderer.install()
        let body = """
        {"wb":1,"title":"Broken math","sections":[{"id":"q1","title":"One"}]}
        {"el":"math","id":"m","sec":"q1","tex":"\\\\notacommand{x}"}
        {"step":1,"show":["m"],"say":"x"}
        """
        let outcome = WBStreamParser.parse(body)
        let scene = WhiteboardScene(board: outcome.board, viewportSize: WhiteboardScene.viewportSize(forPanelSize: Self.panelSize))
        let data = try #require(WhiteboardExporter.exportPDFData(scene: scene, theme: .dark))
        #expect(PDFDocument(data: data)?.string?.contains("notacommand") == true)
    }
}
