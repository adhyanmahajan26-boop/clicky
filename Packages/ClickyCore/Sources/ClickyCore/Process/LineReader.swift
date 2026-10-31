//
//  LineReader.swift
//  ClickyCore
//
//  Splits a byte stream into lines on 0x0A only. Foundation's line readers
//  also break on U+2028 / U+2029 and CR, which would cut a stream-json event
//  in half whenever the model writes a line separator inside a string.
//  Partial lines are kept until their newline arrives; a line longer than
//  5 MB is dropped (counted) instead of growing without bound.
//

import Foundation

public struct LineReader: Sendable {
    public static let maximumLineBytes = 5 * 1024 * 1024

    private var pendingBytes = Data()
    private var isDiscardingOversizedLine = false
    public private(set) var droppedOversizedLineCount = 0

    public init() {}

    /// Adds bytes; returns every line they completed (without the 0x0A).
    public mutating func append(_ bytes: Data) -> [Data] {
        var completedLines: [Data] = []
        var searchStart = bytes.startIndex
        while let newlineIndex = bytes[searchStart...].firstIndex(of: 0x0A) {
            let linePart = bytes[searchStart..<newlineIndex]
            if isDiscardingOversizedLine {
                isDiscardingOversizedLine = false
            } else if pendingBytes.count + linePart.count > Self.maximumLineBytes {
                droppedOversizedLineCount += 1
            } else {
                pendingBytes.append(linePart)
                completedLines.append(pendingBytes)
            }
            pendingBytes = Data()
            searchStart = bytes.index(after: newlineIndex)
        }
        let remainder = bytes[searchStart...]
        if !isDiscardingOversizedLine {
            if pendingBytes.count + remainder.count > Self.maximumLineBytes {
                droppedOversizedLineCount += 1
                pendingBytes = Data()
                isDiscardingOversizedLine = true
            } else {
                pendingBytes.append(remainder)
            }
        }
        return completedLines
    }

    /// End of stream: the last line if it had no trailing newline.
    public mutating func finish() -> Data? {
        defer {
            pendingBytes = Data()
            isDiscardingOversizedLine = false
        }
        return pendingBytes.isEmpty || isDiscardingOversizedLine ? nil : pendingBytes
    }
}
