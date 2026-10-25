//
//  DiffParser.swift
//  ClickyCore
//
//  Parses `git diff` / `gh pr diff` unified output into files and hunks, for
//  the review panel and for CodeGuards (which must see every changed path
//  and every added line). Handles renames/copies with similarity, binary
//  files (the "Binary files … differ" line and GIT binary patch), C-quoted
//  paths with octal escapes ("a/sp ace\303\251.txt" → UTF-8), new/deleted
//  files, mode changes and "\ No newline at end of file". Hunk line counts
//  drive the parse, so a removed line reading "--- x" stays a line.
//

import Foundation

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context
        case added
        case removed
    }

    public var kind: Kind
    /// The line without its leading " ", "+" or "-".
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
    /// Followed by "\ No newline at end of file".
    public var hasNoNewlineAtEnd: Bool

    public init(kind: Kind, text: String, oldLineNumber: Int?, newLineNumber: Int?, hasNoNewlineAtEnd: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.hasNoNewlineAtEnd = hasNoNewlineAtEnd
    }
}

public struct DiffHunk: Equatable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Text after the closing "@@" (often the enclosing function).
    public var sectionHeading: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, sectionHeading: String, lines: [DiffLine] = []) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.sectionHeading = sectionHeading
        self.lines = lines
    }
}

public struct DiffFile: Equatable, Sendable {
    /// nil when the file is new (/dev/null).
    public var oldPath: String?
    /// nil when the file was deleted (/dev/null).
    public var newPath: String?
    public var isNewFile = false
    public var isDeletedFile = false
    public var isRename = false
    public var isCopy = false
    /// "similarity index N%", for renames and copies.
    public var similarityPercent: Int?
    public var isBinary = false
    public var oldMode: String?
    public var newMode: String?
    public var hunks: [DiffHunk] = []

    public init(oldPath: String? = nil, newPath: String? = nil) {
        self.oldPath = oldPath
        self.newPath = newPath
    }

    /// The path to show: the new one, or the old one for a deletion.
    public var displayPath: String { newPath ?? oldPath ?? "" }

    /// Every path this file touches (both sides of a rename).
    public var touchedPaths: [String] {
        var paths: [String] = []
        if let oldPath { paths.append(oldPath) }
        if let newPath, newPath != oldPath { paths.append(newPath) }
        return paths
    }

    public var isModeChange: Bool { oldMode != nil && newMode != nil && oldMode != newMode }

    public var addedLines: [DiffLine] { hunks.flatMap { $0.lines.filter { $0.kind == .added } } }
    public var removedLines: [DiffLine] { hunks.flatMap { $0.lines.filter { $0.kind == .removed } } }
}

public enum DiffParser {
    public static func parse(_ diffText: String) -> [DiffFile] {
        var parsedFiles: [DiffFile] = []
        var currentFile: DiffFile?
        var currentHunk: DiffHunk?
        var oldLinesRemaining = 0
        var newLinesRemaining = 0
        var nextOldLineNumber = 0
        var nextNewLineNumber = 0
        var isSkippingBinaryPatch = false
        var sawGitHeaderForCurrentFile = false

        func closeHunk() {
            if let finishedHunk = currentHunk { currentFile?.hunks.append(finishedHunk) }
            currentHunk = nil
            oldLinesRemaining = 0
            newLinesRemaining = 0
        }

        func closeFile() {
            closeHunk()
            if let finishedFile = currentFile { parsedFiles.append(finishedFile) }
            currentFile = nil
            isSkippingBinaryPatch = false
            sawGitHeaderForCurrentFile = false
        }

        var rawLines = diffText.components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }

        for rawLine in rawLines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

