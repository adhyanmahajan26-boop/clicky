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
        let paths = spellings(of: folder)
        switch harness {
        case "t3":
            guard let cli = BotsT3.cli, isT3ServerUp else { return [] }
            return HarnessChatFiles.t3Threads(json: output(of: cli, ["thread", "list", "--project", folder, "--json"]))
        case "claude": return claude(paths)
        case "codex": return codex(paths)
        case "cursor": return paths.flatMap(cursor).uniqued
        case "opencode": return openCode(paths)
        case "gemini": return paths.flatMap(gemini).uniqued
        case "grok": return paths.flatMap(grok).uniqued
        default: return []
        }
    }

    /// The ways a folder's path can be spelled. Foundation's resolving leaves /private off /tmp, while the harnesses go by the real path.
    static func spellings(of folder: String) -> [String] {
        var paths = [folder, URL(fileURLWithPath: folder).resolvingSymlinksInPath().path]
        if let real = realpath(folder, nil) {
            paths.append(String(cString: real))
            free(real)
        }
        return Array(Set(paths))
    }

    private static var home: URL { URL(fileURLWithPath: TheoProfile.realHome, isDirectory: true) }

    /// T3 Code's server is up, so its CLI can be asked. With none up, the CLI writes a database and a signing key into its folder, and that
    /// folder is T3 Code's own. (If the server's down the menu says to open T3 Code.)
    static var isT3ServerUp: Bool {
        guard let cli = BotsT3.cli else { return false }
        let t3Home = cli.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = try? String(contentsOf: t3Home.appendingPathComponent("userdata/server-runtime.json"), encoding: .utf8)
        guard let pid = HarnessChatFiles.t3ServerPID(runtimeJSON: runtime) else { return false }
        return kill(pid, 0) == 0
    }

    private static let sqlite = URL(fileURLWithPath: "/usr/bin/sqlite3")

    private static func claude(_ paths: [String]) -> [HarnessChat] {
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        var directories: [URL] = []
        for path in paths {
            let name = HarnessChatFiles.claudeFolderName(for: path)
            if name.count <= HarnessChatFiles.claudeFolderNameLimit {
                directories.append(projects.appendingPathComponent(name, isDirectory: true))
            } else {
                // Cut at 200 with a hash after it: the cut name finds it, and each session's own folder says if it's the one.
                let cut = String(name.prefix(HarnessChatFiles.claudeFolderNameLimit))
                let all = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
                directories += all.filter { $0.lastPathComponent.hasPrefix(cut) }
            }
        }
        let folders = Set(paths)
        return directories.flatMap { directory in
            newestFiles(in: directory, suffix: ".jsonl").compactMap { file, modified in
                HarnessChatFiles.claudeSession(id: file.deletingPathExtension().lastPathComponent, lines: startAndEndLines(of: file), folders: folders, modifiedAt: modified)
            }
        }.uniqued
    }

    private static func codex(_ paths: [String]) -> [HarnessChat] {
        let manager = FileManager.default
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        // Its own list, when it can be read. The number in the file's name is a version.
        let stores = ((try? manager.contentsOfDirectory(atPath: codex.path)) ?? []).filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }.sorted()
        if let store = stores.last {
            let wanted = paths.map(HarnessChatFiles.sqliteQuoted).joined(separator: ",")
            let query = "select id, title, first_user_message, updated_at_ms from threads where cwd in (\(wanted)) and archived = 0 order by updated_at_ms desc limit \(maximumShown);"
            let found = HarnessChatFiles.codexThreads(sqliteJSON: output(of: sqlite, ["-readonly", "-json", codex.appendingPathComponent(store).path, query]))
            if !found.isEmpty { return found }
        }
        // Its session files otherwise.
        let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
        let titles = HarnessChatFiles.codexTitles(indexLines: (try? String(contentsOf: codex.appendingPathComponent("session_index.jsonl"), encoding: .utf8))?.components(separatedBy: "\n") ?? [])
        guard let walker = manager.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var rollouts: [(URL, Date)] = []
        for case let file as URL in walker where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
            rollouts.append((file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
        }
        var found: [HarnessChat] = []
        for (file, modified) in rollouts.sorted(by: { $0.1 > $1.1 }).prefix(200) {
            let lines = firstLines(of: file, keeping: 200_000)
            guard let first = lines.first, let meta = HarnessChatFiles.codexMeta(firstLine: first), paths.contains(meta.cwd) else { continue }
            let title = titles[meta.id].flatMap { HarnessChatText.title(from: $0) } ?? HarnessChatFiles.codexFirstAsk(lines: lines) ?? "Untitled chat"
            found.append(HarnessChat(id: meta.id, title: title, updatedAt: modified))
            if found.count >= maximumShown { break }
        }
        return found
    }

    /// Never `cursor-agent ls`: with no terminal it hangs until killed, and it rewrites files in old chats.
    private static func cursor(_ folder: String) -> [HarnessChat] {
        let manager = FileManager.default
        let directory = home.appendingPathComponent(".cursor/chats/\(HarnessChatFiles.cursorFolderName(for: folder))", isDirectory: true)
        let chats = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return chats.compactMap { chat -> HarnessChat? in
            let modified = (try? chat.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let meta = try? String(contentsOf: chat.appendingPathComponent("meta.json"), encoding: .utf8) {
                let prompts = (try? Data(contentsOf: chat.appendingPathComponent("prompt_history.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }
                return HarnessChatFiles.cursorChat(id: chat.lastPathComponent, metaJSON: meta, firstPrompt: prompts?.first, modifiedAt: modified)
            }
            let store = chat.appendingPathComponent("store.db").path
            guard manager.fileExists(atPath: store) else { return nil }
            let hex = output(of: sqlite, ["-readonly", store, "select value from meta where key='0';"])
            return HarnessChatFiles.cursorChat(id: chat.lastPathComponent, storeMetaHex: hex, modifiedAt: modified)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Its database, read-only: `opencode session list` isn't per folder, prints nothing for a repo with no sessions, and can add a row.
    private static func openCode(_ paths: [String]) -> [HarnessChat] {
        let store = home.appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: store.path) else { return [] }
        let wanted = paths.map(HarnessChatFiles.sqliteQuoted).joined(separator: ",")
        let query = "select id, title, time_updated from session where directory in (\(wanted)) and parent_id is null and time_archived is null order by time_updated desc limit \(maximumShown);"
        let found = HarnessChatFiles.openCodeRows(sqliteJSON: output(of: sqlite, ["-readonly", "-json", store.path, query]))
        if !found.isEmpty { return found }
        // No rows means no chats. Only a database of another shape needs its CLI, which can add a row of its own, so that's the last resort.
        guard output(of: sqlite, ["-readonly", store.path, "select count(*) from session;"]).isEmpty,
              let executable = HarnessCatalog.executable(for: "opencode"), let folder = paths.first else { return [] }
        let json = output(of: executable, ["session", "list", "--format", "json", "-n", "300"], in: folder)
        return paths.flatMap { HarnessChatFiles.openCodeSessions(json: json, folder: $0) }.uniqued
    }

    private static func gemini(_ folder: String) -> [HarnessChat] {
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        let projects = try? String(contentsOf: gemini.appendingPathComponent("projects.json"), encoding: .utf8)
        guard let slug = HarnessChatFiles.geminiSlug(projectsJSON: projects, folder: folder) else { return [] }
        let chats = gemini.appendingPathComponent("tmp/\(slug)/chats", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("session-") }.compactMap { file -> HarnessChat? in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return HarnessChatFiles.geminiChat(fileText: text, modifiedAt: modified)
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
    /// Only for a run from before runs recorded their chat: anything newer knows its own, or says it couldn't tell.
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

    /// The first and last 64 KB of a transcript: a title can be at either end. Claude Code's own list reads the same.
    private static func startAndEndLines(of file: URL, keeping bytes: Int = 65_536) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard size > UInt64(bytes * 2) else {
            return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self).components(separatedBy: "\n")
        }
        var lines = String(decoding: (try? handle.read(upToCount: bytes)) ?? Data(), as: UTF8.self).components(separatedBy: "\n")
        lines.removeLast()
        try? handle.seek(toOffset: size - UInt64(bytes))
        var tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self).components(separatedBy: "\n")
        tail.removeFirst()
        return lines + tail
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
    static func output(of executable: URL, _ arguments: [String], in folder: String? = nil) -> String {
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
