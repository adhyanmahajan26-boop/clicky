//
//  ProjectBridgeFiles.swift
//  ClickyCore
//
//  The two files of the project bridge.
//
//  Outbox (Clicky writes): ~/.clicky/project-outbox/<yyyyMMdd-HHmmss>-<uuid>.json,
//  written to a dot-prefixed `.tmp` file in the same folder and renamed, so
//  the coordinator never reads half a file. Exactly these keys, nil as null:
//    {"id": "<uuid>", "createdAt": "<ISO8601>", "transcript": "<task text>",
//     "frontApp": {"bundleId": …, "name": …}, "frontWindowTitle": … | null,
//     "repoRoot": "<git root>" | null, "cursorDisplay": {"id": …, "name": …} | null}
//  No screenshots, file contents, tokens or anything else.
//
//  Inbox (the coordinator writes): ~/.clicky/project-inbox/<id>.json,
//    {"id": "<uuid>", "status": "received" | "thread_started" | "done" | "failed",
//     "note": "…"?, "link": "https://…"?}
//  Files over 16 KB, malformed JSON, an unknown status or an id that doesn't
//  match the file name are ignored. The note is display/speak text only
//  (one line, at most 120 characters); nothing in it is ever followed. A
//  link is shown, never opened.
//

import Foundation

// MARK: - Outbox

public struct ProjectOutboxMessage: Codable, Equatable, Sendable {
    public struct FrontApp: Codable, Equatable, Sendable {
        public var bundleId: String?
        public var name: String?

        public init(bundleId: String?, name: String?) {
            self.bundleId = bundleId
            self.name = name
        }

        private enum CodingKeys: String, CodingKey { case bundleId, name }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(bundleId, forKey: .bundleId)
            try container.encode(name, forKey: .name)
        }
    }

    public struct CursorDisplay: Codable, Equatable, Sendable {
        /// CGDirectDisplayID.
        public var id: UInt32?
        public var name: String?

        public init(id: UInt32?, name: String?) {
            self.id = id
            self.name = name
        }

        private enum CodingKeys: String, CodingKey { case id, name }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
        }
    }

    public static let maximumTranscriptLength = 4000
    public static let maximumWindowTitleLength = 300

    public var id: String
    public var createdAt: String
    public var transcript: String
    public var frontApp: FrontApp
    public var frontWindowTitle: String?
    public var repoRoot: String?
    public var cursorDisplay: CursorDisplay?

    /// Long transcripts and titles are cut; an empty title is nil.
    public init(id: String = UUID().uuidString.lowercased(), createdAt: Date = Date(), transcript: String, frontApp: FrontApp,
                frontWindowTitle: String?, repoRoot: String?, cursorDisplay: CursorDisplay?) {
        self.id = id
        self.createdAt = Self.iso8601String(from: createdAt)
        self.transcript = String(transcript.prefix(Self.maximumTranscriptLength))
        self.frontApp = frontApp
        let trimmedTitle = frontWindowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.frontWindowTitle = trimmedTitle.isEmpty ? nil : String(trimmedTitle.prefix(Self.maximumWindowTitleLength))
        self.repoRoot = repoRoot
        self.cursorDisplay = cursorDisplay
    }

    static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, transcript, frontApp, frontWindowTitle, repoRoot, cursorDisplay
    }

    /// Every key always written (nil as null), so the coordinator sees one fixed shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(frontApp, forKey: .frontApp)
        try container.encode(frontWindowTitle, forKey: .frontWindowTitle)
        try container.encode(repoRoot, forKey: .repoRoot)
        try container.encode(cursorDisplay, forKey: .cursorDisplay)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The front window's git root only when it was found and isn't one of
    /// Clicky's own checkouts.
    public static func repoRoot(from resolution: FrontWindowRepoResolution, homeDirectory: String = NSHomeDirectory(),
                                fileSystem: RepoFileSystem = .live) -> String? {
        guard case .found(let rootPath, _) = resolution else { return nil }
        return CodeRepoDenylist.isDeniedLocalRoot(rootPath, homeDirectory: homeDirectory, fileSystem: fileSystem) ? nil : rootPath
    }
}

