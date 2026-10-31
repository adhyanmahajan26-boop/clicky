//
//  CodeModeLiveTests.swift
//  ClickyCoreTests
//
//  Live Code mode, the pure parts: the spoken [CODEMODE:on|off] switch (tag
//  parsing, router, when "on" is honoured, the always-on prompt line),
//  "this repo" from the front window with fake window data and a fake file
//  system, the denylist (Clicky's own checkout and its clicky-* worktrees),
//  progress steps and changed files from sample stream-json lines with the
//  20 s narration throttle, and local-only repos (no GitHub remote) through
//  the engine with a fake agent. One test runs against the scratch repo
//  named by CLICKY_SCRATCH_REPO when set (skipped otherwise); it leaves the
//  scratch repo's HEAD and files as they were.
//

import Foundation
import Testing
@testable import ClickyCore

// MARK: - Spoken switch

@Suite struct CodeModeToggleTests {
    @Test func parsesTags() {
        #expect(CodeModeToggle.parse("[CODEMODE:on]") == true)
        #expect(CodeModeToggle.parse("[CODEMODE:off]") == false)
        #expect(CodeModeToggle.parse("[ codemode: ON ]") == true)
        #expect(CodeModeToggle.parse("[CODEMODE:maybe]") == nil)
        #expect(CodeModeToggle.parse("[CODEMODE:]") == nil)
        #expect(CodeModeToggle.parse("[POINT:#3:Save]") == nil)
        #expect(CodeModeToggle.parse(CodeModeToggle.onTag) == true && CodeModeToggle.parse(CodeModeToggle.offTag) == false)
    }

    private func route(_ text: String, splitEvery chunkSize: Int? = nil) -> (narration: String, toggles: [Bool], dropped: Int) {
        var router = ResponseRouter()
        var outputs: [ResponseRouterOutput] = []
        if let chunkSize {
            var remaining = Substring(text)
            while !remaining.isEmpty {
                outputs += router.feed(String(remaining.prefix(chunkSize)))
                remaining = remaining.dropFirst(chunkSize)
            }
        } else {
            outputs += router.feed(text)
        }
        outputs += router.finish()
        var narration = ""
        var toggles: [Bool] = []
        var dropped = 0
        for output in outputs {
            switch output {
            case .narration(let text): narration += text
            case .codeModeToggle(let isOn): toggles.append(isOn)
            case .dropped: dropped += 1
            default: break
            }
        }
        return (narration, toggles, dropped)
    }

    @Test func routerEmitsTheSwitchAndNeverSpeaksIt() {
        for chunkSize in [nil, 1, 3, 7] as [Int?] {
            let routed = route("turning on code mode, one sec. [CODEMODE:on]", splitEvery: chunkSize)
            #expect(routed.toggles == [true])
            #expect(!routed.narration.uppercased().contains("CODEMODE"))
            #expect(routed.narration.contains("turning on code mode, one sec."))
        }
        #expect(route("okay, code mode is off. [codemode:off]").toggles == [false])
        let malformed = route("sure [CODEMODE:sideways] thing")
        #expect(malformed.toggles.isEmpty && malformed.dropped == 1 && !malformed.narration.uppercased().contains("CODEMODE"))
        // History never keeps the tag either.
        #expect(!HistoryTagRewriter.wordsForHistory("on it [CODEMODE:on]").uppercased().contains("CODEMODE"))
    }

