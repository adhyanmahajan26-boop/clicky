//
//  ActionDSL.swift
//  ClickyCore
//
//  P7 computer-use actions: the <actions> block Claude answers with when the
//  owner asks Clicky to *do* something on his Mac ("open chrome and google
//  this", "open the second link", "highlight the important facts",
//  "summarize the article on screen"). The block body is one JSON object:
//
//    <actions>{"goal":"find ramen near me",
//              "steps":[{"do":"open_app","name":"Google Chrome"},
//                       {"do":"search","query":"ramen near me","engine":"google"}],
//              "done":false}</actions>
//
//  Steps (field names exactly as the prompt teaches them):
//    open_app {name | bundle}            open_url {url}  (http/https only)
//    search {query, engine: google|youtube}
//    click {id}                          type {id?, text, enter?}
//    key {combo}  ("cmd+t", "shift+tab", "return")
//    scroll {id?, direction: up|down|left|right, amount 1…10}
//    select_copy {id | text}             wait {seconds ≤ 5}
//    switch_window {app | title}
//    highlight {targets: [id | "#id" | "exact text"], notes?: [String]}
//    summarize {text?, title?}           code_task {project?, instructions}
//
//  `id` is an element id of the screen the answer was given for (the
//  grounding lists, #n). "done": true says these are the last steps (no
//  observe turn after them). The parser is strict about the envelope
//  (size, JSON, step count) and lenient per step: a step it can't use is
//  listed in `rejectedSteps` (the model hears why) and the rest still run.
//

import Foundation

public enum ActionSearchEngine: String, Equatable, Sendable, CaseIterable {
    case google
    case youtube

    /// The results page for `query` (percent-encoded as a query value).
    public func resultsURL(for query: String) -> URL? {
        var components: URLComponents
        switch self {
        case .google:
            components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .youtube:
            components = URLComponents(string: "https://www.youtube.com/results")!
            components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        }
        // URLComponents leaves "+" and "&"-safe characters alone; "+" would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

public enum ActionScrollDirection: String, Equatable, Sendable, CaseIterable {
    case up, down, left, right
}

/// What a highlight step marks: an element id or exact on-screen text.
public enum ActionHighlightTarget: Equatable, Sendable {
    case element(Int)
    case text(String)
}

public enum ActionKeyModifier: String, Equatable, Hashable, Sendable, CaseIterable, Comparable {
    case control, option, shift, command

    public static func < (lhs: ActionKeyModifier, rhs: ActionKeyModifier) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    var shortName: String {
        switch self {
        case .control: return "ctrl"
        case .option: return "opt"
        case .shift: return "shift"
        case .command: return "cmd"
        }
    }
}

/// One key press with its modifiers, e.g. cmd+shift+n.
public struct ActionKeyCombo: Equatable, Hashable, Sendable {
    public var modifiers: Set<ActionKeyModifier>
    /// Normalised key name: "a"…"z", "0"…"9", "return", "tab", "space",
    /// "delete", "forwarddelete", "escape", "left", "right", "up", "down",
    /// "pageup", "pagedown", "home", "end", "f1"…"f12", or punctuation.
    public var key: String
    /// macOS virtual key code (kVK_*).
    public var virtualKeyCode: UInt16

    public init(modifiers: Set<ActionKeyModifier>, key: String, virtualKeyCode: UInt16) {
        self.modifiers = modifiers
        self.key = key
        self.virtualKeyCode = virtualKeyCode
    }

    /// Return or keypad Enter, with or without modifiers.
    public var isReturnKey: Bool { key == "return" || key == "enter" }

    /// "cmd+shift+n" (modifiers in a fixed order).
    public var displayText: String {
        (modifiers.sorted().map(\.shortName) + [key]).joined(separator: "+")
    }

    static let modifierAliases: [String: ActionKeyModifier] = [
        "cmd": .command, "command": .command, "⌘": .command, "meta": .command, "super": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "ctl": .control, "⌃": .control
    ]

    static let keyAliases: [String: String] = [
        "enter": "enter", "return": "return", "ret": "return", "↩": "return",
        "esc": "escape", "escape": "escape",
        "tab": "tab", "space": "space", "spacebar": "space",
        "backspace": "delete", "delete": "delete", "del": "delete", "⌫": "delete",
        "forwarddelete": "forwarddelete", "fwddelete": "forwarddelete",
        "left": "left", "leftarrow": "left", "arrowleft": "left", "←": "left",
        "right": "right", "rightarrow": "right", "arrowright": "right", "→": "right",
        "up": "up", "uparrow": "up", "arrowup": "up", "↑": "up",
        "down": "down", "downarrow": "down", "arrowdown": "down", "↓": "down",
        "pageup": "pageup", "pgup": "pageup", "pagedown": "pagedown", "pgdn": "pagedown",
        "home": "home", "end": "end"
    ]

    /// kVK_ codes (Carbon Events.h) for every key the DSL accepts.
    static let virtualKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "enter": 76, "escape": 53,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f10": 109, "f12": 111, "home": 115, "pageup": 116,
        "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126
    ]

    /// "cmd+shift+n", "Cmd-T", "⌘L", "shift + tab". Nil for an unknown key,
    /// two non-modifier keys, or a bare modifier.
    public static func parse(_ text: String) -> ActionKeyCombo? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        // "⌘L" / "⌘⇧N": symbols glued to the key.
        for symbol in ["⌘", "⇧", "⌥", "⌃"] { trimmed = trimmed.replacingOccurrences(of: symbol, with: symbol + "+") }
        let separators = CharacterSet(charactersIn: "+ ")
        var parts = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        // "cmd-t" (but "-" alone is a key, and "cmd+-" keeps it).
        if parts.count == 1, parts[0].count > 1, parts[0].contains("-") {
            parts = parts[0].split(separator: "-", omittingEmptySubsequences: true).map(String.init)
            if trimmed.hasSuffix("--") { parts.append("-") }
        }
        if trimmed.hasSuffix("++") || trimmed == "+" { return nil }
        var modifiers: Set<ActionKeyModifier> = []
        var keyName: String?
        for part in parts {
            if let modifier = modifierAliases[part] {
                modifiers.insert(modifier)
                continue
            }
            guard keyName == nil else { return nil }
            keyName = keyAliases[part] ?? part
        }
        guard let keyName, let virtualKeyCode = virtualKeyCodes[keyName] else { return nil }
        return ActionKeyCombo(modifiers: modifiers, key: keyName, virtualKeyCode: virtualKeyCode)
    }
}

