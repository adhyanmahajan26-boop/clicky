//
//  VoiceFastPath.swift
//  ClickyCore
//
//  P8 local fast path: simple spoken commands done on the Mac in well
//  under a second, with no Claude call. Pure: a transcript goes in, a
//  command (or nil → the normal Claude turn) comes out; the tier decision
//  for one command and the facts the app read is here too.
//
//  - Whole-utterance matching only, after dropping the wake phrase and
//    politeness ("hey claudia, could you turn the volume up please").
//    "what's the volume of a sphere" or "open the second link and summarize
//    it" never match: anything that isn't exactly a command goes to Claude.
//  - en-IN ASR quirks are accepted ("new tap", "close the tap", "volume
//    hundred percent", "reduce the volume", "minimise", "maximise").
//  - Safety: the same ActionTierClassifier tiers as computer-use actions.
//    An explicit spoken command counts as the confirm for that exact action
//    (confirm → do it), except "lock screen" and closing a window with
//    unsaved changes, which still wait for a spoken yes or a click. Refused
//    stays refused (secure fields, terminals for keys, Safari / Netflix
//    unless named, Clicky's own windows).
//

import Foundation

public enum VoiceMediaKey: String, Equatable, Sendable, CaseIterable {
    case playPause
    case next
    case previous
}

public enum VoiceWindowCommand: Equatable, Sendable {
    case snapLeftHalf
    case snapRightHalf
    case maximize
    case minimize
    /// "move window to monitor 2" (1-based, the order the app numbers screens).
    case moveToScreenNumber(Int)
    case moveToScreenOnLeft
    case moveToScreenOnRight
    case moveToNextScreen
}

public enum VoiceKeyCommand: String, Equatable, Sendable, CaseIterable {
    case newTab
    case closeTab
    case closeWindow
    case goBack
    case goForward
    case copy
    case paste
    case selectAll

    public var keyCombo: ActionKeyCombo {
        switch self {
        case .newTab: return ActionKeyCombo.parse("cmd+t")!
        case .closeTab, .closeWindow: return ActionKeyCombo.parse("cmd+w")!
        case .goBack: return ActionKeyCombo.parse("cmd+[")!
        case .goForward: return ActionKeyCombo.parse("cmd+]")!
        case .copy: return ActionKeyCombo.parse("cmd+c")!
        case .paste: return ActionKeyCombo.parse("cmd+v")!
        case .selectAll: return ActionKeyCombo.parse("cmd+a")!
        }
    }

    /// Copy / paste / select all act on the focused field (never a secure one).
    public var actsOnFocusedField: Bool { self == .copy || self == .paste || self == .selectAll }
}

public enum VoiceScrollCommand: String, Equatable, Sendable, CaseIterable {
    case up
    case down
    case pageUp
    case pageDown
    case top
    case bottom

    public var keyCombo: ActionKeyCombo? {
        switch self {
        case .pageUp: return ActionKeyCombo.parse("pageup")
        case .pageDown: return ActionKeyCombo.parse("pagedown")
        case .top: return ActionKeyCombo.parse("cmd+up")
        case .bottom: return ActionKeyCombo.parse("cmd+down")
        case .up, .down: return nil
        }
    }
}

public enum VoiceOpenItemKind: String, Equatable, Sendable {
    case folder
    case file
    case any
}

public enum VoiceFastPathCommand: Equatable, Sendable {
    case volumeUp
    case volumeDown
    case volumeSet(percent: Int)
    case mute
    case unmute
    case brightnessUp
    case brightnessDown
    /// `namesNetflixOrSafari`: he said "pause Netflix" / "play Netflix" (the only way media keys reach Netflix).
    case media(VoiceMediaKey, namesNetflixOrSafari: Bool)
    case window(VoiceWindowCommand)
    case switchToApp(name: String)
    case openApp(name: String)
    case openItem(name: String, kind: VoiceOpenItemKind)
    case key(VoiceKeyCommand)
    case scroll(VoiceScrollCommand)
    case missionControl
    case showDesktop
    case readAloud
    case startDictation
    case stopDictation
    case screenshot(SnapshotTarget)
    case lockScreen

