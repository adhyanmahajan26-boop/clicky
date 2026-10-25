//
//  ResponseRouter.swift
//  ClickyCore
//
//  Splits Claude's streamed answer, as it arrives, into narration and
//  everything that must never be spoken:
//   - [POINT:…] [MARK:…] [CLEAR] [SNAP:…] (any case, optional space after "["):
//     replaced in the narration by U+E000 plus an index into `tags`, parsed
//     the moment they close (so they can be resolved early and drawn when
//     their words are spoken);
//   - [WORKER:title:task]: on its own line, ending at the line's last "]";
//     emitted at once (spawned unanchored);
//   - <whiteboard>, <code>, <type>, <codetask> blocks: handed to their
//     consumer, or "I can't do that yet" when nothing consumes them
//     (<codetask> is P5 Code mode's JSON task; "<code" alone stays <code>).
//  A "]" inside "…" doesn't close a tag (\" escapes). A tag held longer than
//  800 characters, or still open at the end, is dropped and logged.
//  Narration loses stray tag fragments and "@x,y" coordinates; "#57" is kept
//  (SpeechSafetyNet decides later whether it's a leaked id).
//
//  Output is the same however the text is chunked: narration is released at
//  whitespace or tag boundaries only.
//

import Foundation

public enum ResponseRouterOutput: Equatable, Sendable {
    /// Narration text (U+E000 marks where tag `index` sits).
    case narration(String)
    case tag(index: Int, tag: ParsedTag)
    case worker(title: String, task: String)
    case block(name: String, body: String)
    /// A block nobody consumes yet ("I can't do that yet" is in the narration).
    case unsupportedBlock(name: String)
    case dropped(reason: String, raw: String)
}

public struct ResponseRouter: Sendable {
    public static let placeholder: Character = "\u{E000}"
    public static let maximumHeldTagLength = 800
    public static let maximumHeldBlockLength = 40_000
    public static let maximumWorkers = 4
    public static let blockNames = ["whiteboard", "code", "type", "codetask"]
    public static let unsupportedBlockSentence = "I can't do that yet."

    private static let tagHeads = ["POINT:", "MARK:", "WORKER:", "CLEAR]", "SNAP:", "SNAP]"]

    /// Block names that have a consumer (P4+ register theirs).
    public var blockConsumers: Set<String>
    public private(set) var tags: [ParsedTag] = []
    public private(set) var workerCount = 0
    public private(set) var droppedCount = 0

    private var pending = ""
    private var skippingUntilTagClose = false

    public init(blockConsumers: Set<String> = []) {
        self.blockConsumers = blockConsumers
    }

    public mutating func feed(_ chunk: String) -> [ResponseRouterOutput] {
        pending += chunk
        return process(isFinal: false)
    }

    public mutating func finish() -> [ResponseRouterOutput] {
        process(isFinal: true)
    }

    // MARK: - Scanning

    private enum Head {
        case tag(isWorker: Bool)
        case block(name: String)
    }

    private enum HeadMatch {
        case match(Head)
        case incomplete
        case notAHead
    }

