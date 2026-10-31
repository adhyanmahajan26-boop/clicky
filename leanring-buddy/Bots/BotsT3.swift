//
//  BotsT3.swift
//  leanring-buddy
//
//  Hands the Project room's final prompt to T3 Code and follows it through:
//  a project (a new git repo under ~/Projects, or a new branch in a worktree
//  of a repo Addy named), a thread on Opus 5.5 at high effort, then the run
//  tracked until it ends. The result comes back to the room as a report:
//  the agent's summary, what changed, Theo's own test run, and a draft PR
//  when the work landed on a branch of a GitHub repo.
//

import AppKit
import Foundation

enum BotsT3Error: LocalizedError {
    case noCLI
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noCLI: return "T3 Code's t3 command isn't installed on this Mac (open T3 Code once to install it)."
        case .failed(let message): return message
        }
    }
}

/// One coding run Theo started in T3 Code, saved so tracking survives a restart of Theo.
struct T3Run: Codable, Identifiable, Equatable {
    /// T3 Code's thread id.
    var id: String
    var title: String
    /// Where the agent works: the new project folder, or the repo Addy named.
    var folder: String
    /// The repo Addy named, when the work goes on a branch of it.
    var repo: String?
    var branch: String?
    /// The commit the run started from, for the diff.
    var baseCommit: String?
    var link: String?
    /// "running", "waiting" (the agent asked something), "done" or "failed".
    var phase: String = "running"
    /// The agent's latest words, shown on the run's card while it works.
    var activity: String?
    var startedAt: Date = Date()
    var finishedAt: Date?
    var pullRequest: String?
}

enum BotsT3 {
    /// The coding model T3 Code builds with: Opus 5.5 through T3 Code's Claude provider.
    static let provider = "claudeAgent"
    static let model = "claude-opus-5-5"
    static let effort = "high"
    static let modelName = "Claude Opus 5.5"

