import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// MARK: - Fixtures

private let resolverDisplay = DisplayInfo(
    displayID: 1,
    localizedName: "Main",
    boundsCG: CGRect(x: 0, y: 0, width: 3440, height: 1440),
    visibleCG: CGRect(x: 0, y: 30, width: 3440, height: 1410),
    frameAppKit: CGRect(x: 0, y: 0, width: 3440, height: 1440),
    isMain: true
)

/// 3440x1440 points shown as 2000x837 model pixels (scale 1.72).
private let resolverFrame = CaptureFrame(
    display: resolverDisplay,
    screenNumber: 1,
    native: PixelSize(width: 3440, height: 1440),
    model: PixelSize(width: 2000, height: 837)
)

/// Live lookups from the test: elements keep their registry frame unless
/// their label is in `goneLabels`; text ranges are never found in AX.
private final class MockLookup: GroundingLiveLookup {
    var goneLabels: Set<String> = []

    func refreshedFrame(of element: GroundingElement) -> CGRect? {
        if let label = element.label, goneLabels.contains(label) {
            return nil
        }
        return element.visibleFrameCG
    }

    func textRanges(of query: String, in element: GroundingElement) -> [(frameCG: CGRect, isFuzzy: Bool)] {
        []
    }
}

private func accessibilityElement(
    _ label: String?,
    role: GroundingRole = .button,
    frame: CGRect,
    windowZIndex: Int = 0
) -> GroundingElement {
    GroundingElement(
        role: role,
        label: label,
        frameCG: frame,
        processIdentifier: 42,
        windowID: 10,
        windowTitle: "Inbox",
        applicationName: "Mail",
        displayID: 1,
        isInteractive: true,
        isInFrontWindow: true,
        source: .accessibility,
        windowZIndex: windowZIndex
    )
}

private func ocrLine(_ text: String, frame: CGRect) -> OCRLine {
    OCRLine(text: text, frameCG: frame, displayID: 1)
}

private func parseTag(_ raw: String) throws -> ParsedTag {
    try #require(MarkTagParser.parse(raw))
}

private func makeResolver(
    registry: ElementRegistry,
    lookup: GroundingLiveLookup = MockLookup(),
    cursor: CGPoint = CGPoint(x: 0, y: 0)
) -> TargetResolver {
    TargetResolver(
        registry: registry,
        framesByScreenNumber: [1: resolverFrame],
        cursorCG: cursor,
        windowStack: nil,
        lookup: lookup
    )
}

// MARK: - Element targets

@Test func elementTargetResolvesToTheRefreshedElementFrame() throws {
    var registry = ElementRegistry()
    let shareFrame = CGRect(x: 1000, y: 400, width: 100, height: 40)
    _ = registry.append(accessibilityElement("Share", frame: shareFrame))

    let resolved = try #require(makeResolver(registry: registry).resolve(try parseTag("[POINT:#1:Share]")))

    #expect(resolved.method == .element)
    #expect(resolved.confidence == 0.98)
    #expect(resolved.elementID == 1)
    #expect(resolved.frameCG == shareFrame)
    #expect(resolved.pointCG == shareFrame.center)
}

@Test func goneElementFallsBackToItsLabelInTheOCRText() throws {
    var registry = ElementRegistry()
    _ = registry.append(accessibilityElement("Share", frame: CGRect(x: 100, y: 100, width: 100, height: 40)))
    let ocrFrame = CGRect(x: 500, y: 500, width: 60, height: 20)
    registry.allOCRLines = [ocrLine("Share", frame: ocrFrame)]
    let lookup = MockLookup()
    lookup.goneLabels = ["Share"]

    let resolved = try #require(makeResolver(registry: registry, lookup: lookup).resolve(try parseTag("[POINT:#1:Share]")))

    #expect(resolved.method == .textExact)
    #expect(resolved.frameCG == ocrFrame)
}