    /// A short name for logs, the dashboard and the debug inbox.
    public var actionName: String {
        switch self {
        case .volumeUp: return "volumeUp"
        case .volumeDown: return "volumeDown"
        case .volumeSet: return "volumeSet"
        case .mute: return "mute"
        case .unmute: return "unmute"
        case .brightnessUp: return "brightnessUp"
        case .brightnessDown: return "brightnessDown"
        case .media(let key, _): return "media.\(key.rawValue)"
        case .window(let windowCommand):
            switch windowCommand {
            case .snapLeftHalf: return "window.snapLeft"
            case .snapRightHalf: return "window.snapRight"
            case .maximize: return "window.maximize"
            case .minimize: return "window.minimize"
            case .moveToScreenNumber: return "window.moveToScreen"
            case .moveToScreenOnLeft: return "window.moveToLeftScreen"
            case .moveToScreenOnRight: return "window.moveToRightScreen"
            case .moveToNextScreen: return "window.moveToNextScreen"
            }
        case .switchToApp: return "switchToApp"
        case .openApp: return "openApp"
        case .openItem: return "openItem"
        case .key(let keyCommand): return "key.\(keyCommand.rawValue)"
        case .scroll(let scrollCommand): return "scroll.\(scrollCommand.rawValue)"
        case .missionControl: return "missionControl"
        case .showDesktop: return "showDesktop"
        case .readAloud: return "readAloud"
        case .startDictation: return "dictation.start"
        case .stopDictation: return "dictation.stop"
        case .screenshot: return "screenshot"
        case .lockScreen: return "lockScreen"
        }
    }

    /// The parameters, for the debug inbox ("percent": 40, "name": "notes").
    public var parameters: [String: String] {
        switch self {
        case .volumeSet(let percent): return ["percent": String(percent)]
        case .media(_, let namesNetflixOrSafari): return namesNetflixOrSafari ? ["namesNetflixOrSafari": "true"] : [:]
        case .window(.moveToScreenNumber(let number)): return ["screen": String(number)]
        case .switchToApp(let name), .openApp(let name): return ["name": name]
        case .openItem(let name, let kind): return ["name": name, "kind": kind.rawValue]
        case .screenshot(let target): return ["target": target.rawValue]
        default: return [:]
        }
    }

    /// "Volume 40." — the 1–3 word acknowledgement spoken after it's done.
    public func acknowledgement(volumePercentAfter: Int? = nil) -> String {
        switch self {
        case .volumeUp, .volumeDown, .volumeSet:
            if let volumePercentAfter { return "Volume \(volumePercentAfter)." }
            return "Done."
        case .mute: return "Muted."
        case .unmute: return "Unmuted."
        case .brightnessUp, .brightnessDown: return "Done."
        case .media(let key, _):
            switch key {
            case .playPause: return "Done."
            case .next: return "Next."
            case .previous: return "Previous."
            }
        case .window(.minimize): return "Minimized."
        case .window(.maximize): return "Maximized."
        case .window: return "Done."
        case .switchToApp, .openApp, .openItem: return "Opening."
        case .key, .scroll, .missionControl, .showDesktop: return "Done."
        case .readAloud: return ""
        case .startDictation: return "Typing."
        case .stopDictation: return "Stopped typing."
        case .screenshot: return "Screenshot saved."
        case .lockScreen: return "Locking."
        }
    }
}

// MARK: - Parser

public enum VoiceFastPathParser {
    /// Longest utterance considered (anything longer is a real question).
    static let maximumWordCount = 12

    static let leadingFillers: [String] = [
        "hey claudia", "hey clicky", "hi claudia", "okay claudia", "ok claudia", "claudia", "clicky",
        "please", "can you", "could you", "would you", "will you", "can u", "could u", "would you please", "can you please",
        "could you please", "i want you to", "i want to", "i'd like you to", "id like you to", "i need you to", "kindly",
        "just", "now", "okay", "ok", "so", "and", "um", "uh", "alright", "hey", "go ahead and", "quickly", "actually"
    ]
    static let trailingFillers: [String] = [
        "please", "for me", "now", "right now", "thanks", "thank you", "quickly", "a bit", "a little", "a little bit", "bit", "ok", "okay"
    ]
    /// A question, not a command ("what's the volume", "how do I mute").
    static let questionStarters: Set<String> = [
        "what", "whats", "how", "hows", "why", "when", "where", "who", "whos", "which", "is", "are", "does", "do", "did", "tell", "explain",
        "should", "shall", "was", "were", "has", "have", "if", "whether"
    ]

