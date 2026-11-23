//
//  ModelFreshness.swift
//  ClickyCore
//
//  Keeping model choices current without a new build of Vello. Pure parts only; the app fetches the lists
//  (`ModelFreshnessController`):
//  - `ModelVersionShape` / `ModelUpgrade`: which id is the same model family at a newer version ("claude-sonnet-5" →
//    "claude-sonnet-5-5", "claude-opus-4-8" → "claude-opus-5-5", "grok-4.6" → "grok-4.7"). Never across families (Sonnet
//    never becomes Opus, a mini never becomes the full model), never onto a dated snapshot or a preview, and a model
//    pinned to a snapshot is left alone.
//  - `ModelListFilter`: which ids in a provider's list are for chatting (not embeddings, voices or images).
//  - `ClaudeFastMode`: which Claude models fast mode runs on.
//  - `ClaudeAliasProbe`: the model id Claude Code's own alias ("opus") stands for, read from the first line it prints.
//  - `ClaudeModelList`: the Claude models to offer, newest of each family, from what's bundled and what was found.
//  - `ModelAutoUpgrade`: the owner's switch and the record of what was moved.
//

import Foundation

/// A model id read as a family plus version numbers.
public struct ModelVersionShape: Equatable, Sendable {
    /// The id with each version written as "#": "claude-sonnet-#", "gpt-#-mini", "grok-#-build-fast", "openrouter/x/y-#".
    public let family: String
    /// Each version in order: "grok-4.7-build-fast" → [[4, 7]], "qwen3-235b" → [[3], [235]].
    public let versions: [[Int]]
    /// Ends in a dated snapshot ("-20250929", "-2024-08-06", "-1017"): pinned on purpose.
    public let isSnapshot: Bool
    /// A preview, experimental, alpha or beta build.
    public let isPreview: Bool

    public init?(modelID: String) {
        let lowered = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return nil }
        // "anthropic/claude-sonnet-5-5": the part before the last slash is kept as it is, so providers never mix.
        let name: Substring
        var family = ""
        if let slash = lowered.lastIndex(of: "/") {
            family = String(lowered[...slash])
            name = lowered[lowered.index(after: slash)...]
        } else {
            name = lowered[...]
        }

        var versions: [[Int]] = []
        // The version being read is still open while digit groups are only split by "-" or "." ("5-5", "4.7").
        var versionIsOpen = false
        var pendingSeparator = ""
        var snapshot = false
        var preview = false

        // Tokens are runs of letters and digits; everything else separates them.
        var tokens: [(text: String, separatorBefore: String)] = []
        var currentToken = ""
        var currentSeparator = ""
        for character in name {
            if character.isLetter || character.isNumber {
                currentToken.append(character)
            } else {
                if !currentToken.isEmpty {
                    tokens.append((currentToken, currentSeparator))
                    currentToken = ""
                    currentSeparator = ""
                }
                currentSeparator.append(character)
            }
        }
        if !currentToken.isEmpty { tokens.append((currentToken, currentSeparator)) }
        let trailingSeparator = currentToken.isEmpty ? currentSeparator : ""

