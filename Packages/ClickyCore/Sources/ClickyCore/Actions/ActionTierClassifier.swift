//
//  ActionTierClassifier.swift
//  ClickyCore
//
//  P7: how careful Clicky must be with one action step. Pure: the app reads
//  the live facts (the target element's AX role/subrole/label, its app and
//  window, the frontmost app for keys) into ActionTargetFacts and asks here.
//
//  Tiers, safest rule first:
//   refused   — never done, whatever the owner says: Clicky's own windows,
//               secure / password fields (AXSecureTextField, secure event
//               input), payment fields (card number, CVV, expiry, IBAN…),
//               keychain and security prompts (SecurityAgent, coreautha,
//               Keychain Access, password managers), typing or keys into a
//               terminal (code goes through code mode), System Settings'
//               Privacy & Security panes, Return when the owner never said
//               "press enter" / "send it", system-level key combos (force
//               quit, log out, empty trash, lock), and Safari or any window
//               showing Netflix unless the owner named it this turn.
//   confirm   — waits for the owner's spoken "yes" or a real click on the
//               confirm card: anything that sends, posts, submits, buys,
//               deletes, closes unsaved work or changes settings (classified
//               by the button's label, the key combo, or System Settings as
//               the app), and Return after the owner asked for it.
//   countdown — 1.5 s on screen first (any key, mouse move or "stop"
//               cancels): typing into a field, clicking a button / checkbox /
//               pop-up / row or text that isn't a plain link, other keys.
//   free      — open an app / a link / a search, scroll, links, tabs and
//               menu items, select & copy, highlight, summarize, switch
//               window, wait, code tasks (code mode keeps its own gates).
//

import Foundation

public enum ActionTier: String, Equatable, Sendable, CaseIterable, Comparable {
    case free
    case countdown
    case confirm
    case refused

    public static func < (lhs: ActionTier, rhs: ActionTier) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct ActionTierDecision: Equatable, Sendable {
    public var tier: ActionTier
    /// Why ("password field", "button \"Send\" sends", "plain link").
    public var reason: String

    public init(_ tier: ActionTier, _ reason: String) {
        self.tier = tier
        self.reason = reason
    }
}

/// What the app read about the step's target just before deciding.
public struct ActionTargetFacts: Equatable, Sendable {
    public var bundleIdentifier: String?
    public var applicationName: String?
    public var windowTitle: String?
    /// Raw AX role ("AXButton"), when there is an AX element.
    public var role: String?
    public var subrole: String?
    /// The grounding role from the element list, when the step names an id.
    public var groundingRole: GroundingRole?
    /// Title / description / label as read (or the OCR text).
    public var label: String?
    public var placeholder: String?
    /// AXIdentifier / AXDOMIdentifier / autocomplete hints.
    public var identifier: String?
    /// The document / web area URL, when readable.
    public var url: String?
    public var isOwnApplication: Bool
    public var isSecureEventInputOn: Bool

    public init(bundleIdentifier: String? = nil, applicationName: String? = nil, windowTitle: String? = nil, role: String? = nil, subrole: String? = nil,
                groundingRole: GroundingRole? = nil, label: String? = nil, placeholder: String? = nil, identifier: String? = nil, url: String? = nil,
                isOwnApplication: Bool = false, isSecureEventInputOn: Bool = false) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.role = role
        self.subrole = subrole
        self.groundingRole = groundingRole
        self.label = label
        self.placeholder = placeholder
        self.identifier = identifier
        self.url = url
        self.isOwnApplication = isOwnApplication
        self.isSecureEventInputOn = isSecureEventInputOn
    }
}

/// What the owner said this turn (the task's own request).
public struct ActionTurnContext: Equatable, Sendable {
    public var ownerTranscript: String

    public init(ownerTranscript: String) {
        self.ownerTranscript = ownerTranscript
    }

    public var ownerNamedSafariOrNetflix: Bool { ActionWordMatch.containsWord(in: ownerTranscript, anyOf: ["safari", "netflix"]) }
    public var ownerAskedToPressReturn: Bool { ActionReturnRule.ownerAskedToPressReturn(ownerTranscript) }
}

