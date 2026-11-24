//
//  HandsFreeBargeIn.swift
//  ClickyCore
//
//  Whether words the hands-free mic heard while Pointer Assistant was talking
//  are a new instruction from the owner (they replace what it's doing) rather
//  than its own voice coming back. Pure.
//
//  Only used with echo cancellation on: the canceller already takes most of
//  Pointer Assistant's voice out, and its leftovers are mostly its own words.
//  A new instruction is at least three words, mostly not ones it just said.
//

import Foundation

public enum HandsFreeBargeIn {
    public static let fewestWords = 3

    public static func isNewInstruction(_ heardText: String, recentClickySpokenWords: Set<String>) -> Bool {
        let heardWords = WakeWordMatcher.normalizedWords(in: heardText)
        guard heardWords.count >= fewestWords else { return false }
        return !FollowUpEchoGuard.isLikelyEcho(heardText, recentClickySpokenWords: recentClickySpokenWords)
    }
}
