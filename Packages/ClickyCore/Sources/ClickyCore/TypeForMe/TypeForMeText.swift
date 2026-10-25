//
//  TypeForMeText.swift
//  ClickyCore
//
//  P6.2 "Type this for me": what may be typed. The <type> body is cleaned
//  (line endings become \n, every other control character except \n and \t
//  is removed), capped at 5000 characters, and for terminals its line
//  breaks are stripped (a newline in a shell would run a command). The
//  chunker cuts single-line text into pieces of at most 20 UTF-16 code
//  units — the most one CGEvent's keyboardSetUnicodeString carries — and
//  never splits a Character (ZWJ emoji, flags, combining marks, CJK).
//

import Foundation

public struct TypeForMeText: Equatable, Sendable {
    public static let maximumCharacterCount = 5000
    public static let maximumPreviewCharacterCount = 300
    /// keyboardSetUnicodeString's limit per event.
    public static let maximumUTF16UnitsPerEvent = 20

    /// The text that will be typed.
    public let text: String
    /// The body was longer than 5000 characters and was cut.
    public let wasTruncated: Bool

    public init(text: String, wasTruncated: Bool) {
        self.text = text
        self.wasTruncated = wasTruncated
    }

    /// Cleans a <type> block body: one leading and trailing line break are
    /// dropped (the block usually sits on its own lines), control characters
    /// other than \n and \t removed, then capped.
    public static func prepare(blockBody: String, stripsNewlines: Bool = false) -> TypeForMeText {
        var cleaned = stripControlCharacters(blockBody)
        while cleaned.first == "\n" { cleaned.removeFirst() }
        while cleaned.last == "\n" { cleaned.removeLast() }
        if stripsNewlines { cleaned = stripNewlines(cleaned) }
        let wasTruncated = cleaned.count > maximumCharacterCount
        if wasTruncated { cleaned = String(cleaned.prefix(maximumCharacterCount)) }
        return TypeForMeText(text: cleaned, wasTruncated: wasTruncated)
    }

    /// \r\n and \r become \n; every other Cc character except \n and \t goes.
    public static func stripControlCharacters(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || !isControlScalar(scalar) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    /// Cc: C0 controls, DEL and C1 controls.
    static func isControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }

    /// For terminals: each run of line breaks becomes one space (so words
    /// on separate lines don't run together), never a Return.
    public static func stripNewlines(_ text: String) -> String {
        var result = ""
        var needsSpaceBeforeNextCharacter = false
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                needsSpaceBeforeNextCharacter = !result.isEmpty
            } else {
                if needsSpaceBeforeNextCharacter, result.last != " ", character != " " { result.append(" ") }
                needsSpaceBeforeNextCharacter = false
                result.append(character)
            }
        }
        return result
    }

    /// The card's preview: at most 300 characters, "…" when cut.
    public var preview: String {
        guard text.count > Self.maximumPreviewCharacterCount else { return text }
        return String(text.prefix(Self.maximumPreviewCharacterCount - 1)) + "…"
    }

    public var isSingleLine: Bool { !text.contains("\n") }

    /// UTF-16 length (what the insertion log records).
    public var utf16Length: Int { text.utf16.count }
}

public enum UnicodeTypingChunker {
    /// Pieces of at most `maximumUnits` UTF-16 code units, each made of
    /// whole Characters. nil when one Character alone is longer than the
    /// limit (it can't be typed without splitting it) or the text has a
    /// line break (unicode typing is single-line only).
    public static func chunks(of text: String, maximumUnits: Int = TypeForMeText.maximumUTF16UnitsPerEvent) -> [String]? {
        guard !text.contains("\n"), !text.contains("\r") else { return nil }
        var chunks: [String] = []
        var currentChunk = ""
        var currentUnits = 0
        for character in text {
            let characterUnits = String(character).utf16.count
            guard characterUnits <= maximumUnits else { return nil }
            if currentUnits + characterUnits > maximumUnits {
                chunks.append(currentChunk)
                currentChunk = ""
                currentUnits = 0
            }
            currentChunk.append(character)
            currentUnits += characterUnits
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk) }
        return chunks
    }
}
