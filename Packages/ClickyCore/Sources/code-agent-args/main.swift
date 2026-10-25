//
//  main.swift (code-agent-args)
//
//  Prints exactly what Clicky would pass to the Code-mode agent, as JSON,
//  so Tools/codeprobe.sh exercises the real rules instead of a copy:
//    swift run code-agent-args --ctx DIR --outbox DIR --empty-gh DIR [--bash] [--help-text FILE] [--prompt TEXT]
//  Output: {"arguments": [...], "environmentOverrides": {...},
//  "strippedEnvironmentKeys": [...], "settings": {...}, "droppedFlags": [...],
//  "allow": [...], "deny": [...]}. `--help-text` is `claude --help` output;
//  flags it doesn't list are dropped or replaced like the preflight does
//  (--max-turns counts as probe-verified, as the app's preflight verifies it).
//  Nothing runs here.
//

import ClickyCore
import Foundation

var options: [String: String] = [:]
var includesBash = false
var argumentIterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = argumentIterator.next() {
    switch argument {
    case "--bash": includesBash = true
    case "--ctx", "--outbox", "--empty-gh", "--help-text", "--prompt":
        guard let value = argumentIterator.next() else {
            FileHandle.standardError.write(Data("code-agent-args: \(argument) needs a value\n".utf8))
            exit(64)
        }
        options[argument] = value
    default:
        FileHandle.standardError.write(Data("code-agent-args: unknown argument \(argument)\n".utf8))
        exit(64)
    }
}
guard let contextPath = options["--ctx"], let outboxPath = options["--outbox"], let emptyGHPath = options["--empty-gh"] else {
    FileHandle.standardError.write(Data("usage: code-agent-args --ctx DIR --outbox DIR --empty-gh DIR [--bash] [--help-text FILE] [--prompt TEXT]\n".utf8))
    exit(64)
}

let invocation = AgentInvocation(prompt: options["--prompt"] ?? "Probe", contextDirectoryPath: contextPath, outboxDirectoryPath: outboxPath,
                                 emptyGHConfigDirectoryPath: emptyGHPath, ownership: .own, isReadOnly: false, bashAllowed: includesBash,
                                 session: .new(identifier: UUID().uuidString.lowercased()))
var argv = invocation.arguments
var droppedFlags: [String] = []
if let helpPath = options["--help-text"], let helpText = try? String(contentsOfFile: helpPath, encoding: .utf8) {
    let report = AgentFlagSupport.evaluate(helpFlags: ClaudeHelpParser.supportedFlags(fromHelpText: helpText), probeVerifiedFlags: AgentFlagSupport.probeVerifiableFlags)
    let filtered = invocation.arguments(supportedFlags: report.effectiveSupportedFlags)
    argv = filtered.arguments
    droppedFlags = filtered.droppedFlags
}

let output: [String: Any] = [
    "arguments": argv,
    "droppedFlags": droppedFlags,
    "environmentOverrides": invocation.environmentOverrides,
    "strippedEnvironmentKeys": ["GH_TOKEN", "GITHUB_TOKEN", "SSH_AUTH_SOCK", "ANTHROPIC_*"],
    "settings": invocation.settingsObject,
    "allow": invocation.allowedPermissionRules,
    "deny": invocation.deniedPermissionRules,
    "tools": invocation.tools,
    "settingSources": invocation.settingSources
]
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
