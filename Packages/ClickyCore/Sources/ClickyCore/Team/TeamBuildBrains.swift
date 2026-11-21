//
//  TeamBuildBrains.swift
//  ClickyCore
//
//  Which brain and model a bot made (or changed) from a ```team block runs on, from the words in the block ("haiku",
//  "Claude Opus 5.5", "Codex") and the brains set up on this computer. Pure: the app's `BotsStore.buildTeamFromChat`
//  passes the brains it can use. The Windows and Linux app has the same rules in `team_build.rs` (`pick_brain`).
//

import Foundation

public enum TeamBuildBrains {
    /// One model a brain offers, by its id and the name people see.
    public struct Model: Equatable, Sendable {
        public var id: String
        public var label: String
        public init(id: String, label: String? = nil) {
            self.id = id
            self.label = label ?? id
        }
    }

    /// A brain a bot can run on here: an engine id ("claude", "codex", "api:openai"), its name and its models (empty when
    /// Vello can't list them, as with most agents).
    public struct Brain: Equatable, Sendable {
        public var engine: String
        public var label: String
        public var models: [Model]
        public init(engine: String, label: String, models: [Model] = []) {
            self.engine = engine
            self.label = label
            self.models = models
        }
    }

    /// The choice for one bot. `model` nil: the brain's usual starting model (or, for a bot that exists, the one it has).
    /// `trouble` says in a few words why something asked for couldn't be used, for Vello's note.
    public struct Pick: Equatable, Sendable {
        public var engine: String
        public var model: String?
        public var trouble: String?
        public init(engine: String, model: String? = nil, trouble: String? = nil) {
            self.engine = engine
            self.model = model
            self.trouble = trouble
        }
    }

    /// `brains` in the order to try them (the maker's own first). A brain that's asked for and isn't set up here is said
    /// and the maker's is used; a model is looked for on the asked brain, else on the maker's, else on any brain here.
    public static func pick(brain askedBrain: String?, model askedModel: String?, makerEngine: String, among brains: [Brain]) -> Pick {
        var trouble: String?
        var engine = makerEngine
        if let askedBrain {
            if let found = matchBrain(askedBrain, among: brains) {
                engine = found.engine
            } else {
                trouble = "there's no brain called \(askedBrain) set up here"
            }
        }
        guard let askedModel else { return Pick(engine: engine, trouble: trouble) }

        let chosen = brains.first { $0.engine == engine }
        if let chosen, let model = matchModel(askedModel, among: chosen.models) {
            return Pick(engine: engine, model: model.id, trouble: trouble)
        }
        // A brain whose models Vello can't list (most agents) takes an exact model id as it is.
        let chosenTakesIDs = (chosen?.models.isEmpty ?? true) && looksLikeModelID(askedModel)
        // No brain was named: another brain here with that model will do, in order. An exact id that the maker's own
        // brain takes as it is stays there ("gpt-6" for a bot made by a Codex CEO), but words ("opus") move.
        if askedBrain == nil {
            for other in brains where other.engine != engine {
                guard let model = matchModel(askedModel, among: other.models) else { continue }
                if chosenTakesIDs && model.id.lowercased() == askedModel.trimmingCharacters(in: .whitespaces).lowercased() { continue }
                return Pick(engine: other.engine, model: model.id)
            }
        }
        if chosenTakesIDs {
            return Pick(engine: engine, model: askedModel, trouble: trouble)
        }
        let brainName = chosen?.label ?? engine
        let modelTrouble = "\(brainName) has no model called \(askedModel)"
        return Pick(engine: engine, trouble: trouble.map { $0 + ", and " + modelTrouble } ?? modelTrouble)
    }

    /// The model `asked` names: its exact id, else the first whose id or name holds the asked words in order ("haiku",
    /// "opus 5.5", "Claude Sonnet").
    public static func matchModel(_ asked: String, among models: [Model]) -> Model? {
        let exact = asked.trimmingCharacters(in: .whitespaces).lowercased()
        if let model = models.first(where: { $0.id.lowercased() == exact }) { return model }
        let wanted = words(of: asked)
        guard !wanted.isEmpty else { return nil }
        return models.first { holdsInOrder(words(of: $0.id), wanted) || holdsInOrder(words(of: $0.label), wanted) }
    }

    /// The brain `asked` names, by its engine id or the words of its name ("Claude Code", "codex", "OpenAI").
    public static func matchBrain(_ asked: String, among brains: [Brain]) -> Brain? {
        let exact = asked.trimmingCharacters(in: .whitespaces).lowercased()
        if let brain = brains.first(where: { $0.engine.lowercased() == exact }) { return brain }
        let wanted = words(of: asked).filter { !fillerBrainWords.contains($0) }
        guard !wanted.isEmpty else { return nil }
        return brains.first { brain in
            let named = Set(words(of: brain.engine) + words(of: brain.label))
            return wanted.allSatisfy(named.contains)
        }
    }

    /// An exact model id rather than words: no spaces, only the characters ids use.
    public static func looksLikeModelID(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:"))
        return trimmed.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Words that don't tell brains apart: "Claude Code" and "Claude" are the same ask.
    static let fillerBrainWords: Set<String> = ["code", "cli", "agent", "api", "key", "the", "app"]

    /// "Claude Opus 5.5" → ["claude", "opus", "5", "5"]; letters and digits apart, so "gpt5" is ["gpt", "5"].
    static func words(of text: String) -> [String] {
        var found: [String] = []
        var current = ""
        var currentIsDigits = false
        for character in text.lowercased() {
            let isLetter = character.isLetter && character.isASCII
            let isDigit = character.isNumber && character.isASCII
            if !isLetter && !isDigit {
                if !current.isEmpty { found.append(current); current = "" }
                continue
            }
            if !current.isEmpty && currentIsDigits != isDigit { found.append(current); current = "" }
            current.append(character)
            currentIsDigits = isDigit
        }
        if !current.isEmpty { found.append(current) }
        return found
    }

    /// Whether every word of `wanted` is in `words`, in that order (others may come between).
    static func holdsInOrder(_ words: [String], _ wanted: [String]) -> Bool {
        var next = 0
        for word in words where next < wanted.count && word == wanted[next] { next += 1 }
        return next == wanted.count
    }
}
