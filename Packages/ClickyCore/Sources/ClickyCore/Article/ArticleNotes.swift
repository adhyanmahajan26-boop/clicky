//
//  ArticleNotes.swift
//  ClickyCore
//
//  P8 notes: what the notes panel shows and what "save my notes" writes.
//   - ArticleNotes: title, URL, the 1–2 sentence summary, numbered notes
//     each with the sentence it quotes (and so the highlight it links to).
//   - ArticleNotesMarkdown: the Markdown file (~/Clicky Notes/<title>.md).
//   - ArticleNotesFileNaming: a safe file name from the title, and a free
//     one when a file of that name already exists (never overwrites notes
//     Clicky didn't write in this session).
//   - ArticleNotesBoard: the same notes as a whiteboard board, so the PDF
//     goes through the existing WhiteboardExporter path.
//   - ArticleNotesDock: where the panel goes beside the article window.
//   - NotesVoiceCommand / NotesTag: "save my notes" and [NOTES:save].
//

import CoreGraphics
import Foundation

public struct ArticleNoteItem: Equatable, Sendable, Codable {
    /// The note itself (≤ 15 words).
    public var note: String
    /// The sentence it quotes, verbatim from the article (its highlight).
    public var quote: String

    public init(note: String, quote: String) {
        self.note = note
        self.quote = quote
    }
}

public struct ArticleNotes: Equatable, Sendable, Codable {
    public var title: String
    public var url: String?
    public var summary: String
    public var items: [ArticleNoteItem]

    public init(title: String, url: String? = nil, summary: String, items: [ArticleNoteItem]) {
        self.title = title
        self.url = url
        self.summary = summary
        self.items = items
    }

    public static let maximumItemCount = 10
    public static let maximumNoteWords = 15
    public static let maximumQuoteLength = 400
    public static let maximumSummaryLength = 400

    /// A note cut to 15 words ("…" when cut).
    public static func clippedNote(_ note: String) -> String {
        let words = note.split(whereSeparator: \.isWhitespace)
        guard words.count > maximumNoteWords else { return words.joined(separator: " ") }
        return words.prefix(maximumNoteWords).joined(separator: " ") + "…"
    }
}

// MARK: - Markdown

