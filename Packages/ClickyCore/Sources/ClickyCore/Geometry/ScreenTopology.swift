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