public enum ActionStep: Equatable, Sendable {
    case openApp(name: String?, bundleIdentifier: String?)
    case openURL(URL)
    case search(query: String, engine: ActionSearchEngine)
    case click(elementID: Int)
    /// `pressesReturn` = the model asked for Return after typing ("enter": true).
    case type(elementID: Int?, text: String, pressesReturn: Bool)
    case key(ActionKeyCombo)
    case scroll(elementID: Int?, direction: ActionScrollDirection, amount: Int)
    case selectCopy(elementID: Int?, text: String?)
    case wait(seconds: Double)
    case switchWindow(app: String?, title: String?)
    case highlight(targets: [ActionHighlightTarget], notes: [String])
    case summarize(text: String?, title: String?)
    case codeTask(project: String?, instructions: String)

    /// The DSL verb ("open_app").
    public var verb: String {
        switch self {
        case .openApp: return "open_app"
        case .openURL: return "open_url"
        case .search: return "search"
        case .click: return "click"
        case .type: return "type"
        case .key: return "key"
        case .scroll: return "scroll"
        case .selectCopy: return "select_copy"
        case .wait: return "wait"
        case .switchWindow: return "switch_window"
        case .highlight: return "highlight"
        case .summarize: return "summarize"
        case .codeTask: return "code_task"
        }
    }

    /// Element ids of the current screen the step depends on.
    public var referencedElementIDs: [Int] {
        switch self {
        case .click(let elementID): return [elementID]
        case .type(let elementID, _, _), .scroll(let elementID, _, _), .selectCopy(let elementID, _): return elementID.map { [$0] } ?? []
        case .highlight(let targets, _):
            return targets.compactMap { target in
                if case .element(let elementID) = target { return elementID }
                return nil
            }
        default: return []
        }
    }

    /// After this step the screen (and so every element id) is likely different.
    public var changesScreen: Bool {
        switch self {
        case .openApp, .openURL, .search, .click, .key, .switchWindow, .codeTask: return true
        case .type(_, _, let pressesReturn): return pressesReturn
        case .scroll: return true
        case .selectCopy, .wait, .highlight, .summarize: return false
        }
    }

    /// A type step with "enter":true, or a key step that is Return / Enter.
    public var pressesReturn: Bool {
        switch self {
        case .type(_, _, let pressesReturn): return pressesReturn
        case .key(let combo): return combo.isReturnKey
        default: return false
        }
    }

