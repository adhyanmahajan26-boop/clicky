//
//  WBNormalizer.swift
//  ClickyCore
//
//  Turns repaired JSON values into a WBBoard, forgiving the ways a model
//  bends the CWB v1 contract: synonym element kinds and field names, numbers
//  where strings belong, off-palette colours, missing or duplicate ids,
//  missing or unknown sections, wrapper objects and bare arrays, steps that
//  arrive before their elements. Cross-references (arrow endpoints, step
//  ids, "near", callout targets) are only resolved at stream end, when every
//  element has arrived. Limits are enforced and everything dropped is
//  counted, so callers can tell a slightly bent board from a broken one.
//
//  Pure and deterministic: output order is arrival order, never Dictionary
//  or Set order (dictionary-shaped input such as "cue" is sorted).
//

import Foundation

public struct WBParseStats: Codable, Equatable, Sendable {
    public var elementCount = 0
    public var stepCount = 0
    /// Top-level items seen: header, element and step objects, plus values
    /// no repair rung could parse.
    public var itemCount = 0
    /// Items dropped (unparseable, unknown, over a limit, dangling arrows).
    public var droppedCount = 0
    /// Ids in steps, "near" and callout targets that matched nothing.
    public var droppedReferenceCount = 0
    /// One line per drop, in order.
    public var droppedReasons: [String] = []
    /// Indexed like WBRepairRung.allCases.
    public var rungCounts: [Int] = Array(repeating: 0, count: WBRepairRung.allCases.count)

    public init() {}

    public func count(for rung: WBRepairRung) -> Int {
        rungCounts[WBRepairRung.allCases.firstIndex(of: rung)!]
    }

    mutating func addRung(_ rung: WBRepairRung) {
        rungCounts[WBRepairRung.allCases.firstIndex(of: rung)!] += 1
    }

    /// No elements, or more than 30% of the items dropped.
    public var isTooBroken: Bool {
        if elementCount == 0 { return true }
        guard itemCount > 0 else { return false }
        return Double(droppedCount) / Double(itemCount) > 0.3
    }
}

public struct WBParseOutcome: Equatable, Sendable {
    public var board: WBBoard
    public var stats: WBParseStats

    /// At least one element and not too broken.
    public var isUsable: Bool { stats.elementCount > 0 && !stats.isTooBroken }
}

public struct WBNormalizer: Sendable {
    public static let maximumElementCount = 60
    public static let maximumStepCount = 20
    public static let sectionsPerPage = 8
    public static let maximumSectionCount = 24
    public static let maximumIdentifierLength = 32
    public static let defaultSectionIdentifier = "main"

    /// Default SF Symbol check: a non-empty run of [a-z0-9.].
    public static let defaultSymbolCheck: @Sendable (String) -> Bool = { symbolName in
        !symbolName.isEmpty && symbolName.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." }
    }

    private let isValidSymbol: @Sendable (String) -> Bool

    private var boardTitle: String?
    private var boardDirection: WBDirection?
    private var sections: [WBSection] = []
    /// Sections made from an element's unknown "sec"; a later header may name them.
    private var sectionIdentifiersCreatedFromElements: [String] = []
    private var currentSectionIdentifier: String?
    private var elements: [WBElement] = []
    private var usedElementIdentifiers: Set<String> = []
    private var nextAutomaticIdentifierNumber = 1
    private var pendingSteps: [PendingStep] = []
    private var stats = WBParseStats()

    private struct PendingStep: Sendable {
        var shownReferences: [String] = []
        var highlightedReferences: [String] = []
        var say = ""
        var cueReferences: [(reference: String, word: String)] = []
        var pointReference: String?
        var focusReference: String?
    }

    public init(isValidSymbol: @escaping @Sendable (String) -> Bool = WBNormalizer.defaultSymbolCheck) {
        self.isValidSymbol = isValidSymbol
    }

    // MARK: - Ingest

    /// One value from WBRepair (its rung is recorded).
    public mutating func ingest(_ repairResult: WBRepairResult, wasClosedByScanner: Bool = false) {
        var rung = repairResult.rung
        if wasClosedByScanner, rung != .failed,
           WBRepairRung.allCases.firstIndex(of: rung)! < WBRepairRung.allCases.firstIndex(of: .balanced)! {
            rung = .balanced
        }
        stats.addRung(rung)
        if rung == .failed {
            stats.itemCount += 1
            recordDrop("unparseable value")
            return
        }
        for value in repairResult.values { ingest(value) }
    }

    public mutating func ingest(_ value: WBJSONValue) {
        switch value {
        case .array(let items):
            for item in items { ingest(item) }
        case .object(let members):
            ingestObject(members)
        default:
            stats.itemCount += 1
            recordDrop("bare value")
        }
    }

