//
//  ActionEnterPolicyTests.swift
//  ClickyCoreTests
//
//  P8: Enter / Return for computer-use actions — the owner's enter intent
//  (ASR-tolerant), the tiers it leads to, terminals running Claude Code,
//  and the Safari follow-up window.
//

import Foundation
import Testing
@testable import ClickyCore

struct ActionEnterIntentTests {
    func asked(_ transcript: String, returnStep: Bool = true) -> Bool {
        ActionEnterIntent.ownerAsked(transcript, stepPressesReturn: returnStep)
    }

    @Test func theTwoRealASRStringsCountWithAReturnStep() {
        #expect(asked("Present for me too"))
        #expect(asked("Press Centre"))
        #expect(asked("Press Centre."))
        #expect(asked("present for me too", returnStep: true))
        // Without a Return step they aren't an enter intent.
        #expect(!asked("Present for me too", returnStep: false))
        #expect(!asked("Press Centre", returnStep: false))
    }

    @Test func explicitEnglishPhrases() {
        for phrase in ["press enter", "Hit enter.", "press return", "hit return please", "the enter key", "type hello and enter", "type it then enter",
                       "send it", "reply ok and send", "submit", "submit the form", "press the enter key", "hit the return key", "press inter",
                       "Clicky, press enter now", "and send it to him"] {
            #expect(asked(phrase, returnStep: false), "\(phrase)")
            #expect(asked(phrase, returnStep: true), "\(phrase)")
        }
    }

    @Test func hindiAndHinglishPhrases() {
        for phrase in ["enter dabao", "Enter daba do", "enter karo", "enter kar do", "enter press karo", "bhej do", "message bhej do",
                       "send kar do", "haan send karo", "एंटर दबाओ", "भेज दो"] {
            #expect(asked(phrase, returnStep: false), "\(phrase)")
        }
    }

    @Test func shortASRLookAlikesOnlyForAReturnStep() {
        for phrase in ["press center", "press centre please", "present", "president", "press entre", "press under", "press inter now",
                       "enter", "enter please", "return", "hit centre", "okay press center", "press enter for me too"] {
            #expect(asked(phrase, returnStep: true), "\(phrase)")
        }
        for phrase in ["press center", "present", "president", "enter", "press under"] {
            #expect(!asked(phrase, returnStep: false), "\(phrase)")
        }
    }

    @Test func negatives() {
        // Without a Return step context.
        for phrase in ["present the slides", "send me the file", "enter the matrix", "type hello", "what does the send button do",
                       "the enterprise plan", "the president of france", "center the title", "return the book"] {
            #expect(!asked(phrase, returnStep: false), "\(phrase)")
        }
        // Real words around a look-alike: not an enter intent even for a Return step.
        for phrase in ["present the slides", "enter the matrix", "send me the file", "the president of france", "center the title",
                       "return the book tomorrow", "presentation"] {
            #expect(!asked(phrase, returnStep: true), "\(phrase)")
        }
        // Long utterances only count through explicit phrases.
        #expect(!asked("i want to present this for my team", returnStep: true))
    }

    @Test func confirmRepliesIncludeHindi() {
        for yes in ["yes", "haan", "ha", "Haan ji", "ok", "okay", "do it", "go ahead", "theek hai", "haan kar do"] {
            #expect(ActionConfirmReply.parse(yes) == .yes, "\(yes)")
        }
        for no in ["nahi", "mat karo", "no"] {
            #expect(ActionConfirmReply.parse(no) == .no, "\(no)")
        }
    }

    @Test func stepKnowsItPressesReturn() {
        #expect(ActionStep.type(elementID: 1, text: "x", pressesReturn: true).pressesReturn)
        #expect(!ActionStep.type(elementID: 1, text: "x", pressesReturn: false).pressesReturn)
        #expect(ActionStep.key(ActionKeyCombo.parse("return")!).pressesReturn)
        #expect(ActionStep.key(ActionKeyCombo.parse("enter")!).pressesReturn)
        #expect(!ActionStep.key(ActionKeyCombo.parse("tab")!).pressesReturn)
    }
}

