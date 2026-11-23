//
//  ForgottenTurn.swift
//  ClickyCore
//
//  A call turn that was started over takes its first try out of the conversation's memory.
//

import Foundation

/// When the owner keeps talking before any of an answer is heard, the call drops that answer and asks again with all their
/// words (`CallCutIn`). The first try must leave the conversation too: kept, the model saw the same question twice with
/// two different answers, one the owner never heard, and lost the thread (Air, 24 Nov, Super Neutral Observer).
public enum ForgottenTurn {
    /// The conversation without the turn that asked `turnText`: its answer, if it got one, and the question itself, both
    /// only when they're the newest messages. Anything older is never touched. `role` is "user" or "assistant".
    public static func dropping<Message>(turnText: String, from messages: [Message], role: (Message) -> String, text: (Message) -> String) -> [Message] {
        var kept = messages
        if let last = kept.last, role(last) == "assistant", kept.count >= 2 {
            let question = kept[kept.count - 2]
            if role(question) == "user", sameWords(text(question), turnText) {
                kept.removeLast(2)
                return kept
            }
        }
        if let last = kept.last, role(last) == "user", sameWords(text(last), turnText) {
            kept.removeLast()
        }
        return kept
    }

    static func sameWords(_ first: String, _ second: String) -> Bool {
        first.trimmingCharacters(in: .whitespacesAndNewlines) == second.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
