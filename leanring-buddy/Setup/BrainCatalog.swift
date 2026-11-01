//
//  BrainCatalog.swift
//  leanring-buddy
//
//  The models the brain switch offers, per brain: Claude's own list, the
//  ChatGPT models Codex says this account may use (its models cache, else
//  T3 Code's manifest), `opencode models`, and `cursor-agent --list-models`.
//  Loaded in the background when Setup or the panel's menu needs it.
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class BrainCatalog: ObservableObject {
    static let shared = BrainCatalog()

    @Published private(set) var models: [BrainProvider: [String]] = [.claude: ClickyModels.options.map(\.identifier)]
    @Published private(set) var notes: [BrainProvider: String] = [:]
    @Published private(set) var isLoading = false
    private var lastLoad: Date?

    func label(for setting: String) -> String {
        let model = BrainModel(setting: setting)
        if model.provider == .api {
            let parts = model.modelIdentifier.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return model.modelIdentifier }
            return "\(parts[1]) · \(ProviderInfo.info(for: parts[0])?.label ?? parts[0])"
        }
        if model.isClaude, let option = ClickyModels.options.first(where: { $0.identifier == model.modelIdentifier }) { return option.label }
        return model.modelIdentifier
    }

    /// Reloads at most once a minute.
    func load(force: Bool = false) {
        if !force, let lastLoad, Date().timeIntervalSince(lastLoad) < 60 { return }
        lastLoad = Date()
        isLoading = true
        Task.detached(priority: .utility) {
            var found: [BrainProvider: [String]] = [.claude: ClickyModels.options.map(\.identifier)]
            var notes: [BrainProvider: String] = [:]
            let home = FileManager.default.homeDirectoryForCurrentUser

            if BrainCLIRunner.locateExecutable(for: .codex) != nil {
                var codexModels: [String] = []
                if let cache = try? Data(contentsOf: home.appendingPathComponent(".codex/models_cache.json")) {
                    codexModels = BrainModelCatalog.codexModels(cacheJSON: cache)
                }
                if codexModels.isEmpty, let manifest = try? Data(contentsOf: home.appendingPathComponent(".t3/userdata/model-manifest.json")) {
                    codexModels = BrainModelCatalog.t3CurrentModels(manifestJSON: manifest)["codex"] ?? []
                }
                found[.codex] = codexModels
                if codexModels.isEmpty { notes[.codex] = "Run `codex` once in Terminal to sign in with ChatGPT." }
            } else {
                notes[.codex] = "Codex isn't installed."
            }

            if let openCode = BrainCLIRunner.locateExecutable(for: .opencode) {
                found[.opencode] = BrainModelCatalog.openCodeModels(listing: Self.output(of: openCode, ["models"]))
            } else {
                notes[.opencode] = "OpenCode isn't installed."
            }

            if let cursor = BrainCLIRunner.locateExecutable(for: .cursor) {
                let listing = Self.output(of: cursor, ["--list-models"])
                let cursorModels = BrainModelCatalog.cursorModels(listing: listing)
                found[.cursor] = cursorModels
                if cursorModels.isEmpty { notes[.cursor] = "Sign in with `cursor-agent login` in Terminal." }
            } else {
                notes[.cursor] = "Cursor Agent isn't installed."
            }

            await MainActor.run {
                self.models = found
                self.notes = notes
                self.isLoading = false
            }
        }
    }

    /// stdout of a short command (20 s at most).
    private nonisolated static func output(of executable: URL, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let deadline = DispatchTime.now() + 20
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The model a brain starts with when the switch moves to it.
    func defaultModel(for provider: BrainProvider) -> String? {
        switch provider {
        case .claude: return ClickyModels.sonnet
        case .api: return nil
        default:
            guard let first = models[provider]?.first else { return nil }
            return BrainModel(provider: provider, modelIdentifier: first).setting
        }
    }
}