    /// Lowercase, apostrophes dropped, "%" → " percent", other punctuation → spaces, single spaces.
    public static func normalize(_ transcript: String) -> String {
        var text = ActionWordMatch.normalized(transcript)
        text = text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "%", with: " percent ")
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        text = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The command words with fillers stripped from both ends.
    static func coreText(_ transcript: String) -> String {
        var text = normalize(transcript)
        var changed = true
        while changed {
            changed = false
            for filler in leadingFillers where text == filler || text.hasPrefix(filler + " ") {
                text = String(text.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            for filler in trailingFillers where text.hasSuffix(" " + filler) {
                text = String(text.dropLast(filler.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return text
    }

    public static func parse(_ transcript: String) -> VoiceFastPathCommand? {
        let text = coreText(transcript)
        guard !text.isEmpty else { return nil }
        let words = text.split(separator: " ").map(String.init)
        guard words.count <= maximumWordCount else { return nil }
        if let firstWord = words.first, questionStarters.contains(firstWord) { return nil }

        for rule in rules {
            if let command = rule(text) { return command }
        }
        return nil
    }

    // MARK: Rules

    typealias Rule = (String) -> VoiceFastPathCommand?

    static let rules: [Rule] = [
        dictationRule, volumeRule, muteRule, brightnessRule, mediaRule, windowRule, keyRule, scrollRule,
        systemRule, readAloudRule, screenshotRule, lockRule, openItemRule, switchAppRule, openAppRule
    ]

    /// Exact match against any of the alternatives (each a full regex, anchored here).
    static func matches(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { firstCapture(text, $0) != nil }
    }

    /// The whole-text regex's captures ("" for an unmatched optional group); nil when it doesn't match.
    static func firstCapture(_ text: String, _ pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let captureRange = Range(match.range(at: index), in: text) else { return "" }
            return String(text[captureRange])
        }
    }

    static let the = "(?:the |my |this |that )?"
    static let volumeNoun = "(?:volume|sound|audio)"

    static let dictationRule: Rule = { text in
        if matches(text, ["type what i say", "type what im saying", "type what i am saying", "type everything i say", "take dictation",
                          "start dictation", "start dictating", "dictation mode", "dictate", "start typing what i say", "type after me",
                          "write what i say", "type as i speak", "type while i speak"]) { return .startDictation }
        if matches(text, ["stop typing", "stop dictation", "stop dictating", "end dictation", "dictation off", "stop writing", "done typing",
                          "finish typing", "stop the dictation", "exit dictation"]) { return .stopDictation }
        return nil
    }

    static let volumeRule: Rule = { text in
        // Set: "volume 40", "set the volume to 40 percent", "make volume hundred", "volume at fifty", "volume full".
        let setPatterns = [
            "(?:set |make |put |change |turn |keep |do |bring )?\(the)\(volumeNoun) (?:to |at |on |as |level )?(.+?)(?: percent| per cent)?",
            "(?:set |make |put |change |turn |bring )\(the)\(volumeNoun) (?:level )?(?:to |at |on )?(.+?)(?: percent| per cent)?"
        ]
        for pattern in setPatterns {
            if let captures = firstCapture(text, pattern), let percent = VoiceNumberWords.percent(from: captures[1]) {
                return .volumeSet(percent: percent)
            }
        }
        if let captures = firstCapture(text, "(?:set |make |put )?(?:it |volume )?(?:to |at )?(.+?) percent \(volumeNoun)"),
           let percent = VoiceNumberWords.percent(from: captures[1]) {
            return .volumeSet(percent: percent)
        }
        if matches(text, [
            "\(volumeNoun) up", "\(the)\(volumeNoun) up", "turn (?:it |\(the)\(volumeNoun) )?up(?: \(the)\(volumeNoun))?", "turn up \(the)\(volumeNoun)",
            "(?:increase|raise|boost|bump up|pump up) \(the)\(volumeNoun)", "(?:increase|raise) \(volumeNoun)", "louder", "make it louder",
            "a bit louder", "more \(volumeNoun)", "\(volumeNoun) higher", "higher \(volumeNoun)", "\(volumeNoun) increase"
        ]) { return .volumeUp }
        if matches(text, [
            "\(volumeNoun) down", "\(the)\(volumeNoun) down", "turn (?:it |\(the)\(volumeNoun) )?down(?: \(the)\(volumeNoun))?", "turn down \(the)\(volumeNoun)",
            "(?:decrease|lower|reduce|drop|cut) \(the)\(volumeNoun)", "(?:decrease|lower|reduce) \(volumeNoun)", "quieter", "softer", "make it quieter",
            "less \(volumeNoun)", "\(volumeNoun) lower", "lower \(volumeNoun)", "\(volumeNoun) decrease", "\(volumeNoun) less"
        ]) { return .volumeDown }
        return nil
    }

    static let muteRule: Rule = { text in
        if matches(text, ["unmute", "un mute", "unmute \(the)(?:sound|volume|audio|mac|speakers?)", "turn (?:the )?sound (?:back )?on",
                          "sound on", "unmute it"]) { return .unmute }
        if matches(text, ["mute", "mute \(the)(?:sound|volume|audio|mac|speakers?|computer)", "mute it", "turn (?:the )?sound off",
                          "sound off", "silence", "mute everything", "volume off", "turn off \(the)(?:sound|volume)", "volume mute"]) { return .mute }
        return nil
    }

    static let brightnessRule: Rule = { text in
        let brightness = "(?:brightness|screen brightness|display brightness)"
        if matches(text, ["\(the)\(brightness) up", "turn up \(the)\(brightness)", "turn \(the)\(brightness) up", "(?:increase|raise) \(the)\(brightness)",
                          "brighter", "make (?:it|the screen) brighter", "more brightness", "brightness increase"]) { return .brightnessUp }
        if matches(text, ["\(the)\(brightness) down", "turn down \(the)\(brightness)", "turn \(the)\(brightness) down",
                          "(?:decrease|lower|reduce|dim) \(the)\(brightness)", "dimmer", "dim (?:the )?screen", "make (?:it|the screen) (?:dimmer|darker)",
                          "less brightness", "brightness decrease"]) { return .brightnessDown }
        return nil
    }

    static let mediaRule: Rule = { text in
        let namesNetflixOrSafari = ActionWordMatch.containsWord(in: text, anyOf: ["netflix", "safari"])
        let media = "(?:music|song|track|video|the music|the song|the track|the video|playback|it|spotify|netflix|the show|the movie|safari)"
        // "stop it" is Clicky's own stop (barge-in), never a media key.
        let stoppableMedia = "(?:music|song|the music|the song|playback|spotify|netflix|the video|the show|the movie)"
        if matches(text, ["play", "pause", "resume", "play pause", "play \(media)", "pause \(media)", "resume \(media)", "stop \(stoppableMedia)",
                          "stop the music", "unpause", "unpause \(media)", "continue playing", "start playing", "keep playing",
                          "pause it for a second", "hit play", "hit pause", "press play", "press pause"]) {
            return .media(.playPause, namesNetflixOrSafari: namesNetflixOrSafari)
        }
        let item = "(?:song|track|one|video|episode)"
        if matches(text, ["next \(item)", "skip", "skip \(the)\(item)", "skip this", "skip it", "play \(the)next \(item)", "go to \(the)next \(item)",
                          "next \(item) please", "skip ahead"]) {
            return .media(.next, namesNetflixOrSafari: namesNetflixOrSafari)
        }
        if matches(text, ["previous \(item)", "last \(item)", "go back a \(item)", "back a \(item)", "play \(the)previous \(item)",
                          "play \(the)last \(item)", "go to \(the)previous \(item)", "previous \(item) please"]) {
            return .media(.previous, namesNetflixOrSafari: namesNetflixOrSafari)
        }
        return nil
    }

    static let windowRule: Rule = { text in
        let window = "(?:window|this window|the window|it|this|app|the app)"
        let move = "(?:snap|move|put|tile|throw|send|push)"
        if matches(text, ["\(move) (?:\(window) )?(?:(?:to|on|onto) (?:the )?)?left(?: half| side)?(?: of (?:the )?screen)?",
                          "(?:\(window) )?(?:to (?:the )?)?left half", "left half", "snap left", "half left", "window left"]) {
            return .window(.snapLeftHalf)
        }
        if matches(text, ["\(move) (?:\(window) )?(?:(?:to|on|onto) (?:the )?)?right(?: half| side)?(?: of (?:the )?screen)?",
                          "(?:\(window) )?(?:to (?:the )?)?right half", "right half", "snap right", "half right", "window right"]) {
            return .window(.snapRightHalf)
        }
        if matches(text, ["maximi[sz]e(?: \(window))?", "maximi[sz]e it", "make (?:\(window) )?(?:full size|bigger|fill the screen)",
                          "fill (?:the )?screen", "(?:\(window) )?fill (?:the )?screen", "zoom (?:the )?window", "max (?:the )?window"]) {
            return .window(.maximize)
        }
        if matches(text, ["minimi[sz]e(?: \(window))?", "minimi[sz]e it", "hide (?:this|the) window", "send (?:\(window) )?to (?:the )?dock"]) {
            return .window(.minimize)
        }
        let screen = "(?:monitor|screen|display)"
        if let captures = firstCapture(text, "\(move) (?:\(window) )?(?:to |onto |on )(?:the )?(?:\(screen) (?:number )?(\\w+)|(\\w+) \(screen))") {
            let numberText = captures[1].isEmpty ? captures[2] : captures[1]
            switch numberText {
            case "left": return .window(.moveToScreenOnLeft)
            case "right": return .window(.moveToScreenOnRight)
            case "other", "next", "second other": return .window(.moveToNextScreen)
            default:
                if let number = VoiceNumberWords.ordinalOrCardinal(numberText), (1...9).contains(number) { return .window(.moveToScreenNumber(number)) }
            }
        }
        return nil
    }

    static let keyRule: Rule = { text in
        let tab = "(?:tab|tap|tabs)"
        if matches(text, ["new \(tab)", "(?:open|create|make|add) (?:a )?new \(tab)", "open (?:a|another) \(tab)", "another \(tab)"]) { return .key(.newTab) }
        if matches(text, ["close \(the)(?:current )?\(tab)", "close (?:this|the|current) \(tab)", "close \(tab)"]) { return .key(.closeTab) }
        if matches(text, ["close \(the)(?:current )?window", "close (?:this|the) window"]) { return .key(.closeWindow) }
        if matches(text, ["go back", "back", "navigate back", "previous page", "go to (?:the )?previous page", "back (?:one )?page", "go back a page",
                          "go back one page"]) { return .key(.goBack) }
        if matches(text, ["go forward", "forward", "navigate forward", "next page", "go to (?:the )?next page", "forward (?:one )?page"]) {
            return .key(.goForward)
        }
        if matches(text, ["copy", "copy (?:this|it|the selection|the selected text|selection|selected text)", "copy selected"]) { return .key(.copy) }
        if matches(text, ["paste", "paste (?:it|this|that|here|it here)", "paste (?:the )?clipboard"]) { return .key(.paste) }
        if matches(text, ["select all", "select everything", "select all (?:the )?text", "select all of it"]) { return .key(.selectAll) }
        return nil
    }

    static let scrollRule: Rule = { text in
        if matches(text, ["scroll up", "scroll (?:it |the page )?up", "scroll up (?:a bit|a little)", "up a bit"]) { return .scroll(.up) }
        if matches(text, ["scroll down", "scroll (?:it |the page )?down", "scroll down (?:a bit|a little)", "scroll", "down a bit", "scroll don"]) { return .scroll(.down) }
        if matches(text, ["page up", "one page up", "scroll (?:one |a )?page up", "previous screen"]) { return .scroll(.pageUp) }
        if matches(text, ["page down", "one page down", "scroll (?:one |a )?page down", "next screen"]) { return .scroll(.pageDown) }
        if matches(text, ["(?:go|scroll|jump|take me) (?:to )?(?:the )?top(?: of (?:the )?page)?", "top of (?:the )?page", "to the top", "top"]) {
            return .scroll(.top)
        }
        if matches(text, ["(?:go|scroll|jump|take me) (?:to )?(?:the )?bottom(?: of (?:the )?page)?", "bottom of (?:the )?page", "to the bottom", "bottom"]) {
            return .scroll(.bottom)
        }
        return nil
    }

    static let systemRule: Rule = { text in
        if matches(text, ["mission control", "(?:open|show|start|launch) (?:the )?mission control", "show (?:me )?all (?:the )?windows",
                          "show all windows"]) { return .missionControl }
        if matches(text, ["show (?:me )?(?:the |my )?desktop", "go to (?:the )?desktop", "desktop", "hide all windows", "reveal (?:the )?desktop"]) {
            return .showDesktop
        }
        return nil
    }

    static let readAloudRule: Rule = { text in
        if matches(text, ["read (?:this|that|it|the selection|the selected text|selection|what i selected|what is selected|the text)(?: (?:aloud|out loud|out|for me|to me))?",
                          "read (?:aloud|out loud)", "read it out(?: loud)?", "read this out(?: loud)?", "read out (?:this|the selection|the text)"]) {
            return .readAloud
        }
        return nil
    }

    static let screenshotRule: Rule = { text in
        if matches(text, ["(?:take |grab |capture )?(?:a )?screenshot (?:of )?(?:this |the |my )?window", "screenshot (?:of )?(?:this |the )?window",
                          "capture (?:this |the )?window"]) { return .screenshot(.window) }
        if matches(text, ["(?:take|grab|capture) (?:a )?(?:screenshot|screen shot|screen grab)", "screenshot", "screen shot",
                          "(?:take |grab )?(?:a )?screenshot (?:of )?(?:the |my |this )?(?:whole )?screen", "capture (?:the |my )?screen",
                          "screenshot this", "take a picture of (?:the|my) screen"]) { return .screenshot(.screen) }
        return nil
    }

    static let lockRule: Rule = { text in
        if matches(text, ["lock \(the)(?:screen|mac|computer|laptop)", "lock screen", "lock it", "lock up", "lock (?:the )?(?:screen|mac) now"]) {
            return .lockScreen
        }
        return nil
    }

    /// Words that make "open X" something for Claude ("open the second link", "open this").
    static let openTargetStopWords: Set<String> = [
        "link", "links", "page", "article", "result", "results", "email", "mail", "message", "video", "this", "that", "it", "them", "and", "then",
        "with", "in", "on", "for", "to", "first", "second", "third", "fourth", "last", "next", "previous", "new", "tab", "tabs", "window", "url",
        "website", "site", "google", "search", "up", "a", "an", "image", "picture", "pdf", "document", "chat", "conversation", "thread", "post",
        "comment", "reply", "notification", "here", "there", "what", "where", "which", "my", "file", "folder", "document", "me", "all"
    ]

    static let openItemRule: Rule = { text in
        // "open the projects folder", "open folder projects", "open my notes file", "open file budget".
        let open = "(?:open up|find and open|open|show|reveal)"
        if let captures = firstCapture(text, "\(open) (?:the |my )?(folder|file|document) (?:called |named )?(.+)") {
            return makeOpenItem(name: captures[2], kindWord: captures[1])
        }
        if let captures = firstCapture(text, "\(open) (?:the |my )?(.+?) (folder|file|document|directory)") {
            return makeOpenItem(name: captures[1], kindWord: captures[2])
        }
        return nil
    }

    static func makeOpenItem(name: String, kindWord: String) -> VoiceFastPathCommand? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let nameWords = trimmedName.split(separator: " ")
        guard !trimmedName.isEmpty, nameWords.count <= 4, !nameWords.contains(where: { ["this", "that", "it", "and", "then"].contains(String($0)) }) else { return nil }
        let kind: VoiceOpenItemKind = kindWord == "folder" || kindWord == "directory" ? .folder : .file
        return .openItem(name: trimmedName, kind: kind)
    }

    static let switchAppRule: Rule = { text in
        if let captures = firstCapture(text, "(?:switch|swap|change|jump|flip|go back) (?:over |back )?to (?:the )?(.+?)(?: app| application| window)?") {
            return appName(captures[1]).map { .switchToApp(name: $0) }
        }
        if let captures = firstCapture(text, "(?:bring up|bring|show) (?:the )?(.+?) (?:app|application|window)(?: to the front)?") {
            return appName(captures[1]).map { .switchToApp(name: $0) }
        }
        return nil
    }

    static let openAppRule: Rule = { text in
        if let captures = firstCapture(text, "(?:open up|fire up|open|launch|start|run|load) (?:the )?(.+?)(?: app| application)?") {
            return appName(captures[1]).map { .openApp(name: $0) }
        }
        return nil
    }

    /// 1–3 words, none that make it something Claude should handle.
    static func appName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let words = trimmed.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return nil }
        guard !words.contains(where: { openTargetStopWords.contains($0) }) else { return nil }
        return trimmed
    }
}

// MARK: - Numbers

/// "forty", "fifty five", "hundred", "half", "max" → 0…100.
public enum VoiceNumberWords {
    static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "to": 2, "too": 2, "three": 3, "four": 4, "for": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19
    ]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let ordinals: [String: Int] = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "1st": 1, "2nd": 2, "3rd": 3, "4th": 4]

