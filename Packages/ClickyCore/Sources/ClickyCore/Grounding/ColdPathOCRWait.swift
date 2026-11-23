//
//  ColdPathOCRWait.swift
//  ClickyCore
//
//  A question with no prewarm (an order from Vello, a step's follow-up look,
//  a short push-to-talk) takes the cold path: the element list goes out with
//  AX only and OCR runs behind it. When the window in front on the cursor's
//  screen has next to nothing in AX (an app whose tree is empty right now, a
//  canvas, a page still loading), that list showed nothing of it at all and
//  Pointer Assistant said "the sidebar isn't readable" while it was right
//  there in the picture (Air, 23 Nov, turns 140859 and 140914, both orders
//  from Vello). Then the list waits a little for OCR instead.
//

import CoreGraphics
import Foundation

public enum ColdPathOCRWait {
    /// Fewer AX elements than this in the front window: its text comes from OCR or not at all.
    public static let thinWindowElementCount = 8
    /// The longest the list waits for OCR (it usually takes 0.3 to 0.5 s on one screen).
    public static let longestWaitSeconds = 0.9

    /// The front app window on the cursor's screen, and how many of `axElements` are in it (nil: no app window there).
    public static func elementsInFrontWindow(axElements: [GroundingElement], windowStack: WindowStack, cursorCG: CGPoint) -> Int? {
        guard let cursorDisplay = windowStack.displays.first(where: { $0.boundsCG.contains(cursorCG) }) ?? windowStack.displays.first,
              let frontWindow = windowStack.windows.first(where: { $0.isApplicationWindowLayer && $0.boundsCG.intersects(cursorDisplay.boundsCG) }) else {
            return nil
        }
        return axElements.filter { $0.windowID == frontWindow.windowID && !$0.isSystemChrome }.count
    }

    /// Whether the cold path waits for OCR before the list goes out.
    public static func shouldWait(axElements: [GroundingElement], windowStack: WindowStack, cursorCG: CGPoint) -> Bool {
        guard let count = elementsInFrontWindow(axElements: axElements, windowStack: windowStack, cursorCG: cursorCG) else { return false }
        return count < thinWindowElementCount
    }
}
