//
//  CodeGuards.swift
//  ClickyCore
//
//  The last look before anything leaves the machine: scans the diff, the
//  commit message and every PR/comment body Clicky is about to send.
//  RED findings block the approve button: secrets (GitHub, Anthropic, AWS
//  tokens, private keys), conflict markers in added lines, and any change
//  under .github/workflows/. Some RED findings can be acknowledged by the
//  user (hooks, Claude/MCP config, package.json scripts) — the ack goes into
//  the ApprovalKey. Secrets are reported masked, never echoed whole.
//

import Foundation

public struct CodeGuardFinding: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// e.g. "GitHub token", "Anthropic API key".
        case secret(kindName: String)
        case conflictMarker
        case workflowChange
        /// Hooks / agent config / package.json: RED but ack-able.
        case sensitivePath
    }

    public enum Source: Equatable, Sendable {
        case diff
        case commitMessage
        /// A PR, review or comment body; the label says which.
        case body(label: String)
    }

    public var kind: Kind
    public var source: Source
    /// Repo-relative path (diff findings only).
    public var file: String?
    /// 1-based: the new-file line for diffs, else the line in the text.
    public var line: Int?
    /// When true the user may acknowledge it; otherwise it blocks outright.
    public var isAckable: Bool
    /// Human-readable, with any secret masked.
    public var message: String

    /// The string stored in the acks of an ApprovalKey (ack-able findings only).
    public var ackIdentifier: String? {
        guard isAckable, let file else { return nil }
        return "sensitive-path:\(file)"
    }

    public var isBlocking: Bool { !isAckable }
}

public enum CodeGuards {
    struct SecretPattern {
        let kindName: String
        let regularExpression: NSRegularExpression
    }

