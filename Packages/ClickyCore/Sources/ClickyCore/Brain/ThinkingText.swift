//
//  ThinkingText.swift
//  ClickyCore
//
//  Thinking models (Qwen 3.x, QwQ, DeepSeek R1 and the like) write their reasoning before the answer. A server that
//  separates it sends it as `reasoning_content` (or `reasoning`), which nothing here ever reads as the answer. One that
//  doesn't sends it in the answer itself, between <think> and </think>, and a chat template that already put the opening
//  <think> in the prompt makes the reply start mid-think with only the closing tag. Nothing inside a think block is ever
//  spoken on a call or shown as a bot's answer: `visible` is what's left.
//
//  It works on the whole text so far, so a stream can call it on every piece. The result only ever grows while a reply
//  streams (a caller passing on deltas never has to take words back): anything that might still turn out to be thinking
//  is held until it's sure.
//

import Foundation

public enum ThinkingText {
    static let openingTag = "<think>"
    static let closingTag = "</think>"

    /// Model ids that think in their answer, where a server may leave the opening tag in the prompt: their replies are held
    /// until the thinking is known to be over (a closing tag, or the end of the reply), unless the server is seen
    /// separating the reasoning itself.
    public static func mayThinkWithoutOpeningTag(model: String) -> Bool {
        let lowered = model.lowercased()
        let thinkingFamilies = ["qwen3", "qwq", "deepseek-r1", "r1-distill", "thinking", "reasoning", "reasoner", "magistral",
                                "gpt-oss", "glm-4.5", "glm-z1", "ornith", "exaone-deep", "hermes-4"]
        return thinkingFamilies.contains { lowered.contains($0) }
    }

    /// Whether one server-sent line ("data: {…}") carries reasoning the server separated from the answer. Once a stream has
    /// shown one, its answer can't start mid-think, so nothing needs holding.
    public static func lineCarriesReasoning(_ line: String) -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let delta = (object["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { return false }
        for key in ["reasoning_content", "reasoning"] {
            if let reasoning = delta[key] as? String, !reasoning.isEmpty { return true }
        }
        return false
    }

    /// The answer in `text` without any thinking. `isComplete` false: the reply is still streaming, so a tag that's only
    /// half there is held back, and with `holdsUntilSure` (a model that may start mid-think) nothing shows until a closing
    /// tag or the end. A think block that never closes hides everything after its opening tag.
    public static func visible(_ text: String, isComplete: Bool, holdsUntilSure: Bool = false) -> String {
        var answer = Substring(text)
        let leading = answer.drop(while: \.isWhitespace)
        if startsWith(leading, openingTag) {
            // Opens with thinking: the answer starts after its closing tag.
            let afterOpening = leading.dropFirst(openingTag.count)
            guard let closing = range(of: closingTag, in: afterOpening) else { return "" }
            answer = afterOpening[closing.upperBound...]
        } else if !isComplete, !leading.isEmpty, isStartOf(leading, tag: openingTag) {
            // "<thi": the opening tag still arriving.
            return ""
        } else if let closing = range(of: closingTag, in: answer),
                  range(of: openingTag, in: answer).map({ $0.lowerBound > closing.lowerBound }) ?? true {
            // Started mid-think (the opening tag was in the prompt): everything up to the closing tag was thinking.
            answer = answer[closing.upperBound...]
        } else if holdsUntilSure, !isComplete {
            return ""
        }
        // Any later think blocks: a whole one goes, an unclosed one hides the rest.
        var shown = ""
        var remaining = answer
        while let opening = range(of: openingTag, in: remaining) {
            shown += remaining[..<opening.lowerBound]
            let afterOpening = remaining[opening.upperBound...]
            guard let closing = range(of: closingTag, in: afterOpening) else {
                remaining = ""
                break
            }
            remaining = afterOpening[closing.upperBound...]
        }
        shown += remaining
        shown = shown.replacingOccurrences(of: closingTag, with: "", options: .caseInsensitive)
        if !isComplete { shown = withoutHalfATagAtTheEnd(shown) }
        let trimmedStart = String(shown.drop(while: \.isWhitespace))
        return isComplete ? trimmedStart.trimmingCharacters(in: .whitespacesAndNewlines) : trimmedStart
    }

    /// A streaming reply ending in "<", "</th" or "<think": held back until the next piece says whether it's a tag.
    private static func withoutHalfATagAtTheEnd(_ text: String) -> String {
        guard let lastOpenAngle = text.lastIndex(of: "<") else { return text }
        let ending = text[lastOpenAngle...]
        if isStartOf(ending, tag: openingTag) || isStartOf(ending, tag: closingTag) {
            return String(text[..<lastOpenAngle])
        }
        return text
    }

    private static func startsWith(_ text: Substring, _ tag: String) -> Bool {
        text.lowercased().hasPrefix(tag)
    }

    /// `text` is the first part of `tag` (or all of it).
    private static func isStartOf(_ text: Substring, tag: String) -> Bool {
        text.count <= tag.count && tag.hasPrefix(text.lowercased())
    }

    private static func range(of tag: String, in text: Substring) -> Range<Substring.Index>? {
        text.range(of: tag, options: .caseInsensitive)
    }
}
