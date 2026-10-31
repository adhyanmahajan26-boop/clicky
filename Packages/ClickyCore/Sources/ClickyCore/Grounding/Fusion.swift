//
//  Fusion.swift
//  ClickyCore
//
//  Merges AX elements and OCR lines into the numbered registry the model
//  sees, then formats each screen's element list.
//
//  - An OCR line is left out of the LIST (never out of text search) when an
//    AX element already says the same thing at that spot, or it overlaps a
//    small (leaf) AX element.
//  - score = 3·(interactive + frontWindow + focused) + 2·e^(−d/400 pt)
//            + hasLabel + 0.5·ocrOnly − 2·(area > 15% of the screen)
//  - Top 120 on the cursor screen, 40 on others. Ids start at 1, ordered by
//    screen (cursor first), then window front to back, then reading order.
//

import CoreGraphics
import Foundation

public struct ScreenGroundingInput: Sendable {
    public let frame: CaptureFrame
    public let isCursorScreen: Bool
    public let axElements: [GroundingElement]
    public let ocrLines: [OCRLine]

    public init(frame: CaptureFrame, isCursorScreen: Bool, axElements: [GroundingElement], ocrLines: [OCRLine]) {
        self.frame = frame
        self.isCursorScreen = isCursorScreen
        self.axElements = axElements
        self.ocrLines = ocrLines
    }
}

public enum GroundingFusion {
    public static let cursorScreenCap = 120
    public static let otherScreenCap = 40

    public static func buildRegistry(screens: [ScreenGroundingInput], cursorCG: CGPoint, windowStack: WindowStack) -> ElementRegistry {
        var registry = ElementRegistry()
        registry.allOCRLines = screens.flatMap(\.ocrLines)

        for screen in screens.sorted(by: { $0.frame.screenNumber < $1.frame.screenNumber }) {
            let screenArea = screen.frame.regionCG.area
            var candidates = screen.axElements.map { axElement -> GroundingElement in
                var element = axElement
                if !element.isSystemChrome && windowStack.isBehind(point: element.visibleFrameCG.center, processIdentifier: element.processIdentifier) {
                    element.isBehind = true
                }
                return element
            }
            let redundancyIndex = RedundancyIndex(axElements: screen.axElements, windowStack: windowStack)
            candidates += screen.ocrLines
                .filter { !redundancyIndex.isRedundant($0) }
                .map { ocrElement(for: $0, windowStack: windowStack) }

            let scoredCandidates = candidates
                .map { candidate in (candidate, score(candidate, cursorCG: cursorCG, screenArea: screenArea)) }
                .sorted { $0.1 > $1.1 }
                .prefix(screen.isCursorScreen ? cursorScreenCap : otherScreenCap)
                .map(\.0)

            for element in scoredCandidates.sorted(by: idOrder) {
                _ = registry.append(element)
            }
        }
        return registry
    }

    static func score(_ element: GroundingElement, cursorCG: CGPoint, screenArea: CGFloat) -> Double {
        let interactiveTerm = (element.isInteractive ? 1.0 : 0) + (element.isInFrontWindow ? 1 : 0) + (element.isFocused ? 1 : 0)
        let distanceInPoints = Double(element.visibleFrameCG.edgeDistance(to: cursorCG))
        let hasLabel = (element.label?.isEmpty == false) ? 1.0 : 0
        let isLarge = screenArea > 0 && element.visibleFrameCG.area > 0.15 * screenArea
        return 3 * interactiveTerm + 2 * exp(-distanceInPoints / 400) + hasLabel + (element.isOCROnly ? 0.5 : 0) - (isLarge ? 2 : 0)
    }

