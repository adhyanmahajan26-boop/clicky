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

    func decide(_ step: ActionStep, _ target: ActionTargetFacts, said transcript: String, current: String? = nil,
                followUp: ActionSafariFollowUp = ActionSafariFollowUp(), now: Date = Date()) -> ActionTierDecision {
        ActionTierClassifier.classify(step, target: target, context: ActionTurnContext(ownerTranscript: transcript, currentTranscript: current,
                                                                                       safariFollowUp: followUp, now: now))
    }

    @Test func ownerSaidItRunsAfterTheCountdown() {
        for target in [Self.chromeAddressBar, Self.claudeApp, Self.messages] {
            #expect(decide(Self.returnKey, target, said: "press enter").tier == .countdown)
            #expect(decide(Self.typeAndEnter, target, said: "type claude.ai and hit enter").tier == .countdown)
            #expect(decide(Self.returnKey, target, said: "Press Centre").tier == .countdown)
            #expect(decide(Self.returnKey, target, said: "Present for me too").tier == .countdown)
            #expect(decide(Self.returnKey, target, said: "enter dabao").tier == .countdown)
        }
        // The turn that started the task, or this turn's own words.
        #expect(decide(Self.returnKey, Self.chromeAddressBar, said: "type claude.ai in chrome", current: "press enter").tier == .countdown)
    }

    @Test func modelGuessedReturnAsksFirst() {
        let decision = decide(Self.returnKey, Self.chromeAddressBar, said: "type claude.ai in the address bar")
        #expect(decision.tier == .confirm)
        #expect(decision.confirmQuestion == "Press enter? Say yes.")
        #expect(decision.confirmWindowSeconds == 6)
        let typed = decide(Self.typeAndEnter, Self.messages, said: "write hi to mom")
        #expect(typed.tier == .confirm)
        #expect(typed.confirmQuestion == "Press enter? Say yes.")
        // A look-alike that isn't short isn't his yes.
        #expect(decide(Self.returnKey, Self.chromeAddressBar, said: "present the slides").tier == .confirm)
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
        #expect(decide(.type(elementID: nil, text: "fix the tests", pressesReturn: true), claude, said: "type fix the tests in claude code and press enter").tier == .countdown)
        #expect(decide(.type(elementID: nil, text: "fix the tests", pressesReturn: false), claude, said: "type fix the tests").tier == .countdown)
        #expect(decide(Self.returnKey, claude, said: "Press Centre").tier == .countdown)
        #expect(decide(Self.returnKey, claude, said: "type it into claude code").tier == .confirm)
        let iterm = ActionTargetFacts(bundleIdentifier: "com.googlecode.iterm2", applicationName: "iTerm2", terminalForeground: .claudeCode)
        #expect(decide(Self.returnKey, iterm, said: "hit enter").tier == .countdown)
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

    // MARK: Safari follow-ups

    @Test func safariNamedInTheSameTaskCovers() {
        #expect(decide(Self.returnKey, Self.safariAddressBar, said: "type claude.ai in safari and press enter").tier == .countdown)
        #expect(decide(Self.returnKey, Self.safariAddressBar, said: "press enter").tier == .refused)
    }

    @Test func safariNamedWithinTwoMinutesCoversTheSameWindow() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var followUp = ActionSafariFollowUp()
        followUp.noteOwnerNamedSafari(windowIdentifier: 41, at: start)
        // "type in Safari …" then "Present for me too" 30 s later.
        #expect(decide(Self.returnKey, Self.safariAddressBar, said: "Present for me too", followUp: followUp, now: start + 30).tier == .countdown)
        #expect(decide(Self.returnKey, Self.safariAddressBar, said: "Press Centre", followUp: followUp, now: start + 119).tier == .countdown)
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
