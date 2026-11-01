//
//  HarnessCatalog.swift
//  leanring-buddy
//
//  "Every harness": the coding-agent CLIs Theo can drive at terminal level (T3 Code, Claude Code, Codex,
//  Cursor Agent, OpenCode, Grok, Gemini CLI). This file holds the table of harnesses, how to find them,
//  whether they are signed in (and as whom), their model lists, and HarnessCenter, the observable object
//  the UI reads. The user's defaults (harness, model, effort, coding target) live in UserDefaults through
//  HarnessPrefs, which any thread may read.
//

import ClickyCore
import Combine
import Foundation

struct HarnessModel: Codable, Hashable, Identifiable {
    var id: String
    var label: String
}

struct HarnessInfo {
    enum ModelSource { case fixed([HarnessModel]), codexCache, cursorList, opencodeList, freeText, t3 }
    let id: String
    let label: String
    let binaries: [String]
    /// Efforts offered when the model gives no list of its own (empty: the harness has no effort setting).
    let efforts: [String]
    let modelSource: ModelSource
    /// Bots can run on it headless (BotRunner); T3 Code can't, it is only a coding target.
    let canRunBots: Bool
}

enum HarnessCatalog {
    static let claudeModels: [HarnessModel] = [
        HarnessModel(id: "claude-opus-5-5", label: "Claude Opus 5.5"),
        HarnessModel(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5"),
        HarnessModel(id: "claude-haiku-5-5", label: "Claude Haiku 5.5"),
        HarnessModel(id: "claude-fable-5-1", label: "Claude Fable 5.1"),
    ]
    static let grokModels: [HarnessModel] = ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"]
        .map { HarnessModel(id: $0, label: $0) }

    static let all: [HarnessInfo] = [
        HarnessInfo(id: "t3", label: "T3 Code", binaries: ["t3"], efforts: ["low", "medium", "high"], modelSource: .t3, canRunBots: false),
        HarnessInfo(id: "claude", label: "Claude Code", binaries: ["claude"], efforts: ["low", "medium", "high", "xhigh", "max"],
                    modelSource: .fixed(claudeModels), canRunBots: true),
        HarnessInfo(id: "codex", label: "Codex (ChatGPT)", binaries: ["codex"], efforts: ["low", "medium", "high", "xhigh"],
                    modelSource: .codexCache, canRunBots: true),
        HarnessInfo(id: "cursor", label: "Cursor Agent", binaries: ["cursor-agent", "agent"], efforts: [],
                    modelSource: .cursorList, canRunBots: true),
        HarnessInfo(id: "opencode", label: "OpenCode", binaries: ["opencode"], efforts: ["low", "medium", "high"],
                    modelSource: .opencodeList, canRunBots: true),
        HarnessInfo(id: "grok", label: "Grok", binaries: ["grok"], efforts: ["low", "medium", "high"],
                    modelSource: .fixed(grokModels), canRunBots: true),
        HarnessInfo(id: "gemini", label: "Gemini CLI", binaries: ["gemini"], efforts: [], modelSource: .freeText, canRunBots: true),
    ]

    /// Harnesses a coding hand-off can go to (all of them).
    static var codingTargets: [HarnessInfo] { all }
    /// Harnesses a bot can run on.
    static var botEngines: [HarnessInfo] { all.filter { $0.canRunBots } }

    static func info(_ id: String) -> HarnessInfo? { all.first { $0.id == id } }
    static func label(_ id: String) -> String {
        if id.hasPrefix("api:") { return (ProviderInfo.info(for: String(id.dropFirst(4)))?.label ?? String(id.dropFirst(4))) + " API" }
        return info(id)?.label ?? id
    }

    // MARK: Finding binaries

    /// The login shell's PATH, asked once (nvm, pnpm, bun and friends are only on it in a login shell).
    /// Blocks on first use for up to 5 s: call off the main thread.
    static let loginShellPath: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Interactive shells may print banners; the PATH is the last line.
        return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
    }()