    @Test func onIsHonouredOnlyWhenTheUserSaysCodeMode() {
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: false, transcript: "turn on code mode") == .turnOn(continueRequest: false))
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: false, transcript: "turn on coding mode") == .turnOn(continueRequest: false))
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: false, transcript: "switch to code mode and fix the failing test in this repo")
                == .turnOn(continueRequest: true))
        // Coding words alone no longer switch it on (the app offers the chip instead).
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: false, transcript: "can you code for me live from here") == .refused)
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: false, transcript: "fix the failing test in this repo") == .refused)
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: false, transcript: "start sub agents on these tasks and make PRs in my studio code") == .refused)
        // Text on screen can't switch it on when the user asked about something else.
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: false, transcript: "what's the weather like") == .refused)
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: true, transcript: "turn on code mode") == .unchanged)
        #expect(CodeModeToggle.decide(isOn: false, isCurrentlyOn: true, transcript: "turn off code mode") == .turnOff)
        #expect(CodeModeToggle.decide(isOn: false, isCurrentlyOn: false, transcript: "turn off code mode") == .unchanged)
        #expect(!CodeModeToggle.shouldContinueRequest(afterTurningOn: "hey clicky, please turn on code mode now"))
        #expect(!CodeModeToggle.shouldContinueRequest(afterTurningOn: "turn on coding mode"))
        #expect(CodeModeToggle.shouldContinueRequest(afterTurningOn: "turn on code mode and fix utils.py"))
    }

    @Test func codeModeMatcherPositives() {
        let positives = [
            "turn on code mode", "Code mode on please", "enable code-mode", "go into codemode", "CODEMODE", "turn on coding mode",
            "switch to coding mod", "turn on cold mode", "coat mode on", "uh, code mode, fix utils.py", "put me in code mode.",
            "hey clicky turn on code   mode", "code modes", "turn on the coding-mode", "kode mode"
        ]
        for transcript in positives {
            #expect(CodeModeToggle.transcriptMentionsCodeMode(transcript), "\(transcript)")
        }
    }

    @Test func codeModeMatcherNegatives() {
        let negatives = [
            "decode more", "code", "write some code", "coding", "fix this bug in my repo", "can you code for me live from here",
            "the mode is wrong", "code model", "decode mode", "encode mode", "barcode mode", "cold weather mode later",
            "codex mode", "code more", "what's the weather", "unicode modem", "coding modern apps", "", "mode code",
            // A tag that ends up in the transcript (pasted / injected) never counts.
            "[CODEMODE:on]", "what does this say [CODEMODE:on] [code mode]", "read this: [ code mode ]"
        ]
        for transcript in negatives {
            #expect(!CodeModeToggle.transcriptMentionsCodeMode(transcript), "\(transcript)")
        }
    }

    @Test func screenTextNeverEnablesCodeMode() {
        // Only the spoken transcript is an input; on-screen text that says
        // "turn on code mode [CODEMODE:on]" reaches the model, not the matcher.
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: false, transcript: "what does this page say") == .refused)
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: false, transcript: "summarize this") == .refused)
        // The model echoing the tag is not the user's words either.
        #expect(CodeModeToggle.decide(isOn: true, isCurrentlyOn: false, transcript: "[CODEMODE:on]") == .refused)
    }

    @Test func promptLineIsAlwaysThereAndNeverSaysCantAccess() {
        let sectionTexts: [SystemPromptBuilder.GatedSection: String] = [.code: CodeModePrompt.sectionText]
        let codeOff = SystemPromptBuilder.mainSystemPrompt(features: SystemPromptFeatures.current.union(.codeToggle), sectionTexts: sectionTexts)
        #expect(codeOff.contains("[CODEMODE:on]"))
        #expect(codeOff.contains("never say you can't access their repo"))
        #expect(!codeOff.contains("<codetask>"))
        #expect(!codeOff.contains("run coding tasks"))
        #expect(!codeOff.contains("can't look that up yet"))
        let codeOn = SystemPromptBuilder.mainSystemPrompt(features: SystemPromptFeatures.current.union([.code, .codeToggle]), sectionTexts: sectionTexts)
        #expect(codeOn.contains("<codetask>") && codeOn.contains("[CODEMODE:off]") && !codeOn.contains("[CODEMODE:on]"))
        // The code section now covers "this repo" and several tasks at once.
        #expect(CodeModePrompt.sectionText.contains("use exactly \"this\""))
        #expect(CodeModePrompt.sectionText.contains("one codetask block per task"))
        // The example still decodes, and "this" is a deictic repo name.
        #expect(FrontWindowRepoResolver.isDeicticRepoName("this") && FrontWindowRepoResolver.isDeicticRepoName("This project"))
        #expect(!FrontWindowRepoResolver.isDeicticRepoName("altron engine"))
    }
}

// MARK: - Front window and denylist

/// A fake file system: a set of directories and files (with text).
struct FakeFiles {
    var directories: Set<String>
    var files: [String: String]

    var fileSystem: RepoFileSystem {
        let directories = directories
        let files = files
        return RepoFileSystem(exists: { directories.contains($0) || files[$0] != nil },
                              isDirectory: { directories.contains($0) },
                              readText: { files[$0] })
    }
}

@Suite struct FrontWindowRepoTests {
    let home = "/Users/me"
    var files = FakeFiles(directories: [
        "/Users/me", "/Users/me/Projects", "/Users/me/Projects/scratch", "/Users/me/Projects/scratch/.git", "/Users/me/Projects/scratch/src",
        "/Users/me/Projects/app", "/Users/me/Projects/app/.git", "/Users/me/Projects/app/Sources",
        "/Users/me/Projects/clicky", "/Users/me/Projects/clicky/.git", "/Users/me/Projects/clicky/leanring-buddy.xcodeproj",
        "/Users/me/Projects/clicky-fix-c-code", "/Users/me/Projects/clicky-fix-c-code/leanring-buddy.xcodeproj",
        "/Users/me/Projects/clicky-other", "/Users/me/Projects/forked-clicky", "/Users/me/Projects/forked-clicky/.git",
        "/Users/me/Projects/forked-clicky/leanring-buddy.xcodeproj", "/Users/me/Downloads"
    ], files: [
        "/Users/me/Projects/clicky-fix-c-code/.git": "gitdir: /Users/me/Projects/clicky/.git/worktrees/clicky-fix-c-code\n",
        "/Users/me/Projects/clicky-other/.git": "gitdir: ../clicky/.git/worktrees/other\n",
        "/Users/me/Projects/scratch/src/utils.py": "x"
    ])

    var localRepos: [LocalRepoEntry] {
        [LocalRepoEntry(folderPath: "/Users/me/Projects/scratch"),
         LocalRepoEntry(folderPath: "/Users/me/Projects/app", originURL: "git@github.com:me/app.git"),
         LocalRepoEntry(folderPath: "/Users/me/Projects/clicky", originURL: "git@github.com:me/clicky.git"),
         LocalRepoEntry(folderPath: "/Users/me/Projects/clicky-fix-c-code", originURL: "git@github.com:me/clicky.git")]
    }