@Test func farHintWithMismatchedNameSwitchesToAWellMatchingElementNearTheHint() throws {
    var registry = ElementRegistry()
    // Element 1 is "Save", far away; the model's name and hint point at "Download".
    _ = registry.append(accessibilityElement("Save", frame: CGRect(x: 100, y: 100, width: 80, height: 30)))
    _ = registry.append(accessibilityElement("Download", frame: CGRect(x: 2550, y: 1010, width: 100, height: 40)))

    // Hint (1500, 600) model px is about (2581, 1033) points, next to element 2.
    let resolved = try #require(makeResolver(registry: registry).resolve(try parseTag("[POINT:#1@1500,600:Download]")))

    #expect(resolved.method == .elementAlternative)
    #expect(resolved.elementID == 2)
    #expect(resolved.label == "Download")
}

@Test func unlabelledElementIsNeverOverriddenByAHint() throws {
    var registry = ElementRegistry()
    let unlabelledFrame = CGRect(x: 100, y: 100, width: 80, height: 30)
    _ = registry.append(accessibilityElement(nil, frame: unlabelledFrame))
    _ = registry.append(accessibilityElement("Download", frame: CGRect(x: 2550, y: 1010, width: 100, height: 40)))

    let resolved = try #require(makeResolver(registry: registry).resolve(try parseTag("[POINT:#1@1500,600:Download]")))

    #expect(resolved.method == .element)
    #expect(resolved.elementID == 1)
    #expect(resolved.frameCG == unlabelledFrame)
}

@Test func spanTargetIsTheUnionOfTheFramesInRange() throws {
    var registry = ElementRegistry()
    _ = registry.append(accessibilityElement("Other", frame: CGRect(x: 900, y: 900, width: 10, height: 10)))
    _ = registry.append(accessibilityElement("A", frame: CGRect(x: 100, y: 100, width: 50, height: 20)))
    _ = registry.append(accessibilityElement("B", frame: CGRect(x: 160, y: 100, width: 50, height: 20)))
    _ = registry.append(accessibilityElement("C", frame: CGRect(x: 220, y: 100, width: 50, height: 20)))

    let resolved = try #require(makeResolver(registry: registry).resolve(try parseTag("[MARK:box:#2-#4]")))

    #expect(resolved.method == .span)
    #expect(resolved.confidence == 0.95)
    #expect(resolved.frameCG == CGRect(x: 100, y: 100, width: 170, height: 20))
    #expect(resolved.pointCG == CGRect(x: 100, y: 100, width: 170, height: 20).center)
}

// MARK: - Text targets

@Test func exactTextBeatsAFuzzyMatch() throws {
    var registry = ElementRegistry()
    let exactFrame = CGRect(x: 300, y: 100, width: 80, height: 20)
    // "Setings" is one edit away from "Settings" (fuzzy), and listed first.
    registry.allOCRLines = [
        ocrLine("Setings", frame: CGRect(x: 100, y: 100, width: 80, height: 20)),
        ocrLine("Settings", frame: exactFrame),
    ]

    let resolved = try #require(makeResolver(registry: registry).resolve(try parseTag("[POINT:\"Settings\"]")))

    #expect(resolved.method == .textExact)
    #expect(resolved.confidence == 0.95)
    #expect(resolved.frameCG == exactFrame)
}

@Test func occurrenceNumberPicksTheSecondMatchInReadingOrder() throws {
    var registry = ElementRegistry()
    let first = CGRect(x: 100, y: 100, width: 40, height: 20)
    let second = CGRect(x: 400, y: 100, width: 40, height: 20)
    let third = CGRect(x: 100, y: 300, width: 40, height: 20)
    // Listed out of reading order on purpose.
    registry.allOCRLines = [
        ocrLine("Save", frame: third),
        ocrLine("Save", frame: second),
        ocrLine("Save", frame: first),
    ]

    let resolved = try #require(makeResolver(registry: registry).resolve(try parseTag("[POINT:\"Save\"~2]")))

    #expect(resolved.frameCG == second)
}