    /// Re-read after an install, so a harness installed just now is found without restarting Theo.
    static var searchDirectories: [String] { _searchDirectories }
    private static let _searchDirectories: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixed = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.grok/bin", "\(home)/.cursor/bin",
                     "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.opencode/bin"]
        var seen = Set<String>()
        return (fixed + loginShellPath.split(separator: ":").map(String.init)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }()

    static func locate(binary name: String) -> URL? {
        for dir in searchDirectories {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Where a harness's command lives (T3 Code: its launcher in the data folder).
    static func executable(for id: String) -> URL? {
        if id == "t3" { return BotsT3.cli }
        guard let info = info(id) else { return nil }
        for name in info.binaries { if let found = locate(binary: name) { return found } }
        return nil
    }

    // MARK: Install, sign in, keys

    /// How to install a harness and sign it in, from each tool's own docs and `--help` (checked 2026-11-01).
    struct Setup {
        /// The official one-line installer, shown and run in Theo's terminal.
        var install: String
        var installPage: String
        /// The CLI's own login arguments. Empty: signing in is part of running it (Gemini CLI).
        var signIn: [String]
        var signOut: [String]?
        /// What opens if the owner has to choose something in the terminal.
        var signInHint: String
        /// The provider whose saved key this harness can run on.
        var keyProvider: String?
        /// Environment variable names that key goes in.
        var keyVariables: [String]
    }

    static let setups: [String: Setup] = [
        "t3": Setup(install: "curl -fsSL https://t3.codes/install.sh | sh", installPage: "https://github.com/pingdotgg/t3code/releases",
                    signIn: [], signOut: nil, signInHint: "T3 Code uses the sign-ins of the harnesses below.", keyProvider: nil, keyVariables: []),
        "claude": Setup(install: "curl -fsSL https://claude.ai/install.sh | bash", installPage: "https://code.claude.com/docs/en/setup",
                        signIn: ["auth", "login"], signOut: ["auth", "logout"], signInHint: "Your browser opens to sign in with your Claude account.",
                        keyProvider: "anthropic", keyVariables: ["ANTHROPIC_API_KEY"]),
        "codex": Setup(install: "curl -fsSL https://chatgpt.com/codex/install.sh | sh", installPage: "https://github.com/openai/codex",
                       signIn: ["login"], signOut: ["logout"], signInHint: "Your browser opens to sign in with ChatGPT.",
                       keyProvider: "openai", keyVariables: ["OPENAI_API_KEY", "CODEX_API_KEY"]),
        "cursor": Setup(install: "curl https://cursor.com/install -fsS | bash", installPage: "https://cursor.com/docs/cli/installation",
                        signIn: ["login"], signOut: ["logout"], signInHint: "Your browser opens to sign in with Cursor.",
                        keyProvider: "cursor", keyVariables: ["CURSOR_API_KEY"]),
        "opencode": Setup(install: "curl -fsSL https://opencode.ai/install | bash", installPage: "https://opencode.ai/docs/",
                          signIn: ["auth", "login"], signOut: ["auth", "logout"], signInHint: "Pick a provider in the terminal. OpenCode's free models need no sign-in.",
                          keyProvider: nil, keyVariables: []),
        "grok": Setup(install: "curl -fsSL https://x.ai/cli/install.sh | bash", installPage: "https://docs.x.ai/build/overview",
                      signIn: ["login"], signOut: ["logout"], signInHint: "Your browser opens to sign in with your xAI account.",
                      keyProvider: "xai", keyVariables: ["XAI_API_KEY"]),
        "gemini": Setup(install: "npm install -g @google/gemini-cli", installPage: "https://github.com/google-gemini/gemini-cli",
                        signIn: [], signOut: nil, signInHint: "Choose \u{201C}Sign in with Google\u{201D} in the terminal. Free and Google AI Pro access moved to Antigravity CLI in June 2026; Gemini CLI now needs Code Assist or an API key.",
                        keyProvider: "gemini", keyVariables: ["GEMINI_API_KEY"]),
    ]

    /// Environment variables OpenCode reads for each provider's key.
    private static let openCodeKeys: [(provider: String, variable: String)] = [
        ("anthropic", "ANTHROPIC_API_KEY"), ("openai", "OPENAI_API_KEY"), ("gemini", "GOOGLE_GENERATIVE_AI_API_KEY"), ("xai", "XAI_API_KEY"),
        ("groq", "GROQ_API_KEY"), ("openrouter", "OPENROUTER_API_KEY"), ("mistral", "MISTRAL_API_KEY"), ("deepseek", "DEEPSEEK_API_KEY"),
        ("together", "TOGETHER_AI_API_KEY"), ("fireworks", "FIREWORKS_API_KEY"), ("cerebras", "CEREBRAS_API_KEY"),
    ]

    /// The saved key(s) as environment variables, when the owner has switched this harness to its API key.
    static func apiKeyEnvironment(for harness: String) -> [String: String] {
        guard HarnessPrefs.usesAPIKey(harness) else { return [:] }
        if harness == "opencode" {
            var environment: [String: String] = [:]
            for entry in openCodeKeys { if let key = ProviderKeychain.get(entry.provider) { environment[entry.variable] = key } }
            return environment
        }
        guard let setup = setups[harness], let provider = setup.keyProvider, let key = ProviderKeychain.get(provider) else { return [:] }
        return Dictionary(uniqueKeysWithValues: setup.keyVariables.map { ($0, key) })
    }

    /// The environment for a harness process: Theo's, minus the variables that would make a Claude Code child
    /// think it runs inside another Claude session, with a PATH that has the usual install folders.
    static func childEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK") {
            environment[key] = nil
        }
        environment["NO_COLOR"] = "1"
        environment["PATH"] = (searchDirectories + (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init))
            .joined(separator: ":")
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// Names of environment variables to unset (`env -u`) for a command started by tmux.
    static var scrubbedVariableNames: [String] {
        ProcessInfo.processInfo.environment.keys.filter { $0 == "CLAUDECODE" || $0.hasPrefix("CLAUDE_CODE_") || $0.hasPrefix("CLAUDE_AGENT_SDK") }
            .sorted()
    }

    // MARK: Running short commands

    /// stdout+stderr of a short command, killed after `timeout` seconds. Empty when it can't start.
    static func output(of executable: URL, _ arguments: [String], timeout: TimeInterval = 20, merge: Bool = true) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = childEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = merge ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Status

struct HarnessStatus: Equatable {
    var id: String
    var installed: Bool = false
    var path: String?
    /// nil: the CLI can't say (OpenCode, or the check failed).
    var loggedIn: Bool?
    /// "addyyo1227@gmail.com · max plan", "ChatGPT · Pro", …
    var account: String?
    var detail: String?
    var version: String?
    /// Installed and not known to be signed out.
    var ready: Bool { installed && loggedIn != false }
}

enum HarnessDetector {
    /// Checks one harness. Runs CLI commands: call off the main thread.
    static func status(for id: String) -> HarnessStatus {
        var status = HarnessStatus(id: id)
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let executable = HarnessCatalog.executable(for: id) else {
            // Gemini keeps its creds even when the binary isn't on this PATH.
            status.detail = id == "t3" ? "Open T3 Code once to install its t3 command." : "\(HarnessCatalog.label(id)) isn't installed."
            return status
        }
        status.installed = true
        status.path = executable.path
        if id != "t3" {
            // "2.1.312 (Claude Code)", "codex-cli 0.165.0", "grok 1.0.70 (f50904e)": the part with the digits.
            let first = HarnessCatalog.output(of: executable, ["--version"], timeout: 8, merge: false).split(separator: "\n").first.map(String.init) ?? ""
            status.version = first.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init)
        }
        switch id {
        case "t3":
            status.account = ClaudiaT3Integration.t3Apps.first.map { $0.deletingPathExtension().lastPathComponent }
            status.loggedIn = true
        case "claude":
            let text = HarnessCatalog.output(of: executable, ["auth", "status"], timeout: 15, merge: false)
            if let object = jsonObject(in: text) {
                status.loggedIn = object["loggedIn"] as? Bool
                let email = object["email"] as? String
                let plan = (object["subscriptionType"] as? String).map { "\($0) plan" }
                    ?? (object["authMethod"] as? String)
                status.account = [email, plan].compactMap { $0 }.joined(separator: " · ")
            }
        case "codex":
            let text = HarnessCatalog.output(of: executable, ["login", "status"], timeout: 15)
            let lower = text.lowercased()
            status.loggedIn = lower.contains("logged in") && !lower.contains("not logged in")
            var parts: [String] = []
            if lower.contains("chatgpt") { parts.append("ChatGPT") } else if lower.contains("api key") { parts.append("API key") }
            if let claims = codexClaims(home: home) {
                if let email = claims["email"] as? String { parts.append(email) }
                if let auth = claims["https://api.openai.com/auth"] as? [String: Any], let plan = auth["chatgpt_plan_type"] as? String {
                    parts.append("\(plan) plan")
                }
            }
            status.account = parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "cursor":
            // `status` says "Login successful" even when the session has expired; `about` shows the real account.
            let about = HarnessCatalog.output(of: executable, ["about"], timeout: 20)
            var email: String?
            var tier: String?
            for line in about.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("User Email") { email = text.dropFirst("User Email".count).trimmingCharacters(in: .whitespaces) }
                if text.hasPrefix("Subscription Tier") { tier = text.dropFirst("Subscription Tier".count).trimmingCharacters(in: .whitespaces) }
            }
            if let email {
                status.loggedIn = !email.lowercased().contains("not logged in")
                if status.loggedIn == true {
                    status.account = [email, tier.flatMap { $0.lowercased() == "unknown" ? nil : $0 }].compactMap { $0 }.joined(separator: " · ")
                } else {
                    status.detail = "Sign in with `cursor-agent login`."
                }
            } else {
                let text = HarnessCatalog.output(of: executable, ["status"], timeout: 20).lowercased()
                status.loggedIn = text.contains("logged in") && !text.contains("not logged in") && !text.contains("authentication required")
            }
        case "grok":
            // `grok models` prints "You are logged in with grok.com." and the model list.
            let text = HarnessCatalog.output(of: executable, ["models"], timeout: 15)
            if text.lowercased().contains("logged in") {
                status.loggedIn = !text.lowercased().contains("not logged in")
                status.account = text.split(separator: "\n").first { $0.lowercased().contains("logged in") }
                    .map { $0.replacingOccurrences(of: "You are logged in with ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            }
        case "opencode":
            let auth = home.appendingPathComponent(".local/share/opencode/auth.json")
            if let data = try? Data(contentsOf: auth), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty {
                status.account = object.keys.sorted().joined(separator: ", ")
            }
            status.detail = "Free models, no sign-in needed"
        case "gemini":
            let creds = FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/oauth_creds.json").path)
            let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil
            status.loggedIn = creds || key
            status.account = creds ? "Google account" : (key ? "API key" : nil)
            if status.loggedIn != true { status.detail = "Sign in with Google, or use an API key" }
        default:
            break
        }
        return status
    }

    /// Gemini creds present without the binary (so Setup can say "installed? no, but signed in").
    static func geminiCredsPresent() -> Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json").path)
    }

    private static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
    }

    /// The ID token's claims in ~/.codex/auth.json (email, plan), without verifying anything.
    private static func codexClaims(home: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex/auth.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any], let token = tokens["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let decoded = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
    }
}

