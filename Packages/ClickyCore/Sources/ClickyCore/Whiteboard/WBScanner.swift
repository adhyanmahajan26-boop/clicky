//
//  WBScanner.swift
//  ClickyCore
//
//  Cuts the streamed whiteboard body into top-level JSON values (objects or
//  arrays) the moment each one closes, so elements can be parsed and drawn
//  while the model is still writing. Tracks bracket depth and "…" strings
//  (with \ escapes); text between values is ignored. One model slip is
//  caught early: a "{" where an object expects a key (a line that never got
//  its closing "}") ends the open value there, closed per WBRepair.balance,
//  instead of swallowing the rest of the board. finish() emits whatever is
//  still open, balanced the same way.
//
//  Works on unicode scalars with all state carried between calls, so
//  splitting the input at any character gives identical output.
//

import Foundation

public struct WBScannedValue: Equatable, Sendable {
    public var text: String
    /// True when the value never closed and was closed by WBRepair.balance.
    public var wasClosedByScanner: Bool

    public init(text: String, wasClosedByScanner: Bool = false) {
        self.text = text
        self.wasClosedByScanner = wasClosedByScanner
    }
}

public struct WBScanner: Sendable {
    private var currentValueText = String.UnicodeScalarView()
    private var openBracketStack: [Unicode.Scalar] = []
    private var isInsideString = false
    private var isAfterBackslash = false
    /// The last character outside strings and whitespace, inside the value.
    private var lastSignificantScalar: Unicode.Scalar?

    public init() {}

    public mutating func feed(_ chunk: String) -> [WBScannedValue] {
        var emittedValues: [WBScannedValue] = []
        for scalar in chunk.unicodeScalars {
            consume(scalar, into: &emittedValues)
        }
        return emittedValues
    }

    public mutating func finish() -> [WBScannedValue] {
        var emittedValues: [WBScannedValue] = []
        if !openBracketStack.isEmpty {
            emittedValues.append(WBScannedValue(text: WBRepair.balance(String(currentValueText)), wasClosedByScanner: true))
        }
        resetValueState()
        return emittedValues
    }

    private mutating func consume(_ scalar: Unicode.Scalar, into emittedValues: inout [WBScannedValue]) {
        if openBracketStack.isEmpty {
            // Between values: wait for an opening bracket.
            guard scalar == "{" || scalar == "[" else { return }
            openBracketStack.append(scalar)
            currentValueText.append(scalar)
            lastSignificantScalar = scalar
            return
        }

        if isInsideString {
            currentValueText.append(scalar)
            if isAfterBackslash {
                isAfterBackslash = false
            } else if scalar == "\\" {
                isAfterBackslash = true
            } else if scalar == "\"" {
                isInsideString = false
                lastSignificantScalar = scalar
            }
            return
        }

        switch scalar {
        case "\"":
            isInsideString = true
            currentValueText.append(scalar)
        case "{", "[":
            if scalar == "{", openBracketStack.last == "{", lastSignificantScalar != ":" {
                // An object can only hold "{" as a value (after ":"): the open
                // value is unterminated; close it and start over here.
                emittedValues.append(WBScannedValue(text: WBRepair.balance(String(currentValueText)), wasClosedByScanner: true))
                resetValueState()
                openBracketStack.append(scalar)
                currentValueText.append(scalar)
                lastSignificantScalar = scalar
                return
            }
            openBracketStack.append(scalar)
            currentValueText.append(scalar)
            lastSignificantScalar = scalar
        case "}", "]":
            currentValueText.append(scalar)
            lastSignificantScalar = scalar
            // A mismatched closer still pops one level; WBRepair sorts out the text.
            openBracketStack.removeLast()
            if openBracketStack.isEmpty {
                emittedValues.append(WBScannedValue(text: String(currentValueText)))
                resetValueState()
            }
        default:
            currentValueText.append(scalar)
            if !scalar.properties.isWhitespace { lastSignificantScalar = scalar }
        }
    }

    private mutating func resetValueState() {
        currentValueText = String.UnicodeScalarView()
        openBracketStack = []
        isInsideString = false
        isAfterBackslash = false
        lastSignificantScalar = nil
    }
}
