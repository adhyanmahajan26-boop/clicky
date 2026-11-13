import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// MARK: - DSL parsing

struct ActionDSLTests {
    func plan(_ body: String) throws -> ActionPlan {
        try ActionDSL.parse(body).get()
    }

    @Test func parsesTheOwnersExampleTask() throws {
        let parsed = try plan("""
            {"goal":"ramen","steps":[{"do":"open_app","name":"Google Chrome"},{"do":"search","query":"best ramen","engine":"google"},
             {"do":"click","id":14},{"do":"highlight","targets":[3,"#4","Opening hours"],"notes":["key fact"]},{"do":"summarize"}],"done":false}
            """)
        #expect(parsed.goal == "ramen")
        #expect(!parsed.isDone)
        #expect(parsed.rejectedSteps.isEmpty)
        #expect(parsed.steps == [
            .openApp(name: "Google Chrome", bundleIdentifier: nil),
            .search(query: "best ramen", engine: .google),
            .click(elementID: 14),
            .highlight(targets: [.element(3), .element(4), .text("Opening hours")], notes: ["key fact"]),
            .summarize(text: nil, title: nil)
        ])
    }

    @Test func everyVerbParses() throws {
        let parsed = try plan("""
            {"steps":[
             {"do":"open_app","bundle":"com.apple.TextEdit"},
             {"do":"open_url","url":"example.com/a"},
             {"do":"search","query":"cats","engine":"youtube"},
             {"do":"type","id":"#5","text":"hello"},
             {"do":"type","text":"focused"},
             {"do":"key","combo":"cmd+shift+n"},
             {"do":"scroll","direction":"up","amount":40},
             {"do":"select_copy","text":"copy me"},
             {"do":"wait","seconds":9},
             {"do":"switch_window","app":"Notes"},
             {"do":"summarize","text":"- a\\n- b","title":"T"},
             {"do":"code_task","project":"clicky","instructions":"fix it"}
            ],"done":true}
            """)
        #expect(parsed.isDone)
        #expect(parsed.steps.count == 12)
        #expect(parsed.steps[1] == .openURL(URL(string: "https://example.com/a")!))
        #expect(parsed.steps[2] == .search(query: "cats", engine: .youtube))
        #expect(parsed.steps[3] == .type(elementID: 5, text: "hello", pressesReturn: false))
        #expect(parsed.steps[4] == .type(elementID: nil, text: "focused", pressesReturn: false))
        if case .key(let combo) = parsed.steps[5] {
            #expect(combo.modifiers == [.command, .shift])
            #expect(combo.key == "n")
            #expect(combo.virtualKeyCode == 45)
        } else { Issue.record("not a key step") }
        // Amount clamped to 10, wait to 5 s.
        #expect(parsed.steps[6] == .scroll(elementID: nil, direction: .up, amount: 10))
        #expect(parsed.steps[8] == .wait(seconds: 5))
        #expect(parsed.steps[10] == .summarize(text: "- a\n- b", title: "T"))
        #expect(parsed.steps[11] == .codeTask(project: "clicky", instructions: "fix it"))
    }

    @Test func invalidEnvelopesFail() {
        #expect(ActionDSL.parse("") == .failure(.empty))
        #expect(ActionDSL.parse("not json") == .failure(.notJSON))
        #expect(ActionDSL.parse("[1,2]") == .failure(.notJSON))
        #expect(ActionDSL.parse(#"{"goal":"x"}"#) == .failure(.noStepsArray))
        #expect(ActionDSL.parse(#"{"steps":[]}"#) == .failure(.noUsableSteps([])))
        let thirteen = (1...13).map { _ in #"{"do":"wait","seconds":1}"# }.joined(separator: ",")
        #expect(ActionDSL.parse(#"{"steps":[\#(thirteen)]}"#) == .failure(.tooManySteps(count: 13)))
    }

    @Test func oversizedBodyFails() {
        let huge = #"{"steps":[{"do":"type","text":""# + String(repeating: "a", count: ActionDSL.maximumBodyLength) + #""}]}"#
        guard case .failure(.tooLong) = ActionDSL.parse(huge) else { Issue.record("expected tooLong"); return }
    }

    @Test func oversizedTypedTextIsRejectedPerStep() throws {
        let text = String(repeating: "b", count: ActionDSL.maximumTypedTextLength + 1)
        let parsed = try plan(#"{"steps":[{"do":"type","text":"\#(text)"},{"do":"wait","seconds":1}]}"#)
        #expect(parsed.steps == [.wait(seconds: 1)])
        #expect(parsed.rejectedSteps.first?.position == 1)
    }

    @Test func doneAloneIsAFinishedTask() throws {
        let parsed = try plan(#"{"goal":"g","done":true}"#)
        #expect(parsed.isDone)
        #expect(parsed.steps.isEmpty)
    }

    @Test func badStepsAreListedAndTheRestRun() throws {
        let parsed = try plan("""
            {"steps":[{"do":"teleport"},{"do":"click"},{"do":"open_url","url":"file:///etc/passwd"},{"do":"open_url","url":"javascript:alert(1)"},
             {"do":"key","combo":"cmd+nope"},{"do":"search","query":"x","engine":"bing"},"text",{"do":"click","id":0},{"do":"wait","seconds":1}]}
            """)
        #expect(parsed.steps == [.wait(seconds: 1)])
        #expect(parsed.rejectedSteps.map(\.position) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(parsed.rejectedSteps[0].reason.contains("unknown step"))
    }

    @Test func allBadStepsFail() {
        guard case .failure(.noUsableSteps(let rejections)) = ActionDSL.parse(#"{"steps":[{"do":"click"}]}"#) else { Issue.record("expected failure"); return }
        #expect(rejections.count == 1)
    }

    @Test func fencedJSONIsAccepted() throws {
        let parsed = try plan("```json\n{\"steps\":[{\"do\":\"wait\",\"seconds\":2}]}\n```")
        #expect(parsed.steps == [.wait(seconds: 2)])
    }

    @Test func enterFlagIsRead() throws {
        let parsed = try plan(#"{"steps":[{"do":"type","id":3,"text":"hi","enter":true}]}"#)
        #expect(parsed.steps == [.type(elementID: 3, text: "hi", pressesReturn: true)])
    }

    @Test func webURLRules() {
        #expect(ActionDSL.webURL(from: "https://a.com/x?y=1")?.absoluteString == "https://a.com/x?y=1")
        #expect(ActionDSL.webURL(from: "news.ycombinator.com")?.absoluteString == "https://news.ycombinator.com")
        #expect(ActionDSL.webURL(from: "ftp://a.com") == nil)
        #expect(ActionDSL.webURL(from: "x-apple.systempreferences:com.apple.preference.security") == nil)
        #expect(ActionDSL.webURL(from: "hello world") == nil)
        #expect(ActionDSL.webURL(from: "notaurl") == nil)
    }

    @Test func searchURLsAreEncoded() {
        #expect(ActionSearchEngine.google.resultsURL(for: "c++ & rust")?.absoluteString == "https://www.google.com/search?q=c%2B%2B%20%26%20rust")
        #expect(ActionSearchEngine.youtube.resultsURL(for: "lofi")?.absoluteString == "https://www.youtube.com/results?search_query=lofi")
    }

    @Test func keyCombos() {
        #expect(ActionKeyCombo.parse("Cmd-T")?.displayText == "cmd+t")
        #expect(ActionKeyCombo.parse("shift + tab")?.displayText == "shift+tab")
        #expect(ActionKeyCombo.parse("⌘L")?.displayText == "cmd+l")
        #expect(ActionKeyCombo.parse("command+shift+q")?.displayText == "shift+cmd+q")
        #expect(ActionKeyCombo.parse("return")?.isReturnKey == true)
        #expect(ActionKeyCombo.parse("enter")?.isReturnKey == true)
        #expect(ActionKeyCombo.parse("cmd+-")?.key == "-")
        #expect(ActionKeyCombo.parse("cmd") == nil)
        #expect(ActionKeyCombo.parse("a+b") == nil)
        #expect(ActionKeyCombo.parse("hyper+x") == nil)
    }

    @Test func screenChangeAndIDs() {
        #expect(ActionStep.click(elementID: 4).changesScreen)
        #expect(!ActionStep.highlight(targets: [.element(2)], notes: []).changesScreen)
        #expect(ActionStep.type(elementID: 2, text: "a", pressesReturn: false).referencedElementIDs == [2])
        #expect(!ActionStep.type(elementID: 2, text: "a", pressesReturn: false).changesScreen)
        #expect(ActionStep.type(elementID: 2, text: "a", pressesReturn: true).changesScreen)
        #expect(ActionStep.highlight(targets: [.element(2), .text("x")], notes: []).referencedElementIDs == [2])
    }

    @Test func notesAreSanitizedForMarkTags() {
        #expect(ActionDSL.cleanNote("a]b|c[d") == "a)b/c(d")
    }
}

// MARK: - Tier classification

struct ActionTierTests {
    static let plainContext = ActionTurnContext(ownerTranscript: "open chrome and google the best ramen")

    func tier(_ step: ActionStep, _ target: ActionTargetFacts?, said transcript: String = "open chrome and google the best ramen",
              leavesSafariAlone: Bool = false) -> ActionTier {
        ActionTierClassifier.classify(step, target: target, context: ActionTurnContext(ownerTranscript: transcript, leavesSafariAlone: leavesSafariAlone)).tier
    }

    static let chrome = ActionTargetFacts(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "Google")
    static func chromeElement(_ role: GroundingRole, _ label: String, axRole: String? = nil, subrole: String? = nil, placeholder: String? = nil) -> ActionTargetFacts {
        ActionTargetFacts(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "Shop", role: axRole, subrole: subrole,
                          groundingRole: role, label: label, placeholder: placeholder)
    }

    @Test func freeSteps() {
        #expect(tier(.openApp(name: "Google Chrome", bundleIdentifier: nil), Self.chrome) == .free)
        #expect(tier(.openURL(URL(string: "https://a.com")!), Self.chrome) == .free)
        #expect(tier(.search(query: "x", engine: .google), Self.chrome) == .free)
        #expect(tier(.wait(seconds: 1), nil) == .free)
        #expect(tier(.scroll(elementID: nil, direction: .down, amount: 3), Self.chrome) == .free)
        #expect(tier(.selectCopy(elementID: 3, text: nil), Self.chromeElement(.text, "Opening hours")) == .free)
        #expect(tier(.highlight(targets: [.element(3)], notes: []), Self.chromeElement(.text, "Fact")) == .free)
        #expect(tier(.summarize(text: nil, title: nil), Self.chrome) == .free)
        #expect(tier(.switchWindow(app: "Notes", title: nil), ActionTargetFacts(bundleIdentifier: "com.apple.Notes", applicationName: "Notes")) == .free)
        #expect(tier(.codeTask(project: "clicky", instructions: "x"), nil) == .free)
    }

    @Test func linksTabsAndMenusAreFree() {
        #expect(tier(.click(elementID: 1), Self.chromeElement(.link, "Best ramen in town - Eater")) == .free)
        #expect(tier(.click(elementID: 1), Self.chromeElement(.tab, "Images")) == .free)
        #expect(tier(.click(elementID: 1), Self.chromeElement(.menuItem, "New Tab")) == .free)
        #expect(tier(.click(elementID: 1), ActionTargetFacts(applicationName: "Dock", label: "Notes", isOwnApplication: false)) == .countdown)
        #expect(tier(.click(elementID: 1), ActionTargetFacts(bundleIdentifier: "com.apple.dock", groundingRole: .dock, label: "Notes")) == .free)
        #expect(tier(.click(elementID: 1), ActionTargetFacts(bundleIdentifier: "com.apple.TextEdit", role: "AXLink", label: "docs")) == .free)
    }

    @Test func countdownSteps() {
        #expect(tier(.type(elementID: 2, text: "best ramen", pressesReturn: false), Self.chromeElement(.textField, "Search")) == .countdown)
        #expect(tier(.click(elementID: 2), Self.chromeElement(.button, "Show more")) == .countdown)
        #expect(tier(.click(elementID: 2), Self.chromeElement(.checkBox, "Remember me")) == .countdown)
        #expect(tier(.click(elementID: 2), Self.chromeElement(.text, "Some paragraph")) == .countdown)
        #expect(tier(.key(ActionKeyCombo.parse("cmd+b")!), Self.chrome) == .countdown)
        #expect(tier(.key(ActionKeyCombo.parse("delete")!), Self.chrome) == .countdown)
    }

    @Test func freeKeys() {
        for combo in ["cmd+t", "cmd+l", "tab", "shift+tab", "pagedown", "escape", "cmd+c", "down"] {
            #expect(tier(.key(ActionKeyCombo.parse(combo)!), Self.chrome) == .free, "\(combo)")
        }
    }

    @Test func sendPostBuyDeleteButtonsNeedConfirm() {
        let labels = ["Send", "Send now", "Post", "Submit", "Publish", "Buy now", "Place order", "Pay $12.00", "Checkout", "Delete", "Remove",
                      "Move to Trash", "Save changes", "Save", "Confirm", "OK", "Don\u{2019}t Save", "Discard", "Subscribe", "Sign out", "Apply"]
        for label in labels {
            let decision = ActionTierClassifier.classify(.click(elementID: 1), target: Self.chromeElement(.button, label), context: Self.plainContext)
            #expect(decision.tier == .confirm, "\(label): \(decision.reason)")
        }
        // Even a link named Delete.
        #expect(tier(.click(elementID: 1), Self.chromeElement(.link, "Delete account")) == .confirm)
    }

    @Test func wordsInsideOtherWordsDontCount() {
        #expect(tier(.click(elementID: 1), Self.chromeElement(.button, "Saved items")) == .countdown)
        #expect(tier(.click(elementID: 1), Self.chromeElement(.link, "Posts")) == .free)
        #expect(tier(.click(elementID: 1), Self.chromeElement(.button, "Facebook")) == .countdown)
        #expect(tier(.click(elementID: 1), Self.chromeElement(.link, "Sender profile")) == .free)
    }

    @Test func mailSendButton() {
        let mail = ActionTargetFacts(bundleIdentifier: "com.apple.mail", applicationName: "Mail", windowTitle: "New Message", role: "AXButton",
                                     groundingRole: .button, label: "Send")
        let decision = ActionTierClassifier.classify(.click(elementID: 9), target: mail, context: Self.plainContext)
        #expect(decision.tier == .confirm)
        #expect(decision.reason.contains("sends"))
    }

    @Test func passwordFieldsAreRefused() {
        let secure = Self.chromeElement(.textField, "Password", axRole: "AXTextField", subrole: "AXSecureTextField")
        #expect(tier(.type(elementID: 1, text: "hunter2", pressesReturn: false), secure) == .refused)
        #expect(tier(.click(elementID: 1), secure) == .refused)
        let labelled = Self.chromeElement(.textField, "Enter your password")
        #expect(tier(.type(elementID: 1, text: "x", pressesReturn: false), labelled) == .refused)
        var secureInput = Self.chromeElement(.textField, "Name")
        secureInput.isSecureEventInputOn = true
        #expect(tier(.type(elementID: 1, text: "x", pressesReturn: false), secureInput) == .refused)
        // Plain fields aren't caught by "pin" inside other words.
        #expect(tier(.type(elementID: 1, text: "x", pressesReturn: false), Self.chromeElement(.textField, "Shipping address")) == .countdown)
    }

    @Test func paymentFieldsAreRefused() {
        for label in ["Card number", "CVV", "Security code", "Expiry date", "MM/YY", "IBAN"] {
            #expect(tier(.type(elementID: 1, text: "4242", pressesReturn: false), Self.chromeElement(.textField, label)) == .refused, "\(label)")
        }
        #expect(tier(.type(elementID: 1, text: "1", pressesReturn: false), Self.chromeElement(.textField, "", placeholder: "1234 1234 1234 1234 card number")) == .refused)
        var autocomplete = Self.chromeElement(.textField, "")
        autocomplete.identifier = "cc-csc"
        #expect(tier(.click(elementID: 1), autocomplete) == .refused)
    }

    @Test func securityPromptsAreRefused() {
        for bundle in ["com.apple.SecurityAgent", "com.apple.keychainaccess", "com.1password.1password", "com.apple.coreautha"] {
            #expect(tier(.click(elementID: 1), ActionTargetFacts(bundleIdentifier: bundle, groundingRole: .button, label: "Allow")) == .refused, "\(bundle)")
        }
        #expect(tier(.click(elementID: 1), ActionTargetFacts(applicationName: "coreautha", groundingRole: .button, label: "OK")) == .refused)
        #expect(tier(.openApp(name: "Keychain Access", bundleIdentifier: nil), ActionTargetFacts(bundleIdentifier: "com.apple.keychainaccess")) == .refused)
    }

    @Test func terminalsRefuseTypingAndKeys() {
        let terminal = ActionTargetFacts(bundleIdentifier: "com.apple.Terminal", applicationName: "Terminal", role: "AXTextArea")
        let iterm = ActionTargetFacts(bundleIdentifier: "com.googlecode.iterm2", applicationName: "iTerm2")
        #expect(tier(.type(elementID: nil, text: "rm -rf ~", pressesReturn: false), terminal) == .refused)
        #expect(tier(.key(ActionKeyCombo.parse("ctrl+c")!), iterm) == .refused)
        #expect(tier(.type(elementID: nil, text: "ls", pressesReturn: false), ActionTargetFacts(applicationName: "Ghostty")) == .refused)
        // Opening one or scrolling is fine.
        #expect(tier(.openApp(name: "Terminal", bundleIdentifier: nil), terminal) == .free)
        #expect(tier(.scroll(elementID: nil, direction: .down, amount: 2), terminal) == .free)
    }

    @Test func systemSettingsChangesNeedConfirmAndPrivacyIsRefused() {
        let settings = ActionTargetFacts(bundleIdentifier: "com.apple.systempreferences", applicationName: "System Settings", windowTitle: "Appearance",
                                         groundingRole: .radio, label: "Dark")
        #expect(tier(.click(elementID: 1), settings) == .confirm)
        #expect(tier(.openApp(name: "System Settings", bundleIdentifier: nil), ActionTargetFacts(bundleIdentifier: "com.apple.systempreferences")) == .free)
        #expect(tier(.scroll(elementID: 1, direction: .down, amount: 3), settings) == .free)
        var privacy = settings
        privacy.windowTitle = "Privacy & Security"
        privacy.label = "Screen Recording"
        #expect(tier(.click(elementID: 1), privacy) == .refused)
        #expect(tier(.scroll(elementID: 1, direction: .down, amount: 3), privacy) == .refused)
        var sidebar = settings
        sidebar.windowTitle = "Wi-Fi"
        sidebar.label = "Privacy & Security"
        #expect(tier(.click(elementID: 1), sidebar) == .refused)
    }

    @Test func safariAndNetflixAreProtectedUnlessNamed() {
        let safari = ActionTargetFacts(bundleIdentifier: "com.apple.Safari", applicationName: "Safari", windowTitle: "Stranger Things | Netflix",
                                       groundingRole: .button, label: "Pause")
        #expect(tier(.click(elementID: 1), safari) == .refused)
        #expect(tier(.scroll(elementID: nil, direction: .down, amount: 1), safari) == .refused)
        #expect(tier(.highlight(targets: [.element(1)], notes: []), safari) == .refused)
        #expect(tier(.summarize(text: nil, title: nil), safari) == .refused)
        #expect(tier(.key(ActionKeyCombo.parse("space")!), safari) == .refused)
        // Safari itself is a browser like any other by default...
        #expect(tier(.openApp(name: "Safari", bundleIdentifier: nil), ActionTargetFacts(bundleIdentifier: "com.apple.Safari")) == .free)
        #expect(tier(.switchWindow(app: "Safari", title: nil), ActionTargetFacts(bundleIdentifier: "com.apple.Safari", applicationName: "Safari")) == .free)
        // ...and hands-off unless named only with "leave Safari alone" on.
        #expect(tier(.openApp(name: "Safari", bundleIdentifier: nil), ActionTargetFacts(bundleIdentifier: "com.apple.Safari"), leavesSafariAlone: true) == .refused)
        #expect(tier(.switchWindow(app: "Safari", title: nil), ActionTargetFacts(bundleIdentifier: "com.apple.Safari", applicationName: "Safari"),
                     leavesSafariAlone: true) == .refused)
        // A Netflix window in another browser is protected too.
        let chromeNetflix = ActionTargetFacts(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "Netflix")
        #expect(tier(.scroll(elementID: nil, direction: .down, amount: 1), chromeNetflix) == .refused)
        // Named this turn: allowed (normal tiers).
        #expect(tier(.click(elementID: 1), safari, said: "pause netflix") == .countdown)
        #expect(tier(.openApp(name: "Safari", bundleIdentifier: nil), ActionTargetFacts(bundleIdentifier: "com.apple.Safari"), said: "open safari",
                     leavesSafariAlone: true) == .free)
        // "safaris" isn't "safari".
        #expect(tier(.click(elementID: 1), safari, said: "book african safaris") == .refused)
    }

    /// Live 2026-11-13: "can you scroll down for me?" on a Wikipedia article in Safari was refused, and so was every click there.
    @Test func safariArticlesAreScrolledAndClickedByDefault() {
        let article = ActionTargetFacts(bundleIdentifier: "com.apple.Safari", applicationName: "Safari", windowTitle: "James Webb Space Telescope - Wikipedia",
                                        groundingRole: .link, label: "Hubble Space Telescope", url: "https://en.wikipedia.org/wiki/James_Webb_Space_Telescope")
        #expect(tier(.scroll(elementID: nil, direction: .down, amount: 3), article, said: "can you scroll down for me?") == .free)
        #expect(tier(.click(elementID: 1), article, said: "open the hubble link") != .refused)
        #expect(tier(.scroll(elementID: nil, direction: .down, amount: 3), article, said: "can you scroll down for me?", leavesSafariAlone: true) == .refused)
        let refusal = ActionTierClassifier.classify(.scroll(elementID: nil, direction: .down, amount: 3), target: article,
                                                    context: ActionTurnContext(ownerTranscript: "scroll down", leavesSafariAlone: true))
        #expect(refusal.reason.contains("Safari"))
        #expect(!refusal.reason.contains("Netflix"))
    }

    @Test func clickysOwnWindowsAreRefused() {
        #expect(tier(.click(elementID: 1), ActionTargetFacts(bundleIdentifier: "com.personal.clicky", groundingRole: .button, label: "Type", isOwnApplication: true)) == .refused)
        #expect(tier(.highlight(targets: [.element(1)], notes: []), ActionTargetFacts(isOwnApplication: true)) == .refused)
    }

    /// Live 2026-11-13: "press the device settings for me on this app" with Theo's own window in front. Clicky saw only the
    /// desktop and asked which app. Theo's main windows are now seen; pressing there waits for the owner's yes.
    @Test func theosMainWindowWaitsForAYesAndItsPanelsStayRefused() {
        let settingsButton = ActionTargetFacts(bundleIdentifier: "com.personal.clicky", applicationName: "Theo", windowTitle: "Theo", groundingRole: .text,
                                               label: "Devices", isOwnApplication: true, isOwnMainWindow: true)
        let click = ActionTierClassifier.classify(.click(elementID: 1), target: settingsButton, context: ActionTurnContext(ownerTranscript: "press the device settings"))
        #expect(click.tier == .confirm)
        #expect(click.confirmQuestion?.contains("Theo") == true)
        #expect(tier(.key(ActionKeyCombo.parse("cmd+f")!), settingsButton) == .confirm)
        #expect(tier(.type(elementID: 1, text: "hi", pressesReturn: false), settingsButton) == .confirm)
        #expect(tier(.scroll(elementID: nil, direction: .down, amount: 3), settingsButton) == .free)
        #expect(tier(.highlight(targets: [.element(1)], notes: []), settingsButton) == .free)
        // The confirm card, notch or spark are Theo's too, but never main windows: still refused, so Clicky can't approve itself.
        var confirmCard = settingsButton
        confirmCard.isOwnMainWindow = false
        confirmCard.windowTitle = nil
        confirmCard.label = "Yes"
        #expect(tier(.click(elementID: 1), confirmCard) == .refused)
        // Password fields in Theo's window are refused like anywhere else.
        var keyField = settingsButton
        keyField.role = "AXSecureTextField"
        #expect(tier(.type(elementID: 1, text: "x", pressesReturn: false), keyField) == .refused)
    }

    @Test func returnIsAutomaticWhenAskedOrImpliedAndNeverAQuestion() {
        let field = Self.chromeElement(.textField, "Message")
        #expect(tier(.type(elementID: 1, text: "hi", pressesReturn: true), field, said: "type hi in the chat and press enter") == .free)
        #expect(tier(.type(elementID: 1, text: "hi", pressesReturn: true), field, said: "tell him hi and send it") == .free)
        #expect(tier(.key(ActionKeyCombo.parse("return")!), Self.chrome, said: "search for ramen") == .free)
        #expect(tier(.key(ActionKeyCombo.parse("cmd+return")!), Self.chrome, said: "search for ramen") == .free)
        #expect(tier(.key(ActionKeyCombo.parse("return")!), Self.chrome, said: "search for ramen then hit enter") == .free)
    }

    @Test func returnRulePhrases() {
        #expect(ActionReturnRule.ownerAskedToPressReturn("type it and press enter"))
        #expect(ActionReturnRule.ownerAskedToPressReturn("reply ok and send it"))
        #expect(ActionReturnRule.ownerAskedToPressReturn("Hit Return when you're done"))
        #expect(!ActionReturnRule.ownerAskedToPressReturn("type hello"))
        #expect(!ActionReturnRule.ownerAskedToPressReturn("what does the send button do"))
        #expect(!ActionReturnRule.ownerAskedToPressReturn("the enterprise plan"))
    }

    @Test func destructiveKeyCombos() {
        for combo in ["cmd+q", "cmd+w", "cmd+delete", "cmd+s", "cmd+shift+w"] {
            #expect(tier(.key(ActionKeyCombo.parse(combo)!), Self.chrome) == .confirm, "\(combo)")
        }
        for combo in ["cmd+opt+esc", "cmd+shift+q", "ctrl+cmd+q", "cmd+shift+delete", "shift+cmd+opt+q"] {
            #expect(tier(.key(ActionKeyCombo.parse(combo)!), Self.chrome) == .refused, "\(combo)")
        }
    }

    @Test func missingTargetIsRefusedForTargetedSteps() {
        #expect(tier(.click(elementID: 99), nil) == .refused)
        #expect(tier(.type(elementID: nil, text: "x", pressesReturn: false), nil) == .refused)
        #expect(tier(.openURL(URL(string: "https://a.com")!), nil) == .free)
    }

    @Test func browserChoiceUsesTheDefaultSafariUnlessItIsLeftAlone() {
        let installed: Set<String> = ["com.apple.Safari", "com.google.Chrome"]
        #expect(ActionBrowserChoice.choose(defaultBrowserBundleIdentifier: "com.apple.Safari", installedBundleIdentifiers: installed, ownerTranscript: "google cats")
                == .use(bundleIdentifier: "com.apple.Safari"))
        #expect(ActionBrowserChoice.choose(defaultBrowserBundleIdentifier: "com.apple.Safari", installedBundleIdentifiers: ["com.apple.Safari"], ownerTranscript: "google x")
                == .use(bundleIdentifier: "com.apple.Safari"))
    }

    @Test func promptFollowsTheSafariChoiceAndAsksForActionNotInstructions() {
        #expect(ActionsPromptSection.text(leavesSafariAlone: false).contains("leaves netflix alone unless the user names it"))
        #expect(!ActionsPromptSection.text(leavesSafariAlone: false).contains("safari"))
        #expect(ActionsPromptSection.text(leavesSafariAlone: true).contains("leaves safari and netflix alone"))
        #expect(ActionsPromptSection.text(leavesSafariAlone: false).contains("don't tell them to click it themselves"))
        #expect(ActionsPromptSection.text(leavesSafariAlone: false).contains("{\"do\":\"key\",\"combo\":\"return\"}"))
    }

    @Test func browserChoiceAvoidsSafariWhenItIsLeftAlone() {
        let installed: Set<String> = ["com.apple.Safari", "com.google.Chrome"]
        #expect(ActionBrowserChoice.choose(defaultBrowserBundleIdentifier: "com.apple.Safari", installedBundleIdentifiers: installed, ownerTranscript: "google cats",
                                           leavesSafariAlone: true)
                == .use(bundleIdentifier: "com.google.Chrome"))
        #expect(ActionBrowserChoice.choose(defaultBrowserBundleIdentifier: "com.apple.Safari", installedBundleIdentifiers: installed, ownerTranscript: "google cats in safari",
                                           leavesSafariAlone: true)
                == .use(bundleIdentifier: "com.apple.Safari"))
        #expect(ActionBrowserChoice.choose(defaultBrowserBundleIdentifier: "org.mozilla.firefox", installedBundleIdentifiers: installed.union(["org.mozilla.firefox"]),
                                           ownerTranscript: "open it in chrome") == .use(bundleIdentifier: "com.google.Chrome"))
        #expect(ActionBrowserChoice.choose(defaultBrowserBundleIdentifier: "org.mozilla.firefox", installedBundleIdentifiers: installed.union(["org.mozilla.firefox"]),
                                           ownerTranscript: "search it") == .use(bundleIdentifier: "org.mozilla.firefox"))
        guard case .refused = ActionBrowserChoice.choose(defaultBrowserBundleIdentifier: "com.apple.Safari", installedBundleIdentifiers: ["com.apple.Safari"], ownerTranscript: "google x",
                                                         leavesSafariAlone: true)
        else { Issue.record("expected refused"); return }
    }
}

