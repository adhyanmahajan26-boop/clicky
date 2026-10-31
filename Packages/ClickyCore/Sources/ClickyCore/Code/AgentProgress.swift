//
//  AgentProgress.swift
//  ClickyCore
//
//  Live progress of the Code-mode agent, read from its stream-json: every
//  `assistant` event's tool_use blocks become a step ("editing utils.py",
//  "running the tests"), and Edit/Write/MultiEdit/NotebookEdit paths are the
//  files changed so far. CodeTaskProgressTracker keeps the current step, the
//  changed files and the start time for the panel, and hands out a short
//  spoken update at most every 20 s (only when the step changed). Pure data:
//  nothing here reads the disk or speaks.
//

import Foundation

public struct AgentProgressEvent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case reading
        case editing
        case searching
        case runningTests
        case building
        case runningCommand
        case planning
        case other
    }

    public var kind: Kind
    /// The file the tool touches, relative to the working directory when it is inside it.
    public var filePath: String?
    /// The tool's name as the agent sent it ("Edit").
    public var toolName: String

    public init(kind: Kind, filePath: String? = nil, toolName: String) {
        self.kind = kind
        self.filePath = filePath
        self.toolName = toolName
    }

    /// True for tools that change a file.
    public var changesFile: Bool { kind == .editing && filePath != nil }

    /// "editing utils.py", "running the tests" (short, for the voice and the panel).
    public var stepDescription: String {
        let fileName = filePath.map { ($0 as NSString).lastPathComponent }
        switch kind {
        case .reading: return fileName.map { "reading \($0)" } ?? "reading the code"
        case .editing: return fileName.map { "editing \($0)" } ?? "editing files"
        case .searching: return "searching the code"
        case .runningTests: return "running the tests"
        case .building: return "building"
        case .runningCommand: return "running a command"
        case .planning: return "planning the change"
        case .other: return "working"
        }
    }
}

public enum AgentProgressExtractor {
    private static let editingTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    private static let testCommandMarkers = ["pytest", "unittest", "swift test", "npm test", "npm run test", "yarn test", "pnpm test", "go test", "cargo test",
                                             "xcodebuild test", "make test", "jest", "vitest", "rspec", "phpunit", "mvn test", "gradle test", "tox", "ctest"]
    private static let buildCommandMarkers = ["swift build", "xcodebuild", "npm run build", "yarn build", "pnpm build", "cargo build", "go build", "make", "tsc", "gradle", "mvn"]

    /// Events in one stream-json line (the raw line as parsed JSON).
    public static func events(fromStreamEvent event: [String: Any], workingDirectory: String?) -> [AgentProgressEvent] {
        guard event["type"] as? String == "assistant",
              let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block -> AgentProgressEvent? in
            guard block["type"] as? String == "tool_use", let toolName = block["name"] as? String else { return nil }
            let input = block["input"] as? [String: Any] ?? [:]
            return progressEvent(toolName: toolName, input: input, workingDirectory: workingDirectory)
        }
    }

    /// Same, from a raw stdout line (non-JSON lines give nothing).
    public static func events(fromLine line: Data, workingDirectory: String?) -> [AgentProgressEvent] {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        return events(fromStreamEvent: event, workingDirectory: workingDirectory)
    }

    static func progressEvent(toolName: String, input: [String: Any], workingDirectory: String?) -> AgentProgressEvent {
        let rawPath = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? (input["path"] as? String)
        let path = rawPath.map { relativePath($0, workingDirectory: workingDirectory) }
        if editingTools.contains(toolName) { return AgentProgressEvent(kind: .editing, filePath: path, toolName: toolName) }
        switch toolName {
        case "Read": return AgentProgressEvent(kind: .reading, filePath: path, toolName: toolName)
        case "Grep", "Glob", "LS": return AgentProgressEvent(kind: .searching, filePath: nil, toolName: toolName)
        case "TodoWrite": return AgentProgressEvent(kind: .planning, filePath: nil, toolName: toolName)
        case "Bash":
            let command = (input["command"] as? String ?? "").lowercased()
            if testCommandMarkers.contains(where: { command.contains($0) }) { return AgentProgressEvent(kind: .runningTests, toolName: toolName) }
            if buildCommandMarkers.contains(where: { command.contains($0) }) { return AgentProgressEvent(kind: .building, toolName: toolName) }
            return AgentProgressEvent(kind: .runningCommand, toolName: toolName)
        default:
            return AgentProgressEvent(kind: .other, filePath: nil, toolName: toolName)
        }
    }

    /// "/wt/src/utils.py" under "/wt" → "src/utils.py"; anything else keeps its last two components.
    static func relativePath(_ path: String, workingDirectory: String?) -> String {
        let standardizedPath = (path as NSString).standardizingPath
        if let workingDirectory {
            let base = (workingDirectory as NSString).standardizingPath
            let prefixes = [base, ProcessSweep.resolvedPath(base) ?? base].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
            for prefix in prefixes where standardizedPath.hasPrefix(prefix) {
                return String(standardizedPath.dropFirst(prefix.count))
            }
        }
        if !standardizedPath.hasPrefix("/") { return standardizedPath }
        let components = (standardizedPath as NSString).pathComponents.filter { $0 != "/" }
        return components.suffix(2).joined(separator: "/")
    }
}