public enum ProjectOutbox {
    public static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/project-outbox", isDirectory: true)
    }

    /// "20261025-142233-<uuid>.json" (local time).
    public static func fileName(for message: ProjectOutboxMessage, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: date))-\(message.id).json"
    }

    /// Writes the message into `directoryURL` (made 0700 if missing) through a
    /// temp file and a rename. Returns the final file's URL.
    @discardableResult
    public static func write(_ message: ProjectOutboxMessage, date: Date = Date(), to directoryURL: URL = defaultDirectoryURL,
                             timeZone: TimeZone = .current) throws -> URL {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let finalFileName = fileName(for: message, date: date, timeZone: timeZone)
        let finalFileURL = directoryURL.appendingPathComponent(finalFileName)
        // Dot-prefixed and .tmp, so a watcher looking for *.json skips it.
        let temporaryFileURL = directoryURL.appendingPathComponent(".\(finalFileName).tmp")
        let messageData = try message.encoded()
        do {
            try messageData.write(to: temporaryFileURL)
            try fileManager.moveItem(at: temporaryFileURL, to: finalFileURL)
        } catch {
            try? fileManager.removeItem(at: temporaryFileURL)
            throw error
        }
        return finalFileURL
    }
}

// MARK: - Inbox

public enum ProjectReplyStatus: String, Codable, CaseIterable, Sendable {
    case received
    case threadStarted = "thread_started"
    case done
    case failed
}

public struct ProjectInboxReply: Equatable, Sendable {
    public var id: String
    public var status: ProjectReplyStatus
    public var note: String?
    public var link: String?

    public init(id: String, status: ProjectReplyStatus, note: String? = nil, link: String? = nil) {
        self.id = id
        self.status = status
        self.note = note
        self.link = link
    }
}

public enum ProjectInbox {
    public static let maximumFileBytes = 16 * 1024
    public static let maximumNoteLength = 120
    static let maximumLinkLength = 2048

    public static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/project-inbox", isDirectory: true)
    }

    /// One reply file's contents. Nil for anything oversized, malformed, with
    /// an unknown status, a non-UUID id, or (with `expectedID`) another task's id.
    public static func parse(_ data: Data, expectedID: String? = nil) -> ProjectInboxReply? {
        guard data.count <= maximumFileBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, UUID(uuidString: id) != nil,
              let statusText = object["status"] as? String, let status = ProjectReplyStatus(rawValue: statusText.lowercased()) else { return nil }
        if let expectedID, id.lowercased() != expectedID.lowercased() { return nil }
        return ProjectInboxReply(id: id.lowercased(), status: status, note: sanitizedNote(object["note"] as? String), link: sanitizedLink(object["link"] as? String))
    }

    /// `<directory>/<taskID>.json` when it exists, is a regular file under
    /// 16 KB and parses. The size is checked before anything is read.
    public static func readReply(forTaskID taskID: String, in directoryURL: URL = defaultDirectoryURL) -> ProjectInboxReply? {
        let replyFileURL = directoryURL.appendingPathComponent("\(taskID).json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: replyFileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = (attributes[.size] as? NSNumber)?.intValue, fileSize <= maximumFileBytes,
              let replyData = try? Data(contentsOf: replyFileURL) else { return nil }
        return parse(replyData, expectedID: taskID)
    }

    /// The reply file's modification date (to skip files that haven't changed).
    public static func modificationDate(forTaskID taskID: String, in directoryURL: URL = defaultDirectoryURL) -> Date? {
        let replyFileURL = directoryURL.appendingPathComponent("\(taskID).json")
        return (try? FileManager.default.attributesOfItem(atPath: replyFileURL.path))?[.modificationDate] as? Date
    }

    /// One line, control characters removed, at most 120 characters. Nil when empty.
    static func sanitizedNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let printableScalars = note.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
        }
        let oneLine = String(printableScalars).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !oneLine.isEmpty else { return nil }
        return oneLine.count > maximumNoteLength ? String(oneLine.prefix(maximumNoteLength - 1)) + "…" : oneLine
    }

    /// An http(s) URL without spaces, else nil. Shown as text; never opened.
    static func sanitizedLink(_ link: String?) -> String? {
        guard let link = link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty, link.count <= maximumLinkLength,
              link.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return link
    }
}

