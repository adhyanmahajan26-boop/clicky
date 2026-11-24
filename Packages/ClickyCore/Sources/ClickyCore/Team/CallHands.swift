//
//  CallHands.swift
//  ClickyCore
//
//  Vello's own hands on a call. Vello used to hand every screen job to Pointer Assistant, a second brain that couldn't
//  hear the call: orders were lost in the relay ("open the Codex app" when Codex lives in ChatGPT), Vello ordered steps
//  it couldn't see in the wrong order, and a "clearer" order threw away work already half done. Now the call's own brain
//  looks at the screen and writes the steps itself, in the same conversation it talks in.
//
//  What the brain writes, at the end of a reply, never spoken:
//    [LOOK]                     show me the screen (badged screenshot + element list come back as the next turn)
//    <actions>{…}</actions>     steps to run now (ActionDSL); the results and a fresh screen come back after each batch
//  `CallScreenStream` takes both out of the streamed reply wherever a delta splits them. The words around them are spoken.
//

import Foundation

/// One thing for Vello's hands in a call reply.
public enum CallScreenPiece: Equatable, Sendable {
    /// `[LOOK]`: capture the screen and show it to the brain.
    case look
    /// An `<actions>` block's body (JSON for ActionDSL).
    case actions(String)
}

/// Takes `[LOOK]` and `<actions>…</actions>` out of a streamed reply. Everything else passes through as speech, in order.
public struct CallScreenStream: Sendable {
    private var held = ""
    /// Text inside an `<actions>` block that's still arriving can be long (a whole prompt to type); a block never closed
    /// is dropped at the end of the reply rather than read out.
    private static let maximumBlockCharacters = ActionDSL.maximumBodyLength + 2_000
    private static let openTag = "<actions>"
    private static let closeTag = "</actions>"
    private static let lookHead = "LOOK"

    public init() {}

    public mutating func feed(_ delta: String) -> (speech: String, pieces: [CallScreenPiece]) {
        held += delta
        return drain(isFinal: false)
    }

    public mutating func finish() -> (speech: String, pieces: [CallScreenPiece]) { drain(isFinal: true) }

    /// The pieces in a whole reply at once, for a brain that gave only its result.
    public static func extract(from text: String) -> (text: String, pieces: [CallScreenPiece]) {
        var stream = CallScreenStream()
        let first = stream.feed(text)
        let last = stream.finish()
        return (first.speech + last.speech, first.pieces + last.pieces)
    }

    private mutating func drain(isFinal: Bool) -> (speech: String, pieces: [CallScreenPiece]) {
        var speech = ""
        var pieces: [CallScreenPiece] = []
        while let open = held.firstIndex(where: { $0 == "<" || $0 == "[" }) {
            speech += held[..<open]
            held = String(held[open...])
            if held.first == "<" {
                switch Self.classifyBlock(held) {
                case .notATag:
                    speech.append(held.removeFirst())
                case .incomplete:
                    if isFinal || held.count > Self.maximumBlockCharacters {
                        // A block that never closed: its steps can't be trusted, and reading JSON aloud helps nobody.
                        if !Self.startsWithOpenTag(held) { speech += held }
                        held = ""
                    }
                    return (Self.withoutCodeFences(speech), pieces)
                case .closed(let body, let end):
                    pieces.append(.actions(body.trimmingCharacters(in: .whitespacesAndNewlines)))
                    held = String(held[end...])
                }
            } else {
                switch Self.classifyLook(held) {
                case .notATag:
                    speech.append(held.removeFirst())
                case .incomplete:
                    if isFinal || held.count > 200 {
                        if !Self.startsWithLookHead(held) { speech += held }
                        held = ""
                    }
                    return (Self.withoutCodeFences(speech), pieces)
                case .closed(_, let end):
                    pieces.append(.look)
                    held = String(held[end...])
                }
            }
        }
        speech += held
        held = ""
        return (Self.withoutCodeFences(speech), pieces)
    }

