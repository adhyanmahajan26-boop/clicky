//
//  BotLiveText.swift
//  leanring-buddy
//
//  The words a bot is streaming right now, kept apart from BotsStore. A reply arrives in many small chunks a second; when the
//  text lived on the store, every chunk redrew everything watching the store (the sidebar, every message of the open chat,
//  the inspector). On a long chat that kept the main thread at 80-100% for the whole reply, which is the lag Addy kept feeling.
//  Now only the live bubble watches `BotLiveText`, and the sidebar's status line watches `BotLiveHeadline`, which changes only
//  when a reply's first line does.
//

import Combine
import Foundation

@MainActor
final class BotLiveText: ObservableObject {
    static let shared = BotLiveText()
    @Published private(set) var text: [String: String] = [:]

    func set(_ value: String?, for botID: String) {
        if text[botID] != value { text[botID] = value }
        BotLiveHeadline.shared.set(value.map(BotsStore.firstLine), for: botID)
    }
}

@MainActor
final class BotLiveHeadline: ObservableObject {
    static let shared = BotLiveHeadline()
    @Published private(set) var line: [String: String] = [:]

    func set(_ value: String?, for botID: String) {
        if line[botID] != value { line[botID] = value }
    }
}