public enum ArticleNotesMarkdown {
    public static func render(_ notes: ArticleNotes, savedAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        lines.append("# \(singleLine(notes.title))")
        lines.append("")
        if let url = notes.url, !url.isEmpty { lines.append("Source: <\(url)>") }
        lines.append("Saved: \(formatter.string(from: savedAt))")
        lines.append("")
        lines.append("## Summary")
        lines.append("")
        lines.append(singleLine(notes.summary))
        lines.append("")
        lines.append("## Notes")
        lines.append("")
        for (index, item) in notes.items.enumerated() {
            lines.append("\(index + 1). \(escapedListText(singleLine(item.note)))")
            if !item.quote.isEmpty { lines.append("   > \(singleLine(item.quote))") }
        }
        if notes.items.isEmpty { lines.append("_No notes._") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A note that itself starts like a list item ("1. …", "- …") would nest; escape its marker.
    static func escapedListText(_ text: String) -> String {
        if let range = text.range(of: #"^(\d+)\."#, options: .regularExpression) {
            return text.replacingCharacters(in: range, with: String(text[range].dropLast()) + "\\.")
        }
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") { return "\\" + text }
        return text
    }
}

// MARK: - Files

public enum ArticleNotesFileNaming {
    public static let folderName = "Clicky Notes"
    public static let fallbackBaseName = "Article notes"
    public static let maximumBaseNameLength = 80

    /// ~/Clicky Notes (in the home folder, not Documents/Desktop: no protected-folder prompt).
    public static func defaultDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The title as a file name: no path separators, colons or control characters, ≤ 80 characters.
    public static func baseName(forTitle title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let replaced = title.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        var collapsed = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // No hidden files and no trailing dots.
        collapsed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if collapsed.count > maximumBaseNameLength {
            let prefix = String(collapsed.prefix(maximumBaseNameLength))
            collapsed = (prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        return collapsed.isEmpty ? fallbackBaseName : collapsed
    }

    /// "<base>.md", or "<base> 2.md", "<base> 3.md"… when the name is taken by a
    /// file Clicky didn't write in this session (`ownedFileNames` may be overwritten).
    public static func fileName(baseName: String, fileExtension: String, existingFileNames: Set<String>, ownedFileNames: Set<String>) -> String {
        let first = "\(baseName).\(fileExtension)"
        if !existingFileNames.contains(first) || ownedFileNames.contains(first) { return first }
        var number = 2
        while true {
            let candidate = "\(baseName) \(number).\(fileExtension)"
            if !existingFileNames.contains(candidate) || ownedFileNames.contains(candidate) { return candidate }
            number += 1
        }
    }

    /// What Clicky says after saving ("saved your notes to clicky notes, as …").
    public static func savedLine(markdownFileName: String, savedPDF: Bool) -> String {
        "saved your notes in the clicky notes folder in your home folder, as \(markdownFileName.replacingOccurrences(of: ".md", with: ""))" + (savedPDF ? ", markdown and pdf." : ", as markdown.")
    }

    public static let nothingToSaveLine = "there are no notes to save yet. ask me to make notes on an article first."
    public static let failedLine = "i couldn't save your notes."
}

// MARK: - PDF (through the whiteboard exporter)

public enum ArticleNotesBoard {
    /// One section: the summary, then the numbered notes, each with its quote.
    public static func board(for notes: ArticleNotes) -> WBBoard {
        let title = notes.title.isEmpty ? "Notes" : notes.title
        let section = WBSection(id: "notes", title: "Notes")
        var elements: [WBElement] = []
        var shown: [String] = []
        if let url = notes.url, !url.isEmpty {
            elements.append(WBElement(id: "source", sectionIdentifier: "notes", payload: .text(WBText(text: url, size: .small))))
            shown.append("source")
        }
        if !notes.summary.isEmpty {
            elements.append(WBElement(id: "summary", sectionIdentifier: "notes", payload: .callout(WBCallout(style: .info, text: notes.summary))))
            shown.append("summary")
        }
        let items = notes.items.prefix(WBList.maximumItemCount).map { item in
            item.quote.isEmpty ? item.note : "\(item.note) — \u{201C}\(item.quote)\u{201D}"
        }
        if !items.isEmpty {
            elements.append(WBElement(id: "items", sectionIdentifier: "notes", payload: .list(WBList(title: nil, items: Array(items), isOrdered: true))))
            shown.append("items")
        }
        return WBBoard(title: title, sections: [section], elements: elements, steps: [WBStep(number: 1, shownIdentifiers: shown)])
    }
}

// MARK: - Docking

public enum ArticleNotesDockSide: String, Equatable, Sendable {
    /// Outside the article window, in the free space to its left / right.
    case left
    case right
    /// Over the window's own margin beside the article column (no free space outside).
    case insideLeft
    case insideRight
}

public struct ArticleNotesDockPlacement: Equatable, Sendable {
    public var side: ArticleNotesDockSide
    /// CG global points (top-left origin).
    public var frameCG: CGRect
    /// Nothing better fit: the panel overlaps the article column.
    public var coversArticleColumn: Bool

    public init(side: ArticleNotesDockSide, frameCG: CGRect, coversArticleColumn: Bool) {
        self.side = side
        self.frameCG = frameCG
        self.coversArticleColumn = coversArticleColumn
    }
}

public enum ArticleNotesDock {
    public static let preferredWidth: CGFloat = 340
    public static let minimumWidth: CGFloat = 250
    public static let gap: CGFloat = 8

    /// Beside the window on the side with the most free space on its display;
    /// else inside the window's margin beside the article column; never over
    /// the column unless nothing else fits. Height = the window's (clamped to
    /// the display), at most `maximumHeight`.
    public static func placement(windowFrameCG: CGRect, articleColumnCG: CGRect?, visibleFrameCG: CGRect,
                                 preferredWidth: CGFloat = preferredWidth, minimumWidth: CGFloat = minimumWidth,
                                 maximumHeight: CGFloat = 720) -> ArticleNotesDockPlacement {
        let window = windowFrameCG.intersection(visibleFrameCG).isNull ? windowFrameCG : windowFrameCG.intersection(visibleFrameCG)
        let leftFree = max(0, window.minX - visibleFrameCG.minX)
        let rightFree = max(0, visibleFrameCG.maxX - window.maxX)
        let height = min(maximumHeight, max(200, min(window.height, visibleFrameCG.height - 2 * gap)))
        let y = min(max(window.minY, visibleFrameCG.minY + gap), visibleFrameCG.maxY - height - gap)

        // Outside the window.
        let bestOutside = rightFree >= leftFree ? (ArticleNotesDockSide.right, rightFree) : (.left, leftFree)
        if bestOutside.1 >= minimumWidth + 2 * gap {
            let width = min(preferredWidth, bestOutside.1 - 2 * gap)
            let x = bestOutside.0 == .right ? window.maxX + gap : window.minX - gap - width
            return ArticleNotesDockPlacement(side: bestOutside.0, frameCG: CGRect(x: x, y: y, width: width, height: height), coversArticleColumn: false)
        }

        // Inside the window, beside the article column.
        let column = (articleColumnCG?.intersection(window)).flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
            ?? CGRect(x: window.midX - window.width * 0.3, y: window.minY, width: window.width * 0.6, height: window.height)
        let leftMargin = max(0, column.minX - window.minX) + leftFree
        let rightMargin = max(0, window.maxX - column.maxX) + rightFree
        let bestInside = rightMargin >= leftMargin ? (ArticleNotesDockSide.insideRight, rightMargin) : (.insideLeft, leftMargin)
        if bestInside.1 >= minimumWidth + 2 * gap {
            let width = min(preferredWidth, bestInside.1 - 2 * gap)
            // Hug the window's own edge when that clears the column, else the display edge (which always does).
            let x: CGFloat
            if bestInside.0 == .insideRight {
                let againstWindowEdge = window.maxX - gap - width
                x = againstWindowEdge >= column.maxX + gap ? againstWindowEdge : visibleFrameCG.maxX - gap - width
            } else {
                let againstWindowEdge = window.minX + gap
                x = againstWindowEdge + width <= column.minX - gap ? againstWindowEdge : visibleFrameCG.minX + gap
            }
            return ArticleNotesDockPlacement(side: bestInside.0, frameCG: CGRect(x: x, y: y, width: width, height: height), coversArticleColumn: false)
        }

        // Nothing fits: the minimum width at the display edge with more room.
        let side: ArticleNotesDockSide = rightMargin >= leftMargin ? .insideRight : .insideLeft
        let x = side == .insideRight ? visibleFrameCG.maxX - gap - minimumWidth : visibleFrameCG.minX + gap
        return ArticleNotesDockPlacement(side: side, frameCG: CGRect(x: x, y: y, width: minimumWidth, height: height), coversArticleColumn: true)
    }
}

// MARK: - Voice command and tag

/// "save my notes", "save the notes", "save these notes" (local, no brain turn).
public enum NotesVoiceCommand: Equatable, Sendable {
    case save

    static let savePhrases: Set<String> = [
        "save my notes", "save the notes", "save notes", "save these notes", "save those notes", "save my note", "save the note",
        "save my notes please", "export my notes", "export the notes", "save notes as markdown", "save my notes as markdown",
        "save my notes as a pdf", "save the notes as a pdf", "save notes to a file", "save my notes to a file", "keep my notes",
        "download my notes"
    ]

    public static func parse(_ utterance: String) -> NotesVoiceCommand? {
        let words = BoardVoiceCommand.normalize(utterance).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 8 else { return nil }
        let joined = words.joined(separator: " ")
        if savePhrases.contains(joined) { return .save }
        // "p d f" as dictated.
        if savePhrases.contains(joined.replacingOccurrences(of: "p d f", with: "pdf")) { return .save }
        return nil
    }
}

/// [NOTES:save]: the model asks the app to save the open notes (never spoken).
public enum NotesTag {
    public static let saveTag = "[NOTES:save]"

    public enum Command: String, Equatable, Sendable {
        case save
        case close
    }

    public static func parse(_ rawTag: String) -> Command? {
        var body = rawTag.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("["), body.hasSuffix("]") else { return nil }
        body = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard body.uppercased().hasPrefix("NOTES:") else { return nil }
        switch body.dropFirst("NOTES:".count).trimmingCharacters(in: .whitespaces).lowercased() {
        case "save", "export": return .save
        case "close", "hide": return .close
        default: return nil
        }
    }
}

/// P9 "Claude-style" live writing: the notes appear character by character with a caret, like a
/// streamed answer. Segments in reading order: the summary, then each note and its quote.
public struct NotesStreamReveal: Equatable, Sendable {
    public static let charactersPerSecond: Double = 50
    /// The newest characters are drawn lighter (a soft fade-in as they arrive).
    public static let fadingTailCharacters = 6

    public let segments: [String]
    public init(notes: ArticleNotes) {
        segments = [notes.summary] + notes.items.flatMap { [$0.note, $0.quote] }
    }

    public var totalCharacters: Int { segments.reduce(0) { $0 + $1.count } }

    public struct Visible: Equatable, Sendable {
        /// Fully revealed part, then the fading tail (both prefixes of the segment).
        public var settled: String
        public var tail: String
        public var hasCaret: Bool
    }

    /// The segment the caret is in (where the next character goes); nil once everything is shown.
    public func caretSegment(revealed: Int) -> Int? {
        guard revealed < totalCharacters else { return nil }
        var cumulative = 0
        for (index, segment) in segments.enumerated() where !segment.isEmpty {
            if revealed < cumulative + segment.count { return index }
            cumulative += segment.count
        }
        return nil
    }

    /// What segment `index` shows after `revealed` characters overall.
    public func visible(segment index: Int, revealed: Int) -> Visible {
        guard segments.indices.contains(index) else { return Visible(settled: "", tail: "", hasCaret: false) }
        let segment = segments[index]
        guard revealed < totalCharacters else { return Visible(settled: segment, tail: "", hasCaret: false) }
        let before = segments[..<index].reduce(0) { $0 + $1.count }
        let shown = max(0, min(segment.count, revealed - before))
        let prefix = String(segment.prefix(shown))
        let tailCount = min(Self.fadingTailCharacters, prefix.count)
        return Visible(settled: String(prefix.dropLast(tailCount)), tail: String(prefix.suffix(tailCount)),
                       hasCaret: caretSegment(revealed: revealed) == index)
    }
}
