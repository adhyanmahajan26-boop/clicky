import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

private let fusionDisplay = DisplayInfo(
    displayID: 1,
    localizedName: "Main",
    boundsCG: CGRect(x: 0, y: 0, width: 3440, height: 1440),
    visibleCG: CGRect(x: 0, y: 30, width: 3440, height: 1410),
    frameAppKit: CGRect(x: 0, y: 0, width: 3440, height: 1440),
    isMain: true
)

private func fusionFrame(screenNumber: Int = 1) -> CaptureFrame {
    CaptureFrame(
        display: fusionDisplay,
        screenNumber: screenNumber,
        native: PixelSize(width: 3440, height: 1440),
        model: PixelSize(width: 2000, height: 837)
    )
}

/// One fullscreen window of pid 42 ("Mail" / "Inbox") as the front-most window.
private let mailWindow = WindowInfo(windowID: 10, processIdentifier: 42, layer: 0,
                                    boundsCG: CGRect(x: 0, y: 0, width: 3440, height: 1440), alpha: 1,
                                    ownerName: "Mail", title: "Inbox")

private func fusionStack(front: [WindowInfo] = []) -> WindowStack {
    WindowStack(windows: front + [mailWindow], ownProcessIdentifier: 1, displays: [fusionDisplay])
}

private func axElement(
    _ label: String?,
    role: GroundingRole = .button,
    frame: CGRect,
    pid: pid_t = 42,
    windowID: CGWindowID? = 10,
    windowTitle: String? = "Inbox",
    applicationName: String? = "Mail",
    displayID: CGDirectDisplayID = 1,
    isInteractive: Bool = true,
    isEnabled: Bool = true,
    isFocused: Bool = false,
    isInFrontWindow: Bool = false,
    isSystemChrome: Bool = false,
    windowZIndex: Int = 0,
    value: String? = nil
) -> GroundingElement {
    GroundingElement(
        role: role,
        label: label,
        value: value,
        frameCG: frame,
        processIdentifier: pid,
        windowID: windowID,
        windowTitle: windowTitle,
        applicationName: applicationName,
        displayID: displayID,
        isInteractive: isInteractive,
        isEnabled: isEnabled,
        isFocused: isFocused,
        isInFrontWindow: isInFrontWindow,
        isSystemChrome: isSystemChrome,
        source: .accessibility,
        windowZIndex: windowZIndex
    )
}

/// Same rounding the list uses: model px of a CG rect, as "x,y,w,h".
private func expectedRect(_ cgRect: CGRect, in frame: CaptureFrame) -> String {
    let pixelRect = frame.modelPxRect(fromCG: cgRect)
    return "\(Int(pixelRect.minX.rounded())),\(Int(pixelRect.minY.rounded())),\(max(1, Int(pixelRect.width.rounded()))),\(max(1, Int(pixelRect.height.rounded())))"
}

private let shareFrame = CGRect(x: 2000, y: 500, width: 100, height: 40)
private let archiveFrame = CGRect(x: 2200, y: 500, width: 80, height: 40)
private let fileMenuFrame = CGRect(x: 100, y: 0, width: 40, height: 24)

// MARK: - Registry

@Test func registryIdsStartAtOneAndFollowMenuBarThenWindowOrderThenReadingOrder() {
    let elements = [
        axElement("Sidebar", role: .text, frame: CGRect(x: 50, y: 300, width: 100, height: 30), windowID: 11,
                  windowTitle: "Other", windowZIndex: 1),
        axElement("Share", frame: shareFrame, isInFrontWindow: true),
        axElement("Compose", frame: CGRect(x: 2000, y: 200, width: 100, height: 40)),
        axElement("File", role: .menu, frame: fileMenuFrame, windowID: nil, windowTitle: nil,
                  applicationName: "Finder", isSystemChrome: true, windowZIndex: 0),
    ]
    let registry = GroundingFusion.buildRegistry(
        screens: [ScreenGroundingInput(frame: fusionFrame(), isCursorScreen: true, axElements: elements, ocrLines: [])],
        cursorCG: CGPoint(x: 0, y: 0),
        windowStack: fusionStack()
    )

    #expect(registry.orderedIDs == [1, 2, 3, 4])
    #expect(registry[1]?.label == "File")   // menu bar first, despite z index 0
    #expect(registry[2]?.label == "Compose") // window z 0, higher on screen
    #expect(registry[3]?.label == "Share")   // window z 0, lower on screen
    #expect(registry[4]?.label == "Sidebar") // window z 1 last
}

