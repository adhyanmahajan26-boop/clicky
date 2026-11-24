//
//  CallControls.swift
//  ClickyCore
//
//  What Vello can switch or start by itself on a voice call, beyond the [CLICKY: …] and [TELL: …] orders: turning
//  Pointer Assistant on or off ([POINTER: on]) and running a routine now ([ROUTINE: its name]). Only a call reads
//  these tags, since everything said on a call is the owner's own voice. Like the orders, a tag is never read aloud,
//  and it can arrive split across any number of streamed pieces. Group mode adds two: [GROUP: on] when Vello hears it's
//  in an X Space or a room with other people (off when it's just the owner again), and [PASS], its answer when it has
//  nothing to add (ClickyCore `CallGroupMode`).
//

import Foundation

public enum CallControl: Equatable, Sendable {
    case pointerAssistant(turnOn: Bool)
    case runRoutine(name: String)
    /// Group mode on or off ([GROUP: on]).
    case groupMode(turnOn: Bool)
    /// [PASS]: nothing to add this turn, so nothing is said. Not a failure.
    case stayQuiet

    private static let turnOnWords: Set<String> = ["on", "start", "activate", "show", "enable", "wake", "open"]
    private static let turnOffWords: Set<String> = ["off", "stop", "deactivate", "hide", "disable", "close", "sleep"]

    /// The control a tag's name and body ask for. Nil when the body is only someone talking about the tag ("[POINTER: on or off]").
    static func parse(head: String, body: String) -> CallControl? {
        let words = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch head.uppercased() {
        case "POINTER":
            let lowered = words.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if turnOnWords.contains(lowered) { return .pointerAssistant(turnOn: true) }
            if turnOffWords.contains(lowered) { return .pointerAssistant(turnOn: false) }
            return nil
        case "ROUTINE":
            let placeholders = ["name", "its name", "the routine's name", "routine name", "its exact name"]
            guard words.count >= 2, words.contains(where: { $0.isLetter || $0.isNumber }), !placeholders.contains(words.lowercased()) else { return nil }
            return .runRoutine(name: words)
        case "GROUP":
            let lowered = words.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if turnOnWords.contains(lowered) { return .groupMode(turnOn: true) }
            if turnOffWords.contains(lowered) { return .groupMode(turnOn: false) }
            return nil
        case "PASS":
            return .stayQuiet
        default:
            return nil
        }
    }

    /// The routine whose name was said, however loosely: an exact match first, then one name holding the other.
    /// Nil when nothing fits or more than one does equally.
    public static func routine(named spoken: String, among routineNames: [String]) -> Int? {
        func simplified(_ text: String) -> String {
            text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        let wanted = simplified(spoken)
        guard !wanted.isEmpty else { return nil }
        let names = routineNames.map(simplified)
        if let exact = names.firstIndex(of: wanted) { return exact }
        let close = names.indices.filter { !names[$0].isEmpty && (names[$0].contains(wanted) || wanted.contains(names[$0])) }
        return close.count == 1 ? close[0] : nil
    }
}

/// Takes the call-only tags out of a reply as it streams. Anything that isn't one of them passes through untouched, so the
/// [CLICKY: …] and [TELL: …] orders still reach `ClickyOrderStream` after this.
public struct CallControlStream: Sendable {
    private var held = ""
    private static let heads = ["POINTER", "ROUTINE", "GROUP", "PASS"]
    private static let maximumHeld = 400

    public init() {}

    public mutating func feed(_ delta: String) -> (speech: String, controls: [CallControl]) {
        held += delta
        return drain(isFinal: false)
    }

    public mutating func finish() -> (speech: String, controls: [CallControl]) { drain(isFinal: true) }

    /// The tags in a whole reply at once, for a brain that gave only its result.
    public static func extract(from text: String) -> (text: String, controls: [CallControl]) {
        var stream = CallControlStream()
        let first = stream.feed(text)
        let last = stream.finish()
        return (first.speech + last.speech, first.controls + last.controls)
    }

