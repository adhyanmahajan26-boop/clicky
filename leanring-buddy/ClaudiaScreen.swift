//
//  ClaudiaScreen.swift
//  leanring-buddy
//
//  "A screen of its own": the display Claudia uses for itself. With one
//  picked (Setup › Claudia's screen), the docked spark lives there, boards
//  and notes open there, and the browser windows / apps it opens are moved
//  there, so the owner's main screen is left alone. With none picked,
//  everything follows the pointer as before.
//

import AppKit
import ClickyCore

@MainActor
enum ClaudiaScreen {
    /// The picked display, if it's connected.
    static var picked: NSScreen? {
        let name = ClickySettings.claudiaScreenName
        guard !name.isEmpty else { return nil }
        return NSScreen.screens.first { $0.localizedName == name }
    }

    /// Where Claudia's own windows go: the picked display, else the pointer's.
    static var forClaudiasWindows: NSScreen? {
        picked ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    /// The docked spark's home: the picked display, else the one with the menu bar.
    static var forDockedSpark: NSScreen? { picked ?? NSScreen.screens.first }

    /// The docked spark's spot (AppKit global coordinates): near the bottom-right corner of the visible frame.
    static func dockedSparkPoint(on screen: NSScreen) -> CGPoint {
        CGPoint(x: screen.visibleFrame.maxX - 70, y: screen.visibleFrame.minY + 70)
    }

    /// Moves an app's front window onto Claudia's screen (same size, clamped), when a screen is picked.
    static func moveFrontWindow(of application: NSRunningApplication?) {
        guard let application, let screen = picked else { return }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        // Electron apps (T3 Code, Slack…) only expose their windows once asked to.
        AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Task { @MainActor in
            // The window may take a moment to appear (a fresh app or a new browser window).
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                var focusedWindow: CFTypeRef?
                AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
                let frontWindow = focusedWindow.map { $0 as! AXUIElement } ?? TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: applicationElement).first
                guard let window = frontWindow,
                      let frameCG = TypeForMeAccessibility.frameCG(of: window) else { continue }
                let targetCG = CGDisplayBounds(screen.displayID)
                guard !targetCG.contains(CGPoint(x: frameCG.midX, y: frameCG.midY)) else { return }
                let width = min(frameCG.width, targetCG.width - 40)
                let height = min(frameCG.height, targetCG.height - 80)
                var origin = CGPoint(x: targetCG.minX + (targetCG.width - width) / 2, y: targetCG.minY + 40)
                var size = CGSize(width: width, height: height)
                // Size first (a big window can't land on a smaller display), then position, then check it moved.
                var positionResult = AXError.failure
                var sizeResult = AXError.failure
                if let sizeValue = AXValueCreate(.cgSize, &size) {
                    sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
                }
                if let positionValue = AXValueCreate(.cgPoint, &origin) {
                    positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                let landed = TypeForMeAccessibility.frameCG(of: window).map { targetCG.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
                print("🖥️ Moved \(application.localizedName ?? "a window") to Theo's screen (\(screen.localizedName)): size \(sizeResult.rawValue), position \(positionResult.rawValue), landed \(landed)")
                if !landed { continue }
                return
            }
        }
    }
}
