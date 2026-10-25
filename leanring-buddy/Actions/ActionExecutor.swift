//
//  ActionExecutor.swift
//  leanring-buddy
//
//  P7: the system side of one action step. Two halves, kept apart so the
//  safety tier is always decided between them:
//   - resolve: read-only. Finds what the step would act on (the element
//     #id of this turn's grounding, the frontmost app and its focused
//     field, the app to open, the browser a link opens in) and reads the
//     live facts ActionTierClassifier needs (AX role/subrole/label, app,
//     window title, secure input). Never focuses, clicks or opens anything.
//   - perform: does it. AX first (AXPress, AXValue / AXSelectedText), a
//     synthetic event only as the fallback — every event made through
//     SyntheticEvents, so it carries SyntheticEventTag and the physical-
//     input monitor never mistakes it for the owner. Return is only ever
//     posted for a step the tier allowed: the owner asked for it (after the
//     countdown) or said yes to "Press enter?".
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ClickyCore

/// What a step acts on, as resolved just before its tier is decided.
struct ResolvedActionTarget {
    var facts: ActionTargetFacts?
    var axElement: AXUIElement?
    var groundingElement: GroundingElement?
    var processIdentifier: pid_t?
    var frameCG: CGRect?
    /// open_app: the app bundle to launch.
    var applicationURL: URL?
    /// switch_window / open_app: the running app.
    var runningApplication: NSRunningApplication?
    /// switch_window by title: the window to raise.
    var windowElement: AXUIElement?
    /// open_url / search: the browser to open it in, and the URL.
    var browserApplicationURL: URL?
    var url: URL?
    /// Couldn't find the target at all (not run, not a refusal).
    var failure: String?
    /// A refusal decided while resolving (no browser but Safari).
    var refusal: String?
    /// P8 read_article / notes / sentence highlights: the article window.
    var articleWindow: ArticleWindowTarget?
}

/// What performing a step produced.
struct ActionPerformResult {
    var outcome: ActionStepOutcome
    /// summarize without text: the page text for the observe turn.
    var pageText: String?
    /// read_article: the article for the observe turn.
    var articleText: String?

    init(_ outcome: ActionStepOutcome, pageText: String? = nil, articleText: String? = nil) {
        self.outcome = outcome
        self.pageText = pageText
        self.articleText = articleText
    }
}

/// An AXUIElement handed to a background walk (AX calls are thread-safe).
nonisolated struct UncheckedAXElement: @unchecked Sendable {
    let element: AXUIElement
}

@MainActor
final class ActionExecutor {
    private unowned let companionManager: CompanionManager
    /// Told about every pointer event Clicky posts (its cursor may warp).
    var onSyntheticPointerEvent: () -> Void = {}

    static let settleAfterFocus: UInt64 = 150_000_000
    static let delayBetweenUnicodeChunks: UInt64 = 12_000_000

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    // MARK: - Resolve (read only)

    func resolve(_ step: ActionStep, groundedTurn: GroundedTurn, ownerTranscript: String) -> ResolvedActionTarget {
        switch step {
        case .openApp(let name, let bundleIdentifier):
            guard let candidate = Self.findApplication(name: name, bundleIdentifier: bundleIdentifier) else {
                return ResolvedActionTarget(failure: "no app called \(name ?? bundleIdentifier ?? "that") on this Mac")
            }
            let runningApplication = candidate.bundleIdentifier.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            var facts = ActionTargetFacts(bundleIdentifier: candidate.bundleIdentifier, applicationName: candidate.name)
            facts.isOwnApplication = candidate.bundleIdentifier == Bundle.main.bundleIdentifier
            return ResolvedActionTarget(facts: facts, applicationURL: candidate.path.map { URL(fileURLWithPath: $0) }, runningApplication: runningApplication)

        case .openURL(let url):
            return resolveBrowser(for: url, ownerTranscript: ownerTranscript)

        case .search(let query, let engine):
            guard let url = engine.resultsURL(for: query) else { return ResolvedActionTarget(failure: "couldn't build the search link") }
            return resolveBrowser(for: url, ownerTranscript: ownerTranscript)

        case .click(let elementID):
            return resolveElement(elementID, in: groundedTurn)

        case .type(let elementID, _, _):
            if let elementID { return resolveElement(elementID, in: groundedTurn) }
            return resolveFrontmost(includingFocusedElement: true)

        case .key:
            return resolveFrontmost(includingFocusedElement: true)

        case .scroll(let elementID, _, _):
            if let elementID { return resolveElement(elementID, in: groundedTurn) }
            return resolveFrontmost(includingFocusedElement: false)

        case .selectCopy(let elementID, _):
            if let elementID { return resolveElement(elementID, in: groundedTurn) }
            return resolveFrontmost(includingFocusedElement: false)

        case .summarize:
            return resolveFrontmost(includingFocusedElement: false)

        case .highlight(let targets, _):
            for target in targets {
                if case .element(let elementID) = target, groundedTurn.registry[elementID] != nil { return resolveElement(elementID, in: groundedTurn) }
            }
            // Sentences go on the article (the front browser), even when Clicky or a terminal is frontmost.
            if targets.contains(where: \.isSentence) { return resolveArticleWindow() }
            return resolveFrontmost(includingFocusedElement: false)

        case .readArticle:
            return resolveArticleWindow()

        case .notes:
            // Notes can still be shown with no browser on screen (docked at the display edge).
            let articleTarget = resolveArticleWindow()
            return articleTarget.failure == nil ? articleTarget : resolveFrontmost(includingFocusedElement: false)

        case .switchWindow(let app, let title):
            return resolveWindow(app: app, title: title)

        case .wait, .codeTask:
            return ResolvedActionTarget()
        }
    }

