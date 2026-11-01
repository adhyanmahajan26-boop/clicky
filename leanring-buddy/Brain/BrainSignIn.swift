//
//  BrainSignIn.swift
//  leanring-buddy
//
//  Whether each brain's command-line agent is installed and signed in. These are
//  the same CLIs T3 Code drives (Claude Code, Codex, Cursor Agent, OpenCode), so a
//  sign-in done in T3 Code counts here too, and the other way round.
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class BrainSignIn: ObservableObject {
    enum State: Equatable {
        case checking
        case notInstalled
        case signedOut
        case signedIn(String)

        var isReady: Bool { if case .signedIn = self { return true } else { return false } }
        var label: String {
            switch self {
            case .checking: return "Checking…"
            case .notInstalled: return "Not installed"
            case .signedOut: return "Signed out"
            case .signedIn(let detail): return detail
            }
        }
    }

    static let shared = BrainSignIn()
    @Published private(set) var states: [BrainProvider: State] = Dictionary(uniqueKeysWithValues: BrainProvider.allCases.map { ($0, .checking) })
        .merging([.api: .signedIn("API key")]) { _, new in new }
    private var lastRefresh: Date?

    /// Re-checks every brain (at most every 20 s unless forced).
    func refresh(force: Bool = false) {
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 20 { return }
        lastRefresh = Date()
        for provider in BrainProvider.allCases {
            Task.detached {
                let state = await Self.check(provider)
                await MainActor.run { self.states[provider] = state }
            }
        }
    }

    nonisolated private static func check(_ provider: BrainProvider) async -> State {
        if provider == .api { return .signedIn("API key") }
        guard let executable = BrainCLIRunner.locateExecutable(for: provider) else { return .notInstalled }
        switch provider {
        case .api:
            return .signedIn("API key")
        case .claude:
            if ClickySettings.brainAuthMode == .apiKey {
                return ClickySettings.anthropicAPIKeyForCalls != nil ? .signedIn("Anthropic API key") : .signedOut
            }
            let (_, output) = run(executable, ["auth", "status"])
            let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
            return object?["loggedIn"] as? Bool == true ? .signedIn("Claude subscription") : .signedOut
        case .codex:
            let (status, output) = run(executable, ["login", "status"])
            return status == 0 && output.localizedCaseInsensitiveContains("logged in") ? .signedIn("ChatGPT account") : .signedOut
        case .cursor:
            let (status, output) = run(executable, ["status"])
            return status == 0 && output.localizedCaseInsensitiveContains("logged in") ? .signedIn("Cursor account") : .signedOut
        case .opencode:
            // OpenCode also runs local models (LM Studio and friends), so installed counts as ready.
            let (_, output) = run(executable, ["auth", "list"])
            let hasCredentials = !output.contains("0 credentials")
            return .signedIn(hasCredentials ? "OpenCode providers" : "Local models")
        }
    }

    nonisolated private static func run(_ executable: URL, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