struct ActionEnterTierTests {
    static let returnKey = ActionStep.key(ActionKeyCombo.parse("return")!)
    static let typeAndEnter = ActionStep.type(elementID: nil, text: "claude.ai", pressesReturn: true)
    static let chromeAddressBar = ActionTargetFacts(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "New Tab",
                                                    role: "AXTextField", groundingRole: .textField, label: "Address and search bar", windowIdentifier: 7)
    static let safariAddressBar = ActionTargetFacts(bundleIdentifier: "com.apple.Safari", applicationName: "Safari", windowTitle: "Start Page",
                                                    role: "AXTextField", label: "Smart Search Field", windowIdentifier: 41)
    static let claudeApp = ActionTargetFacts(bundleIdentifier: "com.anthropic.claudefordesktop", applicationName: "Claude", windowTitle: "Claude",
                                             role: "AXTextArea", label: "Write your prompt to Claude")
    static let messages = ActionTargetFacts(bundleIdentifier: "com.apple.MobileSMS", applicationName: "Messages", role: "AXTextArea", label: "iMessage")

    /// With "leave Safari alone" on, so the Safari follow-up rules below are what's tested (off is the default; see ActionsTests).
    func decide(_ step: ActionStep, _ target: ActionTargetFacts, said transcript: String, current: String? = nil,
                followUp: ActionSafariFollowUp = ActionSafariFollowUp(), now: Date = Date()) -> ActionTierDecision {
        ActionTierClassifier.classify(step, target: target, context: ActionTurnContext(ownerTranscript: transcript, currentTranscript: current,
                                                                                       safariFollowUp: followUp, now: now, leavesSafariAlone: true))
    }

    @Test func ownerSaidItPressesEnterRightAway() {
        // P9: no countdown and no question when he asked.
        for target in [Self.chromeAddressBar, Self.claudeApp, Self.messages] {
            for said in ["press enter", "Press Centre", "Present for me too", "enter dabao", "send it"] {
                let decision = decide(Self.returnKey, target, said: said)
                #expect(decision.tier == .free && !decision.dropsReturn, "\(said) on \(target.applicationName ?? "")")
            }
            #expect(decide(Self.typeAndEnter, target, said: "type claude.ai and hit enter").tier == .free)
        }
        #expect(decide(Self.returnKey, Self.chromeAddressBar, said: "type claude.ai in chrome", current: "press enter").tier == .free)
    }

    @Test func searchingImpliesEnterAndNoOneIsAsked() {
        for said in ["search weather in delhi", "google swift actors", "look up the black hole article", "go to nasa.gov"] {
            let decision = decide(Self.typeAndEnter, Self.chromeAddressBar, said: said)
            #expect(decision.tier == .free && !decision.dropsReturn && decision.confirmQuestion == nil, "\(said)")
        }
        // A search box / address bar / prompt box gets its Enter even when he didn't say it.
        #expect(!decide(Self.returnKey, Self.chromeAddressBar, said: "type claude.ai in the address bar").dropsReturn)
        #expect(!decide(Self.typeAndEnter, Self.claudeApp, said: "ask claude what time it is in tokyo").dropsReturn)
    }

    @Test func messagesToPeopleWaitForSend() {
        let typed = decide(Self.typeAndEnter, Self.messages, said: "write hi to mom")
        #expect(typed.tier == .free && typed.dropsReturn)
        #expect(typed.spokenLine == "Typed it, say send to send.")
        #expect(!decide(Self.returnKey, Self.messages, said: "send").dropsReturn)
        // Searching words aren't a "send" for a message.
        #expect(decide(Self.typeAndEnter, Self.messages, said: "write find me later to mom").dropsReturn)
    }

    @Test func writingInADocumentNeverPressesEnter() {
        let editor = ActionTargetFacts(bundleIdentifier: "com.apple.TextEdit", applicationName: "TextEdit", role: "AXTextArea", label: "text")
        let decision = decide(Self.typeAndEnter, editor, said: "write a haiku about rain")
        #expect(decision.tier == .free && decision.dropsReturn && decision.spokenLine == nil)
        #expect(ActionStep.type(elementID: 3, text: "x", pressesReturn: true).withoutReturn == .type(elementID: 3, text: "x", pressesReturn: false))
    }