    private mutating func process(isFinal: Bool) -> [ResponseRouterOutput] {
        var outputs: [ResponseRouterOutput] = []
        var narration = ""

        func flushNarration() {
            let cleaned = Self.cleanNarration(narration)
            if !cleaned.isEmpty { outputs.append(.narration(cleaned)) }
            narration = ""
        }

        while !pending.isEmpty {
            if skippingUntilTagClose {
                // After an overflow: discard up to the tag's close or the end of the line.
                guard let closeIndex = Self.unquotedCloseIndex(in: pending, from: pending.startIndex, stopsAtNewline: true) else {
                    if isFinal { pending = "" }
                    break
                }
                pending = String(pending[pending.index(after: closeIndex)...])
                skippingUntilTagClose = false
                continue
            }

            guard let openIndex = pending.firstIndex(where: { $0 == "[" || $0 == "<" }) else {
                // Plain text: release up to the last whitespace (a word may still be arriving).
                if isFinal {
                    narration += pending
                    pending = ""
                } else if let lastWhitespace = pending.lastIndex(where: \.isWhitespace) {
                    let releaseEnd = pending.index(after: lastWhitespace)
                    narration += pending[..<releaseEnd]
                    pending = String(pending[releaseEnd...])
                }
                break
            }

            narration += pending[..<openIndex]
            pending = String(pending[openIndex...])

            switch Self.matchHead(pending, isFinal: isFinal) {
            case .notAHead:
                narration.append(pending.removeFirst())
                continue
            case .incomplete:
                if isFinal {
                    // "[PO" at the very end: a fragment, never spoken.
                    record(&outputs, reason: "fragment at end", raw: pending)
                    pending = ""
                }
            case .match(.block(let name)):
                flushNarration()
                guard let blockEnd = Self.blockEnd(in: pending, name: name) else {
                    if pending.count > Self.maximumHeldBlockLength || isFinal {
                        record(&outputs, reason: isFinal ? "block open at end" : "block over \(Self.maximumHeldBlockLength) chars", raw: String(pending.prefix(200)))
                        pending = ""
                    }
                    break
                }
                let blockText = String(pending[..<blockEnd.end])
                pending = String(pending[blockEnd.end...])
                let body = String(blockText[blockEnd.bodyStart..<blockEnd.bodyEnd])
                if blockConsumers.contains(name) {
                    outputs.append(.block(name: name, body: body))
                } else {
                    outputs.append(.unsupportedBlock(name: name))
                    outputs.append(.narration(Self.unsupportedBlockSentence + " "))
                }
                continue
            case .match(.tag(let isWorker)):
                if isWorker {
                    // WORKER runs to the last "]" of its line.
                    guard let lineEnd = pending.firstIndex(of: "\n") ?? (isFinal ? pending.endIndex : nil) else {
                        if pending.count > Self.maximumHeldTagLength {
                            record(&outputs, reason: "worker over \(Self.maximumHeldTagLength) chars", raw: String(pending.prefix(200)))
                            pending = ""
                            skippingUntilTagClose = false
                        }
                        break
                    }
                    let line = pending[..<lineEnd]
                    pending = String(pending[lineEnd...])
                    if let lastClose = line.lastIndex(of: "]"), let worker = Self.parseWorker(String(line[...lastClose])) {
                        if workerCount < Self.maximumWorkers {
                            workerCount += 1
                            flushNarration()
                            outputs.append(.worker(title: worker.title, task: worker.task))
                        } else {
                            record(&outputs, reason: "more than \(Self.maximumWorkers) workers", raw: String(line))
                        }
                        // Anything after the closing "]" on that line is narration.
                        narration += line[line.index(after: lastClose)...]
                    } else {
                        record(&outputs, reason: "malformed worker", raw: String(line))
                    }
                    continue
                }
                guard let closeIndex = Self.unquotedCloseIndex(in: pending, from: pending.startIndex, stopsAtNewline: false) else {
                    if pending.count > Self.maximumHeldTagLength {
                        record(&outputs, reason: "tag over \(Self.maximumHeldTagLength) chars", raw: String(pending.prefix(200)))
                        pending = ""
                        skippingUntilTagClose = true
                        continue
                    }
                    if isFinal {
                        record(&outputs, reason: "tag open at end", raw: pending)
                        pending = ""
                    }
                    break
                }
                let rawTag = String(pending[...closeIndex])
                pending = String(pending[pending.index(after: closeIndex)...])
                guard rawTag.count <= Self.maximumHeldTagLength else {
                    record(&outputs, reason: "tag over \(Self.maximumHeldTagLength) chars", raw: String(rawTag.prefix(200)))
                    continue
                }
                if let parsedTag = MarkTagParser.parse(rawTag) {
                    narration.append(Self.placeholder)
                    flushNarration()
                    outputs.append(.tag(index: tags.count, tag: parsedTag))
                    tags.append(parsedTag)
                } else {
                    record(&outputs, reason: "malformed tag", raw: rawTag)
                }
                continue
            }
            break
        }
        if isFinal, !pending.isEmpty {
            narration += pending
            pending = ""
        }
        flushNarration()
        return outputs
    }

