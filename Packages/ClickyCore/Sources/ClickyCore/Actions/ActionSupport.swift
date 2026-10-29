//
//  ActionSupport.swift
//  ClickyCore
//
//  P7 helpers the executor needs that don't touch the system:
//   - ActionAppNameMatcher: "chrome" / "vs code" / "settings" → the app.
//   - ActionHighlightTags: highlight targets → [MARK:…] tags the existing
//     mark pipeline draws (overlay only).
//   - ActionsDebugAXCommand: argument validation for the debug inbox's
//     test-only axSetPosition / axPerform (TextEdit and Notes only).
//

import Foundation

public struct ActionApplicationCandidate: Equatable, Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public var path: String?

    public init(name: String, bundleIdentifier: String?, path: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }
}

public enum ActionAppNameMatcher {
    /// What people say → the app's real name.
    static let spokenAliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "vs code": "Visual Studio Code", "vscode": "Visual Studio Code",
        "code": "Visual Studio Code", "settings": "System Settings", "system preferences": "System Settings", "preferences": "System Settings",
        "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint", "outlook": "Microsoft Outlook",
        "teams": "Microsoft Teams", "edge": "Microsoft Edge", "arc": "Arc", "claude": "Claude", "finder": "Finder", "messages": "Messages",
        "imessage": "Messages", "app store": "App Store", "facetime": "FaceTime", "whatsapp": "WhatsApp", "spotify": "Spotify",
        "slack": "Slack", "notion": "Notion", "zoom": "zoom.us", "textedit": "TextEdit", "text edit": "TextEdit", "notes": "Notes", "mail": "Mail"
    ]

    static func key(_ name: String) -> String {
        ActionWordMatch.normalized(name).replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exact name, alias, bundle id, then a unique prefix / word match.
    public static func bestMatch(name: String?, bundleIdentifier: String?, candidates: [ActionApplicationCandidate]) -> ActionApplicationCandidate? {
        if let bundleIdentifier {
            if let match = candidates.first(where: { $0.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased() }) { return match }
        }
        guard let name, !key(name).isEmpty else { return nil }
        let spokenKey = key(name)
        let wantedKeys = [spokenKey, spokenAliases[spokenKey].map(key)].compactMap { $0 }
        for wantedKey in wantedKeys {
            if let match = candidates.first(where: { key($0.name) == wantedKey }) { return match }
        }
        let prefixMatches = candidates.filter { key($0.name).hasPrefix(spokenKey) }
        if prefixMatches.count == 1 { return prefixMatches[0] }
        let wordMatches = candidates.filter { ActionWordMatch.containsWord(in: $0.name, anyOf: [spokenKey]) }
        if wordMatches.count == 1 { return wordMatches[0] }
        // Several: the shortest name ("Notes" over "Notes Helper").
        return (prefixMatches.isEmpty ? wordMatches : prefixMatches).min { $0.name.count < $1.name.count }
    }
}

public enum ActionHighlightTags {
    /// One [MARK:…] tag per target: an element gets a box, short text an underline, a sentence a highlight,
    /// with the matching note (if any) as the mark's note.
    public static func tags(targets: [ActionHighlightTarget], notes: [String]) -> [String] {
        targets.enumerated().map { index, target in
            let note = index < notes.count ? ActionDSL.cleanNote(notes[index]) : ""
            switch target {
            case .element(let elementID):
                let label = note.isEmpty ? "important" : note
                return "[MARK:box:#\(elementID):\(sanitizedLabel(label))\(note.isEmpty ? "" : "|" + note)]"
            case .text(let text):
                let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let label = sanitizedLabel(String(text.prefix(40)))
                // A sentence is a highlighter stroke; a short label stays an underline.
                let style = target.isSentence ? "highlight" : "underline"
                return "[MARK:\(style):\"\(escapedText)\":\(label)\(note.isEmpty ? "" : "|" + note)]"
            }
        }
    }

    static func sanitizedLabel(_ label: String) -> String {
        let cleaned = label.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: ":", with: " ").replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "important" : cleaned
    }
}

