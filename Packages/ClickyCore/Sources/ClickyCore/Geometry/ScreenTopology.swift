//
//  ScreenTopology.swift
//  ClickyCore
//
//  The one place screen coordinates are converted. Clicky v2 works in CG
//  global points: origin at the top-left of the main display (screens[0]),
//  y increasing downward — the same space as CGEvent, CGWindowList and the
//  Accessibility API. AppKit (NSScreen, NSWindow, NSEvent.mouseLocation)
//  uses the same x but measures y upward from the bottom of the main display.
//
//  Callers pass `flipH` = NSScreen.screens[0].frame.height (never
//  NSScreen.main, which follows keyboard focus) read on the main actor.
//

import CoreGraphics

public enum ScreenTopology {
    /// AppKit global point → CG global point. y' = H − y.
    public static func cg(fromAppKit appKitPoint: CGPoint, flipH: CGFloat) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: flipH - appKitPoint.y)
    }

    /// CG global point → AppKit global point. The flip is its own inverse.
    public static func appKit(fromCG cgPoint: CGPoint, flipH: CGFloat) -> CGPoint {
        CGPoint(x: cgPoint.x, y: flipH - cgPoint.y)
    }

    /// AppKit global rect → CG global rect. The rect's top edge in AppKit is
    /// its maxY, which becomes its minY in CG: y' = H − maxY.
    public static func cg(fromAppKit appKitRect: CGRect, flipH: CGFloat) -> CGRect {
        CGRect(x: appKitRect.minX, y: flipH - appKitRect.maxY, width: appKitRect.width, height: appKitRect.height)
    }

    /// CG global rect → AppKit global rect (same formula in reverse).
    public static func appKit(fromCG cgRect: CGRect, flipH: CGFloat) -> CGRect {
        CGRect(x: cgRect.minX, y: flipH - cgRect.maxY, width: cgRect.width, height: cgRect.height)
    }
}

// MARK: - Displays

/// One connected display, with every frame in CG global points.
public struct DisplayInfo: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let localizedName: String
    /// Whole display, CG global points (CGDisplayBounds).
    public let boundsCG: CGRect
    /// The area not covered by the menu bar or Dock (NSScreen.visibleFrame flipped).
    public let visibleCG: CGRect
    /// AppKit frame (NSScreen.frame), for code that still needs it.
    public let frameAppKit: CGRect
    public let isMain: Bool

    public init(displayID: CGDirectDisplayID, localizedName: String, boundsCG: CGRect, visibleCG: CGRect, frameAppKit: CGRect, isMain: Bool) {
        self.displayID = displayID
        self.localizedName = localizedName
        self.boundsCG = boundsCG
        self.visibleCG = visibleCG
        self.frameAppKit = frameAppKit
        self.isMain = isMain
    }

    /// Where this display sits relative to the main one, in words, so the
    /// model can tell identical monitors apart ("left of main").
    public func positionDescription(relativeTo mainBoundsCG: CGRect) -> String {
        if isMain { return "main" }
        if boundsCG.maxX <= mainBoundsCG.minX + 1 { return "left of main" }
        if boundsCG.minX >= mainBoundsCG.maxX - 1 { return "right of main" }
        if boundsCG.maxY <= mainBoundsCG.minY + 1 { return "above main" }
        if boundsCG.minY >= mainBoundsCG.maxY - 1 { return "below main" }
        return "overlapping main"
    }
}

extension ScreenTopology {
    /// Overlay-local point for a display's full-screen overlay window
    /// (top-left origin, y down): CG global minus the display's CG origin.
    public static func overlayLocal(fromCG cgPoint: CGPoint, displayBoundsCG: CGRect) -> CGPoint {
        CGPoint(x: cgPoint.x - displayBoundsCG.minX, y: cgPoint.y - displayBoundsCG.minY)
    }

    /// Native pixels per point for a capture: measured from the image, never
    /// from backingScaleFactor (which can lie for scaled display modes).
    public static func pixelsPerPoint(nativeWidthInPixels: CGFloat, regionWidthInPoints: CGFloat) -> CGFloat {
        guard regionWidthInPoints > 0 else { return 1 }
        return nativeWidthInPixels / regionWidthInPoints
    }

    /// The startup self-check: every display's AppKit frame, flipped, must
    /// agree with CGDisplayBounds within 0.5 pt, otherwise coordinates can't
    /// be trusted and grounding is turned off for this session.
    public static func flipDisagreements(displays: [DisplayInfo], flipH: CGFloat, tolerance: CGFloat = 0.5) -> [CGDirectDisplayID] {
        displays.compactMap { display in
            let flipped = cg(fromAppKit: display.frameAppKit, flipH: flipH)
            let isOff = abs(flipped.minX - display.boundsCG.minX) > tolerance
                || abs(flipped.minY - display.boundsCG.minY) > tolerance
                || abs(flipped.width - display.boundsCG.width) > tolerance
                || abs(flipped.height - display.boundsCG.height) > tolerance
            return isOff ? display.displayID : nil
        }
    }
}

#if canImport(AppKit)
import AppKit

extension ScreenTopology {
    /// Height of the main display (screens[0], never NSScreen.main, which
    /// follows keyboard focus): the flip height for every conversion.
    @MainActor
    public static var mainDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// The displays right now. Re-read per question and on screen changes;
    /// never cache across a display reconfiguration.
    @MainActor
    public static func current() -> [DisplayInfo] {
        let flipH = mainDisplayHeight
        return NSScreen.screens.enumerated().compactMap { screenIndex, screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            // Theo's hidden Studio screens aren't anything Clicky should see or point at.
            guard !StudioDisplays.virtualIDs.contains(displayID) else { return nil }
            return DisplayInfo(
                displayID: displayID,
                localizedName: screen.localizedName,
                boundsCG: CGDisplayBounds(displayID),
                visibleCG: cg(fromAppKit: screen.visibleFrame, flipH: flipH),
                frameAppKit: screen.frame,
                isMain: screenIndex == 0
            )
        }
    }
}
#endif
