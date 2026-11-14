//
//  BotsT3.swift
//  leanring-buddy
//
//  Hands the Project room's final prompt to T3 Code and follows it through:
//  a project (a new git repo in the projects folder, ~/Projects unless changed in Settings, or a new branch in a worktree
//  of a repo Addy named), a thread on Opus 5.5 at high effort, then the run
//  tracked until it ends. The result comes back to the room as a report:
//  the agent's summary, what changed, Theo's own test run, and a draft PR
//  when the work landed on a branch of a GitHub repo.
//

import AppKit
import ClickyCore
import Foundation

enum BotsT3Error: LocalizedError {
    case noCLI
    case failed(String)
    /// The thread asked for is already one of Theo's runs: that run's id.
    case alreadyARun(String)

    var errorDescription: String? {
        switch self {
        case .noCLI: return "T3 Code's t3 command isn't installed on this Mac (open T3 Code once to install it)."
        case .alreadyARun: return "That thread is already one of Theo's runs."
        case .failed(let message): return message
        }
    }
}

/// One coding run Theo started in T3 Code, saved so tracking survives a restart of Theo.
struct T3Run: Codable, Identifiable, Equatable {
    /// It runs on the other Mac: this one only shows it and passes on what's asked of it.
    var isRemote: Bool { origin != nil && origin != TheoLink.localName }

    /// T3 Code's thread id.
    var id: String
    var title: String
    /// Where the agent works: the new project folder, or the repo Addy named.
    var folder: String
    /// The repo Addy named, when the work goes on a branch of it.
    var repo: String?
    var branch: String?
    /// The commit the run started from, for the diff. A follow-up moves it on, so its report says what that follow-up changed.
    var baseCommit: String?
    /// Where the branch was cut from, which never moves: what's past it on the branch is the run's own work, not the owner's.
    var forkCommit: String?
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
    /// The branch the run was cut from, the pull request's base.
    var baseBranch: String?
    /// A cloud agent's latest run, after a follow-up started a new one.
    var cloudRunID: String?
    /// The run's own git worktree (harness runs on a repo Addy named).
    var worktree: String?
    /// The Mac it runs on; only that Mac follows it. Nil for runs from before the Macs were linked.
    var origin: String?
    /// The end of its terminal, for watching from the other Mac.
    var paneTail: String?
    /// The group chat that wrote its prompt: it hears how the run went too.
    var alsoRoom: String?
    /// What the result card shows, filled in when the run ends.
    var changedFiles: [RunFileChange]?
    var tests: String?
    /// Why there's no pull request, when one was expected.
    var pullRequestProblem: String?
    /// The agent's own report, for "Show the agent's report" on the result card.
    var fullReport: String?
    /// How far the wrap-up has got: "tests", "push" or "pr". Only for the live card.
    var stage: String?
    /// Stopped by the owner, so the report doesn't call it a failure.
    var stoppedByOwner: Bool?
    /// What it was asked, so a failed run can try again on another harness.
    var prompt: String?
    /// What was typed to the agent after the first prompt, so its report never quotes them back as its own words.
    var followups: [String]?
    /// It carries on an existing chat of its harness: that chat's title.
    var continuedChat: String?
    /// The exact session of its harness, so a follow-up never lands in another one. (T3 Code's is `id`.)
    var sessionID: String?
    /// Its harness doesn't say which chat a new run made, and Theo couldn't tell. It never guesses.
    var chatUnknown: Bool?
    /// Its repo has no remote: the run still has its own branch and worktree, but nothing is pushed and there's no pull request.
    var noRemote: Bool?
}

/// One file a run changed.
struct RunFileChange: Codable, Equatable, Identifiable {
    var path: String
    var added: Int
    var removed: Int
    var id: String { path }
}

enum BotsT3 {
    /// The coding model T3 Code builds with when the owner hasn't picked one in Settings › Harnesses: Opus 5.5 through
    /// T3 Code's Claude provider (`t3 thread start` needs a provider and a model). Only reached by someone who has T3 Code
    /// and sends builds to it; every other harness starts on its own default model.
    static let provider = "claudeAgent"
    static let model = "claude-opus-5-5"
    static let effort = "high"
    static let modelName = "Claude Opus 5.5"

