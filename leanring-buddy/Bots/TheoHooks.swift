//
//  TheoHooks.swift
//  leanring-buddy
//
//  Lifecycle hooks: executable scripts the owner puts in ~/Library/Application Support/Theo/Hooks/<event>/ run when that
//  happens (ClickyCore `TheoHookEvent`: app-started, turn-finished, routine-finished, gateway-message). Each gets the event
//  as JSON in a file named by its first argument (and $THEO_HOOK_FILE), runs in its own process group with a 15-second limit,
//  and can't hold anything up: Theo doesn't wait for it. Only regular files owned by the owner, writable by nobody else, run.
//  What each printed and how it ended goes to ~/Library/Logs/Clicky/hooks.log.
//

import ClickyCore
import Foundation

enum TheoHooks {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Theo/Hooks", isDirectory: true)
    }

    /// The scripts that will run for `event`, in name order.
    static func scripts(for event: TheoHookEvent) -> [URL] {
        let directory = folder.appendingPathComponent(event.rawValue, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name)
            var info = stat()
            // lstat: a link isn't followed, so a link to somewhere else never runs.
            guard lstat(url.path, &info) == 0 else { return nil }
            let isRegular = (info.st_mode & S_IFMT) == S_IFREG
            return TheoHookFiles.runs(name: name, isRegularFile: isRegular, permissions: Int(info.st_mode & 0o7777), ownerID: info.st_uid, userID: getuid()) ? url : nil
        }
    }

    /// Runs every hook for `event`, off the main thread. Returns at once.
    static func fire(_ event: TheoHookEvent, _ fields: [String: Any]) {
        let scripts = scripts(for: event)
        guard !scripts.isEmpty else { return }
        let payload = TheoHookFiles.payload(event: event, at: Date(), fields: fields)
        Task.detached(priority: .utility) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("theo-hook-\(UUID().uuidString).json")
            guard (try? payload.write(to: file, options: .atomic)) != nil else { return }
            chmod(file.path, 0o600)
            defer { try? FileManager.default.removeItem(at: file) }
            var environment = ProcessInfo.processInfo.environment
            BotRunner.scrubClaudeEnvironment(&environment)
            environment["THEO_HOOK_EVENT"] = event.rawValue
            environment["THEO_HOOK_FILE"] = file.path
            for batch in stride(from: 0, to: scripts.count, by: TheoHookFiles.perEvent).map({ Array(scripts[$0..<min($0 + TheoHookFiles.perEvent, scripts.count)]) }) {
                await withTaskGroup(of: String.self) { group in
                    for script in batch {
                        group.addTask {
                            guard let child = try? ChildProcess.launch(executable: script.path, arguments: [file.path], environment: environment,
                                                                       workingDirectory: script.deletingLastPathComponent().path,
                                                                       timeouts: .total(TheoHookFiles.timeLimit), captureLimit: 16 * 1024) else {
                                return "\(script.lastPathComponent): couldn't start"
                            }
                            let result = await child.waitForExit()
                            let how = result.endReason == .totalTimeout ? "stopped after \(Int(TheoHookFiles.timeLimit)) s"
                                : result.terminatingSignal.map { "signal \($0)" } ?? "exit \(result.exitStatus ?? -1)"
                            return "\(script.lastPathComponent): \(how)\n\(result.standardOutputText.suffix(2000))\(result.standardErrorText.suffix(2000))"
                        }
                    }
                    for await line in group { log("\(Date()) [\(event.rawValue)] \(line)") }
                }
            }
        }
    }

    private static func log(_ text: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/hooks.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((text + "\n").utf8))
        try? handle.close()
    }
}