// MARK: - Models

enum HarnessModels {
    /// Codex's visible models from its cache, with the efforts each supports.
    static func codex() -> (models: [HarnessModel], efforts: [String: [String]]) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["models"] as? [[String: Any]] else { return ([], [:]) }
        var models: [HarnessModel] = []
        var efforts: [String: [String]] = [:]
        for entry in list where (entry["visibility"] as? String) != "hide" {
            guard let slug = entry["slug"] as? String else { continue }
            models.append(HarnessModel(id: slug, label: entry["display_name"] as? String ?? slug))
            if let levels = entry["supported_reasoning_levels"] as? [[String: Any]] {
                efforts[slug] = levels.compactMap { $0["effort"] as? String }
            }
        }
        return (models, efforts)
    }

    /// `cursor-agent --list-models` lines: "id - Label" (a trailing "(current)" / "(default)" is kept in the label).
    static func parseCursor(listing: String) -> [HarnessModel] {
        guard let regex = try? NSRegularExpression(pattern: #"^([a-z0-9][\w.\-\[\]=,]*)\s+-\s+(.+)$"#) else { return [] }
        var models: [HarnessModel] = []
        for raw in listing.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 3,
                  let idRange = Range(match.range(at: 1), in: line), let labelRange = Range(match.range(at: 2), in: line) else { continue }
            models.append(HarnessModel(id: String(line[idRange]), label: String(line[labelRange])))
        }
        return models
    }

    static var cacheURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Theo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("models.json")
    }

    struct Cache: Codable {
        var fetchedAt: Date
        var cursor: [HarnessModel]
    }

    static func readCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cache.self, from: data)
    }

    static func writeCache(_ cache: Cache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }

    /// Runs `cursor-agent --list-models` (45 s limit).
    static func fetchCursor(executable: URL) -> [HarnessModel] {
        parseCursor(listing: HarnessCatalog.output(of: executable, ["--list-models"], timeout: 45, merge: false))
    }

    static func opencode(executable: URL) -> [HarnessModel] {
        BrainModelCatalog.openCodeModels(listing: HarnessCatalog.output(of: executable, ["models"], timeout: 20, merge: false))
            .map { HarnessModel(id: $0, label: $0) }
    }
}

