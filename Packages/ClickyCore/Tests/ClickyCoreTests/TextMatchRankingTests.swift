import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// Regression for turn 20261025-161310-2311ea8c: [POINT:"Submit":Submit:screen3]
// resolved (textExact) to the "submit" inside the Chrome address bar text
// "127.0.0.1:8793/submit_form.html" instead of the blue Submit button.

// MARK: - Fixtures (screen 3 of that turn)

private let screen3Display = DisplayInfo(
    displayID: 5,
    localizedName: "DELL S2725QC (1)",
    boundsCG: CGRect(x: 3440, y: 198, width: 1920, height: 1080),
    visibleCG: CGRect(x: 3440, y: 198, width: 1920, height: 1080),
    frameAppKit: CGRect(x: 3440, y: 162, width: 1920, height: 1080),
    isMain: false
)

private let screen3Frame = CaptureFrame(display: screen3Display, screenNumber: 3,
                                        native: PixelSize(width: 3840, height: 2160), model: PixelSize(width: 1456, height: 819))

/// Model px (1456x819) → CG.
private func cgRect(modelX: CGFloat, _ modelY: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    let scale = 1920.0 / 1456.0
    return CGRect(x: 3440 + modelX * scale, y: 198 + modelY * scale, width: width * scale, height: height * scale)
}

private let addressBarFrame = cgRect(modelX: 241, 116, 617, 18)
/// Where AXBoundsForRange put "submit" in the address bar (model px ≈ 337,126).
private let urlSubmitFrame = cgRect(modelX: 322, 117, 30, 17)
private let ocrURLFrame = cgRect(modelX: 245, 117, 200, 16)
private let submitButtonFrame = CGRect(x: 4297, y: 733, width: 85, height: 36)
private let ocrSubmitFrame = CGRect(x: 4316, y: 742, width: 46, height: 18)
private let cursorOnScreen1 = CGPoint(x: 1272, y: 461)

/// AX text range hits per element label.
private final class RangeLookup: GroundingLiveLookup {
    var rangesByLabel: [String: [(frameCG: CGRect, isFuzzy: Bool)]] = [:]

    func refreshedFrame(of element: GroundingElement) -> CGRect? { element.visibleFrameCG }

    func textRanges(of query: String, in element: GroundingElement) -> [(frameCG: CGRect, isFuzzy: Bool)] {
        guard let label = element.label, element.role == .textField || element.role == .text else { return [] }
        return rangesByLabel[label] ?? []
    }
}

private func chromeElement(_ label: String, role: GroundingRole, frame: CGRect, value: String? = nil) -> GroundingElement {
    GroundingElement(role: role, label: label, value: value, frameCG: frame, processIdentifier: 77, windowID: 900,
                     windowTitle: "Contact - Google Chrome", applicationName: "Google Chrome", displayID: 5,
                     isInteractive: true, isInFrontWindow: true, source: .accessibility, windowZIndex: 0)
}

private func contactPageRegistry(includesSubmitButton: Bool) -> (ElementRegistry, RangeLookup, buttonID: Int?) {
    var registry = ElementRegistry()
    _ = registry.append(chromeElement("Contact", role: .tab, frame: cgRect(modelX: 208, 77, 194, 31)))
    _ = registry.append(chromeElement("Reload", role: .button, frame: cgRect(modelX: 180, 112, 26, 26)))
    _ = registry.append(chromeElement("Address and search bar", role: .textField, frame: addressBarFrame,
                                      value: "127.0.0.1:8793/submit_form.html"))
    var buttonID: Int?
    if includesSubmitButton {
        buttonID = registry.append(chromeElement("Submit", role: .button, frame: submitButtonFrame))
    }
    registry.allOCRLines = [
        OCRLine(text: "Contact", frameCG: cgRect(modelX: 240, 84, 60, 14), displayID: 5),
        OCRLine(text: "127.0.0.1:8793/submit_form.html", frameCG: ocrURLFrame, displayID: 5),
        OCRLine(text: "Contact us", frameCG: CGRect(x: 3900, y: 450, width: 160, height: 30), displayID: 5),
        OCRLine(text: "Submit", frameCG: ocrSubmitFrame, displayID: 5),
    ]
    let lookup = RangeLookup()
    lookup.rangesByLabel["Address and search bar"] = [(urlSubmitFrame, false)]
    return (registry, lookup, buttonID)
}

