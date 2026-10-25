//
//  CodeEngineTests.swift
//  ClickyCoreTests
//
//  P5 Code mode, the parts that run processes: the `claude --help` flag
//  parser, the agent runner against fake agents (every bad init field is
//  SIGKILLed), worktrees and their integrity hashes in temp repos, the real
//  outward step runner against a temp bare remote (a failed push sends no
//  replies), preflight and two whole flows with fake `claude`/`gh` scripts,
//  the NSEvent → gate mapping, and an offscreen render of the review panel.
//  Nothing here touches a real repo, the network or the user's git config.
//

import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import ClickyCore

// MARK: - Fixtures

/// A temp folder with helpers for repos and scripts; removed by `cleanUp()`.
final class CodeSandbox: @unchecked Sendable {
    let rootURL: URL
    var root: String { rootURL.path }

    init() throws {
        let baseURL = URL(fileURLWithPath: ProcessSweep.resolvedPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory())
        rootURL = baseURL.appendingPathComponent("clicky-code-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func cleanUp() {
        // Worktrees are locked; unlock by removing the folder outright.
        try? FileManager.default.removeItem(at: rootURL)
    }

    func path(_ relativePath: String) -> String { rootURL.appendingPathComponent(relativePath).path }

    /// Plain git for test setup, isolated from ~/.gitconfig.
    var gitEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
         "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
         "GIT_TERMINAL_PROMPT": "0"]
    }

    @discardableResult
    func git(_ arguments: [String], in directory: String) async throws -> String {
        let result = try await ChildProcess.run(executable: "/usr/bin/git", arguments: ["-C", directory] + arguments, environment: gitEnvironment, timeouts: .total(30))
        guard result.succeeded else { throw CodeCommandError.failed(command: arguments.joined(separator: " "), exitStatus: result.exitStatus, message: result.standardErrorText) }
        return result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A bare "remote" with one commit on main, and a clone of it.
    func makeRemoteAndClone(remoteName: String = "remote.git", cloneName: String = "clone") async throws -> (remote: String, clone: String, baseOID: String) {
        let remotePath = path(remoteName)
        let seedPath = path("seed-\(UUID().uuidString.prefix(4))")
        try await git(["init", "--quiet", "--bare", "--initial-branch=main", remotePath], in: root)
        try await git(["init", "--quiet", "--initial-branch=main", seedPath], in: root)
        try "hello\n".write(toFile: seedPath + "/README.md", atomically: true, encoding: .utf8)
        try await git(["add", "README.md"], in: seedPath)
        try await git(["commit", "--quiet", "-m", "base"], in: seedPath)
        try await git(["push", "--quiet", remotePath, "main"], in: seedPath)
        let clonePath = path(cloneName)
        try await git(["clone", "--quiet", remotePath, clonePath], in: root)
        return (remotePath, clonePath, try await git(["rev-parse", "HEAD"], in: clonePath))
    }

    /// An executable /bin/sh script.
    @discardableResult
    func writeScript(_ name: String, _ body: String) throws -> String {
        let scriptPath = path(name)
        try ("#!/bin/sh\n" + body + "\n").write(toFile: scriptPath, atomically: true, encoding: .utf8)
        chmod(scriptPath, 0o755)
        return scriptPath
    }

    func hardenedGit(ghPath: String = "/usr/bin/false") -> HardenedGit {
        HardenedGit(gitPath: "/usr/bin/git", ghPath: ghPath, runner: ChildProcessCommandRunner(), environment: gitEnvironment)
    }
}

private func processGroupExists(_ processGroupIdentifier: pid_t) -> Bool {
    kill(-processGroupIdentifier, 0) == 0 || errno != ESRCH
}

/// A fake `claude` agent: prints a system/init built from its own argv
/// (tools, permission mode) and cwd, optionally edits README.md, then a result.
/// FAKE_INIT_OVERRIDE replaces the whole init line ("__CWD__" → cwd).
/// FAKE_AFTER_INIT=sleep keeps it alive (must be killed).
let fakeAgentScriptBody = #"""
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
tools_json=$(printf '%s' "$tools" | sed 's/,/","/g')
if [ -n "${FAKE_INIT_OVERRIDE:-}" ]; then
  printf '%s\n' "$FAKE_INIT_OVERRIDE" | sed "s#__CWD__#$cwd#g"
elif [ "${FAKE_NO_INIT:-}" = "1" ]; then
  :
else
  printf '{"type":"system","subtype":"init","permissionMode":"%s","tools":["%s"],"mcp_servers":[],"plugins":[],"apiKeySource":"none","cwd":"%s","session_id":"sess-1"}\n' "$mode" "$tools_json" "$cwd"
fi
if [ "${FAKE_AFTER_INIT:-}" = "sleep" ]; then sleep 300; exit 0; fi
if [ "${FAKE_EDIT:-}" = "1" ]; then printf 'added by agent\n' >> README.md; fi
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
printf '{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"sess-1","structured_output":{"spoken_summary":"%s","commit_message":"Add a README line","thread_replies":[],"tests":"","needs_user_input":null}}\n' "${FAKE_SUMMARY:-All done.}"
"""#

private let testBaseEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

private func sampleInvocation(sandbox: CodeSandbox, readOnly: Bool = false) -> AgentInvocation {
    AgentInvocation(prompt: "do it", contextDirectoryPath: sandbox.path("ctx"), outboxDirectoryPath: sandbox.path("outbox"), emptyGHConfigDirectoryPath: sandbox.path("gh"),
                    ownership: .own, isReadOnly: readOnly, bashAllowed: false, session: .new(identifier: "11111111-2222-3333-4444-555555555555"))
}

private func allFlags() -> Set<String> { Set(AgentFlagSupport.allAgentFlags) }

// MARK: - claude --help

/// Option lines copied from `claude --help` 2.1.301 (descriptions trimmed),
/// plus a description line that names --permission-prompt-tool mid-text.
let claudeHelpFixture = """
Usage: claude [options] [command] [prompt]

Options:
  --add-dir <directories...>            Additional directories to allow tool
                                        access to
  --allowedTools, --allowed-tools <tools...>
      Comma or space-separated list of tool names to allow
  --append-system-prompt <prompt>       Append a system prompt to the default
  --bare                                Minimal mode: skip hooks ...
                                        --settings, --agents, --plugin-dir.
  --disable-slash-commands              Disable all skills
  --disallowedTools, --disallowed-tools <tools...>
      Comma or space-separated list of tool names to deny
  --include-partial-messages            Include partial message chunks as they
  --json-schema <schema>                JSON Schema for structured output
  --model <model>                       Model for the current session.
  --no-session-persistence              Disable session persistence
  --output-format <format>              Output format (only works with --print)
  --permission-mode <mode>              Permission mode to use for the session
  --permission-prompts <target>         Who answers permission prompts with
                                        --print: "host" (the SDK host or
                                        --permission-prompt-tool) or "none"
  -p, --print                           Print response and exit
  -r, --resume [value]                  Resume a conversation by session ID
  --session-id <uuid>                   Use a specific session ID
  --setting-sources <sources>           Comma-separated list of setting sources
  --settings <file-or-json>             Path to a settings JSON file
  --strict-mcp-config                   Only use MCP servers from --mcp-config
  --system-prompt <prompt>              System prompt to use for the session
  --tools <tools...>                    Specify the list of available tools
  --verbose                             Override verbose mode setting from
  -v, --version                         Output the version number

Commands:
  auth                                  Manage authentication
