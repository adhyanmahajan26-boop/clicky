//
//  ProgressiveBoard.swift
//  ClickyCore
//
//  P6.7 progressive boards: for a multi-part question the main model draws
//  the board's frame (agenda, its own sections, recap) and hands whole
//  question sections to helper workers ([WORKER:s2 title:task] lines before
//  the <whiteboard> block). Each helper section starts as one placeholder
//  ({"el":"text","id":"s2_wait","sec":"s2","text":"working on it…"}) shown
//  by one silent step; the helper (Haiku) answers with CWB JSONL for that
//  section only.
//   - WBWorkerSectionFilter keeps only that section's lines: ids must start
//     with "s2_", no header, no other section, arrows stay inside; the rest
//     goes through the usual repair + normalizer.
//   - ProgressiveBoard.replacePlaceholder swaps the placeholder for the
//     helper's elements and its step(s) for the helper's steps, in plan
//     position (or drops it when the helper never came), and says how the
//     step indexes moved so the narrator can follow.
//  The narrator (BoardNarration.swift) decides when a section is spoken.
//

import Foundation

public enum ProgressiveBoard {
    public static let placeholderSuffix = "_wait"
    public static let placeholderText = "working on it…"
    /// Said once when the narration reaches a helper section that isn't there yet.
    public static let bridgeLine = "that part's still coming, i'll come back to it."

    /// Said when helper sections never arrived before the recap.
    public static func droppedLine(sectionCount: Int) -> String {
        sectionCount > 1
            ? "those parts didn't make it in time, so i'll skip them for now."
            : "that part didn't make it in time, so i'll skip it for now."
    }

    public static func placeholderIdentifier(forSection sectionIdentifier: String) -> String {
        sectionIdentifier + placeholderSuffix
    }

    /// The prefix every element id of a helper section starts with ("s2_").
    public static func identifierPrefix(forSection sectionIdentifier: String) -> String {
        sectionIdentifier + "_"
    }

    /// Sections still showing their placeholder, in section order.
    public static func pendingSectionIdentifiers(in board: WBBoard) -> [String] {
        let elementIdentifiers = Set(board.elements.map(\.id))
        return board.sections.map(\.id).filter { elementIdentifiers.contains(placeholderIdentifier(forSection: $0)) }
    }