    /// A private build of T3 Code ("T3 Code Cursor Assistant") that one Mac may have. It's used only where it's
    /// installed; a Mac without it never looks for it and gets stock T3 Code.
    enum PrivateT3Build {
        static let launcherPath = ".t3-claudia/bin/t3"
        static let appName = "T3 Code Cursor Assistant.app"
        static let bundleIdentifier = "com.addy.claudia.t3code"
    }

    /// Stock T3 Code's launcher in its data folder.
    static let stockLauncherPath = ".t3/bin/t3"

    /// The t3 launcher T3 Code writes into its data folder: the private build's when it's installed, else stock T3 Code's.
    static var cli: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [PrivateT3Build.launcherPath, stockLauncherPath].map { home.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var gh: URL? { tool("gh") }

    /// Told to the agent with every prompt, so the report has something to read back.
    static let deliveryNote = """


        ---
        When you're done: commit your work to git with a clear message, run the tests or checks you wrote and \
        say how they went, and end with a short report: what you did, how to run it, the tests and their results, and \
        anything left undone. If your sandbox can't commit, just leave the changes in the folder. Don't push or open a \
        pull request, and don't mention them in your report: Theo commits anything left over, pushes the branch and \
        opens the draft pull request after you finish.
        """

    /// The same for a branch of a repo with no remote: it's committed here, and nothing is pushed.
    static let localDeliveryNote = """


        ---
        When you're done: commit your work to git with a clear message, run the tests or checks you wrote and \
        say how they went, and end with a short report: what you did, how to run it, the tests and their results, and \
        anything left undone. If your sandbox can't commit, just leave the changes in the folder. Don't push or open a \
        pull request: this repo has no remote, so the work stays on this branch, and Theo commits anything left over.
        """

    static func deliveryNote(for run: T3Run) -> String { run.noRemote == true ? localDeliveryNote : deliveryNote }

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

    /// The git repo a folder belongs to, itself or a parent (a run gets its own branch). Nil for a plain folder, where
    /// the work happens in place. A home folder kept in git doesn't count, or every folder in it would get a branch.
    static func gitTopLevel(of folder: URL) async -> URL? {
        guard let output = try? await shell(git, ["rev-parse", "--show-toplevel"], in: folder) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path != TheoProfile.realHome, path != FileManager.default.homeDirectoryForCurrentUser.path else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// A worktree holds the whole repo, so an agent asked about a subfolder is told which one.
    static func subfolderNote(_ folder: URL, in repo: URL) -> String {
        let path = folder.resolvingSymlinksInPath().path
        let top = repo.resolvingSymlinksInPath().path
        guard path != top, path.hasPrefix(top + "/") else { return "" }
        return "The work is in the subfolder \(path.dropFirst(top.count + 1)) of this repository.\n\n"
    }

    /// What a follow-up ends with: a plain folder stays out of git, everything else commits.
    static func followupNote(for run: T3Run) -> String {
        if run.continuedChat != nil { return continuedNote }
        return run.repo == nil && run.baseCommit == nil ? plainFolderNote : deliveryNote(for: run)
    }

    /// A new project's folder is made first and the agent starts inside it, whatever a bot's prompt says about making one.
    static func newFolderNote(_ folder: URL) -> String {
        "You're already in this project's folder, \(folder.path). Work right here: don't make another folder or go anywhere else, whatever the instructions below say about where it goes.\n\n"
    }

    /// The same again after the instructions: a quick model follows whatever it read last.
    static let newFolderReminder = "\n\nRemember: this project's folder already exists and you're in it. Keep everything in the current folder."

    /// Where the project folders are, in words an agent's shell understands ("~/Projects" unless the owner moved it). A test profile's
    /// folders are its own, while its agents keep the owner's real home, so "~/…" would send them into the owner's real folders.
    static var projectsWords: String {
        TheoProfile.isTest ? projectsFolder.path
            : ProjectsFolder.words(forPath: projectsFolder.path, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// What goes to an agent. In a test profile "~/Projects" means that profile's folder, whoever wrote it.
    static func forAgent(_ text: String) -> String {
        TheoProfile.isTest ? text.replacingOccurrences(of: "~/Projects", with: projectsFolder.path) : text
    }

    /// Told to the agent when the folder Addy named has no git: edit it where it is, and leave git out of it.
    static let plainFolderNote = "\n\nThis folder isn't a git repository. Edit the files here and don't run git init or commit."

    /// The folder the work should go into: a "Repo: <path>" line Theo wrote, else a path in the pitch.
    static func targetRepo(answer: String, pitch: String, mustExist: Bool = true) -> URL? {
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
            if !mustExist || (FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue) {
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
    static func submit(prompt: String, title: String, repo: URL?, harness: String? = nil, modelChoice: String? = nil, effortChoice: String? = nil, newFolder: String? = nil, continuing: HarnessChatChoice? = nil, onWaiting: (@MainActor @Sendable () -> Void)? = nil) async throws -> T3Run {
        let target = harness ?? HarnessPrefs.codingTarget
        if let continuing { return try await continueChat(continuing, prompt: prompt, title: title, folder: repo, harness: target, modelChoice: modelChoice, effortChoice: effortChoice) }
        if target == CursorCloud.harnessID { return try await CursorCloud.start(prompt: prompt, title: title, repo: repo) }
        if target != "t3" { return try await HarnessCoding.start(harness: target, prompt: prompt, title: title, repo: repo, modelChoice: modelChoice, effortChoice: effortChoice, newFolder: newFolder, onWaiting: onWaiting) }
        guard let cli else { throw BotsT3Error.noCLI }
        // Everything below talks to T3 Code's server, so it's opened first when it's closed. Its CLI with no server up writes into T3 Code's folder.
        await openServerIfNeeded(cli: cli)
        var arguments = ["thread", "start"]
        var run: T3Run
        var plainFolder = false
        var subfolder = ""
        var topLevel: URL?
        if let repo { topLevel = await gitTopLevel(of: repo) }
        var repoHasRemote = false
        if let topLevel { repoHasRemote = await hasRemote(topLevel) }
        let placement = CodingPlacement.decide(folderNamed: repo != nil, isGitRepo: topLevel != nil, hasRemote: repoHasRemote)
        if let repo, placement == .inPlace {
            plainFolder = true
            _ = try? await shell(cli, ["project", "add", repo.path])
            arguments += [repo.path, "-"]
            run = T3Run(id: "", title: title, folder: repo.path)
        } else if let repo, let topLevel, placement.hasOwnBranch {
            // Its own branch and worktree, with or without a remote; one with no remote is never pushed.
            let branch = "theo/\(slug(title))-\(Int(Date().timeIntervalSince1970) % 100000)"
            let base = try await headCommit(in: topLevel)
            _ = try? await shell(cli, ["project", "add", topLevel.path])
            arguments += [topLevel.path, "-", "--worktree", base, "--branch", branch]
            run = T3Run(id: "", title: title, folder: topLevel.path, repo: topLevel.path, branch: branch, baseCommit: base)
            run.baseBranch = await currentBranch(in: topLevel)
            if !placement.publishes { run.noRemote = true }
            subfolder = subfolderNote(repo, in: topLevel)
        } else {
            let folder = try await newGitProject(title: newFolder ?? title)
            saveBrief(prompt, title: title, engine: "T3 Code")
            let base = try await shell(git, ["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
            try await shell(cli, ["project", "add", folder.path, "--title", title])
            arguments += [folder.path, "-"]
            run = T3Run(id: "", title: title, folder: folder.path, baseCommit: base)
            subfolder = newFolderNote(folder)
        }
        // Settings › Harnesses can pick another model; Claude Opus 5.5 at high effort otherwise.
        let chosenModel = modelChoice ?? (target == HarnessPrefs.codingTarget ? HarnessPrefs.codingModel : nil) ?? model
        let chosenEffort = effortChoice ?? (target == HarnessPrefs.codingTarget ? HarnessPrefs.codingEffort : nil) ?? effort
        arguments += ["--title", title, "--provider", t3Provider(forModel: chosenModel), "--model", chosenModel, "--json"]
        let message = forAgent(subfolder + prompt + (repo == nil ? newFolderReminder : "") + (plainFolder ? plainFolderNote : deliveryNote(for: run)))
        run.model = chosenModel
        run.effort = chosenEffort
        run.prompt = prompt
        let output: String
        do {
            output = try await startThread(cli: cli, arguments: arguments + ["--effort", chosenEffort], message: message)
        } catch BotsT3Error.failed(let text) where text.contains("effort") {
            // A T3 Code build from before --effort: start it on the model's default effort.
            output = try await startThread(cli: cli, arguments: arguments, message: message)
        }
        guard let launched = jsonObject(in: output), let threadID = launched["threadId"] as? String else {
            throw BotsT3Error.failed("T3 Code didn't return the new thread: \(output.suffix(200))")
        }
        run.id = threadID
        run.link = launched["link"] as? String
        // T3 Code isn't brought forward by itself, since that takes focus from whatever the owner is doing. "Watch" on the card opens it.
        return run
    }

    /// What a continued chat ends with. It's the owner's chat in the owner's folder, so what happens to git is up to them.
    static let continuedNote = "\n\n---\nWhen you're done, end with a short report: what you did, how to run it, the tests and their results, and anything left undone."

    /// Carries on a chat the harness already has, in its own folder: no new branch or worktree, and its own session, by id.
    static func continueChat(_ choice: HarnessChatChoice, prompt: String, title: String, folder: URL?, harness: String, modelChoice: String?, effortChoice: String?) async throws -> T3Run {
        guard let folder else { throw BotsT3Error.failed("That needs the folder the chat is in. Pick a folder first.") }
        let label = harness == "t3" ? "T3 Code" : HarnessCatalog.label(harness)
        // T3 Code's threads can only be listed with its server up.
        if harness == "t3", let cli { await openServerIfNeeded(cli: cli) }
        let chats = await HarnessChats.list(harness: harness, folder: folder.path)
        guard let chat = choice.match(in: chats) ?? choice.title.map({ HarnessChat(id: choice.idOrTitle, title: $0, updatedAt: Date()) }) else {
            throw BotsT3Error.failed("\(label) has no chat called \"\(choice.idOrTitle)\" in \(folder.lastPathComponent).")
        }
        var run = T3Run(id: "", title: title, folder: folder.path)
        run.continuedChat = chat.title
        run.sessionID = chat.id
        run.prompt = prompt
        run.baseCommit = (try? await shell(git, ["rev-parse", "HEAD"], in: folder))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = prompt + continuedNote
        guard harness == "t3" else {
            return try await HarnessCoding.continueChat(chat.id, run: run, harness: harness, message: message, modelChoice: modelChoice, effortChoice: effortChoice)
        }
        // A thread's id is its run's id. One Theo already follows carries on as that run: a second under the same id would wipe out its branch, pull request and report.
        if await MainActor.run(body: { BotsStore.shared.t3Runs.contains { $0.id == chat.id } }) { throw BotsT3Error.alreadyARun(chat.id) }
        guard let cli else { throw BotsT3Error.noCLI }
        _ = try await startThread(cli: cli, arguments: ["thread", "send", chat.id, "-"], message: message)
        run.id = chat.id
        return run
    }

    /// Opens T3 Code hidden when its server isn't up, without taking focus, and waits for it a while.
    private static func openServerIfNeeded(cli: URL) async {
        guard !HarnessChats.isT3ServerUp, let app = app(forCLI: cli) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        let front = await MainActor.run { BackgroundInput.FrontmostSnapshot.capture() }
        if let started = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration) {
            let identifier = started.processIdentifier
            await MainActor.run { front.restore(ifStolenBy: [identifier]) }
        }
        for _ in 0..<20 where !HarnessChats.isT3ServerUp { try? await Task.sleep(nanoseconds: 1_500_000_000) }
    }

    /// `t3 thread start`, opening T3 Code first when its server isn't running: hidden and without taking focus, so
    /// the owner doesn't have to start it by hand and whatever they're doing stays in front.
    private static func startThread(cli: URL, arguments: [String], message: String) async throws -> String {
        do {
            return try await shell(cli, arguments, stdin: message)
        } catch BotsT3Error.failed(let text) where text.contains("No running T3 Code server") {
            guard let app = app(forCLI: cli) else { throw BotsT3Error.failed("T3 Code isn't installed. Install it in Settings › Harnesses, or send builds to another harness.") }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            // Electron apps bring themselves forward as they start, whatever they're asked: Theo hands focus straight back.
            let front = await MainActor.run { BackgroundInput.FrontmostSnapshot.capture() }
            if let started = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration) {
                let identifier = started.processIdentifier
                await MainActor.run { front.restore(ifStolenBy: [identifier]) }
            }
            var lastProblem = text
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    return try await shell(cli, arguments, stdin: message)
                } catch BotsT3Error.failed(let problem) where problem.contains("No running T3 Code server") {
                    lastProblem = problem
                }
            }
            throw BotsT3Error.failed("T3 Code didn't start in time: \(lastProblem.suffix(160))")
        }
    }

    /// The T3 Code app whose data folder a `t3` launcher uses.
    private static func app(forCLI cli: URL) -> URL? {
        let stockNames = ["T3 Code (Nightly).app", "T3 Code.app", "T3 Code (Alpha).app"]
        let names = cli.path.hasSuffix(PrivateT3Build.launcherPath) ? [PrivateT3Build.appName] + stockNames : stockNames
        return names.map { URL(fileURLWithPath: "/Applications/\($0)") }.first { FileManager.default.fileExists(atPath: $0.path) }
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

    /// Passes a change to the run's agent. Returns a cloud agent's new run id, when it started one.
    @discardableResult
    static func sendFollowup(_ text: String, to run: T3Run) async throws -> String? {
        if run.harness == CursorCloud.harnessID { return try await CursorCloud.sendFollowup(text, to: run) }
        if HarnessCoding.owns(run) {
            try await HarnessCoding.sendFollowup(text, to: run)
            return nil
        }
        guard let cli else { throw BotsT3Error.noCLI }
        // An agent waiting on a question gets just the answer.
        try await shell(cli, ["thread", "send", run.id, "-"], stdin: run.phase == "waiting" ? text : text + followupNote(for: run))
        return nil
    }

    static func currentBranch(in folder: URL) async -> String? {
        let branch = (try? await shell(git, ["rev-parse", "--abbrev-ref", "HEAD"], in: folder))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch == "HEAD" ? nil : branch
    }

    /// Brings the run's project up in the T3 Code app.
    /// Stops a T3 Code thread as its Stop button does. False when it couldn't: stock T3 Code has no such command.
    @discardableResult
    static func stopThread(_ run: T3Run) async -> Bool {
        guard let cli else { return false }
        return (try? await shell(cli, ["thread", "stop", run.id])) != nil
    }

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
        let app = [PrivateT3Build.bundleIdentifier, "com.t3tools.t3code"].lazy
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

    /// The commit a run starts from. A repo that has no commit yet (just `git init`) gets the same empty "Start" commit a new
    /// folder gets, instead of failing with git's "ambiguous argument 'HEAD'".
    static func headCommit(in folder: URL) async throws -> String {
        if let head = try? await shell(git, ["rev-parse", "--verify", "-q", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty {
            return head
        }
        try await startEmpty(in: folder)
        return try await shell(git, ["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A first, empty commit, so the run's diff has something to start from.
    static func startEmpty(in folder: URL) async throws {
        try await shell(git, ["-c", "user.name=Theo", "-c", "user.email=theo@localhost", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "Start"], in: folder)
    }

    /// Whether a repo pushes anywhere.
    static func hasRemote(_ folder: URL) async -> Bool {
        let remotes = (try? await shell(git, ["remote"], in: folder)) ?? ""
        return !remotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The projects folder (Settings › Harnesses, `v2.code.projectsFolder`, default ~/Projects). Not made until the first project needs it.
    static var projectsFolder: URL {
        URL(fileURLWithPath: ClickySettings.projectsFolderPath(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path), isDirectory: true)
    }

    /// The owner's project folders.
    static func projectNames() -> [String] { projects().map(\.name).sorted() }

    /// The owner's project folders on this Mac, newest first.
    static func projects() -> [DeviceProject] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let found = (try? FileManager.default.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return found.compactMap { url -> DeviceProject? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { return nil }
            return DeviceProject(name: url.lastPathComponent, path: url.path, modifiedAt: values.contentModificationDate)
        }.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    enum MadeProject {
        case made(URL)
        case alreadyThere(URL)
        case failed(String)
    }

    /// A new folder in the projects folder on this Mac, with git and an empty first commit. Used wherever a folder is made, in chat or from a run's card.
    static func makeProject(named name: String) async -> MadeProject {
        let exact = projectsFolder.appendingPathComponent(slug(name), isDirectory: true)
        if FileManager.default.fileExists(atPath: exact.path) { return .alreadyThere(exact) }
        do {
            return .made(try await newGitProject(title: name))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A new project folder with git and an empty first commit. If git can't do that the folder goes again: one left behind with no git would get picked next time.
    static func newGitProject(title: String) async throws -> URL {
        let folder = try newProjectFolder(title: title)
        do {
            try await shell(git, ["init", "-q", "-b", "main"], in: folder)
            try await startEmpty(in: folder)
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func newProjectFolder(title: String) throws -> URL {
        let projects = projectsFolder
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
    static func report(for run: inout T3Run, state: ThreadState, onStage: ((String) -> Void)? = nil) async -> String {
        let folder = URL(fileURLWithPath: state.worktree ?? run.worktree ?? run.folder, isDirectory: true)
        let minutes = max(1, Int((Date().timeIntervalSince(run.startedAt) / 60).rounded()))
        let stopped = run.stoppedByOwner == true
        let failed = ["failed", "interrupted", "cancelled", "rolled_back"].contains(state.status)
        let engine = run.harness.map { HarnessCatalog.label($0) } ?? "T3 Code"
        let usedModel = run.model.map(NativeBot.label(for:)) ?? modelName
        let usedEffort = run.effort ?? effort
        // A continued chat keeps the model it was on, which Theo doesn't always know. It isn't claimed.
        let knowsModel = run.continuedChat == nil || (run.model != nil && run.model != run.harness.map { HarnessCatalog.label($0) })
        let modelPart = !knowsModel ? nil : usedEffort == "default" ? usedModel : "\(usedModel), \(usedEffort) effort"
        // Whatever the agent left uncommitted is committed, so the diff and the PR hold all of it. In a repo the owner
        // named that's only safe in the run's own worktree, never the checkout they work in.
        var commitProblem: String?
        var leftOut: [String] = []
        // A chat the owner picked to continue is theirs: its agent commits or not, as it always has, in the folder itself.
        if run.continuedChat == nil, (run.repo == nil && run.baseCommit != nil) || state.worktree != nil || run.worktree != nil {
            do {
                leftOut = try await commitAll(in: folder, message: "\(run.title): remaining changes from \(engine)")
            } catch {
                commitProblem = "Theo couldn't commit the agent's changes: \(error.localizedDescription.suffix(200))"
            }
        }
        let head = run.branch ?? "HEAD"
        if let base = run.baseCommit { run.changedFiles = await changes(in: folder, from: base, to: head) }
        var lines = [stopped
            ? "Stopped **\(run.title)** in \(engine) after \(minutes) min. " + ((run.changedFiles ?? []).isEmpty ? "It hadn't changed anything yet." : "The work so far is kept on its branch.")
            : failed
            ? "**\(run.title)** stopped in \(engine) (\(state.status)) after \(minutes) min."
            : "**\(run.title)** is done in \(engine)\(modelPart.map { ": \($0)," } ?? ",") \(minutes) min."]
        if !stopped, let summary = state.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            // The chat gets the first paragraph in plain words; the agent's whole report folds up on the card. A heading alone says nothing.
            let paragraphs = summary.components(separatedBy: "\n\n")
            let first = paragraphs.first { !$0.hasPrefix("#") } ?? paragraphs.first ?? summary
            lines.append(first.count > 500 ? String(first.prefix(500)) + "…" : first)
            run.fullReport = trimmedSummary(summary)
        }
        if !failed, !stopped, run.repo == nil || state.worktree != nil || run.worktree != nil {
            onStage?("tests")
            run.tests = await runTests(in: folder)
        }

        var problems: [String] = []
        if !stopped {
            if let pr = state.pullRequest {
                run.pullRequest = pr
            } else if !failed, let branch = run.branch, run.noRemote == true {
                // Nowhere to push: the work stays on its branch here, and the room is told so.
                if let commitProblem { problems.append(commitProblem) }
                lines.append(CodingPlacement.localBranchWords(branch: branch))
            } else if !failed, let branch = run.branch {
                let changed = run.changedFiles ?? []
                if let commitProblem {
                    problems.append(commitProblem)
                } else if changed.isEmpty {
                    if run.pullRequest == nil { problems.append("The agent didn't change anything, so there's nothing to push.") }
                } else if let secret = changed.first(where: { looksLikeSecret($0.path) }) {
                    problems.append("Theo didn't push because \(secret.path) looks like a secret. Take it out of the branch, then write @code push.")
                } else {
                    onStage?("push")
                    let outcome = await publish(in: folder, branch: branch, title: run.title, existing: run.pullRequest, base: run.forkCommit ?? run.baseCommit, baseBranch: run.baseBranch,
                                                body: state.lastMessage ?? "Built by \(engine) from Theo.", engine: engine, model: usedModel, onStage: onStage)
                    run.pullRequest = outcome.url ?? run.pullRequest
                    if let problem = outcome.problem { problems.append(problem) }
                }
            }
        }
        if !leftOut.isEmpty { problems.append("Left out of the commit, because they look like secrets: \(leftOut.joined(separator: ", ")).") }
        run.pullRequestProblem = problems.isEmpty ? nil : problems.joined(separator: " ")
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
        } else if let tests = nodeTestFiles(in: folder), !needsPackages(folder), let node = tool("node") {
            command = (node, ["--test"] + tests)
        } else if hasPythonTests(folder), let python = tool("python3") {
            command = (python, ["-m", "pytest", "-q"])
        }
        guard let (tool, arguments) = command else { return nil }
        do {
            let output = try await shell(tool, arguments, in: folder, limit: 240)
            return "passed. \(testCounts(in: output))"
        } catch {
            let text = error.localizedDescription
            // The tests never ran, which says nothing about the work.
            if text.range(of: #"No module named|Cannot find module|ERR_MODULE_NOT_FOUND|command not found"#, options: .regularExpression) != nil {
                return "couldn't run them here: \(text.suffix(200))"
            }
            return "failed. \(text.suffix(300))"
        }
    }

    /// A fresh worktree has no node_modules, so a project with packages can't run its tests until someone installs them.
    private static func needsPackages(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.appendingPathComponent("node_modules").path),
              let data = fm.contents(atPath: folder.appendingPathComponent("package.json").path),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return ["dependencies", "devDependencies"].contains { !((package[$0] as? [String: Any]) ?? [:]).isEmpty }
    }

    private static func hasPythonTests(_ folder: URL) -> Bool {
        let fm = FileManager.default
        if ["pytest.ini", "pyproject.toml", "setup.py", "conftest.py", "tox.ini"].contains(where: { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) { return true }
        let tests = (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("tests").path)) ?? []
        return tests.contains { $0.hasSuffix(".py") }
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
    private static func publish(in folder: URL, branch: String, title: String, existing: String?, base: String?, baseBranch: String?, body: String,
                                engine: String, model: String, onStage: ((String) -> Void)? = nil) async -> (url: String?, problem: String?) {
        guard let remote = try? await shell(git, ["remote", "get-url", "origin"], in: folder), remote.contains("github.com") else {
            return (nil, "This repo has no GitHub remote, so the work stays on the local branch.")
        }
        // GitHub is the truth: a pull request this branch already has (opened by an earlier try whose answer got lost, a slow
        // network, a restart) is used again rather than opening a second one or refusing to push.
        var existing = existing
        if existing == nil { existing = await openPullRequest(for: branch, in: folder) }
        // The branch was cut from wherever the owner was. Commits of theirs that aren't on GitHub yet would go up with it.
        if existing == nil, let base,
           let count = try? await shell(git, ["rev-list", "--count", base, "--not", "--remotes=origin"], in: folder),
           let unpushed = Int(count.trimmingCharacters(in: .whitespacesAndNewlines)), unpushed > 0 {
            return (nil, "The branch it started from has \(unpushed == 1 ? "1 commit that isn't" : "\(unpushed) commits that aren't") on GitHub yet, and a pull request would publish \(unpushed == 1 ? "it" : "them") too. Push that branch, then write @code push.")
        }
        do {
            try await shell(git, ["push", "-u", "origin", branch], in: folder, limit: 120)
        } catch {
            return (existing, "Couldn't push: \(error.localizedDescription.suffix(200))")
        }
        if let existing { return (existing, nil) }
        onStage?("pr")
        guard let gh else { return (nil, "The branch is pushed, but GitHub's gh command isn't installed, so there's no pull request.") }
        var arguments = ["pr", "create", "--draft", "--head", branch, "--title", title,
                         "--body", "From Theo, built in \(engine) on \(model).\n\n\(trimmedSummary(body))"]
        if let baseBranch, (try? await shell(git, ["ls-remote", "--exit-code", "--heads", "origin", baseBranch], in: folder, limit: 30)) != nil {
            arguments += ["--base", baseBranch]
        }
        do {
            let output = try await shell(gh, arguments, in: folder, limit: 60)
            return (output.split(separator: "\n").last { $0.hasPrefix("https://") }.map(String.init), nil)
        } catch {
            // It may have been made anyway (gh timed out after GitHub said yes).
            if let made = await openPullRequest(for: branch, in: folder) { return (made, nil) }
            return (nil, "The branch is pushed, but the pull request failed: \(error.localizedDescription.suffix(200))")
        }
    }

    /// The open pull request for this branch on GitHub, if there is one.
    private static func openPullRequest(for branch: String, in folder: URL) async -> String? {
        guard let gh, let output = try? await shell(gh, ["pr", "list", "--head", branch, "--state", "open", "--json", "url", "--jq", ".[0].url"], in: folder, limit: 30) else { return nil }
        let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.hasPrefix("https://") ? url : nil
    }

    // MARK: Processes

    static let git = URL(fileURLWithPath: "/usr/bin/git")

    /// A command-line tool by name: the usual install folders, then the login shell's PATH (node from
    /// pnpm or nvm lives in the home folder, which a Mac app's PATH doesn't include).
    static func tool(_ name: String) -> URL? {
        // The real home's folders first: in a test profile the home folder is the profile's own.
        let home = TheoProfile.realHome
        if let found = executable(["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)",
                                   "\(home)/Library/pnpm/\(name)", "/usr/bin/\(name)"]) { return found }
        // Then Theo's one finder, which asks the owner's own login shell for its PATH.
        return HarnessCatalog.locate(binary: name)
    }

    private static func executable(_ paths: [String]) -> URL? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Keys and env files an agent left lying around, which shouldn't reach a commit unless someone means it to.
    static func looksLikeSecret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == ".env" { return true }
        if name.hasPrefix(".env."), ![".env.example", ".env.sample", ".env.template"].contains(name) { return true }
        if ["pem", "key", "p12", "pfx"].contains((name as NSString).pathExtension) { return true }
        return name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name == "credentials.json"
    }

    /// Commits what's there, leaving out what looks like a secret. Returns what it left out.
    @discardableResult
    static func commitAll(in folder: URL, message: String) async throws -> [String] {
        let status = try await shell(git, ["status", "--porcelain"], in: folder)
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        try await shell(git, ["add", "-A"], in: folder)
        let staged = try await shell(git, ["diff", "--cached", "--name-only"], in: folder).split(separator: "\n").map(String.init)
        let secrets = staged.filter(looksLikeSecret)
        if !secrets.isEmpty { try await shell(git, ["reset", "-q", "--"] + secrets, in: folder) }
        guard staged.count > secrets.count else { return secrets }
        try await shell(git, ["-c", "user.name=Theo", "-c", "user.email=theo@localhost", "commit", "-q", "-m", message], in: folder)
        return secrets
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
        // Blocks until the tool ends, so it stays off the small pool Swift's tasks run on.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runTool(executable, arguments, in: folder, stdin: stdin, limit: limit) })
            }
        }
    }

    private static func runTool(_ executable: URL, _ arguments: [String], in folder: URL?, stdin: String?, limit: Double) throws -> String {
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

        let collected = CollectedOutput()
        let reachedEnd = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                reachedEnd.signal()
            } else {
                collected.append(chunk)
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if let stdin {
            try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + limit) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // Something it left running (a test's server, ssh's control master) can hold the pipe open forever.
        _ = reachedEnd.wait(timeout: .now() + 2)
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        let text = collected.text
        if timedOut {
            throw BotsT3Error.failed("\(executable.lastPathComponent) \(arguments.first ?? "") took over \(Int(limit)) s and was stopped: \(text.suffix(300))")
        }
        if process.terminationStatus != 0 {
            throw BotsT3Error.failed("\(executable.lastPathComponent) \(arguments.first ?? "") failed: \(text.suffix(300))")
        }
        return text
    }

    /// A tool's output as it arrives, on the pipe's own queue.
    private final class CollectedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
