//
//  DictationInserter.swift
//  leanring-buddy
//
//  Puts dictated text into the focused field without taking focus. Accessibility first, which leaves the clipboard
//  alone, and is checked by reading the field back. Then the clipboard and the app's Paste (the clipboard is put back
//  afterwards). Never into a password field or while secure input is on.
//

import AppKit
import Carbon
import ClickyCore

@MainActor
enum DictationInserter {
    enum Target {
        /// Whatever has focus when the words are ready.
        case frontmost
        /// One app's focused field, in the background (tests).
        case process(pid_t)
        /// One field of one app, in the background (tests).
        case element(AXUIElement, pid_t)
    }

    struct Outcome {
        var method: String
        var didInsert: Bool
        var message: String?
        /// The field it went into, when known, for a late clean-up.
        var element: AXUIElement?
    }

    /// A slow app reads the clipboard late, so it stays ours a little longer than a typed card's paste.
    private static let restoreDelay: TimeInterval = 0.8
    private static let modifierReleaseTimeout: TimeInterval = 1.0

    static func insert(_ text: String, into target: Target) async -> Outcome {
        let pid: pid_t
        let element: AXUIElement?
        switch target {
        case .frontmost:
            guard let app = NSWorkspace.shared.frontmostApplication else { return Outcome(method: "none", didInsert: false, message: "Nothing to type into") }
            pid = app.processIdentifier
            element = pid == getpid() ? nil : TypeForMeAccessibility.focusedElement(processIdentifier: pid)
        case .process(let processIdentifier):
            pid = processIdentifier
            element = TypeForMeAccessibility.focusedElement(processIdentifier: processIdentifier)
        case .element(let field, let processIdentifier):
            pid = processIdentifier
            element = field
        }
        if IsSecureEventInputEnabled() { return Outcome(method: "none", didInsert: false, message: "Secure input is on, so nothing was typed") }
        if let element, TypeForMeAccessibility.stringAttribute(kAXSubroleAttribute, of: element) == TypeForMePolicy.secureTextFieldSubrole {
            return Outcome(method: "none", didInsert: false, message: "That's a password field, nothing typed")
        }
        // Theo's own fields: straight in. An Accessibility call to ourselves would wait on our own main thread.
        if pid == getpid() {
            if let field = NSApp.keyWindow?.firstResponder as? NSTextInputClient {
                field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                return Outcome(method: "own", didInsert: true)
            }
            return Outcome(method: "none", didInsert: false, message: "No text field has focus")
        }
        if let element {
            let before = TypeForMeAccessibility.value(of: element)
            let didSet = TypeForMeAccessibility.setSelectedText(separated(text, in: element, value: before), of: element)
            let after = TypeForMeAccessibility.value(of: element)
            switch InsertionVerification.evaluate(valueBefore: before, valueAfter: after, insertedText: text) {
            case .verified:
                return Outcome(method: "ax", didInsert: true, element: element)
            case .unverifiable:
                // It changed, but not to the text (an app correcting as it goes). With no value to read, Accessibility proves
                // nothing (Chromium says yes and does nothing), so the clipboard goes next.
                if didSet && after != nil { return Outcome(method: "ax", didInsert: true, element: element) }
            case .unchanged:
                break
            }
        }
        guard await modifiersReleased() else { return Outcome(method: "paste", didInsert: false, message: "A key was still held, nothing typed") }
        let before = element.flatMap(TypeForMeAccessibility.value(of:))
        guard PasteInsertion.paste(element.map { separated(text, in: $0, value: before) } ?? text, processIdentifier: pid, restoreDelay: restoreDelay) else {
            return Outcome(method: "paste", didInsert: false, message: "Couldn't paste there")
        }
        return Outcome(method: "paste", didInsert: true)
    }

    /// A space first when the caret sits right after a word, so a second sentence doesn't run into the first.
    private static func separated(_ text: String, in element: AXUIElement, value: String?) -> String {
        guard let value, let selection = selectedRange(of: element), selection.location > 0, selection.location <= (value as NSString).length else { return text }
        let previous = (value as NSString).character(at: selection.location - 1)
        guard let scalar = Unicode.Scalar(previous), !CharacterSet.whitespacesAndNewlines.contains(scalar), !"([{\"'“‘".unicodeScalars.contains(scalar) else { return text }
        return " " + text
    }

    /// Swaps the text just typed for its tidied version, if it's still there at the caret. False leaves the field alone.
    static func replace(_ old: String, with new: String, target element: AXUIElement?) -> Bool {
        guard let element, old != new, let value = TypeForMeAccessibility.value(of: element),
              let selection = selectedRange(of: element), selection.length == 0 else { return false }
        let characters = value as NSString
        let oldLength = (old as NSString).length
        let start = selection.location - oldLength
        guard start >= 0, selection.location <= characters.length,
              characters.substring(with: NSRange(location: start, length: oldLength)) == old else { return false }
        var range = CFRange(location: start, length: oldLength)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else { return false }
        return TypeForMeAccessibility.setSelectedText(new, of: element)
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func modifiersReleased() async -> Bool {
        let giveUp = ProcessInfo.processInfo.systemUptime + modifierReleaseTimeout
        while !TypeForMeSyntheticEvents.areNoModifiersHeld(CGEventSource.flagsState(.hidSystemState)) {
            if ProcessInfo.processInfo.systemUptime >= giveUp { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}