    /// Steps that read or mark the screen only (they never send an event to an app).
    public var isReadOnly: Bool {
        switch self {
        case .highlight, .summarize, .selectCopy, .wait: return true
        default: return false
        }
    }

    /// One short line for the notch / dashboard / the model's results ("type “hello wor…” into #4").
    public var shortDescription: String {
        func quoted(_ text: String, limit: Int = 28) -> String {
            let flattened = text.replacingOccurrences(of: "\n", with: " ")
            return "\u{201C}" + (flattened.count > limit ? String(flattened.prefix(limit - 1)) + "…" : flattened) + "\u{201D}"
        }
        switch self {
        case .openApp(let name, let bundleIdentifier): return "open \(name ?? bundleIdentifier ?? "app")"
        case .openURL(let url): return "open \(url.host ?? url.absoluteString)"
        case .search(let query, let engine): return "search \(engine.rawValue) for \(quoted(query))"
        case .click(let elementID): return "click #\(elementID)"
        case .type(let elementID, let text, let pressesReturn):
            return "type \(quoted(text))" + (elementID.map { " into #\($0)" } ?? "") + (pressesReturn ? " + return" : "")
        case .key(let combo): return "press \(combo.displayText)"
        case .scroll(let elementID, let direction, let amount): return "scroll \(direction.rawValue) \(amount)" + (elementID.map { " in #\($0)" } ?? "")
        case .selectCopy(let elementID, let text): return "copy " + (text.map { quoted($0) } ?? elementID.map { "#\($0)" } ?? "selection")
        case .wait(let seconds): return "wait \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
        case .switchWindow(let app, let title): return "switch to \(title.map { quoted($0) } ?? app ?? "window")"
        case .highlight(let targets, _): return "highlight \(targets.count) thing\(targets.count == 1 ? "" : "s")"
        case .summarize(let text, _): return text == nil ? "read the page for a summary" : "show the summary"
        case .codeTask(let project, _): return "code task" + (project.map { " in \($0)" } ?? "")
        }
    }
}

/// A step the parser couldn't use, and why (told to the model in the results).
public struct ActionStepRejection: Equatable, Sendable {
    /// 1-based position in the block.
    public var position: Int
    public var verb: String?
    public var reason: String

    public init(position: Int, verb: String?, reason: String) {
        self.position = position
        self.verb = verb
        self.reason = reason
    }
}

public struct ActionPlan: Equatable, Sendable {
    public var goal: String
    public var steps: [ActionStep]
    /// "done": true — these are the last steps; no observe turn after them.
    public var isDone: Bool
    public var rejectedSteps: [ActionStepRejection]

    public init(goal: String, steps: [ActionStep], isDone: Bool, rejectedSteps: [ActionStepRejection] = []) {
        self.goal = goal
        self.steps = steps
        self.isDone = isDone
        self.rejectedSteps = rejectedSteps
    }
}

public enum ActionPlanParseError: Error, Equatable, Sendable {
    case empty
    case tooLong(characterCount: Int)
    case notJSON
    case noStepsArray
    case tooManySteps(count: Int)
    /// Steps were given but none was usable (and the block isn't a bare "done").
    case noUsableSteps([ActionStepRejection])

    /// One line for the log / the model.
    public var explanation: String {
        switch self {
        case .empty: return "the actions block was empty"
        case .tooLong(let characterCount): return "the actions block was \(characterCount) characters (limit \(ActionDSL.maximumBodyLength))"
        case .notJSON: return "the actions block wasn't one JSON object"
        case .noStepsArray: return "the actions block had no \"steps\" array"
        case .tooManySteps(let count): return "the actions block had \(count) steps (limit \(ActionDSL.maximumStepsPerBlock))"
        case .noUsableSteps(let rejections): return "no usable steps: " + rejections.map { "step \($0.position): \($0.reason)" }.joined(separator: "; ")
        }
    }
}

public enum ActionDSL {
    public static let blockName = "actions"
    public static let maximumBodyLength = 16_000
    public static let maximumStepsPerBlock = 12
    public static let maximumTypedTextLength = 2_000
    public static let maximumSummaryLength = 6_000
    public static let maximumWaitSeconds: Double = 5
    public static let maximumScrollAmount = 10
    public static let maximumHighlightTargets = 9
    public static let maximumURLLength = 2_048
    public static let maximumNameLength = 120
    public static let maximumNoteLength = 60