// MARK: - Loop

struct ActionTaskLoopTests {
    @Test func stepLimitIsTwelvePerTask() {
        var loop = ActionTaskLoop(goal: "g", ownerTranscript: "do it")
        for _ in 0..<12 {
            #expect(loop.gate(.wait(seconds: 1), screenChangedEarlierInBatch: false) == .run)
            loop.record(.wait(seconds: 1), tier: .free, tierReason: nil, outcome: .done(detail: nil))
        }
        #expect(loop.isStepBudgetExhausted)
        #expect(loop.gate(.wait(seconds: 1), screenChangedEarlierInBatch: false) == .skipStepLimit)
        #expect(!loop.needsObserveTurn(planWasDone: false, wasCancelled: false))
    }

    @Test func refusedAndSkippedStepsDontUseTheBudget() {
        var loop = ActionTaskLoop(goal: "g", ownerTranscript: "x")
        loop.record(.click(elementID: 1), tier: .refused, tierReason: "pw", outcome: .refused(reason: "password field"))
        loop.record(.click(elementID: 2), tier: nil, tierReason: nil, outcome: .skipped(reason: "stale"))
        loop.record(.click(elementID: 3), tier: .countdown, tierReason: nil, outcome: .failed(reason: "covered"))
        #expect(loop.executedStepCount == 1)
        #expect(loop.remainingStepBudget == 11)
        #expect(loop.records.map(\.number) == [1, 2, 3])
    }

