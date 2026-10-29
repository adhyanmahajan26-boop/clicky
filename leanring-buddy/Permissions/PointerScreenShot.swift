//
//  PointerScreenShot.swift
//  leanring-buddy
//
//  A full-resolution PNG of the screen the pointer is on, without Theo's own
//  windows or the pointer itself (hands-free "take a screenshot").
//

import AppKit
import ScreenCaptureKit

enum PointerScreenShot {
    enum Failure: Error { case noDisplay, encoding }

    @MainActor
    static func capturePNG() async throws -> Data {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareable.displays.first(where: { $0.displayID == screen?.displayID }) ?? shareable.displays.first else {
            throw Failure.noDisplay
        }
        let theoWindows = shareable.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let scale = screen?.backingScaleFactor ?? 2
        let settings = SCStreamConfiguration()
        settings.width = Int(CGFloat(display.width) * scale)
        settings.height = Int(CGFloat(display.height) * scale)
        settings.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: theoWindows),
                                                               configuration: settings)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.encoding }
        return png
    }
}