/// Whole-word, case-insensitive matching on labels and transcripts.
public enum ActionWordMatch {
    public static func normalized(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// True when any phrase appears in `text` bounded by non-letters.
    public static func containsWord(in text: String, anyOf phrases: [String]) -> Bool {
        let haystack = normalized(text)
        for phrase in phrases {
            let escaped = NSRegularExpression.escapedPattern(for: normalized(phrase))
            if haystack.range(of: "(^|[^a-z0-9])\(escaped)($|[^a-z0-9])", options: .regularExpression) != nil { return true }
        }
        return false
    }

    public static func firstWord(in text: String, of phrases: [String]) -> String? {
        phrases.first { containsWord(in: text, anyOf: [$0]) }
    }
}

/// Return / Enter is pressed only when the owner said so in his own words.
public enum ActionReturnRule {
    static let phrases = [
        "press enter", "press return", "hit enter", "hit return", "and enter", "then enter", "press the enter key", "press the return key",
        "send it", "and send", "then send", "send the message", "send that", "submit it", "and submit", "then submit", "and post it", "post it"
    ]

    public static func ownerAskedToPressReturn(_ transcript: String) -> Bool {
        ActionWordMatch.containsWord(in: transcript, anyOf: phrases)
    }
}

public enum ActionTierClassifier {
    // MARK: Bundle lists

    public static let safariBundleIdentifiers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    public static let systemSettingsBundleIdentifiers: Set<String> = ["com.apple.systempreferences", "com.apple.Settings", "com.apple.SystemPreferences"]
    public static let securityBundleIdentifiers: Set<String> = Set(["com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.coreautha",
                                                                    "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.CoreAuthUI"])
        .union(ClickySettings.defaultValueBlockedBundleIDs)
    static let securityApplicationNames = ["securityagent", "coreautha", "coreauthd", "keychain access", "passwords", "1password", "bitwarden"]
    public static let terminalBundleIdentifiers: Set<String> = TypeForMePolicy.terminalBundleIdentifiers.union([
        "io.alacritty", "org.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper", "com.github.wez.wezterm", "org.tabby", "com.raphaelamorim.rio"
    ])
    static let terminalApplicationNames = ["terminal", "iterm", "iterm2", "warp", "ghostty", "alacritty", "kitty", "wezterm", "hyper"]

    // MARK: Label lists

    /// A button with one of these words sends, posts, buys, deletes or changes something for good.
    static let confirmLabelPhrases = [
        "send", "send now", "post", "submit", "publish", "tweet", "reply all", "buy", "buy now", "purchase", "pay", "pay now", "place order", "order now",
        "checkout", "check out", "subscribe", "unsubscribe", "donate", "transfer", "book now", "reserve", "delete", "remove", "trash", "move to trash",
        "erase", "discard", "don't save", "dont save", "save", "save changes", "apply", "confirm", "ok", "allow", "accept", "agree", "approve", "merge",
        "deploy", "install", "uninstall", "sign out", "log out", "sign in", "log in", "upload", "block", "report", "leave", "end call", "archive"
    ]
    /// Field labels that mean a payment form.
    static let paymentFieldPhrases = [
        "card number", "credit card", "debit card", "cardnumber", "cc-number", "cc-csc", "cc-exp", "cvv", "cvv2", "cvc", "csc", "security code",
        "expiry", "expiration", "exp date", "mm/yy", "mm / yy", "iban", "routing number", "account number", "sort code", "bsb"
    ]
    static let passwordFieldPhrases = ["password", "passcode", "passphrase", "pin", "one-time code", "2fa code", "verification code"]
    static let privacyPanePhrases = ["privacy", "privacy & security", "security", "full disk access", "accessibility", "screen recording",
                                     "input monitoring", "location services", "files and folders", "automation", "developer tools"]

    // MARK: Keys