"""

struct ClaudeHelpParserTests {
    @Test func parsesOptionLinesOnly() {
        let flags = ClaudeHelpParser.supportedFlags(fromHelpText: claudeHelpFixture)
        #expect(flags.isSuperset(of: ["-p", "--print", "-r", "--resume", "--disallowedTools", "--disallowed-tools", "--json-schema", "--permission-prompts", "--tools"]))
        #expect(!flags.contains("--permission-prompt-tool"))   // only named inside a description
        #expect(!flags.contains("--max-turns"))                // hidden from --help
        #expect(!flags.contains("--append-system-prompt-file"))
        #expect(!flags.contains("auth"))
    }

    @Test func reportKeepsFallsBackAndNeedsProbe() {
        let helpFlags = ClaudeHelpParser.supportedFlags(fromHelpText: claudeHelpFixture)
        let beforeProbe = AgentFlagSupport.evaluate(helpFlags: helpFlags)
        let statusByFlag = Dictionary(uniqueKeysWithValues: beforeProbe.rows.map { ($0.flag, $0.status) })
        #expect(statusByFlag["--max-turns"] == .needsProbe)
        #expect(statusByFlag["--append-system-prompt-file"] == .fallback)
        #expect(statusByFlag["--json-schema"] == .kept && statusByFlag["--permission-prompts"] == .kept)
        #expect(statusByFlag["-p"] == .kept && statusByFlag["--disallowedTools"] == .kept)
        #expect(!beforeProbe.isUsable && beforeProbe.missingRequiredFlags == ["--max-turns"])

        let afterProbe = AgentFlagSupport.evaluate(helpFlags: helpFlags, probeVerifiedFlags: ["--max-turns"])
        #expect(afterProbe.isUsable && afterProbe.droppedOptionalFlags.isEmpty)
        // The fallback puts rules.md inline and drops nothing.
        let invocation = AgentInvocation(prompt: "x", contextDirectoryPath: "/c", outboxDirectoryPath: "/o", emptyGHConfigDirectoryPath: "/g",
                                         ownership: .own, isReadOnly: false, bashAllowed: false, session: .new(identifier: "s"))
        let (argv, dropped) = invocation.arguments(supportedFlags: afterProbe.effectiveSupportedFlags)
        #expect(dropped.isEmpty)
        #expect(!argv.contains("--append-system-prompt-file"))
        #expect(argv.firstIndex(of: "--append-system-prompt").map { argv[$0 + 1] } == invocation.rulesMarkdown)
        #expect(invocation.missingRequiredFlags(supportedFlags: afterProbe.effectiveSupportedFlags).isEmpty)
        #expect(AgentInvocation.forbiddenTokens(in: argv).isEmpty)
    }

    @Test func missingRequiredFlagIsReported() {
        var helpFlags = ClaudeHelpParser.supportedFlags(fromHelpText: claudeHelpFixture)
        helpFlags.remove("--permission-mode")
        helpFlags.remove("--json-schema")
        let report = AgentFlagSupport.evaluate(helpFlags: helpFlags, probeVerifiedFlags: ["--max-turns"])
        #expect(report.missingRequiredFlags == ["--permission-mode"])
        #expect(report.droppedOptionalFlags == ["--json-schema"])
    }

    /// `CLICKY_REAL_CLAUDE_HELP=<file with claude --help output> swift test` prints the table.
    @Test func realHelpTableWhenProvided() throws {
        guard let helpPath = ProcessInfo.processInfo.environment["CLICKY_REAL_CLAUDE_HELP"] else { return }
        let helpText = try String(contentsOfFile: helpPath, encoding: .utf8)
        let report = AgentFlagSupport.evaluate(helpFlags: ClaudeHelpParser.supportedFlags(fromHelpText: helpText))
        print("CLAUDE-HELP-FLAG-TABLE\n" + report.tableText + "\nmissing before probe: \(report.missingRequiredFlags)\ndropped: \(report.droppedOptionalFlags)")
    }
}

// MARK: - Agent runner

@Suite(.serialized)
struct CodeAgentRunnerTests {
    private func runFakeAgent(sandbox: CodeSandbox, environment extraEnvironment: [String: String], initTimeoutSeconds: TimeInterval = 10,
                              readOnly: Bool = false) async throws -> (AgentRunReport, TimeInterval) {
        let agentPath = try sandbox.writeScript("fake-claude-\(UUID().uuidString.prefix(4)).sh", fakeAgentScriptBody)
        let workPath = sandbox.path("work")
        try FileManager.default.createDirectory(atPath: workPath, withIntermediateDirectories: true)
        let invocation = sampleInvocation(sandbox: sandbox, readOnly: readOnly)
        let expectation = AgentInitExpectation(expectedTools: Set(invocation.expectedInitTools(supportedFlags: allFlags())), apiKeySource: "none", worktreePath: workPath)
        let configuration = AgentRunConfiguration(claudePath: agentPath, invocation: invocation, supportedFlags: allFlags(), expectation: expectation,
                                                  workingDirectory: workPath, baseEnvironment: testBaseEnvironment.merging(extraEnvironment) { $1 },
                                                  timeouts: .total(60), initTimeoutSeconds: initTimeoutSeconds)
        let startDate = Date()
        let report = await CodeAgentRunner(configuration: configuration).run()
        return (report, Date().timeIntervalSince(startDate))
    }

    @Test func goodInitRunsToResult() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let (report, _) = try await runFakeAgent(sandbox: sandbox, environment: ["FAKE_SUMMARY": "It works."])
        guard case .completed(_, let result) = report.outcome else { Issue.record("outcome \(report.outcome)"); return }
        #expect(result?.spokenSummary == "It works.")
        #expect(result?.commitMessage == "Add a README line")
        #expect(report.sessionIdentifier == "sess-1")
        #expect(report.isProcessGroupReaped)
        #expect(report.droppedFlags.isEmpty)
    }

    /// Each bad field → initRejected with that failure, and the agent (which
    /// ignores SIGINT/SIGTERM and would sleep 300 s) is SIGKILLed at once.
    @Test func eachBadInitFieldKillsTheAgent() async throws {
        let base: [String: Any] = ["type": "system", "subtype": "init", "permissionMode": "acceptEdits", "tools": ["Read", "Edit", "Write", "Glob", "Grep", "StructuredOutput"],
                                   "mcp_servers": [], "plugins": [], "apiKeySource": "none", "cwd": "__CWD__"]
        let cases: [(String, [String: Any], (AgentInitFailure) -> Bool)] = [
            ("permissionMode", ["permissionMode": "default"], { if case .permissionMode = $0 { return true }; return false }),
            ("bypass", ["permissionMode": "bypassPermissions"], { if case .permissionMode = $0 { return true }; return false }),
            ("extra tool", ["tools": ["Read", "Edit", "Write", "Glob", "Grep", "StructuredOutput", "Bash"]], { if case .tools(let unexpected, _) = $0 { return unexpected == ["Bash"] }; return false }),
            ("missing tool", ["tools": ["Read"]], { if case .tools = $0 { return true }; return false }),
            ("mcp", ["mcp_servers": [["name": "evil", "status": "connected"]]], { $0 == .mcpServers(["evil"]) }),
            ("plugins", ["plugins": [["name": "helper"]]], { $0 == .plugins(["helper"]) }),
            ("apiKeySource", ["apiKeySource": "ANTHROPIC_API_KEY"], { $0 == .apiKeySource(found: "ANTHROPIC_API_KEY") }),
            ("cwd", ["cwd": "/tmp/elsewhere"], { $0 == .workingDirectory(found: "/tmp/elsewhere") })
        ]
        for (name, overrides, matches) in cases {
            let sandbox = try CodeSandbox()
            defer { sandbox.cleanUp() }
            let initEvent = base.merging(overrides) { $1 }
            let initLine = String(decoding: try JSONSerialization.data(withJSONObject: initEvent, options: [.withoutEscapingSlashes]), as: UTF8.self)
            let (report, elapsed) = try await runFakeAgent(sandbox: sandbox, environment: ["FAKE_INIT_OVERRIDE": initLine, "FAKE_AFTER_INIT": "sleep"])
            guard case .initRejected(let failures) = report.outcome else { Issue.record("\(name): outcome \(report.outcome)"); continue }
            #expect(failures.contains(where: matches), "\(name): \(failures)")
            #expect(elapsed < 5, "\(name) took \(elapsed) s")
            #expect(report.isProcessGroupReaped)
            if let processIdentifier = report.processIdentifier { #expect(!processGroupExists(processIdentifier), "\(name) group alive") }
        }
    }

    @Test func nonInitFirstEventKillsTheAgent() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let (report, elapsed) = try await runFakeAgent(sandbox: sandbox, environment: [
            "FAKE_INIT_OVERRIDE": #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#, "FAKE_AFTER_INIT": "sleep"])
        #expect(report.outcome == .initRejected([.notAnInitEvent]))
        #expect(elapsed < 5)
    }

    @Test func missingInitTimesOutAndKills() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let (report, elapsed) = try await runFakeAgent(sandbox: sandbox, environment: ["FAKE_NO_INIT": "1", "FAKE_AFTER_INIT": "sleep"], initTimeoutSeconds: 1)
        #expect(report.outcome == .initTimedOut)
        #expect(elapsed < 5)
        if let processIdentifier = report.processIdentifier { #expect(!processGroupExists(processIdentifier)) }
    }

    @Test func readOnlyToolsAreChecked() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let (report, _) = try await runFakeAgent(sandbox: sandbox, environment: [:], readOnly: true)
        #expect(report.outcome.isSuccess)
    }

    @Test func extractsResultFromTextWhenNoStructuredOutput() {
        let text = "Here is what I did.\n```json\n{\"spoken_summary\":\"Fixed it.\",\"commit_message\":\"fix: x\",\"thread_replies\":[{\"thread_id\":\"PRRT_1\",\"body\":\"done {ok}\",\"resolve\":true}],\"tests\":\"\",\"needs_user_input\":null}\n```"
        let result = AgentResultExtractor.extract(fromText: text)
        #expect(result?.spokenSummary == "Fixed it.")
        #expect(result?.threadReplies.first?.body == "done {ok}")
        #expect(AgentResultExtractor.extract(fromText: "no json here") == nil)
    }
}

// MARK: - fakecli cancel

@Test func cancelEmptiesFakeCLIIgnoringSIGINTWithinSevenSeconds() async throws {
    let fakeCLIPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Tools/fakecli/fakecli.sh").standardizedFileURL.path
    #expect(FileManager.default.isExecutableFile(atPath: fakeCLIPath) || FileManager.default.fileExists(atPath: fakeCLIPath))
    let childProcess = try ChildProcess.launch(executable: "/bin/sh", arguments: [fakeCLIPath, "ignore-int"], environment: testBaseEnvironment)
    try await Task.sleep(nanoseconds: 300_000_000)
    let startDate = Date()
    childProcess.cancel()
    let result = await childProcess.waitForExit()
    #expect(Date().timeIntervalSince(startDate) < 7)
    #expect(result.endReason == .cancelled)
    #expect(!processGroupExists(childProcess.processGroupIdentifier))
    let childLine = result.standardOutputText.split(separator: "\n").first { $0.hasPrefix("child ") }
    if let childLine, let childPID = pid_t(childLine.dropFirst("child ".count)) {
        #expect(kill(childPID, 0) == -1)
    }
}

// MARK: - Worktrees

@Suite(.serialized)
struct WorktreeTests {
    @Test func integrityDetectsConfigHooksAndPointerChanges() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let (_, clonePath, baseOID) = try await sandbox.makeRemoteAndClone()
        let manager = WorktreeManager(git: sandbox.hardenedGit(), worktreesRootURL: sandbox.rootURL.appendingPathComponent("worktrees"))
        let worktree = try await manager.prepareForBranch(clonePath: clonePath, owner: "o", name: "n", slug: "Fix the thing!", baseRevision: "main")
        #expect(worktree.startOID == baseOID)
        #expect(worktree.branch.hasPrefix("clicky/fix-the-thing-"))
        let paths = try await manager.integrityPaths(for: worktree)
        let before = IntegritySnapshot.capture(paths: paths)
        #expect(before.changedPaths(comparedTo: IntegritySnapshot.capture(paths: paths)).isEmpty)

        // An edit in the worktree itself is fine.
        try "changed\n".write(toFile: worktree.path + "/README.md", atomically: true, encoding: .utf8)
        #expect(before.changedPaths(comparedTo: IntegritySnapshot.capture(paths: paths)).isEmpty)

        let configPath = clonePath + "/.git/config"
        let originalConfig = try String(contentsOfFile: configPath, encoding: .utf8)
        try (originalConfig + "[core]\n\tfsmonitor = /tmp/evil\n").write(toFile: configPath, atomically: true, encoding: .utf8)
        #expect(before.changedPaths(comparedTo: IntegritySnapshot.capture(paths: paths)) == [configPath])
        try originalConfig.write(toFile: configPath, atomically: true, encoding: .utf8)

        let hookPath = clonePath + "/.git/hooks/pre-push"
        try "#!/bin/sh\nexit 0\n".write(toFile: hookPath, atomically: true, encoding: .utf8)
        #expect(before.changedPaths(comparedTo: IntegritySnapshot.capture(paths: paths)) == [hookPath])
        try FileManager.default.removeItem(atPath: hookPath)

        let pointerPath = worktree.path + "/.git"
        let pointer = try String(contentsOfFile: pointerPath, encoding: .utf8)
        try (pointer + "\n").write(toFile: pointerPath, atomically: true, encoding: .utf8)
        #expect(before.changedPaths(comparedTo: IntegritySnapshot.capture(paths: paths)) == [pointerPath])
    }

    @Test func pullRequestWorktreeCommitAndCleanup() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let (remotePath, clonePath, _) = try await sandbox.makeRemoteAndClone()
        // A "PR head" one commit ahead, published as refs/pull/7/head on the remote.
        try await sandbox.git(["checkout", "--quiet", "-b", "feature"], in: clonePath)
        try "feature\n".write(toFile: clonePath + "/feature.txt", atomically: true, encoding: .utf8)
        try await sandbox.git(["add", "feature.txt"], in: clonePath)
        try await sandbox.git(["commit", "--quiet", "-m", "feature"], in: clonePath)
        let headOID = try await sandbox.git(["rev-parse", "HEAD"], in: clonePath)
        try await sandbox.git(["push", "--quiet", remotePath, "HEAD:refs/pull/7/head"], in: clonePath)
        try await sandbox.git(["checkout", "--quiet", "main"], in: clonePath)

        let manager = WorktreeManager(git: sandbox.hardenedGit(), worktreesRootURL: sandbox.rootURL.appendingPathComponent("worktrees"))
        do {
            _ = try await manager.prepareForPullRequest(clonePath: clonePath, fetchURL: remotePath, owner: "o", name: "n", pullRequestNumber: 7, expectedHeadOID: String(repeating: "0", count: 40))
            Issue.record("a wrong head OID must fail")
        } catch WorktreeError.headMismatch {}
        let worktree = try await manager.prepareForPullRequest(clonePath: clonePath, fetchURL: remotePath, owner: "o", name: "n", pullRequestNumber: 7, expectedHeadOID: headOID)
        #expect(worktree.branch == "clicky/pr-7")
        #expect(worktree.path.hasSuffix("worktrees/o__n/pr-7"))

        // No change → nothingToCommit; a change → exactly one commit on top.
        let messageURL = sandbox.rootURL.appendingPathComponent("msg.txt")
        try "Fix review comments\n".write(to: messageURL, atomically: true, encoding: .utf8)
        await #expect(throws: WorktreeError.nothingToCommit) { _ = try await manager.commitAgentChanges(worktree, commitMessageFileURL: messageURL, amend: false) }
        #expect(try await manager.foldAgentCommits(worktree, headBeforeAgent: headOID) == 0)
        try "feature fixed\n".write(toFile: worktree.path + "/feature.txt", atomically: true, encoding: .utf8)
        // The agent may `git commit` (allowlisted): its commits fold back into Clicky's one commit.
        try await sandbox.git(["add", "feature.txt"], in: worktree.path)
        try await sandbox.git(["commit", "--quiet", "-m", "agent's own commit"], in: worktree.path)
        #expect(try await manager.foldAgentCommits(worktree, headBeforeAgent: headOID) == 1)
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: worktree.path) == headOID)
        let commitOID = try await manager.commitAgentChanges(worktree, commitMessageFileURL: messageURL, amend: false)
        #expect(try await sandbox.git(["rev-parse", "HEAD~1"], in: worktree.path) == headOID)
        let diff = try await manager.reviewDiff(worktree)
        #expect(DiffParser.parse(diff).map(\.displayPath) == ["feature.txt"])
        // A follow-up amends (still one commit).
        try "Fix review comments (2)\n".write(to: messageURL, atomically: true, encoding: .utf8)
        let amendedOID = try await manager.commitAgentChanges(worktree, commitMessageFileURL: messageURL, amend: true)
        #expect(amendedOID != commitOID)
        #expect(try await sandbox.git(["rev-parse", "HEAD~1"], in: worktree.path) == headOID)

        // Cleanup sees only Clicky's worktree, counts the unpushed commit, removes it and its refs.
        let entries = try await manager.clickyWorktrees(clonePath: clonePath)
        #expect(entries.count == 1 && entries.first?.shortBranch == "clicky/pr-7")
        #expect(await manager.unpushedCommitCount(entries[0], clonePath: clonePath, alsoExcluding: ["refs/clicky/pr/7"]) == 1)
        try await manager.remove(entries[0], clonePath: clonePath)
        #expect(try await manager.clickyWorktrees(clonePath: clonePath).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        let remainingRefs = try await sandbox.git(["for-each-ref", "--format=%(refname)", "refs/clicky/", "refs/heads/clicky/"], in: clonePath)
        #expect(remainingRefs.isEmpty)
        // The clone itself is never listed as removable.
        await #expect(throws: WorktreeError.notUnderWorktreeRoot(clonePath)) { try await manager.remove(WorktreeListEntry(path: clonePath), clonePath: clonePath) }
    }

    @Test func conflictMergeCommitHasHeadAndBaseParents() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let (remotePath, clonePath, _) = try await sandbox.makeRemoteAndClone()
        try await sandbox.git(["checkout", "--quiet", "-b", "feature"], in: clonePath)
        try "feature line\n".write(toFile: clonePath + "/README.md", atomically: true, encoding: .utf8)
        try await sandbox.git(["commit", "--quiet", "-am", "feature"], in: clonePath)
        let headOID = try await sandbox.git(["rev-parse", "HEAD"], in: clonePath)
        try await sandbox.git(["push", "--quiet", remotePath, "HEAD:refs/pull/3/head"], in: clonePath)
        try await sandbox.git(["checkout", "--quiet", "main"], in: clonePath)
        try "main line\n".write(toFile: clonePath + "/README.md", atomically: true, encoding: .utf8)
        try await sandbox.git(["commit", "--quiet", "-am", "main moves"], in: clonePath)
        try await sandbox.git(["push", "--quiet", remotePath, "main"], in: clonePath)
        let baseOID = try await sandbox.git(["rev-parse", "HEAD"], in: clonePath)

        let manager = WorktreeManager(git: sandbox.hardenedGit(), worktreesRootURL: sandbox.rootURL.appendingPathComponent("worktrees"))
        let worktree = try await manager.prepareForPullRequest(clonePath: clonePath, fetchURL: remotePath, owner: "o", name: "n", pullRequestNumber: 3, expectedHeadOID: headOID)
        let (mergingWorktree, hasConflicts) = try await manager.startConflictMerge(worktree, fetchURL: remotePath, baseBranch: "main")
        #expect(hasConflicts)
        #expect(mergingWorktree.mergeBaseOID == baseOID)
        let conflicted = try String(contentsOfFile: worktree.path + "/README.md", encoding: .utf8)
        #expect(conflicted.contains("<<<<<<<"))
        // The "agent" resolves it.
        try "feature line\nmain line\n".write(toFile: worktree.path + "/README.md", atomically: true, encoding: .utf8)
        let messageURL = sandbox.rootURL.appendingPathComponent("merge-msg.txt")
        try "Merge main into feature\n".write(to: messageURL, atomically: true, encoding: .utf8)
        let mergeOID = try await manager.commitAgentChanges(mergingWorktree, commitMessageFileURL: messageURL, amend: false)
        let parents = try await sandbox.git(["rev-list", "--parents", "-n", "1", mergeOID], in: worktree.path).split(separator: " ").dropFirst().map(String.init)
        #expect(parents == [headOID, baseOID])
    }

    @Test func parsesWorktreePorcelain() {
        let porcelain = "worktree /a/clone\nHEAD 1111\nbranch refs/heads/main\n\nworktree /root/o__n/pr-7\nHEAD 2222\nbranch refs/heads/clicky/pr-7\nlocked\n\nworktree /x\nHEAD 3333\ndetached\nprunable gitdir file points to non-existent location\n"
        let entries = WorktreeListEntry.parsePorcelain(porcelain)
        #expect(entries.count == 3)
        #expect(entries[1].isLocked && entries[1].shortBranch == "clicky/pr-7")
        #expect(entries[2].isDetached && entries[2].isPrunable && entries[2].shortBranch == nil)
    }

    @Test func slugs() {
        #expect(WorktreeManager.slug(from: "Fix the login button!") == "fix-the-login-button")
        #expect(WorktreeManager.slug(from: "!!!") == "change")
        #expect(WorktreeManager.slug(from: "one two three four five six seven").split(separator: "-").count == 5)
    }
}

// MARK: - Outward steps

@Suite(.serialized)
struct OutwardStepRunnerTests {
    struct Setup {
        let sandbox: CodeSandbox
        let remotePath: String
        let clonePath: String
        let baseOID: String
        let reviewOID: String
        let recordPath: String
        let ghPath: String
        let replyPath: String
        let delivery: OutwardDelivery
        let git: HardenedGit
    }

    private func makeSetup(rejectingPush: Bool) async throws -> Setup {
        let sandbox = try CodeSandbox()
        let (remotePath, clonePath, baseOID) = try await sandbox.makeRemoteAndClone()
        if rejectingPush {
            // The hook lives in the temp bare remote, not in any checkout Clicky runs in.
            try sandbox.writeScript("remote.git/hooks/pre-receive", "echo 'denied by test' >&2\nexit 1")
        }
        try "fix\n".write(toFile: clonePath + "/README.md", atomically: true, encoding: .utf8)
        try await sandbox.git(["commit", "--quiet", "-am", "fix"], in: clonePath)
        let reviewOID = try await sandbox.git(["rev-parse", "HEAD"], in: clonePath)
        let recordPath = sandbox.path("gh-calls.log")
        let ghPath = try sandbox.writeScript("fake-gh.sh", "printf '%s\\n' \"$*\" >> '\(recordPath)'\necho '{}'")
        let outboxPath = sandbox.path("outbox")
        try FileManager.default.createDirectory(atPath: outboxPath, withIntermediateDirectories: true)
        let replyPath = outboxPath + "/reply-1.md"
        try "Fixed in this push.".write(toFile: replyPath, atomically: true, encoding: .utf8)
        let delivery = OutwardDelivery(
            repository: GitHubRemote(owner: "o", name: "n"), pullRequestNumber: 1, reviewOID: reviewOID,
            push: .init(repositoryPath: clonePath, remoteURL: remotePath, branch: "main", expectedRemoteOID: baseOID, reviewOID: reviewOID),
            replies: [.init(threadIdentifier: "PRRT_kwDOtest01", bodyFilePath: replyPath)], resolveThreadIdentifiers: ["PRRT_kwDOtest01"])
        return Setup(sandbox: sandbox, remotePath: remotePath, clonePath: clonePath, baseOID: baseOID, reviewOID: reviewOID, recordPath: recordPath,
                     ghPath: ghPath, replyPath: replyPath, delivery: delivery, git: sandbox.hardenedGit(ghPath: ghPath))
    }

    private func stepRunner(_ setup: Setup, key: ApprovalKey) -> CodeOutwardStepRunner {
        CodeOutwardStepRunner(delivery: setup.delivery, git: setup.git, ghPath: setup.ghPath, runner: ChildProcessCommandRunner(),
                              environment: setup.sandbox.gitEnvironment, approvedKey: key, acks: [])
    }

    private func remoteMain(_ setup: Setup) async throws -> String {
        try await setup.sandbox.git(["rev-parse", "main"], in: setup.remotePath)
    }

    @Test func failedPushSendsNoRepliesAndRetryResumes() async throws {
        let setup = try await makeSetup(rejectingPush: true)
        defer { setup.sandbox.cleanUp() }
        let key = try CodeOutwardStepRunner.approvalMaterial(for: setup.delivery, git: setup.git, ghPath: setup.ghPath, acks: []).approvalKey
        let stateURL = setup.sandbox.rootURL.appendingPathComponent("state.json")
        var plan = ExecutionPlan(steps: setup.delivery.stepKinds)
        #expect(plan.steps.map(\.kind) == [.push, .replies, .resolves])

        let outcome = await plan.execute(using: stepRunner(setup, key: key), stateFileURL: stateURL)
        guard case .stopped(let failedStep, let message) = outcome else { Issue.record("expected a stop, got \(outcome)"); return }
        #expect(failedStep == .push)
        #expect(message.contains("rejected"))
        #expect(!FileManager.default.fileExists(atPath: setup.recordPath), "gh must not be called after a failed push")
        #expect(try await remoteMain(setup) == setup.baseOID)
        #expect(try ExecutionPlan.load(from: stateURL).failedStep?.kind == .push)

        // Remote fixed: the retry pushes, then replies, then resolves.
        try FileManager.default.removeItem(atPath: setup.remotePath + "/hooks/pre-receive")
        var retryPlan = try ExecutionPlan.load(from: stateURL)
        retryPlan.prepareForRetry()
        #expect(await retryPlan.execute(using: stepRunner(setup, key: key), stateFileURL: stateURL) == .completed)
        #expect(try await remoteMain(setup) == setup.reviewOID)
        let calls = try String(contentsOfFile: setup.recordPath, encoding: .utf8).split(separator: "\n")
        #expect(calls.count == 2)
        #expect(calls[0].contains("addPullRequestReviewThreadReply") && calls[0].contains("body=@\(setup.replyPath)"))
        #expect(calls[1].contains("resolveReviewThread"))
    }

    @Test func editedBodyAfterApprovalAbortsBeforePush() async throws {
        let setup = try await makeSetup(rejectingPush: false)
        defer { setup.sandbox.cleanUp() }
        let key = try CodeOutwardStepRunner.approvalMaterial(for: setup.delivery, git: setup.git, ghPath: setup.ghPath, acks: []).approvalKey
        try "Fixed in this push!".write(toFile: setup.replyPath, atomically: true, encoding: .utf8)
        var plan = ExecutionPlan(steps: setup.delivery.stepKinds)
        let outcome = await plan.execute(using: stepRunner(setup, key: key))
        #expect(outcome == .stopped(at: .push, message: OutwardStepError.approvalMismatch.description))
        #expect(try await remoteMain(setup) == setup.baseOID)
        #expect(!FileManager.default.fileExists(atPath: setup.recordPath))
    }

    @Test func movedRemoteStopsThePush() async throws {
        let setup = try await makeSetup(rejectingPush: false)
        defer { setup.sandbox.cleanUp() }
        var delivery = setup.delivery
        delivery.push?.expectedRemoteOID = String(repeating: "a", count: 40)
        let key = try CodeOutwardStepRunner.approvalMaterial(for: delivery, git: setup.git, ghPath: setup.ghPath, acks: []).approvalKey
        let runner = CodeOutwardStepRunner(delivery: delivery, git: setup.git, ghPath: setup.ghPath, runner: ChildProcessCommandRunner(),
                                           environment: setup.sandbox.gitEnvironment, approvedKey: key, acks: [])
        await #expect(throws: OutwardStepError.remoteMoved(expected: String(repeating: "a", count: 40), found: setup.baseOID)) { try await runner.run(.push) }
        #expect(try await remoteMain(setup) == setup.baseOID)
    }

    @Test func pushCommandsAreHardenedAndNeverForce() throws {
        let git = HardenedGit(gitPath: "/usr/bin/git", ghPath: "/opt/gh", runner: ChildProcessCommandRunner())
        let delivery = OutwardDelivery(repository: GitHubRemote(owner: "o", name: "n"), pullRequestNumber: 2, reviewOID: "abc",
                                       push: .init(repositoryPath: "/w", remoteURL: "https://github.com/o/n.git", branch: "feat", expectedRemoteOID: "def", reviewOID: "abc"),
                                       commentBodyFilePath: "/outbox/comment.md")
        let commands = CodeOutwardStepRunner.commands(for: delivery, git: git, ghPath: "/opt/gh")
        let pushArgv = try #require(commands.first { $0.arguments.contains("push") }).arguments
        for safety in ["core.fsmonitor=false", "core.hooksPath=/dev/null", "protocol.ext.allow=never", "credential.helper=", "credential.helper=!/opt/gh auth git-credential"] {
            #expect(pushArgv.contains(safety))
        }
        #expect(pushArgv.suffix(5) == ["--porcelain", "--no-verify", "--", "https://github.com/o/n.git", "abc:refs/heads/feat"])
        #expect(!pushArgv.contains("--force") && !pushArgv.contains("-f") && !pushArgv.contains { $0.hasPrefix("+") })
        let commentArgv = try #require(commands.first { $0.gatedAction == .comment }).arguments
        #expect(commentArgv.contains("-R") && commentArgv.contains("--body-file"))
    }

    @Test func porcelainVerdicts() {
        #expect(GitPushPorcelain.parse("To x\n \tabc:refs/heads/a\t1..2\nDone\n").verdict == .ok)
        #expect(GitPushPorcelain.parse("*\tabc:refs/heads/a\t[new branch]\n").verdict == .ok)
        #expect(GitPushPorcelain.parse("!\tabc:refs/heads/a\t[rejected] (fetch first)\n").verdict == .rejected("refs/heads/a: [rejected] (fetch first)"))
        #expect(GitPushPorcelain.parse("+\tabc:refs/heads/a\t1...2 (forced update)\n").verdict == .fatal("forced update of refs/heads/a"))
        #expect(GitPushPorcelain.parse("-\t:refs/heads/a\t[deleted]\n").verdict == .fatal("deletion of refs/heads/a"))
        #expect(GitPushPorcelain.parse("Done\n").verdict == .noRefLine)
    }
}

// MARK: - gh commands

struct GitHubCommandTests {
    let repository = GitHubRemote(owner: "acme", name: "altron-engine")

    @Test func pullRequestCommandsAlwaysNameTheRepo() {
        for argv in [GitHubCommands.pullRequestView(repository, number: 12), GitHubCommands.pullRequestDiff(repository, number: 12),
                     GitHubCommands.pullRequestChecks(repository, number: 12), GitHubCommands.comment(repository, number: 12, bodyFilePath: "/b"),
                     GitHubCommands.review(repository, number: 12, event: .approve, bodyFilePath: "/b"), GitHubCommands.merge(repository, number: 12, method: .squash, headOID: "abc"),
                     GitHubCommands.updateBranch(repository, number: 12), GitHubCommands.openPullRequests(repository, headBranch: "clicky/x")] {
            #expect(argv.firstIndex(of: "-R").map { argv[$0 + 1] } == "acme/altron-engine", "\(argv)")
        }
        let merge = GitHubCommands.merge(repository, number: 12, method: .squash, headOID: "abc")
        #expect(merge.contains("--match-head-commit") && !merge.contains("--delete-branch") && !merge.contains("--admin") && !merge.contains("--auto"))
        #expect(!GitHubCommands.updateBranch(repository, number: 12).contains("--rebase"))
        let reply = GitHubCommands.replyToThread(threadIdentifier: "PRRT_x1", bodyFilePath: "/outbox/reply-1.md")
        #expect(reply.contains("body=@/outbox/reply-1.md"))
    }

    @Test func decodesPullRequestChecksAndThreads() throws {
        let pullRequestJSON = #"{"author":{"login":"someone"},"state":"OPEN","title":"T","url":"u","baseRefName":"main","headRefName":"feat","headRefOid":"abc","headRepository":{"name":"altron-engine"},"headRepositoryOwner":{"login":"forker"},"isCrossRepository":true,"maintainerCanModify":true}"#
        let pullRequest = try GitHubPullRequest.decode(pullRequestJSON)
        #expect(pullRequest.headRemote(base: repository).fullName == "forker/altron-engine")
        #expect(PushPermission.canPush(viewerPermission: "WRITE", viewerLogin: "me", pullRequest: pullRequest, base: repository))
        #expect(!PushPermission.canPush(viewerPermission: "READ", viewerLogin: "me", pullRequest: pullRequest, base: repository))
        #expect(PushPermission.canPush(viewerPermission: "READ", viewerLogin: "forker", pullRequest: pullRequest, base: repository))
        #expect(AgentInvocation.Ownership.forPullRequest(authorLogin: pullRequest.author?.login, viewerLogin: "me") == .external)

        let checks = GitHubChecks.parse(#"[{"name":"build","state":"FAILURE","bucket":"fail","link":"https://github.com/acme/altron-engine/actions/runs/987/job/1"},{"name":"lint","bucket":"pass"}]"#)
        #expect(checks.summary == .failed(["build"]))
        #expect(checks.failedRunIdentifiers == ["987"])
        #expect(GitHubChecks.parse(#"[{"name":"a","bucket":"pending"}]"#).summary == .pending(1))

        let threads = GitHubReviewThread.parse(graphQLResponse: #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_1","isResolved":false,"isOutdated":false,"path":"a.swift","line":3,"comments":{"nodes":[{"author":{"login":"rev"},"body":"rename this"}]}}]}}}}}"#)
        #expect(threads.first?.identifier == "PRRT_1" && threads.first?.comments.first?.body == "rename this")
        #expect(GitHubReviewThread.contextMarkdown(threads).contains("untrusted"))
    }

    @Test func refusesUnsafeNamesAndIDs() {
        #expect(GitHubCommands.isSafeBranchName("feature/login-fix"))
        for bad in ["-x", "a..b", "a:b", "+main", "a b", "a/", "x.lock", "@{u}"] { #expect(!GitHubCommands.isSafeBranchName(bad), "\(bad)") }
        #expect(GitHubCommands.isValidNodeIdentifier("PRRT_kwDOAbc123"))
        #expect(!GitHubCommands.isValidNodeIdentifier("x\" } mutation {"))
    }
}

// MARK: - Preflight

@Suite(.serialized)
struct CodePreflightTests {
    enum ProbePlugins { case none, switchable, sticky }

    /// `.switchable`: the probe reports helper@market unless --settings switches it off
    /// (like a real plugin); `.sticky`: it's reported whatever the settings say.
    private func fakeTools(_ sandbox: CodeSandbox, ghAuthExit: Int = 0, probePlugins: ProbePlugins = .none) throws -> CodeToolPaths {
        try claudeHelpFixture.write(toFile: sandbox.path("help.txt"), atomically: true, encoding: .utf8)
        let probeLog = sandbox.path("probe-args.log")
        let pluginLine: String
        switch probePlugins {
        case .none: pluginLine = #"plugins='[]'"#
        case .sticky: pluginLine = #"plugins='[{"name":"helper","source":"helper@market"}]'"#
        case .switchable: pluginLine = #"case "$*" in *'"helper@market":false'*) plugins='[]' ;; *) plugins='[{"name":"helper","source":"helper@market"}]' ;; esac"#
        }
        let claudePath = try sandbox.writeScript("fake-claude.sh", """
            case "$1" in
              --help) cat '\(sandbox.path("help.txt"))' ;;
              auth) exit 0 ;;
              -p) printf '%s\\n' "$*" >> '\(probeLog)'
                  \(pluginLine)
                  printf '%s\\n' '{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"plugins":'"$plugins"',"apiKeySource":"none","cwd":"/x"}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"OK"}' ;;
            esac
            """)
        let ghPath = try sandbox.writeScript("fake-gh.sh", """
            case "$1 $2" in
              "auth status") exit \(ghAuthExit) ;;
              "api user") echo tester ;;
            esac
            """)
        return CodeToolPaths(git: "/usr/bin/git", gh: ghPath, claude: claudePath)
    }

    @Test func readyWhenEverythingPasses() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let report = await CodePreflight(tools: try fakeTools(sandbox), runner: ChildProcessCommandRunner(), environment: testBaseEnvironment, probeWorkingDirectory: sandbox.root).run()
        #expect(report.isReady, "\(report.statusLine)")
        #expect(report.viewerLogin == "tester")
        #expect(report.apiKeySource == "none")
        #expect(report.effectiveSupportedFlags.contains("--max-turns"))
        #expect(report.droppedOptionalFlags.isEmpty)
        #expect(report.flagTable.contains("--append-system-prompt-file"))
        #expect(report.disabledPluginSources == AgentInvocation.builtinPluginSources)
        #expect(report.spokenExplanation == "Code mode is ready.")
        // One probe, with the agent's isolation (no settings files, skills off).
        let probeLines = try String(contentsOfFile: sandbox.path("probe-args.log"), encoding: .utf8).split(separator: "\n")
        #expect(probeLines.count == 1)
        #expect(probeLines.first?.contains("--disable-slash-commands") == true && probeLines.first?.contains("cc-plugin-telemetry@builtin") == true)
    }

    /// A plugin the probe sees is switched off and the probe re-run; the agent gets the same list.
    @Test func switchesOffAPluginTheProbeSaw() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let report = await CodePreflight(tools: try fakeTools(sandbox, probePlugins: .switchable), runner: ChildProcessCommandRunner(), environment: testBaseEnvironment,
                                         probeWorkingDirectory: sandbox.root).run()
        #expect(report.isReady, "\(report.statusLine)")
        #expect(report.disabledPluginSources == AgentInvocation.builtinPluginSources + ["helper@market"])
        let probeLines = try String(contentsOfFile: sandbox.path("probe-args.log"), encoding: .utf8).split(separator: "\n")
        #expect(probeLines.count == 2)
    }

    @Test func failsWithAReason() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let ghSignedOut = await CodePreflight(tools: try fakeTools(sandbox, ghAuthExit: 1), runner: ChildProcessCommandRunner(), environment: testBaseEnvironment,
                                              probeWorkingDirectory: sandbox.root).run()
        #expect(!ghSignedOut.isReady && ghSignedOut.statusLine.contains("gh auth status"))
        #expect(ghSignedOut.spokenExplanation.contains("gh auth login"))
        // A plugin that loads even when switched off: off, with what to do.
        let withPlugins = await CodePreflight(tools: try fakeTools(sandbox, probePlugins: .sticky), runner: ChildProcessCommandRunner(), environment: testBaseEnvironment,
                                              probeWorkingDirectory: sandbox.root).run()
        #expect(!withPlugins.isReady && withPlugins.statusLine.contains("plugins (helper)"))
        #expect(withPlugins.remedy?.contains("claude update") == true)
        #expect(withPlugins.spokenExplanation.hasPrefix("Code mode can't run: Claude Code still loads plugins (helper)"))
        #expect(withPlugins.spokenExplanation.hasSuffix("turn code mode off and on again to recheck."))
        #expect(CodePreflight.spokenList(["a", "b", "c", "d"]) == "a, b, c and 1 more" && CodePreflight.spokenList(["a", "b"]) == "a and b")
    }

    @Test func probeEnvironmentStripsKeys() {
        let probeEnvironment = CodePreflight.probeEnvironment(base: ["ANTHROPIC_API_KEY": "k", "GH_TOKEN": "t", "PATH": "/bin"])
        #expect(probeEnvironment["ANTHROPIC_API_KEY"] == nil && probeEnvironment["GH_TOKEN"] == nil && probeEnvironment["PATH"] == "/bin")
        #expect(probeEnvironment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] == "1")
        #expect(AgentInvocation.forbiddenTokens(in: ClaudeArgs.preflightProbeArguments).isEmpty)
    }
}

// MARK: - Whole flows with fake CLIs

@Suite(.serialized)
struct CodeTaskEngineTests {
    private func makeEngine(_ sandbox: CodeSandbox, agentEnvironment: [String: String]) throws -> CodeTaskEngine {
        let claudePath = try sandbox.writeScript("fake-claude.sh", fakeAgentScriptBody)
        let ghPath = try sandbox.writeScript("fake-gh.sh", """
            printf '%s\\n' "$*" >> '\(sandbox.path("gh-calls.log"))'
            case "$1 $2" in
              "repo view") echo '{"viewerPermission":"ADMIN","defaultBranchRef":{"name":"main"}}' ;;
            esac
            """)
        let preflight = CodePreflightReport(isReady: true, failureReason: nil, effectiveSupportedFlags: Array(allFlags()), droppedOptionalFlags: [], flagTable: "",
                                            viewerLogin: "tester", unremovableTools: [], apiKeySource: "none", date: Date())
        return CodeTaskEngine(tools: CodeToolPaths(git: "/usr/bin/git", gh: ghPath, claude: claudePath), preflight: preflight, runner: ChildProcessCommandRunner(),
                              environment: sandbox.gitEnvironment, agentBaseEnvironment: sandbox.gitEnvironment.merging(agentEnvironment) { $1 },
                              workspaceRootURL: sandbox.rootURL.appendingPathComponent("code"), worktreesRootURL: sandbox.rootURL.appendingPathComponent("worktrees"),
                              isBashAllowed: false, agentTimeouts: .total(60))
    }

    @Test func askRepoAnswersReadOnlyFromTheClone() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let (_, clonePath, baseOID) = try await sandbox.makeRemoteAndClone(cloneName: "clicky")
        let engine = try makeEngine(sandbox, agentEnvironment: ["FAKE_SUMMARY": "It runs the helper workers."])
        let task = try CodeTask.decode(blockBody: #"{"action":"ask_repo","repo":"clicky","instructions":"what does CompanionWorkers do?"}"#)
        let preparation = try await engine.prepare(task, repository: ResolvedRepository(remote: GitHubRemote(owner: "tester", name: "clicky"), clonePath: clonePath))
        guard case .spoken(let answer, let report) = preparation else { Issue.record("expected a spoken answer"); return }
        #expect(answer == "It runs the helper workers.")
        #expect(report?.outcome.isSuccess == true)
        // Nothing changed in the clone, and no worktree was made.
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: clonePath) == baseOID)
        #expect(try await sandbox.git(["status", "--porcelain"], in: clonePath).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.path("worktrees")))
    }

    @Test func repoChangeBuildsAReviewAndAppliesLocally() async throws {
        let sandbox = try CodeSandbox()
        defer { sandbox.cleanUp() }
        let (_, clonePath, baseOID) = try await sandbox.makeRemoteAndClone(cloneName: "altron-engine")
        let engine = try makeEngine(sandbox, agentEnvironment: ["FAKE_EDIT": "1", "FAKE_SUMMARY": "I added a line."])
        let task = try CodeTask.decode(blockBody: #"{"action":"repo_change","repo":"altron engine","instructions":"add a line to the readme","deliver":"pr","base":"main"}"#)
        let preparation = try await engine.prepare(task, repository: ResolvedRepository(remote: GitHubRemote(owner: "tester", name: "altron-engine"), clonePath: clonePath))
        guard case .review(let review) = preparation else { Issue.record("expected a review"); return }
        #expect(review.content.summary == "I added a line.")
        #expect(review.content.diffFiles.map(\.displayPath) == ["README.md"])
        #expect(review.content.diffFiles.first?.addedLines.map(\.text) == ["added by agent"])
        #expect(review.content.buttons.map(\.id) == ["keep", "apply", "push", "pr"])
        #expect(review.content.buttons.first { $0.isPrimary }?.id == "pr")
        #expect(review.content.findings.isEmpty)
        #expect(review.workspace.readOutboxFile("commit-msg.txt") == "Add a README line")
        let worktree = try #require(review.worktree)
        #expect(worktree.path.hasPrefix(sandbox.path("worktrees")))
        // The agent's edit is in the worktree, not the clone.
        #expect(try String(contentsOfFile: clonePath + "/README.md", encoding: .utf8) == "hello\n")
        let prButton = try #require(review.content.buttons.first { $0.id == "pr" })
        #expect(prButton.commands.contains { $0.arguments.contains("create") && $0.arguments.contains("--body-file") })
        #expect(prButton.commands.allSatisfy { AgentInvocation.forbiddenTokens(in: $0.argv).isEmpty && !$0.arguments.contains("--force") })

        // "Merge into main": a click-approved ff-only merge in the clean clone.
        let applyAction = try #require(review.actionsByButtonID["apply"])
        let material = try #require(try engine.approvalMaterial(for: applyAction, reviewOID: review.reviewOID, acks: []))
        let result = await engine.execute(applyAction, approvedKey: material.approvalKey, reviewOID: review.reviewOID, acks: [], workspace: review.workspace)
        #expect(result.succeeded, "\(result.message)")
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: clonePath) == review.reviewOID)
        #expect(try await sandbox.git(["rev-parse", "HEAD~1"], in: clonePath) == baseOID)
        // A stale key is refused.
        let staleResult = await engine.execute(applyAction, approvedKey: ApprovalKey(hexDigest: "00"), reviewOID: review.reviewOID, acks: [], workspace: review.workspace)
        #expect(!staleResult.succeeded)
    }
}

// MARK: - Gate mapping, review model, prompt, router

@MainActor
struct CodeReviewUITests {
    @Test func realMouseEventsMapAndTaggedOnesAreRefused() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let mouseDown = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: now, windowNumber: 42, context: nil,
                                                        eventNumber: 1, clickCount: 1, pressure: 1))
        let mouseUp = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: now + 0.1, windowNumber: 42, context: nil,
                                                      eventNumber: 2, clickCount: 1, pressure: 0))
        let downInput = try #require(GateEventMapping.gateInput(from: mouseDown, panelShownAt: now - 2, isAppActive: true, isOnTargetButton: true))
        #expect(downInput.kind == .mouseDown && downInput.windowNumber == 42 && downInput.eventSourceUserData == 0)

        var pushGate = ClickGateLogic(action: .push, panelWindowNumber: 42)
        #expect(pushGate.handle(downInput) == .pressStarted)
        #expect(pushGate.handle(try #require(GateEventMapping.gateInput(from: mouseUp, panelShownAt: now - 2, isAppActive: true, isOnTargetButton: true))) == .approved)

        var otherWindowGate = ClickGateLogic(action: .push, panelWindowNumber: 7)
        #expect(otherWindowGate.handle(downInput) == .rejected(.wrongWindow))

        // A click Clicky synthesized itself carries the tag and is refused.
        let syntheticCGEvent = try #require(SyntheticEvents.mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10)))
        #expect(syntheticCGEvent.getIntegerValueField(.eventSourceUserData) == SyntheticEventTag.value)
        let syntheticEvent = try #require(NSEvent(cgEvent: syntheticCGEvent))
        let syntheticInput = try #require(GateEventMapping.gateInput(from: syntheticEvent, panelShownAt: 0, isAppActive: true, isOnTargetButton: true))
        var gate = ClickGateLogic(action: .push, panelWindowNumber: syntheticInput.windowNumber)
        #expect(gate.handle(syntheticInput) == .rejected(.syntheticEvent))
        #expect(SyntheticEvents.keyEvent(virtualKey: 36, keyDown: true)?.getIntegerValueField(.eventSourceUserData) == SyntheticEventTag.value)

        // Return only arms; other keys are ignored; moves aren't gate input.
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: now, windowNumber: 42, context: nil,
                                                      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        var returnGate = ClickGateLogic(action: .push, panelWindowNumber: 42)
        guard case .armed = returnGate.handle(try #require(GateEventMapping.gateInput(from: returnKey, panelShownAt: 0, isAppActive: true, isOnTargetButton: false))) else {
            Issue.record("Return must only arm"); return
        }
        let otherKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: now, windowNumber: 42, context: nil,
                                                     characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(returnGate.handle(try #require(GateEventMapping.gateInput(from: otherKey, panelShownAt: 0, isAppActive: true, isOnTargetButton: true))) == .rejected(.keyIgnored))
        let move = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: now, windowNumber: 42, context: nil, eventNumber: 3, clickCount: 0, pressure: 0))
        #expect(GateEventMapping.gateInput(from: move, panelShownAt: 0, isAppActive: true, isOnTargetButton: true) == nil)

        // A short press on a hold action is refused.
        var mergeGate = ClickGateLogic(action: .merge, panelWindowNumber: 42)
        _ = mergeGate.handle(downInput)
        #expect(mergeGate.handle(try #require(GateEventMapping.gateInput(from: mouseUp, panelShownAt: now - 2, isAppActive: true, isOnTargetButton: true))) == .rejected(.holdTooShort(heldFor: mouseUp.timestamp - mouseDown.timestamp)))
    }

    @Test func approveBlockers() {
        let ackable = CodeGuardFinding(kind: .sensitivePath, source: .diff, file: "package.json", line: nil, isAckable: true, message: "pkg")
        let red = CodeGuardFinding(kind: .workflowChange, source: .diff, file: ".github/workflows/ci.yml", line: nil, isAckable: false, message: "wf")
        var conditions = ReviewApproveConditions(isAgentProcessGroupReaped: true, leftoverProcessIdentifiers: [], pushDryRunSucceeded: true, findings: [ackable], acks: [])
        #expect(conditions.blockers == ["1 finding needs your ack"])
        conditions.acks = ["sensitive-path:package.json"]
        #expect(conditions.blockers.isEmpty)
        conditions.findings.append(red)
        #expect(conditions.blockers == ["1 red finding can't be sent"])
        conditions = ReviewApproveConditions(isAgentProcessGroupReaped: false, leftoverProcessIdentifiers: [123], pushDryRunSucceeded: false, pushDryRunMessage: "denied", findings: [], acks: [])
        #expect(conditions.blockers.count == 3)
    }

    @Test func codeSectionIsGatedAndDropsCantLookUp() {
        let withCode = SystemPromptBuilder.mainSystemPrompt(features: SystemPromptFeatures.current.union(.code), sectionTexts: [.code: CodeModePrompt.sectionText])
        #expect(withCode.contains("<codetask>"))
        #expect(withCode.contains("ask_repo") && withCode.contains("repo_change") && withCode.contains("deliver"))
        #expect(!withCode.contains("can't look that up yet"))
        #expect(!withCode.contains("run coding tasks"))
        let codeOff = SystemPromptBuilder.mainSystemPrompt(features: .current, sectionTexts: [.code: CodeModePrompt.sectionText])
        #expect(!codeOff.contains("<codetask>") && codeOff.contains("can't look that up yet"))
        // The example block in the prompt decodes with the strict decoder.
        let exampleStart = CodeModePrompt.sectionText.range(of: "<codetask>")!.upperBound
        let exampleEnd = CodeModePrompt.sectionText.range(of: "</codetask>")!.lowerBound
        #expect((try? CodeTask.decode(blockBody: String(CodeModePrompt.sectionText[exampleStart..<exampleEnd])))?.action == .fixReview)
    }

    @Test func routerHandsCodetaskToItsConsumerOnly() {
        #expect(ResponseRouter.blockNames.contains("code") && ResponseRouter.blockNames.contains("codetask"))
        let answer = "on it. <codetask>{\"action\":\"ask_repo\",\"repo\":\"clicky\",\"instructions\":\"x\"}</codetask> done"
        var consuming = ResponseRouter(blockConsumers: ["codetask"])
        var outputs: [ResponseRouterOutput] = []
        for character in answer { outputs += consuming.feed(String(character)) }
        outputs += consuming.finish()
        #expect(outputs.contains(.block(name: "codetask", body: "{\"action\":\"ask_repo\",\"repo\":\"clicky\",\"instructions\":\"x\"}")))
        var notConsuming = ResponseRouter(blockConsumers: [])
        let plainOutputs = notConsuming.feed(answer) + notConsuming.finish()
        #expect(plainOutputs.contains(.unsupportedBlock(name: "codetask")))
        // <code> is still its own block.
        var codeRouter = ResponseRouter(blockConsumers: ["code"])
        #expect((codeRouter.feed("<code>let x = 1</code> ") + codeRouter.finish()).contains(.block(name: "code", body: "let x = 1")))
    }

    /// Offscreen render (no window) to ~/Library/Logs/Clicky/renders/p5/.
    @Test func rendersReviewPanelOffscreen() throws {
        let diff = """
            diff --git a/Sources/Engine.swift b/Sources/Engine.swift
            index 1111111..2222222 100644
            --- a/Sources/Engine.swift
            +++ b/Sources/Engine.swift
            @@ -10,4 +10,5 @@ final class Engine {
                 func start() {
            -        loadConfig()
            +        try loadConfig(strict: true)
            +        log("started")
                 }
            diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
            index 3333333..4444444 100644
            --- a/.github/workflows/ci.yml
            +++ b/.github/workflows/ci.yml
            @@ -1,2 +1,2 @@
            -name: CI
            +name: CI (fast)
            """
        let git = HardenedGit(gitPath: "/usr/bin/git", ghPath: "/opt/homebrew/bin/gh", runner: ChildProcessCommandRunner())
        let delivery = OutwardDelivery(repository: GitHubRemote(owner: "acme", name: "altron-engine"), pullRequestNumber: 12, reviewOID: "2222222222",
                                       push: .init(repositoryPath: "~/.clicky/worktrees/acme__altron-engine/pr-12", remoteURL: "https://github.com/acme/altron-engine.git",
                                                   branch: "feat/strict-config", expectedRemoteOID: "1111111111", reviewOID: "2222222222"),
                                       replies: [.init(threadIdentifier: "PRRT_kwDOA1", bodyFilePath: "~/.clicky/code/t/outbox/reply-1.md")], resolveThreadIdentifiers: ["PRRT_kwDOA1"])
        let findings = CodeGuards.scan(diffText: diff, commitMessage: "Use strict config loading")
        let content = CodeReviewContent(
            repositoryFullName: "acme/altron-engine", pullRequestNumber: 12, branch: "clicky/pr-12 → acme/altron-engine:feat/strict-config",
            oldOID: "1111111111", newOID: "2222222222", ciStatus: "failing: build", summary: "I made config loading strict and replied to the review thread.",
            notes: ["Tests: swift test (not run: no shell)"], diffFiles: DiffParser.parse(diff),
            editableTexts: [.init(fileName: "commit-msg.txt", label: "Commit message", text: "Use strict config loading"),
                            .init(fileName: "reply-1.md", label: "Reply on Sources/Engine.swift (and resolve)", text: "Done — loading is strict now.")],
            buttons: [.init(id: "push", title: "Push & reply (1)", gatedAction: .push, commands: CodeOutwardStepRunner.commands(for: delivery, git: git, ghPath: "/opt/homebrew/bin/gh"), isPrimary: true),
                      .init(id: "keep", title: "Keep local", gatedAction: .apply, commands: [], isOutward: false)],
            findings: findings,
            approveBlockers: ReviewApproveConditions(isAgentProcessGroupReaped: true, leftoverProcessIdentifiers: [], pushDryRunSucceeded: true, findings: findings, acks: []).blockers)
        let state = ReviewPanelState(mode: .review, content: content)
        let renderer = ImageRenderer(content: ReviewPanelView(state: state, usesStaticButtons: true).frame(width: 760, height: 980))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width >= 700)
        let outputDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/renders/p5", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: outputDirectory.appendingPathComponent("review-panel.png"))
        }
        #expect(content.approveBlockers == ["1 red finding can't be sent"])

        let chooser = ReviewPanelState(mode: .chooser(title: "Which altron?", candidates: [RepoCandidate(fullName: "acme/altron-engine", folderPath: "/Users/me/Projects/altron-engine", score: 0.92, source: .localOrigin),
                                                                                       RepoCandidate(fullName: "acme/altron-web", folderPath: nil, score: 0.9, source: .githubAccount)]),
                                       content: content)
        let chooserImage = try #require(ImageRenderer(content: ReviewPanelView(state: chooser, usesStaticButtons: true)).nsImage)
        #expect(chooserImage.size.height > 50)

        // "Opening": the repo name big, the full path (never ~-abbreviated) below it, the countdown.
        let card = OpeningCard(repositoryName: "clicky-scratch", path: "/Users/me/Projects/clicky-scratch/", pullRequestNumber: nil, secondsRemaining: 2)
        #expect(card.titleText == "clicky-scratch" && card.pathText == "/Users/me/Projects/clicky-scratch")
        #expect(OpeningCard(repositoryName: "acme/app", path: nil, pullRequestNumber: 12).titleText == "acme/app #12")
        #expect(OpeningCard(repositoryName: "acme/app", path: nil).pathText.contains("GitHub only"))
        let opening = ReviewPanelState(mode: .opening(card), content: content)
        let openingRenderer = ImageRenderer(content: ReviewPanelView(state: opening, usesStaticButtons: true))
        openingRenderer.scale = 2
        let openingImage = try #require(openingRenderer.nsImage)
        #expect(openingImage.size.width >= 500 && openingImage.size.height > 120)
        if let tiff = openingImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: outputDirectory.appendingPathComponent("opening-card.png"))
        }
    }
}