    public static func parse(_ blockBody: String) -> Result<ActionPlan, ActionPlanParseError> {
        var body = blockBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .failure(.empty) }
        guard body.count <= maximumBodyLength else { return .failure(.tooLong(characterCount: body.count)) }
        // Tolerate a ```json fence around the object.
        if body.hasPrefix("```") {
            body = body.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if body.hasSuffix("```") { body = String(body.dropLast(3)) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.notJSON) }
        let goal = (object["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isDone = (object["done"] as? Bool) ?? false
        guard let rawSteps = object["steps"] as? [Any] else {
            // {"done": true} alone: the task is finished.
            if isDone { return .success(ActionPlan(goal: String(goal.prefix(200)), steps: [], isDone: true)) }
            return .failure(.noStepsArray)
        }
        guard rawSteps.count <= maximumStepsPerBlock else { return .failure(.tooManySteps(count: rawSteps.count)) }
        var steps: [ActionStep] = []
        var rejections: [ActionStepRejection] = []
        for (offset, rawStep) in rawSteps.enumerated() {
            let position = offset + 1
            guard let stepObject = rawStep as? [String: Any] else {
                rejections.append(ActionStepRejection(position: position, verb: nil, reason: "not an object"))
                continue
            }
            switch parseStep(stepObject) {
            case .success(let step): steps.append(step)
            case .failure(let rejection):
                rejections.append(ActionStepRejection(position: position, verb: rejection.verb, reason: rejection.reason))
            }
        }
        if steps.isEmpty && !isDone {
            return .failure(rawSteps.isEmpty ? .noUsableSteps([]) : .noUsableSteps(rejections))
        }
        return .success(ActionPlan(goal: String(goal.prefix(200)), steps: steps, isDone: isDone, rejectedSteps: rejections))
    }

    struct StepRejection: Error {
        var verb: String?
        var reason: String
    }

    static func parseStep(_ object: [String: Any]) -> Result<ActionStep, StepRejection> {
        guard let rawVerb = (object["do"] as? String) ?? (object["action"] as? String) else {
            return .failure(StepRejection(verb: nil, reason: "no \"do\""))
        }
        let verb = rawVerb.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_")
        func reject(_ reason: String) -> Result<ActionStep, StepRejection> { .failure(StepRejection(verb: verb, reason: reason)) }
        func string(_ key: String, limit: Int = maximumNameLength) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= limit else { return nil }
            return trimmed
        }

        switch verb {
        case "open_app":
            let name = string("name") ?? string("app")
            let bundleIdentifier = string("bundle") ?? string("bundle_id")
            guard name != nil || bundleIdentifier != nil else { return reject("open_app needs a name or bundle") }
            return .success(.openApp(name: name, bundleIdentifier: bundleIdentifier))

        case "open_url":
            guard let rawURL = string("url", limit: maximumURLLength) else { return reject("open_url needs a url") }
            guard let url = webURL(from: rawURL) else { return reject("only http and https links can be opened") }
            return .success(.openURL(url))

        case "search", "google":
            guard let query = string("query", limit: 500) ?? string("text", limit: 500) else { return reject("search needs a query") }
            let engineName = (string("engine") ?? (verb == "google" ? "google" : "google")).lowercased()
            guard let engine = ActionSearchEngine(rawValue: engineName) else { return reject("engine must be google or youtube") }
            return .success(.search(query: query, engine: engine))

        case "click":
            guard let elementID = elementIdentifier(object["id"]) else { return reject("click needs an element id") }
            return .success(.click(elementID: elementID))

        case "type":
            guard let text = object["text"] as? String, !text.isEmpty else { return reject("type needs text") }
            guard text.count <= maximumTypedTextLength else { return reject("text over \(maximumTypedTextLength) characters") }
            let elementID: Int?
            if object["id"] == nil || object["id"] is NSNull {
                elementID = nil
            } else {
                guard let parsedID = elementIdentifier(object["id"]) else { return reject("bad element id") }
                elementID = parsedID
            }
            let pressesReturn = (object["enter"] as? Bool) ?? (object["submit"] as? Bool) ?? (object["press_return"] as? Bool) ?? false
            return .success(.type(elementID: elementID, text: text, pressesReturn: pressesReturn))

        case "key", "keys", "press":
            guard let comboText = string("combo") ?? string("key") ?? string("keys"),
                  let combo = ActionKeyCombo.parse(comboText) else { return reject("unknown key combo") }
            return .success(.key(combo))

        case "scroll":
            let directionName = (string("direction") ?? "down").lowercased()
            guard let direction = ActionScrollDirection(rawValue: directionName) else { return reject("direction must be up, down, left or right") }
            let amount = max(1, min(maximumScrollAmount, integer(object["amount"]) ?? 3))
            let elementID = object["id"].flatMap(elementIdentifier)
            return .success(.scroll(elementID: elementID, direction: direction, amount: amount))

        case "select_copy", "copy", "select":
            let elementID = object["id"].flatMap(elementIdentifier)
            let text = string("text", limit: maximumTypedTextLength)
            guard elementID != nil || text != nil else { return reject("select_copy needs an id or text") }
            return .success(.selectCopy(elementID: elementID, text: text))

        case "wait":
            guard let seconds = number(object["seconds"]) ?? number(object["s"]), seconds > 0 else { return reject("wait needs seconds > 0") }
            return .success(.wait(seconds: min(seconds, maximumWaitSeconds)))

        case "switch_window", "switch":
            let app = string("app") ?? string("name")
            let title = string("title", limit: 200)
            guard app != nil || title != nil else { return reject("switch_window needs an app or title") }
            return .success(.switchWindow(app: app, title: title))

        case "highlight":
            let rawTargets: [Any]
            if let array = object["targets"] as? [Any] { rawTargets = array } else if let single = object["target"] ?? object["id"] { rawTargets = [single] } else { rawTargets = [] }
            let targets = rawTargets.compactMap(highlightTarget)
            guard !targets.isEmpty else { return reject("highlight needs targets") }
            guard targets.count <= maximumHighlightTargets else { return reject("at most \(maximumHighlightTargets) highlight targets") }
            let rawNotes: [Any] = (object["notes"] as? [Any]) ?? ((object["note"] as? String).map { [$0] } ?? [])
            let notes = rawNotes.compactMap { $0 as? String }.map(cleanNote)
            return .success(.highlight(targets: targets, notes: notes))

        case "summarize", "summary":
            let title = string("title", limit: 100)
            if let rawText = object["text"] as? String {
                let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count <= maximumSummaryLength else { return reject("summary over \(maximumSummaryLength) characters") }
                return .success(.summarize(text: text.isEmpty ? nil : text, title: title))
            }
            return .success(.summarize(text: nil, title: title))

        case "code_task", "codetask", "code":
            guard let instructions = string("instructions", limit: 4_000) ?? string("task", limit: 4_000) else { return reject("code_task needs instructions") }
            return .success(.codeTask(project: string("project") ?? string("repo"), instructions: instructions))

        default:
            return reject("unknown step \"\(verb.prefix(30))\"")
        }
    }

