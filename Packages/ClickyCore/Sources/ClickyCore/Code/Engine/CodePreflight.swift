//
//  CodePreflight.swift
//  ClickyCore
//
//  Decides once per launch whether Code mode can run at all: `claude
//  --help` must list every required agent flag (hidden ones are proven by
//  the probe; dropped optional flags are recorded), `claude auth status` and
//  `gh auth status` must exit 0, the viewer login must be known, and one
//  probe turn with no tools must start and finish cleanly. The probe's
//  system/init gives the tools that can't be removed and the apiKeySource
//  every agent init is later checked against. Any failure turns Code mode
//  off with a sentence saying why.
//

import Foundation

public struct CodePreflightReport: Codable, Equatable, Sendable {
    public var isReady: Bool
    public var failureReason: String?
    public var effectiveSupportedFlags: [String]
    public var droppedOptionalFlags: [String]
    public var flagTable: String
    public var viewerLogin: String?
    public var unremovableTools: [String]
    public var apiKeySource: String?
    public var date: Date

    /// One line for the panel's settings row.
    public var statusLine: String {
        if isReady {
            let droppedNote = droppedOptionalFlags.isEmpty ? "" : " · without \(droppedOptionalFlags.joined(separator: ", "))"
            return "Ready as @\(viewerLogin ?? "?")\(droppedNote)"
        }
        return "Off: \(failureReason ?? "preflight failed")"
    }

    public static func failed(_ reason: String, flagReport: AgentFlagReport? = nil) -> CodePreflightReport {
        CodePreflightReport(isReady: false, failureReason: reason, effectiveSupportedFlags: flagReport.map { Array($0.effectiveSupportedFlags).sorted() } ?? [],
                            droppedOptionalFlags: flagReport?.droppedOptionalFlags ?? [], flagTable: flagReport?.tableText ?? "",
                            viewerLogin: nil, unremovableTools: [], apiKeySource: nil, date: Date())
    }
}

/// What the probe's stream showed.
public struct PreflightProbeResult: Equatable, Sendable {
    public var unremovableTools: [String]
    public var apiKeySource: String?
    public var mcpServerNames: [String]
    public var pluginNames: [String]
    public var sawInit: Bool
    public var succeeded: Bool
    public var resultText: String?

    public static func parse(streamJSON: String) -> PreflightProbeResult {
        var probeResult = PreflightProbeResult(unremovableTools: [], apiKeySource: nil, mcpServerNames: [], pluginNames: [], sawInit: false, succeeded: false, resultText: nil)
        for line in streamJSON.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let eventType = event["type"] as? String else { continue }
            if eventType == "system", event["subtype"] as? String == "init", !probeResult.sawInit {
                probeResult.sawInit = true
                probeResult.unremovableTools = (event["tools"] as? [String] ?? []).sorted()
                probeResult.apiKeySource = event["apiKeySource"] as? String
                probeResult.mcpServerNames = AgentInitValidator.namedEntries(event["mcp_servers"])
                probeResult.pluginNames = AgentInitValidator.namedEntries(event["plugins"])
            } else if eventType == "result" {
                probeResult.resultText = event["result"] as? String
                probeResult.succeeded = event["is_error"] as? Bool != true && (event["subtype"] as? String ?? "success") == "success"
            }
        }
        return probeResult
    }
}

public struct CodePreflight: Sendable {
    public static let probeTimeoutSeconds: TimeInterval = 120

    public var tools: CodeToolPaths
    public var runner: CodeCommandRunning
    public var environment: [String: String]
    public var probeWorkingDirectory: String

    public init(tools: CodeToolPaths, runner: CodeCommandRunning, environment: [String: String] = CodeCommandEnvironment.forClickyCommands(), probeWorkingDirectory: String) {
        self.tools = tools
        self.runner = runner
        self.environment = environment
        self.probeWorkingDirectory = probeWorkingDirectory
    }

    /// The probe's environment matches the agent's: no ANTHROPIC_*, no tokens, no CLAUDE.md.
    public static func probeEnvironment(base baseEnvironment: [String: String]) -> [String: String] {
        var probeEnvironment = baseEnvironment.filter { key, _ in
            !key.hasPrefix("ANTHROPIC_") && !["GH_TOKEN", "GITHUB_TOKEN", "SSH_AUTH_SOCK"].contains(key)
        }
        probeEnvironment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
        return probeEnvironment
    }

