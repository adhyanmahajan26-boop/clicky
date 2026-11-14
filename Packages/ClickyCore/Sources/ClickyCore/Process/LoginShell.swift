//
//  LoginShell.swift
//  ClickyCore
//
//  The shell Theo asks for the owner's PATH. A Mac app started from Finder or
//  launchd gets a bare PATH, so tools installed with nvm, pnpm, bun or Homebrew
//  are only visible to a login shell. That has to be the owner's own shell:
//  someone on bash keeps their PATH in ~/.bash_profile, which zsh never reads.
//  $SHELL first, then the login shell the system has on record for the user,
//  then zsh (the macOS default) when neither is a shell we know how to ask.
//

import Foundation

public enum LoginShell {
    /// Used when the owner's shell can't be found or isn't one we know how to ask for its PATH.
    public static let fallbackShellPath = "/bin/zsh"

    /// Shells that take `-l -i -c <command>` and print `"$PATH"` joined with colons
    /// (fish joins PATH-like variables with colons when they're quoted).
    static let shellNamesThatAnswerPathQuestions: Set<String> = ["zsh", "bash", "sh", "ksh", "dash", "fish"]

    /// The owner's login shell, as an absolute path.
    public static func shellPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        systemRecordedShellPath: String? = LoginShell.systemRecordedShellPath(),
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        for candidateShellPath in [environment["SHELL"], systemRecordedShellPath] {
            guard let candidateShellPath, candidateShellPath.hasPrefix("/") else { continue }
            let shellName = (candidateShellPath as NSString).lastPathComponent
            if shellNamesThatAnswerPathQuestions.contains(shellName), isExecutableFile(candidateShellPath) {
                return candidateShellPath
            }
        }
        return fallbackShellPath
    }

    /// The arguments that make the shell run `command` the way a new Terminal window would.
    /// `interactive` also reads the rc file (~/.zshrc, ~/.bashrc), where nvm and friends usually add themselves.
    public static func arguments(forCommand command: String, interactive: Bool) -> [String] {
        (interactive ? ["-l", "-i", "-c"] : ["-l", "-c"]) + [command]
    }

    /// The owner's PATH as their login shell sees it: the last line the shell prints (an interactive shell may print a
    /// banner first). Empty when the shell can't be asked. Blocks for up to `timeout` seconds.
    public static func askPath(timeout: TimeInterval = 5) -> String {
        let output = commandOutput(executable: shellPath(), arguments: arguments(forCommand: "printf %s \"$PATH\"", interactive: true), timeout: timeout) ?? ""
        return output.split(separator: "\n").last.map(String.init) ?? ""
    }

    /// Runs a short command and returns what it printed, or nil when it couldn't start. It waits on a semaphore, never on
    /// the run loop: `Process.waitUntilExit()` runs the current run loop while it waits, so on the main thread it starts
    /// other main-thread work in the middle. When the caller is a `static let`'s initializer, that work can use the same
    /// `static let` again, and dispatch_once traps ("trying to lock recursively"): a fresh profile crashed at launch that way.
    public static func commandOutput(executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        _ = exited.wait(timeout: .now() + timeout + 2)
        return String(decoding: data, as: UTF8.self)
    }

    /// The login shell in the user's account record (what `chsh` set), or nil.
    public static func systemRecordedShellPath() -> String? {
        guard let accountEntry = getpwuid(getuid()), let shellPathPointer = accountEntry.pointee.pw_shell else { return nil }
        let shellPath = String(cString: shellPathPointer)
        return shellPath.isEmpty ? nil : shellPath
    }
}
