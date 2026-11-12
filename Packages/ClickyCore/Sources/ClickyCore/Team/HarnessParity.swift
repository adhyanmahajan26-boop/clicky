import Foundation

// What a harness like Hermes or OpenClaw does that Theo's bots now do too, kept here as pure logic so it can be tested:
// engine failover, skills (procedural memory), memory in the prompt with a cap, chat recall, quiet routine runs and
// a catch-up window for routines missed while Theo was closed.

// MARK: Engine failover

/// What an engine's error says, for deciding whether to try again, try another model, or stop.
public enum EngineFailure: Equatable, Sendable {
    /// Overloaded, rate-limited, a 5xx or a dropped connection: likely gone in a few seconds.
    case transient
    /// The model itself isn't there (unknown, retired, no access to it): retrying it won't help, another model might.
    case modelUnavailable
    /// Signed out, a bad key, no subscription: no model on this engine will work, so nothing is retried.
    case auth
    /// Anything else (a bad prompt, a crash, a lost session): not Theo's to retry.
    case other

    public static func classify(_ text: String) -> EngineFailure {
        let lower = text.lowercased()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        // Sign-in first: "401" or "please run /login" beats an "error" that also mentions overloading.
        if has(#"invalid api key|invalid x-api-key|authentication_error|please run /login|not logged in|unauthori[sz]ed|\b401\b|oauth token (has )?expired|credit balance is too low|permission_error|\b403\b"#) {
            return .auth
        }
        if has(#"model[^\n]{0,60}(not found|does not exist|isn't available|is not available|not supported|retired|deprecated)|not_found_error[^\n]{0,80}model|unknown model|invalid model|no such model|model_not_found|there's an issue with the selected model|may not exist or you may not have access"#) {
            return .modelUnavailable
        }
        if has(#"overloaded|\b529\b|\b429\b|rate.?limit|too many requests|\b50[0234]\b|internal server error|bad gateway|service unavailable|gateway time-?out|api_error|econnreset|etimedout|socket hang up|connection (reset|refused|error)|network error|fetch failed|request timed out|temporarily unavailable"#) {
            return .transient
        }
        return .other
    }
}

/// How a bot's turn is retried and moved to other models when its engine fails. Same model first, then the chain, never on a sign-in problem.
public struct EngineFailoverPlan: Equatable, Sendable {
    public struct Attempt: Equatable, Sendable {
        public var model: String
        /// Seconds to wait before this attempt.
        public var delay: Double
        public var isFallback: Bool
    }

    /// Delays before each retry of the same model.
    public var retryDelays: [Double]
    /// Other models to try, in order, once the bot's own model has failed.
    public var fallbacks: [String]

    public static let defaultRetryDelays: [Double] = [3, 10]
    /// Claude Code models, strongest first. A bot whose model fails moves along this list, skipping its own.
    public static let defaultClaudeChain = ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"]

    public init(retryDelays: [Double] = EngineFailoverPlan.defaultRetryDelays, fallbacks: [String]) {
        self.retryDelays = retryDelays
        self.fallbacks = fallbacks
    }

    /// The chain for a bot on `model`: the configured list (or the default), without the bot's own model or repeats.
    public static func chain(for model: String, configured: [String]?) -> [String] {
        var seen: Set<String> = [model.lowercased()]
        return (configured?.isEmpty == false ? configured! : defaultClaudeChain)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// What to do after `failure` on attempt number `attempt` (0 = the first try) of `model`. Nil: stop and show the error.
    public func next(after failure: EngineFailure, model: String, attempt: Int, fallbackIndex: Int?) -> Attempt? {
        switch failure {
        case .auth, .other:
            return nil
        case .transient where fallbackIndex == nil && attempt < retryDelays.count:
            return Attempt(model: model, delay: retryDelays[attempt], isFallback: false)
        case .transient, .modelUnavailable:
            let index = (fallbackIndex ?? -1) + 1
            guard index < fallbacks.count else { return nil }
            return Attempt(model: fallbacks[index], delay: failure == .transient ? 1 : 0, isFallback: true)
        }
    }

    /// The line added under a reply that came from another model.
    public static func fallbackNote(from original: String, to used: String, reason: EngineFailure) -> String {
        let why = reason == .modelUnavailable ? "wasn't available" : "kept failing (overloaded or rate-limited)"
        return "_(\(original) \(why), so this reply came from \(used).)_"
    }
}

// MARK: Skills

/// A skill: a step-by-step procedure saved as `skills/<name>/SKILL.md`, the same layout Hermes, OpenClaw and agentskills.io use.
public struct BotSkill: Equatable, Sendable {
    public var name: String
    public var description: String
    public var path: String
    /// The bot that wrote it, or nil for one in the shared folder.
    public var author: String?

    public init(name: String, description: String, path: String, author: String?) {
        self.name = name
        self.description = description
        self.path = path
        self.author = author
    }

    /// Reads the `---` front matter's `name` and `description`. Nil when there's no description, which a skill needs to be found.
    public static func parse(_ text: String, path: String, author: String?, folderName: String) -> BotSkill? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var name: String?
        var description: String?
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" { break }
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
                if key == "name", !value.isEmpty { name = value }
                if key == "description", !value.isEmpty { description = value }
            }
        }
        guard let description else { return nil }
        let cleanName = (name ?? folderName).replacingOccurrences(of: "\n", with: " ")
        return BotSkill(name: String(cleanName.prefix(64)), description: String(description.replacingOccurrences(of: "\n", with: " ").prefix(240)), path: path, author: author)
    }
}