    @Test func typingWithoutReturnIsUnchangedAndSendButtonsNeedAYesUnlessHeSaidSend() {
        #expect(decide(.type(elementID: nil, text: "hi", pressesReturn: false), Self.messages, said: "write hi").tier == .countdown)
        let sendButton = ActionTargetFacts(bundleIdentifier: "com.apple.mail", applicationName: "Mail", groundingRole: .button, label: "Send")
        #expect(decide(.click(elementID: 3), sendButton, said: "reply thanks").tier == .confirm)
        #expect(decide(.click(elementID: 3), sendButton, said: "reply thanks and send it").tier == .countdown)
        #expect(decide(.click(elementID: 3), sendButton, said: "reply thanks and bhej do").tier == .countdown)
        // Other confirm buttons stay confirm.
        let deleteButton = ActionTargetFacts(bundleIdentifier: "com.apple.mail", applicationName: "Mail", groundingRole: .button, label: "Delete")
        #expect(decide(.click(elementID: 3), deleteButton, said: "delete it and send it").tier == .confirm)
    }

    @Test func refusedStepsCarryASpokenReason() {
        let password = ActionTargetFacts(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", subrole: "AXSecureTextField")
        let decision = decide(Self.typeAndEnter, password, said: "type my password and press enter")
        #expect(decision.tier == .refused)
        #expect(decision.refusalLine(for: Self.typeAndEnter).contains("password"))
        #expect(!decision.refusalLine(for: Self.typeAndEnter).isEmpty)
        // Return into System Settings: still a yes first, even when asked.
        let settings = ActionTargetFacts(bundleIdentifier: "com.apple.systempreferences", applicationName: "System Settings", windowTitle: "Wi-Fi")
        #expect(decide(Self.returnKey, settings, said: "press enter").tier == .confirm)
    }

    // MARK: Terminals

    static func terminal(_ foreground: ActionTerminalForeground?) -> ActionTargetFacts {
        ActionTargetFacts(bundleIdentifier: "com.apple.Terminal", applicationName: "Terminal", windowTitle: "claude — ttys004", role: "AXTextArea",
                          terminalForeground: foreground)
    }

    @Test func claudeCodeInATerminalIsAChatBox() {
        let claude = Self.terminal(.claudeCode)
        // Claude Code's prompt is a prompt box: its Enter is automatic.
        #expect(decide(.type(elementID: nil, text: "fix the tests", pressesReturn: true), claude, said: "type fix the tests in claude code and press enter").tier == .free)
        #expect(decide(.type(elementID: nil, text: "fix the tests", pressesReturn: false), claude, said: "type fix the tests").tier == .countdown)
        #expect(decide(Self.returnKey, claude, said: "Press Centre").tier == .free)
        #expect(!decide(Self.returnKey, claude, said: "type it into claude code").dropsReturn)
        let iterm = ActionTargetFacts(bundleIdentifier: "com.googlecode.iterm2", applicationName: "iTerm2", terminalForeground: .claudeCode)
        #expect(decide(Self.returnKey, iterm, said: "hit enter").tier == .free)
    }

    @Test func aShellPromptIsRefusedWithTheCodeTaskOffer() {
        for foreground in [ActionTerminalForeground.shell, .otherCommand("vim"), nil] {
            let decision = decide(.type(elementID: nil, text: "ls", pressesReturn: true), Self.terminal(foreground), said: "type ls and press enter")
            #expect(decision.tier == .refused)
            #expect(decision.refusalLine(for: .type(elementID: nil, text: "ls", pressesReturn: true))
                    == "I won't type into a shell \u{2014} want me to do that as a code task instead?")
        }
        let ghostty = ActionTargetFacts(bundleIdentifier: "com.mitchellh.ghostty", applicationName: "Ghostty", terminalForeground: .shell)
        #expect(decide(Self.returnKey, ghostty, said: "press enter").tier == .refused)
    }