    private mutating func record(_ outputs: inout [ResponseRouterOutput], reason: String, raw: String) {
        droppedCount += 1
        outputs.append(.dropped(reason: reason, raw: raw))
    }

    /// Does `text` (starting with "[" or "<") begin a tag or block head?
    private static func matchHead(_ text: String, isFinal: Bool) -> HeadMatch {
        let characters = Array(text.prefix(16))
        if characters.first == "<" {
            let afterBracket = String(characters.dropFirst()).lowercased()
            for name in blockNames {
                if afterBracket.count > name.count, afterBracket.hasPrefix(name) {
                    let next = afterBracket[afterBracket.index(afterBracket.startIndex, offsetBy: name.count)]
                    if next == ">" || next == " " { return .match(.block(name: name)) }
                } else if name.hasPrefix(afterBracket) || (afterBracket.count == name.count && afterBracket == name) {
                    return isFinal ? .notAHead : .incomplete
                }
            }
            return .notAHead
        }
        var index = 1
        if index < characters.count, characters[index] == " " { index += 1 }
        let afterBracket = String(characters[min(index, characters.count)...]).uppercased()
        for head in tagHeads {
            if afterBracket.hasPrefix(head) { return .match(.tag(isWorker: head == "WORKER:")) }
            if !afterBracket.isEmpty, head.hasPrefix(afterBracket) { return .incomplete }
        }
        if afterBracket.isEmpty { return .incomplete }
        return .notAHead
    }

    /// The "]" closing a tag, skipping quoted text ("\"" escapes a quote).
    private static func unquotedCloseIndex(in text: String, from start: String.Index, stopsAtNewline: Bool) -> String.Index? {
        var isInsideQuotes = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if isInsideQuotes {
                if character == "\\" {
                    index = text.index(after: index)
                    if index < text.endIndex { index = text.index(after: index) }
                    continue
                }
                if character == "\"" { isInsideQuotes = false }
            } else {
                if character == "\"" { isInsideQuotes = true }
                if character == "]" { return index }
                if stopsAtNewline && character == "\n" { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func blockEnd(in text: String, name: String) -> (bodyStart: String.Index, bodyEnd: String.Index, end: String.Index)? {
        guard let openEnd = text.firstIndex(of: ">") else { return nil }
        let bodyStart = text.index(after: openEnd)
        guard let closeRange = text.range(of: "</\(name)>", options: .caseInsensitive, range: bodyStart..<text.endIndex) else { return nil }
        return (bodyStart, closeRange.lowerBound, closeRange.upperBound)
    }

    /// "[WORKER:title:task]" → (title, task); the task may contain anything.
    static func parseWorker(_ rawTag: String) -> (title: String, task: String)? {
        var body = rawTag.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("["), body.hasSuffix("]") else { return nil }
        body = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard body.uppercased().hasPrefix("WORKER:") else { return nil }
        body = String(body.dropFirst("WORKER:".count))
        guard let colonIndex = body.firstIndex(of: ":") else { return nil }
        let title = body[..<colonIndex].trimmingCharacters(in: .whitespaces)
        let task = body[body.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !task.isEmpty else { return nil }
        return (title, task)
    }

    // MARK: - Narration clean-up

    private static let strayCoordinatePattern = try! NSRegularExpression(pattern: #"@\d+(\.\d+)?,\d+(\.\d+)?"#)
    private static let strayHeadPattern = try! NSRegularExpression(pattern: #"\b(?:POINT|MARK|WORKER|SNAP):[^\s\]]*\]"#, options: [.caseInsensitive])

    /// Removes "@x,y" and tag heads that lost their "[" ("POINT:#5]").
    static func cleanNarration(_ text: String) -> String {
        var cleaned = text
        for pattern in [strayCoordinatePattern, strayHeadPattern] {
            cleaned = pattern.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }
        return cleaned
    }
}
