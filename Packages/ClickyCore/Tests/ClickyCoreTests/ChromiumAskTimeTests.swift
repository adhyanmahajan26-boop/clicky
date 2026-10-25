import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// Turn 20261025-161216-42555df1: a frontmost Chrome (second instance, temp
// profile) had only its 15 toolbar elements in the tree on the first ask;
// the page's buttons (aria-label "Share") never made the element list.

private let coverageDisplay = DisplayInfo(displayID: 1, localizedName: "Main", boundsCG: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                          visibleCG: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                          frameAppKit: CGRect(x: 0, y: 0, width: 1600, height: 1000), isMain: true)

private func appWindow(_ windowID: CGWindowID, pid: pid_t, bounds: CGRect, layer: Int = 0) -> WindowInfo {
    WindowInfo(windowID: windowID, processIdentifier: pid, layer: layer, boundsCG: bounds, alpha: 1, ownerName: "App \(pid)", title: nil)
}

private func textElement(_ label: String?, value: String? = nil, pid: pid_t, windowID: CGWindowID?, frame: CGRect,
                         role: GroundingRole = .text) -> GroundingElement {
    GroundingElement(role: role, label: label, value: value, frameCG: frame, processIdentifier: pid, windowID: windowID, displayID: 1,
                     isInteractive: role != .text, source: .accessibility)
}

// MARK: - Ask-time enhanced UI

private typealias Activation = EnhancedUserInterfacePolicy.WebContentActivation
private let t0 = Date(timeIntervalSince1970: 1_000)

@Test func askTimeWritesUnlessAWriteIsStillBeingBuilt() {
    var activation = Activation()
    #expect(activation.shouldWriteAtAsk(at: t0))
    #expect(activation.askWaitSeconds(at: t0) == EnhancedUserInterfacePolicy.askTimeWaitSeconds)
    activation.recordWrite(at: t0)
    // Chrome needs ~2 s: an ask 1 s later waits for that write, it doesn't restart it.
    #expect(!activation.shouldWriteAtAsk(at: t0.addingTimeInterval(1)))
    #expect(activation.isWritePending(at: t0.addingTimeInterval(1)))
    // Long after the cycle: write again.
    #expect(activation.shouldWriteAtAsk(at: t0.addingTimeInterval(Activation.followUpDuration + 1)))
}

@Test func followUpPollsRewritesOnceAndReportsTheReadyPage() {
    var activation = Activation()
    activation.recordWrite(at: t0)
    #expect(activation.followUpStep(webContentState: .noWebArea, at: t0.addingTimeInterval(0.3)) == .poll(after: Activation.pollInterval))
    // Launch-time write lost: nothing by 3 s → write again, once.
    #expect(activation.followUpStep(webContentState: .noWebArea, at: t0.addingTimeInterval(3.1)) == .rewrite)
    activation.recordWrite(at: t0.addingTimeInterval(3.1), isRewrite: true)
    #expect(activation.followUpStep(webContentState: .emptyWebArea, at: t0.addingTimeInterval(3.4)) == .poll(after: Activation.pollInterval))
    #expect(activation.followUpStep(webContentState: .ready, at: t0.addingTimeInterval(5.2)) == .ready)
    #expect(activation.lastReadyAt == t0.addingTimeInterval(5.2))
    #expect(!activation.isWritePending(at: t0.addingTimeInterval(5.3)))
}

@Test func repeatedEmptyCyclesBackOffForAWhileNotForever() {
    var activation = Activation()
    var clock = t0
    for _ in 0..<Activation.failedCyclesBeforeBackoff {
        activation.recordWrite(at: clock)
        clock = clock.addingTimeInterval(Activation.followUpDuration)
        #expect(activation.followUpStep(webContentState: .noWebArea, at: clock) == .gaveUp)
        clock = clock.addingTimeInterval(1)
    }
    // Backed off: asks don't wait (they still write).
    #expect(activation.isBackedOff(at: clock))
    #expect(activation.askWaitSeconds(at: clock) == 0)
    #expect(activation.shouldWriteAtAsk(at: clock))
    // Time-based: after the backoff the ask waits again.
    let later = clock.addingTimeInterval(Activation.backoffSeconds + 1)
    #expect(!activation.isBackedOff(at: later))
    #expect(activation.askWaitSeconds(at: later) == EnhancedUserInterfacePolicy.askTimeWaitSeconds)
    // Coming forward again lifts it at once.
    activation.recordWrite(at: clock, clearsBackoff: true)
    #expect(!activation.isBackedOff(at: clock))
}