    /// Screen by caller; within a screen: system chrome (menu bar, Dock)
    /// first, then windows front to back, then reading order.
    static func idOrder(_ first: GroundingElement, _ second: GroundingElement) -> Bool {
        let firstZ = first.isSystemChrome ? -1 : first.windowZIndex
        let secondZ = second.isSystemChrome ? -1 : second.windowZIndex
        if firstZ != secondZ { return firstZ < secondZ }
        let firstLine = Int((first.visibleFrameCG.minY / 12).rounded(.down))
        let secondLine = Int((second.visibleFrameCG.minY / 12).rounded(.down))
        if firstLine != secondLine { return firstLine < secondLine }
        return first.visibleFrameCG.minX < second.visibleFrameCG.minX
    }

    static func isRedundant(_ ocrLine: OCRLine, axElements: [GroundingElement], windowStack: WindowStack) -> Bool {
        RedundancyIndex(axElements: axElements, windowStack: windowStack).isRedundant(ocrLine)
    }

    /// The AX side of the redundancy rule, prepared once per screen: each
    /// element's leaf flag, and elements bucketed by 64 pt row so a line only
    /// looks at elements that can touch it.
    struct RedundancyIndex {
        private static let rowHeight: CGFloat = 64
        private let elements: [(frame: CGRect, isLeaf: Bool, texts: [String?])]
        private let elementIndexesByRow: [Int: [Int]]

        init(axElements: [GroundingElement], windowStack: WindowStack) {
            let windowAreas = Dictionary(windowStack.windows.map { ($0.windowID, $0.boundsCG.area) }, uniquingKeysWith: { first, _ in first })
            var elements: [(frame: CGRect, isLeaf: Bool, texts: [String?])] = []
            var elementIndexesByRow: [Int: [Int]] = [:]
            for axElement in axElements {
                let frame = axElement.visibleFrameCG
                guard !frame.isNull, frame.width > 0, frame.height > 0 else { continue }
                let containerArea = axElement.windowID.flatMap { windowAreas[$0] } ?? .greatestFiniteMagnitude
                let elementIndex = elements.count
                elements.append((frame, frame.area < 0.25 * containerArea, axElement.matchableTexts))
                for row in Self.rows(of: frame) { elementIndexesByRow[row, default: []].append(elementIndex) }
            }
            self.elements = elements
            self.elementIndexesByRow = elementIndexesByRow
        }

        private static func rows(of frame: CGRect) -> ClosedRange<Int> {
            Int((frame.minY / rowHeight).rounded(.down))...Int((frame.maxY / rowHeight).rounded(.down))
        }

        func isRedundant(_ ocrLine: OCRLine) -> Bool {
            let lineFrame = ocrLine.frameCG
            let lineCenter = lineFrame.center
            var visitedIndexes = Set<Int>()
            for row in Self.rows(of: lineFrame) {
                for elementIndex in elementIndexesByRow[row] ?? [] where visitedIndexes.insert(elementIndex).inserted {
                    let element = elements[elementIndex]
                    guard element.frame.intersects(lineFrame) else { continue }
                    if element.isLeaf && lineFrame.intersectionOverUnion(with: element.frame) > 0.1 { return true }
                    if element.frame.contains(lineCenter), LabelSimilarity.labelSim(ocrLine.text, candidates: element.texts) >= 0.8 {
                        return true
                    }
                }
            }
            return false
        }
    }

    static func ocrElement(for ocrLine: OCRLine, windowStack: WindowStack) -> GroundingElement {
        let ownerWindow = windowStack.windows.first { $0.isApplicationWindowLayer && $0.boundsCG.contains(ocrLine.frameCG.center) }
        return GroundingElement(
            role: .text,
            label: ocrLine.text,
            frameCG: ocrLine.frameCG,
            processIdentifier: ownerWindow?.processIdentifier ?? 0,
            windowID: ownerWindow?.windowID,
            windowTitle: ownerWindow?.title,
            applicationName: ownerWindow?.ownerName,
            displayID: ocrLine.displayID,
            isInteractive: false,
            source: .ocr,
            windowZIndex: ownerWindow.flatMap { windowStack.zIndex(of: $0.windowID) } ?? Int.max / 2
        )
    }
}

