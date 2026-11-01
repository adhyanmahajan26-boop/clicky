import Foundation

/// The owner asking a bot, in chat, to change how it runs: "switch to haiku", "what model are you on", "turn on thinking",
/// "change your schedule". The bot answers with a settings card, not words about settings. Anything longer or about
/// something else ("change the model in my database", "use haiku to write a poem") stays an ordinary message.
public struct BotSettingsIntent: Equatable, Sendable {
    /// "haiku", "sonnet", "opus" or "fable".
    public var model: String?
    /// A harness id: "claude", "codex", "cursor", "grok", "gemini", "opencode".
    public var engine: String?
    public var effort: String?
    public var thinking: Bool?
    public var fast: Bool?

    public init(model: String? = nil, engine: String? = nil, effort: String? = nil, thinking: Bool? = nil, fast: Bool? = nil) {
        self.model = model
        self.engine = engine
        self.effort = effort
        self.thinking = thinking
        self.fast = fast
    }

    public static func parse(_ text: String) -> BotSettingsIntent? {
        var words = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = words.last, ".!?,".contains(last) { words.removeLast() }
        words = words.replacingOccurrences(of: #"^(hey|ok|okay|please|can you|could you|would you)\s+"#, with: "", options: .regularExpression)
        words = words.replacingOccurrences(of: #"\s+(please|now|instead|for now|from now on)$"#, with: "", options: .regularExpression)
        guard !words.isEmpty, words.split(separator: " ").count <= 12, !words.contains("\n") else { return nil }

        let models = "haiku|sonnet|opus|fable"
        let engines = "claude code|claude|codex|cursor|grok|gemini|open code|opencode"
        let efforts = "low|medium|high|xhigh|max"
        let verb = "change|switch|set|update|edit|adjust|pick|choose|move|put"

        func captured(_ pattern: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)),
                  match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: words) else { return nil }
            return String(words[range])
        }
        func matches(_ pattern: String) -> Bool { words.range(of: pattern, options: .regularExpression) != nil }

        // "switch to haiku", "use opus", "run on codex", "change your model to sonnet 5.5"
        let choice = "^(?:\(verb)|use|run|go|try)\\b(?: (?:yourself|your model|your engine|your brain|the model|the engine|model|engine))?(?: (?:to|on|with|over to))? (?:claude )?(\(models)|\(engines))(?: [0-9.]+)?$"
        if let picked = captured(choice) {
            if ["haiku", "sonnet", "opus", "fable"].contains(picked) { return BotSettingsIntent(model: picked) }
            return BotSettingsIntent(engine: engineID(picked))
        }
        // "set your effort to high", "use high effort"
        if let effort = captured("^(?:\(verb)|use)(?: (?:your|the))?(?: effort)?(?: to)? (\(efforts))(?: effort)?$"), words.contains("effort") {
            return BotSettingsIntent(effort: effort)
        }
        // "turn on thinking", "turn fast mode off", "thinking on"
        if let state = captured(#"^(?:turn )?(on|off)(?: your| the)? thinking$"#) ?? captured(#"^(?:turn )?(?:your |the )?thinking (on|off)$"#) {
            return BotSettingsIntent(thinking: state == "on")
        }
        if let state = captured(#"^(?:turn )?(on|off)(?: your| the)? fast(?: mode)?$"#) ?? captured(#"^(?:turn )?(?:your |the )?fast(?: mode)? (on|off)$"#) {
            return BotSettingsIntent(fast: state == "on")
        }
        // "change your model", "change the schedule", "edit your settings"
        let setting = "(?:model|engine|brain|effort|schedule|schedules|routine|routines|settings)"
        if matches("^(?:\(verb)|show|open|see)(?: me)?(?: your| the| this bot's| my)? \(setting)$") { return BotSettingsIntent() }
        // "settings", "your settings", "what model are you on", "which engine are you using", "what's your schedule"
        if matches(#"^(?:your |bot )?settings$"#) { return BotSettingsIntent() }
        if matches("^(?:what|which)(?: is|'s| are)?(?: your| the)? \(setting)(?: are you| do you| is this| is it| you're)?(?: on| using| running on| run on| have| set to)?$") { return BotSettingsIntent() }
        if matches(#"^what are you (?:running on|using|on)$"#) { return BotSettingsIntent() }
        return nil
    }

    private static func engineID(_ word: String) -> String {
        switch word {
        case "claude code", "claude": return "claude"
        case "open code", "opencode": return "opencode"
        default: return word
        }
    }
}
