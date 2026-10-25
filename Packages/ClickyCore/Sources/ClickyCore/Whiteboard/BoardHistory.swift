//
//  BoardHistory.swift
//  ClickyCore
//
//  What the conversation history remembers of a board: a "BOARD STATE"
//  block appended to the assistant's history entry (title, sections, the
//  step on screen, and the board as JSONL), at most 4 KB, so a follow-up
//  ("go deeper on two", "what was step three?") can refer to it. When the
//  JSONL doesn't fit, whole lines are dropped from the end (steps first)
//  and a "…" line says so.
//

import Foundation

public enum BoardHistory {
    public static let maximumBytes = 4096
    public static let heading = "BOARD STATE"
    static let truncationLine = "… (rest of the board left out)"

    public static func boardStateText(board: WBBoard, currentStepNumber: Int?) -> String {
        let sectionText = board.sections.map { section -> String in
            var text = "\(section.id) (\(section.title)"
            if let question = section.question, !question.isEmpty { text += ": \"\(question)\"" }
            return text + ")"
        }.joined(separator: "; ")
        let stepText = currentStepNumber.map { "\($0) of \(board.steps.count)" } ?? "none of \(board.steps.count)"
        let headerLines = [
            heading,
            "title: \(board.title)",
            "sections: \(sectionText)",
            "current step: \(stepText)",
            "jsonl:"
        ]
        var text = clipped(headerLines.joined(separator: "\n"), toBytes: maximumBytes - 64)
        let jsonlLines = WBJSONLSerializer.serialize(board).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let reservedBytes = truncationLine.utf8.count + 1
        for (lineIndex, line) in jsonlLines.enumerated() {
            let isLastLine = lineIndex == jsonlLines.count - 1
            let budget = maximumBytes - (isLastLine ? 0 : reservedBytes)
            if text.utf8.count + 1 + line.utf8.count > budget {
                text += "\n" + truncationLine
                return text
            }
            text += "\n" + line
        }
        return text
    }

    /// The assistant's history text with the board state after it.
    public static func historyEntry(spokenHistory: String, board: WBBoard, currentStepNumber: Int?) -> String {
        let trimmedHistory = spokenHistory.trimmingCharacters(in: .whitespacesAndNewlines)
        let boardState = boardStateText(board: board, currentStepNumber: currentStepNumber)
        return trimmedHistory.isEmpty ? boardState : trimmedHistory + "\n\n" + boardState
    }

    /// `text` cut (at a Character boundary) to at most `maximumByteCount` UTF-8 bytes.
    static func clipped(_ text: String, toBytes maximumByteCount: Int) -> String {
        guard text.utf8.count > maximumByteCount else { return text }
        var clippedText = ""
        for character in text {
            if clippedText.utf8.count + String(character).utf8.count > maximumByteCount { break }
            clippedText.append(character)
        }
        return clippedText
    }

    /// The JSONL of one section (its elements and the steps that show them),
    /// for "go deeper on <n>".
    public static func sectionJSONL(board: WBBoard, sectionIdentifier: String) -> String? {
        guard let section = board.section(withIdentifier: sectionIdentifier) else { return nil }
        let sectionElements = board.elements(inSection: sectionIdentifier)
        let elementIdentifiers = Set(sectionElements.map(\.id))
        let sectionSteps = board.steps.filter { step in step.shownIdentifiers.contains(where: elementIdentifiers.contains) }
        let sectionBoard = WBBoard(title: board.title, direction: board.direction, sections: [section], elements: sectionElements, steps: sectionSteps)
        return WBJSONLSerializer.serialize(sectionBoard)
    }

    /// The question sections in board order (agenda and recap left out):
    /// "go deeper on two" means the second of these.
    public static func questionSections(of board: WBBoard) -> [WBSection] {
        let contentSections = board.sections.filter { !["agenda", "recap"].contains($0.id.lowercased()) }
        return contentSections.isEmpty ? board.sections : contentSections
    }
}