    /// Never pressed: system-level, can't be undone or log the owner out.
    static let refusedKeyCombos: Set<String> = [
        "cmd+opt+escape", "shift+cmd+q", "shift+opt+cmd+q", "ctrl+cmd+q", "shift+cmd+delete", "shift+opt+cmd+delete", "opt+cmd+delete",
        "ctrl+opt+cmd+escape", "shift+cmd+opt+escape", "opt+shift+cmd+escape"
    ].map(normalizedComboText).reduce(into: Set<String>()) { $0.insert($1) }
    /// Close, quit, save, delete: only after a yes.
    static let confirmKeyCombos: Set<String> = [
        "cmd+q", "cmd+w", "shift+cmd+w", "opt+cmd+w", "cmd+delete", "cmd+forwarddelete", "cmd+s", "shift+cmd+s", "cmd+x", "opt+cmd+q"
    ].map(normalizedComboText).reduce(into: Set<String>()) { $0.insert($1) }
    /// Navigation and copying: free.
    static let freeKeyCombos: Set<String> = [
        "up", "down", "left", "right", "pageup", "pagedown", "home", "end", "tab", "shift+tab", "escape", "cmd+c", "cmd+f", "cmd+l", "cmd+t", "cmd+n",
        "cmd+[", "cmd+]", "shift+cmd+[", "shift+cmd+]", "ctrl+tab", "shift+ctrl+tab", "cmd+up", "cmd+down", "cmd+left", "cmd+right", "cmd+1", "cmd+2",
        "cmd+3", "cmd+4", "cmd+5", "cmd+6", "cmd+7", "cmd+8", "cmd+9", "cmd+=", "cmd+-", "cmd+0", "cmd+g", "shift+cmd+g"
    ].map(normalizedComboText).reduce(into: Set<String>()) { $0.insert($1) }

    /// "shift+cmd+q" and "cmd+shift+q" compare equal.
    static func normalizedComboText(_ text: String) -> String {
        ActionKeyCombo.parse(text)?.displayText ?? text
    }

    // MARK: - Classification

    /// `target`: the element the step acts on (click/type/scroll/select/highlight with an id),
    /// the frontmost app and its focused element (type/key/scroll without an id, summarize),
    /// the app being opened or switched to, or the browser a link opens in.
    public static func classify(_ step: ActionStep, target: ActionTargetFacts?, context: ActionTurnContext) -> ActionTierDecision {
        if let refusal = targetRefusal(for: step, target: target, context: context) { return refusal }

        switch step {
        case .openApp:
            if let target, isSystemSettings(target) { return ActionTierDecision(.free, "opening System Settings only shows it") }
            return ActionTierDecision(.free, "opening an app")
        case .openURL:
            return ActionTierDecision(.free, "opening a link")
        case .search:
            return ActionTierDecision(.free, "a web search")
        case .wait:
            return ActionTierDecision(.free, "waiting")
        case .switchWindow:
            return ActionTierDecision(.free, "switching windows")
        case .highlight:
            return ActionTierDecision(.free, "overlay marks only")
        case .summarize:
            return ActionTierDecision(.free, "reading the page")
        case .selectCopy:
            return ActionTierDecision(.free, "select and copy")
        case .scroll:
            return ActionTierDecision(.free, "scrolling")
        case .codeTask:
            return ActionTierDecision(.free, "code mode keeps its own gates")

        case .click:
            let label = target?.label ?? ""
            if let word = ActionWordMatch.firstWord(in: label, of: confirmLabelPhrases) {
                return ActionTierDecision(.confirm, "\u{201C}\(clipped(label))\u{201D} \(confirmVerb(for: word))")
            }
            if let target, isSystemSettings(target) { return ActionTierDecision(.confirm, "changes a setting in System Settings") }
            switch target?.groundingRole ?? roleFromAX(target?.role) {
            case .link?: return ActionTierDecision(.free, "a link")
            case .tab?: return ActionTierDecision(.free, "a tab")
            case .menuItem?, .menu?: return ActionTierDecision(.free, "a menu item")
            case .dock?: return ActionTierDecision(.free, "a Dock item")
            case .button?: return ActionTierDecision(.countdown, "a button")
            case .checkBox?, .radio?, .popUp?, .slider?: return ActionTierDecision(.countdown, "changes a control's state")
            default: return ActionTierDecision(.countdown, "an ordinary click")
            }

        case .type(_, _, let pressesReturn):
            if pressesReturn {
                // targetRefusal already refused Return the owner didn't ask for.
                return ActionTierDecision(.confirm, "typing then pressing Return sends or submits")
            }
            if let target, isSystemSettings(target) { return ActionTierDecision(.confirm, "changes a setting in System Settings") }
            return ActionTierDecision(.countdown, "typing into a field")

        case .key(let combo):
            let comboText = combo.displayText
            if combo.isReturnKey { return ActionTierDecision(.confirm, "Return sends or submits") }
            if confirmKeyCombos.contains(comboText) { return ActionTierDecision(.confirm, "\(comboText) can close, quit, save or delete") }
            if let target, isSystemSettings(target) { return ActionTierDecision(.confirm, "changes a setting in System Settings") }
            if freeKeyCombos.contains(comboText) { return ActionTierDecision(.free, "navigation key") }
            return ActionTierDecision(.countdown, "a key press")
        }
    }