    /// The t3 launcher T3 Code writes into its data folder (Cursor Assistant build first).
    static var cli: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".t3-claudia/bin/t3", ".t3/bin/t3"].map { home.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var gh: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return executable(["\(home)/.local/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
    }

    /// Told to the agent with every prompt, so the report has something to read back.
    static let deliveryNote = """


        ---
        When you're done: commit your work to git with a clear message, run the tests or checks you wrote and \
        say how they went, and end with a short report for the team: what you built, how to run it, the tests \
        and their results, and anything left undone.
        """

    /// The ```prompt block Theo writes as the team's final prompt, if there is one.
    static func promptBlock(in text: String) -> String? { fenced("prompt", in: text) }

    /// A ```followup block: Theo passing a change for an earlier run to its agent.
    static func followupBlock(in text: String) -> String? { fenced("followup", in: text) }

    /// The body of a ```tag block. It ends at a line that is only a fence with no language, so a prompt
    /// that carries its own ```swift samples isn't cut short at the first of them.
    private static func fenced(_ tag: String, in text: String) -> String? {
        guard let start = text.range(of: "```\(tag)") else { return nil }
        var depth = 0
        var body: [Substring] = []
        for line in text[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "```" {
                if depth == 0 { break }
                depth -= 1
            } else if trimmed.hasPrefix("```") {
                depth += 1
            }
            body.append(line)
        }
        let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// "Project: Name" on its own line, else the prompt's first words.
    static func projectTitle(in text: String, prompt: String) -> String {
        if let name = labeledLine("project", in: text) { return String(name.prefix(60)) }
        return prompt.split(separator: " ").prefix(6).joined(separator: " ")
    }

    /// The git repo the work should go into: a "Repo: <path>" line Theo wrote, else a path in the pitch.
    static func targetRepo(answer: String, pitch: String) -> URL? {
        var candidates: [String] = []
        if let line = labeledLine("repo", in: answer) { candidates.append(line) }
        if let regex = try? NSRegularExpression(pattern: #"~/[\w./-]+"#) {
            let range = NSRange(pitch.startIndex..., in: pitch)
            candidates += regex.matches(in: pitch, range: range).compactMap { Range($0.range, in: pitch).map { String(pitch[$0]) } }
        }
        for candidate in candidates {
            let path = (candidate.trimmingCharacters(in: CharacterSet(charactersIn: "`.,) ")) as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path + "/.git") { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return nil
    }

    private static func labeledLine(_ label: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
            if trimmed.lowercased().hasPrefix("\(label):") {
                let value = trimmed.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "theo-project" : String(collapsed.prefix(48))
    }

    // MARK: Starting

    /// Creates the project (or a branch of `repo`), starts the thread and opens it in T3 Code.
    static func submit(prompt: String, title: String, repo: URL?) async throws -> T3Run {
        guard let cli else { throw BotsT3Error.noCLI }
        var arguments = ["thread", "start"]
        var run: T3Run
        if let repo {
            let branch = "theo/\(slug(title))-\(Int(Date().timeIntervalSince1970) % 100000)"
            let base = try await shell(git, ["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try? await shell(cli, ["project", "add", repo.path])
            arguments += [repo.path, "-", "--worktree", base, "--branch", branch]
            run = T3Run(id: "", title: title, folder: repo.path, repo: repo.path, branch: branch, baseCommit: base)
        } else {
            let folder = try newProjectFolder(title: title)
            try "# \(title)\n\nStarted by Theo's Project room. The prompt T3 Code received:\n\n\(prompt)\n"
                .write(to: folder.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)
            try await shell(git, ["init", "-q", "-b", "main"], in: folder)
            try await commitAll(in: folder, message: "Brief from Theo's Project room")
            let base = try await shell(git, ["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
            try await shell(cli, ["project", "add", folder.path, "--title", title])
            arguments += [folder.path, "-"]
            run = T3Run(id: "", title: title, folder: folder.path, baseCommit: base)
        }
        arguments += ["--title", title, "--provider", provider, "--model", model, "--json"]
        let message = prompt + deliveryNote
        let output: String
        do {
            output = try await shell(cli, arguments + ["--effort", effort], stdin: message)
        } catch BotsT3Error.failed(let text) where text.contains("effort") {
            // A T3 Code build from before --effort: start it on the model's default effort.
            output = try await shell(cli, arguments, stdin: message)
        }
        guard let launched = jsonObject(in: output), let threadID = launched["threadId"] as? String else {
            throw BotsT3Error.failed("T3 Code didn't return the new thread: \(output.suffix(200))")
        }
        run.id = threadID
        run.link = launched["link"] as? String
        _ = try? await shell(cli, ["app", run.folder])
        await moveT3ToTheosScreen()
        return run
    }

    /// Sends Addy's change to a run's thread; a busy agent gets it as its next turn.
    static func sendFollowup(_ text: String, to run: T3Run) async throws {
        guard let cli else { throw BotsT3Error.noCLI }
        try await shell(cli, ["thread", "send", run.id, "-"], stdin: text + deliveryNote)
    }

    /// Brings the run's project up in the T3 Code app.
    static func openInApp(_ run: T3Run) {
        guard let cli else { return }
        Task {
            _ = try? await shell(cli, ["app", run.folder])
            await moveT3ToTheosScreen()
        }
    }

    /// T3 Code opens where it last was; with a display picked for Theo, its window goes there instead.
    @MainActor private static func moveT3ToTheosScreen() {
        let app = ["com.addy.claudia.t3code", "com.t3tools.t3code"].lazy
            .compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }.first
        ClaudiaScreen.moveFrontWindow(of: app)
    }

    private static func newProjectFolder(title: String) throws -> URL {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects", isDirectory: true)
        var folder = projects.appendingPathComponent(slug(title), isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = projects.appendingPathComponent("\(slug(title))-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Tracking

    struct ThreadState {
        var status: String
        var busy: Bool
        var waitingForAnswer: Bool
        var lastMessage: String?
        var worktree: String?
        var pullRequest: String?
    }

    static let endedStatuses: Set<String> = ["completed", "failed", "interrupted", "cancelled", "rolled_back"]

    static func state(of run: T3Run) async -> ThreadState? {
        guard let cli, let output = try? await shell(cli, ["thread", "show", run.id, "--json", "--messages", "1"]),
              let object = jsonObject(in: output), let thread = object["thread"] as? [String: Any] else { return nil }
        let status = thread["status"] as? String ?? "unknown"
        let active = thread["activeRunId"] as? String
        let pending = thread["pendingRequestCount"] as? Int ?? 0
        let messages = object["messages"] as? [[String: Any]] ?? []
        let pullRequests = (thread["pullRequests"] as? [[String: Any]] ?? []) + [thread["linkedPullRequest"] as? [String: Any]].compactMap { $0 }
        return ThreadState(
            status: status,
            busy: active != nil && !endedStatuses.contains(status),
            waitingForAnswer: pending > 0 || status == "waiting",
            lastMessage: messages.last?["text"] as? String,
            worktree: thread["worktreePath"] as? String,
            pullRequest: pullRequests.compactMap { $0["url"] as? String }.first)
    }

    /// Everything the room hears when a run ends: the agent's report, the change, a test run, the PR.
    static func report(for run: inout T3Run, state: ThreadState) async -> String {
        let folder = URL(fileURLWithPath: state.worktree ?? run.folder, isDirectory: true)
        let minutes = max(1, Int((Date().timeIntervalSince(run.startedAt) / 60).rounded()))
        let failed = ["failed", "interrupted", "cancelled", "rolled_back"].contains(state.status)
        var lines = [failed
            ? "**\(run.title)** stopped in T3 Code (\(state.status)) after \(minutes) min."
            : "**\(run.title)** is done in T3 Code: \(modelName), \(effort) effort, \(minutes) min."]
        if let summary = state.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append(trimmedSummary(summary))
        }

        // Whatever the agent left uncommitted is committed, so the diff and the PR hold all of it. In a
        // repo Addy named that's only safe in the run's own worktree, never the checkout Addy works in.
        if run.repo == nil || state.worktree != nil {
            try? await commitAll(in: folder, message: "\(run.title): remaining changes from T3 Code")
        }
        let head = run.branch ?? "HEAD"
        if let base = run.baseCommit,
           let stat = try? await shell(git, ["diff", "--shortstat", base, head], in: folder),
           !stat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let files = (try? await shell(git, ["diff", "--name-only", base, head], in: folder))?
                .split(separator: "\n").prefix(8).map { "`\($0)`" }.joined(separator: ", ") ?? ""
            lines.append("**Changes:** \(stat.trimmingCharacters(in: .whitespacesAndNewlines)). \(files)")
        }
        if !failed, run.repo == nil || state.worktree != nil, let tests = await runTests(in: folder) { lines.append("**Tests (Theo's own run):** \(tests)") }

        if let pr = state.pullRequest {
            run.pullRequest = pr
        } else if !failed, let branch = run.branch {
            run.pullRequest = await openDraftPR(in: folder, branch: branch, title: run.title,
                                                body: state.lastMessage ?? "Built by T3 Code from Theo's Project room.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let pr = run.pullRequest {
            lines.append("**Pull request:** \(pr)")
        } else if let branch = run.branch {
            lines.append("**Branch:** `\(branch)` in \((run.repo ?? run.folder).replacingOccurrences(of: home, with: "~")) (no GitHub remote, so no PR).")
        } else {
            lines.append("**Folder:** \(run.folder.replacingOccurrences(of: home, with: "~"))")
        }
        lines.append("Write @T3 with a change and Theo passes it to the coding agent.")
        return lines.joined(separator: "\n\n")
    }

    private static func trimmedSummary(_ text: String) -> String {
        // Screenshots the agent saved to its scratchpad don't exist for the room; keep the words.
        let withoutImages = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)\n?"#, with: "", options: .regularExpression)
        guard withoutImages.count > 1800 else { return withoutImages }
        return String(withoutImages.prefix(1800)) + "…"
    }

    /// Runs the project's own tests when it has a quick way to: an npm test script with its packages
    /// installed, or pytest. Nil when there is nothing to run.
    static func runTests(in folder: URL) async -> String? {
        let fm = FileManager.default
        var command: (URL, [String])?
        if let data = fm.contents(atPath: folder.appendingPathComponent("package.json").path),
           let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = package["scripts"] as? [String: Any], let test = scripts["test"] as? String,
           !test.contains("no test specified"), fm.fileExists(atPath: folder.appendingPathComponent("node_modules").path),
           let npm = executable(["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]) {
            command = (npm, ["test", "--silent"])
        } else if fm.fileExists(atPath: folder.appendingPathComponent("tests").path)
                    || fm.fileExists(atPath: folder.appendingPathComponent("pytest.ini").path),
                  let python = executable(["/opt/homebrew/bin/python3", "/usr/bin/python3"]) {
            command = (python, ["-m", "pytest", "-q"])
        }
        guard let (tool, arguments) = command else { return nil }
        do {
            let output = try await shell(tool, arguments, in: folder, limit: 240)
            let last = output.split(separator: "\n").last.map(String.init) ?? ""
            return "passed. \(last.prefix(160))"
        } catch {
            return "failed. \(error.localizedDescription.suffix(300))"
        }
    }

    /// Pushes the run's branch and opens a draft PR, when the repo lives on GitHub.
    private static func openDraftPR(in folder: URL, branch: String, title: String, body: String) async -> String? {
        guard let gh, let remote = try? await shell(git, ["remote", "get-url", "origin"], in: folder),
              remote.contains("github.com") else { return nil }
        guard (try? await shell(git, ["push", "-u", "origin", branch], in: folder, limit: 120)) != nil else { return nil }
        let output = try? await shell(gh, ["pr", "create", "--draft", "--head", branch, "--title", title,
                                           "--body", "From Theo's Project room, built in T3 Code on \(modelName).\n\n\(trimmedSummary(body))"],
                                      in: folder, limit: 60)
        return output?.split(separator: "\n").last { $0.hasPrefix("https://") }.map(String.init)
    }

    // MARK: Processes

    private static let git = URL(fileURLWithPath: "/usr/bin/git")

    private static func executable(_ paths: [String]) -> URL? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private static func commitAll(in folder: URL, message: String) async throws {
        let status = try await shell(git, ["status", "--porcelain"], in: folder)
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try await shell(git, ["add", "-A"], in: folder)
        try await shell(git, ["-c", "user.name=Theo", "-c", "user.email=theo@localhost", "commit", "-q", "-m", message], in: folder)
    }

    private static func jsonObject(in output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any]
    }

    /// Runs a tool from home (or `folder`) and returns its output; a non-zero exit throws with the
    /// output's tail. Stopped after `limit` seconds.
    @discardableResult
    private static func shell(_ executable: URL, _ arguments: [String], in folder: URL? = nil,
                              stdin: String? = nil, limit: Double = 90) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let cwd = folder ?? FileManager.default.homeDirectoryForCurrentUser
            process.currentDirectoryURL = cwd
            var environment = ProcessInfo.processInfo.environment
            environment["PWD"] = cwd.path
            environment["NO_COLOR"] = "1"
            environment["CI"] = "1"
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let input = Pipe()
            process.standardInput = stdin == nil ? FileHandle.nullDevice : input
            try process.run()
            let watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                if process.isRunning { process.terminate() }
            }
            defer { watchdog.cancel() }
            if let stdin {
                try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                throw BotsT3Error.failed("\(executable.lastPathComponent) \(arguments.first ?? "") failed: \(text.suffix(300))")
            }
            return text
        }.value
    }
}
