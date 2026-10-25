//
//  CodeCommandRunner.swift
//  ClickyCore
//
//  How Code mode runs `git` and `gh`: one-shot ChildProcess calls with
//  absolute executable paths, a time limit, and every argv plus its exit
//  code appended to the task's commands.log (bodies never appear in argv —
//  they go by file — so the log holds no PR text). A protocol so tests can
//  swap in a recording fake.
//

import Foundation

/// What one command produced.
public struct CodeCommandOutput: Equatable, Sendable {
    public var exitStatus: Int32?
    public var standardOutput: String
    public var standardError: String
    public var endReason: ChildProcessEndReason

    public init(exitStatus: Int32?, standardOutput: String, standardError: String, endReason: ChildProcessEndReason = .exited) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.endReason = endReason
    }

    public var succeeded: Bool { endReason == .exited && exitStatus == 0 }
    public var trimmedOutput: String { standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The first stderr line, for messages.
    public var shortError: String {
        let firstLine = standardError.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "exit \(exitStatus.map(String.init) ?? "signal")" : String(firstLine.prefix(200))
    }
}

public enum CodeCommandError: Error, Equatable, Sendable, CustomStringConvertible {
    case failed(command: String, exitStatus: Int32?, message: String)
    case toolMissing(String)

    public var description: String {
        switch self {
        case .failed(let command, let exitStatus, let message): return "\(command) failed (\(exitStatus.map(String.init) ?? "signal")): \(message)"
        case .toolMissing(let name): return "\(name) not found"
        }
    }
}

public protocol CodeCommandRunning: Sendable {
    func run(executable: String, arguments: [String], workingDirectory: String?, environment: [String: String], timeoutSeconds: TimeInterval) async throws -> CodeCommandOutput
}

/// Appends "argv → exit" lines to a file (the task's commands.log).
public final class CodeCommandLog: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func record(executable: String, arguments: [String], workingDirectory: String?, output: CodeCommandOutput?) {
        let quotedCommand = ([executable] + arguments).map(ShellQuoting.quote).joined(separator: " ")
        let outcome = output.map { "exit \($0.exitStatus.map(String.init) ?? "signal") \($0.endReason)" } ?? "spawn failed"
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(workingDirectory ?? "-")] \(quotedCommand) → \(outcome)\n"
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        }
    }
}

/// The real runner: ChildProcess with a total time limit.
public struct ChildProcessCommandRunner: CodeCommandRunning {
    public var log: CodeCommandLog?

    public init(log: CodeCommandLog? = nil) {
        self.log = log
    }

    public func run(executable: String, arguments: [String], workingDirectory: String?, environment: [String: String], timeoutSeconds: TimeInterval) async throws -> CodeCommandOutput {
        do {
            let result = try await ChildProcess.run(executable: executable, arguments: arguments, environment: environment,
                                                    workingDirectory: workingDirectory, timeouts: .total(timeoutSeconds))
            let output = CodeCommandOutput(exitStatus: result.exitStatus, standardOutput: result.standardOutputText,
                                           standardError: result.standardErrorText, endReason: result.endReason)
            log?.record(executable: executable, arguments: arguments, workingDirectory: workingDirectory, output: output)
            return output
        } catch {
            log?.record(executable: executable, arguments: arguments, workingDirectory: workingDirectory, output: nil)
            throw error
        }
    }
}

/// POSIX single-quote quoting, for logs and the panel's argv display.
public enum ShellQuoting {
    public static func quote(_ argument: String) -> String {
        if !argument.isEmpty, argument.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func quote(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}

/// Absolute paths of the three tools Code mode runs.
public struct CodeToolPaths: Equatable, Sendable {
    public var git: String
    public var gh: String
    public var claude: String

    public init(git: String, gh: String, claude: String) {
        self.git = git
        self.gh = gh
        self.claude = claude
    }

    /// Found the way Terminal would (login-shell PATH + ~/.local/bin).
    public static func locate() async throws -> CodeToolPaths {
        guard let gitPath = await ExecutablePath.which("git") else { throw CodeCommandError.toolMissing("git") }
        guard let ghPath = await ExecutablePath.which("gh") else { throw CodeCommandError.toolMissing("gh") }
        guard let claudePath = await ExecutablePath.which("claude") else { throw CodeCommandError.toolMissing("claude") }
        return CodeToolPaths(git: gitPath, gh: ghPath, claude: claudePath)
    }
}

/// The environment Clicky's own git/gh calls get: the app's, without any
/// inherited GIT_* overrides (GIT_DIR and friends), never prompting.
public enum CodeCommandEnvironment {
    public static func forClickyCommands(base baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = baseEnvironment.filter { key, _ in !key.hasPrefix("GIT_") }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        return environment
    }
}