@Test func followUpWithoutAWriteStops() {
    var activation = Activation()
    #expect(activation.followUpStep(webContentState: .noWebArea, at: t0) == .gaveUp)
}

/// Chrome 155 as axfind saw it (2026-10-25): the page hangs off six nested
/// AXGroups under the window; buttons are named by aria-label (AXDescription).
@Test func walkerReachesChromePageButtonsUnderTheNestedGroups() throws {
    let windowFrame = CGRect(x: 400, y: 300, width: 900, height: 600)
    let contentFrame = CGRect(x: 400, y: 332, width: 900, height: 568)
    let webArea = MockNode(role: "AXWebArea", title: "AX Probe", frame: contentFrame, children: [
        MockNode(role: "AXHeading", title: "Probe heading", frame: CGRect(x: 420, y: 350, width: 300, height: 37)),
        MockNode(role: "AXButton", desc: "Share this page", frame: CGRect(x: 428, y: 439, width: 25, height: 22)),
        MockNode(role: "AXButton", title: "Add to cart", frame: CGRect(x: 457, y: 439, width: 90, height: 22)),
        MockNode(role: "AXLink", desc: "Read the docs", frame: CGRect(x: 551, y: 441, width: 100, height: 18)),
    ])
    var content: MockNode = webArea
    for _ in 0..<6 { content = MockNode(role: "AXGroup", frame: contentFrame, children: [content]) }
    let window = MockNode(role: "AXWindow", title: "AX Probe", frame: windowFrame, children: [
        MockNode(role: "AXButton", desc: "close", frame: CGRect(x: 408, y: 308, width: 16, height: 16)), content,
    ])
    let app = MockNode(role: "AXApplication", title: "Google Chrome", pid: 501, children: [window])
    let ax = MockAXQuerying(apps: [app])
    #expect(EnhancedUserInterfacePolicy.webContentState(ax: ax, applicationNode: ax.applicationNode(processIdentifier: 501)) == .ready)

    let display = DisplayInfo(displayID: 1, localizedName: "Main", boundsCG: CGRect(x: 0, y: 0, width: 3440, height: 1440),
                              visibleCG: CGRect(x: 0, y: 0, width: 3440, height: 1440),
                              frameAppKit: CGRect(x: 0, y: 0, width: 3440, height: 1440), isMain: true)
    let stack = WindowStack(windows: [WindowInfo(windowID: 9, processIdentifier: 501, layer: 0, boundsCG: windowFrame, alpha: 1,
                                                 ownerName: "Google Chrome", title: "AX Probe")],
                            ownProcessIdentifier: 1, displays: [display])
    var published: [GroundingElement] = []
    try AXEnumerator.walk(request: AXEnumerationRequest(processIdentifier: 501, applicationName: "Google Chrome", scope: .frontApplication,
                                                        maximumDepth: 40, allowsValues: true),
                          ax: ax, windowStack: stack, shouldStop: { false }, publish: { published.append($0) })
    let labels = Set(published.compactMap(\.label))
    #expect(labels.isSuperset(of: ["Probe heading", "Share this page", "Add to cart", "Read the docs"]))
}

private func chromeTree(webAreaChildren: [MockNode]) -> (app: MockNode, webArea: MockNode) {
    let webArea = MockNode(role: "AXWebArea", title: "Plan draft", children: webAreaChildren)
    let window = MockNode(role: "AXWindow", title: "Plan draft - Google Chrome", children: [
        MockNode(role: "AXGroup", children: [
            MockNode(role: "AXToolbar", children: [MockNode(role: "AXButton", title: "Back"), MockNode(role: "AXTextField", title: "Address and search bar")]),
            MockNode(role: "AXGroup", children: [MockNode(role: "AXScrollArea", children: [webArea])]),
        ]),
    ])
    let app = MockNode(role: "AXApplication", title: "Google Chrome", pid: 501, children: [window])
    return (app, webArea)
}