// MARK: - Task phases and what Clicky says

/// A project task's phase in the Agents dashboard (its record's `phase`).
public enum ProjectTaskPhase: String, Codable, CaseIterable, Sendable {
    /// Written to the outbox, no reply yet.
    case queued
    case received
    case threadStarted
    case done
    case failed

    public init(_ replyStatus: ProjectReplyStatus) {
        switch replyStatus {
        case .received: self = .received
        case .threadStarted: self = .threadStarted
        case .done: self = .done
        case .failed: self = .failed
        }
    }

    /// Phases only move forward; done and failed are both last.
    var rank: Int {
        switch self {
        case .queued: return 0
        case .received: return 1
        case .threadStarted: return 2
        case .done, .failed: return 3
        }
    }

    public var agentStatus: AgentStatus {
        switch self {
        case .queued: return .queued
        case .received, .threadStarted: return .running
        case .done: return .done
        case .failed: return .failed
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return "Sent"
        case .received: return "Received"
        case .threadStarted: return "Thread started"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    /// The collapsed notch status shown for a few seconds after the change.
    public var notchStatusText: String {
        switch self {
        case .queued: return "sent to project"
        case .received: return "project got it"
        case .threadStarted: return "project: thread started"
        case .done: return "project: done"
        case .failed: return "project: failed"
        }
    }
}

public enum ProjectUpdateSpeech {
    public static let sentLine = "Sent to your project."
    public static let askForTaskLine = "What should I send to your project?"
    public static let couldNotWriteLine = "I couldn't send that to your project."

    /// What Clicky says when a task reaches `phase`. "received" is silent
    /// (it comes right after "Sent to your project.").
    public static func line(for phase: ProjectTaskPhase, note: String?) -> String? {
        switch phase {
        case .queued, .received: return nil
        case .threadStarted: return "Your project started a thread for that."
        case .done: return "Your project finished that task."
        case .failed:
            guard let note = ProjectInbox.sanitizedNote(note) else { return "Your project couldn't do that." }
            return "Your project couldn't do that: \(note)"
        }
    }
}

/// Spoken updates: at most once per task per phase, never while Clicky is
/// mid-answer (they wait until it's idle), none at all with the setting off.
public struct ProjectSpokenUpdateQueue: Equatable, Sendable {
    public struct PendingLine: Equatable, Sendable {
        public var taskID: String
        public var phase: ProjectTaskPhase
        public var text: String
    }

    private var announcedKeys: Set<String> = []
    public private(set) var pendingLines: [PendingLine] = []

    public init() {}

    /// Queues the line for a phase change. False (nothing queued) when the
    /// phase was already announced, it has no line, or speaking is off.
    @discardableResult
    public mutating func noteChange(taskID: String, phase: ProjectTaskPhase, note: String?, speaksUpdates: Bool) -> Bool {
        let key = "\(taskID)|\(phase.rawValue)"
        guard speaksUpdates, !announcedKeys.contains(key), let text = ProjectUpdateSpeech.line(for: phase, note: note) else { return false }
        announcedKeys.insert(key)
        pendingLines.append(PendingLine(taskID: taskID, phase: phase, text: text))
        return true
    }

    /// The lines to say now: all of them once Clicky is idle, none before.
    public mutating func takeLinesToSpeak(isClickyIdle: Bool) -> [String] {
        guard isClickyIdle, !pendingLines.isEmpty else { return [] }
        let lines = pendingLines.map(\.text)
        pendingLines.removeAll()
        return lines
    }

    /// Drops a task's waiting lines (a silent task).
    public mutating func dropPendingLines(taskID: String) {
        pendingLines.removeAll { $0.taskID == taskID }
    }
}