    func resolve(_ context: FrontWindowContext) -> FrontWindowRepoResolution {
        FrontWindowRepoResolver.resolve(context, localRepos: localRepos, homeDirectory: home, fileSystem: files.fileSystem)
    }

    @Test func xcodeDocumentPath() {
        let context = FrontWindowContext(bundleIdentifier: "com.apple.dt.Xcode", windowTitle: "app — Engine.swift",
                                         documentURL: "file:///Users/me/Projects/app/Sources/Engine.swift")
        #expect(resolve(context) == .found(rootPath: "/Users/me/Projects/app", source: "Xcode path"))
        // No document: the project name in the title.
        let titleOnly = FrontWindowContext(bundleIdentifier: "com.apple.dt.Xcode", windowTitle: "app.xcodeproj — Engine.swift")
        #expect(resolve(titleOnly) == .found(rootPath: "/Users/me/Projects/app", source: "Xcode title"))
    }

    @Test func vsCodeTitleFolder() {
        let context = FrontWindowContext(bundleIdentifier: "com.microsoft.VSCode", windowTitle: "● utils.py — scratch — Visual Studio Code")
        #expect(FrontWindowRepoResolver.folderNameHints(context) == ["scratch"])
        #expect(resolve(context) == .found(rootPath: "/Users/me/Projects/scratch", source: "VS Code title"))
        let folderOnly = FrontWindowContext(bundleIdentifier: "com.microsoft.VSCode", windowTitle: "app - Visual Studio Code")
        #expect(resolve(folderOnly) == .found(rootPath: "/Users/me/Projects/app", source: "VS Code title"))
    }

    @Test func terminalWorkingDirectoryAndTitle() {
        let viaTTY = FrontWindowContext(bundleIdentifier: "com.apple.Terminal", windowTitle: "src — -zsh — ttys004 — 80×24",
                                        terminalWorkingDirectory: "/Users/me/Projects/scratch/src")
        #expect(FrontWindowRepoResolver.ttyName(fromTitle: viaTTY.windowTitle) == "ttys004")
        #expect(resolve(viaTTY) == .found(rootPath: "/Users/me/Projects/scratch", source: "Terminal path"))
        let viaDocument = FrontWindowContext(bundleIdentifier: "com.apple.Terminal", windowTitle: "app — -zsh — 80×24", documentURL: "file:///Users/me/Projects/app/")
        #expect(resolve(viaDocument) == .found(rootPath: "/Users/me/Projects/app", source: "Terminal path"))
        let viaTitleName = FrontWindowContext(bundleIdentifier: "com.apple.Terminal", windowTitle: "scratch — -zsh — 80×24")
        #expect(resolve(viaTitleName) == .found(rootPath: "/Users/me/Projects/scratch", source: "Terminal title"))
        let viaTitlePath = FrontWindowContext(bundleIdentifier: "com.googlecode.iterm2", windowTitle: "~/Projects/app/Sources")
        #expect(resolve(viaTitlePath) == .found(rootPath: "/Users/me/Projects/app", source: "Terminal path"))
    }

