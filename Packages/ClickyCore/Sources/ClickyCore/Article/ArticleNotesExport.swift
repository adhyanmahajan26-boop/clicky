//
//  ArticleNotesExport.swift
//  ClickyCore
//
//  P8 "save my notes": writes ~/Clicky Notes/<title>.md (and a PDF of the
//  same notes through WhiteboardExporter, the board export path), creating
//  the folder. Plus two small pieces the app needs around the notes step:
//  what read_article hands the model, and whether Clicky still has to say
//  the summary out loud (the model usually says it as its spoken line).
//

import Foundation

public struct ArticleNotesSaveResult: Equatable, Sendable {
    public var markdownURL: URL
    public var pdfURL: URL?

    public init(markdownURL: URL, pdfURL: URL?) {
        self.markdownURL = markdownURL
        self.pdfURL = pdfURL
    }

    public var paths: [String] { [markdownURL.path] + (pdfURL.map { [$0.path] } ?? []) }
}

public enum ArticleNotesExport {
    /// Writes the Markdown (and the PDF when `savesPDF`) into `directory`.
    /// `ownedFileNames`: names this session wrote before (they may be replaced).
    @MainActor
    public static func save(_ notes: ArticleNotes, to directory: URL, ownedFileNames: Set<String>, savesPDF: Bool,
                            savedAt: Date = Date()) throws -> ArticleNotesSaveResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
        let baseName = ArticleNotesFileNaming.baseName(forTitle: notes.title)
        let markdownFileName = ArticleNotesFileNaming.fileName(baseName: baseName, fileExtension: "md", existingFileNames: existing, ownedFileNames: ownedFileNames)
        let markdownURL = directory.appendingPathComponent(markdownFileName)
        try ArticleNotesMarkdown.render(notes, savedAt: savedAt).write(to: markdownURL, atomically: true, encoding: .utf8)

        var pdfURL: URL?
        if savesPDF {
            // The PDF shares the Markdown file's name when that's free, so the two stay a pair.
            let pairedBaseName = String(markdownFileName.dropLast(".md".count))
            let pdfFileName = ArticleNotesFileNaming.fileName(baseName: pairedBaseName, fileExtension: "pdf", existingFileNames: existing, ownedFileNames: ownedFileNames)
            let candidateURL = directory.appendingPathComponent(pdfFileName)
            WBMathRenderer.install()
            let board = ArticleNotesBoard.board(for: notes)
            let scene = WhiteboardScene(board: board, viewportSize: WhiteboardScene.viewportSize(forPanelSize: CGSize(width: 900, height: 1100)))
            try WhiteboardExporter.exportPDF(scene: scene, theme: .paper, to: candidateURL)
            pdfURL = candidateURL
        }
        return ArticleNotesSaveResult(markdownURL: markdownURL, pdfURL: pdfURL)
    }
}

public enum ArticleModelText {
    /// The article as the observe turn shows it to the model.
    public static func text(for document: ArticleDocument) -> String {
        var lines: [String] = []
        lines.append("title: \(document.title ?? "(unknown)")")
        if let url = document.url { lines.append("url: \(url)") }
        lines.append("read via: \(document.source == .accessibility ? "the page's accessibility text" : "screenshots (OCR) — quote sentences as they appear here")")
        lines.append("characters: \(document.utf16Length)\(document.isTruncated ? " (cut at the limit; the rest of the article wasn't read)" : "")")
        lines.append("")
        lines.append(document.text)
        return lines.joined(separator: "\n")
    }
}

public enum ArticleSummarySpeech {
    /// The answer's spoken words: the raw answer minus every <actions>…</actions> block (and an unclosed one).
    public static func narrationOutsideActionBlocks(_ rawResponse: String) -> String {
        var remaining = rawResponse
        var output = ""
        while let open = remaining.range(of: "<actions", options: .caseInsensitive) {
            output += remaining[..<open.lowerBound]
            guard let close = remaining.range(of: "</actions>", options: .caseInsensitive, range: open.upperBound..<remaining.endIndex) else {
                remaining = ""
                break
            }
            remaining = String(remaining[close.upperBound...])
        }
        return output + remaining
    }

    /// Clicky says the summary itself unless the answer already said most of it (≥ 60 % of its words).
    public static func needsSpeaking(summary: String, rawResponse: String) -> Bool {
        let summaryWords = words(summary)
        guard !summaryWords.isEmpty else { return false }
        let spokenWords = Set(words(narrationOutsideActionBlocks(rawResponse)))
        let sharedCount = summaryWords.filter(spokenWords.contains).count
        return Double(sharedCount) / Double(summaryWords.count) < 0.6
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
    }
}