    @Test func staleIDsAreSkippedAfterAScreenChange() {
        let loop = ActionTaskLoop(goal: "g", ownerTranscript: "x")
        #expect(loop.gate(.click(elementID: 4), screenChangedEarlierInBatch: true) == .skipStaleIDs)
        #expect(loop.gate(.type(elementID: nil, text: "a", pressesReturn: false), screenChangedEarlierInBatch: true) == .run)
        #expect(loop.gate(.wait(seconds: 1), screenChangedEarlierInBatch: true) == .run)
        #expect(loop.gate(.click(elementID: 4), screenChangedEarlierInBatch: false) == .run)
    }

    @Test func observeTurns() {
        var loop = ActionTaskLoop(goal: "g", ownerTranscript: "x")
        #expect(loop.needsObserveTurn(planWasDone: false, wasCancelled: false))
        #expect(!loop.needsObserveTurn(planWasDone: true, wasCancelled: false))
        #expect(!loop.needsObserveTurn(planWasDone: false, wasCancelled: true))
        loop.pendingPageText = "article"
        // The page was read: Claude still has to summarize, even after "done".
        #expect(loop.needsObserveTurn(planWasDone: true, wasCancelled: false))
        for _ in 0..<ActionTaskLoop.maximumObserveTurns { loop.beginObserveTurn() }
        #expect(!loop.needsObserveTurn(planWasDone: false, wasCancelled: false))
    }