    private mutating func ingestObject(_ members: [String: WBJSONValue]) {
        for wrapperKey in ["board", "whiteboard", "wb"] {
            if members.count == 1, case .object(let innerMembers)? = members[wrapperKey] {
                ingestObject(innerMembers)
                return
            }
        }
        if members["el"] != nil || (members["type"] != nil && members["step"] == nil && members["elements"] == nil) {
            stats.itemCount += 1
            ingestElement(members)
            return
        }
        if members["step"] != nil {
            stats.itemCount += 1
            ingestStep(members)
            return
        }
        let hasWrappedLists = members["elements"] != nil || members["steps"] != nil
        let hasHeaderFields = members["wb"] != nil || members["sections"] != nil || members["dir"] != nil || (hasWrappedLists && members["title"] != nil)
        if hasHeaderFields {
            stats.itemCount += 1
            ingestHeader(members)
        }
        if hasWrappedLists {
            if case .array(let elementValues)? = members["elements"] {
                for elementValue in elementValues { ingestWrappedItem(elementValue, defaultIsStep: false) }
            }
            if case .array(let stepValues)? = members["steps"] {
                for stepValue in stepValues { ingestWrappedItem(stepValue, defaultIsStep: true) }
            }
            return
        }
        if hasHeaderFields { return }
        stats.itemCount += 1
        if members["show"] != nil || members["say"] != nil {
            ingestStep(members)
        } else if members["from"] != nil && members["to"] != nil {
            var arrowMembers = members
            arrowMembers["el"] = .string("arrow")
            ingestElement(arrowMembers)
        } else {
            recordDrop("unknown object")
        }
    }

    /// An item of a wrapper's "elements" / "steps" list; may lack "el" / "step".
    private mutating func ingestWrappedItem(_ value: WBJSONValue, defaultIsStep: Bool) {
        guard case .object(let members) = value else {
            ingest(value)
            return
        }
        if members["el"] != nil || members["step"] != nil || members["type"] != nil {
            ingestObject(members)
            return
        }
        stats.itemCount += 1
        if defaultIsStep || members["show"] != nil || members["say"] != nil {
            ingestStep(members)
        } else if members["from"] != nil && members["to"] != nil {
            var arrowMembers = members
            arrowMembers["el"] = .string("arrow")
            ingestElement(arrowMembers)
        } else {
            var boxMembers = members
            boxMembers["el"] = .string("box")
            ingestElement(boxMembers)
        }
    }

    private mutating func ingestHeader(_ members: [String: WBJSONValue]) {
        if boardTitle == nil, let title = Self.string(members["title"]) { boardTitle = title }
        if boardDirection == nil, let directionText = Self.string(members["dir"] ?? members["direction"]) {
            boardDirection = Self.snapDirection(directionText)
        }
        guard case .array(let sectionValues)? = members["sections"] else { return }
        for sectionValue in sectionValues {
            var rawIdentifier: String?
            var title: String?
            var question: String?
            switch sectionValue {
            case .object(let sectionMembers):
                rawIdentifier = Self.string(sectionMembers["id"])
                title = Self.string(sectionMembers["title"] ?? sectionMembers["name"])
                question = Self.string(sectionMembers["q"] ?? sectionMembers["question"])
            default:
                title = Self.string(sectionValue)
            }
            let fallbackIdentifier = "s\(sections.count + 1)"
            let sectionIdentifier = Self.sanitizedIdentifier(rawIdentifier ?? title ?? fallbackIdentifier) ?? fallbackIdentifier
            if let existingIndex = sections.firstIndex(where: { $0.id == sectionIdentifier }) {
                if sectionIdentifiersCreatedFromElements.contains(sectionIdentifier) {
                    if let title { sections[existingIndex].title = title }
                    sections[existingIndex].question = question ?? sections[existingIndex].question
                    sectionIdentifiersCreatedFromElements.removeAll { $0 == sectionIdentifier }
                }
                continue
            }
            guard sections.count < Self.maximumSectionCount else {
                recordDrop("section over limit: \(sectionIdentifier)")
                continue
            }
            sections.append(WBSection(id: sectionIdentifier, title: title ?? rawIdentifier ?? sectionIdentifier, question: question))
        }
    }

    private mutating func ingestElement(_ members: [String: WBJSONValue]) {
        let rawKind = (Self.string(members["el"]) ?? Self.string(members["type"]) ?? "").lowercased()
        let kind = Self.canonicalKind(rawKind)
        guard elements.count < Self.maximumElementCount else {
            recordDrop("element over limit")
            return
        }
        let elementIdentifier = uniqueIdentifier(for: Self.string(members["id"]))
        let sectionIdentifier = resolveSectionIdentifier(Self.string(members["sec"] ?? members["section"]))
        let payload: WBElementPayload?
        switch kind {
        case .box: payload = makeBox(members, elementIdentifier: elementIdentifier)
        case .arrow: payload = Self.makeArrow(members)
        case .text: payload = Self.makeText(members)
        case .list: payload = Self.makeList(members)
        case .code: payload = Self.makeCode(members)
        case .math: payload = Self.makeMath(members)
        case .chart: payload = Self.makeChart(members)
        case .table: payload = Self.makeTable(members)
        case .callout: payload = Self.makeCallout(members)
        case .flow: payload = Self.makeFlow(members, flowIdentifier: elementIdentifier, sectionIdentifier: sectionIdentifier)
        case .divider: payload = .divider
        }
        guard let payload else {
            usedElementIdentifiers.remove(elementIdentifier)
            recordDrop("empty \(kind.rawValue) \(elementIdentifier)")
            return
        }
        elements.append(WBElement(id: elementIdentifier, sectionIdentifier: sectionIdentifier, payload: payload))
    }