    /// A volume / brightness percent (0…100), nil if it isn't a number.
    public static func percent(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "full", "max", "maximum", "full volume", "hundred", "a hundred", "one hundred", "100": return 100
        case "half", "halfway", "half way", "fifty fifty": return 50
        case "zero", "nothing", "minimum", "min", "0": return 0
        default: break
        }
        guard let value = number(trimmed), (0...100).contains(value) else { return nil }
        return value
    }

    public static func number(_ text: String) -> Int? {
        let words = text.split(separator: " ").map(String.init).filter { $0 != "and" }
        guard !words.isEmpty, words.count <= 3 else { return nil }
        if words.count == 1, let value = Int(words[0]) { return value }
        var total = 0
        var sawWord = false
        for word in words {
            if let value = tens[word] {
                guard total % 10 == 0 else { return nil }
                total += value
            } else if let value = units[word] {
                // "to" / "for" alone are words, not numbers.
                if words.count == 1, ["to", "too", "for", "oh"].contains(word) { return nil }
                total += value
            } else if word == "hundred" {
                total = max(1, total) * 100
            } else if let value = Int(word) {
                total += value
            } else {
                return nil
            }
            sawWord = true
        }
        return sawWord ? total : nil
    }

    public static func ordinalOrCardinal(_ word: String) -> Int? {
        ordinals[word] ?? number(word)
    }
}