    @Test func continuationMessageCarriesResultsAndPageText() {
        var loop = ActionTaskLoop(goal: "find ramen", ownerTranscript: "x")
        loop.record(.openApp(name: "Google Chrome", bundleIdentifier: nil), tier: .free, tierReason: nil, outcome: .done(detail: nil))
        loop.record(.click(elementID: 5), tier: .refused, tierReason: nil, outcome: .refused(reason: "password field"))
        loop.pendingPageText = "Ramen is great."
        let message = loop.continuationMessage()
        #expect(message.contains("goal: find ramen"))
        #expect(message.contains("1. open_app — open Google Chrome — done"))
        #expect(message.contains("2. click — click #5 — refused: password field — don't retry it"))
        #expect(message.contains("steps used: 1 of 12"))
        #expect(message.contains("PAGE TEXT"))
        #expect(message.contains("Ramen is great."))
        #expect(message.contains("ids are new"))
    }

    @Test func confirmReplies() {
        for yes in ["yes", "Yeah.", "yes please", "go ahead", "Clicky, do it", "okay", "send it", "yep send it".replacingOccurrences(of: "yep ", with: "yes ")] {
            #expect(ActionConfirmReply.parse(yes) == .yes, "\(yes)")
        }
        for no in ["no", "Nope", "cancel", "don't", "never mind", "stop"] {
            #expect(ActionConfirmReply.parse(no) == .no, "\(no)")
        }
        for other in ["what's the weather", "yes but change the subject first and then also add a line", "open notes"] {
            #expect(ActionConfirmReply.parse(other) == .notAReply, "\(other)")
        }
    }

