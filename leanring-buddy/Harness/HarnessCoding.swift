//
//  HarnessCoding.swift
//  leanring-buddy
//
//  The coding hand-off through a harness's own CLI instead of T3 Code. With a coding target of claude,
//  codex, cursor, opencode, grok or gemini, BotsT3.submit lands here: the harness's interactive CLI starts
//  in a real terminal inside Theo (a SwiftTerm TerminalSession the user can watch, type into and pop out), the
//  prompt is pasted in, and the run is tracked by watching the screen and the harness's transcript. tmux is
//  used only when it is installed and the user turned "use tmux" on. If the terminal can't start, the harness
//  runs headless with write access in the project folder. Runs are T3Run values like T3 Code's, so BotsStore, the room
//  cards and BotsT3.report work unchanged.
//
//  Run ids: "term:<uuid>", "tmux:<session>" or "headless:<uuid>".
//

import AppKit
import Foundation

enum HarnessCoding {
    /// A run that went through a harness CLI (T3 Code runs have no `harness`).
    static func owns(_ run: T3Run) -> Bool { run.harness != nil }

    static var tmux: URL? { HarnessCatalog.locate(binary: "tmux") }

    /// Whether coding runs go through tmux (when installed) instead of Theo's own terminal. Off by default.
    static var useTmux: Bool {
        get { UserDefaults.standard.bool(forKey: "theo.coding.useTmux") }
        set { UserDefaults.standard.set(newValue, forKey: "theo.coding.useTmux") }
    }

    // MARK: Command lines

