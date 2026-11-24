//
//  ActionAppHomes.swift
//  ClickyCore
//
//  Apps people name that live inside another app on many Macs: "open Codex" when there's no Codex.app opens ChatGPT,
//  where Codex is a section (Air, 25 Nov: "no app called Codex", then nine orders to find it).
//

import Foundation

public enum ActionAppHomes {
    /// The app a name lives in, by the name as said (case and spaces don't matter). Only used when no app by that name is here.
    static let homes: [String: String] = [
        "codex": "ChatGPT",
        "openai codex": "ChatGPT",
        "chatgpt codex": "ChatGPT",
        "claude code": "Claude",
        "claude cowork": "Claude",
        "cowork": "Claude",
    ]

    public static func home(of name: String) -> String? {
        let key = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        return homes[key]
    }
}