        tokenLoop: for token in tokens {
            pendingSeparator = token.separatorBefore
            if ["preview", "exp", "experimental", "alpha", "beta"].contains(token.text) { preview = true }
            // A long number is a date or build stamp: a snapshot, and nothing after it counts.
            if token.text.allSatisfy(\.isNumber), token.text.count >= 4 {
                snapshot = true
                break tokenLoop
            }
            // Split the token into letter and digit chunks: "qwen3" → qwen, 3; "4o" → 4, o; "235b" → 235, b.
            var chunks: [String] = []
            for character in token.text {
                if let last = chunks.last, let lastCharacter = last.last, lastCharacter.isNumber == character.isNumber {
                    chunks[chunks.count - 1].append(character)
                } else {
                    chunks.append(String(character))
                }
            }
            for (chunkIndex, chunk) in chunks.enumerated() {
                let isFirstChunk = chunkIndex == 0
                if let number = Int(chunk) {
                    // Only a token that is all digits carries a version on ("5-5", "4.1"); "235b" after "qwen3" is a size.
                    let continuesVersion = isFirstChunk && chunks.count == 1 && versionIsOpen && (pendingSeparator == "-" || pendingSeparator == ".")
                    if continuesVersion {
                        versions[versions.count - 1].append(number)
                    } else {
                        if isFirstChunk { family += pendingSeparator }
                        family += "#"
                        versions.append([number])
                    }
                    versionIsOpen = true
                } else {
                    if isFirstChunk { family += pendingSeparator }
                    family += chunk
                    versionIsOpen = false
                }
                pendingSeparator = ""
            }
            // A digit chunk followed by letters in the same token ("4o") closes that version.
            if let lastChunk = chunks.last, Int(lastChunk) == nil { versionIsOpen = false }
        }
        if !snapshot { family += trailingSeparator }

        self.family = family
        self.versions = versions
        self.isSnapshot = snapshot
        self.isPreview = preview
    }

    /// Compares two versions part by part; a missing part counts as 0 ("5" is "5.0").
    public static func compare(_ left: [Int], _ right: [Int]) -> Int {
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart < rightPart ? -1 : 1 }
        }
        return 0
    }
}

public enum ModelUpgrade {
    /// The newest id in `available` that is the same family as `current` at a higher version, or nil when `current` is
    /// already the newest there (or can't be read, or is pinned to a snapshot). Only the first version number may change:
    /// "qwen3-235b" may become "qwen4-235b", never "qwen4-30b".
    public static func newer(than current: String, in available: [String]) -> String? {
        guard let currentShape = ModelVersionShape(modelID: current), !currentShape.isSnapshot,
              let currentFirstVersion = currentShape.versions.first else { return nil }
        var best: (id: String, version: [Int])?
        for candidate in available where candidate.caseInsensitiveCompare(current) != .orderedSame {
            guard let candidateShape = ModelVersionShape(modelID: candidate),
                  candidateShape.family == currentShape.family,
                  !candidateShape.isSnapshot,
                  !candidateShape.isPreview || currentShape.isPreview,
                  candidateShape.versions.count == currentShape.versions.count,
                  Array(candidateShape.versions.dropFirst()) == Array(currentShape.versions.dropFirst()),
                  let candidateFirstVersion = candidateShape.versions.first,
                  ModelVersionShape.compare(candidateFirstVersion, currentFirstVersion) > 0 else { continue }
            if let chosen = best, ModelVersionShape.compare(candidateFirstVersion, chosen.version) <= 0 { continue }
            best = (candidate, candidateFirstVersion)
        }
        return best?.id
    }

    /// The same ids, each family's newest first, families in the order they first appear. Snapshots and previews of a
    /// family come after its plain versions.
    public static func newestFirst(_ ids: [String]) -> [String] {
        var familyOrder: [String] = []
        var membersByFamily: [String: [(id: String, shape: ModelVersionShape?, position: Int)]] = [:]
        for (position, id) in ids.enumerated() {
            let shape = ModelVersionShape(modelID: id)
            let familyKey = shape?.family ?? "\u{0}" + id
            if membersByFamily[familyKey] == nil { familyOrder.append(familyKey) }
            membersByFamily[familyKey, default: []].append((id, shape, position))
        }
        return familyOrder.flatMap { familyKey -> [String] in
            let members = membersByFamily[familyKey] ?? []
            return members.sorted { left, right in
                let leftPinned = (left.shape?.isSnapshot ?? false) || (left.shape?.isPreview ?? false)
                let rightPinned = (right.shape?.isSnapshot ?? false) || (right.shape?.isPreview ?? false)
                if leftPinned != rightPinned { return !leftPinned }
                let leftVersion = left.shape?.versions.first ?? []
                let rightVersion = right.shape?.versions.first ?? []
                let comparison = ModelVersionShape.compare(leftVersion, rightVersion)
                if comparison != 0 { return comparison > 0 }
                return left.position < right.position
            }.map(\.id)
        }
    }