@Test func textInsideScopeElementRestrictsTheSearch() throws {
    var registry = ElementRegistry()
    _ = registry.append(accessibilityElement("Panel", role: .cell, frame: CGRect(x: 500, y: 500, width: 300, height: 300)))
    let insideFrame = CGRect(x: 600, y: 600, width: 40, height: 20)
    registry.allOCRLines = [
        ocrLine("Save", frame: CGRect(x: 100, y: 100, width: 40, height: 20)),
        ocrLine("Save", frame: insideFrame),
    ]

    let resolved = try #require(makeResolver(registry: registry).resolve(try parseTag("[POINT:\"Save\" in #1]")))

    #expect(resolved.frameCG == insideFrame)
}

// MARK: - Point and box targets

@Test func pointInsideASmallMatchingElementSnapsToIt() throws {
    var registry = ElementRegistry()
    let shareFrame = CGRect(x: 1000, y: 400, width: 100, height: 40)
    _ = registry.append(accessibilityElement("Share", frame: shareFrame))

    // Model (610, 244) is about (1050, 421) points: inside the element.
    let resolved = try #require(makeResolver(registry: registry).resolve(try parseTag("[POINT:610,244:Share]")))

    #expect(resolved.method == .snapped)
    #expect(resolved.confidence == 0.85)
    #expect(resolved.elementID == 1)
    #expect(resolved.frameCG == shareFrame)
}

@Test func pointFarFromEverythingStaysRaw() throws {
    var registry = ElementRegistry()
    _ = registry.append(accessibilityElement("Share", frame: CGRect(x: 100, y: 100, width: 100, height: 40)))

    let resolved = try #require(makeResolver(registry: registry).resolve(try parseTag("[POINT:1500,600]")))

    #expect(resolved.method == .raw)
    #expect(resolved.confidence == 0.5)
    #expect(resolved.elementID == nil)
}

@Test func boxTargetSnapsToTheElementUnderItsCentre() throws {
    var registry = ElementRegistry()
    _ = registry.append(accessibilityElement("Share", frame: CGRect(x: 1000, y: 370, width: 200, height: 40)))

    // Box (600, 200, 100, 50) model px: its centre is about (1118, 387) points.
    let resolved = try #require(makeResolver(registry: registry).resolve(try parseTag("[MARK:box:600,200,100,50:Share]")))

    #expect(resolved.method == .snapped)
    #expect(resolved.elementID == 1)
}

// MARK: - Hit test verification

private func resolvedTarget(pid: pid_t, node: MockNode, point: CGPoint, label: String) -> ResolvedTarget {
    ResolvedTarget(
        frameCG: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10),
        pointCG: point,
        confidence: 0.98,
        method: .element,
        elementID: 1,
        displayID: 1,
        label: label,
        processIdentifier: pid,
        axNode: AXNodeReference(node),
        verified: nil,
        occludedByPID: nil
    )
}

@Test func hitTestConfirmsATargetThatIsOnTop() {
    let button = MockNode(role: "AXButton", title: "Share", frame: CGRect(x: 100, y: 100, width: 100, height: 40))
    let window = MockNode(role: "AXWindow", title: "Inbox", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), children: [button])
    let app = MockNode(role: "AXApplication", title: "Mail", pid: 42, children: [window])
    let ax = MockAXQuerying(apps: [app])

    var target = resolvedTarget(pid: 42, node: button, point: CGPoint(x: 150, y: 120), label: "Share")
    HitTestVerifier.verify(&target, ax: ax, ownProcessIdentifier: 1, windowStack: nil)

    #expect(target.verified == true)
    #expect(target.occludedByPID == nil)
}

@Test func hitTestReportsAnotherAppsWindowOnTopAsOccluding() {
    let button = MockNode(role: "AXButton", title: "Share", frame: CGRect(x: 100, y: 100, width: 100, height: 40))
    let window = MockNode(role: "AXWindow", title: "Inbox", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), children: [button])
    let mail = MockNode(role: "AXApplication", title: "Mail", pid: 42, children: [window])
    // Pid 700's window sits in front of the button.
    let coverWindow = MockNode(role: "AXWindow", title: "Cover", frame: CGRect(x: 80, y: 80, width: 300, height: 200))
    let cover = MockNode(role: "AXApplication", title: "Cover app", pid: 700, children: [coverWindow])
    let ax = MockAXQuerying(apps: [cover, mail])

    var target = resolvedTarget(pid: 42, node: button, point: CGPoint(x: 150, y: 120), label: "Share")
    HitTestVerifier.verify(&target, ax: ax, ownProcessIdentifier: 1, windowStack: nil)

    #expect(target.verified == false)
    #expect(target.occludedByPID == 700)
}