// MARK: - Element list text

public enum ElementListWriter {
    public static let maximumLabelLength = 40
    public static let maximumValueLength = 30
    public static let maximumURLValueLength = 120

    /// The header plus one line per listed element on this screen, in model
    /// pixels of `frame` (x,y = top-left, then w,h).
    public static func lines(header: String, frame: CaptureFrame, registry: ElementRegistry, cursorCG: CGPoint?, isCursorScreen: Bool) -> [String] {
        var outputLines = [header]
        let screenEntries = registry.orderedIDs.compactMap { elementID -> (Int, GroundingElement)? in
            guard let element = registry[elementID], element.displayID == frame.display.displayID else { return nil }
            return (elementID, element)
        }

        var cursorFocusParts: [String] = []
        if isCursorScreen, let cursorCG {
            let cursorPixel = frame.modelPx(fromCG: cursorCG)
            var cursorPart = "cursor \(Int(cursorPixel.x.rounded())),\(Int(cursorPixel.y.rounded()))"
            if let overID = screenEntries
                .filter({ $0.1.visibleFrameCG.contains(cursorCG) })
                .min(by: { $0.1.visibleFrameCG.area < $1.1.visibleFrameCG.area })?.0 {
                cursorPart += " over #\(overID)"
            }
            cursorFocusParts.append(cursorPart)
        }
        if let focusedID = screenEntries.first(where: { $0.1.isFocused })?.0 {
            cursorFocusParts.append("focus #\(focusedID)")
        }
        if !cursorFocusParts.isEmpty {
            outputLines.append(cursorFocusParts.joined(separator: "; "))
        }

        var currentGroupLine: String?
        for (elementID, element) in screenEntries {
            let groupLine = groupHeader(for: element)
            if groupLine != currentGroupLine {
                outputLines.append(groupLine)
                currentGroupLine = groupLine
            }
            outputLines.append(elementLine(elementID: elementID, element: element, frame: frame))
        }
        return outputLines
    }

    public static func groupHeader(for element: GroundingElement) -> String {
        if element.role == .dock { return "dock" }
        if element.isSystemChrome { return "menubar (\(quoteSafe(element.applicationName ?? "menu bar")))" }
        if element.windowID != nil {
            return "window \"\(quoteSafe(truncated(element.windowTitle ?? "", to: 60)))\" (\(quoteSafe(element.applicationName ?? "")))"
        }
        return "other"
    }

    public static func elementLine(elementID: Int, element: GroundingElement, frame: CaptureFrame) -> String {
        let pixelRect = frame.modelPxRect(fromCG: element.visibleFrameCG)
        var lineParts = ["\(elementID)", element.role.rawValue, "\"\(quoteSafe(truncated(element.label ?? "", to: maximumLabelLength)))\""]
        if let value = element.value, !value.isEmpty {
            let isURLField = element.role == .textField && (value.contains("://") || value.range(of: #"^[\w-]+(\.[\w-]+)+(/|$)"#, options: .regularExpression) != nil)
            lineParts.append("=\"\(quoteSafe(truncated(value, to: isURLField ? maximumURLValueLength : maximumValueLength)))\"")
        }
        lineParts.append("\(Int(pixelRect.minX.rounded())),\(Int(pixelRect.minY.rounded())),\(max(1, Int(pixelRect.width.rounded()))),\(max(1, Int(pixelRect.height.rounded())))")
        if element.isOCROnly { lineParts.append("ocr") }
        if !element.isEnabled { lineParts.append("dis") }
        if element.isBehind { lineParts.append("behind") }
        return lineParts.joined(separator: " ")
    }

    static func truncated(_ text: String, to maximumLength: Int) -> String {
        let singleLineText = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return singleLineText.count <= maximumLength ? singleLineText : String(singleLineText.prefix(maximumLength - 1)) + "…"
    }

    static func quoteSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
    }
}