// MARK: - Preferences

/// The user's choices, readable from any thread. HarnessCenter publishes changes to them.
enum HarnessPrefs {
    private static var defaults: UserDefaults { .standard }

    /// The harness new bots start on, and the one Setup picks.
    static var defaultHarness: String {
        get { defaults.string(forKey: "theo.harness.default") ?? "claude" }
        set { defaults.set(newValue, forKey: "theo.harness.default") }
    }
    static func defaultModel(_ harness: String) -> String? {
        defaults.string(forKey: "theo.harness.model.\(harness)").flatMap { $0.isEmpty ? nil : $0 }
    }
    static func setDefaultModel(_ model: String?, for harness: String) { defaults.set(model, forKey: "theo.harness.model.\(harness)") }
    static func defaultEffort(_ harness: String) -> String? {
        defaults.string(forKey: "theo.harness.effort.\(harness)").flatMap { $0.isEmpty ? nil : $0 }
    }
    static func setDefaultEffort(_ effort: String?, for harness: String) { defaults.set(effort, forKey: "theo.harness.effort.\(harness)") }

    /// Run this harness on the saved API key instead of its subscription sign-in.
    static func usesAPIKey(_ harness: String) -> Bool { defaults.bool(forKey: "theo.harness.apiKey.\(harness)") }
    static func setUsesAPIKey(_ on: Bool, for harness: String) { defaults.set(on, forKey: "theo.harness.apiKey.\(harness)") }

