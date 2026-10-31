//
//  ActionPageText.swift
//  ClickyCore
//
//  P7 summarize: the article text Claude summarizes, and the "summary"
//  board it is shown on. The app walks the front window's web area (or
//  document) for AXStaticText values; when that yields too little (a canvas
//  app, a PDF, an image) the turn's OCR lines inside the window are used.
//  Both come here to be cleaned (whitespace, duplicates, chrome-sized
//  crumbs) and capped, so the follow-up message stays a sane size.
//

import CoreGraphics
import Foundation

public enum ActionPageText {
    public static let maximumCharacters = 12_000
    /// Less accessibility text than this and the OCR text is used instead (if longer).
    public static let minimumUsefulAccessibilityCharacters = 200

    public enum Source: String, Equatable, Sendable {
        case accessibility
        case ocr
        case none
    }

    /// AXStaticText values in document order → one block of text.
    public static func fromAccessibilityFragments(_ fragments: [String]) -> String {
        var lines: [String] = []
        var seenLines: Set<String> = []
        for fragment in fragments {
            let collapsed = collapseWhitespace(fragment)
            guard collapsed.count >= 2 else { continue }
            // Menus, buttons and nav links repeat; keep the first copy only.
            if collapsed.count < 40 {
                guard !seenLines.contains(collapsed) else { continue }
                seenLines.insert(collapsed)
            }
            if let last = lines.last, last == collapsed { continue }
            lines.append(collapsed)
        }
        return truncated(joinFragments(lines), maximumCharacters: maximumCharacters)
    }

    /// OCR lines → reading order (top to bottom, rows left to right), paragraphs at big gaps.
    public static func fromOCRLines(_ lines: [(text: String, frameCG: CGRect)]) -> String {
        let usable = lines.filter { !collapseWhitespace($0.text).isEmpty && $0.frameCG.height > 0 }
        guard !usable.isEmpty else { return "" }
        let sorted = usable.sorted { first, second in
            if abs(first.frameCG.midY - second.frameCG.midY) > min(first.frameCG.height, second.frameCG.height) / 2 {
                return first.frameCG.midY < second.frameCG.midY
            }
            return first.frameCG.minX < second.frameCG.minX
        }
        var output = ""
        var previousFrame: CGRect?
        for line in sorted {
            let text = collapseWhitespace(line.text)
            if let previousFrame {
                let sameRow = abs(line.frameCG.midY - previousFrame.midY) <= min(line.frameCG.height, previousFrame.height) / 2
                if sameRow {
                    output += " "
                } else {
                    let gap = line.frameCG.minY - previousFrame.maxY
                    output += gap > max(line.frameCG.height, previousFrame.height) * 0.9 ? "\n\n" : "\n"
                }
            }
            output += text
            previousFrame = line.frameCG
        }
        return truncated(output, maximumCharacters: maximumCharacters)
    }

    /// The accessibility text when there's enough of it, else the longer of the two.
    public static func best(accessibilityText: String, ocrText: String) -> (text: String, source: Source) {
        if accessibilityText.count >= minimumUsefulAccessibilityCharacters { return (accessibilityText, .accessibility) }
        if ocrText.count > accessibilityText.count { return (ocrText, .ocr) }
        if !accessibilityText.isEmpty { return (accessibilityText, .accessibility) }
        return ("", .none)
    }

    /// Cuts at the last word boundary before the limit and adds "…".
    public static func truncated(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        let prefix = String(text.prefix(maximumCharacters))
        let cutIndex = prefix.lastIndex(where: \.isWhitespace) ?? prefix.endIndex
        return String(prefix[..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Fragments that end a sentence start a new line; inline pieces (links inside a paragraph) join with a space.
    static func joinFragments(_ fragments: [String]) -> String {
        var output = ""
        for fragment in fragments {
            if output.isEmpty {
                output = fragment
                continue
            }
            let endsSentence = output.last.map { ".!?:;\u{201D}\"".contains($0) } ?? true
            let startsLowercase = fragment.first?.isLowercase ?? false
            output += (endsSentence || !startsLowercase) && fragment.count > 25 ? "\n" : " "
            output += fragment
        }
        return output
    }
}

/// The "summary" whiteboard: a title and up to 12 bullet points.
public enum ActionSummaryBoard {
    public static let maximumBulletLength = 220

    /// "- one\n- two" / "1. one" / a paragraph (split into sentences) → bullets.
    public static func bullets(from summaryText: String) -> [String] {
        let lines = summaryText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var bullets: [String]
        if lines.count > 1 {
            bullets = lines.map(strippedBulletMarker)
        } else {
            let paragraph = strippedBulletMarker(lines.first ?? "")
            bullets = sentences(of: paragraph)
        }
        bullets = bullets.map { $0.count > maximumBulletLength ? String($0.prefix(maximumBulletLength - 1)) + "…" : $0 }.filter { !$0.isEmpty }
        return Array(bullets.prefix(WBList.maximumItemCount))
    }

    public static func board(title: String?, summaryText: String) -> WBBoard {
        let boardTitle = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Summary"
        let section = WBSection(id: "s1", title: boardTitle)
        let list = WBElement(id: "summary", sectionIdentifier: "s1", payload: .list(WBList(title: nil, items: bullets(from: summaryText))))
        return WBBoard(title: boardTitle, sections: [section], elements: [list], steps: [WBStep(number: 1, shownIdentifiers: ["summary"])])
    }

    static func strippedBulletMarker(_ line: String) -> String {
        var text = line
        if let range = text.range(of: #"^\s*([-•*–·]|\d{1,2}[.)])\s+"#, options: .regularExpression) { text.removeSubrange(range) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func sentences(of paragraph: String) -> [String] {
        var sentences: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences.isEmpty ? [paragraph] : sentences
    }
}