public enum BotSkillsPrompt {
    /// At most this many skills are listed in a prompt; the rest are found with Glob.
    public static let listed = 40

    /// The skills section of a bot's persona: what there is, and how to use and write them.
    public static func section(skills: [BotSkill], ownFolder: String, sharedFolder: String, botName: String, owner: String) -> String {
        var text = "Skills: saved step-by-step procedures, yours and other bots'. Before a task that matches one, Read its SKILL.md and follow it; " +
            "say so if you had to depart from it."
        if skills.isEmpty {
            text += " There are none yet."
        } else {
            let sorted = skills.sorted { ($0.author == nil ? 0 : 1, $0.name.lowercased()) < ($1.author == nil ? 0 : 1, $1.name.lowercased()) }
            let shown = sorted.prefix(listed).map { skill -> String in
                let by = skill.author.map { $0 == botName ? " (yours)" : " (by \($0))" } ?? ""
                return "- \(skill.name)\(by): \(skill.description) [\(skill.path)]"
            }
            text += "\n" + shown.joined(separator: "\n")
            if skills.count > listed { text += "\n- …and \(skills.count - listed) more: Glob \(sharedFolder)/**/SKILL.md and the skills folders beside it." }
        }
        text += "\n" + writeHowTo(ownFolder: ownFolder, owner: owner)
        return text
    }

    /// How to save one. Bots write only in their own folder, so their skills go there, and every bot sees them in this list.
    public static func writeHowTo(ownFolder: String, owner: String) -> String {
        "When \(owner) asks you to keep a procedure, or you've just worked out a multi-step job that will come up again, save it as a skill: write " +
        "\(ownFolder)/<short-name>/SKILL.md starting with a front matter block (a line ---, then name: <short-name>, then description: <one line on when to use it>, then ---), " +
        "followed by the steps, any pitfalls, and how to check it worked. Keep secrets out. When you learn a better way, update the skill rather than writing a second one."
    }
}

// MARK: Memory in the prompt

public enum BotMemoryPrompt {
    /// Characters of a bot's memory that go into every prompt. Hermes keeps 2,200 for its notes; Theo's bots keep their facts in one file.
    public static let limit = 4_000

    /// The memory section of a bot's persona, with the file's contents in it so nothing depends on the bot choosing to read it.
    /// Over the limit, the start (the oldest, usually most basic facts) and the newest lines go in, and the bot is told to tidy the file.
    public static func section(_ text: String, path: String, limit: Int = BotMemoryPrompt.limit) -> String {
        let memory = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let howTo = "Add one short line to it when you learn a lasting preference or fact; don't store secrets."
        guard !memory.isEmpty else {
            return "Your memory file is \(path). It's empty so far. " + howTo
        }
        let count = memory.count
        let percent = Int((Double(count) / Double(limit) * 100).rounded())
        guard count > limit else {
            return "Your memory (\(path), \(count)/\(limit) characters, \(percent)% full), as it is now:\n<memory>\n\(memory)\n</memory>\n" + howTo +
                (percent >= 80 ? " It's nearly full: merge or drop stale lines when you add one." : "")
        }
        let headLength = limit / 3
        let tailLength = limit - headLength
        var head = String(memory.prefix(headLength))
        if let cut = head.lastIndex(of: "\n") { head = String(head[..<cut]) }
        var tail = String(memory.suffix(tailLength))
        if let cut = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: cut)...]) }
        let left = count - head.count - tail.count
        return "Your memory (\(path), \(count) characters, over its \(limit)-character limit), the start and the newest lines:\n<memory>\n\(head)\n" +
            "[… \(left) characters not shown …]\n\(tail)\n</memory>\n" +
            "Before anything else this turn, rewrite that file under \(limit) characters: merge duplicates, drop what's stale, keep what still matters. " + howTo
    }
}

public enum BotRecallPrompt {
    /// Where a bot can look up what was said before its engine session began, or before it was cut short.
    public static func section(chatFile: String, owner: String) -> String {
        "Everything said in your chat with \(owner) is saved in \(chatFile). When \(owner) mentions something from earlier that you don't have in front of you, " +
        "Grep that file for it before saying you don't know."
    }
}

// MARK: Routines

public enum RoutineQuiet {
    /// The answer that means "nothing to report": the run is recorded and nothing is posted. Hermes uses [SILENT] and NO_REPLY.
    public static let marker = "[SILENT]"

    public static func isQuiet(_ answer: String?) -> Bool {
        guard let answer else { return false }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "`*_.")).uppercased()
        return trimmed == "[SILENT]" || trimmed == "SILENT" || trimmed == "NO_REPLY" || trimmed == "[NO_REPLY]"
    }

    public static func howTo(owner: String) -> String {
        "If this run is a check and nothing has changed that's worth \(owner)'s attention, answer with exactly \(marker) and nothing else: " +
        "nothing is posted. Never answer \(marker) when the job is to deliver something (a brief, a report, a summary)."
    }
}

public enum RoutineCatchUp {
    /// How late a missed slot may still run: half the routine's period, at least 2 minutes and at most 2 hours (Hermes's rule).
    public static func window(periodSeconds: Double) -> Double {
        min(7_200, max(120, periodSeconds / 2))
    }

    public enum Decision: Equatable { case notYet, fire, missed }

    public static func decide(due: Date, now: Date, periodSeconds: Double) -> Decision {
        let late = now.timeIntervalSince(due)
        if late < 0 { return .notYet }
        return late <= window(periodSeconds: periodSeconds) ? .fire : .missed
    }
}
