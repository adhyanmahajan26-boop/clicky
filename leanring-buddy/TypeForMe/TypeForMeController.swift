//
//  TypeForMeController.swift
//  leanring-buddy
//
//  P6.2 "Type this for me". A <type> block from Claude opens a card near
//  the caret of the field that had focus when it arrived. The card always
//  offers Copy; it offers Type only when v2.typeForMe.enabled is on and no
//  refusal rule applies (secure input, secure field, Clicky itself, blocked
//  app, nothing focused — TypeForMePolicy).
//
//  Confirm: only a real (untagged) Return keyDown or mouse press on Type,
//  completed by its keyUp/mouseUp, after the card's first 0.5 s, not
//  auto-repeat (TypeConfirmGate). Terminals need a second confirm and get
//  no line breaks. The card expires after 30 s, when another app comes
//  forward or when the card loses key status. One confirm types once.
//
//  Insertion: wait until ⌃⌥⌘⇧ are released (2 s, else abort), recheck the
//  frontmost pid and that the focused element is still the target (else
//  "focus moved, nothing typed"), then (a) set kAXSelectedText and verify
//  via the value, (b) paste through the app's plain ⌘V menu item (or a
//  tagged ⌘V) with the clipboard saved and restored, (c) unicode-type
//  single-line text in ≤ 20-unit chunks. The next method runs only when the
//  value is readable and unchanged. Any physical input during insertion
//  aborts. Return/Enter is never sent. The last 20 insertions are logged
//  without their text.
//

import AppKit
import ApplicationServices
import ClickyCore
import Carbon.HIToolbox

@MainActor
final class TypeForMeController {
    private static let modifierReleaseTimeout: TimeInterval = 2
    private static let focusPollInterval: TimeInterval = 0.25
    private static let settleAfterHidingCard: UInt64 = 150_000_000
    private static let pasteVerificationDelay: UInt64 = 300_000_000
    private static let delayBetweenUnicodeChunks: UInt64 = 12_000_000
    private static let escapeDismissalGrace: TimeInterval = 0.5

    /// Everything captured when the card opened.
    private struct Target {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let applicationName: String
        let focusedElement: AXUIElement?
        let fieldRole: String
    }

    private let speak: (String) -> Void
    private let panelController = TypeCardPanelController()
    private var cardState: TypeCardState?
    private var target: Target?
    private var preparedText: TypeForMeText?
    private var gate: TypeConfirmGate?
    private var focusPollTimer: Timer?
    private var isInserting = false
    private var isInsertionInterrupted = false
    private var interruptionMonitors: [Any] = []
    private var lastEscapeDismissalUptime: TimeInterval = -1
    private(set) var insertionLog = TypeInsertionLog()

    init(speak: @escaping (String) -> Void) {
        self.speak = speak
        panelController.onReturnKeyEvent = { [weak self] event in self?.handleConfirmEvent(event, isOnTypeButton: false) }
        panelController.onEscapeKey = { [weak self] in self?.cancelCard(viaEscape: true) }
        panelController.onResignKey = { [weak self] in self?.invalidateForFocusChange(reason: "The card lost focus — ask again to type. You can still copy.") }
    }

    var isCardVisible: Bool { panelController.isVisible }

    // MARK: - Opening the card