// MARK: - Safety

/// What the app read just before deciding (frontmost app, focused field, window).
public struct VoiceFastPathFacts: Equatable, Sendable {
    /// The frontmost app and, for field commands, its focused element.
    public var frontmost: ActionTargetFacts?
    /// The front window shows unsaved changes (AXDocument edited / "Edited" in the title).
    public var frontWindowHasUnsavedChanges: Bool
    /// Netflix / Safari is likely what's playing: Safari is frontmost, or a window title shows Netflix.
    public var isNetflixOrSafariLikelyPlaying: Bool

    public init(frontmost: ActionTargetFacts? = nil, frontWindowHasUnsavedChanges: Bool = false, isNetflixOrSafariLikelyPlaying: Bool = false) {
        self.frontmost = frontmost
        self.frontWindowHasUnsavedChanges = frontWindowHasUnsavedChanges
        self.isNetflixOrSafariLikelyPlaying = isNetflixOrSafariLikelyPlaying
    }

    /// "Untitled — Edited" / "notes.txt - Edited".
    public static func titleShowsUnsavedChanges(_ title: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return title.hasSuffix("edited") && (title.contains("— edited") || title.contains("- edited") || title.contains("– edited"))
    }
}

public enum VoiceFastPathDecision: Equatable, Sendable {
    case execute(reason: String)
    /// Wait for a spoken "yes" or a click on the confirm card.
    case confirm(prompt: String, reason: String)
    case refuse(reason: String)