/// The debug inbox's TEST-ONLY AX commands (the P7 harness moves TextEdit /
/// Notes windows and presses their buttons). Only these two apps; Safari
/// and Clicky itself are refused by name so the reason is explicit.
public enum ActionsDebugAXCommand {
    public static let allowedBundleIdentifiers: Set<String> = ["com.apple.TextEdit", "com.apple.Notes"]
    public static let explicitlyRefusedBundleIdentifiers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    public static let allowedPerformActions: Set<String> = ["press", "delete"]

    public enum WindowSelector: Equatable, Sendable {
        case index(Int)
        case title(String)
    }

    public struct SetPositionRequest: Equatable, Sendable {
        public var bundleIdentifier: String
        public var window: WindowSelector
        public var x: Double
        public var y: Double
        public var width: Double?
        public var height: Double?
        public var isDryRun: Bool
    }

    public struct PerformRequest: Equatable, Sendable {
        public var bundleIdentifier: String
        public var action: String
        public var role: String?
        public var title: String?
    }

    /// nil = allowed; else why not.
    public static func bundleRefusal(_ bundleIdentifier: String?, ownBundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return "needs \"bundle\"" }
        if let ownBundleIdentifier, bundleIdentifier == ownBundleIdentifier { return "never Clicky itself" }
        if bundleIdentifier.lowercased().contains("clicky") || bundleIdentifier == "com.personal.clicky" { return "never Clicky itself" }
        if explicitlyRefusedBundleIdentifiers.contains(bundleIdentifier) { return "never Safari" }
        guard allowedBundleIdentifiers.contains(bundleIdentifier) else {
            return "only \(allowedBundleIdentifiers.sorted().joined(separator: ", ")) are allowed"
        }
        return nil
    }

    public static func parseSetPosition(_ object: [String: Any], ownBundleIdentifier: String?) -> Result<SetPositionRequest, ActionsDebugAXError> {
        let bundleIdentifier = object["bundle"] as? String
        if let refusal = bundleRefusal(bundleIdentifier, ownBundleIdentifier: ownBundleIdentifier) { return .failure(.refused(refusal)) }
        let isDryRun = object["dryRun"] as? Bool ?? false
        let window: WindowSelector
        if let title = object["windowTitle"] as? String, !title.isEmpty {
            window = .title(title)
        } else if let index = ActionDSL.integer(object["windowIndex"]) {
            guard index >= 0, index < 50 else { return .failure(.invalid("windowIndex must be 0…49")) }
            window = .index(index)
        } else {
            window = .index(0)
        }
        func coordinate(_ key: String) -> Double? { ActionDSL.number(object[key]) }
        guard isDryRun || (coordinate("x") != nil && coordinate("y") != nil) else { return .failure(.invalid("needs \"x\" and \"y\" (or dryRun)")) }
        let x = coordinate("x") ?? 0, y = coordinate("y") ?? 0
        guard abs(x) <= 20_000, abs(y) <= 20_000 else { return .failure(.invalid("x/y out of range")) }
        let width = coordinate("w"), height = coordinate("h")
        if (width == nil) != (height == nil) { return .failure(.invalid("give both \"w\" and \"h\", or neither")) }
        if let width, let height, !(50...10_000).contains(width) || !(50...10_000).contains(height) {
            return .failure(.invalid("w/h must be 50…10000"))
        }
        return .success(SetPositionRequest(bundleIdentifier: bundleIdentifier!, window: window, x: x, y: y, width: width, height: height, isDryRun: isDryRun))
    }

    public static func parsePerform(_ object: [String: Any], ownBundleIdentifier: String?) -> Result<PerformRequest, ActionsDebugAXError> {
        let bundleIdentifier = object["bundle"] as? String
        if let refusal = bundleRefusal(bundleIdentifier, ownBundleIdentifier: ownBundleIdentifier) { return .failure(.refused(refusal)) }
        guard let action = (object["action"] as? String)?.lowercased(), allowedPerformActions.contains(action) else {
            return .failure(.invalid("action must be \"press\" or \"delete\""))
        }
        if object["text"] != nil || object["value"] != nil { return .failure(.refused("axPerform never types text")) }
        let role = object["role"] as? String
        let title = object["title"] as? String
        switch action {
        case "press":
            guard let role, !role.isEmpty, let title, !title.isEmpty else { return .failure(.invalid("press needs \"role\" and \"title\"")) }
        default:
            guard bundleIdentifier == "com.apple.Notes" else { return .failure(.refused("delete is only for the selected note in Notes")) }
        }
        return .success(PerformRequest(bundleIdentifier: bundleIdentifier!, action: action, role: role, title: title))
    }
}