private func resolver(_ registry: ElementRegistry, _ lookup: GroundingLiveLookup, cursor: CGPoint = cursorOnScreen1,
                      windowStack: WindowStack? = nil) -> TargetResolver {
    TargetResolver(registry: registry, framesByScreenNumber: [3: screen3Frame], cursorCG: cursor, windowStack: windowStack, lookup: lookup)
}

private func tag(_ raw: String) throws -> ParsedTag {
    try #require(MarkTagParser.parse(raw))
}

// MARK: - The turn

@Test func submitResolvesToTheOCRButtonTextNotTheURLInTheAddressBar() throws {
    // As logged: the page's AX tree wasn't there, only OCR saw the button.
    let (registry, lookup, _) = contactPageRegistry(includesSubmitButton: false)

    let resolved = try #require(resolver(registry, lookup).resolve(try tag(#"[POINT:"Submit":Submit:screen3]"#)))

    #expect(resolved.frameCG == ocrSubmitFrame)
    #expect(resolved.method == .textExact)
    #expect(submitButtonFrame.contains(resolved.pointCG))
}

@Test func submitPrefersTheAXButtonTitledSubmit() throws {
    let (registry, lookup, buttonID) = contactPageRegistry(includesSubmitButton: true)

    let resolved = try #require(resolver(registry, lookup).resolve(try tag(#"[POINT:"Submit":Submit:screen3]"#)))

    #expect(resolved.elementID == buttonID)
    #expect(resolved.frameCG == submitButtonFrame)
    #expect(resolved.method == .textExact)
}

@Test func aHitOnlyInsideAURLIsNeverTextExact() throws {
    var (registry, lookup, _) = contactPageRegistry(includesSubmitButton: false)
    registry.allOCRLines.removeAll { $0.text == "Submit" }

    let resolved = try #require(resolver(registry, lookup).resolve(try tag(#"[POINT:"Submit":Submit:screen3]"#)))

    #expect(resolved.frameCG == urlSubmitFrame)
    #expect(resolved.method != .textExact)
    #expect(resolved.confidence < 0.95)
}

@Test func windowStackMarksTheToolbarBandAsBrowserChrome() throws {
    let (registry, _, _) = contactPageRegistry(includesSubmitButton: false)
    let window = WindowInfo(windowID: 900, processIdentifier: 77, layer: 0, boundsCG: CGRect(x: 3500, y: 290, width: 1200, height: 800),
                            alpha: 1, ownerName: "Google Chrome", title: "Contact - Google Chrome")
    let windowStack = WindowStack(windows: [window], ownProcessIdentifier: 1, displays: [screen3Display])

    let bands = TextMatchClassifier.browserChromeBands(registry: registry, windowStack: windowStack)

    #expect(bands.count == 1)
    #expect(bands[0].contains(urlSubmitFrame.center))
    #expect(!bands[0].contains(ocrSubmitFrame.center))
}

@Test func pageTextBeatsTheSameWholeTextInTheTabStrip() throws {
    let (registry, lookup, _) = contactPageRegistry(includesSubmitButton: false)
    var pageRegistry = registry
    let pageHeadingFrame = CGRect(x: 3900, y: 500, width: 110, height: 30)
    pageRegistry.allOCRLines.append(OCRLine(text: "Contact", frameCG: pageHeadingFrame, displayID: 5))

    // The cursor is right by the tab, yet the page's "Contact" wins.
    let resolved = try #require(resolver(pageRegistry, lookup, cursor: CGPoint(x: 3700, y: 300)).resolve(try tag(#"[POINT:"Contact":Contact:screen3]"#)))

    #expect(resolved.frameCG == pageHeadingFrame)
}