    public var tierName: String {
        switch self {
        case .execute: return "execute"
        case .confirm: return "confirm"
        case .refuse: return "refuse"
        }
    }
}

public enum VoiceFastPathPolicy {
    /// The ActionTierClassifier tier for the command, then the fast-path rule:
    /// the explicit spoken command is the confirm for itself (countdown and
    /// confirm → execute), except lock screen and closing unsaved work.
    public static func decide(_ command: VoiceFastPathCommand, facts: VoiceFastPathFacts, transcript: String) -> VoiceFastPathDecision {
        let context = ActionTurnContext(ownerTranscript: transcript)
        let tierDecision = tier(for: command, facts: facts, context: context)
        switch tierDecision.tier {
        case .refused:
            return .refuse(reason: tierDecision.reason)
        case .free:
            return .execute(reason: tierDecision.reason)
        case .countdown:
            return .execute(reason: "\(tierDecision.reason) (you said it outright)")
        case .confirm:
            switch command {
            case .lockScreen:
                return .confirm(prompt: "Lock the screen?", reason: tierDecision.reason)
            case .key(.closeTab), .key(.closeWindow):
                if facts.frontWindowHasUnsavedChanges {
                    return .confirm(prompt: "That window has unsaved changes. Close it anyway?", reason: "unsaved changes")
                }
                return .execute(reason: "\(tierDecision.reason); you asked for exactly this")
            default:
                return .execute(reason: "\(tierDecision.reason); you asked for exactly this")
            }
        }
    }

