//
//  WBParser.swift
//  ClickyCore
//
//  The whole parsing pipeline in one streaming object: WBScanner cuts
//  values, WBRepair fixes each, WBNormalizer builds the board. The app feeds
//  it the <whiteboard> block body (from ResponseRouter) as it streams;
//  cwb-check and tests use parse(_:) on whole text. Also finds the
//  <whiteboard> block inside a raw model answer.
//

import Foundation

public struct WBStreamParser: Sendable {
    private var scanner = WBScanner()
    private var normalizer: WBNormalizer

    public init(isValidSymbol: @escaping @Sendable (String) -> Bool = WBNormalizer.defaultSymbolCheck) {
        normalizer = WBNormalizer(isValidSymbol: isValidSymbol)
    }

    /// Returns the number of values that closed in this chunk.
    @discardableResult
    public mutating func feed(_ chunk: String) -> Int {
        let scannedValues = scanner.feed(chunk)
        for scannedValue in scannedValues {
            normalizer.ingest(WBRepair.repair(scannedValue.text), wasClosedByScanner: scannedValue.wasClosedByScanner)
        }
        return scannedValues.count
    }

    /// The board so far (see WBNormalizer.provisionalBoard).
    public var provisionalBoard: WBBoard { normalizer.provisionalBoard }

    public mutating func finish() -> WBParseOutcome {
        for scannedValue in scanner.finish() {
            normalizer.ingest(WBRepair.repair(scannedValue.text), wasClosedByScanner: scannedValue.wasClosedByScanner)
        }
        return normalizer.finish()
    }

    public static func parse(_ text: String, isValidSymbol: @escaping @Sendable (String) -> Bool = WBNormalizer.defaultSymbolCheck) -> WBParseOutcome {
        var parser = WBStreamParser(isValidSymbol: isValidSymbol)
        parser.feed(text)
        return parser.finish()
    }
}

public enum WBBlockExtractor {
    /// The bodies of every <whiteboard>…</whiteboard> block, joined by
    /// newlines (an unclosed last block runs to the end); the whole text when
    /// there is no open tag. Tags match in any case.
    public static func whiteboardBody(in answerText: String) -> String {
        let openTag = "<whiteboard>", closeTag = "</whiteboard>"
        var bodies: [String] = []
        var searchStart = answerText.startIndex
        while let openRange = answerText.range(of: openTag, options: .caseInsensitive, range: searchStart..<answerText.endIndex) {
            if let closeRange = answerText.range(of: closeTag, options: .caseInsensitive, range: openRange.upperBound..<answerText.endIndex) {
                bodies.append(String(answerText[openRange.upperBound..<closeRange.lowerBound]))
                searchStart = closeRange.upperBound
            } else {
                bodies.append(String(answerText[openRange.upperBound...]))
                searchStart = answerText.endIndex
            }
        }
        return bodies.isEmpty ? answerText : bodies.joined(separator: "\n")
    }

    public static func containsWhiteboardBlock(_ answerText: String) -> Bool {
        answerText.range(of: "<whiteboard>", options: .caseInsensitive) != nil
    }
}