    /// The refusal rules, safest first; nil when none applies.
    static func targetRefusal(for step: ActionStep, target: ActionTargetFacts?, context: ActionTurnContext) -> ActionTierDecision? {
        // Return the owner never asked for: no tier makes it okay.
        if case .type(_, _, true) = step, !context.ownerAskedToPressReturn {
            return ActionTierDecision(.refused, "Return is pressed only when you say \u{201C}press enter\u{201D} or \u{201C}send it\u{201D}")
        }
        if case .key(let combo) = step {
            if combo.isReturnKey && !context.ownerAskedToPressReturn {
                return ActionTierDecision(.refused, "Return is pressed only when you say \u{201C}press enter\u{201D} or \u{201C}send it\u{201D}")
            }
            if refusedKeyCombos.contains(combo.displayText) { return ActionTierDecision(.refused, "\(combo.displayText) is a system-level shortcut") }
        }
        // Waiting and code tasks touch no app.
        switch step {
        case .wait, .codeTask: return nil
        default: break
        }
        guard let target else {
            switch step {
            case .openURL, .search, .openApp, .switchWindow: return nil
            default: return ActionTierDecision(.refused, "couldn't tell what it would act on")
            }
        }
        if target.isOwnApplication { return ActionTierDecision(.refused, "that's Clicky's own window") }
        if isSecurityApplication(target) { return ActionTierDecision(.refused, "keychain, password and security prompts are off limits") }
        if isProtectedFromActions(target) && !context.ownerNamedSafariOrNetflix {
            return ActionTierDecision(.refused, "Safari and Netflix are left alone unless you name them")
        }
        if isSystemSettings(target) && isPrivacyPane(target) {
            return ActionTierDecision(.refused, "Privacy & Security settings are off limits")
        }
        let actsOnField: Bool
        switch step {
        case .type, .click, .key, .selectCopy: actsOnField = true
        default: actsOnField = false
        }
        if actsOnField {
            if target.subrole == TypeForMePolicy.secureTextFieldSubrole || target.role == TypeForMePolicy.secureTextFieldSubrole {
                return ActionTierDecision(.refused, "that's a password field")
            }
            if isPaymentField(target) { return ActionTierDecision(.refused, "that's a payment field") }
        }
        switch step {
        case .type, .key:
            if target.isSecureEventInputOn { return ActionTierDecision(.refused, "a password prompt has secure input on") }
            if isTerminal(target) { return ActionTierDecision(.refused, "Clicky doesn't type into terminals — that goes through code mode") }
            if isPasswordLabelled(target) { return ActionTierDecision(.refused, "that looks like a password field") }
        default:
            break
        }
        return nil
    }

    // MARK: - Facts

    public static func isSafari(_ target: ActionTargetFacts) -> Bool {
        if let bundleIdentifier = target.bundleIdentifier, safariBundleIdentifiers.contains(bundleIdentifier) { return true }
        return target.applicationName.map { ActionWordMatch.normalized($0).hasPrefix("safari") } ?? false
    }

    public static func showsNetflix(_ target: ActionTargetFacts) -> Bool {
        [target.windowTitle, target.url, target.label].compactMap { $0 }.contains { ActionWordMatch.normalized($0).contains("netflix") }
    }

    /// The owner watches Netflix in Safari: both are hands-off unless named.
    public static func isProtectedFromActions(_ target: ActionTargetFacts) -> Bool {
        isSafari(target) || showsNetflix(target)
    }

    public static func isSystemSettings(_ target: ActionTargetFacts) -> Bool {
        if let bundleIdentifier = target.bundleIdentifier, systemSettingsBundleIdentifiers.contains(bundleIdentifier) { return true }
        guard let name = target.applicationName.map(ActionWordMatch.normalized) else { return false }
        return name == "system settings" || name == "system preferences"
    }

    static func isPrivacyPane(_ target: ActionTargetFacts) -> Bool {
        [target.windowTitle, target.label].compactMap { $0 }.contains { ActionWordMatch.containsWord(in: $0, anyOf: privacyPanePhrases) }
    }

    public static func isSecurityApplication(_ target: ActionTargetFacts) -> Bool {
        if let bundleIdentifier = target.bundleIdentifier, securityBundleIdentifiers.contains(bundleIdentifier) { return true }
        guard let name = target.applicationName.map(ActionWordMatch.normalized) else { return false }
        return securityApplicationNames.contains(name)
    }