    @Test func stopCommands() {
        #expect(ActionStopCommand.isStop("stop"))
        #expect(ActionStopCommand.isStop("Clicky, stop!"))
        #expect(ActionStopCommand.isStop("cancel that please"))
        #expect(!ActionStopCommand.isStop("stop the music from playing in spotify"))
        #expect(!ActionStopCommand.isStop("open chrome"))
    }

    @Test func confirmClickGate() {
        #expect(ActionConfirmClickGate.accepts(eventSourceUserData: 0, secondsSinceShown: 1))
        #expect(!ActionConfirmClickGate.accepts(eventSourceUserData: SyntheticEventTag.value, secondsSinceShown: 1))
        #expect(!ActionConfirmClickGate.accepts(eventSourceUserData: 0, secondsSinceShown: 0.2))
    }

    @Test func recordLines() {
        let record = ActionStepRecord(number: 2, step: .type(elementID: 4, text: "best ramen near me tonight please", pressesReturn: false),
                                      tier: .countdown, tierReason: nil, outcome: .done(detail: nil))
        #expect(record.displayLine.hasPrefix("✓ type \u{201C}best ramen near me tonight"))
        #expect(record.displayLine.hasSuffix("…\u{201D} into #4"))
    }
}

// MARK: - Cancel on physical input

