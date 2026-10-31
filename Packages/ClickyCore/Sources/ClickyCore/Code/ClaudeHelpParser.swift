//
//  ClaudeHelpParser.swift
//  ClickyCore
//
//  Reads `claude --help` and says which of the agent's flags the installed
//  CLI knows. Only option lines count (exactly two spaces, then "-"), so a
//  flag named inside another option's description ("…or
//  --permission-prompt-tool") is never mistaken for a supported one. Some
//  flags work but are hidden from --help (e.g. --max-turns): they count as
//  supported only after the preflight probe ran with them and succeeded.
//  --append-system-prompt-file falls back to --append-system-prompt with
//  rules.md inline when only the inline form is listed.
//

import Foundation

public enum ClaudeHelpParser {
    /// Every flag spelling on an option line: "-p, --print" → ["-p", "--print"].
    public static func supportedFlags(fromHelpText helpText: String) -> Set<String> {
        var flags = Set<String>()
        for rawLine in helpText.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            guard line.hasPrefix("  -"), !line.hasPrefix("   ") else { continue }
            // The option part ends at the first run of two spaces (where the description starts).
            let optionPart: Substring
            if let descriptionGap = line.dropFirst(2).range(of: "  ") {
                optionPart = line[line.index(line.startIndex, offsetBy: 2)..<descriptionGap.lowerBound]
            } else {
                optionPart = line.dropFirst(2)
            }
            for token in optionPart.split(whereSeparator: { $0 == "," || $0 == " " }) {
                var flag = String(token)
                if let equalsIndex = flag.firstIndex(of: "=") { flag = String(flag[..<equalsIndex]) }
                if isFlagSpelling(flag) { flags.insert(flag) }
            }
        }
        return flags
    }

    static func isFlagSpelling(_ token: String) -> Bool {
        token.range(of: #"^--?[A-Za-z][A-Za-z0-9-]*$"#, options: .regularExpression) != nil
    }
}

/// How each of the agent's flags fares against one installed CLI.
public struct AgentFlagReport: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        /// Listed in --help.
        case kept
        /// Hidden from --help, accepted by the preflight probe.
        case probeVerified
        /// Hidden from --help and not (yet) verified by a probe; kept only once verified.
        case needsProbe
        /// Replaced by an equivalent listed flag (rules.md passed inline).
        case fallback
        /// Optional and unknown to this CLI: left out.
        case dropped
        /// Required and unknown: code mode can't run.
        case missingRequired
    }

    public struct Row: Equatable, Sendable {
        public var flag: String
        public var status: Status
        public var note: String?
    }

    public var rows: [Row]
    /// The set to pass to AgentInvocation.arguments(supportedFlags:).
    public var effectiveSupportedFlags: Set<String>

    public var missingRequiredFlags: [String] { rows.filter { $0.status == .missingRequired || $0.status == .needsProbe }.map(\.flag) }
    public var droppedOptionalFlags: [String] { rows.filter { $0.status == .dropped }.map(\.flag) }
    public var isUsable: Bool { missingRequiredFlags.isEmpty }

    /// Plain-text table, one flag per line (logs, the final report).
    public var tableText: String {
        rows.map { row in
            "\(row.flag.padding(toLength: 30, withPad: " ", startingAt: 0)) \(row.status.rawValue)\(row.note.map { "  (\($0))" } ?? "")"
        }.joined(separator: "\n")
    }
}

public enum AgentFlagSupport {
    /// Hidden-but-real flags the preflight probe passes, so a successful probe proves them.
    public static let probeVerifiableFlags: Set<String> = ["--max-turns"]

    /// Every flag either session kind of the agent may use, in argv order.
    public static var allAgentFlags: [String] {
        let sample = AgentInvocation(prompt: "x", contextDirectoryPath: "/c", outboxDirectoryPath: "/o", emptyGHConfigDirectoryPath: "/g",
                                     ownership: .own, isReadOnly: false, bashAllowed: true, session: .new(identifier: "s"))
        var flags = sample.flagGroups.map(\.flag)
        if !flags.contains("--resume") { flags.append("--resume") }
        return flags
    }

    public static func evaluate(helpFlags: Set<String>, probeVerifiedFlags: Set<String> = []) -> AgentFlagReport {
        var rows: [AgentFlagReport.Row] = []
        var effectiveFlags = helpFlags
        for flag in allAgentFlags {
            let isRequired = AgentInvocation.requiredFlags.contains(flag)
            if AgentInvocation.isSupported(flag, by: helpFlags) {
                let alias = (AgentInvocation.flagAliases[flag] ?? []).first { helpFlags.contains($0) }
                rows.append(.init(flag: flag, status: .kept, note: helpFlags.contains(flag) ? nil : alias.map { "listed as \($0)" }))
            } else if probeVerifiableFlags.contains(flag) {
                if probeVerifiedFlags.contains(flag) {
                    rows.append(.init(flag: flag, status: .probeVerified, note: "hidden from --help"))
                    effectiveFlags.insert(flag)
                } else {
                    rows.append(.init(flag: flag, status: isRequired ? .needsProbe : .dropped, note: "hidden from --help; the preflight probe checks it"))
                }
            } else if let fallbackFlag = AgentInvocation.flagFallbacks[flag], helpFlags.contains(fallbackFlag) {
                rows.append(.init(flag: flag, status: .fallback, note: "\(fallbackFlag) with the text inline"))
            } else {
                rows.append(.init(flag: flag, status: isRequired ? .missingRequired : .dropped, note: nil))
            }
        }
        return AgentFlagReport(rows: rows, effectiveSupportedFlags: effectiveFlags)
    }
}