public enum ActionsDebugAXError: Error, Equatable, Sendable {
    case refused(String)
    case invalid(String)

    public var message: String {
        switch self {
        case .refused(let reason): return "refused: \(reason)"
        case .invalid(let reason): return "invalid: \(reason)"
        }
    }
}

/// "close the tabs you opened", "clean up your tabs", "close all the tabs you opened".
public enum BrowserTabCleanupCommand {
    public static func matches(_ transcript: String) -> Bool {
        let text = transcript.lowercased().replacingOccurrences(of: "[^a-z ]", with: "", options: .regularExpression)
        let patterns = [
            "close (?:all )?(?:of )?(?:the |your |those )?tabs (?:that )?you opened",
            "clean ?up (?:the |your |those )?tabs",
            "close (?:all )?(?:of )?your tabs",
            "close (?:the |those )?(?:search |clicky )tabs"
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

/// "Do it for me" / "make the clicks for me" / "click them for me" after a step-by-step answer:
/// Claudia clicks the steps she just marked, in order.
public enum ClickForMeCommand {
    public static func matches(_ transcript: String) -> Bool {
        let text = transcript.lowercased().replacingOccurrences(of: "[^a-z ]", with: "", options: .regularExpression)
        let patterns = [
            "^(?:(?:hey )?(?:theo|clicky) )?(?:please )?(?:can you |could you )?do (?:it|that|them|this|those steps) for me",
            "(?:make|do) the clicks? for me", "click (?:it|them|those|these|that) for me", "click (?:through )?(?:the |those |these )?steps? for me",
            "^(?:please )?(?:go ahead and )?click (?:them|those|it)$", "you (?:do|click) it", "^do (?:the )?steps(?: for me)?$"
        ]
        return patterns.contains { text.trimmingCharacters(in: .whitespaces).range(of: $0, options: .regularExpression) != nil }
    }

    /// "1. Bluetooth | click here" from each [MARK:n:target:label|note] of an answer, in step order.
    public static func markedSteps(inAnswer answer: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"\[MARK:(\d+):[^:\]]*(?::screen\d+)?:([^\]|]*)\|?([^\]]*)\]"#) else { return [] }
        let range = NSRange(answer.startIndex..., in: answer)
        let steps = expression.matches(in: answer, range: range).compactMap { match -> (Int, String)? in
            guard let numberRange = Range(match.range(at: 1), in: answer), let number = Int(answer[numberRange]) else { return nil }
            let label = Range(match.range(at: 2), in: answer).map { String(answer[$0]) } ?? ""
            let note = Range(match.range(at: 3), in: answer).map { String(answer[$0]) } ?? ""
            return (number, "\(number). \(label)\(note.isEmpty ? "" : " — \(note)")")
        }
        return steps.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Added to the turn: the brain answers with one actions block that clicks those steps on the fresh screen.
    public static func instruction(markedSteps: String) -> String {
        """
        the user wants you to do the steps you just marked, for them. your marked steps were:
        \(markedSteps)
        reply with one short spoken line and ONE <actions> block that clicks each step in order on this fresh screen (use the element ids from the new lists; add a short wait step after a click that opens a new page or pane, then continue). when a step needs a choice the user didn't make (a toggle to turn on or off, a value), do it the way your steps said. set "done":true on the last step.
        """
    }
}
