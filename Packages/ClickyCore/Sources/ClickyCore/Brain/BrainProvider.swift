//
//  BrainProvider.swift
//  ClickyCore
//
//  The brain switch: Clicky can think with any model the owner's
//  subscriptions give them, through the same command-line agents T3 Code
//  drives: Claude Code (Claude plan), Codex (ChatGPT plan), Cursor Agent
//  (Cursor plan) and OpenCode (any provider it's set up with, including
//  local LM Studio models). A model setting carries its provider as a
//  prefix ("codex:gpt-6-luna", "opencode:lmstudio/qwen/qwen3.8-27b");
//  plain ids ("claude-sonnet-5-5") are Claude. Claude keeps Clicky's
//  streaming stream-json path; the others run one turn per process and
//  their answer comes back as text with the same tags.
//

import Foundation

public enum BrainProvider: String, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case opencode
    /// The owner's own API key, straight over HTTP: "api:<provider id>/<model>". Not a command-line agent, so it
    /// isn't in `allCases` (the agent pickers and sign-in checks).
    case api

    public static var allCases: [BrainProvider] { [.claude, .codex, .cursor, .opencode] }

    public var displayName: String {
        switch self {
        case .claude: return "Claude (Claude Code)"
        case .codex: return "ChatGPT (Codex)"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .api: return "API key"
        }
    }

    /// The CLI's name on PATH (T3 Code's default binaryPath for the same driver).
    public var executableName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cursor: return "cursor-agent"
        case .opencode: return "opencode"
        case .api: return ""
        }
    }

    /// How the owner signs in, shown when the CLI says it isn't.
    public var signInCommand: String {
        switch self {
        case .claude: return "claude auth login"
        case .codex: return "codex login"
        case .cursor: return "cursor-agent login"
        case .opencode: return "opencode auth login"
        case .api: return "Settings › Models & API keys"
        }
    }
}

/// A model setting split into provider and the provider's own model id.
public struct BrainModel: Equatable, Sendable {
    public var provider: BrainProvider
    public var modelIdentifier: String

    public init(provider: BrainProvider, modelIdentifier: String) {
        self.provider = provider
        self.modelIdentifier = modelIdentifier
    }

    /// "codex:gpt-6-luna" → (codex, gpt-6-luna); anything without a known prefix is Claude.
    public init(setting: String) {
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = trimmed.firstIndex(of: ":"), let provider = BrainProvider(rawValue: String(trimmed[..<colon]).lowercased()),
           provider != .claude {
            self.provider = provider
            self.modelIdentifier = String(trimmed[trimmed.index(after: colon)...])
        } else {
            self.provider = .claude
            self.modelIdentifier = trimmed.hasPrefix("claude:") ? String(trimmed.dropFirst("claude:".count)) : trimmed
        }
    }

    /// The value stored in settings.
    public var setting: String { provider == .claude ? modelIdentifier : "\(provider.rawValue):\(modelIdentifier)" }

    public var isClaude: Bool { provider == .claude }

    /// OpenCode's free cloud models send the request (screenshots included) to whoever hosts them.
    public var sendsScreenshotsToThirdParty: Bool {
        if provider == .api { return !modelIdentifier.hasPrefix("ollama/") && !modelIdentifier.hasPrefix("lmstudio/") }
        return provider == .opencode && !modelIdentifier.hasPrefix("lmstudio/") && !modelIdentifier.hasPrefix("mlxserve/") && !modelIdentifier.hasPrefix("ollama/")
    }
}

/// Builds each non-Claude CLI's one-turn command and reads its JSON output.
public enum BrainCLI {
    /// The prompt for CLIs without a system-prompt flag: the instructions first, clearly fenced.
    public static func combinedPrompt(systemPrompt: String, userText: String) -> String {
        """
        <clicky_instructions>
        \(systemPrompt)
        </clicky_instructions>

        follow the instructions above exactly (they define your output format, tags included). \
        the screenshots attached to this message are the user's screens, in order (screen1, screen2, …). \
        you have no tools in this run and must not try to use any: Clicky itself opens apps, searches, clicks, types and reads \
        articles when your reply contains the tags and blocks described above, so answer only with that reply text.

        \(userText)
        """
    }