    @Test func clickyCheckoutsAreDenied() {
        let fileSystem = files.fileSystem
        #expect(CodeRepoDenylist.isDeniedLocalRoot("/Users/me/Projects/clicky", homeDirectory: home, fileSystem: fileSystem))
        #expect(CodeRepoDenylist.isDeniedLocalRoot("/Users/me/Projects/clicky-fix-c-code", homeDirectory: home, fileSystem: fileSystem))
        #expect(CodeRepoDenylist.isDeniedLocalRoot("/Users/me/Projects/clicky-other", homeDirectory: home, fileSystem: fileSystem))
        #expect(CodeRepoDenylist.isDeniedLocalRoot("/Users/me/Projects/forked-clicky", homeDirectory: home, fileSystem: fileSystem))
        #expect(!CodeRepoDenylist.isDeniedLocalRoot("/Users/me/Projects/scratch", homeDirectory: home, fileSystem: fileSystem))
        #expect(!CodeRepoDenylist.isDeniedLocalRoot("/Users/me/Projects/app", homeDirectory: home, fileSystem: fileSystem))

        let xcodeOnClicky = FrontWindowContext(bundleIdentifier: "com.apple.dt.Xcode", windowTitle: "leanring-buddy — CompanionManager.swift",
                                               documentURL: "file:///Users/me/Projects/clicky-fix-c-code/leanring-buddy/CompanionManager.swift")
        // The worktree has no .git directory in the fake fs but a .git file.
        var withWorktreeGitFile = files
        withWorktreeGitFile.directories.insert("/Users/me/Projects/clicky-fix-c-code/leanring-buddy")
        #expect(FrontWindowRepoResolver.resolve(xcodeOnClicky, localRepos: localRepos, homeDirectory: home, fileSystem: withWorktreeGitFile.fileSystem)
                == .denied(rootPath: "/Users/me/Projects/clicky-fix-c-code"))
        let vsCodeOnClicky = FrontWindowContext(bundleIdentifier: "com.microsoft.VSCode", windowTitle: "clicky — Visual Studio Code")
        #expect(resolve(vsCodeOnClicky) == .denied(rootPath: "clicky"))
        let terminalInClicky = FrontWindowContext(bundleIdentifier: "com.apple.Terminal", terminalWorkingDirectory: "/Users/me/Projects/clicky")
        #expect(resolve(terminalInClicky) == .denied(rootPath: "/Users/me/Projects/clicky"))
    }

    @Test func nothingUsableIsNotFound() {
        #expect(resolve(FrontWindowContext(bundleIdentifier: "com.apple.Safari", windowTitle: "app — GitHub")) == .notFound)
        #expect(resolve(FrontWindowContext(bundleIdentifier: "com.apple.Terminal", windowTitle: "-zsh — 80×24", terminalWorkingDirectory: "/Users/me/Downloads")) == .notFound)
        #expect(resolve(FrontWindowContext(bundleIdentifier: "com.microsoft.VSCode", windowTitle: "Welcome — Visual Studio Code")) == .notFound)
        // The home folder is never a project, even with a stray .git there.
        var homeRepo = files
        homeRepo.directories.insert("/Users/me/.git")
        #expect(FrontWindowRepoResolver.gitRoot(startingAt: "/Users/me/Downloads", homeDirectory: home, fileSystem: homeRepo.fileSystem) == nil)
    }

    @Test func picksTheForegroundShellsDirectory() {
        typealias Process = TerminalTTYLookup.TTYProcess
        let processes = [
            Process(processIdentifier: 100, processGroupIdentifier: 100, foregroundProcessGroupIdentifier: 300, name: "login", workingDirectory: "/"),
            Process(processIdentifier: 200, processGroupIdentifier: 200, foregroundProcessGroupIdentifier: 300, name: "-zsh", workingDirectory: "/Users/me/Projects/app"),
            Process(processIdentifier: 300, processGroupIdentifier: 300, foregroundProcessGroupIdentifier: 300, name: "vim", workingDirectory: "/Users/me/Projects/scratch")
        ]
        #expect(TerminalTTYLookup.pickWorkingDirectory(processes) == "/Users/me/Projects/scratch")
        let idleShell = [processes[0], Process(processIdentifier: 200, processGroupIdentifier: 200, foregroundProcessGroupIdentifier: 999, name: "-zsh",
                                               workingDirectory: "/Users/me/Projects/app")]
        #expect(TerminalTTYLookup.pickWorkingDirectory(idleShell) == "/Users/me/Projects/app")
        #expect(TerminalTTYLookup.workingDirectory(ttyName: "not-a-tty; rm -rf /") == nil)
    }

    @Test func localOnlyReposMatchByFolderName() {
        let matcher = RepoMatcher(localRepos: [LocalRepoEntry(folderPath: "/Users/me/Projects/clicky-scratch"),
                                               LocalRepoEntry(folderPath: "/Users/me/Projects/app", originURL: "git@github.com:me/app.git")])
        let result = matcher.match(spokenName: "clicky scratch")
        #expect(result.isConfident)
        #expect(result.top?.source == .localOnly)
        #expect(result.top?.fullName == "local/clicky-scratch")
        #expect(result.top?.folderPath == "/Users/me/Projects/clicky-scratch")
        #expect(matcher.match(spokenName: "app").top?.source == .localOrigin)
    }
}

// MARK: - Progress from stream-json

@Suite struct AgentProgressTests {
    let worktree = "/tmp/wt/clicky-scratch"

    func events(_ line: String) -> [AgentProgressEvent] {
        AgentProgressExtractor.events(fromLine: Data(line.utf8), workingDirectory: worktree)
    }

