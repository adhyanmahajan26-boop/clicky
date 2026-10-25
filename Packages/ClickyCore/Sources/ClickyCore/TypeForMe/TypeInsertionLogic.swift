//
//  TypeInsertionLogic.swift
//  ClickyCore
//
//  The pure parts of how a confirmed <type> text is put into the field:
//   - InsertionVerification: after a method ran, does the field's value
//     prove it worked, prove it didn't (readable and unchanged → try the
//     next method), or leave it unknown (stop: never risk typing twice)?
//   - PasteMenuFinder: the target app's own Paste menu item — the one
//     whose shortcut is plain ⌘V (AXMenuItemCmdChar "V", modifiers 0), not
//     ⌥⇧⌘V "Paste and Match Style" or ⇧⌘V.
//   - PasteboardRestorePolicy: the user's clipboard is put back after
//     350 ms only if nobody wrote to it since Clicky did.
//   - TypeInsertionLog: the last 20 insertions (app, field role, length,
//     method, result) — never the text itself.
//

import Foundation

public enum TypeInsertionMethod: String, Equatable, Sendable, CaseIterable {
    case accessibilitySelectedText = "ax"
    case paste
    case unicodeTyping = "unicode"
}

public enum InsertionVerification: Equatable, Sendable {
    /// The value now contains the text.
    case verified
    /// The value is readable and exactly as before: nothing happened, try the next method.
    case unchanged
    /// The value can't be read (or changed without the text): stop, say "couldn't verify".
    case unverifiable

    /// AX values may use \r for line breaks: compare with both sides normalized.
    public static func evaluate(valueBefore: String?, valueAfter: String?, insertedText: String) -> InsertionVerification {
        guard let valueAfter else { return .unverifiable }
        let normalizedAfter = normalizeLineBreaks(valueAfter)
        if let valueBefore, normalizeLineBreaks(valueBefore) == normalizedAfter { return .unchanged }
        if insertedText.isEmpty || normalizedAfter.contains(normalizeLineBreaks(insertedText)) { return .verified }
        return .unverifiable
    }

    static func normalizeLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

/// One menu item as read from the Accessibility API.
public struct MenuItemDescriptor: Equatable, Sendable {
    public var title: String
    /// AXMenuItemCmdChar ("V"), nil when the item has no shortcut.
    public var commandCharacter: String?
    /// AXMenuItemCmdModifiers: 0 = ⌘ only; 1 ⇧, 2 ⌥, 4 ⌃, 8 no ⌘ (bit flags).
    public var commandModifiers: Int?
    public var isEnabled: Bool
    /// Index path in the menu bar (menu bar item, then item), for the app to press it.
    public var path: [Int]

    public init(title: String, commandCharacter: String?, commandModifiers: Int?, isEnabled: Bool, path: [Int]) {
        self.title = title
        self.commandCharacter = commandCharacter
        self.commandModifiers = commandModifiers
        self.isEnabled = isEnabled
        self.path = path
    }
}

public enum PasteMenuFinder {
    /// The first enabled item whose shortcut is exactly ⌘V (an unreadable
    /// modifier mask doesn't count: it could be ⌥⇧⌘V).
    public static func plainPasteItem(in items: [MenuItemDescriptor]) -> MenuItemDescriptor? {
        items.first { item in
            item.isEnabled && item.commandCharacter == "V" && item.commandModifiers == 0
        }
    }
}

public enum PasteboardRestorePolicy {
    public static let restoreDelay: TimeInterval = 0.35
    /// The UTI clipboard managers skip (nspasteboard.org).
    public static let transientTypeIdentifier = "org.nspasteboard.TransientType"

    /// Restore only when the pasteboard's changeCount is still the one our write produced.
    public static func shouldRestore(changeCountAfterOurWrite: Int, currentChangeCount: Int) -> Bool {
        changeCountAfterOurWrite == currentChangeCount
    }
}

public enum TypeInsertionResult: String, Equatable, Sendable {
    case inserted
    case insertedUnverified
    case focusMoved
    case modifiersHeld
    case interruptedByInput
    case refused
    case failed
}

public struct TypeInsertionLogEntry: Equatable, Sendable {
    public var date: Date
    public var applicationName: String
    public var fieldRole: String
    public var textLength: Int
    public var method: TypeInsertionMethod?
    public var result: TypeInsertionResult

    public init(date: Date, applicationName: String, fieldRole: String, textLength: Int, method: TypeInsertionMethod?, result: TypeInsertionResult) {
        self.date = date
        self.applicationName = applicationName
        self.fieldRole = fieldRole
        self.textLength = textLength
        self.method = method
        self.result = result
    }

    /// One log line, no text content.
    public var summaryLine: String {
        "\(applicationName) \(fieldRole) len=\(textLength) method=\(method?.rawValue ?? "none") result=\(result.rawValue)"
    }
}

/// The last 20 insertions, oldest first.
public struct TypeInsertionLog: Sendable {
    public static let capacity = 20
    public private(set) var entries: [TypeInsertionLogEntry] = []

    public init() {}

    public mutating func append(_ entry: TypeInsertionLogEntry) {
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}