// MARK: - Explicit box on text inside a card

@Test func explicitBoxOnOCRTextSnapsToTheContainingCard() throws {
    var registry = ElementRegistry()
    let card = CGRect(x: 985, y: 774, width: 237, height: 237)
    _ = registry.append(accessibilityElement("View M2N3G9024", role: .link, frame: card))
    _ = registry.append(accessibilityElement("Page", role: .window, frame: CGRect(x: 0, y: 0, width: 3440, height: 1440)))
    let printedLabel = CGRect(x: 1040, y: 920, width: 110, height: 14)
    registry.allOCRLines = [ocrLine("M2N3G9024", frame: printedLabel)]
    let resolver = makeResolver(registry: registry)

    let boxed = try #require(resolver.resolve(try parseTag("[MARK:box:\"M2N3G9024\":M2N3G9024|wrong photo]")))
    #expect(boxed.method == .textCard)
    #expect(boxed.frameCG == card && boxed.elementID == 1)

    // Not for other styles, an unstyled mark or a point: those keep the words.
    for raw in ["[MARK:underline:\"M2N3G9024\"]", "[MARK:circle:\"M2N3G9024\"]", "[POINT:\"M2N3G9024\":photo]"] {
        let resolved = try #require(resolver.resolve(try parseTag(raw)))
        #expect(resolved.method == .textExact && resolved.frameCG == printedLabel, "\(raw)")
    }
}

/// A live run boxed only the photos of three product cards ([MARK:box:#106:Crimson Kettle|$129]):
/// a box on a product photo now covers the photo plus the name / price / button stacked under it.
@Test func explicitBoxOnAProductPhotoCoversTheStackedProduct() throws {
    var registry = ElementRegistry()
    let photo = CGRect(x: 3838, y: 405, width: 272, height: 90)
    _ = registry.append(accessibilityElement("Crimson Kettle", role: .image, frame: photo))
    _ = registry.append(accessibilityElement("Crimson Kettle", role: .text, frame: CGRect(x: 3838, y: 505, width: 107, height: 17)))
    _ = registry.append(accessibilityElement("$129", role: .text, frame: CGRect(x: 3838, y: 532, width: 36, height: 18)))
    _ = registry.append(accessibilityElement("Add to cart", role: .button, frame: CGRect(x: 3838, y: 561, width: 272, height: 32)))
    // The next card's photo, further down, and a neighbour column: not part of it.
    _ = registry.append(accessibilityElement("Scarlet Pitcher", role: .image, frame: CGRect(x: 3838, y: 636, width: 272, height: 90)))
    _ = registry.append(accessibilityElement("$32", role: .text, frame: CGRect(x: 3522, y: 532, width: 27, height: 18)))
    let resolver = makeResolver(registry: registry)

    let boxed = try #require(resolver.resolve(try parseTag("[MARK:box:#1:Crimson Kettle|$129]")))
    #expect(boxed.method == .imageCard)
    #expect(boxed.frameCG == CGRect(x: 3838, y: 405, width: 272, height: 188))

    // A point or circle on the photo keeps the photo.
    let pointed = try #require(resolver.resolve(try parseTag("[POINT:#1:Crimson Kettle]")))
    #expect(pointed.frameCG == photo)
}

@Test func explicitBoxOnALonePhotoKeepsThePhoto() throws {
    var registry = ElementRegistry()
    let photo = CGRect(x: 100, y: 100, width: 300, height: 200)
    _ = registry.append(accessibilityElement("Sunset", role: .image, frame: photo))
    let boxed = try #require(makeResolver(registry: registry).resolve(try parseTag("[MARK:box:#1:Sunset]")))
    #expect(boxed.frameCG == photo)
}
