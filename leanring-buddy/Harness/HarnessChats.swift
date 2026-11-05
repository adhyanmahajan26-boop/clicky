//
//  HarnessChats.swift
//  leanring-buddy
//
//  The chats a harness already has in a folder on this Mac, newest first, read from where it keeps them. Nothing runs a turn or changes
//  anything. A harness with no way to list them, or that isn't installed here, simply has none: the menu then only offers a new chat.
//

import ClickyCore
import Foundation

enum HarnessChats {
    static let maximumShown = 20

    static func list(harness: String, folder: String) async -> [HarnessChat] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Array(read(harness: harness, folder: folder).prefix(maximumShown)))
            }
        }
    }

    /// This runs off the main thread: harnesses' listings can take a second or two.
    private static func read(harness: String, folder: String) -> [HarnessChat] {
        let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        let paths = Array(Set([folder, resolved]))
        switch harness {
        case "t3":
            guard let cli = BotsT3.cli else { return [] }
            return HarnessChatFiles.t3Threads(json: output(of: cli, ["thread", "list", "--project", folder, "--json"]))
        case "claude": return paths.flatMap(claude).uniqued
        case "codex": return codex(paths)
        case "cursor": return paths.flatMap(cursor).uniqued
        case "opencode":
            guard let executable = HarnessCatalog.executable(for: "opencode") else { return [] }
            let json = output(of: executable, ["session", "list", "--format", "json", "-n", "300"], in: folder)
            return paths.flatMap { HarnessChatFiles.openCodeSessions(json: json, folder: $0) }.uniqued
        case "gemini":
            guard let executable = HarnessCatalog.executable(for: "gemini") else { return [] }
            return HarnessChatFiles.geminiSessions(text: output(of: executable, ["--list-sessions"], in: folder))
        case "grok": return paths.flatMap(grok).uniqued
        default: return []
        }
    }

    private static var home: URL { URL(fileURLWithPath: TheoProfile.realHome, isDirectory: true) }

    private static func claude(_ folder: String) -> [HarnessChat] {
        let directory = home.appendingPathComponent(".claude/projects/\(HarnessChatFiles.claudeFolderName(for: folder))", isDirectory: true)
        return newestFiles(in: directory, suffix: ".jsonl").compactMap { file, modified in
            HarnessChatFiles.claudeSession(id: file.deletingPathExtension().lastPathComponent, lines: firstLines(of: file), modifiedAt: modified)
        }
    }

    private static func codex(_ paths: [String]) -> [HarnessChat] {
        let manager = FileManager.default
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let titles = HarnessChatFiles.codexTitles(indexLines: (try? String(contentsOf: home.appendingPathComponent(".codex/session_index.jsonl"), encoding: .utf8))?.components(separatedBy: "\n") ?? [])
        var found: [HarnessChat] = []
        guard let walker = manager.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var rollouts: [(URL, Date)] = []
        for case let file as URL in walker where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
            rollouts.append((file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
        }
        for (file, modified) in rollouts.sorted(by: { $0.1 > $1.1 }).prefix(400) {
            let lines = firstLines(of: file, keeping: 200_000)
            guard let first = lines.first, let meta = HarnessChatFiles.codexMeta(firstLine: first), paths.contains(meta.cwd) else { continue }
            let title = titles[meta.id].flatMap { HarnessChatText.title(from: $0) } ?? HarnessChatFiles.codexFirstAsk(lines: lines) ?? "Untitled chat"
            found.append(HarnessChat(id: meta.id, title: title, updatedAt: modified))
            if found.count >= maximumShown { break }
        }
        return found
    }

    private static func cursor(_ folder: String) -> [HarnessChat] {
        let manager = FileManager.default
        let directory = home.appendingPathComponent(".cursor/chats/\(HarnessChatFiles.cursorFolderName(for: folder))", isDirectory: true)
        let chats = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return chats.compactMap { chat -> HarnessChat? in
            let modified = (try? chat.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let meta = try? String(contentsOf: chat.appendingPathComponent("meta.json"), encoding: .utf8) {
                return HarnessChatFiles.cursorChat(id: chat.lastPathComponent, metaJSON: meta, modifiedAt: modified)
            }
            let store = chat.appendingPathComponent("store.db").path
            guard manager.fileExists(atPath: store) else { return nil }
            let hex = output(of: URL(fileURLWithPath: "/usr/bin/sqlite3"), ["-readonly", store, "select value from meta where key='0';"])
            return HarnessChatFiles.cursorChat(id: chat.lastPathComponent, storeMetaHex: hex, modifiedAt: modified)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func grok(_ folder: String) -> [HarnessChat] {
        let manager = FileManager.default
        let directory = home.appendingPathComponent(".grok/sessions/\(HarnessChatFiles.grokFolderName(for: folder))", isDirectory: true)
        let history = (try? String(contentsOf: directory.appendingPathComponent("prompt_history.jsonl"), encoding: .utf8))?.components(separatedBy: "\n") ?? []
        let prompts = HarnessChatFiles.grokFirstPrompts(historyLines: history)
        let sessions = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? []
        return sessions.compactMap { session -> HarnessChat? in
            guard let values = try? session.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]), values.isDirectory == true else { return nil }
            let summary = try? String(contentsOf: session.appendingPathComponent("summary.json"), encoding: .utf8)
            return HarnessChatFiles.grokChat(id: session.lastPathComponent, summaryJSON: summary, firstPrompt: prompts[session.lastPathComponent], modifiedAt: values.contentModificationDate ?? .distantPast)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The session a harness started for a run in this folder, for a follow-up once its terminal has gone: never "the last one in this folder".
    static func session(startedFor run: T3Run) async -> String? {
        guard let harness = run.harness, harness != "t3" else { return nil }
        let chats = await list(harness: harness, folder: run.worktree ?? run.folder)
        return chats.filter { $0.updatedAt >= run.startedAt.addingTimeInterval(-5) }.first?.id
    }

    // MARK: Reading

    private static func newestFiles(in directory: URL, suffix: String) -> [(URL, Date)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(suffix) }.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }.prefix(maximumShown).map { $0 }
    }

    /// The start of a big transcript is all a title needs.
    private static func firstLines(of file: URL, keeping maximumBytes: Int = 400_000) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maximumBytes)) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if data.count == maximumBytes { lines.removeLast() }
        return lines
    }

    /// A tool's output, or nothing when it fails: no list is an empty list, never an error in the chat.
    private static func output(of executable: URL, _ arguments: [String], in folder: String? = nil) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home
        var environment = HarnessCatalog.childEnvironment()
        environment["NO_COLOR"] = "1"
        environment["PWD"] = process.currentDirectoryURL?.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
    }
}

private extension Array where Element == HarnessChat {
    /// The same chat found by both spellings of a folder, once, newest first.
    var uniqued: [HarnessChat] {
        var seen = Set<String>()
        return sorted { $0.updatedAt > $1.updatedAt }.filter { seen.insert($0.id).inserted }
    }
}