    public func run() async -> CodePreflightReport {
        // 1. Flags.
        guard let helpOutput = try? await runner.run(executable: tools.claude, arguments: ["--help"], workingDirectory: probeWorkingDirectory,
                                                      environment: environment, timeoutSeconds: 30), helpOutput.succeeded else {
            return .failed("claude --help didn't run")
        }
        let helpFlags = ClaudeHelpParser.supportedFlags(fromHelpText: helpOutput.standardOutput)
        let helpOnlyReport = AgentFlagSupport.evaluate(helpFlags: helpFlags)
        let missingBeforeProbe = helpOnlyReport.rows.filter { $0.status == .missingRequired }.map(\.flag)
        guard missingBeforeProbe.isEmpty else {
            return .failed("this Claude Code lacks \(missingBeforeProbe.joined(separator: ", "))", flagReport: helpOnlyReport)
        }

        // 2. Signed in to both.
        guard let claudeAuth = try? await runner.run(executable: tools.claude, arguments: ["auth", "status"], workingDirectory: probeWorkingDirectory,
                                                      environment: environment, timeoutSeconds: 30), claudeAuth.succeeded else {
            return .failed("Claude Code isn't signed in (claude auth status)", flagReport: helpOnlyReport)
        }
        guard let githubAuth = try? await runner.run(executable: tools.gh, arguments: ["auth", "status"], workingDirectory: probeWorkingDirectory,
                                                      environment: environment, timeoutSeconds: 30), githubAuth.succeeded else {
            return .failed("GitHub CLI isn't signed in (gh auth status)", flagReport: helpOnlyReport)
        }
        guard let viewerOutput = try? await runner.run(executable: tools.gh, arguments: GitHubCommands.viewerLogin(), workingDirectory: probeWorkingDirectory,
                                                        environment: environment, timeoutSeconds: 30), viewerOutput.succeeded,
              !viewerOutput.trimmedOutput.isEmpty, !viewerOutput.trimmedOutput.contains(" ") else {
            return .failed("couldn't read your GitHub login", flagReport: helpOnlyReport)
        }
        let viewerLogin = viewerOutput.trimmedOutput

        // 3. One probe turn.
        guard let probeOutput = try? await runner.run(executable: tools.claude, arguments: ClaudeArgs.preflightProbeArguments, workingDirectory: probeWorkingDirectory,
                                                       environment: Self.probeEnvironment(base: environment), timeoutSeconds: Self.probeTimeoutSeconds) else {
            return .failed("the probe run didn't start", flagReport: helpOnlyReport)
        }
        let probeResult = PreflightProbeResult.parse(streamJSON: probeOutput.standardOutput)
        guard probeOutput.succeeded, probeResult.sawInit, probeResult.succeeded else {
            return .failed("the probe run failed (\(probeOutput.shortError))", flagReport: helpOnlyReport)
        }
        guard probeResult.mcpServerNames.isEmpty else {
            return .failed("MCP servers load even with --strict-mcp-config: \(probeResult.mcpServerNames.joined(separator: ", "))", flagReport: helpOnlyReport)
        }
        guard probeResult.pluginNames.isEmpty else {
            return .failed("plugins load in headless runs (\(probeResult.pluginNames.prefix(3).joined(separator: ", "))), so the agent's init would be rejected", flagReport: helpOnlyReport)
        }

        let probeVerifiedFlags = AgentFlagSupport.probeVerifiableFlags.filter { ClaudeArgs.preflightProbeArguments.contains($0) }
        let flagReport = AgentFlagSupport.evaluate(helpFlags: helpFlags, probeVerifiedFlags: probeVerifiedFlags)
        guard flagReport.isUsable else {
            return .failed("this Claude Code lacks \(flagReport.missingRequiredFlags.joined(separator: ", "))", flagReport: flagReport)
        }
        return CodePreflightReport(isReady: true, failureReason: nil, effectiveSupportedFlags: Array(flagReport.effectiveSupportedFlags).sorted(),
                                   droppedOptionalFlags: flagReport.droppedOptionalFlags, flagTable: flagReport.tableText, viewerLogin: viewerLogin,
                                   unremovableTools: probeResult.unremovableTools, apiKeySource: probeResult.apiKeySource ?? "none", date: Date())
    }
}