    private mutating func ingestStep(_ members: [String: WBJSONValue]) {
        guard pendingSteps.count < Self.maximumStepCount else {
            recordDrop("step over limit")
            return
        }
        var step = PendingStep()
        step.shownReferences = Self.stringList(members["show"] ?? members["shows"] ?? members["reveal"]).compactMap(Self.referenceIdentifier)
        step.highlightedReferences = Self.stringList(members["hl"] ?? members["highlight"]).compactMap(Self.referenceIdentifier)
        step.say = Self.string(members["say"] ?? members["narration"] ?? members["text"]) ?? ""
        switch members["cue"] ?? members["cues"] {
        case .object(let cueMembers)?:
            for (cueKey, cueValue) in cueMembers {
                if let reference = Self.referenceIdentifier(cueKey), let word = Self.string(cueValue) {
                    step.cueReferences.append((reference, word))
                }
            }
        case .array(let cueValues)?:
            for cueValue in cueValues {
                switch cueValue {
                case .array(let pair) where pair.count >= 2:
                    if let reference = Self.string(pair[0]).flatMap(Self.referenceIdentifier), let word = Self.string(pair[1]) {
                        step.cueReferences.append((reference, word))
                    }
                case .object(let cueMembers):
                    if let reference = Self.string(cueMembers["id"]).flatMap(Self.referenceIdentifier), let word = Self.string(cueMembers["word"]) {
                        step.cueReferences.append((reference, word))
                    }
                default:
                    break
                }
            }
        default:
            break
        }
        step.pointReference = Self.string(members["point"]).flatMap(Self.referenceIdentifier)
        step.focusReference = Self.string(members["focus"])
        pendingSteps.append(step)
    }

    // MARK: - Finish

    /// The board so far, for drawing while the stream is still arriving:
    /// arrows whose endpoints haven't arrived and unknown step ids are left
    /// out, and no fallback steps are made. Stats are not final.
    public var provisionalBoard: WBBoard {
        var copy = self
        return copy.finalize(isFinal: false).board
    }

    /// Resolves references and fills in steps; call once the stream ended.
    public func finish() -> WBParseOutcome {
        var copy = self
        return copy.finalize(isFinal: true)
    }

    private mutating func finalize(isFinal: Bool) -> WBParseOutcome {
        resolveArrows(isFinal: isFinal)
        let elementIdentifiers = Set(elements.map(\.id))
        var innerFlowIdentifiers: Set<String> = []
        for element in elements {
            if case .flow(let flow) = element.payload { innerFlowIdentifiers.formUnion(flow.elements.map(\.id)) }
        }
        let knownIdentifiers = elementIdentifiers.union(innerFlowIdentifiers)

        // "near" and callout targets that match nothing are dropped.
        for elementIndex in elements.indices {
            switch elements[elementIndex].payload {
            case .text(var text):
                if let nearReference = text.nearIdentifier {
                    text.nearIdentifier = Self.resolve(nearReference, in: knownIdentifiers)
                    if text.nearIdentifier == nil {
                        text.position = nil
                        if isFinal { stats.droppedReferenceCount += 1 }
                    }
                    elements[elementIndex].payload = .text(text)
                }
            case .callout(var callout):
                if let targetReference = callout.targetIdentifier {
                    callout.targetIdentifier = Self.resolve(targetReference, in: knownIdentifiers)
                    if callout.targetIdentifier == nil, isFinal { stats.droppedReferenceCount += 1 }
                    elements[elementIndex].payload = .callout(callout)
                }
            default:
                break
            }
        }

        var steps = pendingSteps.enumerated().map { stepIndex, pendingStep in
            resolveStep(pendingStep, number: stepIndex + 1, knownIdentifiers: knownIdentifiers, countsDrops: isFinal)
        }
        if isFinal {
            if steps.isEmpty {
                for section in sections {
                    let sectionElementIdentifiers = elements.filter { $0.sectionIdentifier == section.id }.map(\.id)
                    guard !sectionElementIdentifiers.isEmpty else { continue }
                    steps.append(WBStep(number: steps.count + 1, shownIdentifiers: sectionElementIdentifiers, focus: .section(section.id)))
                }
            } else {
                var shownIdentifiers: Set<String> = []
                for step in steps { shownIdentifiers.formUnion(step.shownIdentifiers) }
                let neverShownIdentifiers = elements.map(\.id).filter { !shownIdentifiers.contains($0) }
                steps[steps.count - 1].shownIdentifiers += neverShownIdentifiers
            }
        }

        var pagedSections = sections
        for sectionIndex in pagedSections.indices {
            pagedSections[sectionIndex].page = sectionIndex / Self.sectionsPerPage + 1
        }
        let board = WBBoard(title: boardTitle ?? "", direction: boardDirection ?? .topToBottom, sections: pagedSections, elements: elements, steps: steps)
        var finalStats = stats
        finalStats.elementCount = elements.count
        finalStats.stepCount = steps.count
        return WBParseOutcome(board: board, stats: finalStats)
    }