    /// Only the newest plain version of each family that has one (snapshots and previews of an older version drop out
    /// too); ids that can't be read stay. Order as `newestFirst`.
    public static func newestOfEachFamily(_ ids: [String]) -> [String] {
        let ordered = newestFirst(ids)
        var newestVersionByFamily: [String: [Int]] = [:]
        for id in ordered {
            guard let shape = ModelVersionShape(modelID: id), !shape.isSnapshot, !shape.isPreview, let version = shape.versions.first else { continue }
            if let known = newestVersionByFamily[shape.family], ModelVersionShape.compare(known, version) >= 0 { continue }
            newestVersionByFamily[shape.family] = version
        }
        var seenFamilies = Set<String>()
        return ordered.filter { id in
            guard let shape = ModelVersionShape(modelID: id), let newest = newestVersionByFamily[shape.family] else { return true }
            guard !shape.isSnapshot, !shape.isPreview, let version = shape.versions.first,
                  ModelVersionShape.compare(version, newest) == 0 else { return false }
            return seenFamilies.insert(shape.family).inserted
        }
    }
}

public enum ModelListFilter {
    /// Words in ids that are never for chatting: embeddings, voices, listening, images, moderation, search indexes.
    static let notForChat = ["embed", "whisper", "tts", "dall-e", "image", "moderation", "audio", "transcribe", "rerank",
                             "realtime", "speech", "guard", "sora", "davinci", "babbage", "computer-use", "search"]

    public static func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return !notForChat.contains { lowered.contains($0) }
    }

    /// The chat models of a provider's list, without repeats, each family's newest first.
    public static func chatModels(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        let unique = ids.filter { isChatModel($0) && seen.insert($0).inserted }
        return ModelUpgrade.newestFirst(unique)
    }
}

public enum ClaudeFastMode {
    /// Whether fast mode runs on this Claude model: Opus 5 and newer, Fable and Mythos 5.2 and newer. Sonnet and Haiku
    /// never (Claude Code ignores the setting there). Opus 4.8's fast mode ends on 30 November 2026, so it isn't offered.
    public static func supports(model: String) -> Bool {
        let lowered = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "opus" || lowered == "fable" { return true }
        guard let shape = ModelVersionShape(modelID: lowered), !shape.isSnapshot, let version = shape.versions.first else { return false }
        let bareFamily = shape.family.split(separator: "/").last.map(String.init) ?? shape.family
        switch bareFamily {
        case "claude-opus-#": return ModelVersionShape.compare(version, [5]) >= 0
        case "claude-fable-#", "claude-mythos-#": return ModelVersionShape.compare(version, [5, 2]) >= 0
        default: return false
        }
    }
}

public enum ClaudeAliasProbe {
    /// Claude Code's aliases, each always meaning the newest model of its family for the CLI that's installed.
    public static let aliases = ["opus", "sonnet", "haiku", "fable"]

    /// The model id in Claude Code's first stream-json line (`{"type":"system","subtype":"init","model":"claude-…"}`).
    /// Nil for any other line, or a model that isn't a full Claude id.
    public static func modelID(fromStreamLine line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "system", object["subtype"] as? String == "init",
              let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              model.lowercased().hasPrefix("claude-") else { return nil }
        // "claude-opus-5-5[1m]" is the same model with a longer context window.
        if let bracket = model.firstIndex(of: "[") { return String(model[..<bracket]) }
        return model
    }
}

public enum ClaudeModelList {
    /// Claude model ids found on this Mac: Claude Code's aliases and an Anthropic key's live list.
    public static let discoveredKey = "v4.models.claudeDiscovered"

    public static func discovered(in store: UserDefaults = .standard) -> [String] {
        store.stringArray(forKey: discoveredKey) ?? []
    }