    private enum Shape { case notATag, incomplete, closed(body: String, end: String.Index) }

    /// `text` starts with "<": an actions block, one still arriving, or neither.
    private static func classifyBlock(_ text: String) -> Shape {
        let lowered = text.lowercased()
        if lowered.count < openTag.count {
            return openTag.hasPrefix(lowered) ? .incomplete : .notATag
        }
        guard lowered.hasPrefix(openTag) else { return .notATag }
        guard let closeRange = lowered.range(of: closeTag) else { return .incomplete }
        // Lowercasing keeps every character's place for this ASCII tag, so the offsets map back onto `text`.
        let bodyStart = text.index(text.startIndex, offsetBy: openTag.count)
        let closeStart = text.index(text.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: closeRange.lowerBound))
        let end = text.index(closeStart, offsetBy: closeTag.count)
        return .closed(body: String(text[bodyStart..<closeStart]), end: end)
    }

    /// `text` starts with "[": `[LOOK]` (or `[LOOK: anything]`), one still arriving, or neither.
    private static func classifyLook(_ text: String) -> Shape {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        var letters = ""
        while index < text.endIndex, text[index].isLetter, letters.count < 5 {
            letters.append(text[index])
            index = text.index(after: index)
        }
        let upper = letters.uppercased()
        guard index < text.endIndex else { return lookHead.hasPrefix(upper) ? .incomplete : .notATag }
        guard upper == lookHead else { return .notATag }
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        guard index < text.endIndex else { return .incomplete }
        if text[index] == "]" { return .closed(body: "", end: text.index(after: index)) }
        guard text[index] == ":" else { return .notATag }
        guard let close = text[index...].firstIndex(of: "]") else { return .incomplete }
        return .closed(body: String(text[text.index(after: index)..<close]), end: text.index(after: close))
    }

    private static func startsWithOpenTag(_ text: String) -> Bool { text.lowercased().hasPrefix(openTag) }

    private static func startsWithLookHead(_ text: String) -> Bool {
        text.dropFirst().drop(while: { $0 == " " }).uppercased().hasPrefix(lookHead)
    }

    /// A model that wraps its block in ``` leaves the fences behind as speech: they're never words.
    private static func withoutCodeFences(_ speech: String) -> String {
        guard speech.contains("```") else { return speech }
        return speech.replacingOccurrences(of: #"```[a-zA-Z]*"#, with: "", options: .regularExpression)
    }
}

/// What Vello is told about its hands, and the messages its screen work sends back into the call's conversation.
public enum CallHands {
    /// A job on a call can be long ("open Codex, make a project folder, paste the brief, pick the model"), so it gets far
    /// more steps than Pointer Assistant's twelve.
    public static let stepLimit = 40
    public static let observeTurnLimit = 30