    /// 12, "12", "#12" → 12 (ids start at 1).
    public static func elementIdentifier(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, !isBoolean(number) {
            let doubleValue = number.doubleValue
            guard doubleValue == doubleValue.rounded(), doubleValue >= 1, doubleValue < 100_000 else { return nil }
            return Int(doubleValue)
        }
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard let parsed = Int(text), parsed >= 1, parsed < 100_000 else { return nil }
        return parsed
    }

    static func highlightTarget(_ value: Any) -> ActionHighlightTarget? {
        if let elementID = elementIdentifier(value) {
            if value is String, let text = value as? String, !text.hasPrefix("#"), Int(text) == nil { return .text(text) }
            return .element(elementID)
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Quotes around exact text are optional.
        let unquoted = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}"))
        guard !unquoted.isEmpty, unquoted.count <= 200 else { return nil }
        return .text(unquoted)
    }

    static func cleanNote(_ note: String) -> String {
        // "]" and "|" would break the MARK tag the note travels in.
        let cleaned = note.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > maximumNoteLength ? String(cleaned.prefix(maximumNoteLength - 1)) + "…" : cleaned
    }

    static func integer(_ value: Any?) -> Int? {
        number(value).map { Int($0.rounded()) }
    }

    /// JSON true/false (an NSNumber 1 also casts to Bool in Swift, so ask CF).
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !isBoolean(number) { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// "example.com/x" → https://example.com/x; anything but http(s) → nil.
    public static func webURL(from rawURL: String) -> URL? {
        var text = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lowercased = text.lowercased()
        if !lowercased.hasPrefix("http://") && !lowercased.hasPrefix("https://") {
            // A bare domain gets https; any other scheme (file:, javascript:, x-apple…) is refused.
            if lowercased.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: .regularExpression) != nil && !lowercased.hasPrefix("localhost:") { return nil }
            guard lowercased.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?(/.*)?$"#, options: .regularExpression) != nil else { return nil }
            text = "https://" + text
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