    @Test func foregroundClassification() {
        func process(_ pid: pid_t, group: pid_t, foreground: pid_t, _ name: String, path: String? = nil) -> TerminalTTYLookup.TTYProcess {
            TerminalTTYLookup.TTYProcess(processIdentifier: pid, processGroupIdentifier: group, foregroundProcessGroupIdentifier: foreground, name: name,
                                         workingDirectory: nil, executablePath: path)
        }
        // Claude Code's native binary is named after its version.
        let claudeTab = [process(10, group: 10, foreground: 20, "login"), process(11, group: 11, foreground: 20, "-zsh"),
                         process(20, group: 20, foreground: 20, "2.1.301", path: "/Users/me/.local/share/claude/versions/2.1.301")]
        #expect(TerminalTTYLookup.classifyForeground(claudeTab) == .claudeCode)
        #expect(TerminalTTYLookup.classifyForeground([process(11, group: 11, foreground: 30, "zsh"), process(30, group: 30, foreground: 30, "claude")]) == .claudeCode)
        let shellTab = [process(10, group: 10, foreground: 11, "login"), process(11, group: 11, foreground: 11, "-zsh")]
        #expect(TerminalTTYLookup.classifyForeground(shellTab) == .shell)
        let vimTab = [process(11, group: 11, foreground: 40, "zsh"), process(40, group: 40, foreground: 40, "vim")]
        #expect(TerminalTTYLookup.classifyForeground(vimTab) == .otherCommand("vim"))
        // Claude Code in the background (suspended) isn't the prompt.
        let backgrounded = [process(11, group: 11, foreground: 11, "zsh"), process(20, group: 20, foreground: 11, "claude")]
        #expect(TerminalTTYLookup.classifyForeground(backgrounded) == .shell)
        #expect(TerminalTTYLookup.classifyForeground([]) == nil)
        #expect(TerminalTTYLookup.isClaudeCode(name: "claude", executablePath: nil))
        #expect(!TerminalTTYLookup.isClaudeCode(name: "node", executablePath: "/opt/homebrew/bin/node"))
        #expect(!TerminalTTYLookup.isClaudeCode(name: "zsh", executablePath: "/bin/zsh"))
    }

    // MARK: Return on a selected item

    /// Live 2026-11-13: Spotify, "play Ambarsaria" → click the song, then Return. The Return was dropped as
    /// "typed only", so the song was selected but never played.
    @Test func returnOnASelectedItemIsPressed() {
        let spotifyRow = ActionTargetFacts(bundleIdentifier: "com.spotify.client", applicationName: "Spotify", windowTitle: "Spotify Premium", role: "AXRow",
                                           label: "Ambarsaria")
        let row = decide(Self.returnKey, spotifyRow, said: "Amasya song for me can you play it")
        #expect(row.tier != .refused)
        #expect(row.tier != .confirm)
        #expect(!row.dropsReturn)
        // Focus Clicky can't read (Spotify keeps its AX tree mostly off): pressed after the usual countdown.
        let unknownFocus = ActionTargetFacts(bundleIdentifier: "com.spotify.client", applicationName: "Spotify", windowTitle: "Spotify Premium")
        let unknown = decide(Self.returnKey, unknownFocus, said: "Amasya song for me can you play it")
        #expect(unknown.tier == .countdown)
        #expect(!unknown.dropsReturn)
        let finderFile = ActionTargetFacts(bundleIdentifier: "com.apple.finder", applicationName: "Finder", role: "AXTextField", subrole: nil, label: "report.pdf")
        // A text field (even Finder's rename box) keeps the typing rules: no Return unless asked.
        #expect(decide(Self.returnKey, finderFile, said: "rename it").dropsReturn)
    }

    /// Enter on a focused button is as careful as clicking it (review on PR #13): a dialog's default "Delete" or a
    /// "Buy now" waits for a yes, even when the owner said "press enter".
    @Test func returnOnAFocusedButtonIsAsCarefulAsAClick() {
        let deleteButton = ActionTargetFacts(bundleIdentifier: "com.apple.finder", applicationName: "Finder", windowTitle: "Delete?",
                                             role: "AXButton", label: "Delete")
        #expect(decide(Self.returnKey, deleteButton, said: "clean up my downloads").tier == .confirm)
        #expect(decide(Self.returnKey, deleteButton, said: "press enter").tier == .confirm)
        let buyButton = ActionTargetFacts(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "Checkout", role: "AXButton", label: "Buy now")
        #expect(decide(Self.returnKey, buyButton, said: "get me that charger").tier == .confirm)
        let settingsToggle = ActionTargetFacts(bundleIdentifier: "com.apple.systempreferences", applicationName: "System Settings", windowTitle: "Wi-Fi",
                                               role: "AXCheckBox", label: "Wi-Fi")
        #expect(decide(Self.returnKey, settingsToggle, said: "press enter").tier == .confirm)
        // An ordinary focused button: same countdown as a click, free when the owner asked for Enter.
        let okButton = ActionTargetFacts(bundleIdentifier: "com.apple.Preview", applicationName: "Preview", role: "AXButton", label: "Open")
        #expect(decide(Self.returnKey, okButton, said: "show me that file").tier == .countdown)
        #expect(decide(Self.returnKey, okButton, said: "press enter").tier == .free)
    }