    /// Arrow endpoints: known, or a placeholder box when the id looks like a
    /// name (two or more letters), else the arrow is dropped.
    private mutating func resolveArrows(isFinal: Bool) {
        var knownIdentifiers = Set(elements.map(\.id))
        for element in elements {
            if case .flow(let flow) = element.payload { knownIdentifiers.formUnion(flow.elements.map(\.id)) }
        }
        var resolvedElements: [WBElement] = []
        var placeholderBoxes: [WBElement] = []
        for element in elements {
            guard case .arrow(var arrow) = element.payload else {
                resolvedElements.append(element)
                continue
            }
            var endpointsResolved = true
            for isFromEndpoint in [true, false] {
                let reference = isFromEndpoint ? arrow.fromIdentifier : arrow.toIdentifier
                var resolvedIdentifier = Self.resolve(reference, in: knownIdentifiers)
                if resolvedIdentifier == nil, isFinal,
                   reference.unicodeScalars.filter({ $0.properties.isAlphabetic }).count >= 2,
                   elements.count + placeholderBoxes.count < Self.maximumElementCount,
                   let placeholderIdentifier = Self.sanitizedIdentifier(reference) {
                    let placeholderText = String(placeholderIdentifier.map { $0 == "_" || $0 == "-" ? " " : $0 }.prefix(WBBox.maximumTextLength))
                    placeholderBoxes.append(WBElement(id: placeholderIdentifier, sectionIdentifier: element.sectionIdentifier, payload: .box(WBBox(text: placeholderText, isPlaceholder: true))))
                    knownIdentifiers.insert(placeholderIdentifier)
                    usedElementIdentifiers.insert(placeholderIdentifier)
                    resolvedIdentifier = placeholderIdentifier
                }
                guard let resolvedIdentifier else {
                    endpointsResolved = false
                    break
                }
                if isFromEndpoint { arrow.fromIdentifier = resolvedIdentifier } else { arrow.toIdentifier = resolvedIdentifier }
            }
            if endpointsResolved {
                resolvedElements.append(WBElement(id: element.id, sectionIdentifier: element.sectionIdentifier, payload: .arrow(arrow)))
            } else if isFinal {
                recordDrop("dangling arrow \(element.id)")
            }
        }
        elements = resolvedElements + placeholderBoxes
    }

    private mutating func resolveStep(_ pendingStep: PendingStep, number: Int, knownIdentifiers: Set<String>, countsDrops: Bool) -> WBStep {
        var droppedReferences = 0
        func resolveList(_ references: [String]) -> [String] {
            var resolvedIdentifiers: [String] = []
            for reference in references {
                guard let resolvedIdentifier = Self.resolve(reference, in: knownIdentifiers) else {
                    droppedReferences += 1
                    continue
                }
                if !resolvedIdentifiers.contains(resolvedIdentifier) { resolvedIdentifiers.append(resolvedIdentifier) }
            }
            return resolvedIdentifiers
        }
        var step = WBStep(number: number, say: pendingStep.say)
        step.shownIdentifiers = resolveList(pendingStep.shownReferences)
        step.highlightedIdentifiers = resolveList(pendingStep.highlightedReferences)

        let lowercasedSay = pendingStep.say.lowercased()
        var cues: [(position: Int, cue: WBCue)] = []
        for (reference, word) in pendingStep.cueReferences {
            guard let resolvedIdentifier = Self.resolve(reference, in: knownIdentifiers) else {
                droppedReferences += 1
                continue
            }
            guard !cues.contains(where: { $0.cue.elementIdentifier == resolvedIdentifier }) else { continue }
            let wordRange = lowercasedSay.range(of: word.lowercased())
            let position = wordRange.map { lowercasedSay.distance(from: lowercasedSay.startIndex, to: $0.lowerBound) } ?? Int.max
            cues.append((position, WBCue(elementIdentifier: resolvedIdentifier, word: word)))
        }
        step.cues = cues.sorted {
            $0.position != $1.position ? $0.position < $1.position : $0.cue.elementIdentifier < $1.cue.elementIdentifier
        }.map(\.cue)

        if let pointReference = pendingStep.pointReference {
            step.pointIdentifier = Self.resolve(pointReference, in: knownIdentifiers)
            if step.pointIdentifier == nil { droppedReferences += 1 }
        }
        if let focusReference = pendingStep.focusReference {
            step.focus = resolveFocus(focusReference, shownIdentifiers: step.shownIdentifiers, knownIdentifiers: knownIdentifiers)
            if step.focus == nil { droppedReferences += 1 }
        }
        if countsDrops { stats.droppedReferenceCount += droppedReferences }
        return step
    }

    private func resolveFocus(_ focusReference: String, shownIdentifiers: [String], knownIdentifiers: Set<String>) -> WBFocus? {
        let lowercasedFocus = focusReference.lowercased()
        if lowercasedFocus == "board" || lowercasedFocus == "all" { return .board }
        if lowercasedFocus == "sec" || lowercasedFocus == "section" {
            guard let firstShownIdentifier = shownIdentifiers.first,
                  let shownElement = elements.first(where: { $0.id == firstShownIdentifier }) else { return nil }
            return .section(shownElement.sectionIdentifier)
        }
        if let referenceIdentifier = Self.referenceIdentifier(focusReference),
           let elementIdentifier = Self.resolve(referenceIdentifier, in: knownIdentifiers) {
            return .element(elementIdentifier)
        }
        if let sectionIdentifier = Self.sanitizedIdentifier(focusReference), sections.contains(where: { $0.id == sectionIdentifier }) {
            return .section(sectionIdentifier)
        }
        if let titledSection = sections.first(where: { $0.title.lowercased() == lowercasedFocus }) {
            return .section(titledSection.id)
        }
        return nil
    }

