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
    /// The picked display, if it's connected. Two monitors of the same model are told apart by macOS as
    /// "Name (1)" and "Name (2)", and those numbers can swap after a restart or a replug, which put Theo on
    /// the wrong one. So the picked display's side (left or right of the menu-bar display) is remembered
    /// too, and among same-model twins the side wins over the number.
    static var picked: NSScreen? {
        let name = ClickySettings.claudiaScreenName
        guard !name.isEmpty else { return nil }
        let defaults = UserDefaults.standard
        let twins = NSScreen.screens.filter { baseName($0.localizedName) == baseName(name) }
        if twins.count > 1, defaults.string(forKey: sideNameKey) == name, let side = defaults.string(forKey: sideKey) {
            return side == "right" ? twins.max { $0.frame.midX < $1.frame.midX } : twins.min { $0.frame.midX < $1.frame.midX }
        }
        let byName = NSScreen.screens.first { $0.localizedName == name }
        if let byName, twins.count > 1, let menuBarScreen = NSScreen.screens.first {
            defaults.set(byName.frame.midX >= menuBarScreen.frame.midX ? "right" : "left", forKey: sideKey)
            defaults.set(name, forKey: sideNameKey)
        }
        return byName
    }

    private static let sideKey = "v2.screen.claudia.side"
    private static let sideNameKey = "v2.screen.claudia.sideFor"

    /// "DELL S2725QC (1)" → "DELL S2725QC".
    private static func baseName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
    }

    /// Centres a Theo window on the picked display when it's somewhere else.
    static func place(_ window: NSWindow) {
        guard let screen = picked, window.screen != screen else { return }
        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
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

    /// Moves one specific window (already raised) onto Claudia's screen, same size clamped. No activation.
    static func move(window: AXUIElement, of application: NSRunningApplication?) {
        guard let screen = picked, let frameCG = TypeForMeAccessibility.frameCG(of: window) else { return }
        let targetCG = CGDisplayBounds(screen.displayID)
        guard !targetCG.contains(CGPoint(x: frameCG.midX, y: frameCG.midY)) else { return }
        var size = CGSize(width: min(frameCG.width, targetCG.width - 40), height: min(frameCG.height, targetCG.height - 80))
        var origin = CGPoint(x: targetCG.minX + (targetCG.width - size.width) / 2, y: targetCG.minY + 40)
        if let sizeValue = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) }
        if let positionValue = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) }
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