    /// In Vello's call instructions, in place of the old Pointer Assistant lines.
    public static func howTo(owner: String, leavesSafariAlone: Bool) -> String {
        let protectedApps = leavesSafariAlone ? "Safari and Netflix are left alone unless \(owner) names them" : "Netflix is left alone unless \(owner) names it"
        return """
        You can see and use \(owner)'s Mac yourself on this call: look at the screen, point at things, click, type, scroll, open apps, sites and files. There is no Pointer Assistant any more; you do it, and you stay on the call while you work.
        To see the screen, put [LOOK] at the very end of your reply. The next message brings a screenshot of each screen with numbered badges and a list of what's on it, one line per element: its number, kind and words. That message comes from Vello's eyes, not from \(owner).
        To act, say a few words first, like "Opening Codex now", then put one block at the very end of your reply:
        <actions>{"goal":"short goal","steps":[{"do":"open_app","name":"ChatGPT"},{"do":"wait","seconds":2}]}</actions>
        Steps: open_app {name} · open_url {url} · search {query, engine google or youtube} · click {id} · type {id, text, enter true or false} · key {combo like "cmd+t" or "return"} · scroll {id (optional), direction up/down/left/right, amount 1-10} · point {id} (flies your spark to it, presses nothing) · select_copy {id or text} · wait {seconds, at most 5} · switch_window {app or title} · summarize {} · read_article {}.
        Ids are the badge numbers of the last screen you were shown. Look before you click: if you haven't seen the screen yet, start with [LOOK] or with steps that need no id (open_app, open_url, search, key). After a step that changes the screen, later steps with ids in the same block are skipped, so plan only what you can see, a few steps at a time; typing into the field you just clicked is fine.
        After every block the results come back with a fresh screen and new ids, and you carry on with the next block. When the job is done, check the fresh screen really shows it worked, then tell \(owner) in a sentence, with no block. If a step failed or the screen shows it didn't work, try another way, and say plainly if it still doesn't. A job can take up to \(stepLimit) steps.
        Keep talking while you work: one short line with each block, so \(owner) always knows what you're doing, and never read ids, JSON or brackets aloud.
        Do it yourself: when \(owner) wants something done on screen, do it, don't tell them to click. To show them where something is, use point. In a list a single click only selects; to open or play a row, click it and press return.
        Apps: Codex lives inside the ChatGPT app on this Mac unless a Codex app is installed, and Claude Code is a tab in the Claude app. Open the app, then find the section.
        Enter: put "enter":true on a type step for searches, address bars and prompt boxes (ChatGPT, Codex, Claude). Messages to other people get their return only when \(owner) said send.
        When \(owner) says something while you're working, the steps pause and their words reach you with what was done so far and the screen. A new instruction replaces the old job; a comment or a question doesn't, so answer it and carry on with the next block.
        Safety: only steps that send, post, buy, pay, book or delete something wait for \(owner) to say yes out loud, unless their words already asked for exactly that. Say what you're about to do and wait; never claim it's done before the results say so. Password and payment fields, security prompts, typing into a shell and privacy settings are refused, and \(protectedApps).
        """
    }

    /// The turn that shows the brain the screen after `[LOOK]`. The screenshots and element lists follow it.
    public static func lookMessage(owner: String) -> String {
        "(Vello's eyes, not \(owner) speaking: here is the screen now. Carry on with what \(owner) asked: put the next <actions> block, or answer them if that's all they wanted. Don't describe the screen unless they asked.)"
    }

    /// The turn after a batch ran: the step results (`ActionTaskLoop.continuationMessage`) and the fresh screen.
    public static func observeMessage(continuation: String, owner: String) -> String {
        "(Vello's eyes, not \(owner) speaking: the steps ran. Say one short line about where you are, then put the next block, or tell \(owner) it's done once the screen shows it.)\n\n" + continuation
    }

    /// The owner spoke while steps were running: the steps stopped, and their words come with what was done and the screen.
    public static func ownerSpokeDuringWork(words: String, report: String, owner: String) -> String {
        "\(words)\n\n(\(owner) said that while you were working on screen, so the steps paused. What you'd done: \(report) The screen as it is now is below. If it's a new instruction, do that instead; if not, answer it and carry on with the job.)"
    }

    /// The work stopped by itself (the owner took the mouse, pressed Escape, a step was refused, no yes came).
    public static func workStopped(report: String, owner: String) -> String {
        "(Vello's eyes, not \(owner) speaking: the work on screen stopped. \(report) Tell \(owner) in a sentence, and ask if they want you to carry on when it makes sense.)"
    }

    /// A reply that still gave Pointer Assistant an order out of habit: there's no one to take it, so Vello looks and does it.
    public static func pointerOrderNote(order: String, owner: String) -> String {
        "(Vello's eyes, not \(owner) speaking: there's no Pointer Assistant any more, so do this yourself: \(order). Here is the screen now.)"
    }
}
