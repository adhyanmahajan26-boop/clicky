import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

private let display = DisplayInfo(displayID: 1, localizedName: "Built-in", boundsCG: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                  visibleCG: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                  frameAppKit: CGRect(x: 0, y: 0, width: 1470, height: 956), isMain: true)

private func window(_ windowID: CGWindowID, pid: pid_t, layer: Int = 0) -> WindowInfo {
    WindowInfo(windowID: windowID, processIdentifier: pid, layer: layer, boundsCG: CGRect(x: 0, y: 33, width: 1470, height: 900),
               alpha: 1, ownerName: "App \(pid)", title: nil)
}

private func button(_ label: String, windowID: CGWindowID?, pid: pid_t, isSystemChrome: Bool = false) -> GroundingElement {
    GroundingElement(role: .button, label: label, frameCG: CGRect(x: 8, y: 100, width: 290, height: 32), processIdentifier: pid,
                     windowID: windowID, displayID: 1, isInteractive: true, isSystemChrome: isSystemChrome, source: .accessibility)
}

// Air, 23 Nov, turns 140859 and 140914 (orders from Vello): the Claude window's walk came back empty, the list held only
// the menu bar and the Dock, and Pointer Assistant pointed by raw numbers at the sidebar it could see in the picture.
@Test func aFrontWindowWithNothingInAXWaitsForOCR() {
    let stack = WindowStack(windows: [window(10, pid: 200)], ownProcessIdentifier: 1, displays: [display])
    let menuAndDock = (0..<49).map { button("item \($0)", windowID: nil, pid: 300, isSystemChrome: true) }
    #expect(ColdPathOCRWait.elementsInFrontWindow(axElements: menuAndDock, windowStack: stack, cursorCG: CGPoint(x: 700, y: 400)) == 0)
    #expect(ColdPathOCRWait.shouldWait(axElements: menuAndDock, windowStack: stack, cursorCG: CGPoint(x: 700, y: 400)))
}

@Test func aFrontWindowReadByAXDoesNotWait() {
    let stack = WindowStack(windows: [window(10, pid: 200)], ownProcessIdentifier: 1, displays: [display])
    let sidebar = (0..<97).map { button("row \($0)", windowID: 10, pid: 200) }
    #expect(!ColdPathOCRWait.shouldWait(axElements: sidebar, windowStack: stack, cursorCG: CGPoint(x: 700, y: 400)))
}

@Test func onlyTheFrontWindowCounts() {
    // A window behind full of elements doesn't stand in for an empty one in front.
    let stack = WindowStack(windows: [window(10, pid: 200), window(11, pid: 201)], ownProcessIdentifier: 1, displays: [display])
    let behind = (0..<50).map { button("row \($0)", windowID: 11, pid: 201) }
    #expect(ColdPathOCRWait.shouldWait(axElements: behind, windowStack: stack, cursorCG: CGPoint(x: 700, y: 400)))
}

@Test func noAppWindowMeansNoWait() {
    let stack = WindowStack(windows: [], ownProcessIdentifier: 1, displays: [display])
    #expect(!ColdPathOCRWait.shouldWait(axElements: [], windowStack: stack, cursorCG: CGPoint(x: 700, y: 400)))
}