    // MARK: - Identifiers and sections

    private mutating func uniqueIdentifier(for rawIdentifier: String?) -> String {
        if let baseIdentifier = rawIdentifier.flatMap(Self.sanitizedIdentifier) {
            if !usedElementIdentifiers.contains(baseIdentifier) {
                usedElementIdentifiers.insert(baseIdentifier)
                return baseIdentifier
            }
            var suffixNumber = 2
            while true {
                let suffix = "_\(suffixNumber)"
                let candidate = String(baseIdentifier.prefix(Self.maximumIdentifierLength - suffix.count)) + suffix
                if !usedElementIdentifiers.contains(candidate) {
                    usedElementIdentifiers.insert(candidate)
                    return candidate
                }
                suffixNumber += 1
            }
        }
        while true {
            let candidate = "auto_\(nextAutomaticIdentifierNumber)"
            nextAutomaticIdentifierNumber += 1
            if !usedElementIdentifiers.contains(candidate) {
                usedElementIdentifiers.insert(candidate)
                return candidate
            }
        }
    }

    private mutating func resolveSectionIdentifier(_ rawSection: String?) -> String {
        if let rawSection, let sectionIdentifier = Self.sanitizedIdentifier(rawSection) {
            if sections.contains(where: { $0.id == sectionIdentifier }) {
                currentSectionIdentifier = sectionIdentifier
                return sectionIdentifier
            }
            if let titledSection = sections.first(where: { $0.title.lowercased() == rawSection.lowercased() }) {
                currentSectionIdentifier = titledSection.id
                return titledSection.id
            }
            if sections.count < Self.maximumSectionCount {
                sections.append(WBSection(id: sectionIdentifier, title: rawSection))
                sectionIdentifiersCreatedFromElements.append(sectionIdentifier)
                currentSectionIdentifier = sectionIdentifier
                return sectionIdentifier
            }
        }
        if let currentSectionIdentifier { return currentSectionIdentifier }
        if let firstSection = sections.first { return firstSection.id }
        sections.append(WBSection(id: Self.defaultSectionIdentifier, title: ""))
        currentSectionIdentifier = Self.defaultSectionIdentifier
        return Self.defaultSectionIdentifier
    }

    private mutating func recordDrop(_ reason: String) {
        stats.droppedCount += 1
        stats.droppedReasons.append(reason)
    }

    /// [A-Za-z0-9_-]{1,32}: other characters become "_"; nil when empty.
    public static func sanitizedIdentifier(_ rawIdentifier: String) -> String? {
        let trimmedIdentifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        var sanitized = ""
        for scalar in trimmedIdentifier.unicodeScalars {
            let isAllowed = ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-"
            sanitized.unicodeScalars.append(isAllowed ? scalar : "_")
        }
        sanitized = String(sanitized.prefix(maximumIdentifierLength))
        return sanitized.isEmpty ? nil : sanitized
    }

    /// Like sanitizedIdentifier, but keeps "." (flow inner ids "f1.A").
    static func referenceIdentifier(_ rawReference: String) -> String? {
        let trimmedReference = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedReference.isEmpty ? nil : trimmedReference
    }

    static func resolve(_ reference: String, in knownIdentifiers: Set<String>) -> String? {
        if knownIdentifiers.contains(reference) { return reference }
        if let sanitizedReference = sanitizedIdentifier(reference), knownIdentifiers.contains(sanitizedReference) { return sanitizedReference }
        return nil
    }

    // MARK: - Payloads

    private func makeBox(_ members: [String: WBJSONValue], elementIdentifier: String) -> WBElementPayload {
        let boxText = Self.firstString(members, keys: ["text", "label", "title", "name"]) ?? elementIdentifier
        let iconName = Self.string(members["icon"])?.trimmingCharacters(in: .whitespaces)
        return .box(WBBox(
            text: Self.truncated(boxText, to: WBBox.maximumTextLength),
            shape: Self.snapShape(Self.string(members["shape"]) ?? ""),
            color: Self.string(members["color"] ?? members["colour"]).map(Self.snapColor),
            icon: iconName.flatMap { isValidSymbol($0) ? $0 : nil },
            isPlaceholder: Self.bool(members["placeholder"]) ?? false))
    }

    static func makeArrow(_ members: [String: WBJSONValue]) -> WBElementPayload? {
        guard let fromReference = firstString(members, keys: ["from", "source", "start"]).flatMap(referenceIdentifier),
              let toReference = firstString(members, keys: ["to", "target", "end", "dest"]).flatMap(referenceIdentifier) else { return nil }
        let styleText = (string(members["style"]) ?? "").lowercased()
        let style: WBArrowStyle
        switch styleText {
        case "dashed", "dotted", "dash", "dot": style = .dashed
        case "thick", "bold", "heavy": style = .thick
        default: style = .solid
        }
        let headText = (string(members["head"]) ?? "").lowercased()
        let head: WBArrowHead
        switch headText {
        case "both", "double", "two", "bi": head = .both
        case "none", "no", "line", "false": head = .none
        default: head = .end
        }
        return .arrow(WBArrow(fromIdentifier: fromReference, toIdentifier: toReference, text: firstString(members, keys: ["text", "label"]), style: style, head: head))
    }