            // Inside a hunk the counts decide what a line is.
            if currentHunk != nil {
                if line.hasPrefix("\\") {
                    if var hunk = currentHunk, !hunk.lines.isEmpty {
                        hunk.lines[hunk.lines.count - 1].hasNoNewlineAtEnd = true
                        currentHunk = hunk
                    }
                    continue
                }
                if oldLinesRemaining > 0 || newLinesRemaining > 0 {
                    let marker = line.first
                    let lineBody = line.isEmpty ? "" : String(line.dropFirst())
                    if marker == "+" , newLinesRemaining > 0 {
                        currentHunk?.lines.append(DiffLine(kind: .added, text: lineBody, oldLineNumber: nil, newLineNumber: nextNewLineNumber))
                        nextNewLineNumber += 1
                        newLinesRemaining -= 1
                        continue
                    }
                    if marker == "-", oldLinesRemaining > 0 {
                        currentHunk?.lines.append(DiffLine(kind: .removed, text: lineBody, oldLineNumber: nextOldLineNumber, newLineNumber: nil))
                        nextOldLineNumber += 1
                        oldLinesRemaining -= 1
                        continue
                    }
                    if (marker == " " || line.isEmpty), oldLinesRemaining > 0, newLinesRemaining > 0 {
                        currentHunk?.lines.append(DiffLine(kind: .context, text: lineBody, oldLineNumber: nextOldLineNumber, newLineNumber: nextNewLineNumber))
                        nextOldLineNumber += 1
                        nextNewLineNumber += 1
                        oldLinesRemaining -= 1
                        newLinesRemaining -= 1
                        continue
                    }
                }
                closeHunk()
            }

            if line.hasPrefix("diff --git ") {
                closeFile()
                let headerPaths = parseGitHeaderPaths(String(line.dropFirst("diff --git ".count)))
                currentFile = DiffFile(oldPath: headerPaths?.old, newPath: headerPaths?.new)
                sawGitHeaderForCurrentFile = true
                continue
            }

            if isSkippingBinaryPatch { continue }

            if line.hasPrefix("@@") {
                guard let hunkHeader = parseHunkHeader(line) else { continue }
                if currentFile == nil { currentFile = DiffFile() }
                currentHunk = hunkHeader
                oldLinesRemaining = hunkHeader.oldCount
                newLinesRemaining = hunkHeader.newCount
                nextOldLineNumber = hunkHeader.oldStart
                nextNewLineNumber = hunkHeader.newStart
                continue
            }

            if line.hasPrefix("--- ") {
                // A plain unified diff (no "diff --git") starts a file here.
                if currentFile == nil || !(currentFile?.hunks.isEmpty ?? true) || (!sawGitHeaderForCurrentFile && currentFile?.oldPath != nil) {
                    closeFile()
                    currentFile = DiffFile()
                }
                let oldSide = parseMarkerPath(String(line.dropFirst(4)), prefix: "a/")
                if oldSide == nil { currentFile?.isNewFile = true; currentFile?.oldPath = nil } else { currentFile?.oldPath = oldSide }
                continue
            }
            if line.hasPrefix("+++ ") {
                let newSide = parseMarkerPath(String(line.dropFirst(4)), prefix: "b/")
                if newSide == nil { currentFile?.isDeletedFile = true; currentFile?.newPath = nil } else { currentFile?.newPath = newSide }
                continue
            }

            guard currentFile != nil else { continue }

            if line.hasPrefix("new file mode ") {
                currentFile?.isNewFile = true
                currentFile?.newMode = String(line.dropFirst("new file mode ".count))
                currentFile?.oldPath = nil
            } else if line.hasPrefix("deleted file mode ") {
                currentFile?.isDeletedFile = true
                currentFile?.oldMode = String(line.dropFirst("deleted file mode ".count))
                currentFile?.newPath = nil
            } else if line.hasPrefix("old mode ") {
                currentFile?.oldMode = String(line.dropFirst("old mode ".count))
            } else if line.hasPrefix("new mode ") {
                currentFile?.newMode = String(line.dropFirst("new mode ".count))
            } else if line.hasPrefix("similarity index ") {
                currentFile?.similarityPercent = Int(line.dropFirst("similarity index ".count).trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            } else if line.hasPrefix("rename from ") {
                currentFile?.isRename = true
                currentFile?.oldPath = unquotePathIfNeeded(String(line.dropFirst("rename from ".count)))
            } else if line.hasPrefix("rename to ") {
                currentFile?.isRename = true
                currentFile?.newPath = unquotePathIfNeeded(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("copy from ") {
                currentFile?.isCopy = true
                currentFile?.oldPath = unquotePathIfNeeded(String(line.dropFirst("copy from ".count)))
            } else if line.hasPrefix("copy to ") {
                currentFile?.isCopy = true
                currentFile?.newPath = unquotePathIfNeeded(String(line.dropFirst("copy to ".count)))
            } else if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") {
                currentFile?.isBinary = true
                applyBinaryFilesLinePaths(line, to: &currentFile)
            } else if line == "GIT binary patch" {
                currentFile?.isBinary = true
                isSkippingBinaryPatch = true
            }
        }
        closeFile()
        return parsedFiles
    }