struct ActionCancelLogicTests {
    @Test func disarmedIgnoresEverything() {
        var logic = ActionCancelLogic()
        #expect(logic.handle(PhysicalInputEvent(kind: .mouseDown, timestamp: 1)) == .ignore)
        #expect(logic.handle(PhysicalInputEvent(kind: .keyDown(keyCode: 0), timestamp: 1)) == .ignore)
    }

    @Test func anyRealInputCancelsWhileArmed() {
        let kinds: [PhysicalInputEvent.Kind] = [.mouseDown, .keyDown(keyCode: 53), .scrollWheel, .flagsChanged, .mouseDragged, .mouseMoved(deltaX: 10, deltaY: 0)]
        for kind in kinds {
            var logic = ActionCancelLogic()
            logic.arm()
            guard case .cancel = logic.handle(PhysicalInputEvent(kind: kind, timestamp: 1)) else { Issue.record("\(kind) didn't cancel"); continue }
            // Once only.
            #expect(logic.handle(PhysicalInputEvent(kind: kind, timestamp: 2)) == .ignore)
        }
    }

    @Test func escapeHasItsOwnReason() {
        var logic = ActionCancelLogic()
        logic.arm()
        #expect(logic.handle(PhysicalInputEvent(kind: .keyDown(keyCode: 53), timestamp: 1)) == .cancel(reason: "you pressed Escape"))
    }

    @Test func clickysOwnTaggedEventsNeverCancel() {
        var logic = ActionCancelLogic()
        logic.arm()
        for kind in [PhysicalInputEvent.Kind.mouseDown, .keyDown(keyCode: 36), .scrollWheel, .mouseMoved(deltaX: 400, deltaY: 300)] {
            #expect(logic.handle(PhysicalInputEvent(kind: kind, eventSourceUserData: SyntheticEventTag.value, timestamp: 1)) == .ignore)
        }
        // Another tag value is not ours.
        guard case .cancel = logic.handle(PhysicalInputEvent(kind: .mouseDown, eventSourceUserData: 42, timestamp: 2)) else { Issue.record("expected cancel"); return }
    }

    @Test func jitterIsTolerated() {
        var logic = ActionCancelLogic()
        logic.arm()
        #expect(logic.handle(PhysicalInputEvent(kind: .mouseMoved(deltaX: 1, deltaY: 1), timestamp: 1)) == .ignore)
        #expect(logic.handle(PhysicalInputEvent(kind: .mouseMoved(deltaX: 1, deltaY: 0), timestamp: 1.1)) == .ignore)
        guard case .cancel = logic.handle(PhysicalInputEvent(kind: .mouseMoved(deltaX: 2, deltaY: 0), timestamp: 1.2)) else { Issue.record("expected cancel"); return }
    }

    @Test func cursorWarpRightAfterOurClickIsExcused() {
        var logic = ActionCancelLogic()
        logic.arm()
        logic.noteSyntheticPointerEvent(at: 10)
        #expect(logic.handle(PhysicalInputEvent(kind: .mouseMoved(deltaX: 300, deltaY: 200), timestamp: 10.1)) == .ignore)
        // But not a click, and not a move later on.
        guard case .cancel = logic.handle(PhysicalInputEvent(kind: .mouseMoved(deltaX: 30, deltaY: 0), timestamp: 10.5)) else { Issue.record("expected cancel"); return }
        var clickLogic = ActionCancelLogic()
        clickLogic.arm()
        clickLogic.noteSyntheticPointerEvent(at: 10)
        guard case .cancel = clickLogic.handle(PhysicalInputEvent(kind: .mouseDown, timestamp: 10.05)) else { Issue.record("expected cancel"); return }
    }

    @Test func rearmingResets() {
        var logic = ActionCancelLogic()
        logic.arm()
        _ = logic.handle(PhysicalInputEvent(kind: .mouseDown, timestamp: 1))
        logic.disarm()
        #expect(logic.handle(PhysicalInputEvent(kind: .mouseDown, timestamp: 2)) == .ignore)
        logic.arm()
        #expect(logic.accumulatedMouseDistance == 0)
        guard case .cancel = logic.handle(PhysicalInputEvent(kind: .mouseDown, timestamp: 3)) else { Issue.record("expected cancel"); return }
    }
}

// MARK: - Summaries

struct ActionPageTextTests {
    @Test func accessibilityFragmentsAreCleaned() {
        let text = ActionPageText.fromAccessibilityFragments(["Home", "  The   ramen  boom  ", "Home", "x", "The ramen boom", "It started in 2010 when a small shop opened downtown.",
                                                              "and kept growing", "Sign in"])
        #expect(!text.contains("  "))
        #expect(text.components(separatedBy: "Home").count == 2)
        #expect(!text.contains("x\n"))
        #expect(text.contains("It started in 2010"))
    }

