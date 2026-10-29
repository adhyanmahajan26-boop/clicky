//
//  WBCodeHighlighter.swift
//  ClickyCore
//
//  Simple, language-agnostic colouring for whiteboard code: keywords,
//  strings, numbers and comments (// and # and --), one line at a time.
//  Good enough for a board; never a real parser. Output is an
//  AttributedString per line (no links, nothing clickable).
//

import SwiftUI

public enum WBCodeTokenKind: Equatable, Sendable {
    case plain, keyword, string, number, comment
}

public struct WBCodeToken: Equatable, Sendable {
    public let text: String
    public let kind: WBCodeTokenKind
}

public enum WBCodeHighlighter {
    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "class", "struct", "enum", "import", "def", "from", "in",
        "const", "function", "new", "true", "false", "null", "nil", "None", "True", "False", "self", "this", "public", "private",
        "static", "async", "await", "try", "catch", "throw", "throws", "switch", "case", "break", "continue", "do", "interface",
        "type", "package", "select", "where", "insert", "update", "delete", "join", "on", "as", "and", "or", "not", "lambda",
        "yield", "extends", "implements", "int", "void", "string", "bool", "guard", "protocol", "elif", "with", "pass",
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "JOIN", "ON", "AS", "AND", "OR", "NOT", "CREATE", "INDEX",
        "TABLE", "ORDER", "BY", "GROUP", "INTO", "VALUES", "git", "export", "default", "fn", "mut", "impl", "pub", "use"
    ]

    /// Comment starts that count for this language ("#" only where it's a comment).
    static func commentMarkers(language: String?) -> [String] {
        switch language?.lowercased() {
        case "python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml", "toml", "r", "perl":
            return ["#"]
        case "sql":
            return ["--"]
        case "html", "xml":
            return ["<!--"]
        default:
            return ["//", "#"].filter { $0 == "//" || language == nil }
        }
    }

    public static func tokens(line: String, language: String?) -> [WBCodeToken] {
        var tokens: [WBCodeToken] = []
        let characters = Array(line)
        let markers = commentMarkers(language: language)
        var index = 0
        var plainRun = ""
        func flushPlain() {
            if !plainRun.isEmpty { tokens.append(WBCodeToken(text: plainRun, kind: .plain)) }
            plainRun = ""
        }
        while index < characters.count {
            let rest = String(characters[index...])
            if let marker = markers.first(where: { rest.hasPrefix($0) }), marker != "#" || index == 0 || characters[index - 1].isWhitespace {
                flushPlain()
                tokens.append(WBCodeToken(text: rest, kind: .comment))
                return tokens
            }
            let character = characters[index]
            if character == "\"" || character == "'" || character == "`" {
                flushPlain()
                var endIndex = index + 1
                while endIndex < characters.count {
                    if characters[endIndex] == "\\" { endIndex += 2; continue }
                    if characters[endIndex] == character { break }
                    endIndex += 1
                }
                let stringEnd = min(endIndex + 1, characters.count)
                tokens.append(WBCodeToken(text: String(characters[index..<stringEnd]), kind: .string))
                index = stringEnd
                continue
            }
            if character.isLetter || character == "_" {
                var endIndex = index
                while endIndex < characters.count, characters[endIndex].isLetter || characters[endIndex].isNumber || characters[endIndex] == "_" { endIndex += 1 }
                let word = String(characters[index..<endIndex])
                if keywords.contains(word) {
                    flushPlain()
                    tokens.append(WBCodeToken(text: word, kind: .keyword))
                } else {
                    plainRun += word
                }
                index = endIndex
                continue
            }
            if character.isNumber, index == 0 || !(characters[index - 1].isLetter || characters[index - 1] == "_") {
                flushPlain()
                var endIndex = index
                while endIndex < characters.count, characters[endIndex].isNumber || characters[endIndex] == "." { endIndex += 1 }
                tokens.append(WBCodeToken(text: String(characters[index..<endIndex]), kind: .number))
                index = endIndex
                continue
            }
            plainRun.append(character)
            index += 1
        }
        flushPlain()
        return tokens
    }

    public static func attributedLine(_ line: String, language: String?, palette: WhiteboardPalette) -> AttributedString {
        var attributedLine = AttributedString()
        for token in tokens(line: line, language: language) {
            var piece = AttributedString(token.text)
            switch token.kind {
            case .plain: piece.foregroundColor = palette.ink
            case .keyword: piece.foregroundColor = palette.codeKeyword
            case .string: piece.foregroundColor = palette.codeString
            case .number: piece.foregroundColor = palette.codeNumber
            case .comment: piece.foregroundColor = palette.codeComment
            }
            attributedLine += piece
        }
        if attributedLine.characters.isEmpty { attributedLine = AttributedString(" ") }
        return attributedLine
    }
}
