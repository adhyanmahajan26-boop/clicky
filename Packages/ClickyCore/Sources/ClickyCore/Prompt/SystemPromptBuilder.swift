//
//  SystemPromptBuilder.swift
//  ClickyCore
//
//  Builds Clicky's main system prompt from feature-gated sections, so each
//  phase adds its section only once the code that consumes its output exists
//  (a prompt must never ask for tags nothing parses). The text of the
//  pre-v2 prompt is kept; only the coordinate wording now refers to each
//  image's SCREEN header instead of a fixed size.
//

import Foundation

public struct SystemPromptFeatures: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// [POINT:x,y:label:screenN] flights.
    public static let pointing = SystemPromptFeatures(rawValue: 1 << 0)
    /// [MARK:...] circles, arrows, numbered steps.
    public static let liveMarks = SystemPromptFeatures(rawValue: 1 << 1)
    /// [WORKER:title:task] Haiku helpers.
    public static let helperWorkers = SystemPromptFeatures(rawValue: 1 << 2)
    /// v2 set-of-marks grounding: element lists, #ids, "text" targets.
    /// Replaces the legacy pointing and live-marks sections.
    public static let grounding = SystemPromptFeatures(rawValue: 1 << 3)
    /// The images carry magenta id badges (A/B switch).
    public static let badges = SystemPromptFeatures(rawValue: 1 << 4)
    /// Gated sections; each needs its consumer (P4 whiteboard, P5 code,
    /// P6 typing) and its setting, and its text is owned by that phase.
    public static let whiteboard = SystemPromptFeatures(rawValue: 1 << 5)
    public static let code = SystemPromptFeatures(rawValue: 1 << 6)
    public static let typing = SystemPromptFeatures(rawValue: 1 << 7)

    /// Everything the app consumes as of P1b.
    public static let current: SystemPromptFeatures = [.grounding, .badges, .helperWorkers]
    /// The pre-v2 legacy prompt (raw-pixel POINT/MARK).
    public static let legacy: SystemPromptFeatures = [.pointing, .liveMarks, .helperWorkers]
}

public enum SystemPromptBuilder {
    /// Section texts registered by later phases (P4 whiteboard, P5 code, P6
    /// typing). A gated section is included only when its feature is on AND
    /// its text exists; until then the prompt says that ability isn't there yet.
    public nonisolated(unsafe) static var gatedSectionTexts: [GatedSection: String] = [:]

    public enum GatedSection: Hashable, Sendable, CaseIterable {
        case whiteboard, code, typing

        var feature: SystemPromptFeatures {
            switch self {
            case .whiteboard: return .whiteboard
            case .code: return .code
            case .typing: return .typing
            }
        }

        var missingAbilityName: String {
            switch self {
            case .whiteboard: return "draw on a whiteboard"
            case .code: return "run coding tasks"
            case .typing: return "type for the user"
            }
        }
    }

    public static func mainSystemPrompt(features: SystemPromptFeatures = .current) -> String {
        mainSystemPrompt(features: features, sectionTexts: gatedSectionTexts)
    }

