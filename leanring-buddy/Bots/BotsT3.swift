//
//  BotsT3.swift
//  leanring-buddy
//
//  Submits the Project room's final prompt to T3 Code for real: a project
//  folder under ~/Projects, registered with T3 Code, and a thread started
//  in it on OpenCode, through the t3 command-line tool that T3 Code
//  installs. The project then opens in the T3 Code app.
//

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

enum BotsT3 {
    /// The coding model T3 Code builds with.
    static let provider = "opencode"
    static let model = "opencode/big-pickle"

    /// The t3 launcher T3 Code writes into its data folder (Cursor Assistant build first).
    static var cli: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".t3-claudia/bin/t3", ".t3/bin/t3"].map { home.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The ```prompt block Theo writes as the team's final prompt, if there is one.
    static func promptBlock(in text: String) -> String? {
        guard let start = text.range(of: "```prompt") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "```") else { return nil }
        let body = rest[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// "Project: Name" on its own line, else the prompt's first words.
    static func projectTitle(in text: String, prompt: String) -> String {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
            if trimmed.lowercased().hasPrefix("project:") {
                let name = trimmed.dropFirst("project:".count).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return String(name.prefix(60)) }
            }
        }
        return prompt.split(separator: " ").prefix(6).joined(separator: " ")
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "theo-project" : String(collapsed.prefix(48))
    }

    /// Creates the project, starts the thread and opens it. Returns the project folder.
    static func submit(prompt: String, title: String) async throws -> URL {
        guard let cli else { throw BotsT3Error.noCLI }
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects", isDirectory: true)
        var folder = projects.appendingPathComponent(slug(title), isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = projects.appendingPathComponent("\(slug(title))-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# \(title)\n\nStarted by Theo's Project room. The prompt T3 Code received:\n\n\(prompt)\n"
            .write(to: folder.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)

        try await run(cli, ["project", "add", folder.path, "--title", title], stdin: nil)
        try await run(cli, ["thread", "start", folder.path, "-", "--title", title,
                            "--provider", provider, "--model", model], stdin: prompt)
        _ = try? await run(cli, ["app", folder.path], stdin: nil)
        return folder
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String], stdin: String?) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            var environment = ProcessInfo.processInfo.environment
            environment["PWD"] = FileManager.default.homeDirectoryForCurrentUser.path
            environment["NO_COLOR"] = "1"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let input = Pipe()
            process.standardInput = stdin == nil ? FileHandle.nullDevice : input
            try process.run()
            if let stdin {
                try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                throw BotsT3Error.failed("t3 \(arguments.first ?? "") failed: \(text.suffix(200))")
            }
            return text
        }.value
    }
}
