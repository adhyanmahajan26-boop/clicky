import Foundation

/// The rules behind the model selector: which effort levels a model takes on an engine, the words for each level,
/// a short line about each model, and what the composer's chip says. Pure, so the Mac's selector and its tests agree.
public enum ModelEffort {
    /// Claude Code's `--effort` levels.
    public static let claudeLevels = ["low", "medium", "high", "xhigh", "max"]
    /// OpenCode's `--variant` levels.
    public static let openCodeLevels = ["minimal", "low", "medium", "high", "max"]
    /// Grok's `--reasoning-effort` levels.
    public static let grokLevels = ["low", "medium", "high"]

    /// The effort levels to offer for `model` on `engine`. `engineListed` is what the engine's own catalogue says
    /// (Codex lists them per model); it's used for engines whose levels aren't fixed here. Empty means the engine or
    /// model has no effort setting, so the selector hides the row instead of showing a control that does nothing.
    public static func levels(engine: String, model: String, engineListed: [String]) -> [String] {
        if engine.hasPrefix("api:") { return [] }
        switch engine {
        case "claude":
            // Haiku is the quick, cheap model: Claude Code has no effort dial for it.
            return model.lowercased().contains("haiku") ? [] : claudeLevels
        case "opencode": return openCodeLevels
        case "grok": return grokLevels
        case "cursor", "gemini": return []
        default: return engineListed
        }
    }

    /// The effort a bot keeps after its model or engine changes: the same level when the new model takes it, else
    /// the engine's default (nil).
    public static func carriedOver(effort: String?, toLevels levels: [String]) -> String? {
        guard let effort, !effort.isEmpty, levels.contains(effort) else { return nil }
        return effort
    }

    /// The button word for a level.
    public static func title(for level: String) -> String {
        switch level.lowercased() {
        case "": return "Auto"
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        case "max": return "Max"
        default: return level.capitalized
        }
    }

    /// The short word on the composer's chip.
    public static func shortTitle(for level: String) -> String {
        level.lowercased() == "xhigh" ? "X-high" : title(for: level)
    }

    /// One line under the levels saying what the chosen one does.
    public static func hint(for level: String?) -> String {
        switch (level ?? "").lowercased() {
        case "": return "The model decides how long to think. Right for most chats."
        case "minimal": return "Answers straight away with almost no thinking. Fastest."
        case "low": return "Quick answers, light thinking. Good for simple asks."
        case "medium": return "Thinks a little before answering. A good everyday level."
        case "high": return "Thinks it through. Slower, better on harder problems."
        case "xhigh": return "Thinks for longer still. Uses more of your plan."
        case "max": return "The deepest thinking it has. Slowest, and uses the most of your plan."
        default: return "Applies from the next reply."
        }
    }

    /// A few words about a model, shown under its name in the list, or nil when there's nothing useful to say.
    public static func modelHint(engine: String, model: String) -> String? {
        let lower = model.lowercased()
        if lower.contains("opus") { return "Most capable, slower" }
        if lower.contains("sonnet") { return "Best balance of speed and smarts" }
        if lower.contains("haiku") { return "Fastest and lightest on your plan" }
        if lower.hasSuffix("-free") || lower.contains(":free") { return "Free" }
        if lower.contains("mini") || lower.contains("flash") || lower.contains("fast") { return "Fast and light" }
        if lower.contains("codex") { return "Tuned for code" }
        return nil
    }

    /// What the composer's chip reads: the model without its maker's name, then the effort when one is set.
    public static func chipLabel(modelLabel: String, effort: String?, levels: [String]) -> String {
        var name = modelLabel
        for maker in ["Claude ", "OpenAI ", "Google "] where name.hasPrefix(maker) { name = String(name.dropFirst(maker.count)) }
        if name.isEmpty { name = "Default model" }
        guard !levels.isEmpty, let effort, !effort.isEmpty, levels.contains(effort) else { return name }
        return "\(name) · \(shortTitle(for: effort))"
    }
}

/// How a subscription (a signed-in coding agent) or a saved API key looks in the selector's left column.
public enum BrainSourceState: Equatable {
    case signedIn(account: String?)
    case ready
    case onAPIKey
    case signedOut
    case notInstalled
    case checking

    /// A bot can be moved to it now.
    public var isUsable: Bool {
        switch self {
        case .signedIn, .ready, .onAPIKey: return true
        case .signedOut, .notInstalled, .checking: return false
        }
    }

    /// The small line under its name.
    public var caption: String {
        switch self {
        case .signedIn(let account): return account.map { $0.isEmpty ? "Signed in" : $0 } ?? "Signed in"
        case .ready: return "Ready"
        case .onAPIKey: return "On your API key"
        case .signedOut: return "Not signed in"
        case .notInstalled: return "Not installed"
        case .checking: return "Checking…"
        }
    }

    /// Reads a harness check the way the Harnesses page does.
    public static func of(checked: Bool, installed: Bool, loggedIn: Bool?, account: String?, usesAPIKey: Bool) -> BrainSourceState {
        if !checked { return .checking }
        if !installed { return .notInstalled }
        if usesAPIKey { return .onAPIKey }
        switch loggedIn {
        case true?: return .signedIn(account: account)
        case false?: return .signedOut
        case nil: return .ready
        }
    }
}
