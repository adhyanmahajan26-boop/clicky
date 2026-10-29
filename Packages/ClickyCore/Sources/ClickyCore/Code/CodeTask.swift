//
//  CodeTask.swift
//  ClickyCore
//
//  The `<codetask>` JSON block Claude emits when the user asks by voice for
//  repo work (P5 Code mode). Decoding is strict: an unknown key, a missing
//  required key or an unknown action fails, so a malformed or injected
//  block never turns into an outward action by accident. `flow` says how
//  the app runs it: a read-only agent, an editing agent in a worktree, or
//  the review panel alone (Clicky acts outward only after a real click).
//

import Foundation

public struct CodeTask: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case inspect
        case summarize
        case draftReview = "draft_review"
        case fixReview = "fix_review"
        case fixCI = "fix_ci"
        case edit
        case resolveConflicts = "resolve_conflicts"
        case comment
        case review
        case merge
        case updateBranch = "update_branch"
        case editMeta = "edit_meta"
        case askRepo = "ask_repo"
        case repoChange = "repo_change"
    }

    public enum Flow: String, Sendable {
        /// Agent with Read/Grep/Glob only; nothing is written.
        case readOnlyAgent
        /// Agent edits a git worktree; outward steps go through the panel.
        case editingAgent
        /// No agent: the review panel shows the action and Clicky runs it.
        case panelOnly
    }

    public enum MergeMethod: String, Codable, Sendable {
        case merge
        case squash
        case rebase
    }

    public enum Delivery: String, Codable, Sendable {
        case local
        case branch
        case pr
    }

    public struct Meta: Codable, Equatable, Sendable {
        public var title: String?
        public var body: String?
        public var labels: [String]?

        public init(title: String? = nil, body: String? = nil, labels: [String]? = nil) {
            self.title = title
            self.body = body
            self.labels = labels
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case title, body, labels
        }

        public init(from decoder: Decoder) throws {
            try CodeTask.rejectUnknownKeys(in: decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            body = try container.decodeIfPresent(String.self, forKey: .body)
            labels = try container.decodeIfPresent([String].self, forKey: .labels)
        }
    }

    public var action: Action
    public var repo: String
    public var instructions: String
    public var pr: Int?
    public var threads: [String]?
    public var body: String?
    /// Review event, e.g. APPROVE / REQUEST_CHANGES / COMMENT.
    public var event: String?
    public var method: MergeMethod?
    public var meta: Meta?
    public var base: String?
    public var deliver: Delivery?

    public init(action: Action, repo: String, instructions: String, pr: Int? = nil, threads: [String]? = nil, body: String? = nil, event: String? = nil, method: MergeMethod? = nil, meta: Meta? = nil, base: String? = nil, deliver: Delivery? = nil) {
        self.action = action
        self.repo = repo
        self.instructions = instructions
        self.pr = pr
        self.threads = threads
        self.body = body
        self.event = event
        self.method = method
        self.meta = meta
        self.base = base
        self.deliver = deliver
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case action, repo, instructions, pr, threads, body, event, method, meta, base, deliver
    }

    public init(from decoder: Decoder) throws {
        try CodeTask.rejectUnknownKeys(in: decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Action.self, forKey: .action)
        repo = try container.decode(String.self, forKey: .repo)
        instructions = try container.decode(String.self, forKey: .instructions)
        pr = try container.decodeIfPresent(Int.self, forKey: .pr)
        threads = try container.decodeIfPresent([String].self, forKey: .threads)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        method = try container.decodeIfPresent(MergeMethod.self, forKey: .method)
        meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
        base = try container.decodeIfPresent(String.self, forKey: .base)
        deliver = try container.decodeIfPresent(Delivery.self, forKey: .deliver)
    }

    /// Decodes the body of a `<codetask>` block (surrounding whitespace allowed).
    public static func decode(blockBody: String) throws -> CodeTask {
        let trimmedBody = blockBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return try JSONDecoder().decode(CodeTask.self, from: Data(trimmedBody.utf8))
    }

    public var flow: Flow { action.flow }

    // MARK: - Strictness

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    fileprivate static func rejectUnknownKeys(in decoder: Decoder, allowed allowedKeys: Set<String>) throws {
        let anyKeyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        for presentKey in anyKeyContainer.allKeys where !allowedKeys.contains(presentKey.stringValue) {
            throw DecodingError.dataCorruptedError(forKey: presentKey, in: anyKeyContainer, debugDescription: "Unknown key \"\(presentKey.stringValue)\" in codetask")
        }
    }
}

extension CodeTask.Action {
    public var flow: CodeTask.Flow {
        switch self {
        case .inspect, .summarize, .draftReview, .askRepo:
            return .readOnlyAgent
        case .fixReview, .fixCI, .edit, .resolveConflicts, .repoChange:
            return .editingAgent
        case .comment, .review, .merge, .updateBranch, .editMeta:
            return .panelOnly
        }
    }
}
