import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

private let occlusionDisplay = DisplayInfo(
    displayID: 1,
    localizedName: "Main",
    boundsCG: CGRect(x: 0, y: 0, width: 3440, height: 1440),
    visibleCG: CGRect(x: 0, y: 30, width: 3440, height: 1410),
    frameAppKit: CGRect(x: 0, y: 0, width: 3440, height: 1440),
    isMain: true
)

private let ownProcess: pid_t = 1

private func window(
    id: CGWindowID,
    pid: pid_t,
    layer: Int = 0,
    bounds: CGRect,
    alpha: Double = 1,
    title: String? = nil
) -> WindowInfo {
    WindowInfo(windowID: id, processIdentifier: pid, layer: layer, boundsCG: bounds, alpha: alpha, ownerName: "App\(pid)", title: title)
}

private func stack(_ windows: [WindowInfo]) -> WindowStack {
    WindowStack(windows: windows, ownProcessIdentifier: ownProcess, displays: [occlusionDisplay])
}

private let fullWidthBounds = CGRect(x: 0, y: 0, width: 3440, height: 1440)

// MARK: - isBehind

@Test func menuBarWindowAboveLayerZeroDoesNotHideElementsBehindIt() {
    // Layer 24 (menu bar), full width, pid 500. Nothing else covers the point.
    let windows = stack([
        window(id: 1, pid: 500, layer: 24, bounds: CGRect(x: 0, y: 0, width: 3440, height: 30)),
    ])
    #expect(windows.isBehind(point: CGPoint(x: 100, y: 15), processIdentifier: 42) == false)
}

@Test func nearlyFullWidthOverlayAboveLayerZeroIsIgnored() {
    // Layer 25 full-screen tint, pid 600, in front of pid 42's normal window.
    let windows = stack([
        window(id: 1, pid: 600, layer: 25, bounds: fullWidthBounds),
        window(id: 2, pid: 42, layer: 0, bounds: CGRect(x: 100, y: 100, width: 500, height: 500)),
    ])
    #expect(windows.isBehind(point: CGPoint(x: 150, y: 150), processIdentifier: 42) == false)
}

@Test func menuWindowOfAnotherAppHidesElementBehindIt() {
    // Layer 101 menu of pid 700 in front of pid 42's normal window.
    let windows = stack([
        window(id: 1, pid: 700, layer: 101, bounds: CGRect(x: 100, y: 100, width: 200, height: 300)),
        window(id: 2, pid: 42, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
    ])
    #expect(windows.isBehind(point: CGPoint(x: 150, y: 150), processIdentifier: 42) == true)
}

@Test func overlappingWindowOfAnotherAppIsBehindButSameAppIsNot() {
    let otherAppFront = stack([
        window(id: 1, pid: 43, layer: 0, bounds: CGRect(x: 100, y: 100, width: 300, height: 300)),
        window(id: 2, pid: 42, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
    ])
    #expect(otherAppFront.isBehind(point: CGPoint(x: 150, y: 150), processIdentifier: 42) == true)

    let sameAppFront = stack([
        window(id: 1, pid: 42, layer: 0, bounds: CGRect(x: 100, y: 100, width: 300, height: 300)),
        window(id: 2, pid: 43, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
    ])
    #expect(sameAppFront.isBehind(point: CGPoint(x: 150, y: 150), processIdentifier: 42) == false)
}

@Test func invisibleWindowsAndClickyOwnWindowsAreDropped() {
    let windowStack = stack([
        window(id: 1, pid: 43, layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), alpha: 0),
        window(id: 2, pid: ownProcess, layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500)),
        window(id: 3, pid: 44, layer: 0, bounds: CGRect(x: 0, y: 0, width: 0, height: 500)),
        window(id: 4, pid: 42, layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500)),
    ])
    #expect(windowStack.windows.count == 1)
    #expect(windowStack.windows.first?.windowID == 4)
    #expect(windowStack.zIndex(of: 4) == 0)
    #expect(windowStack.zIndex(of: 1) == nil)
    // Invisible windows never hide anything.
    #expect(windowStack.isBehind(point: CGPoint(x: 10, y: 10), processIdentifier: 42) == false)
}

// MARK: - matchWindow

@Test func matchWindowAcceptsBoundsWithinOnePoint() {
    let windowStack = stack([
        window(id: 10, pid: 42, bounds: CGRect(x: 100, y: 100, width: 800, height: 600), title: "Inbox"),
        window(id: 11, pid: 42, bounds: CGRect(x: 900, y: 100, width: 400, height: 400), title: "Notes"),
    ])
    let match = windowStack.matchWindow(processIdentifier: 42, axBoundsCG: CGRect(x: 100.5, y: 99.5, width: 799.5, height: 600.5), axTitle: nil)
    #expect(match?.windowID == 10)
}

@Test func matchWindowFallsBackToTitleWhenBoundsDiffer() {
    let windowStack = stack([
        window(id: 10, pid: 42, bounds: CGRect(x: 100, y: 100, width: 800, height: 600), title: "Inbox"),
        window(id: 11, pid: 42, bounds: CGRect(x: 900, y: 100, width: 400, height: 400), title: "Notes"),
    ])
    let match = windowStack.matchWindow(processIdentifier: 42, axBoundsCG: CGRect(x: 300, y: 300, width: 100, height: 100), axTitle: "Notes")
    #expect(match?.windowID == 11)
}

@Test func matchWindowReturnsNilForAnotherProcessOrNoMatch() {
    let windowStack = stack([
        window(id: 10, pid: 42, bounds: CGRect(x: 100, y: 100, width: 800, height: 600), title: "Inbox"),
    ])
    // Right bounds and title, wrong pid.
    #expect(windowStack.matchWindow(processIdentifier: 99, axBoundsCG: CGRect(x: 100, y: 100, width: 800, height: 600), axTitle: "Inbox") == nil)
    // Nothing matches bounds or title.
    #expect(windowStack.matchWindow(processIdentifier: 42, axBoundsCG: CGRect(x: 0, y: 0, width: 10, height: 10), axTitle: "Missing") == nil)
    #expect(windowStack.matchWindow(processIdentifier: 42, axBoundsCG: CGRect(x: 0, y: 0, width: 10, height: 10), axTitle: nil) == nil)
}