    // MARK: - Headers

    /// "@@ -a,b +c,d @@ heading"; a missing count means 1.
    static func parseHunkHeader(_ line: String) -> DiffHunk? {
        guard line.hasPrefix("@@ -") else { return nil }
        let afterOpening = line.dropFirst(3)
        guard let closingRange = afterOpening.range(of: " @@") else { return nil }
        let rangesText = afterOpening[..<closingRange.lowerBound]
        var heading = String(afterOpening[closingRange.upperBound...])
        if heading.hasPrefix(" ") { heading.removeFirst() }
        let rangeParts = rangesText.split(separator: " ")
        guard rangeParts.count == 2, rangeParts[0].hasPrefix("-"), rangeParts[1].hasPrefix("+"),
              let oldRange = parseRange(rangeParts[0].dropFirst()), let newRange = parseRange(rangeParts[1].dropFirst()) else { return nil }
        return DiffHunk(oldStart: oldRange.start, oldCount: oldRange.count, newStart: newRange.start, newCount: newRange.count, sectionHeading: heading)
    }

    private static func parseRange(_ text: Substring) -> (start: Int, count: Int)? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(parts[0]) else { return nil }
        if parts.count == 1 { return (start, 1) }
        guard parts.count == 2, let count = Int(parts[1]) else { return nil }
        return (start, count)
    }

    /// "a/x b/y", either side possibly C-quoted. Unquoted paths with spaces
    /// are split where both halves name the same path (git's own heuristic).
    static func parseGitHeaderPaths(_ headerText: String) -> (old: String, new: String)? {
        var remainder = Substring(headerText)
        guard let firstToken = takePathToken(&remainder, stopAtSpaceBeforePrefix: "b/") else { return nil }
        if remainder.hasPrefix(" ") { remainder.removeFirst() }
        guard let secondToken = takePathToken(&remainder, stopAtSpaceBeforePrefix: nil) else { return nil }
        return (stripPrefix(firstToken, "a/"), stripPrefix(secondToken, "b/"))
    }

    private static func takePathToken(_ remainder: inout Substring, stopAtSpaceBeforePrefix nextPrefix: String?) -> String? {
        if remainder.hasPrefix("\"") {
            guard let (unquoted, consumedLength) = unquoteCString(remainder) else { return nil }
            remainder = remainder.dropFirst(consumedLength)
            return unquoted
        }
        guard let nextPrefix else {
            let token = String(remainder)
            remainder = ""
            return token
        }
        // Unquoted first path: prefer the split where both sides match.
        let wholeText = String(remainder)
        var candidateSplits: [String.Index] = []
        var searchStart = wholeText.startIndex
        while let separatorRange = wholeText.range(of: " " + nextPrefix, range: searchStart..<wholeText.endIndex) {
            candidateSplits.append(separatorRange.lowerBound)
            searchStart = wholeText.index(after: separatorRange.lowerBound)
        }
        if let quotedStart = wholeText.range(of: " \"") {
            candidateSplits.append(quotedStart.lowerBound)
        }
        guard !candidateSplits.isEmpty else { return nil }
        var chosenSplit = candidateSplits[0]
        for splitIndex in candidateSplits {
            let firstHalf = stripPrefix(String(wholeText[..<splitIndex]), "a/")
            let secondHalf = stripPrefix(String(wholeText[wholeText.index(after: splitIndex)...]), nextPrefix)
            if firstHalf == secondHalf { chosenSplit = splitIndex; break }
        }
        let token = String(wholeText[..<chosenSplit])
        remainder = Substring(wholeText[chosenSplit...])
        return token
    }

    /// The path after "--- " / "+++ ": nil for /dev/null; strips the a/ or
    /// b/ prefix and any tab-separated timestamp.
    static func parseMarkerPath(_ markerText: String, prefix: String) -> String? {
        var pathText = markerText
        if pathText.hasPrefix("\"") {
            guard let (unquoted, _) = unquoteCString(Substring(pathText)) else { return nil }
            pathText = unquoted
        } else if let tabIndex = pathText.firstIndex(of: "\t") {
            pathText = String(pathText[..<tabIndex])
        }
        if pathText == "/dev/null" { return nil }
        return stripPrefix(pathText, prefix)
    }

    private static func applyBinaryFilesLinePaths(_ line: String, to file: inout DiffFile?) {
        let middle = String(line.dropFirst("Binary files ".count).dropLast(" differ".count))
        var remainder = Substring(middle)
        var oldSide: String?
        if remainder.hasPrefix("\"") {
            guard let (unquoted, consumed) = unquoteCString(remainder) else { return }
            oldSide = unquoted
            remainder = remainder.dropFirst(consumed)
            guard remainder.hasPrefix(" and ") else { return }
            remainder = remainder.dropFirst(5)
        } else if let andRange = remainder.range(of: " and ") {
            oldSide = String(remainder[..<andRange.lowerBound])
            remainder = remainder[andRange.upperBound...]
        } else {
            return
        }
        var newSide = String(remainder)
        if remainder.hasPrefix("\""), let (unquoted, _) = unquoteCString(remainder) { newSide = unquoted }
        if file?.oldPath == nil && file?.newPath == nil {
            file?.oldPath = oldSide == "/dev/null" ? nil : oldSide.map { stripPrefix($0, "a/") }
            file?.newPath = newSide == "/dev/null" ? nil : stripPrefix(newSide, "b/")
        }
        if oldSide == "/dev/null" { file?.isNewFile = true; file?.oldPath = nil }
        if newSide == "/dev/null" { file?.isDeletedFile = true; file?.newPath = nil }
    }

    private static func stripPrefix(_ path: String, _ prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    static func unquotePathIfNeeded(_ text: String) -> String {
        guard text.hasPrefix("\""), let (unquoted, _) = unquoteCString(Substring(text)) else { return text }
        return unquoted
    }

    /// Decodes a git C-quoted string at the start of `text` (\" \\ \t \n \r
    /// \a \b \f \v and 3-digit octal bytes, decoded as UTF-8). Returns the
    /// string and how many characters were consumed, including both quotes.
    public static func unquoteCString(_ text: Substring) -> (String, Int)? {
        guard text.first == "\"" else { return nil }
        var decodedBytes: [UInt8] = []
        let characters = Array(text.dropFirst())
        var characterIndex = 0
        var consumedCount = 1
        while characterIndex < characters.count {
            let character = characters[characterIndex]
            if character == "\"" {
                consumedCount += characterIndex + 1
                return (String(decoding: decodedBytes, as: UTF8.self), consumedCount)
            }
            if character == "\\" {
                guard characterIndex + 1 < characters.count else { return nil }
                let escaped = characters[characterIndex + 1]
                switch escaped {
                case "\"": decodedBytes.append(0x22); characterIndex += 2
                case "\\": decodedBytes.append(0x5C); characterIndex += 2
                case "t": decodedBytes.append(0x09); characterIndex += 2
                case "n": decodedBytes.append(0x0A); characterIndex += 2
                case "r": decodedBytes.append(0x0D); characterIndex += 2
                case "a": decodedBytes.append(0x07); characterIndex += 2
                case "b": decodedBytes.append(0x08); characterIndex += 2
                case "f": decodedBytes.append(0x0C); characterIndex += 2
                case "v": decodedBytes.append(0x0B); characterIndex += 2
                case "0"..."7":
                    guard characterIndex + 3 < characters.count else { return nil }
                    let octalText = String(characters[(characterIndex + 1)...(characterIndex + 3)])
                    guard let octalValue = UInt8(octalText, radix: 8) else { return nil }
                    decodedBytes.append(octalValue)
                    characterIndex += 4
                default:
                    decodedBytes.append(contentsOf: Array(String(escaped).utf8))
                    characterIndex += 2
                }
                continue
            }
            decodedBytes.append(contentsOf: Array(String(character).utf8))
            characterIndex += 1
        }
        return nil
    }
}