    @Test func longTextIsTruncatedAtAWord() {
        let text = ActionPageText.truncated(String(repeating: "word ", count: 5000), maximumCharacters: 100)
        #expect(text.count <= 101)
        #expect(text.hasSuffix("word…"))
    }

    @Test func ocrLinesAreReadInOrder() {
        let lines: [(text: String, frameCG: CGRect)] = [
            ("second line", CGRect(x: 10, y: 40, width: 100, height: 14)),
            ("Title", CGRect(x: 10, y: 10, width: 60, height: 20)),
            ("right", CGRect(x: 200, y: 41, width: 40, height: 14)),
            ("new paragraph", CGRect(x: 10, y: 120, width: 100, height: 14))
        ]
        #expect(ActionPageText.fromOCRLines(lines) == "Title\nsecond line right\n\nnew paragraph")
    }

    @Test func bestSourcePrefersAccessibility() {
        let longAX = String(repeating: "a", count: 300)
        #expect(ActionPageText.best(accessibilityText: longAX, ocrText: "ocr").source == .accessibility)
        #expect(ActionPageText.best(accessibilityText: "short", ocrText: "much longer ocr text").source == .ocr)
        #expect(ActionPageText.best(accessibilityText: "", ocrText: "").source == .none)
    }

    @Test func summaryBullets() {
        #expect(ActionSummaryBoard.bullets(from: "- one\n• two\n3. three\n\n* four") == ["one", "two", "three", "four"])
        #expect(ActionSummaryBoard.bullets(from: "Ramen is old. It got popular. Now it's everywhere.") == ["Ramen is old.", "It got popular.", "Now it's everywhere."])
        let many = (1...20).map { "- point \($0)" }.joined(separator: "\n")
        #expect(ActionSummaryBoard.bullets(from: many).count == WBList.maximumItemCount)
    }