@Test func redundantOCRLineIsDroppedFromTheListButKeptForTextSearch() {
    let staticText = axElement("Hello", role: .text, frame: CGRect(x: 300, y: 300, width: 60, height: 20),
                               isInteractive: false)
    let duplicateOCR = OCRLine(text: "Hello", frameCG: CGRect(x: 302, y: 302, width: 56, height: 16), displayID: 1)
    let newOCR = OCRLine(text: "rate limit exceeded (429)", frameCG: CGRect(x: 600, y: 800, width: 400, height: 20), displayID: 1)
    let registry = GroundingFusion.buildRegistry(
        screens: [ScreenGroundingInput(frame: fusionFrame(), isCursorScreen: true, axElements: [staticText],
                                       ocrLines: [duplicateOCR, newOCR])],
        cursorCG: CGPoint(x: 0, y: 0),
        windowStack: fusionStack()
    )

    // The AX "Hello" stays; the OCR "Hello" is redundant; the new OCR line is listed.
    #expect(registry.orderedIDs.count == 2)
    #expect(registry.allOCRLines.count == 2)
    let listedTexts = registry.orderedIDs.compactMap { registry[$0] }
    #expect(listedTexts.filter { $0.label == "Hello" }.count == 1)
    let ocrEntry = listedTexts.first { $0.label == "rate limit exceeded (429)" }
    #expect(ocrEntry?.isOCROnly == true)
    #expect(ocrEntry?.role == .text)
    #expect(ocrEntry?.windowTitle == "Inbox")
}

@Test func cursorScreenIsCappedAt120AndOtherScreensAt40() {
    func manyElements() -> [GroundingElement] {
        (0..<150).map { index in
            axElement("B\(index)", frame: CGRect(x: CGFloat(index % 50) * 60, y: CGFloat(index / 50) * 40, width: 40, height: 20))
        }
    }
    let cursorRegistry = GroundingFusion.buildRegistry(
        screens: [ScreenGroundingInput(frame: fusionFrame(), isCursorScreen: true, axElements: manyElements(), ocrLines: [])],
        cursorCG: CGPoint(x: 0, y: 0),
        windowStack: fusionStack()
    )
    #expect(cursorRegistry.orderedIDs.count == GroundingFusion.cursorScreenCap)
    #expect(cursorRegistry.orderedIDs.count == 120)

    let otherRegistry = GroundingFusion.buildRegistry(
        screens: [ScreenGroundingInput(frame: fusionFrame(), isCursorScreen: false, axElements: manyElements(), ocrLines: [])],
        cursorCG: CGPoint(x: 0, y: 0),
        windowStack: fusionStack()
    )
    #expect(otherRegistry.orderedIDs.count == GroundingFusion.otherScreenCap)
    #expect(otherRegistry.orderedIDs.count == 40)
}

// MARK: - Element list text

private func listRegistry(shareFocused: Bool = false, archiveEnabled: Bool = false) -> ElementRegistry {
    let elements = [
        axElement("File", role: .menu, frame: fileMenuFrame, windowID: nil, windowTitle: nil,
                  applicationName: "Finder", isSystemChrome: true, windowZIndex: 0),
        axElement("Share", frame: shareFrame, isFocused: shareFocused, isInFrontWindow: true),
        axElement("Archive", frame: archiveFrame, isEnabled: archiveEnabled),
    ]
    return GroundingFusion.buildRegistry(
        screens: [ScreenGroundingInput(frame: fusionFrame(), isCursorScreen: false, axElements: elements, ocrLines: [])],
        cursorCG: CGPoint(x: 0, y: 0),
        windowStack: fusionStack()
    )
}

@Test func listStartsWithHeaderThenGroupLinesAndElementLines() {
    let frame = fusionFrame()
    let lines = ElementListWriter.lines(header: "SCREEN 2 (3440x1440)", frame: frame, registry: listRegistry(archiveEnabled: false),
                                        cursorCG: nil, isCursorScreen: false)

    #expect(lines.count == 6)
    #expect(lines[0] == "SCREEN 2 (3440x1440)")
    #expect(lines[1] == "menubar (Finder)")
    #expect(lines[2] == "1 menu \"File\" \(expectedRect(fileMenuFrame, in: frame))")
    #expect(lines[3] == "window \"Inbox\" (Mail)")
    // Hand-checked: 2000 * 2000/3440 = 1162.8 -> 1163, 500 * 837/1440 = 290.6 -> 291, 100 * 0.581 -> 58, 40 * 0.581 -> 23.
    #expect(lines[4] == "2 btn \"Share\" 1163,291,58,23")
    #expect(lines[5] == "3 btn \"Archive\" \(expectedRect(archiveFrame, in: frame)) dis")
}

@Test func cursorLineNamesTheElementUnderTheCursorAndTheFocusedElement() {
    let frame = fusionFrame()
    let cursor = CGPoint(x: 2050, y: 520) // inside Share
    let lines = ElementListWriter.lines(header: "H", frame: frame, registry: listRegistry(shareFocused: true), cursorCG: cursor,
                                        isCursorScreen: true)

    let pixel = frame.modelPx(fromCG: cursor)
    #expect(lines[1] == "cursor \(Int(pixel.x.rounded())),\(Int(pixel.y.rounded())) over #2; focus #2")
}