    /// Keeps the Claude ids among `ids` (the newest of each family, at most 40 in all). True when something new was learned.
    @discardableResult
    public static func remember(_ ids: [String], in store: UserDefaults = .standard) -> Bool {
        let claudeIDs = ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.lowercased().hasPrefix("claude-") && ModelListFilter.isChatModel($0) }
        guard !claudeIDs.isEmpty else { return false }
        let before = discovered(in: store)
        let merged = Array(ModelUpgrade.newestOfEachFamily(claudeIDs + before).prefix(40))
        guard Set(merged) != Set(before) else { return false }
        store.set(merged, forKey: discoveredKey)
        return true
    }

    static let familyOrder = ["opus", "sonnet", "haiku", "fable"]

    /// The Claude models to offer: the newest of each family from what's bundled and what was found, Opus, Sonnet,
    /// Haiku and Fable first, then any other family (Mythos for an organization that has it).
    public static func current(bundled: [String] = ClickyModels.bundledIdentifiers, discovered: [String]) -> [String] {
        let newest = ModelUpgrade.newestOfEachFamily(discovered + bundled)
        func rank(_ id: String) -> Int {
            familyOrder.firstIndex { id.lowercased().hasPrefix("claude-\($0)-") } ?? familyOrder.count
        }
        return newest.enumerated().sorted { left, right in
            let leftRank = rank(left.element)
            let rightRank = rank(right.element)
            return leftRank != rightRank ? leftRank < rightRank : left.offset < right.offset
        }.map(\.element)
    }

    /// The newest id of one family ("opus"), from what's bundled and what was found.
    public static func newest(family: String, discovered: [String]) -> String? {
        current(discovered: discovered).first { $0.lowercased().hasPrefix("claude-\(family.lowercased())-") }
    }

    /// "claude-opus-5-5" → "Opus 5.5"; "claude-fable-5-2" → "Fable 5.2".
    public static func shortLabel(for id: String) -> String {
        guard let shape = ModelVersionShape(modelID: id), let version = shape.versions.first,
              shape.family.hasPrefix("claude-") else { return id }
        let familyName = shape.family.dropFirst("claude-".count).replacingOccurrences(of: "-#", with: "")
            .split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return "\(familyName) \(version.map(String.init).joined(separator: "."))"
    }
}

public enum ModelAutoUpgrade {
    /// The owner's switch: move bots and Vello's own choices onto the newest model of the same family (default on).
    public static let enabledKey = "v4.models.autoUpgrade"
    /// What was moved, newest first: "Researcher: Claude Sonnet 5 → Claude Sonnet 5.5".
    public static let historyKey = "v4.models.upgradeHistory"
    public static let lastCheckKey = "v4.models.lastFreshnessCheck"

    public static func isOn(in store: UserDefaults = .standard) -> Bool {
        store.object(forKey: enabledKey) == nil ? true : store.bool(forKey: enabledKey)
    }

    public static func setOn(_ isOn: Bool, in store: UserDefaults = .standard) {
        store.set(isOn, forKey: enabledKey)
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var at: Date
        public var line: String
        public init(at: Date, line: String) {
            self.at = at
            self.line = line
        }
    }

    public static func history(in store: UserDefaults = .standard) -> [Entry] {
        guard let data = store.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Adds lines to the front of the record, keeping the last 30.
    public static func record(_ lines: [String], at date: Date = Date(), in store: UserDefaults = .standard) {
        guard !lines.isEmpty else { return }
        let entries = lines.map { Entry(at: date, line: $0) } + history(in: store)
        store.set(try? JSONEncoder().encode(Array(entries.prefix(30))), forKey: historyKey)
    }

    /// A check is due when none ran in the last `interval` seconds (12 hours by default).
    public static func isCheckDue(now: Date = Date(), interval: TimeInterval = 12 * 3600, in store: UserDefaults = .standard) -> Bool {
        guard let last = store.object(forKey: lastCheckKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= interval || now < last
    }
}