    static let secretPatterns: [SecretPattern] = [
        ("GitHub token", #"gh[opsu]_\w{36}"#),
        ("GitHub fine-grained token", #"github_pat_\w+"#),
        ("Anthropic API key", #"sk-ant-\S+"#),
        ("AWS access key", #"AKIA[0-9A-Z]{16}"#),
        ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#)
    ].map { SecretPattern(kindName: $0.0, regularExpression: try! NSRegularExpression(pattern: $0.1)) }

    public struct BodyText: Sendable {
        public var label: String
        public var text: String
        public init(label: String, text: String) {
            self.label = label
            self.text = text
        }
    }

    /// Everything about to go out. Findings are in source order: diff, commit message, bodies.
    public static func scan(diffText: String, commitMessage: String? = nil, bodies: [BodyText] = []) -> [CodeGuardFinding] {
        scan(diffFiles: DiffParser.parse(diffText), commitMessage: commitMessage, bodies: bodies)
    }

    public static func scan(diffFiles: [DiffFile], commitMessage: String? = nil, bodies: [BodyText] = []) -> [CodeGuardFinding] {
        var findings: [CodeGuardFinding] = []
        for diffFile in diffFiles {
            findings += pathFindings(for: diffFile)
            for addedLine in diffFile.addedLines {
                findings += secretFindings(in: addedLine.text, source: .diff, file: diffFile.displayPath, line: addedLine.newLineNumber)
                if isConflictMarker(addedLine.text) {
                    findings.append(CodeGuardFinding(kind: .conflictMarker, source: .diff, file: diffFile.displayPath, line: addedLine.newLineNumber, isAckable: false,
                                                     message: "Conflict marker in \(diffFile.displayPath)\(addedLine.newLineNumber.map { ":\($0)" } ?? "")"))
                }
            }
        }
        if let commitMessage {
            findings += textFindings(in: commitMessage, source: .commitMessage)
        }
        for body in bodies {
            findings += textFindings(in: body.text, source: .body(label: body.label))
        }
        return findings
    }

    public static func hasBlockingFindings(_ findings: [CodeGuardFinding], acks: Set<String>) -> Bool {
        findings.contains { finding in
            if finding.isBlocking { return true }
            guard let ackIdentifier = finding.ackIdentifier else { return true }
            return !acks.contains(ackIdentifier)
        }
    }

    // MARK: - Paths

    static func pathFindings(for diffFile: DiffFile) -> [CodeGuardFinding] {
        var findings: [CodeGuardFinding] = []
        for touchedPath in diffFile.touchedPaths {
            if isWorkflowPath(touchedPath) {
                findings.append(CodeGuardFinding(kind: .workflowChange, source: .diff, file: touchedPath, line: nil, isAckable: false,
                                                 message: "Changes a GitHub Actions workflow: \(touchedPath)"))
            } else if isSensitivePath(touchedPath) {
                findings.append(CodeGuardFinding(kind: .sensitivePath, source: .diff, file: touchedPath, line: nil, isAckable: true,
                                                 message: "Changes hooks or agent/package config: \(touchedPath)"))
            }
        }
        return findings
    }

    /// Anything under .github/workflows/ at the repo root (case-insensitive).
    public static func isWorkflowPath(_ path: String) -> Bool {
        path.lowercased().hasPrefix(".github/workflows/")
    }

    /// .husky/ or .claude/ anywhere, or a file named .mcp.json, CLAUDE.md or package.json.
    public static func isSensitivePath(_ path: String) -> Bool {
        let pathComponents = path.split(separator: "/").map { $0.lowercased() }
        guard let fileName = pathComponents.last else { return false }
        if pathComponents.dropLast().contains(where: { $0 == ".husky" || $0 == ".claude" }) { return true }
        return [".mcp.json", "claude.md", "package.json"].contains(fileName) || fileName == ".husky" || fileName == ".claude"
    }

    // MARK: - Text

    static func textFindings(in text: String, source: CodeGuardFinding.Source) -> [CodeGuardFinding] {
        var findings: [CodeGuardFinding] = []
        for (lineOffset, textLine) in text.components(separatedBy: "\n").enumerated() {
            findings += secretFindings(in: textLine, source: source, file: nil, line: lineOffset + 1)
        }
        return findings
    }

    static func secretFindings(in text: String, source: CodeGuardFinding.Source, file: String?, line: Int?) -> [CodeGuardFinding] {
        var findings: [CodeGuardFinding] = []
        let searchRange = NSRange(text.startIndex..., in: text)
        for secretPattern in secretPatterns {
            for match in secretPattern.regularExpression.matches(in: text, range: searchRange) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let masked = mask(String(text[matchRange]))
                let location = [file, line.map(String.init)].compactMap { $0 }.joined(separator: ":")
                findings.append(CodeGuardFinding(kind: .secret(kindName: secretPattern.kindName), source: source, file: file, line: line, isAckable: false,
                                                 message: "Possible \(secretPattern.kindName) \(masked)\(location.isEmpty ? "" : " at \(location)")"))
            }
        }
        return findings
    }

    /// Keeps a short recognisable head and the length: "ghp_…(40 chars)".
    /// Private-key headers carry no secret, so they are shown as-is.
    public static func mask(_ secret: String) -> String {
        if secret.hasPrefix("-----BEGIN") { return secret }
        let visiblePrefixLength: Int
        if secret.hasPrefix("github_pat_") { visiblePrefixLength = 11 }
        else if secret.hasPrefix("sk-ant-") { visiblePrefixLength = 7 }
        else { visiblePrefixLength = 4 }
        return "\(secret.prefix(min(visiblePrefixLength, secret.count / 2)))…(\(secret.count) chars)"
    }

    /// "<<<<<<< x", "=======" alone, ">>>>>>> x" (bare 7-char markers count too).
    public static func isConflictMarker(_ line: String) -> Bool {
        line.hasPrefix("<<<<<<< ") || line == "<<<<<<<" || line == "=======" || line.hasPrefix(">>>>>>> ") || line == ">>>>>>>"
    }
}