@Test func cursorLineWithoutElementUnderCursorHasNoOverPart() {
    let frame = fusionFrame()
    let lines = ElementListWriter.lines(header: "H", frame: frame, registry: listRegistry(), cursorCG: CGPoint(x: 10, y: 1000),
                                        isCursorScreen: true)
    #expect(lines[1].hasPrefix("cursor "))
    #expect(!lines[1].contains("over"))
    #expect(!lines[1].contains("focus"))
}

@Test func labelsAreTruncatedToFortyCharactersWithAnEllipsisAndQuotesAreSwapped() {
    let longLabel = String(repeating: "a", count: 50)
    let elements = [axElement("Say \"hi\"", frame: shareFrame), axElement(longLabel, frame: archiveFrame)]
    let registry = GroundingFusion.buildRegistry(
        screens: [ScreenGroundingInput(frame: fusionFrame(), isCursorScreen: false, axElements: elements, ocrLines: [])],
        cursorCG: CGPoint(x: 0, y: 0),
        windowStack: fusionStack()
    )
    let lines = ElementListWriter.lines(header: "H", frame: fusionFrame(), registry: registry, cursorCG: nil, isCursorScreen: false)

    let truncated = String(repeating: "a", count: 39) + "…"
    #expect(truncated.count == 40)
    #expect(lines.contains { $0.contains("\"\(truncated)\"") })
    #expect(lines.contains { $0.contains("\"Say 'hi'\"") })
}

@Test func valuesAreShownAfterTheLabelAndTruncated() {
    let longValue = String(repeating: "v", count: 40)
    let urlValue = "https://example.com/" + String(repeating: "p", count: 150)
    let elements = [
        axElement("Query", role: .textField, frame: shareFrame, value: longValue),
        axElement("Address", role: .textField, frame: archiveFrame, value: urlValue),
    ]
    let registry = GroundingFusion.buildRegistry(
        screens: [ScreenGroundingInput(frame: fusionFrame(), isCursorScreen: false, axElements: elements, ocrLines: [])],
        cursorCG: CGPoint(x: 0, y: 0),
        windowStack: fusionStack()
    )
    let lines = ElementListWriter.lines(header: "H", frame: fusionFrame(), registry: registry, cursorCG: nil, isCursorScreen: false)

    // Plain values: 29 characters + ellipsis (30 total).
    let shortShown = String(repeating: "v", count: 29) + "…"
    #expect(lines.contains { $0.hasPrefix("1 tf \"Query\" =\"\(shortShown)\" ") })
    // URL-like text fields keep up to 120 characters.
    let urlShown = String(urlValue.prefix(119)) + "…"
    #expect(lines.contains { $0.hasPrefix("2 tf \"Address\" =\"\(urlShown)\" ") })
}

@Test func ocrOnlyItemsAreFlaggedAndBehindElementsAreMarked() {
    // A front window of another app covers the Share button.
    let cover = WindowInfo(windowID: 20, processIdentifier: 43, layer: 0,
                           boundsCG: CGRect(x: 2000, y: 400, width: 300, height: 300), alpha: 1,
                           ownerName: "Other", title: "Other window")
    let elements = [axElement("Share", frame: shareFrame)]
    let ocr = [OCRLine(text: "rate limit exceeded (429)", frameCG: CGRect(x: 600, y: 800, width: 400, height: 20), displayID: 1)]
    let registry = GroundingFusion.buildRegistry(
        screens: [ScreenGroundingInput(frame: fusionFrame(), isCursorScreen: false, axElements: elements, ocrLines: ocr)],
        cursorCG: CGPoint(x: 0, y: 0),
        windowStack: fusionStack(front: [cover])
    )
    let lines = ElementListWriter.lines(header: "H", frame: fusionFrame(), registry: registry, cursorCG: nil, isCursorScreen: false)

    #expect(lines.contains { $0.hasPrefix("1 btn \"Share\" ") && $0.hasSuffix(" behind") })
    #expect(lines.contains { $0.hasPrefix("2 txt \"rate limit exceeded (429)\" ") && $0.hasSuffix(" ocr") })
    #expect(registry[1]?.isBehind == true)
}

@Test func onlyElementsOnTheGivenScreenAreListed() {
    let otherScreen = axElement("Elsewhere", frame: shareFrame, displayID: 2)
    let registry = GroundingFusion.buildRegistry(
        screens: [ScreenGroundingInput(frame: fusionFrame(), isCursorScreen: false,
                                       axElements: [otherScreen, axElement("Share", frame: archiveFrame)], ocrLines: [])],
        cursorCG: CGPoint(x: 0, y: 0),
        windowStack: fusionStack()
    )
    let lines = ElementListWriter.lines(header: "H", frame: fusionFrame(), registry: registry, cursorCG: nil, isCursorScreen: false)
    #expect(!lines.contains { $0.contains("Elsewhere") })
    #expect(lines.contains { $0.contains("\"Share\"") })
}
