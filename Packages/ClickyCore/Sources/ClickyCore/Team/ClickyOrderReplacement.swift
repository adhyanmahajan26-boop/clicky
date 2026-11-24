//
//  ClickyOrderReplacement.swift
//  ClickyCore
//
//  When a newer order to Pointer Assistant replaces the ones still waiting or
//  running, instead of queueing behind them. Pure.
//
//  Orders take turns (`BotsStore.clickyOrderLine`) so that two orders from the
//  same thing the owner said ("open Safari", then "search this in Safari") run
//  one after the other. But when the owner has said something new since an
//  older order was given, the newer order is the instruction that counts: the
//  older one is dropped, and what it started on screen is stopped. Before this,
//  a new order waited up to three minutes behind the old one's steps (the
//  owner, 2026-11-24: "it keeps doing old things even after told to do new one").
//

import Foundation

public enum ClickyOrderReplacement {
    /// `newOwnerLine` / `earlierOwnerLine`: the newest line the owner had said when each order was given
    /// (empty when an order didn't come from the owner's words, such as a routine or the control inbox).
    public static func replaces(newOwnerLine: String, earlierOwnerLine: String) -> Bool {
        let newWords = normalized(newOwnerLine)
        let earlierWords = normalized(earlierOwnerLine)
        guard !newWords.isEmpty, !earlierWords.isEmpty else { return false }
        return newWords != earlierWords
    }

    static func normalized(_ line: String) -> String {
        line.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