    /// The interactive command for a coding run. Full access inside the project folder, since the user asked
    /// for this run and may not be watching: Claude accepts edits, Codex writes the workspace and asks for
    /// anything beyond it, Cursor/OpenCode auto-approve, Grok and Gemini accept edits.
    /// `gitFolder`: the repo's own .git, which sits outside a worktree. Codex's sandbox has to be able to write there, or it can't commit.
    /// `continues`: picks up the last conversation in that folder, for a follow-up after the terminal has gone.
    static func interactiveArguments(harness: String, model: String?, effort: String?, folder: String, gitFolder: String? = nil, continues: Bool = false) -> [String] {
        var args: [String] = []
        if continues {
            switch harness {
            case "claude", "cursor", "grok": args += ["--continue"]
            case "codex": args += ["resume", "--last"]
            case "gemini": args += ["--resume", "latest"]
            default: break
            }
        }
        switch harness {
        case "claude":
            if let model { args += ["--model", model] }
            if let effort { args += ["--effort", effort] }
            args += ["--permission-mode", "auto"]
        case "codex":
            if let model { args += ["-m", model] }
            if let effort { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            args += ["-c", "check_for_update_on_startup=false", "--sandbox", "workspace-write", "-a", "never", "-C", folder]
            if let gitFolder { args += ["--add-dir", gitFolder] }
        case "cursor":
            if let model { args += ["--model", model] }
            args += ["--workspace", folder, "--force", "--trust"]
        case "opencode":
            if let model { args += ["-m", model] }
            args += ["--auto", folder]
        case "grok":
            if let model { args += ["-m", model] }
            if let effort { args += ["--reasoning-effort", effort] }
            args += ["--cwd", folder, "--permission-mode", "auto"]
        case "gemini":
            if let model { args += ["-m", model] }
            args += ["--approval-mode", "auto_edit"]
        default: break
        }
        return args
    }

    /// The headless (no tmux) command: the prompt is part of it.
    static func headlessArguments(harness: String, model: String?, effort: String?, folder: String, prompt: String, outFile: String) -> [String] {
        var args: [String] = []
        switch harness {
        case "claude":
            args = ["-p", "--output-format", "json", "--permission-mode", "auto"]
            if let model { args += ["--model", model] }
            if let effort { args += ["--effort", effort] }
            args += ["--", prompt]
        case "codex":
            args = ["exec", "--json", "--skip-git-repo-check", "-C", folder]
            if let model { args += ["-m", model] }
            if let effort { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            args += ["-c", "check_for_update_on_startup=false", "-s", "workspace-write", "-o", outFile, "--", prompt]
        case "cursor":
            args = ["-p", "--output-format", "text", "--force", "--trust", "--workspace", folder]
            if let model { args += ["--model", model] }
            args += [prompt]
        case "opencode":
            args = ["run", "--format", "json", "--dir", folder]
            if let model { args += ["-m", model] }
            if let effort { args += ["--variant", effort] }
            args += [prompt]
        case "grok":
            args = ["-p", prompt, "--output-format", "streaming-messages-json", "--permission-mode", "auto"]
            if let model { args += ["-m", model] }
            if let effort { args += ["--reasoning-effort", effort] }
        case "gemini":
            args = ["-p", prompt, "--output-format", "json", "--approval-mode", "auto_edit"]
            if let model { args += ["-m", model] }
        default: break
        }
        return args
    }

    /// The final reply from a headless run's stdout (and Codex's -o file).
    static func headlessReply(harness: String, stdout: String, outFile: String) -> String? {
        func object(_ text: String) -> [String: Any]? {
            guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
        }
        let reply: String?
        switch harness {
        case "claude": reply = object(stdout)?["result"] as? String
        case "gemini": reply = object(stdout)?["response"] as? String
        case "codex": reply = try? String(contentsOfFile: outFile, encoding: .utf8)
        case "cursor": reply = stdout
        case "opencode":
            var parser = BotStreamParser(isClaude: false)
            for line in stdout.split(separator: "\n") { _ = parser.consume(String(line)) }
            reply = parser.text
        case "grok":
            var last: String?
            for line in stdout.split(separator: "\n") {
                if let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                   event["type"] as? String == "result" { last = event["result"] as? String }
            }
            reply = last
        default: reply = nil
        }
        let trimmed = reply?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Starting

    static func start(harness: String, prompt: String, title: String, repo: URL?) async throws -> T3Run {
        guard let executable = HarnessCatalog.executable(for: harness) else {
            throw BotsT3Error.failed("\(HarnessCatalog.label(harness)) isn't installed on this Mac, so the coding run can't start there. Pick another coding target in Settings.")
        }
        // The coding target's model and effort are for that harness only; another one would refuse to start on them.
        let isCodingTarget = harness == HarnessPrefs.codingTarget
        let model = (isCodingTarget ? HarnessPrefs.codingModel : nil) ?? HarnessPrefs.defaultModel(harness) ?? (harness == "codex" ? codexPlanModel() : nil)
        let effort = (isCodingTarget ? HarnessPrefs.codingEffort : nil) ?? HarnessPrefs.defaultEffort(harness)
        let git = BotsT3.git
        var run: T3Run
        let workdir: URL
        var plainFolder = false
        var gitFolder: String?
        var topLevel: URL?
        if let repo { topLevel = await BotsT3.gitTopLevel(of: repo) }
        if let repo, topLevel == nil {
            // A plain folder: the work happens right there, with no branch and nothing added to it.
            plainFolder = true
            workdir = repo
            run = T3Run(id: "", title: title, folder: repo.path)
        } else if let repo = topLevel {
            // A branch in its own worktree, like T3 Code's: Addy's checkout is never touched.
            let branch = "theo/\(BotsT3.slug(title))-\(Int(Date().timeIntervalSince1970) % 100000)"
            let base = try await BotsT3.shell(git, ["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
            let trees = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Theo/worktrees", isDirectory: true)
            try FileManager.default.createDirectory(at: trees, withIntermediateDirectories: true)
            workdir = trees.appendingPathComponent("\(BotsT3.slug(title))-\(Int(Date().timeIntervalSince1970) % 100000)", isDirectory: true)
            try await BotsT3.shell(git, ["worktree", "add", "-b", branch, workdir.path, base], in: repo)
            run = T3Run(id: "", title: title, folder: repo.path, repo: repo.path, branch: branch, baseCommit: base)
            run.worktree = workdir.path
            run.baseBranch = await BotsT3.currentBranch(in: repo)
            gitFolder = repo.appendingPathComponent(".git").path
        } else {
            workdir = try BotsT3.newProjectFolder(title: title)
            BotsT3.saveBrief(prompt, title: title, engine: HarnessCatalog.label(harness))
            try await BotsT3.shell(git, ["init", "-q", "-b", "main"], in: workdir)
            try await BotsT3.startEmpty(in: workdir)
            let base = try await BotsT3.shell(git, ["rev-parse", "HEAD"], in: workdir).trimmingCharacters(in: .whitespacesAndNewlines)
            run = T3Run(id: "", title: title, folder: workdir.path, baseCommit: base)
        }
        run.harness = harness
        run.model = model ?? HarnessCatalog.label(harness)
        run.effort = effort ?? "default"
        run.prompt = prompt
        var message = prompt + (plainFolder ? BotsT3.plainFolderNote : BotsT3.deliveryNote)
        if let branch = run.branch, let named = repo, let repo = topLevel {
            // The prompt names the project's own path; without this the agent goes there and works in Addy's checkout.
            message = "You are already in a git worktree of \(repo.path), at \(workdir.path), on branch \(branch). " +
                "Do all the work and commit here. Don't cd to \(repo.path) or change it, and don't switch branches.\n\n" +
                BotsT3.subfolderNote(named, in: repo) + message
        }

        // A saved key can't go through tmux without showing up in a process's arguments, so that run takes Theo's own terminal.
        if useTmux, let tmux, HarnessCatalog.apiKeyEnvironment(for: harness).isEmpty {
            let session = "theo-\(BotsT3.slug(title).prefix(30))-\(Int(Date().timeIntervalSince1970) % 100000)"
            let unset = HarnessCatalog.scrubbedVariableNames.flatMap { ["-u", $0] }
            let command = (["env"] + unset + [executable.path] +
                           interactiveArguments(harness: harness, model: model, effort: effort, folder: workdir.path, gitFolder: gitFolder)).map(quoted).joined(separator: " ")
            try await BotsT3.shell(tmux, ["new-session", "-d", "-s", session, "-c", workdir.path, "-x", "180", "-y", "50", command])
            run.id = "tmux:\(session)"
            try await deliver(message, to: session, tmux: tmux)
            PaneWatch.reset(session)
        } else if let terminal = await startTerminal(harness: harness, executable: executable, model: model, effort: effort, folder: workdir, title: title, gitFolder: gitFolder) {
            run.id = terminal.id
            await deliver(message, to: terminal, isFirstPrompt: true)
            PaneWatch.reset(terminal.id)
            PaneWatch.delivered(terminal.id)
        } else {
            run.id = "headless:\(UUID().uuidString.lowercased())"
            startHeadless(id: run.id, harness: harness, executable: executable, model: model, effort: effort, folder: workdir, prompt: message)
        }
        return run
    }

    /// Codex's config can name a model the signed-in plan can't use, and the run then dies at once. With no model
    /// picked in Theo, that one is swapped for the first model the plan lists.
    static func codexPlanModel() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex/models_cache.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        let listed = models.filter { $0["visibility"] as? String == "list" }.compactMap { $0["slug"] as? String }
        let config = (try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
        let configured = config.split(separator: "\n").first { $0.hasPrefix("model =") || $0.hasPrefix("model=") }
            .map { $0.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        if let configured, listed.contains(configured) { return nil }
        return listed.first
    }

    // MARK: In-app terminal

    @MainActor
    private static func startTerminal(harness: String, executable: URL, model: String?, effort: String?, folder: URL, title: String, gitFolder: String?) async -> TerminalSession? {
        let id = "term:\(UUID().uuidString.lowercased())"
        let args = interactiveArguments(harness: harness, model: model, effort: effort, folder: folder.path, gitFolder: gitFolder)
        // No self-updates mid-run: OpenCode's update dialog swallowed the prompt.
        var environment = TerminalSession.defaultEnvironment()
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
        environment.merge(HarnessCatalog.apiKeyEnvironment(for: harness)) { _, new in new }
        return TerminalSessions.shared.start(id: id, title: "\(HarnessCatalog.label(harness)) · \(title)", command: executable.path,
                                             arguments: args, environment: environment, workingDirectory: folder.path)
    }

    /// A fresh terminal under an existing run's id.
    @MainActor
    private static func restartTerminal(id: String, harness: String, executable: URL, model: String?, effort: String?, folder: URL, title: String, gitFolder: String?) -> TerminalSession? {
        var environment = TerminalSession.defaultEnvironment()
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
        environment.merge(HarnessCatalog.apiKeyEnvironment(for: harness)) { _, new in new }
        return TerminalSessions.shared.start(id: id, title: "\(HarnessCatalog.label(harness)) · \(title)", command: executable.path,
                                             arguments: interactiveArguments(harness: harness, model: model, effort: effort, folder: folder.path, gitFolder: gitFolder, continues: true),
                                             environment: environment, workingDirectory: folder.path)
    }

    /// Stops a run's agent. The terminal stays readable until it's closed.
    @MainActor
    static func stop(_ run: T3Run) {
        if run.id.hasPrefix("term:") {
            TerminalSessions.shared.session(for: run.id)?.interrupt()
            TerminalSessions.shared.session(for: run.id)?.terminate()
        } else if run.id.hasPrefix("tmux:"), let tmux {
            let process = Process()
            process.executableURL = tmux
            process.arguments = ["kill-session", "-t", String(run.id.dropFirst(5))]
            try? process.run()
        } else if run.id.hasPrefix("headless:") {
            activeLock.withLock { activeProcesses[run.id] }?.terminate()
        }
    }

    /// Waits for the TUI to settle (answering a folder-trust question on the way), then pastes the text and presses Return.
    /// False when a question on the screen meant the text couldn't go in.
    @MainActor
    @discardableResult
    private static func deliver(_ text: String, to terminal: TerminalSession, isFirstPrompt: Bool) async -> Bool {
        var previous = ""
        var stable = 0
        var answeredTrust = 0
        for _ in 0..<36 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard terminal.isRunning else { return false }
            let screen = terminal.screenText().trimmingCharacters(in: .whitespacesAndNewlines)
            stable = (screen == previous && screen.count > 20) ? stable + 1 : 0
            previous = screen
            if stable >= 2 {
                if isFirstPrompt, answeredTrust < 3, answerTrustScreen(screen, terminal: terminal) {
                    answeredTrust += 1
                    stable = 0
                    // Cursor's screen is slow to go, and more presses would type into the composer.
                    if screen.contains("[a] Trust") { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                    continue
                }
                // A dialog over the composer (OpenCode's "Update Complete") would swallow the prompt. Before the first
                // prompt only: later those words can be in the agent's report, and Esc means something else then.
                if isFirstPrompt, screen.range(of: #"(?i)update complete"#, options: .regularExpression) != nil {
                    terminal.sendRaw("\u{1B}")
                    stable = 0
                    continue
                }
                break
            }
        }
        // Still on a question screen after all that: don't type the prompt into it.
        let final = terminal.screenText()
        if Self.isQuestionScreen(final) { return false }
        await terminal.send(text: text)
        // Some TUIs (Codex) read the Return right after a paste as part of the paste, and the prompt sits unsent.
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let screen = terminal.screenText()
            // A permission question that opened meanwhile isn't Theo's to answer.
            guard terminal.isRunning, !looksBusy(screen), !isQuestionScreen(screen) else { return true }
            terminal.pressEnter()
        }
        return true
    }

    /// Busy signs of each harness's TUI: a spinner line, "esc to interrupt", "generating".
    static func looksBusy(_ pane: String) -> Bool {
        let tail = pane.split(separator: "\n", omittingEmptySubsequences: false).suffix(14).joined(separator: "\n")
        return tail.range(of: #"(?i)esc.{0,6}interrupt|esc to cancel,\s*\d|ctrl\+c to (interrupt|stop|cancel)|working \(|generating…|running tool|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏"#,
                          options: .regularExpression) != nil
    }

    /// The folder is one Theo made (or the repo Addy named) for this run, so a "trust this folder?" screen is
    /// answered yes: the highlighted choice moves to the option saying yes/trust, then Return.
    @MainActor
    @discardableResult
    static func answerTrustScreen(_ screen: String, terminal: TerminalSession) -> Bool {
        // The API key screen only shows when the owner asked for this harness to use their key.
        guard screen.range(of: #"(?i)do you trust|trust (this|the) (folder|directory|workspace)|you created or one you trust|allow .* to work in this folder|detected a custom api key"#,
                           options: .regularExpression) != nil else { return false }
        // Cursor's screen takes a key: "[a] Trust this workspace".
        if screen.contains("[a] Trust") {
            terminal.sendRaw("a")
            return true
        }
        let lines = screen.components(separatedBy: "\n")
        let options = lines.enumerated().filter { $0.element.range(of: #"^\s*(❯|>|›|\d\.|\s)\s*\S"#, options: .regularExpression) != nil
            && $0.element.range(of: #"(?i)\b(yes|no|trust|exit|quit|cancel)\b"#, options: .regularExpression) != nil }
        let cursor = options.first { $0.element.contains("❯") || $0.element.contains("›") || $0.element.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        let yes = options.first { $0.element.range(of: #"(?i)\byes\b|i trust|trust this"#, options: .regularExpression) != nil }
        if let cursor, let yes {
            let steps = options.firstIndex { $0.offset == yes.offset }! - options.firstIndex { $0.offset == cursor.offset }!
            let key = steps >= 0 ? "\u{1B}[B" : "\u{1B}[A"
            for _ in 0..<abs(steps) { terminal.sendRaw(key) }
        }
        terminal.pressEnter()
        return true
    }

    /// A screen waiting on a choice (trust, permission, y/n): nothing should be typed into it.
    static func isQuestionScreen(_ screen: String) -> Bool {
        let tail = screen.split(separator: "\n", omittingEmptySubsequences: false).suffix(16).joined(separator: "\n")
        if tail.range(of: #"(?i)\(y/n\)|\[y/n\]|yes, proceed|allow once|approve this|enter to confirm|trust this folder|do you trust|esc to cancel(?!,\s*\d)"#,
                      options: .regularExpression) != nil { return true }
        // "Do you want to…" in an agent's report is only words. A dialog offers the choices under it.
        return tail.range(of: #"(?i)do you want to"#, options: .regularExpression) != nil
            && tail.range(of: #"(?im)^\W*(1\.\s*yes|(❯|›|>)\s*(1\.\s*)?yes)\b"#, options: .regularExpression) != nil
    }

    /// A harness's own line saying a turn ended ("✻ Baked for 19s", "─ Worked for 1m 12s ─"), not prose that happens to say so.
    static func finishLines(in text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"(?i)^\W*\w+ed for \d+\s?(h|m|min|s|sec)\b"#, options: .regularExpression) != nil }
    }

    // MARK: tmux

    private static func capture(_ session: String, tmux: URL, lines: Int = 60) async -> String? {
        try? await BotsT3.shell(tmux, ["capture-pane", "-p", "-t", session, "-S", "-\(lines)"], limit: 15)
    }

    /// Waits for the CLI's screen to settle (answering a folder-trust question on the way), then pastes the
    /// text and presses Enter.
    private static func deliver(_ text: String, to session: String, tmux: URL) async throws {
        var previous = ""
        var stable = 0
        var answeredTrust = 0
        for _ in 0..<36 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let pane = await capture(session, tmux: tmux) else {
                throw BotsT3Error.failed("The \(session) terminal session closed right after it started. Run the harness once in Terminal to see why.")
            }
            let screen = pane.trimmingCharacters(in: .whitespacesAndNewlines)
            stable = (screen == previous && screen.count > 20) ? stable + 1 : 0
            previous = screen
            if stable >= 2 {
                // "Do you trust this folder?" defaults to yes; this folder is the one the user asked to work in.
                if answeredTrust < 2, screen.range(of: #"(?i)do you trust|trust (this|the) (folder|directory|workspace)"#, options: .regularExpression) != nil {
                    _ = try? await BotsT3.shell(tmux, ["send-keys", "-t", session, "Enter"])
                    answeredTrust += 1
                    stable = 0
                    continue
                }
                break
            }
        }
        let buffer = "\(session)-prompt"
        try await BotsT3.shell(tmux, ["load-buffer", "-b", buffer, "-"], stdin: text)
        try await BotsT3.shell(tmux, ["paste-buffer", "-p", "-d", "-b", buffer, "-t", session])
        try? await Task.sleep(nanoseconds: 800_000_000)
        try await BotsT3.shell(tmux, ["send-keys", "-t", session, "Enter"])
    }

    static func sendFollowup(_ text: String, to run: T3Run) async throws {
        // An agent waiting on a question gets just the answer, typed straight in.
        let answersQuestion = run.phase == "waiting"
        let label = HarnessCatalog.label(run.harness ?? "")
        if run.id.hasPrefix("term:") {
            let followUpMessage = text + BotsT3.followupNote(for: run)
            if let terminal = await TerminalSessions.shared.session(for: run.id), await terminal.isRunning {
                let before = await terminal.screenText()
                if answersQuestion {
                    await terminal.send(text: text)
                } else if !(await deliver(followUpMessage, to: terminal, isFirstPrompt: false)) {
                    throw BotsT3Error.failed("\(label) is showing a question on its screen, so that couldn't go in. Open it from the run's card to answer, then send it again.")
                }
                PaneWatch.reset(run.id, screenBefore: before)
                PaneWatch.delivered(run.id)
                return
            }
            // The terminal has gone (the agent exited, or Theo restarted): a new one on the same worktree and
            // branch carries on, so the follow-up lands on the same pull request.
            guard let harness = run.harness, let executable = HarnessCatalog.executable(for: harness) else {
                throw BotsT3Error.failed("\(HarnessCatalog.label(run.harness ?? "")) isn't installed any more.")
            }
            let folder = URL(fileURLWithPath: run.worktree ?? run.folder, isDirectory: true)
            // The run's own model when it had one (with none picked, run.model is only the harness's name).
            let model = run.model == HarnessCatalog.label(harness) ? (harness == "codex" ? codexPlanModel() : nil) : run.model
            let effort = run.effort == "default" ? nil : run.effort
            let gitFolder = run.repo.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(".git").path }
            guard let terminal = await restartTerminal(id: run.id, harness: harness, executable: executable, model: model, effort: effort, folder: folder, title: run.title, gitFolder: gitFolder) else {
                throw BotsT3Error.failed("The \(HarnessCatalog.label(harness)) terminal couldn't start.")
            }
            if !(await deliver(followUpMessage, to: terminal, isFirstPrompt: true)) {
                throw BotsT3Error.failed("\(label) is showing a question on its screen, so that couldn't go in. Open it from the run's card to answer, then send it again.")
            }
            PaneWatch.reset(run.id)
            PaneWatch.delivered(run.id)
            return
        }
        guard run.id.hasPrefix("tmux:"), let tmux else {
            throw BotsT3Error.failed("That coding run has ended; start a new one.")
        }
        let session = String(run.id.dropFirst(5))
        guard (try? await BotsT3.shell(tmux, ["has-session", "-t", session])) != nil else {
            throw BotsT3Error.failed("The \(HarnessCatalog.label(run.harness ?? "")) terminal session has closed; start a new run.")
        }
        let before = await capture(session, tmux: tmux) ?? ""
        try await deliver(answersQuestion ? text : text + BotsT3.followupNote(for: run), to: session, tmux: tmux)
        PaneWatch.reset(session, screenBefore: before)
        PaneWatch.delivered(session)
    }

    /// Opens a terminal window attached to the run's tmux session: iTerm or Ghostty when installed, else Terminal.
    static func openInTerminal(_ run: T3Run) {
        if run.id.hasPrefix("term:") {
            Task { @MainActor in TerminalWindowController.pop(sessionID: run.id) }
            return
        }
        if run.id.hasPrefix("tmux:") { openInTerminal(session: String(run.id.dropFirst(5))); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: run.worktree ?? run.folder, isDirectory: true))
    }

    static func openInTerminal(session: String) {
        guard let tmux else { return }
        let attach = "\(quoted(tmux.path)) attach -t \(quoted(session))"
        let fm = FileManager.default
        let script: String
        if fm.fileExists(atPath: "/Applications/iTerm.app") {
            let escaped = attach.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            script = "tell application \"iTerm\"\nactivate\ncreate window with default profile command \"\(escaped)\"\nend tell"
        } else if fm.fileExists(atPath: "/Applications/Ghostty.app") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", "Ghostty", "--args", "-e", tmux.path, "attach", "-t", session]
            try? process.run()
            return
        } else {
            let escaped = attach.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        }
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }

    // MARK: Tracking

    /// What the pane looked like at the last check, to tell "working" (it changes) from "finished" (it doesn't).
    private final class PaneWatch: @unchecked Sendable {
        private static let lock = NSLock()
        private static var watches: [String: (hash: Int, since: Date)] = [:]
        /// A new prompt went in. `screenBefore`: what was on screen, so its old "Baked for 19s" doesn't end the new turn.
        static func reset(_ session: String, screenBefore: String = "") {
            lock.withLock {
                watches[session] = nil
                seen[session] = []
                busy.remove(session)
                oldFinishLines[session] = Set(HarnessCoding.finishLines(in: screenBefore))
                if !screenBefore.isEmpty { followedUp.insert(session) }
            }
        }
        private static var oldFinishLines: [String: Set<String>] = [:]
        private static var followedUp: Set<String> = []
        private static var trustAnswers: [String: Int] = [:]

        static func saysFinished(_ session: String, tail: String) -> Bool {
            lock.withLock {
                let old = oldFinishLines[session] ?? []
                return HarnessCoding.finishLines(in: tail).contains { !old.contains($0) }
            }
        }

        /// A late trust screen is only answered before the agent has started on its first prompt, and twice at most:
        /// later on those words could be in anything it's reading, and Return might answer a different question.
        static func mayAnswerTrustScreen(_ session: String) -> Bool {
            lock.withLock {
                guard !busy.contains(session), !followedUp.contains(session), (trustAnswers[session] ?? 0) < 2 else { return false }
                trustAnswers[session, default: 0] += 1
                return true
            }
        }

        /// Screens seen since the prompt went in, and whether it ever looked busy: a run that shows neither
        /// never started, however quiet its screen is.
        private static var seen: [String: Set<Int>] = [:]
        private static var busy: Set<String> = []
        private static var tracked: Set<String> = []
        static func delivered(_ session: String) { lock.withLock { _ = tracked.insert(session) } }
        static func note(_ session: String, hash: Int, busy isBusy: Bool) {
            lock.withLock {
                seen[session, default: []].insert(hash)
                if isBusy { busy.insert(session) }
            }
        }
        /// Only for runs started this launch; anything older gets the benefit of the doubt.
        static func neverStarted(_ session: String) -> Bool {
            lock.withLock { tracked.contains(session) && !busy.contains(session) && (seen[session]?.count ?? 0) < 4 }
        }
        /// Seconds the pane has been unchanged.
        static func unchangedSeconds(_ session: String, hash: Int) -> TimeInterval {
            lock.withLock {
                let now = Date()
                if let entry = watches[session], entry.hash == hash { return now.timeIntervalSince(entry.since) }
                watches[session] = (hash, now)
                return 0
            }
        }

        private static var askingSince: [String: Date] = [:]
        /// Seconds a question has been on screen (0 and forgotten once it's gone).
        static func askingSeconds(_ run: String, asking: Bool) -> TimeInterval {
            lock.withLock {
                guard asking else { askingSince[run] = nil; return 0 }
                let since = askingSince[run] ?? Date()
                askingSince[run] = since
                return Date().timeIntervalSince(since)
            }
        }
    }

    /// Seconds the pane must sit still before the run counts as finished.
    static let idleSeconds: TimeInterval = 40

    static func state(of run: T3Run) async -> BotsT3.ThreadState? {
        if run.id.hasPrefix("headless:") { return headlessState(of: run) }
        if run.id.hasPrefix("term:") { return await terminalState(of: run) }
        guard run.id.hasPrefix("tmux:"), let tmux else { return nil }
        let session = String(run.id.dropFirst(5))
        guard (try? await BotsT3.shell(tmux, ["has-session", "-t", session])) != nil else {
            // The CLI exited and took its session with it.
            // Nothing says it finished, so it's not reported as done and nothing half-made gets pushed.
            return BotsT3.ThreadState(status: "interrupted", busy: false, waitingForAnswer: false,
                                      lastMessage: "The \(HarnessCatalog.label(run.harness ?? "")) session ended before saying it was done. The work so far is in its folder; write @code to carry on.",
                                      worktree: run.worktree, pullRequest: nil)
        }
        guard let pane = await capture(session, tmux: tmux) else { return nil }
        return evaluate(run, pane: pane, unchanged: PaneWatch.unchangedSeconds(session, hash: pane.hashValue))
    }

    /// The screen is read on the main actor; reading the agent's transcript and asking git happen off it.
    private static func terminalState(of run: T3Run) async -> BotsT3.ThreadState? {
        let terminal: (pane: String, isRunning: Bool, exitCode: Int32?)? = await MainActor.run {
            guard let terminal = TerminalSessions.shared.session(for: run.id) else { return nil }
            let pane = terminal.screenText()
            // A trust screen that showed up after the prompt was typed: answer it and keep going.
            if terminal.isRunning, pane.range(of: #"(?i)trust this folder|do you trust|you created or one you trust"#, options: .regularExpression) != nil,
               PaneWatch.mayAnswerTrustScreen(run.id) {
                answerTrustScreen(pane, terminal: terminal)
            }
            return (pane, terminal.isRunning, terminal.exitCode)
        }
        guard let terminal else {
            // Theo restarted and the terminal went with it. Nothing says the agent finished, so it isn't reported as done
            // and nothing half-made gets pushed.
            return BotsT3.ThreadState(status: "interrupted", busy: false, waitingForAnswer: false,
                                      lastMessage: "Theo restarted while the run was going. The work so far is in its folder; write @code to carry on.",
                                      worktree: run.worktree, pullRequest: nil)
        }
        guard terminal.isRunning else {
            let summary = transcriptSummary(for: run) ?? paneSummary(terminal.pane)
            return BotsT3.ThreadState(status: terminal.exitCode == 0 ? "completed" : "failed", busy: false, waitingForAnswer: false,
                                      lastMessage: summary.isEmpty ? "The \(HarnessCatalog.label(run.harness ?? "")) session ended without a report." : summary,
                                      worktree: run.worktree, pullRequest: nil)
        }
        return evaluate(run, pane: terminal.pane, unchanged: PaneWatch.unchangedSeconds(run.id, hash: terminal.pane.hashValue))
    }

    /// Working / waiting / finished from what the screen shows, shared by the terminal and tmux paths.
    private static func evaluate(_ run: T3Run, pane: String, unchanged: TimeInterval) -> BotsT3.ThreadState {
        let tail = pane.split(separator: "\n", omittingEmptySubsequences: false).suffix(14).joined(separator: "\n")
        let working = looksBusy(pane)
        PaneWatch.note(run.id, hash: pane.hashValue, busy: working)
        let asking = isQuestionScreen(pane)
        if !asking { _ = PaneWatch.askingSeconds(run.id, asking: false) }
        // A harness's own "Baked for 19s" line says the turn is over, so there's no need to wait for a long quiet spell.
        let saysFinished = PaneWatch.saysFinished(run.id, tail: tail)
        let settled = !working && (saysFinished ? unchanged >= 6 : Date().timeIntervalSince(run.startedAt) > 60 && unchanged >= idleSeconds)
        // A question on screen for a while is waiting for Addy, even if a spinner or clock keeps it moving.
        if asking && Date().timeIntervalSince(run.startedAt) > 30 && (settled || PaneWatch.askingSeconds(run.id, asking: true) >= 15) {
            let question = tail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(6).joined(separator: "\n")
            return BotsT3.ThreadState(status: "waiting", busy: false, waitingForAnswer: true,
                                      lastMessage: "It is asking:\n\n\(question)\n\n(Open \"Watch\" to answer in the terminal.)",
                                      worktree: run.worktree, pullRequest: nil)
        }
        // A plan's limit or a model it can't use: the agent would sit there (OpenCode retries for hours), so say so now.
        // The agent's own output can carry those words too, so a working agent only counts when it says it's retrying.
        if let blocked = tail.range(of: #"(?i)free limit reached|free usage exceeded|usage limit reached|is not supported when using|out of credits|quota exceeded"#, options: .regularExpression),
           tail[tail.lineRange(for: blocked)].range(of: "(?i)retrying", options: .regularExpression) != nil || (!working && !saysFinished && unchanged >= 8) {
            let raw = tail[tail.lineRange(for: blocked)].trimmingCharacters(in: CharacterSet(charactersIn: "│┃■⬝ \n"))
            // OpenCode's "[retrying in 6h 10m attempt #1" says nothing useful here.
            let line = raw.replacingOccurrences(of: #"\s*\[retrying.*$"#, with: "", options: .regularExpression)
            return BotsT3.ThreadState(status: "failed", busy: false, waitingForAnswer: false,
                                      lastMessage: "\(HarnessCatalog.label(run.harness ?? "The agent")) can't run this on your plan: \(line)",
                                      worktree: run.worktree, pullRequest: nil)
        }
        if settled, transcriptSummary(for: run) == nil, PaneWatch.neverStarted(run.id), !workHappened(run, pane: pane) {
            return BotsT3.ThreadState(status: "waiting", busy: false, waitingForAnswer: true,
                                      lastMessage: "\(HarnessCatalog.label(run.harness ?? "The agent")) hasn't started on this. Open \"Watch\" to see its screen.",
                                      worktree: run.worktree, pullRequest: nil)
        }
        if settled {
            let summary = transcriptSummary(for: run) ?? paneSummary(pane)
            return BotsT3.ThreadState(status: "completed", busy: false, waitingForAnswer: false, lastMessage: summary,
                                      worktree: run.worktree, pullRequest: nil)
        }
        return BotsT3.ThreadState(status: "running", busy: true, waitingForAnswer: false,
                                  lastMessage: transcriptSummary(for: run), worktree: run.worktree, pullRequest: nil)
    }

    /// Signs a run did its work even if every poll missed it being busy: a finished line, or a new commit or changed file.
    private static func workHappened(_ run: T3Run, pane: String) -> Bool {
        if pane.range(of: #"(?i)worked for \d|(crunched|baked|brewed|cooked|churned|sauteed|cogitated) for \d"#, options: .regularExpression) != nil { return true }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = BotsT3.git
        process.arguments = ["-C", run.worktree ?? run.folder, "status", "--porcelain", "--branch"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let status = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if status.split(separator: "\n").count > 1 { return true }
        guard let base = run.baseCommit else { return false }
        let head = Process()
        let headPipe = Pipe()
        head.executableURL = BotsT3.git
        head.arguments = ["-C", run.worktree ?? run.folder, "rev-parse", "HEAD"]
        head.standardOutput = headPipe
        head.standardError = Pipe()
        guard (try? head.run()) != nil else { return false }
        head.waitUntilExit()
        let now = String(data: headPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return now != base
    }

    private static func paneSummary(_ pane: String) -> String {
        // The agent's words, without the TUI's frames, status bars and hints.
        let chrome = #"(?i)shift\+tab|ctrl\+|tab agents|\bmcp\b|\[dashboard\]|auto mode|worktree |openai codex|^\W*(❯|›|>)\W*$"#
        let lines = pane.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.trimmingCharacters(in: CharacterSet(charactersIn: "│┃╹▀╭╮╰╯─ ")).trimmingCharacters(in: .whitespaces)
        }
        .filter { $0.range(of: chrome, options: .regularExpression) == nil }
        return lines.suffix(40).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Transcripts

    private static func mangled(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    private static func newestFiles(in folder: URL, suffix: String, after date: Date, recursive: Bool = false) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var found: [(URL, Date)] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if recursive, values?.isDirectory == true {
                found += newestFiles(in: url, suffix: suffix, after: date, recursive: false).compactMap { inner in
                    (try? inner.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map { (inner, $0) }
                }
            } else if url.lastPathComponent.hasSuffix(suffix), let modified = values?.contentModificationDate, modified >= date.addingTimeInterval(-5) {
                found.append((url, modified))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// A transcript's lines. Only the end of a long one: the last words are what's wanted, and this runs every few seconds.
    private static func jsonLines(_ url: URL, keeping maximumBytes: UInt64 = 2_000_000) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let first = size > maximumBytes ? size - maximumBytes : 0
        try? handle.seek(toOffset: first)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if first > 0 { lines.removeFirst(min(1, lines.count)) }
        return lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    private static func textBlocks(_ content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return (content as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let text = blocks.compactMap { ($0["type"] as? String) == "text" || ($0["type"] as? String) == "output_text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// The agent's last words from its own transcript: Claude's project log, Codex's rollout file, Cursor's
    /// agent transcript. Nil for the others (the caller falls back to the pane).
    static func transcriptSummary(for run: T3Run) -> String? {
        guard let harness = run.harness else { return nil }
        let folder = run.worktree ?? run.folder
        let home = FileManager.default.homeDirectoryForCurrentUser
        let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        switch harness {
        case "claude":
            for path in Set([folder, resolved]) {
                let dir = home.appendingPathComponent(".claude/projects/\(mangled(path))", isDirectory: true)
                for file in newestFiles(in: dir, suffix: ".jsonl", after: run.startedAt) {
                    for event in jsonLines(file).reversed() where event["type"] as? String == "assistant" {
                        if let text = textBlocks((event["message"] as? [String: Any])?["content"]) { return text }
                    }
                }
            }
        case "codex":
            let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
            let calendar = Calendar(identifier: .gregorian)
            var days = [run.startedAt]
            if !calendar.isDate(Date(), inSameDayAs: run.startedAt) { days.append(Date()) }
            for day in days {
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                let dir = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!), isDirectory: true)
                for file in newestFiles(in: dir, suffix: ".jsonl", after: run.startedAt) where file.lastPathComponent.hasPrefix("rollout-") {
                    guard let meta = jsonLines(file, keeping: 200_000_000).first?["payload"] as? [String: Any], let cwd = meta["cwd"] as? String,
                          cwd == folder || cwd == resolved else { continue }
                    for event in jsonLines(file).reversed() {
                        let payload = event["payload"] as? [String: Any]
                        if event["type"] as? String == "event_msg", payload?["type"] as? String == "task_complete",
                           let last = payload?["last_agent_message"] as? String, !last.isEmpty { return last }
                        if event["type"] as? String == "response_item", payload?["role"] as? String == "assistant",
                           let text = textBlocks(payload?["content"]) { return text }
                    }
                }
            }
        case "cursor":
            for path in Set([folder, resolved]) {
                let dir = home.appendingPathComponent(".cursor/projects/\(mangled(path).trimmingCharacters(in: CharacterSet(charactersIn: "-")))/agent-transcripts", isDirectory: true)
                for file in newestFiles(in: dir, suffix: ".jsonl", after: run.startedAt, recursive: true) {
                    for event in jsonLines(file).reversed() where event["role"] as? String == "assistant" {
                        if let text = textBlocks((event["message"] as? [String: Any])?["content"]) { return text }
                    }
                }
            }
        default: break
        }
        return nil
    }

    // MARK: Headless fallback

    private static let activeLock = NSLock()
    private nonisolated(unsafe) static var active: Set<String> = []
    /// Headless runs' processes, so Stop can reach them.
    private nonisolated(unsafe) static var activeProcesses: [String: Process] = [:]

    private static var runsFolder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Theo/runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func resultFile(_ id: String) -> URL {
        runsFolder.appendingPathComponent(id.replacingOccurrences(of: "headless:", with: "") + ".json")
    }

    private static func startHeadless(id: String, harness: String, executable: URL, model: String?, effort: String?, folder: URL, prompt: String) {
        activeLock.withLock { _ = active.insert(id) }
        let out = runsFolder.appendingPathComponent(id.replacingOccurrences(of: "headless:", with: "") + ".out")
        let reply = out.appendingPathExtension("reply")
        // It blocks for the whole run, so it stays off the small pool Swift's tasks run on.
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = headlessArguments(harness: harness, model: model, effort: effort, folder: folder.path, prompt: prompt, outFile: reply.path)
            process.currentDirectoryURL = folder
            var environment = HarnessCatalog.childEnvironment()
            environment["PWD"] = folder.path
            environment.merge(HarnessCatalog.apiKeyEnvironment(for: harness)) { _, new in new }
            process.environment = environment
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: out)
            process.standardOutput = handle ?? FileHandle.nullDevice
            process.standardError = handle ?? FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            var status = "failed"
            var text = ""
            if (try? process.run()) != nil {
                activeLock.withLock { activeProcesses[id] = process }
                let watchdog = Task.detached {
                    try? await Task.sleep(nanoseconds: 45 * 60 * 1_000_000_000)
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                activeLock.withLock { activeProcesses[id] = nil }
                watchdog.cancel()
                try? handle?.close()
                let stdout = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
                if process.terminationStatus == 0, let answer = headlessReply(harness: harness, stdout: stdout, outFile: reply.path) {
                    status = "completed"
                    text = answer
                } else {
                    text = "\(HarnessCatalog.label(harness)) stopped (exit \(process.terminationStatus)): \(stdout.suffix(300))"
                }
            } else {
                text = "\(HarnessCatalog.label(harness)) couldn't be started."
            }
            let payload: [String: String] = ["status": status, "text": text]
            if let data = try? JSONSerialization.data(withJSONObject: payload) { try? data.write(to: resultFile(id), options: .atomic) }
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: reply)
            activeLock.withLock { _ = active.remove(id) }
        }
    }

    private static func headlessState(of run: T3Run) -> BotsT3.ThreadState? {
        if let data = try? Data(contentsOf: resultFile(run.id)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return BotsT3.ThreadState(status: object["status"] ?? "completed", busy: false, waitingForAnswer: false,
                                      lastMessage: object["text"], worktree: run.worktree, pullRequest: nil)
        }
        if activeLock.withLock({ active.contains(run.id) }) {
            return BotsT3.ThreadState(status: "running", busy: true, waitingForAnswer: false, lastMessage: nil,
                                      worktree: run.worktree, pullRequest: nil)
        }
        // Theo restarted mid-run: the process went with it.
        return BotsT3.ThreadState(status: "interrupted", busy: false, waitingForAnswer: false,
                                  lastMessage: "Theo restarted while the run was going; the work so far is in the project folder.",
                                  worktree: run.worktree, pullRequest: nil)
    }
}
