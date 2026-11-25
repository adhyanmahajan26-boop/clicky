//
//  TeamLiveView.swift
//  ClickyCore
//
//  What a team card shows about a team that is alive in Vello: which categories came from a ready-made team (its own
//  name, or a numbered copy such as "Research Desk 2"), which of its bots are which, and a tally of what they are doing
//  right now ("2 working · 1 needs you"). The cards themselves are the app's Settings › Bot teams and Home's org chart.
//

import Foundation

public enum TeamLiveView {
    /// The categories made from a team called `teamName`, by index into `categoryNames`: the exact name first, then its
    /// numbered copies in number order. "Research Desk 2" counts; "Research Desk Two" and "Research" don't.
    public static func categoryIndices(teamName: String, categoryNames: [String]) -> [Int] {
        let wanted = teamName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return [] }
        var exact: [Int] = []
        var copies: [(number: Int, index: Int)] = []
        for (index, raw) in categoryNames.enumerated() {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if name == wanted { exact.append(index); continue }
            guard name.hasPrefix(wanted + " ") else { continue }
            let tail = name.dropFirst(wanted.count + 1)
            if !tail.isEmpty, tail.count <= 3, tail.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(tail), number >= 2 {
                copies.append((number, index))
            }
        }
        return exact + copies.sorted { $0.number < $1.number }.map(\.index)
    }

    /// Each team member's live bot, by place in `memberNames`, picked from the bots in the category (`botNames`). A member
    /// matches its own name or a numbered copy of it ("Web Scout 2"); each bot is used once. Nil where no bot fits (it was
    /// deleted or moved out).
    public static func members(_ memberNames: [String], among botNames: [String]) -> [Int?] {
        var used: Set<Int> = []
        return memberNames.map { member in
            let found = categoryIndices(teamName: member, categoryNames: botNames).first { !used.contains($0) }
            if let found { used.insert(found) }
            return found
        }
    }

    /// How many of a team are in each lane, for the line on its card.
    public struct Tally: Equatable, Sendable {
        public var working = 0
        public var needsYou = 0
        public var failed = 0
        public var done = 0
        public var resting = 0

        public init(working: Int = 0, needsYou: Int = 0, failed: Int = 0, done: Int = 0, resting: Int = 0) {
            self.working = working
            self.needsYou = needsYou
            self.failed = failed
            self.done = done
            self.resting = resting
        }

        public init(_ states: [PixelState]) {
            for state in states {
                switch state.lane {
                case .working: working += 1
                case .needsYou: needsYou += 1
                case .failed: failed += 1
                case .done: done += 1
                case .quiet: resting += 1
                }
            }
        }

        public var total: Int { working + needsYou + failed + done + resting }

        /// "1 needs you · 2 working · 1 resting": what needs the owner first, and nothing that is zero. "All resting" when
        /// nobody is doing anything.
        public var words: String {
            guard total > 0 else { return "No bots" }
            if resting == total { return total == 1 ? "Resting" : "All \(total) resting" }
            var parts: [String] = []
            if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
            if failed > 0 { parts.append("\(failed) failed") }
            if working > 0 { parts.append("\(working) working") }
            if done > 0 { parts.append("\(done) done") }
            if resting > 0 { parts.append("\(resting) resting") }
            return parts.joined(separator: " · ")
        }
    }
}