    static func makeText(_ members: [String: WBJSONValue]) -> WBElementPayload? {
        guard let text = firstString(members, keys: ["text", "label", "caption", "title", "content", "value", "name", "tex"]) ?? listText(members) else { return nil }
        let size: WBTextSize
        switch members["size"] {
        case .number(let pointSize)?:
            size = pointSize < 14 ? .small : pointSize < 20 ? .medium : pointSize < 30 ? .large : .title
        default:
            switch (string(members["size"]) ?? "").lowercased() {
            case "s", "sm", "small", "caption", "tiny", "xs": size = .small
            case "l", "lg", "large", "big", "heading", "h2", "h3": size = .large
            case "xl", "xxl", "title", "huge", "h1": size = .title
            default: size = .medium
            }
        }
        let positionText = (string(members["pos"] ?? members["position"]) ?? "").lowercased()
        let position: WBRelativePosition?
        switch positionText {
        case "top", "above", "up", "over", "n": position = .top
        case "bottom", "below", "under", "down", "s": position = .bottom
        case "left", "w": position = .left
        case "right", "e": position = .right
        default: position = nil
        }
        return .text(WBText(text: text, size: size, nearIdentifier: string(members["near"]).flatMap(referenceIdentifier), position: position))
    }

    /// Items of a list-shaped object, joined, for an unknown kind turned text.
    private static func listText(_ members: [String: WBJSONValue]) -> String? {
        let items = stringList(members["items"])
        return items.isEmpty ? nil : items.joined(separator: "; ")
    }

    static func makeList(_ members: [String: WBJSONValue]) -> WBElementPayload? {
        var items: [String]
        if case .string(let itemsText)? = members["items"] {
            items = itemsText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            items = stringList(members["items"] ?? members["bullets"] ?? members["points"])
        }
        items = Array(items.filter { !$0.isEmpty }.prefix(WBList.maximumItemCount))
        let title = firstString(members, keys: ["title", "text", "label"])
        guard !items.isEmpty || title != nil else { return nil }
        return .list(WBList(title: title, items: items, isOrdered: bool(members["ordered"] ?? members["numbered"]) ?? false))
    }