    private mutating func drain(isFinal: Bool) -> (speech: String, controls: [CallControl]) {
        var speech = ""
        var controls: [CallControl] = []
        while let open = held.firstIndex(of: "[") {
            speech += held[..<open]
            held = String(held[open...])
            switch Self.classify(held) {
            case .notATag:
                speech.append(held.removeFirst())
            case .incomplete:
                if isFinal || held.count > Self.maximumHeld {
                    // Never closed: a control tag is dropped rather than read out, anything else is said as written.
                    if !Self.startsWithFullHead(held) { speech += held }
                    held = ""
                }
                return (speech, controls)
            case .closed(let head, let body, let end):
                // A tag that asks for nothing real ("[POINTER: on or off]") is dropped too: a voice reading it out helps nobody.
                if let control = CallControl.parse(head: head, body: body) { controls.append(control) }
                held = String(held[held.index(after: end)...])
            }
        }
        speech += held
        held = ""
        return (speech, controls)
    }

    private enum Shape { case notATag, incomplete, closed(head: String, body: String, end: String.Index) }

    private static func startsWithFullHead(_ text: String) -> Bool {
        let upper = text.dropFirst().drop(while: { $0 == " " }).uppercased()
        return heads.contains { upper.hasPrefix($0) }
    }

    /// `text` starts with "[". Whether it's the start of one of the call's tags, one still arriving, or neither.
    private static func classify(_ text: String) -> Shape {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        var letters = ""
        while index < text.endIndex, text[index].isLetter, letters.count < 8 {
            letters.append(text[index])
            index = text.index(after: index)
        }
        let upper = letters.uppercased()
        guard index < text.endIndex else {
            // Still arriving: hold it while it could become one of the heads.
            return heads.contains { $0.hasPrefix(upper) } ? .incomplete : .notATag
        }
        guard let head = heads.first(where: { $0 == upper }) else { return .notATag }
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        guard index < text.endIndex else { return .incomplete }
        // [PASS] has nothing after its name.
        if head == "PASS", text[index] == "]" { return .closed(head: head, body: "", end: index) }
        guard text[index] == ":" else { return .notATag }
        let bodyStart = text.index(after: index)
        guard let close = text[bodyStart...].firstIndex(of: "]") else { return .incomplete }
        return .closed(head: head, body: String(text[bodyStart..<close]), end: close)
    }
}

/// Vello on a call handing a job to itself, in its own text chat: [TELL: Vello: what to do].
public enum CallOwnChat {
    /// Whether a [TELL: name: …] on a call means Vello's own chat: its own name, its names before and after the rename, or "yourself".
    public static func meansOwnChat(_ name: String, ceoName: String) -> Bool {
        func simplified(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = simplified(name)
        guard !wanted.isEmpty else { return false }
        return [ceoName, "Vello", "Theo", "yourself", "myself", "me", "my chat", "your chat", "own chat", "my own chat", "text chat", "my text chat"]
            .map(simplified).contains(wanted)
    }

    /// The owner's message in that chat: what they said on the call, oldest first, from the call's newest-first lines (at most three).
    public static func ownerMessage(ownerWordsNewestFirst: String) -> String {
        let lines = ownerWordsNewestFirst.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        return "On our call: " + lines.prefix(3).reversed().joined(separator: " ")
    }

    /// Goes on top of that turn: what Vello said on the call it would do there.
    public static func taskNote(task: String, owner: String) -> String {
        "You're on a voice call with \(owner) right now, and on the call you said you'd do this here, in your own chat, with your apps and tools: \(task). " +
            "Do it now. Then answer in a few short plain sentences with what you found or did: your answer is read out on the call."
    }

    /// What comes back to the call: the answer without code blocks or markdown, which a voice can't read, and not too long.
    public static func report(answer: String, maximumCharacters: Int = 900) -> String {
        var text = answer.replacingOccurrences(of: "(?s)```.*?(```|$)", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[*_`#>|]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maximumCharacters { text = String(text.prefix(maximumCharacters)) + "…" }
        return text.isEmpty ? "Your text chat finished without saying anything." : "Your text chat answered: \(text)"
    }
}
