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

    /// The login shell in the user's account record (what `chsh` set), or nil.
    public static func systemRecordedShellPath() -> String? {
        guard let accountEntry = getpwuid(getuid()), let shellPathPointer = accountEntry.pointee.pw_shell else { return nil }
        let shellPath = String(cString: shellPathPointer)
        return shellPath.isEmpty ? nil : shellPath
    }
}