    public static func isTerminal(_ target: ActionTargetFacts) -> Bool {
        if let bundleIdentifier = target.bundleIdentifier, terminalBundleIdentifiers.contains(bundleIdentifier) { return true }
        guard let name = target.applicationName.map(ActionWordMatch.normalized) else { return false }
        return terminalApplicationNames.contains(name)
    }

    static func isPaymentField(_ target: ActionTargetFacts) -> Bool {
        [target.label, target.placeholder, target.identifier].compactMap { $0 }.contains { ActionWordMatch.containsWord(in: $0, anyOf: paymentFieldPhrases) }
    }

    static func isPasswordLabelled(_ target: ActionTargetFacts) -> Bool {
        [target.label, target.placeholder, target.identifier].compactMap { $0 }.contains { ActionWordMatch.containsWord(in: $0, anyOf: passwordFieldPhrases) }
    }

    static func roleFromAX(_ role: String?) -> GroundingRole? {
        switch role {
        case "AXLink": return .link
        case "AXButton", "AXMenuButton": return .button
        case "AXTabGroup", "AXTab": return .tab
        case "AXMenuItem", "AXMenuBarItem": return .menuItem
        case "AXCheckBox": return .checkBox
        case "AXRadioButton": return .radio
        case "AXPopUpButton": return .popUp
        case "AXSlider": return .slider
        case "AXDockItem": return .dock
        default: return nil
        }
    }

    static func confirmVerb(for word: String) -> String {
        switch word {
        case "send", "send now", "post", "submit", "publish", "tweet", "reply all", "upload": return "sends or posts"
        case "buy", "buy now", "purchase", "pay", "pay now", "place order", "order now", "checkout", "check out", "subscribe", "donate", "transfer",
             "book now", "reserve": return "buys or pays"
        case "delete", "remove", "trash", "move to trash", "erase", "discard", "don't save", "dont save", "archive", "block", "report", "leave",
             "end call", "unsubscribe": return "deletes, removes or ends something"
        case "save", "save changes", "apply", "install", "uninstall", "merge", "deploy": return "saves or applies changes"
        default: return "needs your yes"
        }
    }

    static func clipped(_ text: String) -> String {
        text.count > 40 ? String(text.prefix(39)) + "…" : text
    }
}

/// Which browser a link or search opens in.
public enum ActionBrowserChoice {
    public static let knownBrowsers: [(bundleIdentifier: String, spokenNames: [String])] = [
        ("com.google.Chrome", ["chrome", "google chrome"]),
        ("company.thebrowser.Browser", ["arc"]),
        ("org.mozilla.firefox", ["firefox"]),
        ("com.microsoft.edgemac", ["edge", "microsoft edge"]),
        ("com.brave.Browser", ["brave"]),
        ("com.apple.Safari", ["safari"])
    ]

    public enum Decision: Equatable, Sendable {
        case use(bundleIdentifier: String)
        case refused(reason: String)
    }

    /// The browser the owner named (if installed), else the default one unless
    /// it's Safari he didn't name, else the first installed non-Safari browser.
    public static func choose(defaultBrowserBundleIdentifier: String?, installedBundleIdentifiers: Set<String>, ownerTranscript: String) -> Decision {
        for browser in knownBrowsers where installedBundleIdentifiers.contains(browser.bundleIdentifier) {
            if ActionWordMatch.containsWord(in: ownerTranscript, anyOf: browser.spokenNames) { return .use(bundleIdentifier: browser.bundleIdentifier) }
        }
        let context = ActionTurnContext(ownerTranscript: ownerTranscript)
        if let defaultBrowserBundleIdentifier {
            let isSafariDefault = ActionTierClassifier.safariBundleIdentifiers.contains(defaultBrowserBundleIdentifier)
            if !isSafariDefault || context.ownerNamedSafariOrNetflix { return .use(bundleIdentifier: defaultBrowserBundleIdentifier) }
        }
        for browser in knownBrowsers where !ActionTierClassifier.safariBundleIdentifiers.contains(browser.bundleIdentifier)
            && installedBundleIdentifiers.contains(browser.bundleIdentifier) {
            return .use(bundleIdentifier: browser.bundleIdentifier)
        }
        return .refused(reason: "the only browser is Safari, which is left alone unless you name it")
    }
}