    /// The tier, from ActionTierClassifier wherever the command is an action step.
    public static func tier(for command: VoiceFastPathCommand, facts: VoiceFastPathFacts, context: ActionTurnContext) -> ActionTierDecision {
        let frontmost = facts.frontmost
        if let frontmost, frontmost.isOwnApplication, commandActsOnFrontWindow(command) {
            return ActionTierDecision(.refused, "that's Clicky's own window")
        }
        switch command {
        case .volumeUp, .volumeDown, .volumeSet, .mute, .unmute, .brightnessUp, .brightnessDown:
            return ActionTierDecision(.free, "a system level control")
        case .media(_, let namesNetflixOrSafari):
            if facts.isNetflixOrSafariLikelyPlaying && !namesNetflixOrSafari && !context.ownerNamedSafariOrNetflix {
                return ActionTierDecision(.refused, "Netflix or Safari may be playing; say \u{201C}pause Netflix\u{201D} to control it")
            }
            return ActionTierDecision(.free, "a media key")
        case .window:
            guard let frontmost else { return ActionTierDecision(.refused, "no window in front") }
            if ActionTierClassifier.isProtectedFromActions(frontmost) && !context.ownerNamedSafariOrNetflix {
                return ActionTierDecision(.refused, "Safari and Netflix are left alone unless you name them")
            }
            if ActionTierClassifier.isSecurityApplication(frontmost) { return ActionTierDecision(.refused, "security prompts are off limits") }
            return ActionTierDecision(.free, "moving a window")
        case .switchToApp(let name):
            return ActionTierClassifier.classify(.switchWindow(app: name, title: nil), target: nil, context: context)
        case .openApp(let name):
            return ActionTierClassifier.classify(.openApp(name: name, bundleIdentifier: nil), target: nil, context: context)
        case .openItem:
            return ActionTierDecision(.free, "opening a file or folder")
        case .key(let keyCommand):
            return ActionTierClassifier.classify(.key(keyCommand.keyCombo), target: frontmost, context: context)
        case .scroll(let scrollCommand):
            if let keyCombo = scrollCommand.keyCombo {
                // Page / top / bottom keys; a terminal still gets them as a scroll would (not typing).
                if let frontmost, ActionTierClassifier.isTerminal(frontmost) {
                    return ActionTierClassifier.classify(.scroll(elementID: nil, direction: .down, amount: 1), target: frontmost, context: context)
                }
                return ActionTierClassifier.classify(.key(keyCombo), target: frontmost, context: context)
            }
            return ActionTierClassifier.classify(.scroll(elementID: nil, direction: scrollCommand == .up ? .up : .down, amount: 1),
                                                 target: frontmost, context: context)
        case .missionControl, .showDesktop:
            return ActionTierDecision(.free, "showing windows")
        case .readAloud:
            if let frontmost, frontmost.subrole == TypeForMePolicy.secureTextFieldSubrole || frontmost.isSecureEventInputOn {
                return ActionTierDecision(.refused, "that's a password field")
            }
            return ActionTierDecision(.free, "reading the selection")
        case .startDictation, .stopDictation:
            return ActionTierDecision(.free, "dictation mode (each line is checked before typing)")
        case .screenshot:
            return ActionTierDecision(.free, "saving a screenshot")
        case .lockScreen:
            return ActionTierDecision(.confirm, "locking the screen ends what's on it until you sign in")
        }
    }

    static func commandActsOnFrontWindow(_ command: VoiceFastPathCommand) -> Bool {
        switch command {
        case .window, .key, .scroll, .readAloud: return true
        default: return false
        }
    }

    /// Dictation: whether one dictated line may be typed into this field.
    public static func dictationRefusal(focused: ActionTargetFacts?) -> String? {
        guard let focused else { return "no text field is focused" }
        return ActionTierClassifier.targetRefusal(for: .type(elementID: nil, text: "x", pressesReturn: false), target: focused,
                                                  context: ActionTurnContext(ownerTranscript: "type what i say"))?.reason
    }
}