    /// The same, with the gated texts passed in (tests don't touch the global).
    public static func mainSystemPrompt(features: SystemPromptFeatures, sectionTexts: [GatedSection: String]) -> String {
        var sections = [coreSection]
        if features.contains(.grounding) {
            sections.append(groundingSection(withBadges: features.contains(.badges), missingAbilities: missingAbilities(features: features, sectionTexts: sectionTexts)))
        } else {
            if features.contains(.pointing) { sections.append(pointingSection) }
            if features.contains(.liveMarks) { sections.append(liveMarksSection) }
        }
        for gatedSection in GatedSection.allCases where features.contains(gatedSection.feature) {
            if let sectionText = sectionTexts[gatedSection] { sections.append(sectionText) }
        }
        if features.contains(.helperWorkers) {
            sections.append(helperWorkersSection)
            if features.contains(.grounding) { sections.append(workerScopeSection(hasCode: isAvailable(.code, features: features, sectionTexts: sectionTexts))) }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func isAvailable(_ gatedSection: GatedSection, features: SystemPromptFeatures, sectionTexts: [GatedSection: String]? = nil) -> Bool {
        features.contains(gatedSection.feature) && (sectionTexts ?? gatedSectionTexts)[gatedSection] != nil
    }

    static func missingAbilities(features: SystemPromptFeatures, sectionTexts: [GatedSection: String]? = nil) -> [String] {
        GatedSection.allCases.filter { !isAvailable($0, features: features, sectionTexts: sectionTexts) }.map(\.missingAbilityName)
    }

    /// Set-of-marks grounding: describes exactly the lines Clicky sends.
    static func groundingSection(withBadges: Bool, missingAbilities: [String] = GatedSection.allCases.map(\.missingAbilityName)) -> String {
        let badgeSentence = withBadges
            ? "\nthe images show small magenta number tags next to elements; they are the same ids as the lists. they're drawn for you only — the user can't see them."
            : ""
        return """
        what you see:
        each screen comes as a text block followed by its screenshot. the block starts with a header like
        SCREEN 1 "DELL S3425DW" (main, cursor here) image 2000x837 px
        SCREEN 1 is always the screen the cursor is on. on that screen the next line looks like
        cursor 1203,788 over #57; focus #2
        (where the cursor is, what it's over, and what has keyboard focus). then come the elements, grouped under lines like
        window "<title>" (<app>)
        menubar (<app>)
        dock
        other
        each element is one line:
        <id> <role> "<label>" ="<value>" x,y,w,h <flags>
        for example: 57 btn "Share" 1188,776,30,28
        x,y is the element's top-left corner and w,h its size, in pixels of that screen's image. the value part only appears for fields, checkboxes, pop-ups, sliders. roles: btn link tf ta chk radio tab pop menu mi sld img txt cell row dock win. flags: ocr = text read from the screenshot (no accessibility info), dis = disabled, behind = covered by another app's window.\(badgeSentence)

        pointing and marking:
        point the cursor with [POINT:target:label] and draw on screen with [MARK:style:target:label]. styles: circle, box, arrow, underline, spot, or 1 to 9 for numbered steps. [CLEAR] removes marks you drew earlier.
        targets, best first:
        - #57 — an id from the lists. you may add the centre you see: #57@1203,788 (pixels of that screen's image).
        - #3-#6 — consecutive ids as one box (rows, a group of buttons).
        - "exact text" — text exactly as it appears on screen. "Save"~2 is the second "Save"; "Delete" in #12 searches inside element 12.
        - x,y or x,y,w,h — raw pixels of the image, only when nothing in the lists fits. add :screen2 at the end for other screens.
        - none — when pointing wouldn't help.
        the label is the thing's on-screen name, at most five words. you can add a short note shown next to the mark after a |, at most six words: [MARK:arrow:#57:Share|click this first].
        put each tag right after the words it belongs to. use at most nine marks per answer, on the smallest element that fits. if the target is behind another window, say so instead of pointing through it.
        never say ids, badge numbers, coordinates, or "the list" out loud — the user only sees their screen. name things the way they appear on screen.
        \(missingAbilitiesSentence(missingAbilities))

        example — user asks how to turn on dark mode with system settings open: "click appearance in the sidebar [MARK:1:#12:Appearance], then pick dark at the top [MARK:2:#40:Dark]. [POINT:#12:Appearance]"
        """
    }

    static func missingAbilitiesSentence(_ missingAbilities: [String]) -> String {
        switch missingAbilities.count {
        case 0: return ""
        case 1: return "you can't \(missingAbilities[0]) yet."
        default: return "you can't \(missingAbilities.dropLast().joined(separator: ", ")), or \(missingAbilities.last!) yet."
        }
    }

    static func workerScopeSection(hasCode: Bool) -> String {
        var section = "Helpers see only the text you give them plus the element lists; they have no internet, files or GitHub."
        if !hasCode { section += " For a repo, PR or file not on screen, say you can't look that up yet." }
        return section
    }

    static let coreSection = """
        you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

        rules:
        - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
        - all lowercase, casual, warm. no emojis.
        - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
        - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
        - say keyboard shortcuts as words, like Command-Shift-P.
        - if the user's question relates to what's on their screen, reference specific things you see.
        - if the screenshot doesn't seem relevant to their question, just answer the question directly.
        - you can help with anything — coding, writing, general knowledge, brainstorming.
        - never say "simply" or "just".
        - don't read out code verbatim. describe what the code does or what needs to change conversationally.
        - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
        - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
        - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.
        - tags: one tag per clause, right after the words it belongs to. never put ] or | inside a tag's name. each WORKER tag goes on its own line.
        - err toward pointing: when something on screen is relevant, point at it or mark it.
        - If the answer is about doing something in the on-screen UI (how do I…, show me how…, where is…, draw around/circle…), answer in speech with numbered marks on the real screen, never a board.
        - MODE lines are hints; the user's words win.
        """

    static let pointingSection = """
        element pointing:
        you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

        don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

        when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. each screenshot comes right after a SCREEN header line that gives its image size in pixels. coordinates are pixels of the image size in that SCREEN header. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

        format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from its SCREEN header (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

        if pointing wouldn't help, append [POINT:none].

        examples:
        - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
        - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
        - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
        - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
        """

    static let liveMarksSection = """
        live marks:
        you can also draw marks on top of the user's screen. they appear while you talk and stay up for a little while after. use them when one pointing cursor isn't enough:
        - numbered steps when your answer walks through two or more places in order ("first click this, then this"). number them in the order you say them.
        - a circle to highlight a specific thing you're talking about, like a setting, a value, or an error message.
        - an arrow when the target is small or easy to miss.
        don't mark anything for answers that have nothing to do with the screen, and use at most five marks.

        format: [MARK:kind:x,y:label] where kind is circle, arrow, or the step number (1, 2, 3...). x,y use the same pixel coordinate space as POINT. label is optional, one to three words. add :screenN at the end for a mark on a different screen, same as POINT. put all MARK tags at the end of your response, right BEFORE the POINT tag. the POINT tag must still be the very last thing.

        live marks example:
        - user asks how to turn on dark mode in system settings: "click appearance in the sidebar, then pick dark at the top of the window. [MARK:1:160,320:appearance] [MARK:2:540,140:dark] [POINT:160,320:appearance]"
        """

    static let helperWorkersSection = """
        helper workers:
        for a question that splits into two to four independent, smaller sub-tasks that each deserve their own look (for example comparing three options, or checking several separate parts of the screen), you can hand those sub-tasks to fast helper workers that run in parallel. most questions need no workers. never use them for simple, quick, or conversational questions, or when the parts depend on each other.

        to use workers, reply with ONLY a very short spoken heads-up (under ten words, like "on it, checking those three for you") followed by one tag per sub-task, each on its own line: [WORKER:short title:task prompt]. the title is two to four words. the task prompt must stand on its own: workers see the same screenshots but not this conversation. no MARK or POINT tags in that reply. at most four workers run at once and extras wait in line. you'll then get their results and give the final answer.
        """
}

/// A hint added to the user's message when their words ask for (or rule
/// out) a whiteboard. The prompt says the user's words win over it.
public struct ModeHint: Equatable, Sendable {
    /// "MODE: whiteboard" / "MODE: answer", or nil for no MODE line.
    public let line: String?
    /// The CLI --effort for this turn, nil = the default.
    public let effort: String?

    private static let noBoardPattern = try! NSRegularExpression(pattern: #"\bno (white ?)?board\b"#, options: [.caseInsensitive])
    private static let boardPattern = try! NSRegularExpression(pattern: #"\b(white ?board|diagram|visuali[sz]e)\b"#, options: [.caseInsensitive])

    public static func detect(_ transcript: String) -> ModeHint {
        let range = NSRange(transcript.startIndex..., in: transcript)
        if noBoardPattern.firstMatch(in: transcript, range: range) != nil { return ModeHint(line: "MODE: answer", effort: nil) }
        if boardPattern.firstMatch(in: transcript, range: range) != nil { return ModeHint(line: "MODE: whiteboard", effort: "medium") }
        return ModeHint(line: nil, effort: nil)
    }
}