    private static let workerTitlePattern = try! NSRegularExpression(pattern: #"^\s*(s\d{1,2})(?:\b|_)[\s:_-]*(.*)$"#, options: [.caseInsensitive])

    /// "s2 The handshake" → ("s2", "The handshake"); nil for an ordinary helper.
    public static func workerSection(fromWorkerTitle workerTitle: String) -> (sectionIdentifier: String, title: String)? {
        let range = NSRange(workerTitle.startIndex..., in: workerTitle)
        guard let match = workerTitlePattern.firstMatch(in: workerTitle, range: range),
              let identifierRange = Range(match.range(at: 1), in: workerTitle) else { return nil }
        let sectionIdentifier = workerTitle[identifierRange].lowercased()
        let title = Range(match.range(at: 2), in: workerTitle).map { workerTitle[$0].trimmingCharacters(in: .whitespaces) } ?? ""
        return (sectionIdentifier, title.isEmpty ? sectionIdentifier : title)
    }

    // MARK: - Merge

    /// A board after a section changed, and where its steps went.
    public struct SectionChange: Equatable, Sendable {
        public var board: WBBoard
        /// Old step index → new step index; removed steps are missing.
        public var stepIndexMapping: [Int: Int]
        /// New indexes of the helper's steps, ascending (empty for a drop).
        public var insertedStepIndexes: [Int]
    }

    /// Replaces section `sectionIdentifier`'s placeholder with the helper's
    /// elements and its placeholder step(s) with the helper's steps (at the
    /// placeholder step's place, else before the first step of a later
    /// section). With no helper board the placeholder is dropped (and the
    /// section too, when nothing else is in it). Nil when the section has
    /// no placeholder (already merged or dropped, or unknown).
    public static func replacePlaceholder(ofSection sectionIdentifier: String, in board: WBBoard, with workerBoard: WBBoard?) -> SectionChange? {
        let placeholderIdentifier = placeholderIdentifier(forSection: sectionIdentifier)
        guard let placeholderElementIndex = board.elements.firstIndex(where: { $0.id == placeholderIdentifier }) else { return nil }
        let prefix = identifierPrefix(forSection: sectionIdentifier)

        // Elements: the helper's take the placeholder's place.
        let existingIdentifiers = Set(board.elements.map(\.id))
        let incomingElements = (workerBoard?.elements ?? []).filter {
            $0.id.hasPrefix(prefix) && $0.id != placeholderIdentifier && !existingIdentifiers.contains($0.id)
        }.map { WBElement(id: $0.id, sectionIdentifier: sectionIdentifier, payload: $0.payload) }
        var elements = board.elements
        elements.replaceSubrange(placeholderElementIndex...placeholderElementIndex, with: incomingElements)
        elements = elements.compactMap { element -> WBElement? in
            var element = element
            switch element.payload {
            case .arrow(let arrow) where arrow.fromIdentifier == placeholderIdentifier || arrow.toIdentifier == placeholderIdentifier:
                return nil
            case .text(var text) where text.nearIdentifier == placeholderIdentifier:
                text.nearIdentifier = nil
                text.position = nil
                element.payload = .text(text)
            case .callout(var callout) where callout.targetIdentifier == placeholderIdentifier:
                callout.targetIdentifier = nil
                element.payload = .callout(callout)
            default:
                break
            }
            return element
        }

        // Sections: a helper's title fills a nameless section; an emptied one goes.
        var sections = board.sections
        if let sectionIndex = sections.firstIndex(where: { $0.id == sectionIdentifier }) {
            if let workerTitle = workerBoard?.sections.first(where: { $0.id == sectionIdentifier })?.title,
               !workerTitle.isEmpty, sections[sectionIndex].title.isEmpty || sections[sectionIndex].title == sectionIdentifier {
                sections[sectionIndex].title = workerTitle
            }
            if !elements.contains(where: { $0.sectionIdentifier == sectionIdentifier }) { sections.remove(at: sectionIndex) }
        }

        // Steps: the helper's go where the placeholder step was.
        let insertionIndex = board.steps.firstIndex { stepMentions($0, identifier: placeholderIdentifier) }
            ?? firstStepIndex(after: sectionIdentifier, in: board)
            ?? board.steps.count
        let incomingSteps = (workerBoard?.steps ?? []).map { removingReferences(in: $0, keeping: { $0.hasPrefix(prefix) }) }
            .filter { !$0.shownIdentifiers.isEmpty || !$0.say.isEmpty }
        var steps: [WBStep] = []
        var stepIndexMapping: [Int: Int] = [:]
        var insertedStepIndexes: [Int] = []
        func insertIncomingSteps() {
            for step in incomingSteps {
                insertedStepIndexes.append(steps.count)
                steps.append(step)
            }
        }
        for (oldIndex, step) in board.steps.enumerated() {
            if oldIndex == insertionIndex { insertIncomingSteps() }
            let mentionsPlaceholder = stepMentions(step, identifier: placeholderIdentifier)
            let cleanedStep = removingReferences(in: step, keeping: { $0 != placeholderIdentifier })
            if mentionsPlaceholder, cleanedStep.shownIdentifiers.isEmpty, cleanedStep.highlightedIdentifiers.isEmpty { continue }
            stepIndexMapping[oldIndex] = steps.count
            steps.append(cleanedStep)
        }
        if insertionIndex >= board.steps.count { insertIncomingSteps() }
        for stepIndex in steps.indices { steps[stepIndex].number = stepIndex + 1 }

        var mergedBoard = board
        mergedBoard.elements = elements
        mergedBoard.sections = sections
        mergedBoard.steps = steps
        for sectionIndex in mergedBoard.sections.indices {
            mergedBoard.sections[sectionIndex].page = sectionIndex / WBNormalizer.sectionsPerPage + 1
        }
        return SectionChange(board: mergedBoard, stepIndexMapping: stepIndexMapping, insertedStepIndexes: insertedStepIndexes)
    }

    static func stepMentions(_ step: WBStep, identifier: String) -> Bool {
        if step.shownIdentifiers.contains(identifier) || step.highlightedIdentifiers.contains(identifier) { return true }
        if step.cues.contains(where: { $0.elementIdentifier == identifier }) || step.pointIdentifier == identifier { return true }
        if case .element(let focusIdentifier)? = step.focus, focusIdentifier == identifier { return true }
        return false
    }

    /// The step with only the ids `keeping` accepts (focus on a dropped element goes).
    static func removingReferences(in step: WBStep, keeping isKept: (String) -> Bool) -> WBStep {
        var cleanedStep = step
        cleanedStep.shownIdentifiers = step.shownIdentifiers.filter(isKept)
        cleanedStep.highlightedIdentifiers = step.highlightedIdentifiers.filter(isKept)
        cleanedStep.cues = step.cues.filter { isKept($0.elementIdentifier) }
        if let pointIdentifier = step.pointIdentifier, !isKept(pointIdentifier) { cleanedStep.pointIdentifier = nil }
        if case .element(let focusIdentifier)? = step.focus, !isKept(focusIdentifier) { cleanedStep.focus = nil }
        return cleanedStep
    }

    /// The section a step is about: its focus, else its first shown element's.
    static func sectionIdentifier(of step: WBStep, in board: WBBoard) -> String? {
        switch step.focus {
        case .section(let sectionIdentifier)?: return sectionIdentifier
        case .element(let elementIdentifier)?:
            if let element = board.element(withIdentifier: elementIdentifier) { return element.sectionIdentifier }
        default: break
        }
        return step.shownIdentifiers.lazy.compactMap { board.element(withIdentifier: $0)?.sectionIdentifier }.first
    }

    /// The first step about a section that comes after `sectionIdentifier`.
    static func firstStepIndex(after earlierSectionIdentifier: String, in board: WBBoard) -> Int? {
        guard let sectionPosition = board.sections.firstIndex(where: { $0.id == earlierSectionIdentifier }) else { return nil }
        let laterSections = Set(board.sections[(sectionPosition + 1)...].map(\.id))
        return board.steps.firstIndex { step in Self.sectionIdentifier(of: step, in: board).map(laterSections.contains) ?? false }
    }
}

// MARK: - Worker filter

/// One helper's section, validated.
public struct WBWorkerSectionOutcome: Equatable, Sendable {
    public var sectionIdentifier: String
    /// Just this section: its elements (ids "s<k>_…") and steps.
    public var board: WBBoard
    public var acceptedLineCount: Int
    /// One line per rejected or dropped line, for the log.
    public var rejectedReasons: [String]

