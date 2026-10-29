//
//  SnapshotCapture.swift
//  leanring-buddy
//
//  Takes the screenshot a [SNAP:…] tag asks for (SnapshotTag.swift in ClickyCore
//  says what each target covers), saves it as a full-resolution PNG in
//  ~/Desktop/Clicky Screenshots, and puts it on the clipboard.
//
//  Clicky's own windows are left out unless the tag says "+marks": the overlay
//  (and its marks) is kept only then, so a plain shot shows the user's content.
//  The window target keeps just that window (anything covering it is left out
//  too), so the shot is never cut off by another app's window on top.
//

import AppKit
import ClickyCore
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One saved snapshot.
struct SnapshotResult {
    let fileURL: URL
    let target: SnapshotTarget
    let includesClickyOverlay: Bool
    /// The saved PNG's size in pixels.
    let pixelWidth: Int
    let pixelHeight: Int
    /// The captured area in CG global points (top-left origin).
    let regionCG: CGRect
}

@MainActor
enum SnapshotCapture {
    static let screenshotsFolderName = "Clicky Screenshots"

    /// The PNG of the most recent snapshot this session (code mode can attach it later).
    private(set) static var lastSavedPNGURL: URL?

    /// Takes the shot, saves it, and copies it to the clipboard. `markRectsCG`
    /// are the marks on screen right now (only the marks target uses them).
    static func capture(request: SnapshotRequest, markRectsCG: [CGRect]) async throws -> SnapshotResult {
        let captured: (image: CGImage, regionCG: CGRect)
        switch request.target {
        case .screen:
            let cursorDisplay = try cursorDisplay()
            captured = try await captureDisplay(cursorDisplay, regionCG: nil, includesClickyOverlay: request.includesClickyOverlay)
        case .marks:
            guard let markedRegionCG = SnapshotRegion.marksRegion(markRectsCG: markRectsCG) else {
                throw ScreenCaptureError(message: "There are no marks on screen to take a picture of.")
            }
            let display = try displayMostOverlapping(markedRegionCG)
            guard let clampedRegionCG = SnapshotRegion.clamped(markedRegionCG, to: display.boundsCG) else {
                throw ScreenCaptureError(message: "The marks are off the screen.")
            }
            captured = try await captureDisplay(display, regionCG: clampedRegionCG, includesClickyOverlay: request.includesClickyOverlay)
        case .window:
            captured = try await captureFrontmostWindow(includesClickyOverlay: request.includesClickyOverlay)
        case .board:
            // [SNAP:board] saves the whiteboard (AnswerSession → BoardController.exportBoard), never a screen capture.
            throw ScreenCaptureError(message: "A board is saved with the board export, not captured.")
        }
        let capturedImage = captured.image

        let snapshotFileURL = try nextSnapshotFileURL(capturedAt: Date())
        // Encoding a full-resolution PNG takes a moment; keep it off the main actor.
        let pngData = try await Task.detached(priority: .userInitiated) { try encodePNG(capturedImage) }.value
        try pngData.write(to: snapshotFileURL, options: .atomic)
        copyPNGToPasteboard(pngData)
        lastSavedPNGURL = snapshotFileURL
        print("📸 SnapshotCapture: saved \(snapshotFileURL.path) (\(request.target.rawValue), \(capturedImage.width)x\(capturedImage.height) px)")

        return SnapshotResult(
            fileURL: snapshotFileURL,
            target: request.target,
            includesClickyOverlay: request.includesClickyOverlay,
            pixelWidth: capturedImage.width,
            pixelHeight: capturedImage.height,
            regionCG: captured.regionCG
        )
    }

    /// For code mode (not wired yet): takes the shot and returns its PNG file URL.
    static func takeSnapshotPNGURL(request: SnapshotRequest, markRectsCG: [CGRect]) async throws -> URL {
        try await capture(request: request, markRectsCG: markRectsCG).fileURL
    }

    // MARK: - Targets

    /// A display (or a region of one) without Clicky's windows unless asked.
    private static func captureDisplay(_ display: DisplayInfo, regionCG: CGRect?, includesClickyOverlay: Bool) async throws -> (image: CGImage, regionCG: CGRect) {
        try await ScreenCaptureService.captureNativeImage(of: display, regionCG: regionCG, includesOwnWindows: includesClickyOverlay)
    }