    @Test func extractsStepsAndFiles() {
        let edit = events(#"{"type":"assistant","message":{"content":[{"type":"text","text":"I'll fix it."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/tmp/wt/clicky-scratch/src/utils.py","old_string":"a","new_string":"b"}}]}}"#)
        #expect(edit == [AgentProgressEvent(kind: .editing, filePath: "src/utils.py", toolName: "Edit")])
        #expect(edit.first?.stepDescription == "editing utils.py")
        #expect(edit.first?.changesFile == true)
        let write = events(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/tmp/wt/clicky-scratch/tests/test_new.py","content":"x"}}]}}"#)
        #expect(write.first?.filePath == "tests/test_new.py")
        let read = events(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Read","input":{"file_path":"/tmp/wt/clicky-scratch/utils.py"}}]}}"#)
        #expect(read.first?.stepDescription == "reading utils.py" && read.first?.changesFile == false)
        let tests = events(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"python3 -m unittest discover -s tests"}}]}}"#)
        #expect(tests.first?.stepDescription == "running the tests")
        let grep = events(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t5","name":"Grep","input":{"pattern":"def add"}},{"type":"tool_use","id":"t6","name":"Glob","input":{"pattern":"**/*.py"}}]}}"#)
        #expect(grep.map(\.stepDescription) == ["searching the code", "searching the code"])
        // Results, init, text-only turns and junk give nothing.
        #expect(events(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#).isEmpty)
        #expect(events(#"{"type":"system","subtype":"init","tools":["Read"]}"#).isEmpty)
        #expect(events(#"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#).isEmpty)
        #expect(events("not json").isEmpty)
        // A path outside the worktree keeps its last two components.
        #expect(AgentProgressExtractor.relativePath("/Users/me/elsewhere/deep/file.txt", workingDirectory: worktree) == "deep/file.txt")
    }

    @Test func trackerKeepsFilesAndThrottlesNarration() {
        let start = Date(timeIntervalSince1970: 1_000)
        var tracker = CodeTaskProgressTracker(startedAt: start, initialStep: "making a worktree")
        #expect(tracker.narrationIfDue(now: start.addingTimeInterval(30)) == nil)  // no tool call yet
        tracker.apply(AgentProgressEvent(kind: .reading, filePath: "utils.py", toolName: "Read"))
        #expect(tracker.narrationIfDue(now: start.addingTimeInterval(5)) == nil)    // the heads-up was just spoken
        #expect(tracker.narrationIfDue(now: start.addingTimeInterval(20)) == "reading utils.py")
        tracker.apply(AgentProgressEvent(kind: .editing, filePath: "utils.py", toolName: "Edit"))
        tracker.apply(AgentProgressEvent(kind: .editing, filePath: "utils.py", toolName: "Edit"))
        tracker.apply(AgentProgressEvent(kind: .editing, filePath: "tests/test_utils.py", toolName: "Write"))
        #expect(tracker.narrationIfDue(now: start.addingTimeInterval(39)) == nil)   // < 20 s since the last one
        #expect(tracker.narrationIfDue(now: start.addingTimeInterval(41)) == "editing test_utils.py")
        #expect(tracker.narrationIfDue(now: start.addingTimeInterval(90)) == nil)   // same step: nothing new to say
        #expect(tracker.changedFiles == ["utils.py", "tests/test_utils.py"])
        let snapshot = tracker.snapshot(title: "Working on scratch", now: start.addingTimeInterval(65), queuedCount: 2)
        #expect(snapshot.elapsedText == "1:05" && snapshot.toolCallCount == 4 && snapshot.queuedCount == 2)
        #expect(snapshot.stepLine == "Editing test_utils.py  ·  1:05")
    }
}

// MARK: - Engine: local-only repos, progress, denylist

/// A fake agent that announces an Edit of $FAKE_TARGET (and edits it), a test run, then a result.
private let progressAgentScriptBody = #"""
trap '' INT TERM
tools=""; mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tools) tools="$2"; shift ;;
    --permission-mode) mode="$2"; shift ;;
    --json-schema) schema=1; shift ;;
  esac
  shift
done
# Like the real CLI: --json-schema adds the StructuredOutput tool.
if [ -n "${schema:-}" ]; then tools="$tools,StructuredOutput"; fi
cwd=$(pwd)
target="${FAKE_TARGET:-README.md}"
tools_json=$(printf '%s' "$tools" | sed 's/,/","/g')
printf '{"type":"system","subtype":"init","permissionMode":"%s","tools":["%s"],"mcp_servers":[],"plugins":[],"apiKeySource":"none","cwd":"%s","session_id":"sess-2"}\n' "$mode" "$tools_json" "$cwd"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"%s/%s"}}]}}\n' "$cwd" "$target"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"%s/%s","old_string":"x","new_string":"y"}}]}}\n' "$cwd" "$target"
printf '\n# edited by the fake agent\n' >> "$target"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"python3 -m unittest"}}]}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"denied","is_error":true}]}}'
printf '{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"sess-2","structured_output":{"spoken_summary":"I edited %s.","commit_message":"Edit %s","thread_replies":[],"tests":"","needs_user_input":null}}\n' "$target" "$target"
"""#

/// Collects progress events from the engine's (background) callback.
private final class ProgressEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [AgentProgressEvent] = []
    func append(_ event: AgentProgressEvent) { lock.withLock { collected.append(event) } }
    var events: [AgentProgressEvent] { lock.withLock { collected } }
}

struct CodeModeLiveEngineTests {
    private func makeEngine(_ sandbox: CodeSandbox, agentEnvironment: [String: String]) throws -> (CodeTaskEngine, ghLog: String) {
        let claudePath = try sandbox.writeScript("fake-claude.sh", progressAgentScriptBody)
        let ghLogPath = sandbox.path("gh-calls.log")
        let ghPath = try sandbox.writeScript("fake-gh.sh", "printf '%s\\n' \"$*\" >> '\(ghLogPath)'\nexit 1")
        let preflight = CodePreflightReport(isReady: true, failureReason: nil, effectiveSupportedFlags: AgentFlagSupport.allAgentFlags, droppedOptionalFlags: [], flagTable: "",
                                            viewerLogin: "tester", unremovableTools: [], apiKeySource: "none", date: Date())
        let engine = CodeTaskEngine(tools: CodeToolPaths(git: "/usr/bin/git", gh: ghPath, claude: claudePath), preflight: preflight, runner: ChildProcessCommandRunner(),
                                    environment: sandbox.gitEnvironment, agentBaseEnvironment: sandbox.gitEnvironment.merging(agentEnvironment) { $1 },
                                    workspaceRootURL: sandbox.rootURL.appendingPathComponent("code"), worktreesRootURL: sandbox.rootURL.appendingPathComponent("worktrees"),
                                    isBashAllowed: false, agentTimeouts: .total(60))
        return (engine, ghLogPath)
    }

    /// One commit, no remote (like ~/Projects/clicky-scratch).
    private func makeLocalOnlyRepo(_ sandbox: CodeSandbox, name: String) async throws -> String {
        let repoPath = sandbox.path(name)
        try await sandbox.git(["init", "--quiet", "--initial-branch=main", repoPath], in: sandbox.root)
        try "def add(first, second):\n    return first + second\n".write(toFile: repoPath + "/utils.py", atomically: true, encoding: .utf8)
        try await sandbox.git(["add", "utils.py"], in: repoPath)
        try await sandbox.git(["commit", "--quiet", "-m", "base"], in: repoPath)
        return repoPath
    }

    private func runLocalChange(engine: CodeTaskEngine, repoPath: String, log: ProgressEventLog) async throws -> PreparedReview {
        engine.onAgentProgress = { event in log.append(event) }
        let task = try CodeTask.decode(blockBody: #"{"action":"repo_change","repo":"this","instructions":"document add()","deliver":"pr"}"#)
        let repository = ResolvedRepository(remote: GitHubRemote(owner: RepoMatcher.localOnlyOwner, name: (repoPath as NSString).lastPathComponent), clonePath: repoPath, isLocalOnly: true)
        guard case .review(let review) = try await engine.prepare(task, repository: repository) else { throw CodeTaskEngineError.nothingChanged }
        return review
    }

    @Test func localOnlyChangeReportsProgressAndOffersNothingOutward() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let repoPath = try await makeLocalOnlyRepo(sandbox, name: "scratch")
        let baseOID = try await sandbox.git(["rev-parse", "HEAD"], in: repoPath)
        let (engine, ghLogPath) = try makeEngine(sandbox, agentEnvironment: ["FAKE_TARGET": "utils.py"])
        let log = ProgressEventLog()
        let review = try await runLocalChange(engine: engine, repoPath: repoPath, log: log)
        #expect(log.events.map(\.stepDescription) == ["reading utils.py", "editing utils.py", "running the tests"])
        #expect(log.events.filter(\.changesFile).compactMap(\.filePath) == ["utils.py"])
        #expect(review.content.diffFiles.map(\.displayPath) == ["utils.py"])
        // No GitHub remote: keep / merge locally only, no push or PR, no dry run, and gh never ran.
        #expect(review.content.buttons.map(\.id) == ["keep", "apply"])
        #expect(review.content.buttons.allSatisfy { !$0.isOutward })
        #expect(review.dryRunPush == nil)
        #expect(!FileManager.default.fileExists(atPath: ghLogPath))
        // The edit is in the worktree; the repo itself is untouched.
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: repoPath) == baseOID)
        #expect(try await sandbox.git(["status", "--porcelain"], in: repoPath).isEmpty)
    }

    @Test func localOnlyRefusesPullRequestActionsAndClickyCheckoutsAreRefused() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let repoPath = try await makeLocalOnlyRepo(sandbox, name: "scratch")
        let (engine, _) = try makeEngine(sandbox, agentEnvironment: [:])
        let localOnly = ResolvedRepository(remote: GitHubRemote(owner: "local", name: "scratch"), clonePath: repoPath, isLocalOnly: true)
        for body in [#"{"action":"fix_review","repo":"this","instructions":"x","pr":1}"#, #"{"action":"merge","repo":"this","instructions":"x","pr":1}"#,
                     #"{"action":"summarize","repo":"this","instructions":"x","pr":1}"#] {
            let task = try CodeTask.decode(blockBody: body)
            await #expect(throws: CodeTaskEngineError.localOnlyRepository(task.action)) { try await engine.prepare(task, repository: localOnly) }
        }
        // A checkout of Clicky (leanring-buddy.xcodeproj at its root) is refused before anything runs.
        let clickyPath = try await makeLocalOnlyRepo(sandbox, name: "clicky-copy")
        try FileManager.default.createDirectory(atPath: clickyPath + "/leanring-buddy.xcodeproj", withIntermediateDirectories: true)
        let task = try CodeTask.decode(blockBody: #"{"action":"ask_repo","repo":"clicky","instructions":"what is this?"}"#)
        await #expect(throws: CodeTaskEngineError.deniedRepository(clickyPath)) {
            try await engine.prepare(task, repository: ResolvedRepository(remote: GitHubRemote(owner: "me", name: "clicky"), clonePath: clickyPath))
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.path("code")))
    }

    /// Against the real scratch repo (CLICKY_SCRATCH_REPO=~/Projects/clicky-scratch). The fake
    /// agent edits utils.py in a Clicky worktree; the scratch repo's HEAD and files stay as they were,
    /// and the worktree is removed again.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLICKY_SCRATCH_REPO"] != nil))
    func scratchRepoRoundTrip() async throws {
        let scratchPath = (ProcessInfo.processInfo.environment["CLICKY_SCRATCH_REPO"]! as NSString).expandingTildeInPath
        #expect(!CodeRepoDenylist.isDeniedLocalRoot(scratchPath))
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let baseOID = try await sandbox.git(["rev-parse", "HEAD"], in: scratchPath)
        let originalUtils = try String(contentsOfFile: scratchPath + "/utils.py", encoding: .utf8)
        // "this repo" from a VS Code window on the scratch repo.
        let frontWindow = FrontWindowContext(bundleIdentifier: "com.microsoft.VSCode", windowTitle: "utils.py — \((scratchPath as NSString).lastPathComponent) — Visual Studio Code")
        let resolution = FrontWindowRepoResolver.resolve(frontWindow, localRepos: [LocalRepoEntry(folderPath: scratchPath)])
        #expect(resolution == .found(rootPath: scratchPath, source: "VS Code title"))

        let (engine, ghLogPath) = try makeEngine(sandbox, agentEnvironment: ["FAKE_TARGET": "utils.py"])
        let log = ProgressEventLog()
        let review = try await runLocalChange(engine: engine, repoPath: scratchPath, log: log)
        #expect(log.events.filter(\.changesFile).compactMap(\.filePath) == ["utils.py"])
        #expect(review.content.buttons.map(\.id).contains("keep") && !review.content.buttons.contains { $0.isOutward })
        #expect(!FileManager.default.fileExists(atPath: ghLogPath))
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: scratchPath) == baseOID)
        #expect(try String(contentsOfFile: scratchPath + "/utils.py", encoding: .utf8) == originalUtils)
        // Clean up the Clicky worktree and branch in the scratch repo.
        let manager = engine.worktreeManager
        for entry in try await manager.clickyWorktrees(clonePath: scratchPath) { try await manager.remove(entry, clonePath: scratchPath) }
        if let branch = review.worktree?.branch { _ = try? await sandbox.git(["branch", "-D", branch], in: scratchPath) }
        await manager.removeAllClickyRefs(clonePath: scratchPath)
        #expect(try await manager.clickyWorktrees(clonePath: scratchPath).isEmpty)
    }
}

// MARK: - Live: the real Claude Code CLI, end to end

/// `CLICKY_LIVE_AGENT_REPO=<a throwaway clone of ~/Projects/clicky-scratch> swift test --filter liveAgent`
/// runs the real preflight (real `claude`, a fake `gh` so nothing reaches GitHub) and then one real
/// repo_change through CodeTaskEngine with Bash on, as the app does after a passing codeprobe. The
/// agent's init must validate (no plugins, MCP servers or extra tools), the change lands in a Clicky
/// worktree, and `python3 -m unittest` passes there. The clone's own branch is left as it was.
@Suite(.serialized)
struct CodeModeLiveAgentTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLICKY_LIVE_AGENT_REPO"] != nil), .timeLimit(.minutes(15)))
    func liveAgentAddsMultiply() async throws {
        let repoPath = (ProcessInfo.processInfo.environment["CLICKY_LIVE_AGENT_REPO"]! as NSString).expandingTildeInPath
        let claudePath = try #require(await ExecutablePath.which("claude"))
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let ghPath = try sandbox.writeScript("fake-gh.sh", """
            case "$1 $2" in
              "auth status") exit 0 ;;
              "api user") echo tester ;;
              *) exit 1 ;;
            esac
            """)
        let tools = CodeToolPaths(git: "/usr/bin/git", gh: ghPath, claude: claudePath)
        let baseOID = try await sandbox.git(["rev-parse", "HEAD"], in: repoPath)

        let preflight = await CodePreflight(tools: tools, runner: ChildProcessCommandRunner(), probeWorkingDirectory: sandbox.root).run()
        print("live preflight: \(preflight.statusLine) · disabled plugins \(preflight.disabledPluginSources) · unremovable \(preflight.unremovableTools)")
        #expect(preflight.isReady, "\(preflight.spokenExplanation)")
        guard preflight.isReady else { return }

        let engine = CodeTaskEngine(tools: tools, preflight: preflight, runner: ChildProcessCommandRunner(),
                                    workspaceRootURL: sandbox.rootURL.appendingPathComponent("code"), worktreesRootURL: sandbox.rootURL.appendingPathComponent("worktrees"),
                                    isBashAllowed: true)
        let task = try CodeTask.decode(blockBody: #"{"action":"repo_change","repo":"this","instructions":"add a function multiply(a,b) to utils.py with a unittest","deliver":"pr"}"#)
        let repository = ResolvedRepository(remote: GitHubRemote(owner: RepoMatcher.localOnlyOwner, name: (repoPath as NSString).lastPathComponent), clonePath: repoPath, isLocalOnly: true)
        let preparation = try await engine.prepare(task, repository: repository)
        guard case .review(let review) = preparation else { Issue.record("expected a review, got \(preparation)"); return }

        // The agent's own init event, as the validator saw it.
        let transcript = try String(contentsOf: review.workspace.agentTranscriptURL, encoding: .utf8)
        let initLine = try #require(transcript.split(separator: "\n").first { $0.contains(#""subtype":"init""#) })
        let initEvent = try #require(JSONSerialization.jsonObject(with: Data(initLine.utf8)) as? [String: Any])
        print("live init: tools \(initEvent["tools"] ?? "-") · plugins \(initEvent["plugins"] ?? "-") · mcp \(initEvent["mcp_servers"] ?? "-") · skills \((initEvent["skills"] as? [Any])?.count ?? -1) · permissionMode \(initEvent["permissionMode"] ?? "-")")
        #expect(AgentInitValidator.namedEntries(initEvent["plugins"]).isEmpty)
        #expect(AgentInitValidator.namedEntries(initEvent["mcp_servers"]).isEmpty)
        #expect(review.agentReport?.outcome.isSuccess == true)

        let worktree = try #require(review.worktree)
        print("live diff (\(review.content.diffFiles.map(\.displayPath))):\n\(review.diffText.prefix(2000))")
        #expect(review.diffText.contains("def multiply"))
        let unittest = try await ChildProcess.run(executable: "/usr/bin/env", arguments: ["python3", "-m", "unittest", "-v"],
                                                  environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "PYTHONDONTWRITEBYTECODE": "1"], workingDirectory: worktree.path, timeouts: .total(60))
        print("live unittest: exit \(unittest.exitStatus.map(String.init) ?? "signal")\n\(unittest.standardErrorText.suffix(800))")
        #expect(unittest.succeeded)
        // More tests than the one the scratch repo starts with: the new unittest ran too.
        let ranLine = unittest.standardErrorText.split(separator: "\n").first { $0.hasPrefix("Ran ") }
        let ranCount = ranLine.flatMap { Int($0.split(separator: " ")[1]) } ?? 0
        #expect(ranCount >= 2, "\(ranCount) tests ran")

        // The clone's branch is where it was; remove the Clicky worktree and branch.
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: repoPath) == baseOID)
        let manager = engine.worktreeManager
        for entry in try await manager.clickyWorktrees(clonePath: repoPath) { try await manager.remove(entry, clonePath: repoPath) }
        _ = try? await sandbox.git(["branch", "-D", worktree.branch], in: repoPath)
        await manager.removeAllClickyRefs(clonePath: repoPath)
    }
}

// MARK: - "Turn on code mode" chip

@Suite struct CodeModeChipGateTests {
    private let window = 42
    private func input(_ kind: CodeModeChipInput.Kind, at timestamp: TimeInterval, userData: Int64 = 0, window: Int? = nil, onChip: Bool = true) -> CodeModeChipInput {
        CodeModeChipInput(kind: kind, timestamp: timestamp, windowNumber: window ?? self.window, eventSourceUserData: userData, isOnChip: onChip)
    }

    @Test func aRealClickTurnsItOnOnce() {
        var gate = CodeModeChipGate(windowNumber: window, shownAt: 100)
        #expect(gate.handle(input(.mouseDown, at: 101)) == .pressStarted)
        #expect(gate.handle(input(.mouseUp, at: 101.1)) == .turnOn)
        #expect(gate.handle(input(.mouseDown, at: 102)) == .rejected(.alreadyUsed))
    }

    @Test func syntheticKeysVoiceAndEarlyClicksNeverCount() {
        var gate = CodeModeChipGate(windowNumber: window, shownAt: 100)
        #expect(gate.handle(input(.mouseDown, at: 101, userData: SyntheticEventTag.value)) == .rejected(.syntheticEvent))
        #expect(gate.handle(input(.mouseUp, at: 101.1, userData: SyntheticEventTag.value)) == .rejected(.syntheticEvent))
        #expect(gate.handle(input(.key, at: 101)) == .rejected(.notAMouseClick))
        #expect(gate.handle(input(.voice, at: 101)) == .rejected(.notAMouseClick))
        #expect(gate.handle(input(.mouseDown, at: 100.2)) == .rejected(.shownTooRecently))
        #expect(gate.handle(input(.mouseUp, at: 100.3)) == .rejected(.releaseWithoutPress))
        // A real press followed by a synthetic release is not a click.
        #expect(gate.handle(input(.mouseDown, at: 101)) == .pressStarted)
        #expect(gate.handle(input(.mouseUp, at: 101.1, userData: SyntheticEventTag.value)) == .rejected(.syntheticEvent))
        #expect(gate.handle(input(.mouseUp, at: 101.2)) == .rejected(.releaseWithoutPress))
        #expect(gate.handle(input(.mouseDown, at: 101, window: 7)) == .rejected(.wrongWindow))
        #expect(gate.handle(input(.mouseDown, at: 101, onChip: false)) == .rejected(.notOnChip))
        #expect(gate.handle(input(.mouseDown, at: 100 + CodeModeChipGate.lifetime + 1)) == .rejected(.expired))
        #expect(!gate.isUsed)
    }

    @Test func releaseOffTheChipCancels() {
        var gate = CodeModeChipGate(windowNumber: window, shownAt: 0)
        #expect(gate.handle(input(.mouseDown, at: 1)) == .pressStarted)
        #expect(gate.handle(input(.mouseUp, at: 1.2, onChip: false)) == .rejected(.notOnChip))
        #expect(gate.handle(input(.mouseUp, at: 1.3)) == .rejected(.releaseWithoutPress))
    }
}
