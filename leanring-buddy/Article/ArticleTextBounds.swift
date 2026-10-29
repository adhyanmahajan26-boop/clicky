//
//  ArticleTextBounds.swift
//  leanring-buddy
//
//  P8 highlights: screen rects of a range of an AXStaticText run, one per
//  text line. Three ways, best first:
//   1. AXBoundsForRange on the run (a CFRange into its AXValue);
//   2. text markers on the web area (AXTextMarkerRangeForUIElement →
//      AXIndexForTextMarker gives the run's start index in the document,
//      AXTextMarkerForIndex the markers at start + offset, then
//      AXBoundsForTextMarkerRange) — Chrome and WebKit both answer these;
//   3. the run's AXFrame (whole run, or a proportional slice of a
//      one-line run).
//  A range taller than ~1.6 lines wrapped: it is measured word by word and
//  the word rects are grouped into lines (ArticleLineFragments), so a
//  sentence over three lines gets three strokes, not one box.
//  Everything here is read-only AX; it runs off the main thread.
//

import ApplicationServices
import ClickyCore
import Foundation

nonisolated enum ArticleTextBounds {
    enum Method: String {
        case boundsForRange
        case textMarkers
        case elementFrame
    }

    struct Measurement {
        var lineRects: [CGRect]
        var method: Method?
    }

    /// Line rects for `range` (UTF-16, into the run's AXValue `runText`).
    static func lineRects(element: AXUIElement, runText: String, range: Range<Int>, webArea: AXUIElement?) -> Measurement {
        AXUIElementSetMessagingTimeout(element, 0.3)
        let runLength = runText.utf16.count
        // A run whose text came back shorter (or empty) than when it was read
        // would make lowerBound > upperBound, which traps; clamp both ends.
        let clampedLowerBound = min(max(0, range.lowerBound), runLength)
        let clampedRange = clampedLowerBound..<max(clampedLowerBound, min(runLength, range.upperBound))
        guard !clampedRange.isEmpty else { return Measurement(lineRects: [], method: nil) }

        for method in [Method.boundsForRange, .textMarkers] {
            guard let whole = bounds(element: element, range: clampedRange, method: method, webArea: webArea) else { continue }
            let firstCharacter = bounds(element: element, range: clampedRange.lowerBound..<(clampedRange.lowerBound + 1), method: method, webArea: webArea)
            let lineHeight = firstCharacter?.height ?? whole.height
            if ArticleLineFragments.isSingleLine(rangeBounds: whole, lineHeight: lineHeight) {
                return Measurement(lineRects: [whole], method: method)
            }
            // Wrapped: measure each word and group them into lines.
            let rangeText = substring(runText, clampedRange)
            let wordRects = ArticleLineFragments.wordRanges(in: rangeText, base: clampedRange.lowerBound).compactMap { wordRange in
                bounds(element: element, range: wordRange, method: method, webArea: webArea)
            }
            let lines = ArticleLineFragments.lineRects(fromWordRects: wordRects)
            if !lines.isEmpty { return Measurement(lineRects: lines, method: method) }
        }

        // The run's frame: all of it, or a horizontal slice of a one-line run.
        guard let frame = TypeForMeAccessibilityFrame.frameCG(of: element), frame.width > 0, frame.height > 0 else {
            return Measurement(lineRects: [], method: nil)
        }
        let coveredFraction = Double(clampedRange.count) / Double(max(1, runLength))
        if coveredFraction >= 0.9 || frame.height > 30 {
            return Measurement(lineRects: [frame], method: .elementFrame)
        }
        let startFraction = CGFloat(clampedRange.lowerBound) / CGFloat(max(1, runLength))
        let endFraction = CGFloat(clampedRange.upperBound) / CGFloat(max(1, runLength))
        let slice = CGRect(x: frame.minX + frame.width * startFraction, y: frame.minY, width: max(2, frame.width * (endFraction - startFraction)), height: frame.height)
        return Measurement(lineRects: [slice], method: .elementFrame)
    }

    static func bounds(element: AXUIElement, range: Range<Int>, method: Method, webArea: AXUIElement?) -> CGRect? {
        switch method {
        case .boundsForRange:
            var cfRange = CFRange(location: range.lowerBound, length: range.count)
            guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
            var boundsValue: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue) == .success else { return nil }
            return usableRect(boundsValue)
        case .textMarkers:
            guard let webArea, let startIndex = documentStartIndex(of: element, webArea: webArea),
                  let startMarker = parameterized(webArea, "AXTextMarkerForIndex", NSNumber(value: startIndex + range.lowerBound)),
                  let endMarker = parameterized(webArea, "AXTextMarkerForIndex", NSNumber(value: startIndex + range.upperBound)),
                  let markerRange = parameterized(webArea, "AXTextMarkerRangeForUnorderedTextMarkers", [startMarker, endMarker] as CFArray),
                  let boundsValue = parameterized(webArea, "AXBoundsForTextMarkerRange", markerRange) else { return nil }
            return usableRect(boundsValue)
        case .elementFrame:
            return TypeForMeAccessibilityFrame.frameCG(of: element)
        }
    }

    /// Where the run starts in the web area's text-marker index space.
    static func documentStartIndex(of element: AXUIElement, webArea: AXUIElement) -> Int? {
        guard let markerRange = parameterized(element, "AXTextMarkerRangeForUIElement", element),
              let startMarker = parameterized(webArea, "AXStartTextMarkerForTextMarkerRange", markerRange),
              let index = parameterized(webArea, "AXIndexForTextMarker", startMarker) as? NSNumber else { return nil }
        return index.intValue
    }

    static func parameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success else { return nil }
        return value
    }

    static func usableRect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.width > 0, rect.height > 0, rect.height < 400, !(rect.origin == .zero && rect.width < 2) else { return nil }
        return rect
    }

    static func substring(_ text: String, _ range: Range<Int>) -> String {
        let utf16 = text.utf16
        guard range.lowerBound >= 0, range.upperBound <= utf16.count else { return "" }
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        return String(utf16[start..<end]) ?? ""
    }
}

/// AXPosition + AXSize, callable off the main thread.
nonisolated enum TypeForMeAccessibilityFrame {
    /// AXFrame in one round trip (Chrome and WebKit have it), else AXPosition + AXSize.
    static func frameCG(of element: AXUIElement) -> CGRect? {
        var frameValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameValue) == .success, let frameValue,
           CFGetTypeID(frameValue) == AXValueGetTypeID() {
            var frame = CGRect.zero
            // swiftlint:disable:next force_cast
            if AXValueGetValue(frameValue as! AXValue, .cgRect, &frame) { return frame }
        }
        return positionAndSizeFrame(of: element)
    }

    static func positionAndSizeFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        return CGRect(origin: position, size: size)
    }
}