@Test func webContentStateFindsTheWebAreaAndItsChildren() {
    let (emptyApp, _) = chromeTree(webAreaChildren: [])
    let emptyAX = MockAXQuerying(apps: [emptyApp])
    #expect(EnhancedUserInterfacePolicy.webContentState(ax: emptyAX, applicationNode: emptyAX.applicationNode(processIdentifier: 501)) == .emptyWebArea)

    let (readyApp, _) = chromeTree(webAreaChildren: [MockNode(role: "AXButton", desc: "Share")])
    let readyAX = MockAXQuerying(apps: [readyApp])
    #expect(EnhancedUserInterfacePolicy.webContentState(ax: readyAX, applicationNode: readyAX.applicationNode(processIdentifier: 501)) == .ready)

    let noWebApp = MockNode(role: "AXApplication", pid: 502, children: [MockNode(role: "AXWindow", children: [MockNode(role: "AXButton", title: "OK")])])
    let noWebAX = MockAXQuerying(apps: [noWebApp])
    #expect(EnhancedUserInterfacePolicy.webContentState(ax: noWebAX, applicationNode: noWebAX.applicationNode(processIdentifier: 502)) == .noWebArea)
}

@Test func waitForWebContentReturnsOnceThePageTreeIsBuilt() {
    let (app, webArea) = chromeTree(webAreaChildren: [])
    let ax = MockAXQuerying(apps: [app])
    var clock = Date(timeIntervalSince1970: 0)
    var sleeps = 0
    // Chromium builds the page's tree ~75 ms after the flag is set.
    let result = EnhancedUserInterfacePolicy.waitForWebContent(ax: ax, applicationNode: ax.applicationNode(processIdentifier: 501),
                                                               now: { clock }) { interval in
        sleeps += 1
        clock = clock.addingTimeInterval(interval)
        if sleeps == 3 { webArea.add(MockNode(role: "AXButton", desc: "Share")) }
    }
    #expect(result.state == .ready)
    #expect(sleeps == 3)
    #expect(abs(result.waitedSeconds - 0.075) < 1e-6)
}

@Test func waitForWebContentGivesUpAtTheDeadline() {
    // The ask-time wait is now 0.6 s (Chrome needs ~2 s; the rest is polled in the background).
    #expect(EnhancedUserInterfacePolicy.askTimeWaitSeconds == 0.6)
    let (app, _) = chromeTree(webAreaChildren: [])
    let ax = MockAXQuerying(apps: [app])
    var clock = Date(timeIntervalSince1970: 0)
    let result = EnhancedUserInterfacePolicy.waitForWebContent(ax: ax, applicationNode: ax.applicationNode(processIdentifier: 501),
                                                               now: { clock }) { clock = clock.addingTimeInterval($0) }
    #expect(result.state == .emptyWebArea)
    let limit: Double = EnhancedUserInterfacePolicy.askTimeWaitSeconds
    let poll: Double = EnhancedUserInterfacePolicy.askTimePollSeconds
    let waited: Double = result.waitedSeconds
    #expect(waited <= limit + 1e-6)
    #expect(waited >= limit - poll - 1e-6)
}

// MARK: - OCR coverage

@Test func coverageExcludesThePartAWindowInFrontHides() {
    // A trusted text area (pid 42, window 10) with another app's window
    // (pid 77, window 20, in front) over its right half.
    let windows = [appWindow(20, pid: 77, bounds: CGRect(x: 400, y: 0, width: 600, height: 600)),
                   appWindow(10, pid: 42, bounds: CGRect(x: 0, y: 0, width: 800, height: 800))]
    let windowStack = WindowStack(windows: windows, ownProcessIdentifier: 1, displays: [coverageDisplay])
    let editor = textElement(nil, pid: 42, windowID: 10, frame: CGRect(x: 100, y: 100, width: 500, height: 400), role: .textArea)

    let frames = OCRCoveragePlanner.coveringFramesCG(axElements: [editor], displayID: 1, windowStack: windowStack, trustedProcessIdentifiers: [42])

    #expect(frames == [CGRect(x: 100, y: 100, width: 300, height: 400)])
    #expect(!frames.contains { $0.intersects(windows[0].boundsCG) })
}