    static func makeCode(_ members: [String: WBJSONValue]) -> WBElementPayload? {
        let rawCode: String?
        if case .array(let lineValues)? = members["text"] ?? members["code"] ?? members["lines"] {
            rawCode = lineValues.compactMap { string($0, trims: false) }.joined(separator: "\n")
        } else {
            rawCode = string(members["text"] ?? members["code"] ?? members["src"] ?? members["source"], trims: false)
        }
        guard var codeLines = rawCode?.components(separatedBy: "\n") else { return nil }
        codeLines = codeLines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        while let lastLine = codeLines.last, lastLine.trimmingCharacters(in: .whitespaces).isEmpty { codeLines.removeLast() }
        while let firstLine = codeLines.first, firstLine.trimmingCharacters(in: .whitespaces).isEmpty { codeLines.removeFirst() }
        codeLines = Array(codeLines.prefix(WBCode.maximumLineCount))
        guard !codeLines.isEmpty else { return nil }
        var highlightedLines: [Int] = []
        let highlightValues: [WBJSONValue]
        switch members["hl"] ?? members["highlight"] {
        case .array(let values)?: highlightValues = values
        case let singleValue?: highlightValues = [singleValue]
        case nil: highlightValues = []
        }
        for highlightValue in highlightValues {
            if let lineNumber = integer(highlightValue) {
                highlightedLines.append(lineNumber)
            } else if let rangeText = string(highlightValue) {
                let bounds = rangeText.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] <= WBCode.maximumLineCount {
                    highlightedLines += Array(bounds[0]...bounds[1])
                }
            }
        }
        highlightedLines = Array(Set(highlightedLines.filter { (1...codeLines.count).contains($0) })).sorted()
        return .code(WBCode(language: firstString(members, keys: ["lang", "language"]), text: codeLines.joined(separator: "\n"), highlightedLines: highlightedLines))
    }

    static func makeMath(_ members: [String: WBJSONValue]) -> WBElementPayload? {
        guard var tex = firstString(members, keys: ["tex", "latex", "formula", "equation", "math", "text"]) else { return nil }
        for delimiter in ["$$", "$", "\\[", "\\("] {
            let closingDelimiter = delimiter == "\\[" ? "\\]" : delimiter == "\\(" ? "\\)" : delimiter
            if tex.count > delimiter.count + closingDelimiter.count, tex.hasPrefix(delimiter), tex.hasSuffix(closingDelimiter) {
                tex = String(tex.dropFirst(delimiter.count).dropLast(closingDelimiter.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return tex.isEmpty ? nil : .math(WBMath(tex: tex))
    }

    static func makeChart(_ members: [String: WBJSONValue]) -> WBElementPayload? {
        var points: [WBChartPoint] = []
        if case .array(let dataValues)? = members["data"] ?? members["points"] ?? members["series"] {
            for dataValue in dataValues {
                switch dataValue {
                case .array(let pair) where pair.count >= 2:
                    if let label = string(pair[0]), let value = number(pair[1]) { points.append(WBChartPoint(label: label, value: value)) }
                case .object(let pointMembers):
                    if let label = firstString(pointMembers, keys: ["label", "name", "x", "key"]),
                       let value = (["value", "y", "n", "count"].lazy.compactMap { number(pointMembers[$0]) }).first {
                        points.append(WBChartPoint(label: label, value: value))
                    }
                default:
                    break
                }
            }
        } else if case .array(let labelValues)? = members["labels"], case .array(let valueValues)? = members["values"] {
            for (labelValue, valueValue) in zip(labelValues, valueValues) {
                if let label = string(labelValue), let value = number(valueValue) { points.append(WBChartPoint(label: label, value: value)) }
            }
        }
        points = Array(points.prefix(WBChart.maximumPointCount))
        guard !points.isEmpty else { return nil }
        let kind: WBChartKind
        switch (string(members["kind"] ?? members["chart"]) ?? "").lowercased() {
        case "line", "area", "trend", "scatter": kind = .line
        case "pie", "donut", "doughnut": kind = .pie
        default: kind = .bar
        }
        return .chart(WBChart(kind: kind, title: firstString(members, keys: ["title", "text", "label"]), points: points))
    }

    static func makeTable(_ members: [String: WBJSONValue]) -> WBElementPayload? {
        var columns = stringList(members["cols"] ?? members["columns"] ?? members["headers"] ?? members["header"])
        var rowValues: [WBJSONValue] = []
        if case .array(let values)? = members["rows"] ?? members["data"] { rowValues = values }
        var rows: [[String]] = []
        for rowValue in rowValues {
            switch rowValue {
            case .array(let cellValues):
                rows.append(cellValues.map { string($0) ?? "" })
            case .object(let cellMembers):
                rows.append(columns.map { string(cellMembers[$0]) ?? "" })
            default:
                if let cellText = string(rowValue) { rows.append([cellText]) }
            }
        }
        if columns.isEmpty, !rows.isEmpty { columns = rows.removeFirst() }
        columns = Array(columns.prefix(WBTable.maximumColumnCount))
        guard !columns.isEmpty else { return nil }
        rows = rows.prefix(WBTable.maximumRowCount).map { row in
            let trimmedRow = Array(row.prefix(columns.count))
            return trimmedRow + Array(repeating: "", count: columns.count - trimmedRow.count)
        }
        return .table(WBTable(columns: columns, rows: rows))
    }

    static func makeCallout(_ members: [String: WBJSONValue]) -> WBElementPayload? {
        guard let text = firstString(members, keys: ["text", "label", "note", "title"]) else { return nil }
        let style: WBCalloutStyle
        switch (string(members["style"] ?? members["kind"]) ?? "").lowercased() {
        case "tip", "hint", "idea", "good", "success": style = .tip
        case "warn", "warning", "caution", "careful": style = .warning
        case "error", "danger", "bad", "wrong", "mistake": style = .error
        default: style = .info
        }
        return .callout(WBCallout(targetIdentifier: firstString(members, keys: ["target", "near", "to", "for"]).flatMap(referenceIdentifier), style: style, text: text))
    }

    static func makeFlow(_ members: [String: WBJSONValue], flowIdentifier: String, sectionIdentifier: String) -> WBElementPayload? {
        let source: String?
        if case .array(let lineValues)? = members["src"] ?? members["source"] ?? members["mermaid"] ?? members["lines"] {
            source = lineValues.compactMap { string($0) }.joined(separator: "\n")
        } else {
            source = firstString(members, keys: ["src", "source", "mermaid", "text", "code"])
        }
        guard let source else { return nil }
        let flow = MermaidFlowParser.parse(source, flowIdentifier: flowIdentifier, sectionIdentifier: sectionIdentifier)
        return flow.elements.isEmpty ? nil : .flow(flow)
    }

    // MARK: - Snapping

    static func canonicalKind(_ rawKind: String) -> WBElementKind {
        switch rawKind {
        case "box", "rect", "rectangle", "node", "shape", "card", "block": return .box
        case "arrow", "line", "edge", "link", "connector", "connection": return .arrow
        case "text", "note", "label", "caption", "title", "heading", "paragraph": return .text
        case "list", "bullets", "bullet", "bulleted", "items": return .list
        case "code", "snippet", "codeblock": return .code
        case "math", "latex", "formula", "equation", "tex": return .math
        case "chart", "graph", "plot", "bar", "pie": return .chart
        case "table", "grid", "matrix": return .table
        case "callout", "annotation", "tip", "warning": return .callout
        case "flow", "mermaid", "flowchart", "diagram": return .flow
        case "divider", "separator", "hr", "rule": return .divider
        default: return .text
        }
    }

    static func snapDirection(_ directionText: String) -> WBDirection {
        switch directionText.uppercased() {
        case "LR", "RL", "HORIZONTAL", "ROW", "LEFT-RIGHT": return .leftToRight
        default: return .topToBottom
        }
    }

    static func snapShape(_ shapeText: String) -> WBBoxShape {
        switch shapeText.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "round", "rounded", "roundrect", "rounded-rect", "rounded-rectangle", "soft": return .round
        case "pill", "capsule", "stadium", "terminal": return .pill
        case "diamond", "rhombus", "decision", "choice": return .diamond
        case "circle", "oval", "ellipse", "dot": return .circle
        case "cyl", "cylinder", "database", "db", "storage", "store": return .cyl
        case "note", "sticky", "postit", "post-it": return .note
        default: return .rect
        }
    }

    private static let colorSynonyms: [(word: String, color: WBColor)] = [
        ("grey", .gray), ("silver", .gray), ("black", .gray), ("white", .gray), ("slate", .gray), ("charcoal", .gray), ("neutral", .gray),
        ("teal", .blue), ("cyan", .blue), ("navy", .blue), ("sky", .blue), ("azure", .blue), ("aqua", .blue), ("cobalt", .blue), ("turquoise", .blue),
        ("indigo", .purple), ("violet", .purple), ("magenta", .purple), ("pink", .purple), ("lavender", .purple), ("lilac", .purple), ("fuchsia", .purple), ("plum", .purple),
        ("lime", .green), ("olive", .green), ("emerald", .green), ("mint", .green), ("forest", .green), ("sage", .green),
        ("gold", .yellow), ("amber", .yellow), ("lemon", .yellow), ("mustard", .yellow),
        ("brown", .orange), ("coral", .orange), ("peach", .orange), ("tan", .orange), ("salmon", .orange),
        ("crimson", .red), ("maroon", .red), ("scarlet", .red), ("ruby", .red), ("rose", .red), ("cherry", .red)
    ]

    /// Exact palette name, else a palette or synonym word inside the name
    /// (earliest wins), else a hex colour's hue, else gray.
    public static func snapColor(_ colorText: String) -> WBColor {
        let lowercasedColor = colorText.lowercased().trimmingCharacters(in: .whitespaces)
        if let exactColor = WBColor(rawValue: lowercasedColor) { return exactColor }
        if lowercasedColor.hasPrefix("#"), let hexColor = hexColor(String(lowercasedColor.dropFirst())) { return hexColor }
        var bestMatch: (position: Int, color: WBColor)?
        let candidateWords = WBColor.allCases.map { ($0.rawValue, $0) } + colorSynonyms.map { ($0.word, $0.color) }
        for (word, color) in candidateWords {
            guard let wordRange = lowercasedColor.range(of: word) else { continue }
            let position = lowercasedColor.distance(from: lowercasedColor.startIndex, to: wordRange.lowerBound)
            if bestMatch == nil || position < bestMatch!.position { bestMatch = (position, color) }
        }
        return bestMatch?.color ?? .gray
    }

    private static func hexColor(_ hexDigits: String) -> WBColor? {
        let expandedDigits = hexDigits.count == 3 ? hexDigits.map { "\($0)\($0)" }.joined() : hexDigits
        guard expandedDigits.count == 6, let rgbValue = Int(expandedDigits, radix: 16) else { return nil }
        let red = Double((rgbValue >> 16) & 0xFF) / 255, green = Double((rgbValue >> 8) & 0xFF) / 255, blue = Double(rgbValue & 0xFF) / 255
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let chroma = maximum - minimum
        guard chroma > 0.15 else { return .gray }
        var hue: Double
        if maximum == red { hue = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6) }
        else if maximum == green { hue = (blue - red) / chroma + 2 }
        else { hue = (red - green) / chroma + 4 }
        hue *= 60
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<15: return .red
        case ..<40: return .orange
        case ..<70: return .yellow
        case ..<165: return .green
        case ..<250: return .blue
        case ..<330: return .purple
        default: return .red
        }
    }

    // MARK: - Value helpers

    /// Strings, numbers (as text, integers without ".0") and booleans.
    static func string(_ value: WBJSONValue?, trims: Bool = true) -> String? {
        switch value {
        case .string(let text)?:
            let result = trims ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
            return result.isEmpty ? nil : result
        case .number(let number)?: return WBJSONLSerializer.numberText(number)
        case .bool(let flag)?: return flag ? "true" : "false"
        default: return nil
        }
    }

    static func firstString(_ members: [String: WBJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let text = string(members[key]) { return text }
        }
        return nil
    }

    static func stringList(_ value: WBJSONValue?) -> [String] {
        switch value {
        case .array(let values)?: return values.compactMap { string($0) }
        case let singleValue?: return string(singleValue).map { [$0] } ?? []
        case nil: return []
        }
    }

    static func number(_ value: WBJSONValue?) -> Double? {
        switch value {
        case .number(let number)?: return number
        case .string(let text)?:
            let cleanedText = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "$", with: "")
            return Double(cleanedText)
        default: return nil
        }
    }

    static func integer(_ value: WBJSONValue?) -> Int? {
        guard let number = number(value), number == number.rounded(), abs(number) < 1e9 else { return nil }
        return Int(number)
    }

    static func bool(_ value: WBJSONValue?) -> Bool? {
        switch value {
        case .bool(let flag)?: return flag
        case .number(let number)?: return number != 0
        case .string(let text)?: return ["true", "yes", "1"].contains(text.lowercased())
        default: return nil
        }
    }

    static func truncated(_ text: String, to maximumLength: Int) -> String {
        text.count <= maximumLength ? text : String(text.prefix(maximumLength - 1)) + "…"
    }
}
