//
//  HarnessChatFiles.swift
//  ClickyCore
//
//  What chats a coding harness already has in a folder, read from where that harness keeps them, so a run can carry on in one rather than
//  start a new one. Every format here was checked on the owner's Macs; the parsers take the harness's own text so they can be tested.
//

import CryptoKit
import Foundation

/// One existing chat of a harness in a folder.
public struct HarnessChat: Codable, Equatable, Identifiable, Sendable {
    /// What the harness resumes it by.
    public var id: String
    public var title: String
    public var updatedAt: Date

    public init(id: String, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// A chat to carry on: picked from the menu, or named by a bot by id or title.
public struct HarnessChatChoice: Equatable, Sendable {
    public var idOrTitle: String
    /// Its title, when it was picked from a list.
    public var title: String?

    public init(idOrTitle: String, title: String? = nil) {
        self.idOrTitle = idOrTitle
        self.title = title
    }

    /// The chat this means, out of the ones in the folder: by id, then by the words of its title.
    public func match(in chats: [HarnessChat]) -> HarnessChat? {
        let wanted = idOrTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = chats.first(where: { $0.id == wanted }) { return exact }
        let lowered = wanted.lowercased()
        return chats.first { $0.title.lowercased() == lowered } ?? chats.first { $0.title.lowercased().contains(lowered) && !lowered.isEmpty }
    }
}

public enum HarnessChatText {
    /// A chat's title in the menu: its first words, without what Theo adds to a prompt or markup.
    public static func title(from text: String, limit: Int = 60) -> String? {
        var lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Theo's own opening for a run in a worktree says nothing about the chat.
        if lines.first?.hasPrefix("You are already in a git worktree") == true { lines.removeFirst() }
        guard var line = lines.first(where: { !$0.hasPrefix("<") && !$0.hasPrefix("[") && !$0.hasPrefix("(") }) else { return nil }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : line
    }

    /// "5m", "3h", "2d", for the menu.
    public static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

public enum HarnessChatFiles {
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return isoFractional.date(from: text) ?? iso.date(from: text)
    }

    private static func object(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    // MARK: T3 Code

    /// `<T3 home>/userdata/server-runtime.json`: the pid of the server that's up. Asking the CLI anything with no server up makes it write
    /// a database and a signing key into its folder, and that folder belongs to T3 Code, so nothing asks without checking this first.
    public static func t3ServerPID(runtimeJSON: String?) -> Int32? {
        guard let runtimeJSON, let runtime = object(runtimeJSON), let pid = runtime["pid"] as? Int else { return nil }
        return Int32(pid)
    }

    /// `t3 thread list --project <folder> --json`: an array, or an object holding "threads".
    public static func t3Threads(json: String) -> [HarnessChat] {
        guard let start = json.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let parsed = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) else { return [] }
        let items = (parsed as? [[String: Any]]) ?? ((parsed as? [String: Any])?["threads"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let id = (item["threadId"] ?? item["id"]) as? String else { return nil }
            let when = date(item["updatedAt"] as? String) ?? date(item["settledAt"] as? String) ?? date(item["createdAt"] as? String) ?? .distantPast
            let title = (item["title"] as? String).flatMap { HarnessChatText.title(from: $0) } ?? "Untitled thread"
            return HarnessChat(id: id, title: title, updatedAt: when)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Claude Code

    /// ~/.claude/projects/<this>: the folder's path with everything but letters and digits as "-". A path over 200 characters is cut there,
    /// with a hash after it, so `claudeFolderPrefix` finds that one. Different folders can share a name, so a session's own cwd decides.
    public static func claudeFolderName(for path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    public static let claudeFolderNameLimit = 200

    /// A session file's lines, from its start and its end, for this folder. Its given title if it has one, else its first real message from the owner.
    /// Nil for another folder's session, or one with nothing said in it.
    public static func claudeSession(id: String, lines: [String], folders: Set<String>? = nil, modifiedAt: Date) -> HarnessChat? {
        var custom: String?
        var aiTitle: String?
        var summary: String?
        var lastPrompt: String?
        var firstAsked: String?
        var cwd: String?
        var hasConversation = false
        for line in lines {
            guard let event = object(line), let type = event["type"] as? String else { continue }
            if cwd == nil, let there = event["cwd"] as? String { cwd = (event["relocatedCwd"] as? String) ?? there }
            switch type {
            case "custom-title": custom = (event["customTitle"] as? String) ?? custom
            case "ai-title": aiTitle = (event["aiTitle"] as? String) ?? aiTitle
            case "summary": summary = (event["summary"] as? String) ?? summary
            case "last-prompt": lastPrompt = (event["lastPrompt"] as? String) ?? lastPrompt
            case "user":
                hasConversation = true
                if firstAsked == nil, event["isMeta"] as? Bool != true, event["isSidechain"] as? Bool != true, let message = event["message"] as? [String: Any] {
                    firstAsked = textOfClaudeContent(message["content"]).flatMap { HarnessChatText.title(from: $0) }
                }
            case "assistant": hasConversation = true
            default: break
            }
        }
        guard hasConversation else { return nil }
        if let folders, let cwd, !folders.contains(cwd) { return nil }
        let given = [custom, aiTitle, summary].compactMap { $0 }.first.flatMap { HarnessChatText.title(from: $0) }
        return HarnessChat(id: id, title: given ?? firstAsked ?? lastPrompt.flatMap { HarnessChatText.title(from: $0) } ?? "Untitled chat", updatedAt: modifiedAt)
    }

    private static func textOfClaudeContent(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        return blocks.first { $0["type"] as? String == "text" }?["text"] as? String
    }

    // MARK: Codex

    /// A rollout file's first line: which folder it's in, and its id.
    public static func codexMeta(firstLine: String) -> (id: String, cwd: String, startedAt: Date?)? {
        guard let event = object(firstLine), let payload = event["payload"] as? [String: Any], let cwd = payload["cwd"] as? String,
              let id = (payload["id"] ?? payload["session_id"]) as? String else { return nil }
        return (id, cwd, date(payload["timestamp"] as? String) ?? date(event["timestamp"] as? String))
    }

    /// ~/.codex/session_index.jsonl: the names Codex gave its threads. A later line wins.
    public static func codexTitles(indexLines: [String]) -> [String: String] {
        var titles: [String: String] = [:]
        for line in indexLines {
            if let entry = object(line), let id = entry["id"] as? String, let name = entry["thread_name"] as? String, !name.isEmpty { titles[id] = name }
        }
        return titles
    }

    /// The first thing asked in a rollout, for a thread with no name.
    public static func codexFirstAsk(lines: [String]) -> String? {
        for line in lines {
            guard let event = object(line), let payload = event["payload"] as? [String: Any] else { continue }
            if event["type"] as? String == "event_msg", payload["type"] as? String == "user_message", let text = payload["message"] as? String {
                return HarnessChatText.title(from: text)
            }
            // The owner's own words, not the environment Codex describes first.
            if event["type"] as? String == "response_item", payload["role"] as? String == "user",
               let meta = payload["internal_chat_message_metadata_passthrough"] as? [String: Any], (meta["content_item_kinds"] as? [String])?.contains("user.text") == true,
               let blocks = payload["content"] as? [[String: Any]], let text = blocks.compactMap({ $0["text"] as? String }).first {
                return HarnessChatText.title(from: text)
            }
        }
        return nil
    }

    /// The rows of ~/.codex/state_*.sqlite's `threads`, as sqlite3's -json prints them. Codex's own list, and the quickest.
    public static func codexThreads(sqliteJSON: String) -> [HarnessChat] {
        rows(sqliteJSON).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let title = (row["title"] as? String).flatMap { HarnessChatText.title(from: $0) } ?? (row["first_user_message"] as? String).flatMap { HarnessChatText.title(from: $0) } ?? "Untitled chat"
            let updated = (row["updated_at_ms"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            return HarnessChat(id: id, title: title, updatedAt: updated)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func rows(_ json: String) -> [[String: Any]] {
        guard let start = json.firstIndex(of: "[") else { return [] }
        return ((try? JSONSerialization.jsonObject(with: Data(json[start...].utf8))) as? [[String: Any]]) ?? []
    }

    /// One quoted value for a sqlite3 command line, which has no bound parameters.
    public static func sqliteQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    // MARK: Cursor

    /// ~/.cursor/chats/<this>/<chat id>: the MD5 of the folder's path.
    public static func cursorFolderName(for path: String) -> String {
        Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A chat's meta.json. Nil for one with no conversation in it. `firstPrompt`: from its prompt_history.json, for one with no title.
    public static func cursorChat(id: String, metaJSON: String, firstPrompt: String? = nil, modifiedAt: Date) -> HarnessChat? {
        guard let meta = object(metaJSON), meta["hasConversation"] as? Bool != false, meta["isSubagent"] as? Bool != true else { return nil }
        let updated = (meta["updatedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? modifiedAt
        let title = (meta["title"] as? String).flatMap { HarnessChatText.title(from: $0) } ?? firstPrompt.flatMap { HarnessChatText.title(from: $0) } ?? "Untitled chat"
        return HarnessChat(id: id, title: title, updatedAt: updated)
    }

    /// Older chats have no meta.json: `store.db`'s meta row holds the same as hex-encoded JSON. It also holds the chat's encryption key:
    /// only the name is read from it, and nothing from it is ever logged.
    public static func cursorChat(id: String, storeMetaHex: String, modifiedAt: Date) -> HarnessChat? {
        let hex = storeMetaHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let meta = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return nil }
        let title = (meta["name"] as? String).flatMap { HarnessChatText.title(from: $0) } ?? "Untitled chat"
        return HarnessChat(id: id, title: title, updatedAt: modifiedAt)
    }

    // MARK: OpenCode

    /// `opencode session list --format json`, which lists every folder's: only this one's come back.
    public static func openCodeSessions(json: String, folder: String) -> [HarnessChat] {
        rows(json).compactMap { item in
            guard let id = item["id"] as? String, item["directory"] as? String == folder else { return nil }
            let updated = ((item["updated"] ?? item["created"]) as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            return HarnessChat(id: id, title: (item["title"] as? String).flatMap { HarnessChatText.title(from: $0) } ?? "Untitled chat", updatedAt: updated)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The rows of opencode.db's `session` for one folder, as sqlite3's -json prints them. Reading these writes nothing, unlike its CLI.
    public static func openCodeRows(sqliteJSON: String) -> [HarnessChat] {
        rows(sqliteJSON).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let updated = (row["time_updated"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            return HarnessChat(id: id, title: (row["title"] as? String).flatMap { HarnessChatText.title(from: $0) } ?? "Untitled chat", updatedAt: updated)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Gemini

    /// ~/.gemini/projects.json: the folder its chats are kept under, for this path. Nil when Gemini hasn't been used there.
    public static func geminiSlug(projectsJSON: String?, folder: String) -> String? {
        guard let projectsJSON, let top = object(projectsJSON), let projects = top["projects"] as? [String: String] else { return nil }
        return projects[folder]
    }

    /// One chat file in ~/.gemini/tmp/<slug>/chats: JSON lines whose first holds the metadata, or an older single JSON object.
    /// Its `sessionId` is what --resume takes. Gemini's own --list-sessions isn't used: it can spend a model call, and it writes.
    public static func geminiChat(fileText: String, modifiedAt: Date) -> HarnessChat? {
        var sessionID: String?
        var summary: String?
        var firstAsked: String?
        var lastUpdated: Date?
        var isSubagent = false
        func read(_ event: [String: Any]) {
            if sessionID == nil { sessionID = event["sessionId"] as? String }
            if let said = event["summary"] as? String, !said.isEmpty { summary = said }
            if let updated = date(event["lastUpdated"] as? String) { lastUpdated = updated }
            if event["kind"] as? String == "subagent" { isSubagent = true }
            if firstAsked == nil, event["type"] as? String == "user" { firstAsked = geminiText(event["content"]).flatMap { HarnessChatText.title(from: $0) } }
        }
        if let whole = (try? JSONSerialization.jsonObject(with: Data(fileText.utf8))) as? [String: Any] {
            read(whole)
            for message in whole["messages"] as? [[String: Any]] ?? [] { read(message) }
        } else {
            for line in fileText.components(separatedBy: "\n") {
                if let event = object(line) { read(event) }
            }
        }
        guard let sessionID, !isSubagent, firstAsked != nil || summary != nil else { return nil }
        let title = summary.flatMap { HarnessChatText.title(from: $0) } ?? firstAsked ?? "Untitled chat"
        return HarnessChat(id: sessionID, title: title, updatedAt: lastUpdated ?? modifiedAt)
    }

    private static func geminiText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        return (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.first
    }

    // MARK: Grok

    /// ~/.grok/sessions/<this>/<session id>: the folder's path, percent-encoded.
    public static func grokFolderName(for path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// A session's summary.json. Its generated title, else the first thing asked in it.
    public static func grokChat(id: String, summaryJSON: String?, firstPrompt: String?, modifiedAt: Date) -> HarnessChat? {
        let summary = summaryJSON.flatMap(object)
        if summary?["session_kind"] as? String == "subagent" { return nil }
        let given = (summary?["generated_title"] as? String) ?? (summary?["session_summary"] as? String)
        guard let title = given.flatMap({ HarnessChatText.title(from: $0) }) ?? firstPrompt.flatMap({ HarnessChatText.title(from: $0) }) else { return nil }
        let updated = date(summary?["last_active_at"] as? String) ?? date(summary?["updated_at"] as? String) ?? modifiedAt
        return HarnessChat(id: id, title: title, updatedAt: updated)
    }

    /// prompt_history.jsonl in that folder: the first thing asked in each session.
    public static func grokFirstPrompts(historyLines: [String]) -> [String: String] {
        var first: [String: String] = [:]
        for line in historyLines {
            if let entry = object(line), let id = entry["session_id"] as? String, first[id] == nil, let prompt = entry["prompt"] as? String { first[id] = prompt }
        }
        return first
    }
}
