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
    /// The chat it was started from (nil: the Project room).
    var room: String?
    /// Set when the run goes through a harness's own CLI instead of T3 Code ("claude", "codex", …).
    var harness: String?
    var model: String?
    var effort: String?
    /// The run's own git worktree (harness runs on a repo Addy named).
    var worktree: String?
    /// What the result card shows, filled in when the run ends.
    var changedFiles: [RunFileChange]?
    var tests: String?
    /// Why there's no pull request, when one was expected.
    var pullRequestProblem: String?
    /// Stopped by the owner, so the report doesn't call it a failure.
    var stoppedByOwner: Bool?
    /// What it was asked, so a failed run can try again on another harness.
    var prompt: String?
}

/// One file a run changed.
struct RunFileChange: Codable, Equatable, Identifiable {
    var path: String
    var added: Int
    var removed: Int
    var id: String { path }
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

    static var gh: URL? { tool("gh") }

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
        return shortTitle(from: prompt)
    }

    /// "fix the bug in add.js so the test passes, in ~/foo" reads "Fix the bug in add.js".
    static func shortTitle(from text: String) -> String {
        var words = Array(text.split(separator: "\n").first?.split(separator: " ").prefix(6).map(String.init) ?? [])
        let weak: Set<String> = ["so", "to", "in", "the", "and", "a", "an", "of", "for", "with", "on", "that", "then"]
        while let last = words.last?.trimmingCharacters(in: .punctuationCharacters).lowercased(), weak.contains(last) { words.removeLast() }
        // A path says little as a title.
        words.removeAll { $0.hasPrefix("/") || $0.hasPrefix("~/") }
        let joined = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",.;: "))
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Whether a folder is a git repo (a run gets its own branch) or a plain folder (the work happens in place).
    static func isGitRepo(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
    }

    /// Told to the agent when the folder Addy named has no git: edit it where it is, and leave git out of it.
    static let plainFolderNote = "\n\nThis folder isn't a git repository. Edit the files here and don't run git init or commit."

    /// The folder the work should go into: a "Repo: <path>" line Theo wrote, else a path in the pitch.
    static func targetRepo(answer: String, pitch: String) -> URL? {
        var candidates: [String] = []
        if let line = labeledLine("repo", in: answer) { candidates.append(line) }
        // A path in quotes or backticks (it can have spaces), then a bare ~/… or /Users/… one.
        for pattern in [#"[`"'](~?/[^`"']+)[`"']"#, #"(?:^|\s)((?:~|/Users|/Volumes|/private|/tmp|/opt)/[\w./-]+)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(pitch.startIndex..., in: pitch)
            candidates += regex.matches(in: pitch, range: range).compactMap { Range($0.range(at: 1), in: pitch).map { String(pitch[$0]) } }
        }
        for candidate in candidates {
            let path = (candidate.trimmingCharacters(in: CharacterSet(charactersIn: "`.,) ")) as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
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

    /// Creates the project (or a branch of `repo`) and starts the work on `harness` (the default coding target
    /// when nil): T3 Code's own thread, or a harness in Theo's terminal.
    static func submit(prompt: String, title: String, repo: URL?, harness: String? = nil) async throws -> T3Run {
        let target = harness ?? HarnessPrefs.codingTarget
        if target == CursorCloud.harnessID { return try await CursorCloud.start(prompt: prompt, title: title, repo: repo) }
        if target != "t3" { return try await HarnessCoding.start(harness: target, prompt: prompt, title: title, repo: repo) }
        guard let cli else { throw BotsT3Error.noCLI }
        var arguments = ["thread", "start"]
        var run: T3Run
        var plainFolder = false
        if let repo, !isGitRepo(repo) {
            plainFolder = true
            _ = try? await shell(cli, ["project", "add", repo.path])
            arguments += [repo.path, "-"]
            run = T3Run(id: "", title: title, folder: repo.path)
        } else if let repo {
            let branch = "theo/\(slug(title))-\(Int(Date().timeIntervalSince1970) % 100000)"
            let base = try await shell(git, ["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try? await shell(cli, ["project", "add", repo.path])
            arguments += [repo.path, "-", "--worktree", base, "--branch", branch]
            run = T3Run(id: "", title: title, folder: repo.path, repo: repo.path, branch: branch, baseCommit: base)
        } else {
            let folder = try newProjectFolder(title: title)
            saveBrief(prompt, title: title, engine: "T3 Code")
            try await shell(git, ["init", "-q", "-b", "main"], in: folder)
            try await startEmpty(in: folder)
            let base = try await shell(git, ["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
            try await shell(cli, ["project", "add", folder.path, "--title", title])
            arguments += [folder.path, "-"]
            run = T3Run(id: "", title: title, folder: folder.path, baseCommit: base)
        }
        // Settings › Harnesses can pick another model; Claude Opus 5.5 at high effort otherwise.
        let chosenModel = HarnessPrefs.codingModel ?? model
        let chosenEffort = HarnessPrefs.codingEffort ?? effort
        arguments += ["--title", title, "--provider", t3Provider(forModel: chosenModel), "--model", chosenModel, "--json"]
        let message = prompt + (plainFolder ? plainFolderNote : deliveryNote)
        run.model = chosenModel
        run.effort = chosenEffort
        run.prompt = prompt
        let output: String
        do {
            output = try await shell(cli, arguments + ["--effort", chosenEffort], stdin: message)
        } catch BotsT3Error.failed(let text) where text.contains("effort") {
            // A T3 Code build from before --effort: start it on the model's default effort.
            output = try await shell(cli, arguments, stdin: message)
        }
        guard let launched = jsonObject(in: output), let threadID = launched["threadId"] as? String else {
            throw BotsT3Error.failed("T3 Code didn't return the new thread: \(output.suffix(200))")
        }
        run.id = threadID
        run.link = launched["link"] as? String
        // T3 Code isn't brought forward by itself, since that takes focus from whatever the owner is doing. "Watch" on the card opens it.
        return run
    }

    /// T3 Code's driver for a model.
    static func t3Provider(forModel model: String) -> String {
        if model.hasPrefix("claude") { return provider }
        if model.hasPrefix("gpt") || model.hasPrefix("o1") || model.hasPrefix("o3") { return "codex" }
        if model.contains("/") { return "opencode" }
        return provider
    }

    /// Sends Addy's change to a run's thread; a busy agent gets it as its next turn.
    /// The commit a run's work is on now, so the next report shows only the change that follows.
    static func currentHead(of run: T3Run, worktree: String?) async -> String? {
        let folder = URL(fileURLWithPath: worktree ?? run.folder, isDirectory: true)
        return try? await shell(git, ["rev-parse", run.branch ?? "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sendFollowup(_ text: String, to run: T3Run) async throws {
        if run.harness == CursorCloud.harnessID { return try await CursorCloud.sendFollowup(text, to: run) }
        if HarnessCoding.owns(run) { return try await HarnessCoding.sendFollowup(text, to: run) }
        guard let cli else { throw BotsT3Error.noCLI }
        try await shell(cli, ["thread", "send", run.id, "-"], stdin: text + deliveryNote)
    }

    /// Brings the run's project up in the T3 Code app.
    static func openInApp(_ run: T3Run) {
        if run.harness == CursorCloud.harnessID {
            if let link = run.link.flatMap(URL.init(string:)) { NSWorkspace.shared.open(link) }
            return
        }
        if HarnessCoding.owns(run) { HarnessCoding.openInTerminal(run); return }
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

    /// The prompt a run was given, kept with Theo (not in the project, where the coding agent took it for a
    /// teammate's file): ~/Library/Application Support/Theo/briefs/<title>.md.
    static func saveBrief(_ prompt: String, title: String, engine: String) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Theo/briefs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "# \(title)\n\nThe prompt \(engine) received:\n\n\(prompt)\n"
            .write(to: folder.appendingPathComponent("\(slug(title)).md"), atomically: true, encoding: .utf8)
    }

    /// A first, empty commit, so the run's diff has something to start from.
    static func startEmpty(in folder: URL) async throws {
        try await shell(git, ["-c", "user.name=Theo", "-c", "user.email=theo@localhost", "commit", "-q", "--allow-empty", "-m", "Start"], in: folder)
    }

    static func newProjectFolder(title: String) throws -> URL {
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
        if run.harness == CursorCloud.harnessID { return await CursorCloud.state(of: run) }
        if HarnessCoding.owns(run) { return await HarnessCoding.state(of: run) }
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

    /// Everything the room hears when a run ends: the agent's report in words, with the facts on the run itself for its
    /// result card: files changed, Theo's own test run, the commit, the pushed branch and the draft PR.
    static func report(for run: inout T3Run, state: ThreadState) async -> String {
        let folder = URL(fileURLWithPath: state.worktree ?? run.worktree ?? run.folder, isDirectory: true)
        let minutes = max(1, Int((Date().timeIntervalSince(run.startedAt) / 60).rounded()))
        let stopped = run.stoppedByOwner == true
        let failed = ["failed", "interrupted", "cancelled", "rolled_back"].contains(state.status)
        let engine = run.harness.map { HarnessCatalog.label($0) } ?? "T3 Code"
        let usedModel = run.model.map(NativeBot.label(for:)) ?? modelName
        let usedEffort = run.effort ?? effort
        let modelPart = usedEffort == "default" ? usedModel : "\(usedModel), \(usedEffort) effort"
        var lines = [stopped
            ? "Stopped **\(run.title)** in \(engine) after \(minutes) min. The work so far is kept."
            : failed
            ? "**\(run.title)** stopped in \(engine) (\(state.status)) after \(minutes) min."
            : "**\(run.title)** is done in \(engine): \(modelPart), \(minutes) min."]
        if !stopped, let summary = state.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append(trimmedSummary(summary))
        }

        // Whatever the agent left uncommitted is committed, so the diff and the PR hold all of it. In a repo the owner
        // named that's only safe in the run's own worktree, never the checkout they work in.
        if (run.repo == nil && run.baseCommit != nil) || state.worktree != nil || run.worktree != nil {
            try? await commitAll(in: folder, message: "\(run.title): remaining changes from \(engine)")
        }
        let head = run.branch ?? "HEAD"
        if let base = run.baseCommit { run.changedFiles = await changes(in: folder, from: base, to: head) }
        if !failed, !stopped, run.repo == nil || state.worktree != nil || run.worktree != nil { run.tests = await runTests(in: folder) }

        if !stopped {
            if let pr = state.pullRequest {
                run.pullRequest = pr
            } else if !failed, let branch = run.branch {
                let outcome = await publish(in: folder, branch: branch, title: run.title, existing: run.pullRequest,
                                            body: state.lastMessage ?? "Built by \(engine) from Theo.", engine: engine, model: usedModel)
                run.pullRequest = outcome.url ?? run.pullRequest
                run.pullRequestProblem = outcome.problem
            }
        }
        if !failed && !stopped { lines.append("Write @code with a change and it goes to \(engine) on the same branch\(run.pullRequest == nil ? "" : " and pull request").") }
        return lines.joined(separator: "\n\n")
    }

    /// Files changed between two commits, from `git diff --numstat` ("12\t3\tpath"; binary files say "-").
    static func changes(in folder: URL, from base: String, to head: String) async -> [RunFileChange] {
        guard let output = try? await shell(git, ["diff", "--numstat", base, head], in: folder) else { return [] }
        return parseNumstat(output)
    }

    static func parseNumstat(_ output: String) -> [RunFileChange] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return RunFileChange(path: parts[2], added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
        }
    }

    private static func trimmedSummary(_ text: String) -> String {
        // Screenshots the agent saved to its scratchpad don't exist for the room; keep the words.
        let withoutImages = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)\n?"#, with: "", options: .regularExpression)
        guard withoutImages.count > 2400 else { return withoutImages }
        let head = String(withoutImages.prefix(2400))
        // End on a whole paragraph where there is one; the full report is in T3 Code.
        let cut = head.range(of: "\n\n", options: .backwards).map { String(head[..<$0.lowerBound]) } ?? head
        return cut + "\n\n_(The full report is in T3 Code.)_"
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
           let npm = tool("npm") {
            command = (npm, ["test", "--silent"])
        } else if let tests = nodeTestFiles(in: folder), let node = tool("node") {
            command = (node, ["--test"] + tests)
        } else if fm.fileExists(atPath: folder.appendingPathComponent("tests").path)
                    || fm.fileExists(atPath: folder.appendingPathComponent("pytest.ini").path),
                  let python = tool("python3") {
            command = (python, ["-m", "pytest", "-q"])
        }
        guard let (tool, arguments) = command else { return nil }
        do {
            let output = try await shell(tool, arguments, in: folder, limit: 240)
            return "passed. \(testCounts(in: output))"
        } catch {
            return "failed. \(error.localizedDescription.suffix(300))"
        }
    }

    /// *.test.js / *.test.mjs files in the folder or one level down (relative paths), for `node --test`.
    static func nodeTestFiles(in folder: URL) -> [String]? {
        let fm = FileManager.default
        var found: [String] = []
        let top = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in top where !name.hasPrefix(".") && name != "node_modules" {
            if name.hasSuffix(".test.js") || name.hasSuffix(".test.mjs") { found.append(name); continue }
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            for inner in (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(name).path)) ?? []
            where inner.hasSuffix(".test.js") || inner.hasSuffix(".test.mjs") {
                found.append("\(name)/\(inner)")
            }
        }
        return found.isEmpty ? nil : found.sorted()
    }

    /// The page a run built: index.html in its folder or one level down.
    static func page(of run: T3Run) -> URL? {
        let folder = URL(fileURLWithPath: run.folder, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("index.html").path) { return folder.appendingPathComponent("index.html") }
        for name in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() where !name.hasPrefix(".") && name != "node_modules" {
            let candidate = folder.appendingPathComponent(name).appendingPathComponent("index.html")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// "5 tests, 5 passed, 0 failed" from node's, npm's or pytest's summary lines, else the last line.
    static func testCounts(in output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var counts: [String] = []
        for key in ["tests", "pass", "fail"] {
            if let line = lines.last(where: { $0.hasPrefix("ℹ \(key) ") || $0.hasPrefix("# \(key) ") }),
               let number = line.split(separator: " ").last {
                counts.append("\(number) \(["tests": "tests", "pass": "passed", "fail": "failed"][key]!)")
            }
        }
        if !counts.isEmpty { return counts.joined(separator: ", ") }
        return String((lines.last { !$0.isEmpty } ?? "").prefix(160))
    }

    /// Pushes the run's branch and, the first time, opens a draft PR, when the repo lives on GitHub. A follow-up only
    /// pushes: the same pull request picks it up.
    private static func publish(in folder: URL, branch: String, title: String, existing: String?, body: String,
                                engine: String, model: String) async -> (url: String?, problem: String?) {
        guard let remote = try? await shell(git, ["remote", "get-url", "origin"], in: folder), remote.contains("github.com") else {
            return (nil, "This repo has no GitHub remote, so the work stays on the local branch.")
        }
        do {
            try await shell(git, ["push", "-u", "origin", branch], in: folder, limit: 120)
        } catch {
            return (existing, "Couldn't push: \(error.localizedDescription.suffix(200))")
        }
        if let existing { return (existing, nil) }
        guard let gh else { return (nil, "The branch is pushed, but GitHub's gh command isn't installed, so there's no pull request.") }
        do {
            let output = try await shell(gh, ["pr", "create", "--draft", "--head", branch, "--title", title,
                                              "--body", "From Theo, built in \(engine) on \(model).\n\n\(trimmedSummary(body))"], in: folder, limit: 60)
            return (output.split(separator: "\n").last { $0.hasPrefix("https://") }.map(String.init), nil)
        } catch {
            return (nil, "The branch is pushed, but the pull request failed: \(error.localizedDescription.suffix(200))")
        }
    }

    // MARK: Processes

    static let git = URL(fileURLWithPath: "/usr/bin/git")

    /// A command-line tool by name: the usual install folders, then the login shell's PATH (node from
    /// pnpm or nvm lives in the home folder, which a Mac app's PATH doesn't include).
    static func tool(_ name: String) -> URL? {
        let home = TheoProfile.realHome
        if let found = executable(["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)",
                                   "\(home)/Library/pnpm/\(name)", "/usr/bin/\(name)"]) { return found }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static func executable(_ paths: [String]) -> URL? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func commitAll(in folder: URL, message: String) async throws {
        let status = try await shell(git, ["status", "--porcelain"], in: folder)
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try await shell(git, ["add", "-A"], in: folder)
        try await shell(git, ["-c", "user.name=Theo", "-c", "user.email=theo@localhost", "commit", "-q", "-m", message], in: folder)
    }

    static func jsonObject(in output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any]
    }

    /// Runs a tool from home (or `folder`) and returns its output; a non-zero exit throws with the
    /// output's tail. Stopped after `limit` seconds.
    @discardableResult
    static func shell(_ executable: URL, _ arguments: [String], in folder: URL? = nil,
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
            environment["GH_PROMPT_DISABLED"] = "1"
            let home = TheoProfile.realHome
            environment["PATH"] = "\(executable.deletingLastPathComponent().path):\(home)/.local/bin:\(home)/Library/pnpm:" +
                "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
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