    /// Where the coding hand-off goes: t3 (default), claude, codex, cursor, opencode, grok or gemini.
    static var codingTarget: String {
        get { defaults.string(forKey: "theo.coding.target") ?? "t3" }
        set {
            // A model belongs to one harness: passing it to another makes that harness refuse to start.
            if newValue != codingTarget {
                defaults.removeObject(forKey: "theo.coding.model")
                defaults.removeObject(forKey: "theo.coding.effort")
            }
            defaults.set(newValue, forKey: "theo.coding.target")
        }
    }
    static var codingModel: String? {
        get { defaults.string(forKey: "theo.coding.model").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "theo.coding.model") }
    }
    static var codingEffort: String? {
        get { defaults.string(forKey: "theo.coding.effort").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "theo.coding.effort") }
    }
}

// MARK: - Center

@MainActor
final class HarnessCenter: ObservableObject {
    static let shared = HarnessCenter()

    @Published private(set) var statuses: [String: HarnessStatus] = [:]
    /// Models per harness id (Gemini and T3 Code: empty, the UI offers free text / T3's own default).
    @Published private(set) var models: [String: [HarnessModel]] = [
        "claude": HarnessCatalog.claudeModels, "grok": HarnessCatalog.grokModels,
    ]
    /// Efforts per Codex model id, as Codex's cache lists them.
    @Published private(set) var codexEfforts: [String: [String]] = [:]
    @Published private(set) var isRefreshing = false
    /// Harnesses being re-checked one at a time.
    @Published private(set) var checking: Set<String> = []
    private var lastRefresh: Date?

    private init() {
        if let cache = HarnessModels.readCache() { models["cursor"] = cache.cursor }
        let codex = HarnessModels.codex()
        if !codex.models.isEmpty { models["codex"] = codex.models; codexEfforts = codex.efforts }
    }

    // MARK: Reading

    func status(for harness: String) -> HarnessStatus { statuses[harness] ?? HarnessStatus(id: harness) }
    func models(for harness: String) -> [HarnessModel] { models[harness] ?? [] }
    /// Harnesses that are installed and not signed out.
    var readyHarnesses: [HarnessInfo] { HarnessCatalog.all.filter { status(for: $0.id).ready } }

    /// Efforts to offer for a harness and model (Codex: that model's own list).
    func efforts(for harness: String, model: String?) -> [String] {
        if harness == "codex", let model, let list = codexEfforts[model], !list.isEmpty { return list }
        return HarnessCatalog.info(harness)?.efforts ?? []
    }

