//
//  ModelFreshness.swift
//  leanring-buddy
//
//  Keeps the model pickers and everyone's model choices current without a new build. At launch and every 12 hours it:
//  1. asks every saved API key's provider for its live model list (`ProviderKeys.refreshModels`),
//  2. asks Claude Code which model each of its aliases ("opus", "sonnet", "haiku", "fable") stands for, when it's signed in
//     with a Claude plan (the alias always means the newest model the installed Claude Code knows; the process is stopped
//     as soon as it names the model, before it answers anything),
//  3. re-checks every subscription (HarnessCenter: Claude Code, Codex, Cursor, OpenCode, Grok, Gemini) and their lists,
//  4. when Settings › Models & API keys › "Keep models up to date" is on (default), moves each bot, Pointer Assistant's
//     models and the harness defaults onto the newest model of the same family that's offered here (ClickyCore
//     `ModelUpgrade`: Sonnet 5 → Sonnet 5.5, never Sonnet → Opus), and records what moved.
//  The pure rules are ClickyCore `Settings/ModelFreshness.swift`.
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class ModelFreshnessController: ObservableObject {
    static let shared = ModelFreshnessController()

    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: ModelAutoUpgrade.lastCheckKey) as? Date
    @Published private(set) var history: [ModelAutoUpgrade.Entry] = ModelAutoUpgrade.history()
    @Published var keepsModelsCurrent: Bool = ModelAutoUpgrade.isOn() {
        didSet {
            ModelAutoUpgrade.setOn(keepsModelsCurrent)
            if keepsModelsCurrent { upgradeEverything() }
        }
    }

    private var timer: Timer?
    private var started = false

    /// From launch: a check now (after the first harness check has had time to finish), then every 12 hours while Vello runs.
    func start() {
        guard !started else { return }
        started = true
        HarnessCenter.shared.useDiscoveredModels()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await self.checkNow(force: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await ModelFreshnessController.shared.checkNow(force: false) }
        }
    }

    /// Every list again, then the upgrade. `force` skips the 12-hour wait (the Check now button).
    func checkNow(force: Bool) async {
        guard !isChecking else { return }
        guard force || ModelAutoUpgrade.isCheckDue() else {
            // Lists already fresh: still upgrade, in case a bot was moved back to an older model on the other Mac.
            upgradeEverything()
            return
        }
        isChecking = true
        defer { isChecking = false }

        let keys = ProviderKeys.shared
        await withTaskGroup(of: Void.self) { group in
            for provider in keys.usableChatProviders where provider.modelsPath != nil {
                let providerID = provider.id
                group.addTask { @MainActor in _ = await keys.refreshModels(providerID) }
            }
        }
        // An Anthropic key's list names Claude's newest models, which Claude Code on a plan can use too.
        if let anthropic = ProviderInfo.info(for: "anthropic"), keys.hasKey(for: "anthropic") {
            ClaudeModelList.remember(keys.models(for: anthropic))
        }
        await probeClaudeCodeAliases()

        HarnessCenter.shared.refresh(force: true)
        BrainCatalog.shared.load(force: true)
        // The harness check runs in the background; wait for it (at most a minute) so the upgrade sees its lists.
        for _ in 0..<60 where HarnessCenter.shared.isRefreshing {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        HarnessCenter.shared.useDiscoveredModels()

        let now = Date()
        UserDefaults.standard.set(now, forKey: ModelAutoUpgrade.lastCheckKey)
        lastCheck = now
        upgradeEverything()
    }

    // MARK: Claude Code's aliases

    /// Which model each Claude Code alias means today. Only with a Claude plan sign-in: on an API key the key's own list says it.
    private func probeClaudeCodeAliases() async {
        let center = HarnessCenter.shared
        guard center.status(for: "claude").loggedIn == true, !center.usesAPIKey("claude"),
              let executable = HarnessCatalog.executable(for: "claude") else { return }
        var found: [String] = []
        for alias in ClaudeAliasProbe.aliases {
            if let model = await Self.modelID(forAlias: alias, executable: executable) { found.append(model) }
        }
        if !found.isEmpty { ClaudeModelList.remember(found) }
    }

    /// Starts `claude -p --model <alias>` with no tools and reads its first line, which names the model, then stops it.
    nonisolated private static func modelID(forAlias alias: String, executable: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readAliasModel(alias: alias, executable: executable))
            }
        }
    }

    nonisolated private static func readAliasModel(alias: String, executable: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "--model", alias, "--output-format", "stream-json", "--verbose", "--max-turns", "1",
                             "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                             "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#, "--", "."]
        var environment = HarnessCatalog.childEnvironment(extra: ["CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1"])
        // The plan's own sign-in, never a key in the environment.
        environment["ANTHROPIC_API_KEY"] = nil
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = DispatchTime.now() + 25
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        var buffered = Data()
        var model: String?
        let handle = output.fileHandleForReading
        readLoop: while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffered.append(chunk)
            while let newline = buffered.firstIndex(of: 0x0A) {
                let line = String(decoding: buffered[buffered.startIndex..<newline], as: UTF8.self)
                buffered.removeSubrange(buffered.startIndex...newline)
                if let named = ClaudeAliasProbe.modelID(fromStreamLine: line) {
                    model = named
                    break readLoop
                }
            }
            if buffered.count > 1_000_000 { break }
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return model
    }

    // MARK: Moving everyone onto the newest model

    /// Moves every model choice that has a newer one of the same family on offer. Does nothing while the switch is off.
    func upgradeEverything() {
        guard ModelAutoUpgrade.isOn() else { return }
        var moved: [String] = []

        let store = BotsStore.shared
        for bot in store.bots where !bot.model.isEmpty {
            let offered = BotModels.list(for: bot.provider, current: "")
            guard let newer = ModelUpgrade.newer(than: bot.model, in: offered) else { continue }
            var edited = bot
            edited.model = newer
            edited.effort = ModelEffort.carriedOver(effort: bot.effort, toLevels: BotModels.efforts(for: bot.provider, model: newer))
            store.save(edited)
            moved.append("\(bot.name): \(BotModels.label(bot.model, on: bot.provider)) → \(BotModels.label(newer, on: bot.provider))")
        }

        // Pointer Assistant's own models, when they're Claude ids.
        let claudeOffered = HarnessCatalog.claudeModels.map(\.id)
        func upgradeClaudeSetting(_ title: String, current: String, save: (String) -> Void) {
            guard BrainModel(setting: current).isClaude, let newer = ModelUpgrade.newer(than: current, in: claudeOffered) else { return }
            save(newer)
            moved.append("\(title): \(ClaudeModelList.shortLabel(for: current)) → \(ClaudeModelList.shortLabel(for: newer))")
        }
        upgradeClaudeSetting("Pointer Assistant", current: ClickyModels.main) { ClickyModels.main = $0 }
        if ClickyModels.helperWasChosen {
            upgradeClaudeSetting("Pointer Assistant's helpers", current: ClickyModels.helper) { ClickyModels.helper = $0 }
        }
        upgradeClaudeSetting("Pointer Assistant's code agent", current: ClickyModels.code) { ClickyModels.code = $0 }

        // Each harness's default model, and the model coding runs use.
        for harness in HarnessCatalog.all.map(\.id) {
            guard let current = HarnessPrefs.defaultModel(harness) else { continue }
            let offered = BotModels.list(for: harness, current: "")
            guard let newer = ModelUpgrade.newer(than: current, in: offered) else { continue }
            HarnessPrefs.setDefaultModel(newer, for: harness)
            moved.append("\(HarnessCatalog.label(harness)) default: \(current) → \(newer)")
        }
        if let current = HarnessPrefs.codingModel {
            let offered = BotModels.list(for: HarnessPrefs.codingTarget, current: "")
            if let newer = ModelUpgrade.newer(than: current, in: offered) {
                // Straight into the setting: the setter would also pin the coding target, which isn't the owner's choice here.
                UserDefaults.standard.set(newer, forKey: "theo.coding.model")
                moved.append("Coding runs: \(current) → \(newer)")
            }
        }

        guard !moved.isEmpty else { return }
        ModelAutoUpgrade.record(moved)
        history = ModelAutoUpgrade.history()
        NSLog("Vello moved %d model choice(s) to newer models", moved.count)
    }
}