@Test func coverageWithoutAWindowIDStopsAtTheElementsOwnWindow() {
    let windows = [appWindow(20, pid: 77, bounds: CGRect(x: 0, y: 0, width: 150, height: 150)),
                   appWindow(10, pid: 42, bounds: CGRect(x: 0, y: 0, width: 800, height: 800)),
                   appWindow(30, pid: 88, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))]
    let windowStack = WindowStack(windows: windows, ownProcessIdentifier: 1, displays: [coverageDisplay])
    let label = textElement("Quarterly totals by region", pid: 42, windowID: nil, frame: CGRect(x: 100, y: 100, width: 200, height: 20))

    let frames = OCRCoveragePlanner.coveringFramesCG(axElements: [label], displayID: 1, windowStack: windowStack, trustedProcessIdentifiers: [42])

    // Window 20 (in front) hides its left 50 pt; window 30 is behind.
    #expect(frames == [CGRect(x: 150, y: 100, width: 150, height: 20)])
}

@Test func aBigTextFrameWithAFewCharactersDoesNotCoverItsWholeFrame() {
    let windowStack = WindowStack(windows: [appWindow(10, pid: 42, bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000))],
                                  ownProcessIdentifier: 1, displays: [coverageDisplay])
    let bigLabel = textElement("Share", pid: 42, windowID: 10, frame: CGRect(x: 0, y: 100, width: 1200, height: 700))
    let paragraph = textElement(String(repeating: "word ", count: 200), pid: 42, windowID: 10, frame: CGRect(x: 0, y: 0, width: 600, height: 300))
    let smallField = textElement("Address and search bar", value: "127.0.0.1:8793/toolbar.html", pid: 42, windowID: 10,
                                 frame: CGRect(x: 200, y: 40, width: 600, height: 20), role: .textField)

    let frames = OCRCoveragePlanner.coveringFramesCG(axElements: [bigLabel, paragraph, smallField], displayID: 1, windowStack: windowStack,
                                                     trustedProcessIdentifiers: [42])

    #expect(frames == [paragraph.visibleFrameCG, smallField.visibleFrameCG])
}

@Test func uncoveredPageRegionIsPlannedForOCR() {
    // The page area (no AX text over it) with ink must be OCRed even though
    // the address bar above it is covered.
    let width = 1024, height = 768
    var pixels = [UInt8](repeating: 250, count: (width / 8) * (height / 8))
    for row in 40..<60 { for column in 20..<100 where column % 3 == 0 { pixels[row * (width / 8) + column] = 20 } }
    let gray = GrayImage(width: width / 8, height: height / 8, pixels: pixels, nativePixelsPerPixel: 8)
    let addressBarPx = CGRect(x: 0, y: 0, width: 1024, height: 64)

    let plan = OCRCoveragePlanner.plan(imageWidthPx: width, imageHeightPx: height, coveredRectsPx: [addressBarPx], grayImage: gray)

    let inkRegion = CGRect(x: 160, y: 320, width: 640, height: 160)
    #expect(plan.regionsPx.contains { $0.intersects(inkRegion) })
}

@Test func subtractSplitsARectAroundHoles() {
    let pieces = OCRCoveragePlanner.subtract([CGRect(x: 40, y: 40, width: 20, height: 20)], from: CGRect(x: 0, y: 0, width: 100, height: 100))
    let totalArea: CGFloat = pieces.reduce(CGFloat(0)) { $0 + $1.area }
    #expect(totalArea == 9600)
    #expect(!pieces.contains { $0.intersects(CGRect(x: 41, y: 41, width: 18, height: 18)) })
    #expect(OCRCoveragePlanner.subtract([CGRect(x: -10, y: -10, width: 200, height: 200)], from: CGRect(x: 0, y: 0, width: 50, height: 50)).isEmpty)
}