    /// The model a new bot / run on this harness starts with: the user's default, else the harness's first.
    func resolvedModel(for harness: String) -> String? {
        if let chosen = HarnessPrefs.defaultModel(harness) { return chosen }
        return models(for: harness).first?.id
    }

    // MARK: Defaults (published)

    var defaultHarness: String {
        get { HarnessPrefs.defaultHarness }
        set { objectWillChange.send(); HarnessPrefs.defaultHarness = newValue }
    }
    func defaultModel(for harness: String) -> String? { HarnessPrefs.defaultModel(harness) }
    func setDefaultModel(_ model: String?, for harness: String) { objectWillChange.send(); HarnessPrefs.setDefaultModel(model, for: harness) }
    func defaultEffort(for harness: String) -> String? { HarnessPrefs.defaultEffort(harness) }
    func setDefaultEffort(_ effort: String?, for harness: String) { objectWillChange.send(); HarnessPrefs.setDefaultEffort(effort, for: harness) }

    func usesAPIKey(_ harness: String) -> Bool { HarnessPrefs.usesAPIKey(harness) }
    func setUsesAPIKey(_ on: Bool, for harness: String) { objectWillChange.send(); HarnessPrefs.setUsesAPIKey(on, for: harness) }

    /// Re-checks one harness (after a sign-in or install) without touching the others.
    func recheck(_ harness: String) {
        checking.insert(harness)
        Task.detached(priority: .userInitiated) {
            _ = HarnessCatalog.searchDirectories
            let status = HarnessDetector.status(for: harness)
            await MainActor.run {
                self.statuses[harness] = status
                self.checking.remove(harness)
            }
        }
    }

    var codingTarget: String {
        get { HarnessPrefs.codingTarget }
        set { objectWillChange.send(); HarnessPrefs.codingTarget = newValue }
    }
    var codingModel: String? {
        get { HarnessPrefs.codingModel }
        set { objectWillChange.send(); HarnessPrefs.codingModel = newValue }
    }
    var codingEffort: String? {
        get { HarnessPrefs.codingEffort }
        set { objectWillChange.send(); HarnessPrefs.codingEffort = newValue }
    }

    // MARK: Refreshing

    /// Detects every harness and reloads the model lists in the background. Skipped when run less than a
    /// minute ago unless `force`.
    func refresh(force: Bool = false) {
        if isRefreshing { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        lastRefresh = Date()
        isRefreshing = true
        let cachedCursorAge = HarnessModels.readCache().map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
        Task.detached(priority: .utility) {
            _ = HarnessCatalog.searchDirectories // login-shell PATH, once
            let ids = HarnessCatalog.all.map(\.id)
            let found = await withTaskGroup(of: HarnessStatus.self) { group -> [String: HarnessStatus] in
                for id in ids { group.addTask { HarnessDetector.status(for: id) } }
                var all: [String: HarnessStatus] = [:]
                for await status in group { all[status.id] = status }
                return all
            }
            // A gemini sign-in without the binary on PATH still gets reported.
            let codex = HarnessModels.codex()
            var cursorModels: [HarnessModel]?
            if let cursor = HarnessCatalog.executable(for: "cursor"), found["cursor"]?.loggedIn == true,
               force || cachedCursorAge > 6 * 3600 {
                let fetched = HarnessModels.fetchCursor(executable: cursor)
                if !fetched.isEmpty {
                    cursorModels = fetched
                    HarnessModels.writeCache(.init(fetchedAt: Date(), cursor: fetched))
                }
            }
            var opencodeModels: [HarnessModel] = []
            if let opencode = HarnessCatalog.executable(for: "opencode") { opencodeModels = HarnessModels.opencode(executable: opencode) }
            await MainActor.run {
                self.statuses = found
                if !codex.models.isEmpty { self.models["codex"] = codex.models; self.codexEfforts = codex.efforts }
                if let cursorModels { self.models["cursor"] = cursorModels }
                // BrainCatalog's OpenCode list (loaded by Setup) wins when it has one.
                let brain = BrainCatalog.shared.models[.opencode] ?? []
                if !brain.isEmpty {
                    self.models["opencode"] = brain.map { HarnessModel(id: $0, label: $0) }
                } else if !opencodeModels.isEmpty {
                    self.models["opencode"] = opencodeModels
                }
                self.isRefreshing = false
            }
        }
    }
}
