//
//  LiveScreenMark.swift
//  leanring-buddy
//
//  Live marks are circles, arrows, and numbered step badges that Claude can
//  draw on top of the user's screen while it answers, so "click here, then
//  here" becomes a visible 1-2-3 instead of one cursor flight.
//
//  Claude adds [MARK:...] tags to the end of its response (before the
//  [POINT:...] tag). This file parses those tags. Pure Foundation so the
//  parser can be tested without the app.
//
//  Tag format: [MARK:kind:x,y:label:screenN]
//    kind   — "circle", "arrow", or a step number ("1", "step2", ...)
//    x,y    — pixel coordinates in that screen's screenshot (top-left origin)
//    label  — optional short text drawn next to the mark
//    screenN — optional, which screen the mark is on (defaults to the cursor's)
//

import CoreGraphics
import Foundation

enum LiveScreenMarkKind: Equatable {
    /// A ring drawn around an element: "this thing here".
    case circle
    /// An arrow whose head points at an element.
    case arrow
    /// A numbered badge for multi-step instructions: "first this, then this".
    case numberedStep(stepNumber: Int)
}

/// A mark as Claude wrote it, still in screenshot pixel coordinates.
struct ParsedLiveScreenMarkTag: Equatable {
    let markKind: LiveScreenMarkKind
    let screenshotPixelCoordinate: CGPoint
    let markLabel: String?
    /// 1-based screen number from the screenshot labels, or nil for the cursor screen.
    let screenNumber: Int?
}

/// A mark ready to draw, in AppKit global screen coordinates.
struct LiveScreenMark: Identifiable, Equatable {
    let id = UUID()
    let markKind: LiveScreenMarkKind
    let globalScreenLocation: CGPoint
    let markLabel: String?
    /// Position in the response, used to stagger the draw-in animation so
    /// marks appear one after another instead of all at once.
    let orderInResponse: Int
}

enum LiveScreenMarkTagParser {
    /// More marks than this turns the screen into noise, so extras are dropped.
    static let maximumMarksPerResponse = 6

    private static let markTagPattern = #"\[MARK:\s*(circle|arrow|step\s*\d+|\d+)\s*:\s*(\d+)\s*,\s*(\d+)(?::([^\]:]*))?(?::\s*screen\s*(\d+))?\s*\]"#

    /// Removes every [MARK:...] tag from the response and returns the
    /// remaining text plus the parsed marks, in the order Claude wrote them.
    /// Malformed tags are still removed so they never get read aloud.
    static func extractLiveScreenMarkTags(from responseText: String) -> (textWithoutMarkTags: String, parsedMarkTags: [ParsedLiveScreenMarkTag]) {
        guard let markTagRegex = try? NSRegularExpression(pattern: markTagPattern, options: [.caseInsensitive]) else {
            return (responseText, [])
        }

        let fullResponseRange = NSRange(responseText.startIndex..., in: responseText)
        var parsedMarkTags: [ParsedLiveScreenMarkTag] = []

        for markTagMatch in markTagRegex.matches(in: responseText, range: fullResponseRange) {
            guard parsedMarkTags.count < maximumMarksPerResponse,
                  let parsedMarkTag = parseMarkTagMatch(markTagMatch, in: responseText) else { continue }
            parsedMarkTags.append(parsedMarkTag)
        }

        var textWithoutMarkTags = markTagRegex.stringByReplacingMatches(in: responseText, range: fullResponseRange, withTemplate: "")

        // Catch anything that looks like a mark tag but didn't match the
        // strict pattern (e.g. a typo from the model) so it isn't spoken.
        if let looseMarkTagRegex = try? NSRegularExpression(pattern: #"\[MARK:[^\]]*\]"#, options: [.caseInsensitive]) {
            textWithoutMarkTags = looseMarkTagRegex.stringByReplacingMatches(
                in: textWithoutMarkTags,
                range: NSRange(textWithoutMarkTags.startIndex..., in: textWithoutMarkTags),
                withTemplate: ""
            )
        }

        // Tags removed from the middle of a sentence leave double spaces.
        let collapsedText = textWithoutMarkTags
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (collapsedText, parsedMarkTags)
    }

    private static func parseMarkTagMatch(_ markTagMatch: NSTextCheckingResult, in responseText: String) -> ParsedLiveScreenMarkTag? {
        guard let kindRange = Range(markTagMatch.range(at: 1), in: responseText),
              let xRange = Range(markTagMatch.range(at: 2), in: responseText),
              let yRange = Range(markTagMatch.range(at: 3), in: responseText),
              let pixelX = Double(responseText[xRange]),
              let pixelY = Double(responseText[yRange]) else { return nil }

        let kindText = responseText[kindRange].lowercased().replacingOccurrences(of: " ", with: "")
        let markKind: LiveScreenMarkKind
        if kindText == "circle" {
            markKind = .circle
        } else if kindText == "arrow" {
            markKind = .arrow
        } else if let stepNumber = Int(kindText.replacingOccurrences(of: "step", with: "")), stepNumber > 0 {
            markKind = .numberedStep(stepNumber: stepNumber)
        } else {
            return nil
        }

        var markLabel: String? = nil
        if let labelRange = Range(markTagMatch.range(at: 4), in: responseText) {
            let trimmedLabel = responseText[labelRange].trimmingCharacters(in: .whitespaces)
            markLabel = trimmedLabel.isEmpty ? nil : trimmedLabel
        }

        var screenNumber: Int? = nil
        if let screenRange = Range(markTagMatch.range(at: 5), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        // With no label, "[MARK:circle:10,20:screen2]" puts "screen2" in the
        // label slot. Treat it as the screen number instead.
        if screenNumber == nil, let labelThatIsReallyAScreenNumber = markLabel?.lowercased(),
           labelThatIsReallyAScreenNumber.hasPrefix("screen"),
           let parsedScreenNumber = Int(labelThatIsReallyAScreenNumber.dropFirst("screen".count).trimmingCharacters(in: .whitespaces)) {
            screenNumber = parsedScreenNumber
            markLabel = nil
        }

        return ParsedLiveScreenMarkTag(
            markKind: markKind,
            screenshotPixelCoordinate: CGPoint(x: pixelX, y: pixelY),
            markLabel: markLabel,
            screenNumber: screenNumber
        )
    }
}