/// What the panel shows while the agent works.
public struct CodeTaskProgressSnapshot: Equatable, Sendable {
    public var title: String
    public var currentStep: String
    public var changedFiles: [String]
    public var elapsedSeconds: Int
    public var toolCallCount: Int
    /// Tasks waiting after this one.
    public var queuedCount: Int

    public init(title: String, currentStep: String, changedFiles: [String], elapsedSeconds: Int, toolCallCount: Int, queuedCount: Int = 0) {
        self.title = title
        self.currentStep = currentStep
        self.changedFiles = changedFiles
        self.elapsedSeconds = elapsedSeconds
        self.toolCallCount = toolCallCount
        self.queuedCount = queuedCount
    }

    /// "0:42", "3:05".
    public var elapsedText: String { String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60) }

    /// "Editing utils.py  ·  0:42".
    public var stepLine: String {
        let step = currentStep.prefix(1).uppercased() + String(currentStep.dropFirst())
        return "\(step)  ·  \(elapsedText)"
    }
}

public struct CodeTaskProgressTracker: Sendable {
    public static let defaultNarrationInterval: TimeInterval = 20

    public private(set) var startedAt: Date
    public private(set) var currentStep: String
    public private(set) var changedFiles: [String] = []
    public private(set) var toolCallCount = 0
    public private(set) var lastNarration: String?
    private var lastNarrationAt: Date?
    public var narrationInterval: TimeInterval

    public init(startedAt: Date = Date(), initialStep: String = "starting", narrationInterval: TimeInterval = CodeTaskProgressTracker.defaultNarrationInterval) {
        self.startedAt = startedAt
        self.currentStep = initialStep
        self.narrationInterval = narrationInterval
    }

    /// A phase from the engine ("Making a worktree in o/n") before the agent's own events.
    public mutating func setPhase(_ phase: String) {
        currentStep = phase
    }

    public mutating func apply(_ event: AgentProgressEvent) {
        toolCallCount += 1
        currentStep = event.stepDescription
        if event.changesFile, let filePath = event.filePath, !changedFiles.contains(filePath) {
            changedFiles.append(filePath)
        }
    }

    /// A short spoken update when one is due: at least `narrationInterval`
    /// after the start (the heads-up was just spoken) and after the last
    /// update, and only when the step differs from the last one spoken.
    public mutating func narrationIfDue(now: Date) -> String? {
        let reference = lastNarrationAt ?? startedAt
        guard now.timeIntervalSince(reference) >= narrationInterval else { return nil }
        guard toolCallCount > 0, currentStep != lastNarration else { return nil }
        lastNarration = currentStep
        lastNarrationAt = now
        return currentStep
    }

    public func snapshot(title: String, now: Date, queuedCount: Int = 0) -> CodeTaskProgressSnapshot {
        CodeTaskProgressSnapshot(title: title, currentStep: currentStep, changedFiles: changedFiles,
                                 elapsedSeconds: max(0, Int(now.timeIntervalSince(startedAt))), toolCallCount: toolCallCount, queuedCount: queuedCount)
    }
}