    public var isUsable: Bool { !board.elements.isEmpty }
}

public enum WBWorkerSectionFilter {
    public static let maximumElementCount = 20
    public static let maximumStepCount = 6

    /// Keeps only `sectionIdentifier`'s lines from a helper's reply: element
    /// ids must start with "s<k>_" (and aren't the placeholder), "sec" (if
    /// given) must be this section, arrows must stay inside it; header lines
    /// and anything else are rejected. Steps keep only this section's ids.
    /// The survivors go through WBRepair + WBNormalizer as usual.
    public static func filter(workerText: String, sectionIdentifier: String, sectionTitle: String? = nil,
                              isValidSymbol: @escaping @Sendable (String) -> Bool = WBNormalizer.defaultSymbolCheck) -> WBWorkerSectionOutcome {
        let prefix = ProgressiveBoard.identifierPrefix(forSection: sectionIdentifier)
        let placeholderIdentifier = ProgressiveBoard.placeholderIdentifier(forSection: sectionIdentifier)
        var rejectedReasons: [String] = []

        var scanner = WBScanner()
        let scannedValues = scanner.feed(WBBlockExtractor.whiteboardBody(in: workerText)) + scanner.finish()
        var values: [WBJSONValue] = []
        for scannedValue in scannedValues {
            let repairResult = WBRepair.repair(scannedValue.text)
            if repairResult.rung == .failed { rejectedReasons.append("unparseable line") }
            values += repairResult.values
        }
        values = values.flatMap { value -> [WBJSONValue] in
            if case .array(let items) = value { return items }
            return [value]
        }

        func isInside(_ reference: String) -> Bool { reference.hasPrefix(prefix) && reference != placeholderIdentifier }

        var acceptedValues: [WBJSONValue] = []
        var elementCount = 0
        var stepCount = 0
        for value in values {
            guard case .object(var members) = value else {
                rejectedReasons.append("not an object")
                continue
            }
            let isElement = members["el"] != nil || (members["type"] != nil && members["step"] == nil)
            let isStep = !isElement && (members["step"] != nil || members["show"] != nil || members["say"] != nil)
            if isElement {
                let rawIdentifier = WBNormalizer.string(members["id"]) ?? ""
                guard let elementIdentifier = WBNormalizer.sanitizedIdentifier(rawIdentifier), isInside(elementIdentifier) else {
                    rejectedReasons.append("id outside \(sectionIdentifier): \(rawIdentifier.isEmpty ? "(none)" : rawIdentifier)")
                    continue
                }
                if let rawSection = WBNormalizer.string(members["sec"] ?? members["section"]),
                   WBNormalizer.sanitizedIdentifier(rawSection) != sectionIdentifier {
                    rejectedReasons.append("other section \(rawSection): \(elementIdentifier)")
                    continue
                }
                let rawKind = (WBNormalizer.string(members["el"]) ?? WBNormalizer.string(members["type"]) ?? "").lowercased()
                if WBNormalizer.canonicalKind(rawKind) == .arrow {
                    let endpoints = [members["from"], members["to"]].map { WBNormalizer.string($0) ?? "" }
                    guard endpoints.allSatisfy(isInside) else {
                        rejectedReasons.append("arrow leaves \(sectionIdentifier): \(elementIdentifier)")
                        continue
                    }
                }
                guard elementCount < maximumElementCount else {
                    rejectedReasons.append("element over limit: \(elementIdentifier)")
                    continue
                }
                members["sec"] = .string(sectionIdentifier)
                members["section"] = nil
                elementCount += 1
                acceptedValues.append(.object(members))
            } else if isStep {
                for key in ["show", "shows", "reveal", "hl", "highlight"] {
                    if let list = members[key] {
                        members[key] = .array(WBNormalizer.stringList(list).filter(isInside).map(WBJSONValue.string))
                    }
                }
                for key in ["cue", "cues"] {
                    if case .object(let cueMembers)? = members[key] { members[key] = .object(cueMembers.filter { isInside($0.key) }) }
                }
                if let pointReference = WBNormalizer.string(members["point"]), !isInside(pointReference) { members["point"] = nil }
                if let focusReference = WBNormalizer.string(members["focus"]), !isInside(focusReference), focusReference != sectionIdentifier {
                    members["focus"] = nil
                }
                let shownCount = WBNormalizer.stringList(members["show"] ?? members["shows"] ?? members["reveal"]).count
                let saysSomething = !(WBNormalizer.string(members["say"] ?? members["narration"]) ?? "").isEmpty
                guard shownCount > 0 || saysSomething else {
                    rejectedReasons.append("step without \(sectionIdentifier) elements")
                    continue
                }
                guard stepCount < maximumStepCount else {
                    rejectedReasons.append("step over limit")
                    continue
                }
                stepCount += 1
                acceptedValues.append(.object(members))
            } else if members["wb"] != nil || members["sections"] != nil || members["dir"] != nil || members["title"] != nil {
                rejectedReasons.append("header line")
            } else {
                rejectedReasons.append("unknown line")
            }
        }

        let title = sectionTitle ?? sectionIdentifier
        var normalizer = WBNormalizer(isValidSymbol: isValidSymbol)
        normalizer.ingest(.object(["wb": .number(1), "title": .string(title),
                                   "sections": .array([.object(["id": .string(sectionIdentifier), "title": .string(title)])])]))
        for acceptedValue in acceptedValues { normalizer.ingest(acceptedValue) }
        let outcome = normalizer.finish()
        rejectedReasons += outcome.stats.droppedReasons

        var sectionBoard = outcome.board
        sectionBoard.sections = sectionBoard.sections.filter { $0.id == sectionIdentifier }
        sectionBoard.elements = sectionBoard.elements.filter { $0.sectionIdentifier == sectionIdentifier && isInside($0.id) }
        return WBWorkerSectionOutcome(sectionIdentifier: sectionIdentifier, board: sectionBoard,
                                      acceptedLineCount: acceptedValues.count, rejectedReasons: rejectedReasons)
    }
}