    /// A <type> block arrived (routed always: with the feature off the card is Copy-only).
    func present(blockBody: String) {
        guard !isInserting else {
            print("⌨️ <type> block ignored: an insertion is running")
            return
        }
        closeCard()
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return }
        let processIdentifier = frontmostApplication.processIdentifier
        let bundleIdentifier = frontmostApplication.bundleIdentifier
        let focusedElement = TypeForMeAccessibility.focusedElement(processIdentifier: processIdentifier)
        let role = focusedElement.flatMap { TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: $0) }
        let subrole = focusedElement.flatMap { TypeForMeAccessibility.stringAttribute(kAXSubroleAttribute, of: $0) }
        let isTerminal = TypeForMePolicy.isTerminal(bundleIdentifier: bundleIdentifier)
        let text = TypeForMeText.prepare(blockBody: blockBody, stripsNewlines: isTerminal)
        let refusal = TypeForMePolicy.refusal(for: currentFacts(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier, focusedElement: focusedElement,
                                                                role: role, subrole: subrole),
                                              ownBundleIdentifier: Bundle.main.bundleIdentifier, ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                                              blockedBundleIdentifiers: ClickySettings.typeForMeBlockedBundleIDs)
        let applicationName = frontmostApplication.localizedName ?? bundleIdentifier ?? "this app"
        let newTarget = Target(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier, applicationName: applicationName,
                               focusedElement: focusedElement, fieldRole: role ?? "unknown")
        // The card itself never shows a secure field's surroundings, only the text Claude wrote.
        let fieldDescription = focusedElement.map(TypeForMeAccessibility.fieldDescription(of:)) ?? "no focused field"
        var countDescription = "\(text.text.count) characters"
        if text.wasTruncated { countDescription += " (cut to \(TypeForMeText.maximumCharacterCount))" }
        let state = TypeCardState(applicationName: applicationName, applicationIcon: frontmostApplication.icon, fieldDescription: fieldDescription,
                                  preview: text.preview, characterCountDescription: countDescription,
                                  insertionMethodDescription: TypeForMePolicy.insertionMethodDescription(isTerminal: isTerminal, isSingleLine: text.isSingleLine),
                                  refusalExplanation: text.text.isEmpty ? "There's nothing to type." : refusal?.cardExplanation)
        state.onTypeButtonMouseEvent = { [weak self] event, isOnTypeButton in self?.handleConfirmEvent(event, isOnTypeButton: isOnTypeButton) }
        state.onCopy = { [weak self] in self?.copyToClipboard() }
        state.onCancel = { [weak self] in self?.cancelCard(viaEscape: false) }

        target = newTarget
        preparedText = text
        cardState = state
        let caretRectCG = focusedElement.flatMap { TypeForMeAccessibility.caretRectCG(of: $0) ?? TypeForMeAccessibility.frameCG(of: $0) }
        let shownAt = panelController.show(state: state, caretRectCG: caretRectCG)
        gate = TypeConfirmGate(shownAt: shownAt, isTypingAllowed: state.offersTyping,
                               requiredConfirmCount: TypeForMePolicy.requiredConfirmCount(bundleIdentifier: bundleIdentifier))
        startFocusPolling()
        print("⌨️ Type card for \(applicationName) (\(role ?? "no field")), \(text.utf16Length) units, typing \(state.offersTyping ? "offered" : "refused: \(refusal.map { "\($0)" } ?? "empty")")")
    }

    private func currentFacts(processIdentifier: pid_t, bundleIdentifier: String?, focusedElement: AXUIElement?, role: String?, subrole: String?) -> TypeForMeTargetFacts {
        TypeForMeTargetFacts(isFeatureEnabled: ClickySettings.isTypeForMeEnabled, isSecureEventInputEnabled: IsSecureEventInputEnabled(),
                             bundleIdentifier: bundleIdentifier, processIdentifier: processIdentifier, hasFocusedElement: focusedElement != nil,
                             focusedElementRole: role, focusedElementSubrole: subrole)
    }

    // MARK: - Esc, Copy, Cancel

    /// CompanionManager.escapeKeyConsumers: the card takes Esc first (also
    /// right after the panel itself handled the same press).
    func handleEscapeKey() -> Bool {
        if isCardVisible {
            cancelCard(viaEscape: true)
            return true
        }
        return ProcessInfo.processInfo.systemUptime - lastEscapeDismissalUptime < Self.escapeDismissalGrace
    }

    private func cancelCard(viaEscape: Bool) {
        guard isCardVisible else { return }
        if viaEscape { lastEscapeDismissalUptime = ProcessInfo.processInfo.systemUptime }
        closeCard()
    }

    private func copyToClipboard() {
        guard let text = preparedText?.text, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        cardState?.statusLine = "Copied."
        cardState?.isTypeButtonEnabled = false
        gate?.invalidateForFocusChange()
        let copiedCardState = cardState
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            // Only this card: a newer <type> card may have replaced it meanwhile.
            guard let self, let copiedCardState, self.cardState === copiedCardState else { return }
            self.closeCard()
        }
    }

    private func closeCard() {
        focusPollTimer?.invalidate()
        focusPollTimer = nil
        panelController.hide()
        cardState = nil
        gate = nil
        if !isInserting {
            target = nil
            preparedText = nil
        }
    }

    // MARK: - Expiry

    private func startFocusPolling() {
        focusPollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.focusPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFocusAndExpiry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusPollTimer = timer
    }

    private func pollFocusAndExpiry() {
        guard let gate, let target, let cardState, cardState.offersTyping, cardState.isTypeButtonEnabled else { return }
        if gate.isExpired(at: ProcessInfo.processInfo.systemUptime) {
            invalidateForFocusChange(reason: "Expired after 30 seconds. Ask again to type. You can still copy.")
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            invalidateForFocusChange(reason: "Another app came forward. Ask again to type. You can still copy.")
            return
        }
        // A different element took focus inside the app (nil can be transient while the card is key).
        if let targetElement = target.focusedElement,
           let currentElement = TypeForMeAccessibility.focusedElement(processIdentifier: target.processIdentifier),
           !CFEqual(currentElement, targetElement) {
            invalidateForFocusChange(reason: "Focus moved. Ask again to type. You can still copy.")
        }
    }

    private func invalidateForFocusChange(reason: String) {
        guard cardState != nil, !isInserting else { return }
        gate?.invalidateForFocusChange()
        if cardState?.offersTyping == true {
            cardState?.isTypeButtonEnabled = false
            cardState?.statusLine = reason
        }
    }

    // MARK: - Confirm

    private func handleConfirmEvent(_ event: NSEvent, isOnTypeButton: Bool) {
        guard var currentGate = gate, let input = TypeConfirmEventMapping.confirmInput(from: event, isOnTypeButton: isOnTypeButton) else { return }
        let decision = currentGate.handle(input)
        gate = currentGate
        switch decision {
        case .confirmed:
            beginInsertion()
        case .needsAnotherConfirm:
            cardState?.statusLine = "This is a terminal: press Return (or click Type) once more to type it."
        case .pressStarted:
            break
        case .rejected(let rejection):
            if rejection == .expired { invalidateForFocusChange(reason: "Expired. Ask again to type. You can still copy.") }
        }
    }

    // MARK: - Insertion

    private func beginInsertion() {
        guard let target, let preparedText, let targetElement = target.focusedElement else { return }
        isInserting = true
        closeCard()
        Task { [weak self] in
            guard let self else { return }
            let (method, result) = await self.insert(preparedText.text, into: targetElement, target: target)
            self.finishInsertion(target: target, textLength: preparedText.utf16Length, method: method, result: result)
        }
    }

    private func finishInsertion(target: Target, textLength: Int, method: TypeInsertionMethod?, result: TypeInsertionResult) {
        stopInterruptionMonitors()
        isInserting = false
        self.target = nil
        preparedText = nil
        let entry = TypeInsertionLogEntry(date: Date(), applicationName: target.applicationName, fieldRole: target.fieldRole, textLength: textLength,
                                          method: method, result: result)
        insertionLog.append(entry)
        print("⌨️ Type for me: \(entry.summaryLine)")
        switch result {
        case .inserted: break
        case .insertedUnverified: speak("inserted, but i couldn't verify it landed.")
        case .focusMoved: speak("focus moved, nothing typed.")
        case .modifiersHeld: speak("a modifier key was still held down, so nothing was typed.")
        case .interruptedByInput: speak("you pressed something while i was typing, so i stopped.")
        case .refused: speak("that field is protected now, nothing typed.")
        case .failed: speak("i couldn't type into that field, nothing typed.")
        }
    }

    /// Runs the methods in order; returns the last method tried and the outcome.
    private func insert(_ text: String, into targetElement: AXUIElement, target: Target) async -> (TypeInsertionMethod?, TypeInsertionResult) {
        try? await Task.sleep(nanoseconds: Self.settleAfterHidingCard)
        guard await waitUntilModifiersReleased() else { return (nil, .modifiersHeld) }
        guard isFocusStillOnTarget(targetElement, target: target) else { return (nil, .focusMoved) }
        if IsSecureEventInputEnabled() || TypeForMeAccessibility.stringAttribute(kAXSubroleAttribute, of: targetElement) == TypeForMePolicy.secureTextFieldSubrole {
            return (nil, .refused)
        }
        startInterruptionMonitors()

        // (a) kAXSelectedText.
        let valueBefore = TypeForMeAccessibility.value(of: targetElement)
        let didSetSelectedText = TypeForMeAccessibility.setSelectedText(text, of: targetElement)
        let valueAfterSelectedText = TypeForMeAccessibility.value(of: targetElement)
        switch InsertionVerification.evaluate(valueBefore: valueBefore, valueAfter: valueAfterSelectedText, insertedText: text) {
        case .verified: return (.accessibilitySelectedText, .inserted)
        case .unverifiable: return (.accessibilitySelectedText, didSetSelectedText ? .insertedUnverified : .failed)
        case .unchanged: break
        }
        if isInsertionInterrupted { return (.accessibilitySelectedText, .interruptedByInput) }

        // (b) paste.
        guard isFocusStillOnTarget(targetElement, target: target) else { return (.accessibilitySelectedText, .focusMoved) }
        let didPaste = paste(text, processIdentifier: target.processIdentifier)
        try? await Task.sleep(nanoseconds: Self.pasteVerificationDelay)
        if isInsertionInterrupted { return (.paste, .interruptedByInput) }
        if didPaste {
            switch InsertionVerification.evaluate(valueBefore: valueBefore, valueAfter: TypeForMeAccessibility.value(of: targetElement), insertedText: text) {
            case .verified: return (.paste, .inserted)
            case .unverifiable: return (.paste, .insertedUnverified)
            case .unchanged: break
            }
        }

        // (c) unicode typing, single-line only.
        guard let chunks = UnicodeTypingChunker.chunks(of: text) else { return (.paste, .failed) }
        for chunk in chunks {
            if isInsertionInterrupted { return (.unicodeTyping, .interruptedByInput) }
            guard isFocusStillOnTarget(targetElement, target: target) else { return (.unicodeTyping, .focusMoved) }
            guard TypeForMeSyntheticEvents.areNoModifiersHeld(CGEventSource.flagsState(.hidSystemState)) else { return (.unicodeTyping, .modifiersHeld) }
            for event in TypeForMeSyntheticEvents.unicodeEvents(for: chunk) { event.post(tap: .cghidEventTap) }
            try? await Task.sleep(nanoseconds: Self.delayBetweenUnicodeChunks)
        }
        try? await Task.sleep(nanoseconds: Self.delayBetweenUnicodeChunks * 4)
        switch InsertionVerification.evaluate(valueBefore: valueBefore, valueAfter: TypeForMeAccessibility.value(of: targetElement), insertedText: text) {
        case .verified: return (.unicodeTyping, .inserted)
        case .unverifiable: return (.unicodeTyping, .insertedUnverified)
        case .unchanged: return (.unicodeTyping, .failed)
        }
    }

    /// Frontmost pid and focused element still the ones the card was opened for.
    private func isFocusStillOnTarget(_ targetElement: AXUIElement, target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let currentElement = TypeForMeAccessibility.focusedElement(processIdentifier: target.processIdentifier) else { return false }
        return CFEqual(currentElement, targetElement)
    }

    private func waitUntilModifiersReleased() async -> Bool {
        let giveUpUptime = ProcessInfo.processInfo.systemUptime + Self.modifierReleaseTimeout
        while !TypeForMeSyntheticEvents.areNoModifiersHeld(CGEventSource.flagsState(.hidSystemState)) {
            if ProcessInfo.processInfo.systemUptime >= giveUpUptime { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    // MARK: - Paste

    /// Saves the clipboard, writes the text (marked transient), presses the
    /// app's plain ⌘V Paste item (else posts a tagged ⌘V), and restores the
    /// clipboard 350 ms later if nothing else wrote to it meanwhile.
    private func paste(_ text: String, processIdentifier: pid_t) -> Bool {
        let pasteboard = NSPasteboard.general
        let savedItems = Self.copyItems(of: pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardRestorePolicy.transientTypeIdentifier))
        pasteboard.writeObjects([item])
        let changeCountAfterOurWrite = pasteboard.changeCount

        let menu = TypeForMeAccessibility.menuItems(processIdentifier: processIdentifier)
        var didTrigger = false
        if let pasteItem = PasteMenuFinder.plainPasteItem(in: menu.descriptors), let pasteElement = menu.elementsByPath[pasteItem.path] {
            didTrigger = TypeForMeAccessibility.press(pasteElement)
        }
        if !didTrigger, TypeForMeSyntheticEvents.areNoModifiersHeld(CGEventSource.flagsState(.hidSystemState)) {
            let commandVEvents = TypeForMeSyntheticEvents.commandVEvents()
            for event in commandVEvents { event.post(tap: .cghidEventTap) }
            didTrigger = commandVEvents.count == 2
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + PasteboardRestorePolicy.restoreDelay) {
            guard PasteboardRestorePolicy.shouldRestore(changeCountAfterOurWrite: changeCountAfterOurWrite, currentChangeCount: pasteboard.changeCount) else {
                print("⌨️ Clipboard changed since the paste; not restoring it")
                return
            }
            pasteboard.clearContents()
            if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
        }
        return didTrigger
    }

    /// Deep copies of every item and type on the pasteboard.
    private static func copyItems(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { originalItem in
            let copiedItem = NSPasteboardItem()
            for type in originalItem.types {
                if let data = originalItem.data(forType: type) { copiedItem.setData(data, forType: type) }
            }
            return copiedItem
        }
    }

    // MARK: - Interruption

    private func startInterruptionMonitors() {
        isInsertionInterrupted = false
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let isInterruption = TypeConfirmEventMapping.isPhysicalInterruption(event)
            MainActor.assumeIsolated { if isInterruption { self?.isInsertionInterrupted = true } }
        }) {
            interruptionMonitors.append(globalMonitor)
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if TypeConfirmEventMapping.isPhysicalInterruption(event) { self?.isInsertionInterrupted = true }
            return event
        }) {
            interruptionMonitors.append(localMonitor)
        }
    }

    private func stopInterruptionMonitors() {
        interruptionMonitors.forEach(NSEvent.removeMonitor)
        interruptionMonitors = []
    }
}