    @Test func returnStillWaitsInTextFieldsAndMessages() {
        let document = ActionTargetFacts(bundleIdentifier: "com.apple.TextEdit", applicationName: "TextEdit", windowTitle: "Untitled", role: "AXTextArea")
        #expect(decide(Self.returnKey, document, said: "write hello").dropsReturn)
        #expect(decide(Self.returnKey, Self.messages, said: "tell mom hi").dropsReturn)
        let messagesNoFocus = ActionTargetFacts(bundleIdentifier: "com.apple.MobileSMS", applicationName: "Messages")
        #expect(decide(Self.returnKey, messagesNoFocus, said: "tell mom hi").dropsReturn)
        #expect(!decide(Self.returnKey, Self.messages, said: "send it").dropsReturn)
    }

    // MARK: Safari follow-ups

    @Test func safariNamedInTheSameTaskCovers() {
        #expect(decide(Self.returnKey, Self.safariAddressBar, said: "type claude.ai in safari and press enter").tier == .free)
        #expect(decide(Self.returnKey, Self.safariAddressBar, said: "press enter").tier == .refused)
    }

    @Test func safariNamedWithinTwoMinutesCoversTheSameWindow() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var followUp = ActionSafariFollowUp()
        followUp.noteOwnerNamedSafari(windowIdentifier: 41, at: start)
        // "type in Safari …" then "Present for me too" 30 s later.
        #expect(decide(Self.returnKey, Self.safariAddressBar, said: "Present for me too", followUp: followUp, now: start + 30).tier == .free)
        #expect(decide(Self.returnKey, Self.safariAddressBar, said: "Press Centre", followUp: followUp, now: start + 119).tier == .free)
        // Past 2 minutes: refused again (with a reason).
        let late = decide(Self.returnKey, Self.safariAddressBar, said: "press enter", followUp: followUp, now: start + 125)
        #expect(late.tier == .refused)
        #expect(late.refusalLine(for: Self.returnKey).contains("Safari"))
        // Another Safari window isn't covered.
        var otherWindow = Self.safariAddressBar
        otherWindow.windowIdentifier = 99
        #expect(decide(Self.returnKey, otherWindow, said: "press enter", followUp: followUp, now: start + 30).tier == .refused)
        // A window showing Netflix needs "netflix" said.
        var netflix = Self.safariAddressBar
        netflix.windowTitle = "Stranger Things | Netflix"
        #expect(decide(.key(ActionKeyCombo.parse("space")!), netflix, said: "pause it", followUp: followUp, now: start + 30).tier == .refused)
        #expect(decide(.key(ActionKeyCombo.parse("space")!), netflix, said: "pause netflix", followUp: followUp, now: start + 30).tier == .countdown)
        // A Chrome window isn't Safari: the follow-up doesn't matter there.
        #expect(!followUp.covers(Self.chromeAddressBar, ownerNamedNetflix: false, at: start + 30))
    }

    @Test func safariGrantWithoutAWindowCoversAnySafariWindow() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        var followUp = ActionSafariFollowUp()
        followUp.noteOwnerNamedSafari(windowIdentifier: nil, at: start)
        #expect(followUp.covers(Self.safariAddressBar, ownerNamedNetflix: false, at: start + 60))
        #expect(!followUp.covers(Self.safariAddressBar, ownerNamedNetflix: false, at: start + 121))
        // Notes older than 2 minutes are dropped.
        followUp.noteOwnerNamedSafari(windowIdentifier: 5, at: start + 200)
        #expect(followUp.grants.count == 1)
    }
}

/// Live P8 run: "click #68 (the search box), type … + return" skipped the type step as stale.
@Test func clickingIntoATextFieldKeepsLaterIDsValid() {
    let click = ActionStep.click(elementID: 68)
    #expect(!click.changesScreen(targetRole: "AXTextField"))
    #expect(!click.changesScreen(targetRole: "AXSearchField"))
    #expect(click.changesScreen(targetRole: "AXLink"))
    #expect(click.changesScreen(targetRole: nil))
}