    /// Arguments after the executable. The prompt goes on stdin for Codex ("-"), as an argument for the others.
    public static func arguments(for model: BrainModel, imagePaths: [String], workingDirectory: String, prompt: String) -> (arguments: [String], stdinPrompt: String?) {
        switch model.provider {
        case .claude, .api:
            return ([], nil)
        case .codex:
            // Codex's own tools (browser, computer use, shell, apps, plugins) are off: Clicky acts through its
            // own tags, and Codex reaching for Chrome itself got "chrome access was blocked" instead of an answer.
            var arguments = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                             "-s", "read-only", "-C", workingDirectory, "-c", "web_search=\"disabled\""]
            for feature in codexDisabledFeatures { arguments += ["--disable", feature] }
            if !model.modelIdentifier.isEmpty { arguments += ["-m", model.modelIdentifier] }
            for imagePath in imagePaths { arguments += ["--image", imagePath] }
            arguments.append("-")
            return (arguments, prompt)
        case .cursor:
            var arguments = ["-p", "--output-format", "stream-json", "--stream-partial-output", "--trust", "--workspace", workingDirectory]
            if !model.modelIdentifier.isEmpty { arguments += ["--model", model.modelIdentifier] }
            // Cursor Agent has no image flag: it reads the attached screenshots from their paths.
            let imageNote = imagePaths.isEmpty ? "" : "\n\nthe screenshots are these image files (read them): " + imagePaths.joined(separator: ", ")
            arguments.append(prompt + imageNote)
            return (arguments, nil)
        case .opencode:
            var arguments = ["run", "--format", "json", "--dir", workingDirectory]
            if !model.modelIdentifier.isEmpty { arguments += ["-m", model.modelIdentifier] }
            for imagePath in imagePaths { arguments += ["-f", imagePath] }
            arguments += ["--", prompt]
            return (arguments, nil)
        }
    }

    /// Codex features that would let it act by itself instead of answering in Clicky's format.
    public static let codexDisabledFeatures = [
        "browser_use", "browser_use_external", "browser_use_full_cdp_access", "computer_use", "in_app_browser", "apps", "plugins",
        "shell_tool", "unified_exec", "multi_agent", "image_generation", "hooks", "goals", "tool_suggest", "skill_search", "view_image"
    ]

    public enum OutputEvent: Equatable, Sendable {
        /// The answer so far grew by this text.
        case text(String)
        /// The whole answer (replaces anything streamed).
        case finalText(String)
        case error(String)
        case tokens(input: Int, output: Int)
    }

    /// One JSON line of a CLI's output → what it means for the answer.
    public static func parseLine(_ line: Data, provider: BrainProvider) -> [OutputEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = object["type"] as? String else { return [] }
        switch provider {
        case .claude, .api:
            return []
        case .codex:
            switch type {
            case "item.completed":
                guard let item = object["item"] as? [String: Any] else { return [] }
                if item["type"] as? String == "agent_message", let text = item["text"] as? String { return [.text(repairBlockTags(text))] }
                return []
            case "turn.completed":
                let usage = object["usage"] as? [String: Any] ?? [:]
                return [.tokens(input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0)]
            case "turn.failed":
                let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "Codex failed"
                return [.error(readableError(message))]
            case "error":
                return [.error(readableError(object["message"] as? String ?? "Codex error"))]
            default:
                return []
            }
        case .opencode:
            switch type {
            case "text":
                if let text = (object["part"] as? [String: Any])?["text"] as? String { return [.text(text)] }
                return []
            case "step_finish":
                let tokens = (object["part"] as? [String: Any])?["tokens"] as? [String: Any] ?? [:]
                return [.tokens(input: tokens["input"] as? Int ?? 0, output: tokens["output"] as? Int ?? 0)]
            case "error":
                let error = object["error"] as? [String: Any]
                let message = ((error?["data"] as? [String: Any])?["message"] as? String) ?? (error?["message"] as? String) ?? "OpenCode error"
                return [.error(message)]
            default:
                return []
            }
        case .cursor:
            switch type {
            case "assistant":
                let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                return text.isEmpty ? [] : [.text(text)]
            case "result":
                if object["is_error"] as? Bool == true { return [.error(object["result"] as? String ?? "Cursor error")] }
                if let result = object["result"] as? String, !result.isEmpty { return [.finalText(result)] }
                return []
            default:
                return []
            }
        }
    }

    /// Small slips other models make in Clicky's block tags ("</actions}" or a missing ">" at the end of a
    /// closing tag): fixed before the answer router sees them, or the whole block would be dropped.
    public static func repairBlockTags(_ text: String) -> String {
        var repaired = text
        for tag in ["actions", "whiteboard"] {
            repaired = repaired.replacingOccurrences(of: "</\\s*\(tag)\\s*(?:[}\\])]|>?)(?=\\s|$)", with: "</\(tag)>",
                                                     options: [.regularExpression, .caseInsensitive])
        }
        return repaired
    }

    /// Codex wraps API errors as JSON inside the message: keep the human part.
    static func readableError(_ message: String) -> String {
        if let data = message.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = (object["error"] as? [String: Any])?["message"] as? String {
            return inner
        }
        return message
    }
}

/// The models each brain can use, for the pickers.
public enum BrainModelCatalog {
    /// Codex's own cache of the models this ChatGPT account may use (visibility "list").
    public static func codexModels(cacheJSON: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: cacheJSON) else { return [] }
        let models = (object as? [String: Any])?["models"] as? [[String: Any]] ?? (object as? [[String: Any]] ?? [])
        return models.compactMap { model in
            guard let slug = model["slug"] as? String ?? model["id"] as? String else { return nil }
            return (model["visibility"] as? String ?? "list") == "list" ? slug : nil
        }
    }

    /// `opencode models` prints one provider/model per line.
    public static func openCodeModels(listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("/") && !$0.contains(" ") }
    }

    /// `cursor-agent --list-models`: lines like "gpt-6 - GPT 6" or "• sonnet-4.5".
    public static func cursorModels(listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            for bullet in ["•", "-", "*"] where text.hasPrefix(bullet) { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard let first = text.split(separator: " ").first.map(String.init), !first.isEmpty,
                  first.range(of: #"^[a-z0-9][a-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
            return first
        }
    }

    /// T3 Code's model manifest (~/.t3/userdata/model-manifest.json): currentModels per driver.
    public static func t3CurrentModels(manifestJSON: Data) -> [String: [String]] {
        guard let object = try? JSONSerialization.jsonObject(with: manifestJSON) as? [String: Any],
              let manifest = object["manifest"] as? [String: Any],
              let current = manifest["currentModels"] as? [String: [String]] else { return [:] }
        return current
    }
}