@Test func caseExactWholeLineBeatsACaseFoldedOne() throws {
    var registry = ElementRegistry()
    let shoutedFrame = CGRect(x: 100, y: 100, width: 80, height: 20)
    let exactFrame = CGRect(x: 2000, y: 1000, width: 80, height: 20)
    registry.allOCRLines = [
        OCRLine(text: "SUBMIT", frameCG: shoutedFrame, displayID: 5),
        OCRLine(text: "Submit", frameCG: exactFrame, displayID: 5),
    ]

    let resolved = try #require(resolver(registry, RangeLookup(), cursor: CGPoint(x: 90, y: 90)).resolve(try tag(#"[POINT:"Submit":Submit:screen3]"#)))

    #expect(resolved.frameCG == exactFrame)
}

@Test func wordBoundaryHitBeatsAHitInsideAnIdentifier() throws {
    var registry = ElementRegistry()
    let identifierFrame = CGRect(x: 100, y: 100, width: 300, height: 20)
    let sentenceFrame = CGRect(x: 2000, y: 1000, width: 300, height: 20)
    registry.allOCRLines = [
        OCRLine(text: "deploy_button_id", frameCG: identifierFrame, displayID: 5),
        OCRLine(text: "Press Deploy to ship it", frameCG: sentenceFrame, displayID: 5),
    ]

    let resolved = try #require(resolver(registry, RangeLookup(), cursor: CGPoint(x: 90, y: 90)).resolve(try tag(#"[POINT:"Deploy":Deploy:screen3]"#)))

    #expect(sentenceFrame.contains(resolved.pointCG))
    #expect(resolved.method == .textExact)
}

// MARK: - Classifier

@Test func classifierRanksWholeTokenAndInToken() {
    let url = TextMatchClassifier.occurrences(of: "Submit", in: "127.0.0.1:8793/submit_form.html")
    #expect(url.count == 1)
    #expect(url.first?.quality == .inToken)
    #expect(url.first?.isCaseExact == false)

    let whole = TextMatchClassifier.occurrences(of: "Submit", in: "Submit")
    #expect(whole.first?.quality == .whole)
    #expect(whole.first?.isCaseExact == true)

    #expect(TextMatchClassifier.occurrences(of: "Submit", in: "  Submit →").first?.quality == .whole)
    #expect(TextMatchClassifier.occurrences(of: "submit", in: "Submit").first?.isCaseExact == false)
    #expect(TextMatchClassifier.occurrences(of: "Submit", in: "Click Submit.").first?.quality == .token)
    #expect(TextMatchClassifier.occurrences(of: "Submit", in: "Resubmit").first?.quality == .inToken)
    #expect(TextMatchClassifier.occurrences(of: "form", in: "submit_form.html").first?.quality == .inToken)
    #expect(TextMatchClassifier.occurrences(of: "html", in: "see submit_form.html").first?.quality == .inToken)
    #expect(TextMatchClassifier.occurrences(of: "Share", in: "Share / Export").first?.quality == .token)
}

@Test func addressBarAndTabsAreBrowserChromeOnlyInBrowsers() {
    #expect(TextMatchClassifier.isBrowserChrome(chromeElement("Address and search bar", role: .textField, frame: addressBarFrame)))
    #expect(TextMatchClassifier.isBrowserChrome(chromeElement("Contact", role: .tab, frame: .zero)))
    var settingsTab = chromeElement("General", role: .tab, frame: .zero)
    settingsTab.applicationName = "System Settings"
    #expect(!TextMatchClassifier.isBrowserChrome(settingsTab))
    #expect(!TextMatchClassifier.isBrowserChrome(chromeElement("Submit", role: .button, frame: .zero)))
}