    /// The topmost window of the frontmost app (the topmost one of any other
    /// app when Clicky itself is frontmost), captured on its own.
    private static func captureFrontmostWindow(includesClickyOverlay: Bool) async throws -> (image: CGImage, regionCG: CGRect) {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let targetWindow = frontmostNonClickyWindow(in: shareableContent) else {
            throw ScreenCaptureError(message: "No app window is on screen to take a picture of.")
        }
        let display = try displayMostOverlapping(targetWindow.frame)
        guard let regionCG = SnapshotRegion.clamped(targetWindow.frame, to: display.boundsCG) else {
            throw ScreenCaptureError(message: "That window is off the screen.")
        }
        guard let screenCaptureKitDisplay = shareableContent.displays.first(where: { $0.displayID == display.displayID }) else {
            throw ScreenCaptureError(message: "Display \(display.displayID) isn't available to ScreenCaptureKit")
        }

        // Only the target window (plus Clicky's windows with "+marks") is drawn, so
        // whatever covers the window on screen stays out of the shot.
        let ownWindows = includesClickyOverlay
            ? shareableContent.windows.filter { $0.owningApplication?.processID == getpid() }
            : []
        let contentFilter = SCContentFilter(display: screenCaptureKitDisplay, including: [targetWindow] + ownWindows)
        let pointPixelScale = CGFloat(SCShareableContent.info(for: contentFilter).pointPixelScale)
        let outputSize = RecheckMath.pixelSize(region: regionCG, pointPixelScale: pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = RecheckMath.sourceRect(region: regionCG, displayBounds: display.boundsCG)
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB

        let capturedImage = try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration)
        return (image: capturedImage, regionCG: regionCG)
    }

    /// Front to back: the first normal (layer 0) window of the frontmost app,
    /// else the first normal window of any app but Clicky.
    private static func frontmostNonClickyWindow(in shareableContent: SCShareableContent) -> SCWindow? {
        let ownProcessIdentifier = getpid()
        var windowsByNumber: [CGWindowID: SCWindow] = [:]
        for window in shareableContent.windows {
            windowsByNumber[window.windowID] = window
        }
        let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        var candidates: [(window: SCWindow, ownerProcessIdentifier: pid_t)] = []
        for windowInfo in windowInfoList {
            guard let windowLayer = (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue, windowLayer == 0,
                  let ownerProcessIdentifier = (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerProcessIdentifier != ownProcessIdentifier,
                  let windowNumber = (windowInfo[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let window = windowsByNumber[windowNumber],
                  window.frame.width >= 40, window.frame.height >= 40 else { continue }
            candidates.append((window, ownerProcessIdentifier))
        }
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return candidates.first(where: { $0.ownerProcessIdentifier == frontmostProcessIdentifier })?.window ?? candidates.first?.window
    }

    // MARK: - Displays

    /// The display the cursor is on (the main display if the cursor is off every display).
    private static func cursorDisplay() throws -> DisplayInfo {
        let displays = ScreenTopology.current()
        let cursorCG = ScreenTopology.cg(fromAppKit: NSEvent.mouseLocation, flipH: ScreenTopology.mainDisplayHeight)
        if let cursorDisplay = displays.first(where: { $0.boundsCG.contains(cursorCG) }) { return cursorDisplay }
        guard let fallbackDisplay = displays.first(where: \.isMain) ?? displays.first else {
            throw ScreenCaptureError(message: "No displays found")
        }
        return fallbackDisplay
    }

    /// The display a region (in CG points) overlaps the most.
    private static func displayMostOverlapping(_ regionCG: CGRect) throws -> DisplayInfo {
        guard let display = ScreenTopology.current().max(by: { overlapArea($0.boundsCG, regionCG) < overlapArea($1.boundsCG, regionCG) }) else {
            throw ScreenCaptureError(message: "No displays found")
        }
        return display
    }

    private static func overlapArea(_ rectCG: CGRect, _ otherRectCG: CGRect) -> CGFloat {
        let intersection = rectCG.intersection(otherRectCG)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    // MARK: - Files and clipboard

    /// ~/Desktop/Clicky Screenshots/Clicky YYYY-MM-DD at HH.mm.ss.png (a second
    /// shot in the same second gets " 2", " 3", …). Creates the folder.
    private static func nextSnapshotFileURL(capturedAt capturedDate: Date) throws -> URL {
        let folderURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(screenshotsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseFileName = "Clicky \(timestampFormatter.string(from: capturedDate))"

        var candidateURL = folderURL.appendingPathComponent("\(baseFileName).png")
        var duplicateNumber = 2
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateURL = folderURL.appendingPathComponent("\(baseFileName) \(duplicateNumber).png")
            duplicateNumber += 1
        }
        return candidateURL
    }

    /// The clipboard gets the PNG itself, so it pastes straight into an image field.
    private static func copyPNGToPasteboard(_ pngData: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }

    /// Runs off the main actor.
    nonisolated static func encodePNG(_ image: CGImage) throws -> Data {
        let pngData = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenCaptureError(message: "Couldn't create a PNG encoder")
        }
        CGImageDestinationAddImage(imageDestination, image, nil)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw ScreenCaptureError(message: "PNG encoding failed")
        }
        return pngData as Data
    }
}