    private func resolveElement(_ elementID: Int, in groundedTurn: GroundedTurn) -> ResolvedActionTarget {
        guard let groundingElement = groundedTurn.registry[elementID] else {
            return ResolvedActionTarget(failure: "there's no #\(elementID) on this screen")
        }
        let axElement = groundingElement.axNode.flatMap { Self.axElement(from: $0.underlyingObject) }
        let liveFrame = AXGroundingLiveLookup(ax: companionManager.groundingCoordinator.ax).refreshedFrame(of: groundingElement) ?? groundingElement.visibleFrameCG
        let facts = Self.facts(processIdentifier: groundingElement.processIdentifier, element: axElement, groundingElement: groundingElement)
        return ResolvedActionTarget(facts: facts, axElement: axElement, groundingElement: groundingElement,
                                    processIdentifier: groundingElement.processIdentifier, frameCG: liveFrame)
    }

    private func resolveFrontmost(includingFocusedElement: Bool) -> ResolvedActionTarget {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return ResolvedActionTarget(failure: "no app is in front") }
        let processIdentifier = frontmostApplication.processIdentifier
        let focusedElement = includingFocusedElement ? TypeForMeAccessibility.focusedElement(processIdentifier: processIdentifier) : nil
        let facts = Self.facts(processIdentifier: processIdentifier, element: focusedElement, groundingElement: nil)
        let windowFrame = Self.focusedWindow(processIdentifier: processIdentifier).flatMap(TypeForMeAccessibility.frameCG)
        return ResolvedActionTarget(facts: facts, axElement: focusedElement, processIdentifier: processIdentifier,
                                    frameCG: focusedElement.flatMap(TypeForMeAccessibility.frameCG) ?? windowFrame,
                                    runningApplication: frontmostApplication)
    }

    /// P8: the article window (the frontmost browser's front window, ArticleWindowChoice).
    private func resolveArticleWindow() -> ResolvedActionTarget {
        guard let articleWindow = ArticleReader.findArticleWindow() else { return ResolvedActionTarget(failure: "no browser window with an article is on screen") }
        var facts = Self.facts(processIdentifier: articleWindow.processIdentifier, element: nil, groundingElement: nil)
        if let windowElement = articleWindow.windowElement { facts.windowTitle = TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: windowElement) ?? facts.windowTitle }
        return ResolvedActionTarget(facts: facts, processIdentifier: articleWindow.processIdentifier, frameCG: articleWindow.windowFrameCG,
                                    runningApplication: NSRunningApplication(processIdentifier: articleWindow.processIdentifier), articleWindow: articleWindow)
    }

    private func resolveBrowser(for url: URL, ownerTranscript: String) -> ResolvedActionTarget {
        let workspace = NSWorkspace.shared
        let defaultBrowserBundleIdentifier = workspace.urlForApplication(toOpen: URL(string: "https://example.com")!).flatMap { Bundle(url: $0)?.bundleIdentifier }
        var installedBundleIdentifiers: Set<String> = []
        for browser in ActionBrowserChoice.knownBrowsers where workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil {
            installedBundleIdentifiers.insert(browser.bundleIdentifier)
        }
        if let defaultBrowserBundleIdentifier { installedBundleIdentifiers.insert(defaultBrowserBundleIdentifier) }
        switch ActionBrowserChoice.choose(defaultBrowserBundleIdentifier: defaultBrowserBundleIdentifier, installedBundleIdentifiers: installedBundleIdentifiers,
                                          ownerTranscript: ownerTranscript) {
        case .refused(let reason):
            return ResolvedActionTarget(url: url, refusal: reason)
        case .use(let bundleIdentifier):
            guard let browserURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return ResolvedActionTarget(url: url, failure: "couldn't find the browser")
            }
            let name = FileManager.default.displayName(atPath: browserURL.path).replacingOccurrences(of: ".app", with: "")
            return ResolvedActionTarget(facts: ActionTargetFacts(bundleIdentifier: bundleIdentifier, applicationName: name),
                                        browserApplicationURL: browserURL, url: url)
        }
    }

    private func resolveWindow(app: String?, title: String?) -> ResolvedActionTarget {
        let regularApplications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var candidateApplications = regularApplications
        if let app {
            let candidates = regularApplications.map { ActionApplicationCandidate(name: $0.localizedName ?? "", bundleIdentifier: $0.bundleIdentifier, path: $0.bundleURL?.path) }
            guard let match = ActionAppNameMatcher.bestMatch(name: app, bundleIdentifier: nil, candidates: candidates),
                  let runningApplication = regularApplications.first(where: { $0.bundleIdentifier == match.bundleIdentifier && $0.localizedName == match.name }) else {
                // Not running: open it instead.
                if title == nil, let candidate = Self.findApplication(name: app, bundleIdentifier: nil) {
                    return ResolvedActionTarget(facts: ActionTargetFacts(bundleIdentifier: candidate.bundleIdentifier, applicationName: candidate.name),
                                                applicationURL: candidate.path.map { URL(fileURLWithPath: $0) })
                }
                return ResolvedActionTarget(failure: "\(app) isn't open")
            }
            candidateApplications = [runningApplication]
        }
        if let title {
            let wantedTitle = title.lowercased()
            for runningApplication in candidateApplications where runningApplication.processIdentifier != getpid() {
                let applicationElement = TypeForMeAccessibility.applicationElement(processIdentifier: runningApplication.processIdentifier)
                for window in TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: applicationElement) {
                    guard let windowTitle = TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: window), windowTitle.lowercased().contains(wantedTitle) else { continue }
                    var facts = Self.facts(processIdentifier: runningApplication.processIdentifier, element: nil, groundingElement: nil)
                    facts.windowTitle = windowTitle
                    return ResolvedActionTarget(facts: facts, processIdentifier: runningApplication.processIdentifier,
                                                runningApplication: runningApplication, windowElement: window)
                }
            }
            return ResolvedActionTarget(failure: "no window titled \u{201C}\(title)\u{201D}")
        }
        guard let runningApplication = candidateApplications.first else { return ResolvedActionTarget(failure: "nothing to switch to") }
        let facts = Self.facts(processIdentifier: runningApplication.processIdentifier, element: nil, groundingElement: nil)
        return ResolvedActionTarget(facts: facts, processIdentifier: runningApplication.processIdentifier, runningApplication: runningApplication)
    }

    // MARK: - Facts

    static func axElement(from object: AnyObject) -> AXUIElement? {
        guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (object as! AXUIElement)
    }

    static func focusedWindow(processIdentifier: pid_t) -> AXUIElement? {
        let applicationElement = TypeForMeAccessibility.applicationElement(processIdentifier: processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: applicationElement).first
        }
        // swiftlint:disable:next force_cast
        return (windowValue as! AXUIElement)
    }

    static func facts(processIdentifier: pid_t, element: AXUIElement?, groundingElement: GroundingElement?) -> ActionTargetFacts {
        let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
        var facts = ActionTargetFacts()
        facts.bundleIdentifier = runningApplication?.bundleIdentifier
        facts.applicationName = runningApplication?.localizedName ?? groundingElement?.applicationName
        facts.isOwnApplication = processIdentifier == getpid() || (runningApplication?.bundleIdentifier != nil && runningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier)
        facts.isSecureEventInputOn = IsSecureEventInputEnabled()
        facts.groundingRole = groundingElement?.role
        facts.windowTitle = groundingElement?.windowTitle
            ?? focusedWindow(processIdentifier: processIdentifier).flatMap { TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: $0) }
        facts.windowIdentifier = groundingElement?.windowID ?? frontWindowIdentifier(processIdentifier: processIdentifier)
        if ActionTierClassifier.isTerminal(facts) {
            facts.terminalForeground = terminalForeground(processIdentifier: processIdentifier, windowTitle: facts.windowTitle)
        }
        if let element {
            facts.role = TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: element)
            facts.subrole = TypeForMeAccessibility.stringAttribute(kAXSubroleAttribute, of: element)
            facts.placeholder = TypeForMeAccessibility.stringAttribute(kAXPlaceholderValueAttribute, of: element)
            facts.identifier = TypeForMeAccessibility.stringAttribute(kAXIdentifierAttribute, of: element)
                ?? TypeForMeAccessibility.stringAttribute("AXDOMIdentifier", of: element)
            let axLabel = [kAXTitleAttribute, kAXDescriptionAttribute].lazy
                .compactMap { TypeForMeAccessibility.stringAttribute($0, of: element)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            facts.label = groundingElement?.label ?? axLabel
        } else {
            facts.label = groundingElement?.label ?? groundingElement?.value
        }
        return facts
    }

    /// The app's frontmost normal window (CGWindowID), front to back. Numbers only: no titles, no pixels.
    static func frontWindowIdentifier(processIdentifier: pid_t) -> UInt32? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let number = window[kCGWindowNumber as String] as? Int else { continue }
            return UInt32(number)
        }
        return nil
    }

    /// Safari's front window right now (for "type it in Safari" follow-ups), or nil when Safari isn't open.
    static func frontSafariWindowIdentifier() -> (isRunning: Bool, windowIdentifier: UInt32?) {
        for bundleIdentifier in ActionTierClassifier.safariBundleIdentifiers {
            if let safari = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                return (true, frontWindowIdentifier(processIdentifier: safari.processIdentifier))
            }
        }
        return (false, nil)
    }

    /// What runs in the terminal's front tab: the tty from the window title
    /// (Terminal can show it), else the only tty under the app — or, with
    /// several tabs, Claude Code only when every tab's foreground job is it.
    /// Read-only (libproc, like `ps -t <tty> -o comm=`); nil = couldn't tell.
    static func terminalForeground(processIdentifier: pid_t, windowTitle: String?) -> ActionTerminalForeground? {
        if let ttyName = FrontWindowRepoResolver.ttyName(fromTitle: windowTitle) {
            return TerminalTTYLookup.foreground(ttyName: ttyName)
        }
        let kinds = TerminalTTYLookup.ttyNames(underApplication: processIdentifier).compactMap(TerminalTTYLookup.foreground(ttyName:))
        if kinds.count == 1 { return kinds[0] }
        if !kinds.isEmpty && kinds.allSatisfy({ $0 == .claudeCode }) { return .claudeCode }
        if !kinds.isEmpty && kinds.allSatisfy({ $0 == .shell }) { return .shell }
        return nil
    }

    /// Running apps plus the usual app folders (names and bundle ids only; nothing is launched).
    static func findApplication(name: String?, bundleIdentifier: String?) -> ActionApplicationCandidate? {
        if let bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return ActionApplicationCandidate(name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                                              bundleIdentifier: bundleIdentifier, path: url.path)
        }
        var candidates: [ActionApplicationCandidate] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { ActionApplicationCandidate(name: $0.localizedName ?? "", bundleIdentifier: $0.bundleIdentifier, path: $0.bundleURL?.path) }
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       (NSHomeDirectory() as NSString).appendingPathComponent("Applications"), "/System/Library/CoreServices"]
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (folder as NSString).appendingPathComponent(entry)
                // CoreServices: Finder only (no agents).
                if folder.hasSuffix("CoreServices") && entry != "Finder.app" { continue }
                candidates.append(ActionApplicationCandidate(name: String(entry.dropLast(4)), bundleIdentifier: Bundle(path: path)?.bundleIdentifier, path: path))
            }
        }
        return ActionAppNameMatcher.bestMatch(name: name, bundleIdentifier: bundleIdentifier, candidates: candidates)
    }

    // MARK: - Perform

    /// Runs a step whose tier allowed it. `session`: the answer on screen (highlights draw through it).
    func perform(_ step: ActionStep, target: ResolvedActionTarget, groundedTurn: GroundedTurn, session: AnswerSession?,
                 ownerTranscript: String, isCancelled: @escaping () -> Bool) async -> ActionPerformResult {
        switch step {
        case .highlight(let targets, let notes):
            return ActionPerformResult(await highlight(targets: targets, notes: notes, target: target, session: session))
        case .readArticle:
            guard let articleWindow = target.articleWindow else { return ActionPerformResult(.failed(reason: "no article window")) }
            let result = await companionManager.articleController.readArticle(target: articleWindow, scroll: { [weak self] point, pixels in
                self?.postPixelScroll(at: point, pixels: pixels)
            }, isCancelled: isCancelled)
            guard result.document.utf16Length > 0 else { return ActionPerformResult(.failed(reason: "couldn't read any text in the article window")) }
            let detail = "read \(result.document.utf16Length) characters via \(result.document.source.rawValue)" + (result.document.isTruncated ? ", cut at the limit" : "")
            return ActionPerformResult(.done(detail: detail), articleText: ArticleModelText.text(for: result.document))
        case .notes(let notes):
            companionManager.articleController.showNotes(notes, target: target.articleWindow)
            // The model normally says the summary as its spoken line; say it here only if it didn't.
            if let session, !session.coordinator.isSilent, ArticleSummarySpeech.needsSpeaking(summary: notes.summary, rawResponse: session.rawResponse) {
                companionManager.speakCodeModeLine(notes.summary)
            } else if session == nil {
                companionManager.speakCodeModeLine(notes.summary)
            }
            return ActionPerformResult(.done(detail: "notes panel shown with \(notes.items.count) notes"))
        default:
            let legacy = await performOther(step, target: target, groundedTurn: groundedTurn, session: session, ownerTranscript: ownerTranscript, isCancelled: isCancelled)
            return ActionPerformResult(legacy.outcome, pageText: legacy.pageText)
        }
    }

    /// P8 highlight: sentences become highlighter strokes on the article (tracked as it scrolls);
    /// element ids and short labels stay overlay marks (box / underline) as before.
    private func highlight(targets: [ActionHighlightTarget], notes: [String], target: ResolvedActionTarget, session: AnswerSession?) async -> ActionStepOutcome {
        let sentenceTargets = targets.enumerated().filter { $0.element.isSentence }
        var markTargets = targets.enumerated().filter { !$0.element.isSentence }.map { (target: $0.element, note: $0.offset < notes.count ? notes[$0.offset] : "") }
        var details: [String] = []
        if !sentenceTargets.isEmpty {
            guard let articleWindow = target.articleWindow ?? ArticleReader.findArticleWindow() else { return .failed(reason: "no browser window with an article is on screen") }
            let sentences = sentenceTargets.compactMap { $0.element.text }
            let outcome = await companionManager.articleController.highlight(sentences: sentences, target: articleWindow)
            details.append("\(outcome.matchedCount) of \(sentences.count) sentences highlighted" + (outcome.methods.isEmpty ? "" : " (\(outcome.methods.joined(separator: ", ")))"))
            if !outcome.unmatchedSentences.isEmpty {
                details.append("not found on the page: " + outcome.unmatchedSentences.map { "\u{201C}\($0.prefix(50))…\u{201D}" }.joined(separator: "; ") + " — copy sentences word for word")
            }
            if outcome.matchedCount == 0 && markTargets.isEmpty {
                // Last chance: the old on-screen text marks (they match OCR on screen).
                markTargets = outcome.unmatchedSentences.map { (target: ActionHighlightTarget.text($0), note: "") }
                if session == nil { return .failed(reason: details.joined(separator: "; ")) }
            }
        }
        if !markTargets.isEmpty {
            guard let session else { return details.isEmpty ? .failed(reason: "no answer on screen to draw marks with") : .done(detail: details.joined(separator: "; ")) }
            let parsedTags = ActionHighlightTags.tags(targets: markTargets.map(\.target), notes: markTargets.map(\.note)).compactMap(MarkTagParser.parse)
            if !parsedTags.isEmpty {
                session.showActionHighlights(parsedTags)
                details.append("\(parsedTags.count) marked")
            }
        }
        guard !details.isEmpty else { return .failed(reason: "couldn't make marks for those targets") }
        return .done(detail: details.joined(separator: "; "))
    }

    /// One tagged pixel scroll over the article (positive = further down the page), pointer moved there first like `scroll`.
    func postPixelScroll(at point: CGPoint, pixels: Int) {
        onSyntheticPointerEvent()
        SyntheticEvents.mouseEvent(.mouseMoved, at: point)?.post(tap: .cghidEventTap)
        ArticleHighlightController.postScroll(at: point, pixels: pixels)
        onSyntheticPointerEvent()
    }

    private func performOther(_ step: ActionStep, target: ResolvedActionTarget, groundedTurn: GroundedTurn, session: AnswerSession?,
                              ownerTranscript: String, isCancelled: @escaping () -> Bool) async -> (outcome: ActionStepOutcome, pageText: String?) {
        switch step {
        case .openApp:
            if let runningApplication = target.runningApplication, !runningApplication.isTerminated {
                runningApplication.activate(options: [.activateAllWindows])
                return (.done(detail: "brought it forward"), nil)
            }
            guard let applicationURL = target.applicationURL else { return (.failed(reason: "couldn't find the app"), nil) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
                return (.done(detail: nil), nil)
            } catch {
                return (.failed(reason: "the app didn't open"), nil)
            }

        case .openURL, .search:
            guard let url = target.url, let browserApplicationURL = target.browserApplicationURL else { return (.failed(reason: "no browser to open it in"), nil) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: browserApplicationURL, configuration: configuration)
                return (.done(detail: target.facts?.applicationName.map { "in \($0)" }), nil)
            } catch {
                return (.failed(reason: "the browser didn't open the link"), nil)
            }

        case .click:
            return (await click(target), nil)

        case .type(let elementID, let text, let pressesReturn):
            return (await type(text, into: target, focusesFirst: elementID != nil, pressesReturn: pressesReturn, isCancelled: isCancelled), nil)

        case .key(let combo):
            guard TypeForMeSyntheticEvents.areNoModifiersHeld(CGEventSource.flagsState(.hidSystemState)) else { return (.failed(reason: "a modifier key was held down"), nil) }
            postKey(combo)
            return (.done(detail: nil), nil)

        case .scroll(_, let direction, let amount):
            guard let frame = target.frameCG, frame.width > 0, frame.height > 0 else { return (.failed(reason: "nothing to scroll"), nil) }
            scroll(at: CGPoint(x: frame.midX, y: frame.midY), direction: direction, amount: amount)
            return (.done(detail: nil), nil)

        case .selectCopy(_, let text):
            let copiedText: String?
            if let text {
                copiedText = text
            } else if let element = target.axElement {
                let selectedText = TypeForMeAccessibility.stringAttribute(kAXSelectedTextAttribute, of: element)
                copiedText = [selectedText, TypeForMeAccessibility.value(of: element), target.groundingElement?.label]
                    .compactMap { $0 }.first { !$0.isEmpty }
            } else {
                copiedText = target.groundingElement?.label ?? target.groundingElement?.value
            }
            guard let copiedText, !copiedText.isEmpty else { return (.failed(reason: "nothing to copy there"), nil) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copiedText, forType: .string)
            return (.done(detail: "copied \(copiedText.count) characters"), nil)

        case .wait(let seconds):
            let endUptime = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < endUptime {
                if isCancelled() { return (.cancelled, nil) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return (.done(detail: nil), nil)

        case .switchWindow:
            if let windowElement = target.windowElement {
                AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
                target.runningApplication?.activate(options: [])
                return (.done(detail: nil), nil)
            }
            if let runningApplication = target.runningApplication {
                runningApplication.activate(options: [.activateAllWindows])
                return (.done(detail: nil), nil)
            }
            if let applicationURL = target.applicationURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
                return (.done(detail: "it wasn't open, so i opened it"), nil)
            }
            return (.failed(reason: "nothing to switch to"), nil)

        case .highlight, .readArticle, .notes:
            // Handled in perform.
            return (.failed(reason: "internal: handled elsewhere"), nil)

        case .summarize(let text, let title):
            if let text {
                companionManager.boardController.presentStatic(board: ActionSummaryBoard.board(title: title, summaryText: text))
                return (.done(detail: "summary shown on the board"), nil)
            }
            let (pageText, source) = await readPageText(target: target, groundedTurn: groundedTurn)
            guard !pageText.isEmpty else { return (.failed(reason: "couldn't read any text in the front window"), nil) }
            return (.done(detail: "read \(pageText.count) characters via \(source.rawValue)"), pageText)

        case .codeTask(let project, let instructions):
            return (startCodeTask(project: project, instructions: instructions, ownerTranscript: ownerTranscript), nil)
        }
    }

    // MARK: Click

    private func click(_ target: ResolvedActionTarget) async -> ActionStepOutcome {
        if let element = target.axElement {
            let actionNames = Self.actionNames(of: element)
            if actionNames.contains(kAXPressAction as String) || actionNames.isEmpty {
                if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return .done(detail: "pressed") }
            }
        }
        guard let frame = target.frameCG, frame.width > 0, frame.height > 0 else { return .failed(reason: "couldn't find where to click") }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        // Never click through another app's window (or Clicky's own).
        if let expectedProcessIdentifier = target.processIdentifier {
            let systemWideElement = AXUIElementCreateSystemWide()
            var hitElement: AXUIElement?
            if AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &hitElement) == .success, let hitElement {
                var hitProcessIdentifier: pid_t = 0
                AXUIElementGetPid(hitElement, &hitProcessIdentifier)
                if hitProcessIdentifier != expectedProcessIdentifier { return .failed(reason: "something is covering it") }
            }
        }
        guard TypeForMeSyntheticEvents.areNoModifiersHeld(CGEventSource.flagsState(.hidSystemState)) else { return .failed(reason: "a modifier key was held down") }
        postClick(at: point)
        return .done(detail: "clicked")
    }

    static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names = names as? [String] else { return [] }
        return names
    }

    private func postClick(at point: CGPoint) {
        onSyntheticPointerEvent()
        for (type, clickState) in [(CGEventType.mouseMoved, 0), (.leftMouseDown, 1), (.leftMouseUp, 1)] {
            guard let event = SyntheticEvents.mouseEvent(type, at: point) else { continue }
            if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
            event.post(tap: .cghidEventTap)
        }
        onSyntheticPointerEvent()
    }

    // MARK: Type

    private func type(_ text: String, into target: ResolvedActionTarget, focusesFirst: Bool, pressesReturn: Bool,
                      isCancelled: @escaping () -> Bool) async -> ActionStepOutcome {
        guard var element = target.axElement else { return .failed(reason: "no text field to type into") }
        if focusesFirst {
            let didFocus = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
            if !didFocus, let frame = target.frameCG, frame.width > 0 { postClick(at: CGPoint(x: frame.midX, y: frame.midY)) }
            try? await Task.sleep(nanoseconds: Self.settleAfterFocus)
            // A web field's focus may land on a child: type where the focus really is, if it's in the same app.
            if let processIdentifier = target.processIdentifier, let focused = TypeForMeAccessibility.focusedElement(processIdentifier: processIdentifier) {
                element = focused
            }
        }
        // Re-check right before typing: the field may have turned into a password prompt.
        if IsSecureEventInputEnabled() || TypeForMeAccessibility.stringAttribute(kAXSubroleAttribute, of: element) == TypeForMePolicy.secureTextFieldSubrole {
            return .refused(reason: "that's a password field")
        }
        if isCancelled() { return .cancelled }

        var method = "ax"
        let valueBefore = TypeForMeAccessibility.value(of: element)
        var verification = InsertionVerification.unchanged
        if valueBefore?.isEmpty ?? true,
           AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success {
            verification = InsertionVerification.evaluate(valueBefore: valueBefore, valueAfter: TypeForMeAccessibility.value(of: element), insertedText: text)
        }
        if verification == .unchanged, TypeForMeAccessibility.setSelectedText(text, of: element) {
            verification = InsertionVerification.evaluate(valueBefore: valueBefore, valueAfter: TypeForMeAccessibility.value(of: element), insertedText: text)
        }
        if verification == .unchanged {
            method = "keys"
            guard let chunks = UnicodeTypingChunker.chunks(of: text) else { return .failed(reason: "multi-line text couldn't be typed there") }
            for chunk in chunks {
                if isCancelled() { return .cancelled }
                guard TypeForMeSyntheticEvents.areNoModifiersHeld(CGEventSource.flagsState(.hidSystemState)) else { return .failed(reason: "a modifier key was held down") }
                for event in TypeForMeSyntheticEvents.unicodeEvents(for: chunk) { event.post(tap: .cghidEventTap) }
                try? await Task.sleep(nanoseconds: Self.delayBetweenUnicodeChunks)
            }
            try? await Task.sleep(nanoseconds: Self.delayBetweenUnicodeChunks * 4)
            verification = InsertionVerification.evaluate(valueBefore: valueBefore, valueAfter: TypeForMeAccessibility.value(of: element), insertedText: text)
            if verification == .unchanged { return .failed(reason: "the text didn't land in the field") }
        }
        if pressesReturn {
            if isCancelled() { return .cancelled }
            // Only reached when the tier allowed it: the owner asked ("press enter" / "send it") or said yes.
            postKey(ActionKeyCombo(modifiers: [], key: "return", virtualKeyCode: 36))
        }
        let detail = (verification == .verified ? "typed" : "typed, unverified") + " (\(method))" + (pressesReturn ? " + return" : "")
        return .done(detail: detail)
    }

    // MARK: Keys and scrolling

    private func postKey(_ combo: ActionKeyCombo) {
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        for isKeyDown in [true, false] {
            guard let event = SyntheticEvents.keyEvent(virtualKey: CGKeyCode(combo.virtualKeyCode), keyDown: isKeyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private func scroll(at point: CGPoint, direction: ActionScrollDirection, amount: Int) {
        // Scroll events go to the window under the pointer: move it there first (tagged).
        onSyntheticPointerEvent()
        SyntheticEvents.mouseEvent(.mouseMoved, at: point)?.post(tap: .cghidEventTap)
        let lines = Int32(amount * 3)
        let verticalLines: Int32 = direction == .up ? lines : (direction == .down ? -lines : 0)
        let horizontalLines: Int32 = direction == .left ? lines : (direction == .right ? -lines : 0)
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line, wheelCount: 2,
                                  wheel1: verticalLines, wheel2: horizontalLines, wheel3: 0) else { return }
        SyntheticEvents.stamp(event)
        event.location = point
        event.post(tap: .cghidEventTap)
        onSyntheticPointerEvent()
    }

    // MARK: Page text

    /// The front window's text: its web area / document via AX, else this turn's OCR inside the window.
    private func readPageText(target: ResolvedActionTarget, groundedTurn: GroundedTurn) async -> (String, ActionPageText.Source) {
        var accessibilityText = ""
        var windowFrame: CGRect?
        if let processIdentifier = target.processIdentifier, let window = Self.focusedWindow(processIdentifier: processIdentifier) {
            windowFrame = TypeForMeAccessibility.frameCG(of: window)
            AXUIElementSetMessagingTimeout(window, 0.5)
            let uncheckedWindow = UncheckedAXElement(element: window)
            let fragments = await Task.detached(priority: .userInitiated) { Self.collectTextFragments(from: uncheckedWindow.element) }.value
            accessibilityText = ActionPageText.fromAccessibilityFragments(fragments)
        }
        var ocrText = ""
        if accessibilityText.count < ActionPageText.minimumUsefulAccessibilityCharacters {
            var workingTurn = groundedTurn
            await workingTurn.ensureOCRLines()
            let lines = workingTurn.registry.allOCRLines
                .filter { line in windowFrame.map { $0.intersects(line.frameCG) } ?? true }
                .map { (text: $0.text, frameCG: $0.frameCG) }
            ocrText = ActionPageText.fromOCRLines(lines)
        }
        let best = ActionPageText.best(accessibilityText: accessibilityText, ocrText: ocrText)
        return (best.text, best.source)
    }

    /// Static text in document order (depth first), skipping toolbars and menus; ≤ 6000 nodes, ≤ 1.5 s.
    nonisolated static func collectTextFragments(from root: AXUIElement) -> [String] {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var fragments: [String] = []
        var visitedCount = 0
        // The web area, if there is one, is the article.
        let start = findDescendant(of: root, role: "AXWebArea", deadline: deadline) ?? root
        var stack: [(element: AXUIElement, depth: Int)] = [(start, 0)]
        let skippedRoles: Set<String> = ["AXToolbar", "AXMenuBar", "AXMenu", "AXMenuButton", "AXTabGroup", "AXScrollBar", "AXButton", "AXPopUpButton"]
        while let (element, depth) = stack.popLast() {
            visitedCount += 1
            if visitedCount > 6_000 || ProcessInfo.processInfo.systemUptime > deadline { break }
            let role = stringValue(kAXRoleAttribute, of: element) ?? ""
            if skippedRoles.contains(role) { continue }
            if role == "AXStaticText" || role == "AXTextArea" || role == "AXHeading" {
                if let text = stringValue(kAXValueAttribute, of: element) ?? stringValue(kAXTitleAttribute, of: element), !text.isEmpty {
                    fragments.append(text)
                    if role == "AXStaticText" || role == "AXTextArea" { continue }
                }
            }
            guard depth < 60 else { continue }
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else { continue }
            for child in children.reversed() { stack.append((child, depth + 1)) }
        }
        return fragments
    }

    nonisolated static func findDescendant(of root: AXUIElement, role wantedRole: String, deadline: TimeInterval) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visitedCount = 0
        while !queue.isEmpty {
            let element = queue.removeFirst()
            visitedCount += 1
            if visitedCount > 400 || ProcessInfo.processInfo.systemUptime > deadline { return nil }
            if stringValue(kAXRoleAttribute, of: element) == wantedRole { return element }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success, let children = childrenValue as? [AXUIElement] {
                queue += children
            }
        }
        return nil
    }

    nonisolated static func stringValue(_ attributeName: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Code tasks

    /// A named project goes through NamedProjectRouter (project name → repo, pick card when unsure);
    /// without one, code mode's own "this repo" task.
    private func startCodeTask(project: String?, instructions: String, ownerTranscript: String) -> ActionStepOutcome {
        if let project, !project.isEmpty, project.lowercased() != "this" {
            guard let namedProjectRouter = companionManager.projectBridge.namedProjectRouter else { return .failed(reason: "project lookup isn't available") }
            namedProjectRouter.startActionCodeTask(projectName: project, instructions: instructions, transcript: ownerTranscript)
            return .done(detail: "handed to code mode for \(project)")
        }
        guard ClickySettings.isCodeEnabled else { return .failed(reason: "code mode is off; name the project or turn code mode on") }
        companionManager.codeModeController.start(CodeTask(action: .repoChange, repo: "this", instructions: instructions),
                                                  context: CodeTurnContext(transcript: ownerTranscript))
        return .done(detail: "handed to code mode")
    }
}