    @Test func summaryBoard() {
        let board = ActionSummaryBoard.board(title: "The ramen boom", summaryText: "- a\n- b")
        #expect(board.title == "The ramen boom")
        #expect(board.elements.count == 1)
        if case .list(let list) = board.elements[0].payload { #expect(list.items == ["a", "b"]) } else { Issue.record("not a list") }
        #expect(board.steps.first?.shownIdentifiers == ["summary"])
        #expect(ActionSummaryBoard.board(title: nil, summaryText: "x").title == "Summary")
    }
}

// MARK: - Support

struct ActionSupportTests {
    static let apps = [
        ActionApplicationCandidate(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", path: "/Applications/Google Chrome.app"),
        ActionApplicationCandidate(name: "Notes", bundleIdentifier: "com.apple.Notes", path: nil),
        ActionApplicationCandidate(name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode", path: nil),
        ActionApplicationCandidate(name: "System Settings", bundleIdentifier: "com.apple.systempreferences", path: nil),
        ActionApplicationCandidate(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", path: nil)
    ]

    @Test func appNames() {
        #expect(ActionAppNameMatcher.bestMatch(name: "chrome", bundleIdentifier: nil, candidates: Self.apps)?.bundleIdentifier == "com.google.Chrome")
        #expect(ActionAppNameMatcher.bestMatch(name: "VS Code", bundleIdentifier: nil, candidates: Self.apps)?.bundleIdentifier == "com.microsoft.VSCode")
        #expect(ActionAppNameMatcher.bestMatch(name: "settings", bundleIdentifier: nil, candidates: Self.apps)?.bundleIdentifier == "com.apple.systempreferences")
        #expect(ActionAppNameMatcher.bestMatch(name: "Notes.app", bundleIdentifier: nil, candidates: Self.apps)?.bundleIdentifier == "com.apple.Notes")
        #expect(ActionAppNameMatcher.bestMatch(name: nil, bundleIdentifier: "com.apple.textedit", candidates: Self.apps)?.name == "TextEdit")
        #expect(ActionAppNameMatcher.bestMatch(name: "Photoshop", bundleIdentifier: nil, candidates: Self.apps) == nil)
    }

    @Test func highlightTagsParse() throws {
        let tags = ActionHighlightTags.tags(targets: [.element(12), .text("Opened in \"2010\""), .element(3)], notes: ["key fact", "first shop|year"])
        #expect(tags.count == 3)
        let first = try #require(MarkTagParser.parse(tags[0]))
        #expect(first.target == .element(id: 12, hint: nil))
        #expect(first.style == .box)
        #expect(first.note == "key fact")
        let second = try #require(MarkTagParser.parse(tags[1]))
        #expect(second.target == .text("Opened in \"2010\"", occurrence: nil, scopeID: nil))
        #expect(second.style == .underline)
        let third = try #require(MarkTagParser.parse(tags[2]))
        #expect(third.note == nil || third.note == "")
    }

    @Test func debugAXAllowlist() {
        #expect(ActionsDebugAXCommand.bundleRefusal("com.apple.TextEdit", ownBundleIdentifier: "com.personal.clicky") == nil)
        #expect(ActionsDebugAXCommand.bundleRefusal("com.apple.Notes", ownBundleIdentifier: "com.personal.clicky") == nil)
        #expect(ActionsDebugAXCommand.bundleRefusal("com.apple.Safari", ownBundleIdentifier: "com.personal.clicky") == "never Safari")
        #expect(ActionsDebugAXCommand.bundleRefusal("com.personal.clicky", ownBundleIdentifier: "com.personal.clicky") == "never Clicky itself")
        #expect(ActionsDebugAXCommand.bundleRefusal("com.google.Chrome", ownBundleIdentifier: nil)?.hasPrefix("only") == true)
        #expect(ActionsDebugAXCommand.bundleRefusal(nil, ownBundleIdentifier: nil) == "needs \"bundle\"")
    }

    @Test func debugSetPositionValidation() {
        let ok = ActionsDebugAXCommand.parseSetPosition(["bundle": "com.apple.TextEdit", "windowIndex": 1, "x": 100, "y": 50, "w": 600, "h": 400], ownBundleIdentifier: nil)
        #expect(ok == .success(.init(bundleIdentifier: "com.apple.TextEdit", window: .index(1), x: 100, y: 50, width: 600, height: 400, isDryRun: false)))
        let byTitle = ActionsDebugAXCommand.parseSetPosition(["bundle": "com.apple.Notes", "windowTitle": "Notes", "x": 0, "y": 0], ownBundleIdentifier: nil)
        #expect((try? byTitle.get())?.window == .title("Notes"))
        let dryRun = ActionsDebugAXCommand.parseSetPosition(["bundle": "com.apple.Notes", "dryRun": true], ownBundleIdentifier: nil)
        #expect((try? dryRun.get())?.isDryRun == true)
        #expect(ActionsDebugAXCommand.parseSetPosition(["bundle": "com.apple.Notes"], ownBundleIdentifier: nil) == .failure(.invalid("needs \"x\" and \"y\" (or dryRun)")))
        #expect(ActionsDebugAXCommand.parseSetPosition(["bundle": "com.apple.Notes", "x": 0, "y": 0, "w": 300], ownBundleIdentifier: nil) == .failure(.invalid("give both \"w\" and \"h\", or neither")))
        #expect(ActionsDebugAXCommand.parseSetPosition(["bundle": "com.apple.Notes", "x": 0, "y": 0, "w": 10, "h": 10], ownBundleIdentifier: nil) == .failure(.invalid("w/h must be 50…10000")))
        #expect(ActionsDebugAXCommand.parseSetPosition(["bundle": "com.apple.Safari", "x": 0, "y": 0], ownBundleIdentifier: nil) == .failure(.refused("never Safari")))
        #expect(ActionsDebugAXCommand.parseSetPosition(["bundle": "com.apple.Notes", "x": 99_999, "y": 0], ownBundleIdentifier: nil) == .failure(.invalid("x/y out of range")))
    }

    @Test func debugPerformValidation() {
        #expect((try? ActionsDebugAXCommand.parsePerform(["bundle": "com.apple.TextEdit", "action": "press", "role": "AXButton", "title": "Cancel"], ownBundleIdentifier: nil).get())?.action == "press")
        #expect(ActionsDebugAXCommand.parsePerform(["bundle": "com.apple.TextEdit", "action": "press"], ownBundleIdentifier: nil) == .failure(.invalid("press needs \"role\" and \"title\"")))
        #expect(ActionsDebugAXCommand.parsePerform(["bundle": "com.apple.TextEdit", "action": "delete"], ownBundleIdentifier: nil) == .failure(.refused("delete is only for the selected note in Notes")))
        #expect((try? ActionsDebugAXCommand.parsePerform(["bundle": "com.apple.Notes", "action": "delete"], ownBundleIdentifier: nil).get())?.action == "delete")
        #expect(ActionsDebugAXCommand.parsePerform(["bundle": "com.apple.Notes", "action": "type"], ownBundleIdentifier: nil) == .failure(.invalid("action must be \"press\" or \"delete\"")))
        #expect(ActionsDebugAXCommand.parsePerform(["bundle": "com.apple.Notes", "action": "press", "role": "AXTextArea", "title": "x", "text": "hi"], ownBundleIdentifier: nil) == .failure(.refused("axPerform never types text")))
        #expect(ActionsDebugAXCommand.parsePerform(["bundle": "com.apple.Safari", "action": "press", "role": "AXButton", "title": "Play"], ownBundleIdentifier: nil) == .failure(.refused("never Safari")))
    }
}

// MARK: - Router, prompt, notch, settings

struct ActionsIntegrationTests {
    @Test func routerHandsTheActionsBlockToItsConsumer() {
        var router = ResponseRouter(blockConsumers: ["actions"])
        var outputs = router.feed("opening chrome… <actions>{\"steps\":[{\"do\":\"open_app\",")
        outputs += router.feed("\"name\":\"Google Chrome\"}]}</actions> done")
        outputs += router.finish()
        #expect(outputs.contains(.block(name: "actions", body: "{\"steps\":[{\"do\":\"open_app\",\"name\":\"Google Chrome\"}]}")))
        let narration = outputs.compactMap { output -> String? in if case .narration(let text) = output { return text } else { return nil } }.joined()
        #expect(!narration.contains("open_app"))
        #expect(narration.contains("opening chrome"))
    }

    @Test func routerWithoutConsumerSaysItCant() {
        var router = ResponseRouter(blockConsumers: [])
        let outputs = router.feed("<actions>{}</actions>") + router.finish()
        #expect(outputs.contains(.unsupportedBlock(name: "actions")))
    }

    @Test func promptSectionOnlyWithTheFeature() {
        let withActions = SystemPromptBuilder.mainSystemPrompt(features: SystemPromptFeatures.current.union(.actions), sectionTexts: [:])
        let without = SystemPromptBuilder.mainSystemPrompt(features: .current, sectionTexts: [:])
        #expect(withActions.contains("<actions>{\"goal\""))
        #expect(withActions.contains("put the return in the step list"))
        #expect(withActions.contains("never say you pressed enter or sent anything until that step's result says done"))
        #expect(!without.contains("<actions>"))
        // Typing is an action step now, so it isn't listed as missing.
        #expect(!withActions.contains("type for the user yet"))
        #expect(without.contains("type for the user yet"))
    }

    @Test func notchShowsTheActionTaskSteps() {
        var store = AgentStore()
        store.upsert(AgentRecord(id: "a1", kind: .actionTask, title: "find ramen", currentStep: "type “ramen” in 1.5 s",
                                 actionSteps: ["✓ open Google Chrome", "✓ search google for “ramen”", "✕ click #3", "✓ wait 1 s", "✓ scroll down 3"]))
        let content = NotchStatus.content(phase: .idle, store: store, captionText: nil, isCodeModeOn: false, selectedAgentID: nil, now: Date(),
                                          canCancel: { _ in true }, canOpenReview: { _ in false })
        #expect(content.statusText == "doing: find ramen")
        #expect(content.actionStepLines.count == NotchGeometry.maximumActionStepLines)
        #expect(content.actionStepLines.last == "▸ type “ramen” in 1.5 s")
        #expect(content.agentRows.first?.statusText == "type “ramen” in 1.5 s")
        let layout = NotchGeometry.layout(for: NotchScreenMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTopInset: 0,
                                                                 auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil))
        let withSteps = NotchView.pillSize(content: content, layout: layout, isExpanded: true)
        var noSteps = content
        noSteps.actionStepLines = []
        #expect(withSteps.height == NotchView.pillSize(content: noSteps, layout: layout, isExpanded: true).height
                + NotchGeometry.actionStepsHeight(lineCount: 4) + NotchGeometry.sectionSpacing)
    }

    @Test func agentRecordWithStepsRoundTrips() throws {
        let record = AgentRecord(kind: .actionTask, title: "t", actionSteps: ["✓ a"])
        let decoded = try JSONDecoder().decode(AgentRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.actionSteps == ["✓ a"])
        #expect(decoded.kind == .actionTask)
        // Old records without the field still decode.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentRecord(kind: .brain, title: "b"))) as! [String: Any]
        old.removeValue(forKey: "actionSteps")
        let oldDecoded = try JSONDecoder().decode(AgentRecord.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(oldDecoded.actionSteps == nil)
    }

    @Test func settingsDefaults() {
        let enabled = ClickySettingsCatalog.entries.first { $0.key == ClickySettings.Keys.actionsEnabled }
        #expect(enabled?.kind == .toggle(defaultValue: true))
        let countdown = ClickySettingsCatalog.entries.first { $0.key == ClickySettings.Keys.actionsCountdownSeconds }
        #expect(countdown?.kind == .number(defaultValue: 1.5, range: 0.5...5, step: 0.5))
    }
}
